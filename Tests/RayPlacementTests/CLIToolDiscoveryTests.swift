import Foundation
import Testing
@testable import RayPlacement

@Test func cliLargeCatalogUsesDiscoveryWithoutLosingExecutionAllowlist() throws {
    let native = (0..<120).map { index in
        LimaAIToolDefinition(id: "fixture_\(index)", name: "fixture_\(index)",
            description: String(repeating: "Read fixture evidence. ", count: 80),
            parameters: ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"], "additionalProperties": false],
            risk: .read)
    }
    let tools = CLIChatProviderClient.requestTools(localTools: native, mcpServers: [])
    let prompt = try CLIChatProviderClient.prompt(input: "Look up evidence", history: [], attachments: [],
                                                systemInstructions: "", localTools: tools)
    #expect(prompt.count < 10_000)
    #expect(prompt.contains(CLIToolDiscovery.name))
    let call = AIOutputItem(phase: .completed, apiType: "function_call", id: "describe", callID: "describe",
        name: CLIToolDiscovery.name, arguments: #"{"query":"fixture_119","offset":0}"#)
    let result = CLIToolDiscovery.execute(call, allowedTools: tools)
    #expect(!result.isError)
    #expect(result.output.contains("fixture_119"))
    #expect(result.output.contains("parameters"))
    let envelope = #"{"kind":"tool_call","text":"","tool":"fixture_119","arguments":"{\"query\":\"sample\"}"}"#
    #expect(try CLIChatProviderClient.events(from: envelope, localTools: tools).count == 3)
    #expect(throws: CLIChatProviderClient.Failure.self) {
        _ = try CLIChatProviderClient.events(from: envelope, localTools: [CLIToolDiscovery.definition])
    }
}

@Test func cliLargeVisibleContextKeepsToolsAvailableThroughDiscovery() throws {
    let native = (0..<50).map { index in
        LimaAIToolDefinition(id: "fixture_\(index)", name: "fixture_\(index)",
            description: String(repeating: "Read fixture evidence. ", count: 80),
            parameters: ["type": "object", "properties": [:], "required": [], "additionalProperties": false],
            risk: .read)
    }
    let tools = CLIChatProviderClient.requestTools(localTools: native, mcpServers: [])
    let attachment = AIAttachment(kind: .selection, displayName: "Visible selection", text: String(repeating: "context ", count: 8000))
    let prompt = try CLIChatProviderClient.prompt(input: "Review the selection", history: [], attachments: [attachment],
        systemInstructions: String(repeating: "Instruction. ", count: 2000), localTools: tools)
    #expect(prompt.count <= 140_000)
    #expect(prompt.contains(CLIToolDiscovery.name))
    #expect(prompt.contains("VISIBLE CONTEXT"))
}

@Test func cliDiscoveryRejectsUnexpectedArguments() {
    let call = AIOutputItem(phase: .completed, apiType: "function_call", id: "describe", callID: "describe",
        name: CLIToolDiscovery.name, arguments: #"{"query":"","offset":-1,"endpoint":"https://unexpected.invalid"}"#)
    #expect(CLIToolDiscovery.execute(call, allowedTools: []).isError)
}

@Test @MainActor func liveCodexConnectedServiceEnvelopeAndLimaContinuation() async throws {
    guard ProcessInfo.processInfo.environment["LIMA_TEST_LIVE_CODEX"] == "1" else { return }
    let id = UUID()
    let server = MCPServer(id: id, name: "Fixture Evidence Service", url: "https://unused.invalid",
        tools: [MCPToolDescriptor(serverID: id, name: "lookup", risk: .read, enabled: true, declaredReadOnly: true)])
    let tools = CLIChatProviderClient.requestTools(localTools: [], mcpServers: [server])
    let client = CLIChatProviderClient(provider: .codexCLI)
    let request = "Call lima_list_connected_tools with server_id empty and offset 0 to list Lima's connected services. Then report the exact service name from the actual tool result. Do not use any CLI-native tools."
    var call: AIOutputItem?
    var responseID = ""
    var sawThinking = false
    for try await event in client.streamReply(apiKey: "", model: "default", input: request, history: [],
        previousResponseID: nil, reasoningEffort: .medium, attachments: [], mcpServers: [server],
        localTools: tools, systemInstructions: "") {
        if case .outputItem(let item) = event { call = item }
        if case .responseCreated(let id) = event { responseID = id }
        if case .activity(let activity) = event, activity.kind == .thinking { sawThinking = true }
    }
    let requested = try #require(call)
    #expect(requested.name == CLIConnectedTools.listName)
    #expect(sawThinking)
    let callID = try #require(requested.callID)
    // Listing service metadata exercises the real Lima dispatcher without
    // making any request to the fixture endpoint or accessing user content.
    let result = await CLIConnectedTools.execute(requested, allowedServers: [server], store: MCPServerStore(fixtures: [server]))
    #expect(!result.isError)
    let history = [
        AIProviderMessage(role: .user, text: request),
        AIProviderMessage(role: .assistant, content: [.toolUse(id: callID, name: requested.name!, arguments: requested.arguments!)]),
        AIProviderMessage(role: .user, content: [.toolResult(id: callID, output: result.output)])
    ]
    var reply = ""
    for try await event in client.streamToolOutputs(apiKey: "", model: "default", previousResponseID: responseID,
        history: history, outputs: [["type": "function_call_output", "call_id": callID, "output": result.output]],
        reasoningEffort: .medium, mcpServers: [server], localTools: tools, systemInstructions: "") {
        if case .textDelta(let text) = event { reply += text }
    }
    #expect(reply.contains("Fixture Evidence Service"))
}
