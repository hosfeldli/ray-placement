import Foundation
import Testing
@testable import RayPlacement

@Test func aiReasoningEffortUsesFriendlyLabelsAndStableValues() {
    #expect(AIReasoningEffort.medium.rawValue == "medium")
    #expect(AIReasoningEffort.medium.title == "Standard")
    #expect(AIReasoningEffort.high.detail.contains("deliberate"))
}

@Test func aiModelCapabilitiesLimitReasoningToSupportedValues() {
    let chat = AIModelOption(id: "gpt-5")
    #expect(chat.supportsReasoning)
    #expect(chat.supportedReasoningEfforts.contains(.high))

    let nonReasoning = AIModelOption(id: "gpt-4o")
    #expect(!nonReasoning.supportsReasoning)
    #expect(nonReasoning.supportedReasoningEfforts.isEmpty)
}

@Test func aiModelDiscoveryFiltersNonChatModels() {
    #expect(AIModelOption.isChatModel("gpt-5"))
    #expect(AIModelOption.isChatModel("o4-mini"))
    #expect(!AIModelOption.isChatModel("text-embedding-3-small"))
    #expect(!AIModelOption.isChatModel("dall-e-3"))
}

@Test func responsesPayloadOmitsUnsupportedReasoningAndPreservesContinuation() throws {
    let body = AIChatResponsesClient.replyBody(
        model: "gpt-4o",
        input: [["role": "user", "content": [["type": "input_text", "text": "Hello"]]]],
        previousResponseID: "resp_previous",
        reasoningEffort: .high,
        tools: []
    )
    #expect(body["model"] as? String == "gpt-4o")
    #expect(body["previous_response_id"] as? String == "resp_previous")
    #expect(body["reasoning"] == nil)
    #expect(body["stream"] as? Bool == true)
}

@Test func responsePayloadUsesMCPApprovalPolicyWithoutEmbeddingCredential() throws {
    let serverID = UUID()
    let tools = [
        MCPToolDescriptor(serverID: serverID, name: "search", risk: .read, enabled: true),
        MCPToolDescriptor(serverID: serverID, name: "delete_repo", risk: .destructive, enabled: true)
    ]
    let body = AIChatResponsesClient.replyBody(
        model: "gpt-5",
        input: [["role": "user", "content": [["type": "input_text", "text": "Inspect"]]]],
        previousResponseID: nil,
        reasoningEffort: .medium,
        tools: [[
            "type": "mcp",
            "server_label": "GitHub",
            "server_url": "https://example.com/mcp",
            "allowed_tools": tools.map(\.name),
            "require_approval": ["never": ["tool_names": ["search"]]]
        ]]
    )
    let payload = try #require(body["tools"] as? [[String: Any]])
    #expect(payload.first?["authorization"] == nil)
    #expect(payload.first?["headers"] == nil)
}

@Test func mcpHTTPURLsRejectMissingHostsAndSanitizeLabels() {
    let server = MCPServer(name: "123 GitHub / Docs", url: "https://")
    #expect(server.validHTTPURL == nil)
    #expect(server.apiLabel == "mcp_123_GitHub___Docs")
}

@Test func mcpAuthorizationHeaderPreservesExplicitScheme() {
    #expect(MCPCredentialStore.authorizationHeaderValue("token") == "Bearer token")
    #expect(MCPCredentialStore.authorizationHeaderValue("Basic abc") == "Basic abc")
}

@Test func aiConversationRoundTripsNewPhaseTwoMetadata() throws {
    let conversation = AIConversation(
        title: "API debugging",
        model: "gpt-5.6",
        reasoningEffort: .high,
        reasoningSummary: "The failure comes from the request body.",
        activities: [AIAgentActivity(kind: .toolCompleted, title: "Read package.json", completed: true)],
        attachments: [AIAttachment(kind: .clipboard, displayName: "Clipboard", text: "hello")],
        messages: [AIChatMessage(role: .user, text: "Explain this")]
    )
    let data = try JSONEncoder().encode(conversation)
    let restored = try JSONDecoder().decode(AIConversation.self, from: data)
    #expect(restored.reasoningEffort == .high)
    #expect(restored.reasoningSummary?.contains("request body") == true)
    #expect(restored.activities.first?.title == "Read package.json")
    #expect(restored.attachments.first?.kind == .clipboard)
}

@Test func legacyConversationDecodingSuppliesNewDefaults() throws {
    let legacy: [String: Any] = [
        "id": UUID().uuidString,
        "title": "Legacy",
        "createdAt": Date().timeIntervalSince1970,
        "updatedAt": Date().timeIntervalSince1970,
        "model": "gpt-5.6",
        "messages": []
    ]
    let data = try JSONSerialization.data(withJSONObject: legacy)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let restored = try decoder.decode(AIConversation.self, from: data)
    #expect(restored.reasoningEffort == .medium)
    #expect(restored.activities.isEmpty)
    #expect(restored.attachments.isEmpty)
}

@Test func mcpRiskClassificationRequiresApprovalForWritesAndDestructiveTools() {
    #expect(MCPToolRisk.read.requiresApproval == false)
    #expect(MCPToolRisk.write.requiresApproval == true)
    #expect(MCPToolRisk.destructive.requiresApproval == true)
}

@Test func mcpServerAllowlistDefaultsToDiscoveredTools() {
    let serverID = UUID()
    let tools = [
        MCPToolDescriptor(serverID: serverID, name: "read_file", risk: .read, enabled: true),
        MCPToolDescriptor(serverID: serverID, name: "delete_file", risk: .destructive, enabled: true)
    ]
    let server = MCPServer(name: "Files", url: "https://example.com/mcp", allowedToolNames: tools.map(\.name), tools: tools)
    #expect(server.enabledTools.map(\.name) == ["read_file", "delete_file"])
    #expect(server.apiLabel == "Files")
}

@Test func mcpServerCanRepresentAllToolsDisabled() {
    let serverID = UUID()
    let tool = MCPToolDescriptor(serverID: serverID, name: "read_file", risk: .read, enabled: true)
    let server = MCPServer(name: "Files", url: "https://example.com/mcp", allowedToolNames: [MCPServer.noToolsSentinel], tools: [tool])
    #expect(server.enabledTools.isEmpty)
}

@Test func markdownRendererSeparatesFencedCodeBlocks() {
    let markdown = "Intro\n```swift\nlet answer = 42\n```\nDone"
    let mirror = AIMarkdownView(markdown: markdown)
    #expect(mirror.markdown.contains("let answer = 42"))
}

@Test func usageMetricsDisplayKnownTotal() {
    let usage = AIUsageMetrics(inputTokens: 10, cachedInputTokens: 2, outputTokens: 7, reasoningTokens: 3)
    #expect(usage.totalKnownTokens == 20)
    #expect(usage.displayText == "20 tokens")
}

// MARK: - Responses event compatibility

private func responseEvent(_ type: String, _ fields: [String: Any] = [:]) -> [AIChatStreamEvent] {
    var payload = fields
    payload["type"] = type
    let data = try! JSONSerialization.data(withJSONObject: payload, options: [])
    return AIResponsesEventDecoder.events(eventType: type, dataLines: [String(decoding: data, as: UTF8.self)], model: "gpt-5")
}

private func outputItemEvent(_ eventType: String, item: [String: Any]) -> [AIChatStreamEvent] {
    responseEvent(eventType, ["response_id": "resp_test", "item": item])
}

@Test func responsesDecoderAcceptsPlainAssistantText() {
    let events = responseEvent("response.output_text.delta", ["delta": "Hello"])
    guard case .textDelta(let text) = events.first else {
        Issue.record("Expected a text delta")
        return
    }
    #expect(text == "Hello")
}

@Test func responsesDecoderAcceptsReasoningBeforeMessage() {
    let reasoning = outputItemEvent("response.output_item.added", item: ["type": "reasoning", "id": "reasoning_1"])
    let text = responseEvent("response.output_text.delta", ["delta": "Answer"])
    #expect(reasoning.contains { if case .outputItem(let item) = $0 { return item.kind == .reasoning }; return false })
    #expect(text.contains { if case .textDelta = $0 { return true }; return false })
}

@Test func responsesDecoderAcceptsMessageBeforeReasoning() {
    let text = responseEvent("response.output_text.delta", ["delta": "Answer"])
    let reasoning = outputItemEvent("response.output_item.done", item: ["type": "reasoning", "id": "reasoning_2"])
    #expect(text.contains { if case .textDelta = $0 { return true }; return false })
    #expect(reasoning.contains { if case .outputItem(let item) = $0 { return item.kind == .reasoning }; return false })
}

@Test func responsesDecoderPreservesMultipleOutputItems() {
    let events = outputItemEvent("response.output_item.done", item: [
        "type": "function_call",
        "id": "fc_1",
        "call_id": "call_1",
        "name": "search_files",
        "arguments": "{\"query\":\"report\"}"
    ])
    guard case .outputItem(let item) = events.first else {
        Issue.record("Expected an output item")
        return
    }
    #expect(item.kind == .functionCall)
    #expect(item.callID == "call_1")
    #expect(item.arguments?.contains("report") == true)
}

@Test func responsesDecoderAcceptsStreamedReasoningSummary() {
    let events = responseEvent("response.reasoning_summary_text.delta", ["delta": "I checked the inputs."])
    guard case .reasoningSummaryDelta(let summary) = events.first else {
        Issue.record("Expected a reasoning summary delta")
        return
    }
    #expect(summary == "I checked the inputs.")
}

@Test func responsesDecoderTreatsFunctionCallAsValidNonTextOutput() {
    let events = outputItemEvent("response.output_item.done", item: [
        "type": "function_call",
        "id": "fc_2",
        "call_id": "call_2",
        "name": "get_lima_status",
        "arguments": "{}"
    ])
    #expect(events.contains { if case .failed = $0 { return true }; return false } == false)
    #expect(events.contains { if case .outputItem(let item) = $0 { return item.kind == .functionCall }; return false })
}

@Test func responsesDecoderSupportsFunctionCallContinuationInputs() {
    let output = ["type": "function_call_output", "call_id": "call_3", "output": "{\"ok\":true}"] as [String: Any]
    let body = AIChatResponsesClient.replyBody(
        model: "gpt-5",
        input: [output],
        previousResponseID: "resp_tools",
        reasoningEffort: .medium,
        tools: []
    )
    let input = try? #require(body["input"] as? [[String: Any]])
    #expect(input?.first?["type"] as? String == "function_call_output")
    #expect(body["previous_response_id"] as? String == "resp_tools")
}

@Test func responsesDecoderAcceptsMCPToolCall() {
    let events = outputItemEvent("response.output_item.done", item: [
        "type": "mcp_call",
        "id": "mcp_1",
        "name": "search",
        "server_label": "Docs MCP"
    ])
    #expect(events.contains { if case .outputItem(let item) = $0 { return item.kind == .mcpCall && item.serverLabel == "Docs MCP" }; return false })
}

@Test func responsesDecoderReportsUnknownOutputItemWithoutFailing() {
    let events = outputItemEvent("response.output_item.done", item: [
        "type": "future_output_item",
        "id": "future_1"
    ])
    #expect(events.contains { if case .outputItem(let item) = $0 { return item.kind == .unknown }; return false })
    #expect(events.contains { if case .diagnostic(let diagnostic) = $0 { return diagnostic.outputItemType == "future_output_item" }; return false })
    #expect(events.contains { if case .failed = $0 { return true }; return false } == false)
}

@Test func responsesDecoderReportsUnknownEventWithoutFailing() {
    let events = responseEvent("response.future_event", ["response_id": "resp_future"])
    #expect(events.count == 1)
    guard case .diagnostic(let diagnostic) = events.first else {
        Issue.record("Expected an unknown-event diagnostic")
        return
    }
    #expect(diagnostic.eventType == "response.future_event")
}

@Test func responsesDecoderReportsMalformedJSONSafely() {
    let events = AIResponsesEventDecoder.events(eventType: "response.output_text.delta", dataLines: ["{not-json"], model: "gpt-5")
    guard case .diagnostic(let diagnostic) = events.first else {
        Issue.record("Expected a malformed JSON diagnostic")
        return
    }
    #expect(diagnostic.stage == .stream)
    #expect(diagnostic.message.contains("malformed"))
}

@Test func responsesDecoderPreservesStructuredAPIErrorDetails() {
    let events = responseEvent("error", [
        "error": ["code": "invalid_prompt", "param": "input", "message": "The input is invalid."]
    ])
    #expect(events.contains { if case .failed(let message) = $0 { return message == "The input is invalid." }; return false })
    guard case .diagnostic(let diagnostic) = events.first else {
        Issue.record("Expected an API diagnostic")
        return
    }
    #expect(diagnostic.errorCode == "invalid_prompt")
    #expect(diagnostic.errorParameter == "input")
}

@Test func responsesDecoderEmitsCompletionForEmptyValidResponse() {
    let events = responseEvent("response.completed", ["response": ["id": "resp_empty"]])
    #expect(events.contains { if case .completed(let id) = $0 { return id == "resp_empty" }; return false })
    #expect(events.contains { if case .failed = $0 { return true }; return false } == false)
}

@Test func responsesDecoderAcceptsResponseUsageOnCompletion() {
    let events = responseEvent("response.completed", [
        "response": [
            "id": "resp_usage",
            "usage": ["input_tokens": 4, "output_tokens": 6]
        ]
    ])
    #expect(events.contains { if case .usage(let usage) = $0 { return usage.totalKnownTokens == 10 }; return false })
}

@Test func responsesDecoderAcceptsMCPFailureAsActivity() {
    let events = responseEvent("response.mcp_call.failed", [
        "name": "write_file",
        "server_label": "Files",
        "error": ["message": "Permission denied"]
    ])
    #expect(events.contains { if case .outputItem(let item) = $0 { return item.kind == .mcpCall && item.errorMessage == "Permission denied" }; return false })
}

@Test @MainActor func localToolRiskRequiresApprovalForLocalActions() {
    let read = LimaAIToolRegistry.definition(for: "get_lima_status")
    let action = LimaAIToolRegistry.definition(for: "open_lima_settings")
    #expect(read?.risk.requiresApproval == false)
    #expect(action?.risk.requiresApproval == true)
}

@Test func localToolFailureIsReturnedAsToolOutput() async {
    let call = AIOutputItem(
        phase: .completed,
        apiType: "function_call",
        callID: "call_bad",
        name: "search_files",
        arguments: "{\"query\":123}"
    )
    let result = await LimaAIToolRegistry.execute(call)
    #expect(result.isError)
    #expect(result.output.contains("error"))
}

@Test func unsupportedModelDoesNotReceiveReasoningConfiguration() {
    let body = AIChatResponsesClient.replyBody(
        model: "gpt-4o",
        input: [],
        previousResponseID: nil,
        reasoningEffort: .high,
        tools: []
    )
    #expect(body["reasoning"] == nil)
}

@Test func cancellationAndStreamInterruptionRemainNonFatalToDecoder() {
    #expect(AIResponsesEventDecoder.events(eventType: "", dataLines: ["[DONE]"], model: "gpt-5").isEmpty)
    let partial = responseEvent("response.output_text.delta", ["delta": "partial"])
    #expect(partial.contains { if case .textDelta(let text) = $0 { return text == "partial" }; return false })
}
