import Foundation
import Testing
@testable import RayPlacement

@Test @MainActor func cliProvidersRouteOnlyEnabledBrowserAndNotesTools() {
    for provider in [AIProvider.codexCLI, .claudeCLI] {
        let conversation = AIConversation(provider: provider, model: "default")
        let model = AIChatViewModel(
            store: AIConversationStore(fixtures: [conversation]),
            credentials: AIChatCredentialStore(configuration: .fixture),
                        nativeToolStore: LimaAIToolStore(fixtures: [
                "browser_tabs", "browser_current", "browser_read", "search_notes", "read_note"
            ]),
            transport: FixtureAITransport.standard
        )
        model.select(conversation.id)
        let routed = Set(model.routedNativeTools(for: "Explain this SQL").map(\.id))
        #expect(routed == Set(["browser_tabs", "browser_current", "browser_read", "search_notes", "read_note"]))
        #expect(routed == Set(model.routedNativeTools(for: "Read the current browser page").map(\.id)))
        #expect(routed == Set(model.routedNativeTools(for: "Search my notes").map(\.id)))
    }
}

@Test @MainActor func cliFullNativeCatalogFitsPromptBudget() throws {
    let tools = LimaAIToolRegistry.definitions.filter { $0.responsePayload != nil }
    let prompt = try CLIChatProviderClient.prompt(input: "Help with this task", history: [],
        attachments: [], systemInstructions: "", localTools: tools)
    #expect(prompt.count <= 140_000)
}

private final class CLIOutputCapture {
    var outputs: [[String: Any]] = []
    var history: [AIProviderMessage] = []
}

@Test @MainActor func cliEnvelopeExecutesNativeToolAndContinuesThroughLima() async throws {
    let tool = try #require(LimaAIToolRegistry.definitions.first { $0.id == "get_lima_status" })
    let envelope = #"{"kind":"tool_call","text":"","tool":"get_lima_status","arguments":"{}"}"#
    let events = try CLIChatProviderClient.events(from: envelope, localTools: [tool])
    let capture = CLIOutputCapture()
    var transport = FixtureAITransport(events: events)
    transport.toolOutputEvents = [
        .responseCreated("cli-continuation"),
        .textDelta("Lima status checked."),
        .completed("cli-continuation")
    ]
    transport.onToolOutputs = { outputs, history in
        capture.outputs = outputs
        capture.history = history
    }

    let conversation = AIConversation(provider: .codexCLI, model: "default")
    let store = AIConversationStore(fixtures: [conversation])
    let model = AIChatViewModel(
        store: store,
        credentials: AIChatCredentialStore(configuration: .fixture),
                nativeToolStore: LimaAIToolStore(fixtures: ["get_lima_status"]),
        transport: transport
    )

    model.select(conversation.id)
    model.draft = "Show Lima status"
    model.send()
    for _ in 0..<300 where model.isStreaming {
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(!model.isStreaming)
    #expect(model.streamError == nil)
    #expect(capture.outputs.count == 1)
    #expect((capture.outputs.first?["output"] as? String)?.contains("app_version") == true)
    #expect(capture.history.contains { message in
        message.content.contains { if case .toolResult = $0 { return true }; return false }
    })
    #expect(model.selectedConversation?.messages.last?.text.contains("Lima status checked.") == true)
    #expect(model.selectedConversation?.messages.last?.activities?.contains { $0.kind == .toolCompleted } == true)
}
