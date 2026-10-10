import Foundation
import Testing
@testable import RayPlacement

private final class ParallelSubagentProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var peak = 0
    private var recordedOutputs: [[String: Any]] = []

    func beganChild() {
        lock.lock()
        active += 1
        peak = max(peak, active)
        lock.unlock()
    }

    func endedChild() {
        lock.lock()
        active -= 1
        lock.unlock()
    }

    func recordOutputs(_ outputs: [[String: Any]]) {
        lock.lock()
        recordedOutputs = outputs
        lock.unlock()
    }

    var maximumConcurrentChildren: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    var outputs: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedOutputs
    }

}

#if DEBUG
@Test @MainActor func parallelChildApprovalsAreQueuedAndCancellationDrainsWaiters() async throws {
    let conversation = AIConversation()
    let model = AIChatViewModel(
        store: AIConversationStore(fixtures: [conversation]),
        credentials: AIChatCredentialStore(configuration: .fixture),
        nativeToolStore: LimaAIToolStore(fixtures: ["run_terminal_command"]),
        transport: FixtureAITransport.standard
    )
    func terminalCall(_ id: String) -> AIOutputItem {
        AIOutputItem(
            phase: .completed, apiType: "function_call", callID: id,
            name: "run_terminal_command", arguments: "{}"
        )
    }
    let first = Task { await model.requestSubagentApprovalForTesting(terminalCall("first"), conversationID: conversation.id) }
    for _ in 0..<100 {
        if model.pendingApproval?.localCallID == "first" { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
    let second = Task { await model.requestSubagentApprovalForTesting(terminalCall("second"), conversationID: conversation.id) }
    for _ in 0..<100 {
        if model.queuedSubagentApprovalCountForTesting == 1 { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.pendingApproval?.localCallID == "first")
    #expect(model.queuedSubagentApprovalCountForTesting == 1)
    model.resolvePendingApproval(allow: true)
    #expect(await first.value)
    #expect(model.pendingApproval?.localCallID == "second")
    model.resolvePendingApproval(allow: false)
    #expect(!(await second.value))
    #expect(model.pendingApproval == nil)

    let third = Task { await model.requestSubagentApprovalForTesting(terminalCall("third"), conversationID: conversation.id) }
    for _ in 0..<100 {
        if model.pendingApproval?.localCallID == "third" { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
    let fourth = Task { await model.requestSubagentApprovalForTesting(terminalCall("fourth"), conversationID: conversation.id) }
    for _ in 0..<100 {
        if model.queuedSubagentApprovalCountForTesting == 1 { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
    model.cancelSubagentApprovalsForTesting()
    #expect(!(await third.value))
    #expect(!(await fourth.value))
    #expect(model.pendingApproval == nil)
    #expect(model.queuedSubagentApprovalCountForTesting == 0)
}
#endif

@Test @MainActor func configuredSubagentBudgetBoundsConcurrencyAndAllowsMoreThanThreeChildren() async throws {
    let suite = "ParallelSubagent.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let catalog = AIModelCatalogStore(defaults: defaults)
    catalog.retain(AIModelOption(id: "fixture-model"), for: .openAICompatible)
    let probe = ParallelSubagentProbe()

    func delegate(_ id: String, _ task: String) -> AIChatStreamEvent {
        .outputItem(AIOutputItem(
            phase: .completed, apiType: "function_call", callID: id,
            name: "agent_delegate",
            arguments: "{\"provider\":\"openAICompatible\",\"model\":\"fixture-model\",\"task\":\"\(task)\"}"
        ))
    }

    var transport = FixtureAITransport(events: [])
    transport.toolOutputEvents = [.textDelta("Combined answer"), .completed("parent-final")]
    transport.onToolOutputs = { outputs, _ in probe.recordOutputs(outputs) }
    transport.replyStream = { input, _ in
        if input == "Compare two sources" {
            return AsyncThrowingStream { continuation in
                continuation.yield(.responseCreated("parent-initial"))
                continuation.yield(delegate("child-a", "Analyze A"))
                continuation.yield(delegate("child-b", "Analyze B"))
                continuation.yield(delegate("child-c", "Analyze C"))
                continuation.yield(delegate("child-d", "Analyze D"))
                continuation.yield(.completed("parent-initial"))
                continuation.finish()
            }
        }
        probe.beganChild()
        let delay: Duration
        switch input {
        case "Analyze A": delay = .milliseconds(120)
        case "Analyze B": delay = .milliseconds(20)
        default: delay = .milliseconds(10)
        }
        return AsyncThrowingStream { continuation in
            Task {
                try? await Task.sleep(for: delay)
                probe.endedChild()
                continuation.yield(.textDelta("Analysis \(input.suffix(1))"))
                continuation.yield(.completed("child-result"))
                continuation.finish()
            }
        }
    }

    let store = AIConversationStore(fixtures: [
        AIConversation(provider: .openAICompatible, model: "fixture-model")
    ])
    let model = AIChatViewModel(
        store: store,
        credentials: AIChatCredentialStore(configuration: .fixture),
        nativeToolStore: LimaAIToolStore(fixtures: ["agent_delegate"]),
        transport: transport,
        modelCatalog: catalog,
        subagentBudgetOverride: AIExecutionSubagentBudget(maximumConcurrent: 2, maximumPerRun: 4)
    )
    model.draft = "Compare two sources"
    model.send()
    for _ in 0..<400 where model.isStreaming {
        try? await Task.sleep(for: .milliseconds(10))
    }

    #expect(!model.isStreaming)
    #expect(model.streamError == nil)
    #expect(probe.maximumConcurrentChildren == 2)
    #expect(probe.outputs.compactMap { $0["call_id"] as? String } == ["child-a", "child-b", "child-c", "child-d"])
    #expect((probe.outputs[0]["output"] as? String)?.contains("Analysis A") == true)
    #expect((probe.outputs[1]["output"] as? String)?.contains("Analysis B") == true)
    #expect((probe.outputs[2]["output"] as? String)?.contains("Analysis C") == true)
    #expect((probe.outputs[3]["output"] as? String)?.contains("Analysis D") == true)
    #expect(model.executionRun?.subagentRequestsUsed == 4)
    #expect(model.executionRun?.subagents.count == 4)
    #expect(model.executionRun?.subagents.allSatisfy { $0.state == .completed } == true)
    let activities = try #require(store.conversations.first?.messages.last?.activities)
    let children = AIActivityStream.steps(from: activities, isActive: false)
        .filter { $0.title.hasPrefix("Subagent ") }
    #expect(children.map(\.title) == ["Subagent 1", "Subagent 2", "Subagent 3", "Subagent 4"])
    #expect(children.allSatisfy { $0.status == .completed })
    #expect(children[0].detail?.contains("Analyze A") == true)
    #expect(children[1].detail?.contains("Analyze B") == true)
    #expect(children[2].detail?.contains("Analyze C") == true)
    #expect(children[3].detail?.contains("Analyze D") == true)
}
