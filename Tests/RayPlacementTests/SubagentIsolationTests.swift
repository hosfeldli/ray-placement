import Foundation
import Testing
@testable import RayPlacement

private struct InspectingChildTransport: AIChatTransport {
    func listModels(apiKey: String) async throws -> [AIModelOption] { [] }

    func streamReply(apiKey: String, model: String, input: String,
                     history: [AIProviderMessage], previousResponseID: String?,
                     reasoningEffort: AIReasoningEffort, attachments: [AIAttachment],
                     mcpServers: [MCPServer], localTools: [LimaAIToolDefinition],
                     systemInstructions: String) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        #expect(apiKey == "fixture-only")
        #expect(model == "selected-analysis-model")
        #expect(input == "Review only this supplied evidence.")
        #expect(history.isEmpty)
        #expect(previousResponseID == nil)
        #expect(attachments.isEmpty)
        #expect(mcpServers.isEmpty)
        #expect(localTools.isEmpty)
        #expect(systemInstructions.contains("every Lima tool routed for the parent"))
        #expect(systemInstructions.contains("untrusted data"))
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("Bounded findings"))
            continuation.yield(.completed("child-fixture"))
            continuation.finish()
        }
    }

    func streamApproval(apiKey: String, model: String, previousResponseID: String,
                        requestID: String, approve: Bool, reason: String?,
                        reasoningEffort: AIReasoningEffort, mcpServers: [MCPServer],
                        localTools: [LimaAIToolDefinition],
                        systemInstructions: String) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        Issue.record("A child must never request approval.")
        return AsyncThrowingStream { $0.finish() }
    }

    func streamToolOutputs(apiKey: String, model: String, previousResponseID: String,
                           history: [AIProviderMessage], outputs: [[String: Any]],
                           reasoningEffort: AIReasoningEffort, mcpServers: [MCPServer],
                           localTools: [LimaAIToolDefinition],
                           systemInstructions: String) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        Issue.record("A child must never start a tool loop.")
        return AsyncThrowingStream { $0.finish() }
    }
}

private struct ReadToolChildTransport: AIChatTransport {
    func listModels(apiKey: String) async throws -> [AIModelOption] { [] }

    func streamReply(apiKey: String, model: String, input: String,
                     history: [AIProviderMessage], previousResponseID: String?,
                     reasoningEffort: AIReasoningEffort, attachments: [AIAttachment],
                     mcpServers: [MCPServer], localTools: [LimaAIToolDefinition],
                     systemInstructions: String) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        #expect(history.isEmpty)
        #expect(previousResponseID == nil)
        #expect(localTools.map(\.name) == ["fixture_read", CLIConnectedTools.listName, CLIConnectedTools.callName])
        #expect(mcpServers.isEmpty)
        return AsyncThrowingStream { continuation in
            continuation.yield(.responseCreated("child-response-1"))
            continuation.yield(.outputItem(AIOutputItem(
                phase: .completed, apiType: "function_call", callID: "read-call",
                name: CLIConnectedTools.callName, arguments: "{}"
            )))
            continuation.yield(.completed("child-response-1"))
            continuation.finish()
        }
    }

    func streamApproval(apiKey: String, model: String, previousResponseID: String,
                        requestID: String, approve: Bool, reason: String?,
                        reasoningEffort: AIReasoningEffort, mcpServers: [MCPServer],
                        localTools: [LimaAIToolDefinition],
                        systemInstructions: String) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        Issue.record("A child must never request approval.")
        return AsyncThrowingStream { $0.finish() }
    }

    func streamToolOutputs(apiKey: String, model: String, previousResponseID: String,
                           history: [AIProviderMessage], outputs: [[String: Any]],
                           reasoningEffort: AIReasoningEffort, mcpServers: [MCPServer],
                           localTools: [LimaAIToolDefinition],
                           systemInstructions: String) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        #expect(previousResponseID == "child-response-1")
        #expect(outputs.count == 1)
        #expect(outputs.first?["call_id"] as? String == "read-call")
        #expect(outputs.first?["output"] as? String == "bounded MCP read result")
        #expect(mcpServers.isEmpty)
        #expect(history.count == 2)
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("Read-only analysis complete."))
            continuation.yield(.completed("child-response-2"))
            continuation.finish()
        }
    }
}

private struct ApprovalToolChildTransport: AIChatTransport {
    func listModels(apiKey: String) async throws -> [AIModelOption] { [] }

    func streamReply(apiKey: String, model: String, input: String,
                     history: [AIProviderMessage], previousResponseID: String?,
                     reasoningEffort: AIReasoningEffort, attachments: [AIAttachment],
                     mcpServers: [MCPServer], localTools: [LimaAIToolDefinition],
                     systemInstructions: String) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        #expect(localTools.contains { $0.name == "run_terminal_command" })
        return AsyncThrowingStream { continuation in
            continuation.yield(.responseCreated("child-response-1"))
            continuation.yield(.outputItem(AIOutputItem(
                phase: .completed, apiType: "function_call", callID: "terminal-call",
                name: "run_terminal_command", arguments: "{}"
            )))
            continuation.yield(.completed("child-response-1"))
            continuation.finish()
        }
    }

    func streamApproval(apiKey: String, model: String, previousResponseID: String,
                        requestID: String, approve: Bool, reason: String?,
                        reasoningEffort: AIReasoningEffort, mcpServers: [MCPServer],
                        localTools: [LimaAIToolDefinition],
                        systemInstructions: String) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        Issue.record("Subagent tool approvals must go through the parent's Lima UI.")
        return AsyncThrowingStream { $0.finish() }
    }

    func streamToolOutputs(apiKey: String, model: String, previousResponseID: String,
                           history: [AIProviderMessage], outputs: [[String: Any]],
                           reasoningEffort: AIReasoningEffort, mcpServers: [MCPServer],
                           localTools: [LimaAIToolDefinition],
                           systemInstructions: String) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        #expect(outputs.first?["output"] as? String == "Terminal ran after approval")
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("Approved tool result received."))
            continuation.yield(.completed("child-response-2"))
            continuation.finish()
        }
    }
}

@Test @MainActor func subagentPausesForParentApprovalBeforeRunningRestrictedTools() async {
    let suite = "SubagentApproval.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let policy = AIComputerActionPolicy(defaults: defaults)
    policy.setAccess(.askEveryTime, for: .terminal)
    let terminal = LimaAIToolDefinition(
        id: "run_terminal_command", name: "run_terminal_command", description: "Run bounded local commands.",
        parameters: ["type": "object", "properties": [:] as [String: Any], "additionalProperties": false],
        risk: .localAction, actionCategory: .terminal
    )
    let result = await AISubagentRunner.run(
        client: ApprovalToolChildTransport(), apiKey: "fixture-only",
        model: AIModelOption(id: "selected-analysis-model"), task: "Run the approved bounded check.",
        localTools: [terminal], actionPolicy: policy,
        requestApproval: { call in call.callID == "terminal-call" },
        executeTool: { call, approvalGranted in
            #expect(call.name == "run_terminal_command")
            #expect(approvalGranted)
            return "Terminal ran after approval"
        }
    )
    #expect(!result.isError)
    #expect(result.output.contains("Approved tool result received."))
}

#if DEBUG
@Test @MainActor func streamingAuditTracksTheActiveAssistantAndPreservesVisibleText() throws {
    let model = AIChatVisualFixtures.model(for: .streaming)
    let message = try #require(model.selectedConversation?.messages.last)
    #expect(model.isStreaming)
    #expect(model.streamingTextAssistantID == message.id)
    #expect(model.visibleText(for: message) == message.text)
    #expect(model.visibleReasoningSummary(for: message) == message.reasoningSummary)
    model.applyVisualFixture(isStreaming: false)
    #expect(model.streamingTextAssistantID == nil)
    #expect(model.visibleText(for: message) == message.text)
}
#endif

@Test @MainActor func selectedChildModelReceivesOnlyItsExplicitTask() async {
    let result = await AISubagentRunner.run(client: InspectingChildTransport(), apiKey: "fixture-only",
        model: AIModelOption(id: "selected-analysis-model"), task: "Review only this supplied evidence.",
        executeTool: { _, _ in nil })
    #expect(!result.isError)
    #expect(result.output.contains("Bounded findings"))
    #expect(result.output.contains("selected-analysis-model"))
}

@Test @MainActor func subagentUsesRoutedToolsAndLimaMediatedReadOnlyMCP() async {
    let serverID = UUID()
    let safeMCP = MCPToolDescriptor(serverID: serverID, name: "safe_lookup", title: nil,
        description: nil, risk: .read, enabled: true, declaredReadOnly: true)
    let unsafeMCP = MCPToolDescriptor(serverID: serverID, name: "write_record", title: nil,
        description: nil, risk: .write, enabled: true, declaredReadOnly: true)
    let server = MCPServer(id: serverID, name: "Fixture MCP", url: "https://example.invalid/mcp",
        enabled: true, allowedToolNames: [], tools: [safeMCP, unsafeMCP])
    let readTool = LimaAIToolDefinition(id: "fixture-read", name: "fixture_read",
        description: "Read fixture data.", parameters: [:], risk: .read)
    let writeTool = LimaAIToolDefinition(id: "fixture-write", name: "fixture_write",
        description: "Write fixture data.", parameters: [:], risk: .write)

    let result = await AISubagentRunner.run(
        client: ReadToolChildTransport(), apiKey: "fixture-only",
        model: AIModelOption(id: "selected-analysis-model"), task: "Read the allowed fixture.",
        mcpServers: [server], localTools: [readTool, writeTool],
        executeTool: { call, approvalGranted in
            #expect(call.name == CLIConnectedTools.callName)
            #expect(!approvalGranted)
            return "bounded MCP read result"
        }
    )

    #expect(!result.isError)
    #expect(result.output.contains("Read-only analysis complete."))
    #expect(result.output.contains(CLIConnectedTools.callName))
}

@Test @MainActor func contextToolsRemainStrictAndRespectCapabilityOff() throws {
    for definition in AIContextTools.definitions {
        #expect(definition.responsePayload != nil)
    }
    let store = LimaAIToolStore(fixtures: AIContextTools.ids)
    for id in ["memory", "subagents"] {
        let group = try #require(LimaAIToolGroup.coreGroups.first { $0.id == id })
        #expect(store.isEnabled(group))
        store.setEnabled(group, enabled: false)
        #expect(!store.isEnabled(group))
        #expect(group.toolIDs.isDisjoint(with: store.enabledToolIDs))
    }
    #expect(store.enabledToolIDs == AIContextTools.capabilityIDs)
}
