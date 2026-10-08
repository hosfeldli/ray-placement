import Foundation
import Testing
@testable import RayPlacement

private final class ParallelSubagentProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var peak = 0
    private var recordedOutputs: [[String: Any]] = []
    private var providerMCPCount: Int?
    private var providerToolNames: Set<String> = []

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

    func recordProviderRequest(servers: [MCPServer], tools: [LimaAIToolDefinition]) {
        lock.lock()
        providerMCPCount = servers.count
        providerToolNames = Set(tools.map(\.name))
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

    var providerSawNoDirectMCP: Bool {
        lock.lock()
        defer { lock.unlock() }
        return providerMCPCount == 0
    }

    func providerSawTool(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return providerToolNames.contains(name)
    }
}

#if DEBUG
@Test @MainActor func parallelChildApprovalsAreQueuedAndCancellationDrainsWaiters() async throws {
    let conversation = AIConversation()
    let model = AIChatViewModel(
        store: AIConversationStore(fixtures: [conversation]),
        credentials: AIChatCredentialStore(configuration: .fixture),
        mcpStore: MCPServerStore(fixtures: []),
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

@Test @MainActor func apiProviderDiscoversConnectedReadsThroughLimaWithoutDirectMCP() async {
    let serverID = UUID()
    let server = MCPServer(
        id: serverID, name: "Evidence", url: "https://example.invalid/mcp",
        tools: [MCPToolDescriptor(serverID: serverID, name: "lookup",
            risk: .read, enabled: true, declaredReadOnly: true)]
    )
    let probe = ParallelSubagentProbe()
    var transport = FixtureAITransport(events: [])
    transport.replyStream = { _, servers, tools in
        probe.recordProviderRequest(servers: servers, tools: tools)
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("Ready"))
            continuation.yield(.completed("api-broker-fixture"))
            continuation.finish()
        }
    }
    let model = AIChatViewModel(
        store: AIConversationStore(fixtures: [AIConversation(provider: .openAICompatible, model: "fixture-model")]),
        credentials: AIChatCredentialStore(configuration: .fixture),
        mcpStore: MCPServerStore(fixtures: [server]),
        nativeToolStore: LimaAIToolStore(fixtures: []),
        transport: transport
    )
    #expect(model.routedMCPServers(for: "Unrelated request").map(\.id) == [server.id])
    #expect(Set(model.requestLocalTools(for: "Unrelated request").map(\.name)) ==
            Set([CLIConnectedTools.listName, CLIConnectedTools.callName]))
    model.draft = "Reply briefly"
    model.send()
    for _ in 0..<300 where model.isStreaming {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(!model.isStreaming)
    #expect(probe.providerSawNoDirectMCP)
    #expect(probe.providerSawTool(CLIConnectedTools.listName))
    #expect(probe.providerSawTool(CLIConnectedTools.callName))
}

@Test @MainActor func twoSubagentsRunConcurrentlyAndKeepOrderedIndividualActivity() async throws {
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
    transport.replyStream = { input, servers, tools in
        if input == "Compare two sources" {
            probe.recordProviderRequest(servers: servers, tools: tools)
            return AsyncThrowingStream { continuation in
                continuation.yield(.responseCreated("parent-initial"))
                continuation.yield(delegate("child-a", "Analyze A"))
                continuation.yield(delegate("child-b", "Analyze B"))
                continuation.yield(.completed("parent-initial"))
                continuation.finish()
            }
        }
        probe.beganChild()
        let delay: Duration = input == "Analyze A" ? .milliseconds(120) : .milliseconds(20)
        return AsyncThrowingStream { continuation in
            Task {
                try? await Task.sleep(for: delay)
                probe.endedChild()
                continuation.yield(.textDelta(input == "Analyze A" ? "Analysis A" : "Analysis B"))
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
        mcpStore: MCPServerStore(fixtures: []),
        nativeToolStore: LimaAIToolStore(fixtures: ["agent_delegate"]),
        transport: transport,
        modelCatalog: catalog
    )
    model.draft = "Compare two sources"
    model.send()
    for _ in 0..<400 where model.isStreaming {
        try? await Task.sleep(for: .milliseconds(10))
    }

    #expect(!model.isStreaming)
    #expect(model.streamError == nil)
    #expect(probe.maximumConcurrentChildren == 2)
    #expect(probe.outputs.compactMap { $0["call_id"] as? String } == ["child-a", "child-b"])
    #expect((probe.outputs[0]["output"] as? String)?.contains("Analysis A") == true)
    #expect((probe.outputs[1]["output"] as? String)?.contains("Analysis B") == true)
    let activities = try #require(store.conversations.first?.messages.last?.activities)
    let children = AIActivityStream.steps(from: activities, isActive: false)
        .filter { $0.title.hasPrefix("Subagent ") }
    #expect(children.map(\.title) == ["Subagent 1", "Subagent 2"])
    #expect(children.allSatisfy { $0.status == .completed })
    #expect(children[0].detail?.contains("Analyze A") == true)
    #expect(children[1].detail?.contains("Analyze B") == true)
}
