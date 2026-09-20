import Foundation
import Testing
@testable import RayPlacement

@Test func aiReasoningEffortUsesFriendlyLabelsAndStableValues() {
    #expect(AIReasoningEffort.medium.rawValue == "medium")
    #expect(AIReasoningEffort.medium.title == "Standard")
    #expect(AIReasoningEffort.high.detail.contains("deliberate"))
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
