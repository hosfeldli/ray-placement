import Foundation

/// A bounded value crossing from the MainActor tool adapter into provider
/// orchestration. Provider request dictionaries are constructed only here.
struct AIEngineToolOutput: Sendable {
    let callID: String
    let output: String
    var browserScreenshot: BrowserScreenshotResult? = nil

    var providerValue: [String: Any] {
        ["type": "function_call_output", "call_id": callID, "output": output]
    }
}

struct AIEngineScreenshotInput: Sendable {
    let callID: String
    let mediaType: String
    let base64: String

    var responseInput: [String: Any] {
        ["role": "user", "content": [
            ["type": "input_text", "text": "Browser screenshot from tool call \(callID)."],
            ["type": "input_image", "image_url": "data:\(mediaType);base64,\(base64)"]
        ]]
    }
}

struct AIEngineEventBatchResult: Sendable {
    let responseID: String?
    let functionCalls: [AIOutputItem]
}

/// UI, policy, and AppKit adapters. They are explicitly MainActor-isolated;
/// the provider/tool-round loop never inherits that isolation.
struct AIExecutionCallbacks: Sendable {
    let applyBatch: @MainActor @Sendable ([AIChatStreamEvent], String?) -> AIEngineEventBatchResult
    let canContinue: @MainActor @Sendable () -> Bool
    let persistResponseID: @MainActor @Sendable (String) -> Void
    let fail: @MainActor @Sendable (String, Bool) -> Void
    let approvalRequired: @MainActor @Sendable (AIOutputItem) async -> Bool
    let queueApproval: @MainActor @Sendable (AIOutputItem) async -> Void
    let reserveSubagent: @MainActor @Sendable () -> Int?
    let executeTool: @MainActor @Sendable (AIOutputItem, Int?) async -> AIEngineToolOutput?
    let toolFailure: @MainActor @Sendable (AIOutputItem, String) -> AIEngineToolOutput?
}

struct AIExecutionHealth {
    enum Decision: Equatable {
        case execute
        case suggestRecovery
        case blocked
    }

    private var failedFingerprint: String?
    private var consecutiveEquivalentFailures = 0

    func decision(for call: AIOutputItem) -> Decision {
        guard fingerprint(call) == failedFingerprint else { return .execute }
        if consecutiveEquivalentFailures >= 6 { return .blocked }
        if consecutiveEquivalentFailures >= 3 { return .suggestRecovery }
        return .execute
    }

    mutating func observe(_ call: AIOutputItem, output: AIEngineToolOutput) {
        guard Self.isFailure(output.output) else {
            failedFingerprint = nil
            consecutiveEquivalentFailures = 0
            return
        }
        let current = fingerprint(call)
        if current == failedFingerprint { consecutiveEquivalentFailures += 1 }
        else {
            failedFingerprint = current
            consecutiveEquivalentFailures = 1
        }
    }

    private func fingerprint(_ call: AIOutputItem) -> String {
        let arguments = call.arguments ?? "{}"
        let canonical: String
        if let data = arguments.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let sorted = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let text = String(data: sorted, encoding: .utf8) {
            canonical = text
        } else {
            canonical = arguments
        }
        return (call.name ?? "") + "\n" + canonical
    }

    private static func isFailure(_ output: String) -> Bool {
        guard let data = output.data(using: .utf8),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let state = body["state"] as? String
        return (body["error"] != nil && !(body["error"] is NSNull)) ||
            body["is_error"] as? Bool == true || state == "failed" || state == "cancelled"
    }

    static func recoveryOutput(callID: String) -> AIEngineToolOutput {
        AIEngineToolOutput(callID: callID, output: #"{"state":"failed","error":{"code":"repeated_action_without_progress","message":"The same action has failed repeatedly and was not executed again.","recoverable":true,"next_action":"Read fresh state, inspect the failure, or choose a different action before retrying."}}"#)
    }
}

/// Owns provider-stream consumption, deduplication, task-driven tool continuation,
/// child scheduling, and provider history assembly off the MainActor.
/// Presentation and OS-bound tool adapters are invoked through narrow callbacks.
actor AIExecutionEngine {
    private struct StreamCycle {
        let responseID: String?
        let functionCalls: [AIOutputItem]
    }

    private let providerStreamDeadline: Duration
    private var inFlightLoopsByAssistantID: [UUID: Int] = [:]

    #if DEBUG
    func inFlightLoopCountForTesting() -> Int {
        inFlightLoopsByAssistantID.values.reduce(0, +)
    }
    #endif

    init(providerStreamDeadline: Duration) {
        self.providerStreamDeadline = providerStreamDeadline
    }

    private func shouldContinue(_ callbacks: AIExecutionCallbacks) async -> Bool {
        guard !Task.isCancelled else { return false }
        return await callbacks.canContinue()
    }

    private func imageInput(for output: AIEngineToolOutput) async -> AIEngineScreenshotInput? {
        guard let capture = output.browserScreenshot,
              await BrowserWorkspaceModel.shared.isScreenshotCurrent(capture),
              let base64 = try? await BrowserScreenshotStore.shared.providerBase64(for: capture),
              await BrowserWorkspaceModel.shared.isScreenshotCurrent(capture) else { return nil }
        return AIEngineScreenshotInput(callID: output.callID,
                                      mediaType: capture.mediaType, base64: base64)
    }

    func runToolLoop(
        assistantID: UUID,
        initialStream: AsyncThrowingStream<AIChatStreamEvent, Error>,
        client: any AIChatTransport,
        apiKey: String,
        model: String,
        reasoningEffort: AIReasoningEffort,
        localTools: [LimaAIToolDefinition],
        history: [AIProviderMessage],
        initialResponseID: String?,
        subagentBudget: AIExecutionSubagentBudget,
        systemInstructions: String,
        callbacks: AIExecutionCallbacks
    ) async -> String? {
        inFlightLoopsByAssistantID[assistantID, default: 0] += 1
        defer {
            let remaining = (inFlightLoopsByAssistantID[assistantID] ?? 1) - 1
            if remaining == 0 {
                inFlightLoopsByAssistantID.removeValue(forKey: assistantID)
            } else {
                inFlightLoopsByAssistantID[assistantID] = remaining
            }
        }
        var stream = initialStream
        var currentHistory = history
        var latestResponseID = initialResponseID
        var handledCallIDs = Set<String>()
        var health = AIExecutionHealth()

        while await shouldContinue(callbacks) {
            let cycle = await consume(
                stream: stream,
                initialResponseID: latestResponseID,
                callbacks: callbacks
            )
            latestResponseID = cycle.responseID ?? latestResponseID
            if let latestResponseID {
                await callbacks.persistResponseID(latestResponseID)
            }
            guard !Task.isCancelled,
                  await callbacks.canContinue(),
                  let responseID = latestResponseID else { break }

            let calls = cycle.functionCalls.filter {
                guard let callID = $0.callID, !handledCallIDs.contains(callID) else { return false }
                handledCallIDs.insert(callID)
                return true
            }
            guard !calls.isEmpty else { break }

            var approvalCall: AIOutputItem?
            for call in calls where approvalCall == nil {
                if await callbacks.approvalRequired(call) { approvalCall = call }
            }
            if let approvalCall {
                await callbacks.queueApproval(approvalCall)
                break
            }

            // Independent child analyses from one provider response may run
            // concurrently. Other calls keep their original sequential order.
            var indexedOutputs = Array<AIEngineToolOutput?>(repeating: nil, count: calls.count)
            var delegations: [(index: Int, call: AIOutputItem, ordinal: Int)] = []
            var blocked = false
            for (index, call) in calls.enumerated() {
                guard !Task.isCancelled, await callbacks.canContinue() else { break }
                switch health.decision(for: call) {
                case .execute:
                    break
                case .suggestRecovery:
                    if let callID = call.callID {
                        indexedOutputs[index] = AIExecutionHealth.recoveryOutput(callID: callID)
                    }
                    continue
                case .blocked:
                    await callbacks.fail("The task is blocked: the same action failed repeatedly without progress. Read fresh state or change approach before retrying.", false)
                    blocked = true
                    break
                }
                if blocked { break }
                if call.name == "agent_delegate" {
                    guard let ordinal = await callbacks.reserveSubagent() else {
                        indexedOutputs[index] = await callbacks.toolFailure(
                            call,
                            "The run is no longer active; no new subagent can be started."
                        )
                        continue
                    }
                    delegations.append((index, call, ordinal))
                } else {
                    indexedOutputs[index] = await callbacks.executeTool(call, nil)
                }
            }
            if blocked { break }
            let maximumConcurrent = max(1, subagentBudget.maximumConcurrent)
            for batchStart in stride(from: 0, to: delegations.count, by: maximumConcurrent) {
                guard !Task.isCancelled, await callbacks.canContinue() else { break }
                let batch = delegations[batchStart..<min(delegations.count, batchStart + maximumConcurrent)]
                await withTaskGroup(of: (Int, AIEngineToolOutput)?.self) { group in
                    for delegation in batch {
                        group.addTask {
                            guard !Task.isCancelled,
                                  let output = await callbacks.executeTool(delegation.call, delegation.ordinal)
                            else { return nil }
                            return (delegation.index, output)
                        }
                    }
                    for await completed in group {
                        guard let completed else { continue }
                        indexedOutputs[completed.0] = completed.1
                    }
                }
            }
            let typedOutputs = indexedOutputs.compactMap { $0 }
            guard !Task.isCancelled, await callbacks.canContinue(), !typedOutputs.isEmpty else { break }
            for (index, output) in indexedOutputs.enumerated() {
                if let output { health.observe(calls[index], output: output) }
            }

            // Pixels are loaded only while the tab and read authority match.
            // Codex CLI and API providers receive ephemeral image input;
            // Claude CLI remains text-only. Never expose private capture paths.
            let supportsImageInput = (client as? CLIChatProviderClient)?.provider != .claudeCLI
            var continuationOutputs: [AIEngineToolOutput] = []
            var images: [AIEngineScreenshotInput] = []
            for output in typedOutputs {
                if let capture = output.browserScreenshot {
                    if supportsImageInput, let image = await imageInput(for: output) {
                        // The model needs dimensions and pixels, not a private
                        // on-disk path or internal revision tokens.
                        continuationOutputs.append(AIEngineToolOutput(
                            callID: output.callID,
                            output: "{\"tab_id\":\"\(capture.tabID.uuidString)\",\"media_type\":\"image/jpeg\",\"pixel_width\":\(capture.pixelWidth),\"pixel_height\":\(capture.pixelHeight),\"image_attached\":true}"
                        ))
                        images.append(image)
                    } else if supportsImageInput {
                        continuationOutputs.append(AIEngineToolOutput(
                            callID: output.callID,
                            output: "{\"error\":\"The Browser screenshot changed or was removed before its pixels could be delivered. Capture it again.\"}"
                        ))
                    } else {
                        continuationOutputs.append(AIEngineToolOutput(
                            callID: output.callID,
                            output: #"{"image_attached":false,"reason":"This CLI provider cannot inspect Browser screenshot pixels."}"#
                        ))
                    }
                } else {
                    continuationOutputs.append(output)
                }
            }
            guard !Task.isCancelled, await callbacks.canContinue() else { break }

            let toolUses = calls.compactMap { call -> AIProviderMessage.Content? in
                guard let id = call.callID, let name = call.name else { return nil }
                return .toolUse(id: id, name: name, arguments: call.arguments ?? "{}")
            }
            let toolUseIDs = Set(calls.compactMap(\.callID))
            var toolResults = continuationOutputs.compactMap { output -> AIProviderMessage.Content? in
                guard toolUseIDs.contains(output.callID) else { return nil }
                return .toolResult(id: output.callID, output: output.output)
            }
            toolResults += images.map { .text("Browser screenshot from tool call \($0.callID).") }
            toolResults += images.map { .image(mediaType: $0.mediaType, base64: $0.base64) }
            if !toolUses.isEmpty {
                currentHistory.append(AIProviderMessage(role: .assistant, content: toolUses))
            }
            if !toolResults.isEmpty {
                currentHistory.append(AIProviderMessage(role: .user, content: toolResults))
            }
            stream = client.streamToolOutputs(
                apiKey: apiKey,
                model: model,
                previousResponseID: responseID,
                history: currentHistory,
                outputs: continuationOutputs.map(\.providerValue) + images.map(\.responseInput),
                reasoningEffort: reasoningEffort,
                localTools: localTools,
                systemInstructions: systemInstructions
            )
        }
        return latestResponseID
    }

    private func consume(
        stream: AsyncThrowingStream<AIChatStreamEvent, Error>,
        initialResponseID: String?,
        callbacks: AIExecutionCallbacks
    ) async -> StreamCycle {
        var responseID = initialResponseID
        var functionCalls: [AIOutputItem] = []
        var completed = false
        do {
            let bounded = AIProviderStreamWatchdog.bounded(stream, after: providerStreamDeadline)
            eventBatches: for try await batch in AIProviderEventBatcher.batches(bounded) {
                guard !Task.isCancelled, await callbacks.canContinue() else { break }
                let applied = await callbacks.applyBatch(batch, responseID)
                responseID = applied.responseID
                functionCalls += applied.functionCalls
                for event in batch {
                    if case .completed = event {
                        completed = true
                        break eventBatches
                    }
                    if case .failed = event { break eventBatches }
                }
            }
        } catch is AIProviderStreamWatchdog.DeadlineExceeded {
            if await shouldContinue(callbacks) {
                await callbacks.fail(AIProviderFailure.timeoutMessage, true)
            }
        } catch {
            if await shouldContinue(callbacks) {
                await callbacks.fail("AI Chat couldn’t complete this request.", false)
            }
        }
        if !completed, await shouldContinue(callbacks) {
            await callbacks.fail("The provider stream ended before the response completed.", false)
        }
        return StreamCycle(
            responseID: responseID,
            functionCalls: await callbacks.canContinue() ? functionCalls : []
        )
    }
}
