import Foundation

/// A bounded value crossing from the MainActor tool adapter into provider
/// orchestration. Provider request dictionaries are constructed only here.
struct AIEngineToolOutput: Sendable {
    let callID: String
    let output: String
    var browserScreenshot: BrowserScreenshotResult? = nil
    var savedScreenshot: ScreenshotProviderImage? = nil

    var providerValue: [String: Any] {
        ["type": "function_call_output", "call_id": callID, "output": output]
    }

    /// Preserve bounded semantic observation data while reporting whether the
    /// associated pixels actually reached this provider. Never forward a
    /// private capture URL or internal authority tokens as tool-result text.
    func providerOutput(imageAttached: Bool,
                        imageFailure: BrowserCaptureFailure? = nil) -> String {
        guard let data = output.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any] else {
            return "{\"image_attached\":false,\"error\":\"Image metadata was invalid.\"}"
        }
        func stripped(_ value: Any) -> Any {
            if let items = value as? [Any] { return items.map(stripped) }
            if let fields = value as? [String: Any] {
                let internalKeys: Set<String> = [
                    "fileURL", "file_url", "authorityRevision", "readRevision",
                    "navigationRevision", "pageIdentity"
                ]
                return fields.filter { !internalKeys.contains($0.key) }
                    .mapValues(stripped)
            }
            return value
        }
        var safe = stripped(object) as? [String: Any] ?? [:]
        safe["image_attached"] = imageAttached
        if let imageFailure {
            safe["visual_available"] = false
            safe["image_error"] = [
                "code": imageFailure.rawValue,
                "message": imageFailure.localizedDescription
            ]
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: safe,
                                                           options: [.sortedKeys]) else {
            return "{\"image_attached\":false,\"error\":\"Image metadata was invalid.\"}"
        }
        return String(decoding: encoded, as: UTF8.self)
    }
}

struct AIEngineScreenshotInput: Sendable {
    let callID: String
    let mediaType: String
    let base64: String
    let sourceDescription: String

    var responseInput: [String: Any] {
        ["role": "user", "content": [
            ["type": "input_text", "text": sourceDescription],
            ["type": "input_image", "image_url": "data:\(mediaType);base64,\(base64)"]
        ]]
    }
}

struct AIEngineEventBatchResult: Sendable {
    let responseID: String?
    let functionCalls: [AIOutputItem]
}

/// All calls from one provider response stay together across user reviews.
/// Results already committed by earlier siblings are retained, not replayed.
struct AIEnginePendingToolBatch: Sendable {
    let calls: [AIOutputItem]
    let history: [AIProviderMessage]
    let responseID: String
    let firstApprovalIndex: Int
    var nextIndex = 0
    var outputs: [AIEngineToolOutput] = []
}

/// UI, policy, and AppKit adapters. They are explicitly MainActor-isolated;
/// the provider/tool-round loop never inherits that isolation.
struct AIExecutionCallbacks: Sendable {
    let applyBatch: @MainActor @Sendable ([AIChatStreamEvent], String?) -> AIEngineEventBatchResult
    let canContinue: @MainActor @Sendable () -> Bool
    let persistResponseID: @MainActor @Sendable (String) async -> Void
    let fail: @MainActor @Sendable (String, Bool) -> Void
    let approvalRequired: @MainActor @Sendable (AIOutputItem) async -> Bool
    let queueApproval: @MainActor @Sendable (AIEnginePendingToolBatch) async -> Void
    let reserveSubagent: @MainActor @Sendable () -> Int?
    let executeTool: @MainActor @Sendable (AIOutputItem, Int?) async -> AIEngineToolOutput?
    let toolFailure: @MainActor @Sendable (AIOutputItem, String) -> AIEngineToolOutput?
    let persistPreparedOutputs: @MainActor @Sendable ([AIEngineToolOutput]) async -> Bool
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
        if let capture = output.browserScreenshot {
            guard await BrowserWorkspaceModel.shared.isScreenshotCurrent(capture),
                  let base64 = try? await BrowserScreenshotStore.shared.providerBase64(for: capture),
                  await BrowserWorkspaceModel.shared.isScreenshotCurrent(capture) else { return nil }
            await BrowserScreenshotStore.shared.markProviderImagePrepared(capture.captureID)
            return AIEngineScreenshotInput(
                callID: output.callID, mediaType: capture.mediaType, base64: base64,
                sourceDescription: "Browser screenshot from tool call \(output.callID)."
            )
        }
        if let image = output.savedScreenshot {
            guard await NativeCapabilityRouter.shared.isSavedScreenshotCurrent(image) else { return nil }
            return AIEngineScreenshotInput(
                callID: output.callID, mediaType: image.mediaType,
                base64: image.imageData.base64EncodedString(),
                sourceDescription: "Saved Screenshot History capture \(image.id.uuidString) from tool call \(output.callID)."
            )
        }
        return nil
    }

    /// Shared by ordinary tool rounds and a resumed exact-call approval. A
    /// visual result never passes raw pixels through function-call JSON.
    func prepareVisualOutput(
        _ output: AIEngineToolOutput, client: any AIChatTransport
    ) async -> (AIEngineToolOutput, AIEngineScreenshotInput?) {
        guard output.browserScreenshot != nil || output.savedScreenshot != nil else {
            return (output, nil)
        }
        let supportsImageInput = (client as? CLIChatProviderClient)?.provider != .claudeCLI
        guard supportsImageInput else {
            return (AIEngineToolOutput(
                callID: output.callID,
                output: output.providerOutput(imageAttached: false, imageFailure: .providerUnsupported)
            ), nil)
        }
        guard let image = await imageInput(for: output) else {
            return (AIEngineToolOutput(
                callID: output.callID,
                output: output.providerOutput(imageAttached: false, imageFailure: .expired)
            ), nil)
        }
        return (AIEngineToolOutput(
            callID: output.callID, output: output.providerOutput(imageAttached: true)
        ), image)
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

            var firstApprovalIndex: Int?
            for (index, call) in calls.enumerated() where firstApprovalIndex == nil {
                if await callbacks.approvalRequired(call) { firstApprovalIndex = index }
            }
            if let firstApprovalIndex {
                // Commit earlier siblings in provider order before presenting a
                // later call for review. Keep their outputs, never replay them
                // after the user responds to the approval.
                let prefixCalls = Array(calls.prefix(firstApprovalIndex))
                var prefixIndexedOutputs = Array<AIEngineToolOutput?>(repeating: nil, count: prefixCalls.count)
                var prefixComplete = true
                await withTaskGroup(of: (Int, AIEngineToolOutput?).self) { group in
                    var activeDelegations = 0
                    for (index, call) in prefixCalls.enumerated() {
                        guard await shouldContinue(callbacks) else {
                            prefixComplete = false
                            group.cancelAll()
                            break
                        }
                        if call.name == "agent_delegate" {
                            if activeDelegations >= max(1, subagentBudget.maximumConcurrent),
                               let completed = await group.next() {
                                activeDelegations -= 1
                                prefixIndexedOutputs[completed.0] = completed.1
                            }
                            if let ordinal = await callbacks.reserveSubagent() {
                                group.addTask {
                                    guard !Task.isCancelled else { return (index, nil) }
                                    var result = await callbacks.executeTool(call, ordinal)
                                    if result == nil {
                                        result = await callbacks.toolFailure(
                                            call, "The delegated Lima tool produced no result."
                                        )
                                    }
                                    return (index, result)
                                }
                                activeDelegations += 1
                            } else {
                                prefixIndexedOutputs[index] = await callbacks.toolFailure(
                                    call, "The run is no longer active; no new subagent can be started."
                                )
                            }
                        } else {
                            var result = await callbacks.executeTool(call, nil)
                            if result == nil {
                                result = await callbacks.toolFailure(call, "The Lima tool produced no result.")
                            }
                            prefixIndexedOutputs[index] = result
                        }
                    }
                    for await completed in group {
                        prefixIndexedOutputs[completed.0] = completed.1
                    }
                }
                let prefixOutputs = prefixIndexedOutputs.compactMap { $0 }
                guard prefixComplete, await shouldContinue(callbacks) else { break }
                guard prefixOutputs.count == prefixCalls.count else {
                    await callbacks.fail(
                        "A tool result was unavailable before approval. Retry the request after reviewing completed actions.",
                        false
                    )
                    break
                }
                for (index, result) in prefixOutputs.enumerated() {
                    health.observe(prefixCalls[index], output: result)
                }
                await callbacks.queueApproval(AIEnginePendingToolBatch(
                    calls: calls, history: currentHistory, responseID: responseID,
                    firstApprovalIndex: firstApprovalIndex,
                    nextIndex: firstApprovalIndex, outputs: prefixOutputs
                ))
                break
            }

            // Start independent children as their calls are encountered, up
            // to the run limit. Ordinary sibling tools keep provider order but
            // no longer delay already-requested child analyses.
            var indexedOutputs = Array<AIEngineToolOutput?>(repeating: nil, count: calls.count)
            var blocked = false
            let maximumConcurrent = max(1, subagentBudget.maximumConcurrent)
            await withTaskGroup(of: (Int, AIEngineToolOutput?).self) { group in
                var activeDelegations = 0
                for (index, call) in calls.enumerated() {
                    guard !Task.isCancelled, await callbacks.canContinue() else {
                        group.cancelAll()
                        break
                    }
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
                        group.cancelAll()
                        break
                    }
                    if blocked { break }
                    if call.name == "agent_delegate" {
                        if activeDelegations >= maximumConcurrent,
                           let completed = await group.next() {
                            activeDelegations -= 1
                            indexedOutputs[completed.0] = completed.1
                        }
                        guard let ordinal = await callbacks.reserveSubagent() else {
                            indexedOutputs[index] = await callbacks.toolFailure(
                                call,
                                "The run is no longer active; no new subagent can be started."
                            )
                            continue
                        }
                        group.addTask {
                            guard !Task.isCancelled else { return (index, nil) }
                            var output = await callbacks.executeTool(call, ordinal)
                            if output == nil {
                                output = await callbacks.toolFailure(
                                    call,
                                    "The delegated Lima tool produced no result; its outcome is uncertain. Do not retry it blindly."
                                )
                            }
                            return (index, output)
                        }
                        activeDelegations += 1
                    } else {
                        var result = await callbacks.executeTool(call, nil)
                        if result == nil {
                            result = await callbacks.toolFailure(
                                call, "The Lima tool produced no result; its outcome is uncertain. Do not retry it blindly."
                            )
                        }
                        indexedOutputs[index] = result
                    }
                }
                for await completed in group {
                    indexedOutputs[completed.0] = completed.1
                }
            }
            if blocked { break }
            let typedOutputs = indexedOutputs.compactMap { $0 }
            guard !Task.isCancelled, await callbacks.canContinue() else { break }
            guard typedOutputs.count == calls.count else {
                await callbacks.fail(
                    "One or more tool outcomes were unavailable. Completed actions were not retried; inspect the activity before trying again.",
                    false
                )
                break
            }
            for (index, output) in indexedOutputs.enumerated() {
                if let output { health.observe(calls[index], output: output) }
            }

            // Pixels are loaded only while the tab and read authority match.
            // Preserve semantic observation data even when image delivery fails;
            // neither private capture paths nor internal revisions enter text.
            var continuationOutputs: [AIEngineToolOutput] = []
            var images: [AIEngineScreenshotInput] = []
            for output in typedOutputs {
                let (prepared, image) = await prepareVisualOutput(output, client: client)
                continuationOutputs.append(prepared)
                if let image { images.append(image) }
            }
            guard !Task.isCancelled, await callbacks.canContinue(),
                  await callbacks.persistPreparedOutputs(continuationOutputs) else { break }

            let toolUses = calls.compactMap { call -> AIProviderMessage.Content? in
                guard let id = call.callID, let name = call.name else { return nil }
                return .toolUse(id: id, name: name, arguments: call.arguments ?? "{}")
            }
            let toolUseIDs = Set(calls.compactMap(\.callID))
            var toolResults = continuationOutputs.compactMap { output -> AIProviderMessage.Content? in
                guard toolUseIDs.contains(output.callID) else { return nil }
                return .toolResult(id: output.callID, output: output.output)
            }
            toolResults += images.map { .text($0.sourceDescription) }
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
