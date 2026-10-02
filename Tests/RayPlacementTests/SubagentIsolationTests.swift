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
        #expect(systemInstructions.contains("no tools"))
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

@Test func selectedChildModelReceivesOnlyItsExplicitTask() async {
    let result = await AISubagentRunner.run(client: InspectingChildTransport(), apiKey: "fixture-only",
        model: AIModelOption(id: "selected-analysis-model"), task: "Review only this supplied evidence.")
    #expect(!result.isError)
    #expect(result.output.contains("Bounded findings"))
    #expect(result.output.contains("selected-analysis-model"))
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
    #expect(store.enabledToolIDs.isEmpty)
}
