import Foundation
import Testing
@testable import RayPlacement

@Test func liveCodexCLIAdapterSmoke() async throws {
    guard ProcessInfo.processInfo.environment["LIMA_TEST_LIVE_CODEX"] == "1" else { return }
    let client = CLIChatProviderClient(provider: .codexCLI)
    let stream = client.streamReply(
        apiKey: "", model: "default", input: "Reply with exactly: Lima adapter smoke passed.",
        history: [], previousResponseID: nil, reasoningEffort: .medium,
        attachments: [], mcpServers: [], localTools: [], systemInstructions: ""
    )
    var reply = ""
    for try await event in stream {
        if case .textDelta(let text) = event { reply += text }
    }
    #expect(reply.contains("Lima adapter smoke passed."))
}

@Test func cliProviderArgumentsKeepPromptOffCommandLineAndConstrainTools() {
    let directory = URL(fileURLWithPath: "/tmp/lima-cli-test")
    let codex = CLIChatProviderClient.arguments(for: .codexCLI, model: "default", workingDirectory: directory)
    #expect(codex.contains("--json"))
    #expect(codex.contains("--ephemeral"))
    #expect(codex.contains("--ignore-user-config"))
    #expect(codex.contains("read-only"))
    #expect(codex.last == "-")
    #expect(!codex.contains("--model"))
    let claude = CLIChatProviderClient.arguments(for: .claudeCLI, model: "test-model", workingDirectory: directory)
    #expect(claude.contains("-p"))
    #expect(claude.contains("--tools"))
    #expect(claude.contains(""))
    #expect(claude.suffix(2) == ["--model", "test-model"])
}

@Test func cliProviderExtractsKnownResponseShapes() throws {
    let codex = Data("""
    {"type":"item.completed","item":{"type":"agent_message","text":"First"}}
    {"type":"item.completed","item":{"type":"agent_message","text":"Final reply"}}
    """.utf8)
    #expect(try CLIChatProviderClient.extractReply(from: codex, provider: .codexCLI) == "Final reply")
    let claude = Data(#"{"result":" Claude reply ","is_error":false}"#.utf8)
    #expect(try CLIChatProviderClient.extractReply(from: claude, provider: .claudeCLI) == "Claude reply")
}

@Test func cliProviderKeepsLatestTurnAfterLongHistory() throws {
    let older = (0..<15).map { AIProviderMessage(role: .user, text: String(repeating: "older ", count: 10_000) + String($0)) }
    let latest = "CURRENT REQUEST MUST REMAIN VISIBLE"
    let prompt = try CLIChatProviderClient.prompt(
        input: latest, history: older + [AIProviderMessage(role: .user, text: latest)],
        attachments: [], systemInstructions: ""
    )
    #expect(prompt.contains(latest))
    #expect(prompt.count <= 140_000)
}

@Test func cliProviderPromptIncludesVisibleTextAndRejectsUnsupportedAttachments() throws {
    let history = [AIProviderMessage(role: .user, text: "Summarize this")]
    let note = AIAttachment(kind: .file, displayName: "Visible note", text: "Important text")
    let prompt = try CLIChatProviderClient.prompt(
        input: "Summarize this", history: history, attachments: [note], systemInstructions: ""
    )
    #expect(prompt.contains("Important text"))
    #expect(prompt.contains("USER:\nSummarize this"))
    #expect(prompt.components(separatedBy: "USER:\nSummarize this").count == 2)

    let image = AIAttachment(kind: .image, displayName: "Image")
    #expect(throws: CLIChatProviderClient.Failure.self) {
        _ = try CLIChatProviderClient.prompt(
            input: "Describe", history: [], attachments: [image], systemInstructions: ""
        )
    }
}
