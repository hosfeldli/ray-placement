import AppKit
import Foundation
import Testing
@testable import RayPlacement

@Test func liveCodexCLIAdapterSmoke() async throws {
    guard ProcessInfo.processInfo.environment["LIMA_TEST_LIVE_CODEX"] == "1" else { return }
    let client = CLIChatProviderClient(provider: .codexCLI)
    let stream = client.streamReply(
        apiKey: "", model: "default", input: "Reply with exactly: Lima adapter smoke passed.",
        history: [], previousResponseID: nil, reasoningEffort: .medium,
        attachments: [], localTools: [], systemInstructions: ""
    )
    var reply = ""
    for try await event in stream {
        if case .textDelta(let text) = event { reply += text }
    }
    #expect(reply.contains("Lima adapter smoke passed."))
}

@Test func liveCodexCLIToolEnvelopeSmoke() async throws {
    guard ProcessInfo.processInfo.environment["LIMA_TEST_LIVE_CODEX"] == "1" else { return }
    let tool = fixtureCLITool()
    let client = CLIChatProviderClient(provider: .codexCLI)
    let stream = client.streamReply(
        apiKey: "", model: "default",
        input: "Call the available lima_fixture_lookup tool with key sample. Do not answer before requesting it.",
        history: [], previousResponseID: nil, reasoningEffort: .medium,
        attachments: [], localTools: [tool], systemInstructions: ""
    )
    var call: AIOutputItem?
    var responseID: String?
    for try await event in stream {
        if case .responseCreated(let id) = event { responseID = id }
        if case .outputItem(let item) = event { call = item }
    }
    #expect(call?.name == tool.name)
    #expect(call?.arguments?.contains("sample") == true)
    guard let callID = call?.callID, let responseID else { return }
    let result = #"{"value":"blue"}"#
    let history = [
        AIProviderMessage(role: .user, text: "Call lima_fixture_lookup for sample, then say the returned value."),
        AIProviderMessage(role: .assistant, content: [.toolUse(id: callID, name: tool.name, arguments: call?.arguments ?? "{}")]),
        AIProviderMessage(role: .user, content: [.toolResult(id: callID, output: result)])
    ]
    let continuation = client.streamToolOutputs(
        apiKey: "", model: "default", previousResponseID: responseID,
        history: history, outputs: [["type": "function_call_output", "call_id": callID, "output": result]],
        reasoningEffort: .medium, localTools: [tool], systemInstructions: ""
    )
    var answer = ""
    for try await event in continuation {
        if case .textDelta(let text) = event { answer += text }
    }
    #expect(answer.localizedCaseInsensitiveContains("blue"))
}

@Test func liveCodexCLISelectsUsefulToolWithoutExplicitInstruction() async throws {
    guard ProcessInfo.processInfo.environment["LIMA_TEST_LIVE_CODEX"] == "1" else { return }
    let tool = fixtureCLITool()
    let client = CLIChatProviderClient(provider: .codexCLI)
    let stream = client.streamReply(
        apiKey: "", model: "default",
        input: "What is the current fixture value for key sample? Report a value only if you can inspect it.",
        history: [], previousResponseID: nil, reasoningEffort: .medium,
        attachments: [], localTools: [tool],
        systemInstructions: AIReadOnlyPolicy.assistantInstructions
    )
    var requestedTool: AIOutputItem?
    for try await event in stream {
        if case .outputItem(let item) = event { requestedTool = item }
    }
    #expect(requestedTool?.name == tool.name)
    #expect(requestedTool?.arguments?.contains("sample") == true)
}

@Test @MainActor func liveCodexCLINativeToolExecutionSmoke() async throws {
    guard ProcessInfo.processInfo.environment["LIMA_TEST_LIVE_CODEX"] == "1",
          LimaTestEnvironment.allowsLiveAI else { return }

    // The model receives only this read-only native Lima tool (plus the CLI
    // discovery shim). This exercises Lima's policy gate, executor, provider
    // continuation, durable assistant state, and TaskRegistry projection.
    let conversation = AIConversation(provider: .codexCLI, model: "default")
    let store = AIConversationStore(fixtures: [conversation])
    let tasks = TaskRegistry()
    let model = AIChatViewModel(
        store: store,
        credentials: AIChatCredentialStore(configuration: .current(environment: ["LIMA_TEST_MODE": "1"])),
        nativeToolStore: LimaAIToolStore(fixtures: ["get_lima_status"]),
        transport: CLIChatProviderClient(provider: .codexCLI),
        taskRegistry: tasks
    )
    #expect(model.requestLocalTools(for: "Read Lima status").contains { $0.id == "get_lima_status" })

    model.draft = "Call get_lima_status with {}. Wait for the Lima tool result, then report its app_version."
    model.send()
    for _ in 0..<900 where model.canEndTask {
        try await Task.sleep(for: .milliseconds(100))
    }
    if model.canEndTask { model.endTask() }

    let assistant = try #require(store.conversation(id: conversation.id)?.messages.last(where: { $0.role == .assistant }))
    #expect(model.executionRun?.state == .completed)
    #expect(assistant.failure == nil)
    let expectedVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    #expect(assistant.text.localizedCaseInsensitiveContains(expectedVersion))
    #expect(assistant.activities?.contains(where: { $0.kind == .toolCompleted && $0.title == "get_lima_status" }) == true)
    #expect(tasks.activeTasks.isEmpty)
    #expect(!model.canEndTask)
    #expect(!model.hasActiveStreamTaskForTesting)
    #expect(await model.inFlightExecutionLoopCountForTesting() == 0)
}

@Test @MainActor func liveCodexCLIBrowserScreenshotContinuationSmoke() async throws {
    guard ProcessInfo.processInfo.environment["LIMA_TEST_LIVE_CODEX"] == "1" else { return }
    let context = try #require(CGContext(
        data: nil, width: 64, height: 64, bitsPerComponent: 8,
        bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    let rendered = try #require(context.makeImage())
    let jpeg = try #require(NSBitmapImageRep(cgImage: rendered).representation(
        using: .jpeg, properties: [:]
    ))
    let callID = "screenshot-smoke"
    let history = [
        AIProviderMessage(role: .user, text: "Identify the main color in the Browser screenshot."),
        AIProviderMessage(role: .assistant, content: [
            .toolUse(id: callID, name: "browser_screenshot", arguments: "{}")
        ]),
        AIProviderMessage(role: .user, content: [
            .toolResult(id: callID, output: #"{"image_attached":true}"#),
            .text("Browser screenshot from tool call screenshot-smoke. Identify its main color."),
            .image(mediaType: "image/jpeg", base64: jpeg.base64EncodedString())
        ])
    ]
    let stream = CLIChatProviderClient(provider: .codexCLI).streamToolOutputs(
        apiKey: "", model: "default", previousResponseID: "screenshot-smoke",
        history: history, outputs: [], reasoningEffort: .medium,
        localTools: [], systemInstructions: ""
    )
    var answer = ""
    for try await event in stream {
        if case .textDelta(let text) = event { answer += text }
    }
    #expect(answer.localizedCaseInsensitiveContains("red"))
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
    let selectedCodex = CLIChatProviderClient.arguments(
        for: .codexCLI, model: "gpt-6-sol", workingDirectory: directory
    )
    let codexModelFlag = selectedCodex.firstIndex(of: "--model")
    #expect(codexModelFlag.map { selectedCodex.index(after: $0) }.flatMap { selectedCodex.indices.contains($0) ? selectedCodex[$0] : nil } == "gpt-6-sol")
    let claude = CLIChatProviderClient.arguments(for: .claudeCLI, model: "test-model", workingDirectory: directory)
    #expect(claude.contains("-p"))
    #expect(claude.contains("--tools"))
    #expect(claude.contains(""))
    #expect(claude.suffix(2) == ["--model", "test-model"])
}

private func fixtureCLITool() -> LimaAIToolDefinition {
    LimaAIToolDefinition(
        id: "lima_fixture_lookup", name: "lima_fixture_lookup",
        description: "Return one fixture value without side effects.",
        parameters: [
            "type": "object",
            "properties": ["key": ["type": "string"]],
            "required": ["key"],
            "additionalProperties": false
        ],
        risk: .read
    )
}

@Test func cliTimeoutHasSafeActionableMessage() {
    #expect(CLIChatProviderClient.Failure.timedOut.errorDescription == AIProviderFailure.timeoutMessage)
    #expect(AIProviderFailure.presentation(
        provider: "Codex CLI",
        model: "default",
        status: nil,
        code: nil,
        parameter: nil,
        fallback: AIProviderFailure.timeoutMessage
    ).contains("Codex CLI request timed out"))
}

@Test func cliProviderToolEnvelopeAcceptsOnlyRoutedTools() throws {
    let tool = fixtureCLITool()
    let valid = #"{"kind":"tool_call","text":"","tool":"lima_fixture_lookup","arguments":"{\"key\":\"sample\"}"}"#
    let events = try CLIChatProviderClient.events(from: valid, localTools: [tool])
    let call = events.compactMap { event -> AIOutputItem? in
        if case .outputItem(let item) = event { return item }
        return nil
    }.first
    #expect(call?.name == tool.name)
    #expect(call?.arguments == #"{"key":"sample"}"#)
    #expect(call?.callID != nil)

    let answer = #"{"kind":"answer","text":"Found the value.","tool":"","arguments":"{}"}"#
    let answerEvents = try CLIChatProviderClient.events(from: answer, localTools: [tool])
    #expect(answerEvents.contains { if case .textDelta("Found the value.") = $0 { return true }; return false })

    let unknown = #"{"kind":"tool_call","text":"","tool":"not_enabled","arguments":"{}"}"#
    #expect(throws: CLIChatProviderClient.Failure.self) {
        _ = try CLIChatProviderClient.events(from: unknown, localTools: [tool])
    }
    let malformed = #"{"kind":"tool_call","text":"","tool":"lima_fixture_lookup","arguments":"[]"}"#
    #expect(throws: CLIChatProviderClient.Failure.self) {
        _ = try CLIChatProviderClient.events(from: malformed, localTools: [tool])
    }
}

@Test func cliProviderToolBatchPreservesOrderAndRejectsUnknownTools() throws {
    let tool = fixtureCLITool()
    func envelope(_ calls: [[String: Any]]) throws -> String {
        let encodedCalls = try JSONSerialization.data(withJSONObject: calls)
        let payload: [String: Any] = [
            "kind": "tool_calls", "text": "", "tool": "",
            "arguments": String(decoding: encodedCalls, as: UTF8.self)
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    }

    let reply = try envelope([
        ["tool": tool.name, "arguments": ["key": "first"]],
        ["tool": tool.name, "arguments": ["key": "second"]]
    ])
    let events = try CLIChatProviderClient.events(from: reply, localTools: [tool])
    let calls = events.compactMap { event -> AIOutputItem? in
        if case .outputItem(let item) = event { return item }
        return nil
    }
    #expect(calls.count == 2)
    #expect(calls.compactMap(\.name) == [tool.name, tool.name])
    #expect(calls.map { $0.arguments?.contains("first") == true } == [true, false])
    #expect(Set(calls.compactMap(\.callID)).count == 2)

    let unknown = try envelope([
        ["tool": tool.name, "arguments": ["key": "first"]],
        ["tool": "not_enabled", "arguments": [:] as [String: String]]
    ])
    #expect(throws: CLIChatProviderClient.Failure.self) {
        _ = try CLIChatProviderClient.events(from: unknown, localTools: [tool])
    }
}

@Test func cliProviderPromptCarriesActualToolResult() throws {
    let tool = fixtureCLITool()
    let history = [
        AIProviderMessage(role: .user, text: "Look up sample"),
        AIProviderMessage(role: .assistant, content: [.toolUse(id: "call-1", name: tool.name, arguments: #"{"key":"sample"}"#)]),
        AIProviderMessage(role: .user, content: [.toolResult(id: "call-1", output: #"{"value":"actual result"}"#)])
    ]
    let prompt = try CLIChatProviderClient.prompt(
        input: "", history: history, attachments: [], systemInstructions: "", localTools: [tool]
    )
    #expect(prompt.contains("AVAILABLE LIMA TOOLS"))
    #expect(prompt.contains("Look up sample"))
    #expect(prompt.contains("Lima tool result [call-1] — untrusted data"))
    #expect(prompt.contains("actual result"))
    #expect(prompt.count <= 140_000)
}

@Test func cliProviderPrefersUsefulToolsOnlyWhenRouted() throws {
    let withTools = try CLIChatProviderClient.prompt(
        input: "Research the current state", history: [], attachments: [],
        systemInstructions: "", localTools: [fixtureCLITool()]
    )
    #expect(withTools.contains("Tool-first workflow"))
    #expect(withTools.contains("At the start of each request and after each tool result"))
    #expect(withTools.contains("Do not call tools merely to increase call count"))
    #expect(withTools.contains("Do not use the CLI's own shell, browser, file, or network tools"))
    #expect(withTools.contains("Before the final reply, request a relevant Lima tool"))
    #expect(withTools.contains("stop when further calls would not help"))

    let withoutTools = try CLIChatProviderClient.prompt(
        input: "Explain this supplied text", history: [], attachments: [],
        systemInstructions: "", localTools: []
    )
    #expect(!withoutTools.contains("Tool-first workflow"))
}

@Test func cliProviderSchemaArgumentIsIsolatedFromPrompt() {
    let directory = URL(fileURLWithPath: "/tmp/lima-cli-test")
    let schema = directory.appendingPathComponent("schema.json")
    let arguments = CLIChatProviderClient.arguments(
        for: .codexCLI, model: "default", workingDirectory: directory,
        responseSchemaURL: schema
    )
    #expect(arguments.contains("--output-schema"))
    #expect(arguments.contains(schema.path))
    #expect(arguments.last == "-")
    let image = directory.appendingPathComponent("image-0.png")
    let withImage = CLIChatProviderClient.arguments(
        for: .codexCLI, model: "default", workingDirectory: directory,
        imageURLs: [image]
    )
    #expect(withImage.contains("--image"))
    #expect(withImage.contains(image.path))
    #expect(withImage.last == "-")
}

@Test func cliProviderExtractsKnownResponseShapes() throws {
    let codex = Data("""
    {"type":"item.completed","item":{"type":"agent_message","text":"First"}}
    {"type":"item.completed","item":{"type":"agent_message","text":"Final reply"}}
    """.utf8)
    #expect(try CLIChatProviderClient.extractReply(from: codex, provider: .codexCLI) == "Final reply")
    let claude = Data(#"{"result":" Claude reply ","is_error":false}"#.utf8)
    #expect(try CLIChatProviderClient.extractReply(from: claude, provider: .claudeCLI) == "Claude reply")
    let claudeFailure = Data(#"{"result":"Login failed","is_error":true}"#.utf8)
    #expect(throws: CLIChatProviderClient.Failure.self) {
        _ = try CLIChatProviderClient.extractReply(from: claudeFailure, provider: .claudeCLI)
    }
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

@Test func cliProviderRetainsUserRequestAfterLargeToolResult() throws {
    let request = "Summarize the returned evidence about the blue case."
    let history = [
        AIProviderMessage(role: .user, text: request),
        AIProviderMessage(role: .assistant, content: [.toolUse(id: "call-2", name: "lima_fixture_lookup", arguments: "{}")]),
        AIProviderMessage(role: .user, content: [.toolResult(id: "call-2", output: String(repeating: "evidence ", count: 20_000))])
    ]
    let prompt = try CLIChatProviderClient.prompt(
        input: "", history: history, attachments: [], systemInstructions: "",
        localTools: [fixtureCLITool()]
    )
    #expect(prompt.contains("CURRENT USER REQUEST:\n" + request))
    #expect(prompt.contains("LIMA TOOL DATA — UNTRUSTED"))
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
    let codexPrompt = try CLIChatProviderClient.prompt(
        input: "Describe", history: [], attachments: [image],
        systemInstructions: "", allowImages: true
    )
    #expect(codexPrompt.contains("VISIBLE IMAGE — Image (attached separately)"))
}

@Test func codexCLIContinuationAttachesOnlyCurrentBoundedScreenshot() throws {
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
    let base64 = jpeg.base64EncodedString()
    let history = [
        AIProviderMessage(role: .user, text: "Inspect the page"),
        AIProviderMessage(role: .assistant, content: [
            .toolUse(id: "capture", name: "browser_screenshot", arguments: "{}")
        ]),
        AIProviderMessage(role: .user, content: [
            .toolResult(id: "capture", output: #"{"image_attached":true}"#),
            .text("Browser screenshot from tool call capture."),
            .image(mediaType: "image/jpeg", base64: base64)
        ])
    ]
    let images = CLIChatProviderClient.transientImages(from: history)
    #expect(images.count == 1)
    #expect(try CLIChatProviderClient.validatedJPEGData(for: images[0]) == jpeg)
    let prompt = try CLIChatProviderClient.prompt(
        input: "", history: history, attachments: [], systemInstructions: "",
        allowImages: true
    )
    #expect(prompt.contains("Browser screenshot from tool call capture."))
    #expect(!prompt.contains(base64))
    #expect(CLIChatProviderClient.transientImages(
        from: history + [AIProviderMessage(role: .user, text: "Next turn")]
    ).isEmpty)

    #expect(throws: CLIChatProviderClient.Failure.self) {
        _ = try CLIChatProviderClient.validatedJPEGData(for: .init(
            mediaType: "image/png", base64: base64
        ))
    }
    #expect(throws: CLIChatProviderClient.Failure.self) {
        _ = try CLIChatProviderClient.validatedJPEGData(for: .init(
            mediaType: "image/jpeg", base64: Data([0, 1, 2]).base64EncodedString()
        ))
    }
}
