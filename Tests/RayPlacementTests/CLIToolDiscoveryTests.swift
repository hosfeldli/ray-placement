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
    let tools = CLIChatProviderClient.requestTools(localTools: native)
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
    let tools = CLIChatProviderClient.requestTools(localTools: native)
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
