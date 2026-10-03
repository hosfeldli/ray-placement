import AppKit
import Foundation
import RayPlacementCore
import Testing
@testable import RayPlacement

@Test func testCredentialConfigurationUsesSeparateNamespaceAndExplicitEnvironmentValue() {
    let configuration = AIChatCredentialConfiguration.current(environment: [
        "LIMA_TEST_MODE": "1",
        "LIMA_TEST_OPENAI_API_KEY": " test-key "
    ])
    #expect(configuration.service == "dev.liam.lima.ai.test")
    #expect(configuration.account == "openai-api-key")
    #expect(configuration.environmentAPIKey == "test-key")
    #expect(configuration.isTestCredential)
    #expect(configuration.usesKeychain)

    let production = AIChatCredentialConfiguration.current(environment: [:])
    #expect(production.service == "dev.liam.lima.ai")
    #expect(production.environmentAPIKey == nil)
    #expect(!production.isTestCredential)
}

@Test func liveAITestsRequireBothTestModeAndExplicitSessionSwitch() {
    #expect(!LimaTestEnvironment.allowsLiveAI(environment: ["LIMA_TEST_MODE": "1"]))
    #expect(!LimaTestEnvironment.allowsLiveAI(environment: ["LIMA_ALLOW_LIVE_AI_TESTS": "1"]))
    #expect(LimaTestEnvironment.allowsLiveAI(environment: [
        "LIMA_TEST_MODE": "1",
        "LIMA_ALLOW_LIVE_AI_TESTS": "1"
    ]))
}

@Test func providerNeutralHistoryPreservesTextAndOmitsStreamingPlaceholder() {
    let transcript = AIProviderMessage.transcript([
        AIChatMessage(role: .user, text: "First question"),
        AIChatMessage(role: .assistant, text: "First answer"),
        AIChatMessage(role: .user, text: "Follow up"),
        AIChatMessage(role: .assistant, text: "")
    ])

    #expect(transcript.count == 3)
    let text = transcript.flatMap(\.content).compactMap { item -> String? in
        if case .text(let value) = item { return value }
        return nil
    }
    #expect(text == ["First question", "First answer", "Follow up"])
}

@Test func providerWireHelpersPreserveToolUseAndResultAndBasePath() {
    let history = [
        AIProviderMessage(role: .assistant, content: [
            .toolUse(id: "call-1", name: "search_files", arguments: #"{"query":"invoice"}"#)
        ]),
        AIProviderMessage(role: .user, content: [
            .toolResult(id: "call-1", output: #"{"count":1}"#)
        ])
    ]
    let payload = AIProviderHTTP.messages(history)
    #expect(payload.count == 2)
    #expect(payload[0]["role"] as? String == "assistant")
    #expect(payload[1]["role"] as? String == "user")
    let assistantContent = payload[0]["content"] as? [[String: Any]]
    let userContent = payload[1]["content"] as? [[String: Any]]
    #expect(assistantContent?.first?["type"] as? String == "tool_use")
    #expect(userContent?.first?["type"] as? String == "tool_result")

    let base = AIProviderHTTP.validateBaseURL("https://example.test/v1")
    #expect(AIProviderHTTP.endpoint(base: base!, path: "chat/completions")?.path == "/v1/chat/completions")
}

@Test func sharedProviderRegistryIncludesChatCoreProviders() {
    #expect(AIProvider.chatProviders == [.openAI, .anthropic, .gemini, .openAICompatible])
    #expect(AIProviderClientRegistry.client(for: .openAI, openAICompatibleBaseURL: "") is AIChatResponsesClient)
    #expect(AIProviderClientRegistry.client(for: .anthropic, openAICompatibleBaseURL: "") is AnthropicAIProviderClient)
    #expect(AIProviderClientRegistry.client(for: .gemini, openAICompatibleBaseURL: "") is GeminiAIProviderClient)
    #expect(AIProviderClientRegistry.client(for: .openAICompatible, openAICompatibleBaseURL: "http://127.0.0.1:1234/v1") is OpenAICompatibleAIProviderClient)
}

@Test @MainActor func aiProviderSelectionPersistsPerConversation() {
    let openAIConversation = AIConversation(provider: .openAI, model: "gpt-5.4")
    let geminiConversation = AIConversation(provider: .gemini, model: "gemini-2.5-flash")
    let store = AIConversationStore(fixtures: [openAIConversation, geminiConversation])
    let model = AIChatViewModel(
        store: store,
        credentials: AIChatCredentialStore(configuration: .fixture),
        mcpStore: MCPServerStore(fixtures: []),
        nativeToolStore: LimaAIToolStore(fixtures: []),
        transport: FixtureAITransport.standard
    )

    model.select(openAIConversation.id)
    model.selectProvider(.anthropic)
    #expect(store.conversation(id: openAIConversation.id)?.provider == .anthropic)
    #expect(store.conversation(id: openAIConversation.id)?.model == AIProvider.anthropic.defaultChatModel)

    model.select(geminiConversation.id)
    #expect(model.provider == .gemini)
    #expect(model.model == "gemini-2.5-flash")
}

@Test @MainActor func fixtureCredentialsStayInMemory() {
    let connected = AIChatCredentialStore(configuration: .fixture)
    let missing = AIChatCredentialStore(configuration: .missingFixture)
    #expect(connected.hasAPIKey)
    #expect(!missing.hasAPIKey)
    #expect(missing.apiKey() == nil)
}

@Test @MainActor func publicWebReaderBlocksPrivateHostsAndExtractsReadableContent() {
    #expect(LimaAIToolRegistry.publicWebURL("https://example.com/docs") != nil)
    #expect(LimaAIToolRegistry.publicWebURL("http://127.0.0.1:8080") == nil)
    #expect(LimaAIToolRegistry.publicWebURL("https://192.168.1.1") == nil)
    #expect(LimaAIToolRegistry.publicWebURL("https://localhost") == nil)
    #expect(LimaAIToolRegistry.publicWebURL("https://user:pass@example.com") == nil)

    let extracted = LimaAIToolRegistry.readableWebContent(
        fromHTML: """
        <html lang="en"><head><title>Example &amp; Guide</title>
        <meta name="description" content="Readable &amp; safe">
        <meta property="og:description" content="Literal &amp;lt;code&amp;gt;">
        <style>body { color: red; }</style><script>ignoreThis(); <p>hidden script text</p></script></head>
        <body><nav>Ignore navigation</nav><p>Outside the main article</p>
        <main><h1>Useful guide &mdash; start</h1><p>Read this public text.</p>
        <form><p>Hidden form text</p></form><svg><text>Hidden SVG text</text></svg>
        <a href="/next" data-label="reader > safe">Next &amp; beyond</a>
        <a href="http://127.0.0.1/private">Private</a></main></body></html>
        """,
        baseURL: URL(string: "https://example.com/docs")!
    )
    #expect(extracted.title == "Example & Guide")
    #expect(extracted.content.contains("Useful guide — start"))
    #expect(extracted.content.contains("Read this public text."))
    #expect(!extracted.content.contains("Ignore navigation"))
    #expect(!extracted.content.contains("Outside the main article"))
    #expect(!extracted.content.contains("hidden script text"))
    #expect(!extracted.content.contains("Hidden form text"))
    #expect(!extracted.content.contains("Hidden SVG text"))
    #expect(extracted.headings == ["Useful guide — start"])
    #expect(extracted.metadata["description"] == "Readable & safe")
    #expect(extracted.metadata["og:description"] == "Literal &lt;code&gt;")
    #expect(extracted.metadata["language"] == "en")
    #expect(extracted.links == ["https://example.com/next"])
    #expect(extracted.linkDetails == [[
        "text": "Next & beyond",
        "url": "https://example.com/next"
    ]])
}

@Test @MainActor func fixtureTransportCarriesPromptToVisibleAssistantTurn() async {
    let store = AIConversationStore(fixtures: [])
    let model = AIChatViewModel(
        store: store,
        credentials: AIChatCredentialStore(configuration: .fixture),
        mcpStore: MCPServerStore(fixtures: []),
        nativeToolStore: LimaAIToolStore(fixtures: []),
        transport: FixtureAITransport(events: [
            .responseCreated("fixture-response"),
            .textDelta("Lima works"),
            .completed("fixture-response")
        ])
    )

    model.draft = "Reply with exactly: Lima works"
    model.send()
    for _ in 0..<300 where model.isStreaming {
        try? await Task.sleep(for: .milliseconds(10))
    }

    let assistantText = store.conversations.first?.messages.last(where: { $0.role == .assistant })?.text
    #expect(assistantText == "Lima works")
}

@Test @MainActor func endingStreamingTaskKeepsVisiblePartialAnswerAndStoppedState() async {
    let store = AIConversationStore(fixtures: [])
    let model = AIChatViewModel(
        store: store,
        credentials: AIChatCredentialStore(configuration: .fixture),
        mcpStore: MCPServerStore(fixtures: []),
        nativeToolStore: LimaAIToolStore(fixtures: []),
        transport: FixtureAITransport(
            events: [
                .textDelta("Partial answer"),
                .completed("fixture-cancel")
            ],
            // Yield visible output immediately, then leave a deliberately long
            // cancellation window before completion. This avoids test-scheduler
            // races when the complete suite runs its tests concurrently.
            interEventDelay: .seconds(2)
        )
    )

    model.draft = "Start a paced response"
    model.send()
    for _ in 0..<300 where model.streamingText != "Partial answer" {
        try? await Task.sleep(for: .milliseconds(5))
    }

    #expect(model.canEndTask)
    #expect(model.streamingText == "Partial answer")
    #expect(store.conversations.first?.messages.last?.text == "")
    model.endTask()
    for _ in 0..<300 where model.isStreaming {
        try? await Task.sleep(for: .milliseconds(5))
    }

    let assistant = store.conversations.first?.messages.last(where: { $0.role == .assistant })
    #expect(!model.canEndTask)
    #expect(assistant?.text == "Partial answer")
    #expect(assistant?.activities?.contains(where: { $0.title == "Stopped" }) == true)
    #expect(model.currentTaskState.title == "Stopped")
}

@Test @MainActor func providerFailurePreservesVisiblePartialAnswer() async {
    let store = AIConversationStore(fixtures: [])
    let model = AIChatViewModel(
        store: store,
        credentials: AIChatCredentialStore(configuration: .fixture),
        mcpStore: MCPServerStore(fixtures: []),
        nativeToolStore: LimaAIToolStore(fixtures: []),
        transport: FixtureAITransport(
            events: [
                .reasoningSummaryDelta("Reasoning summary"),
                .textDelta("Partial answer"),
                .failed("HTTP 400: unsupported request option")
            ],
            interEventDelay: .milliseconds(180)
        )
    )

    model.draft = "Start a response that fails"
    model.send()
    for _ in 0..<300 where model.streamingReasoningSummary != "Reasoning summary" {
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.streamingReasoningSummary == "Reasoning summary")
    #expect(store.conversations.first?.messages.last?.reasoningSummary == nil)
    for _ in 0..<300 where model.streamingText != "Partial answer" {
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.streamingText == "Partial answer")

    for _ in 0..<300 where model.isStreaming {
        try? await Task.sleep(for: .milliseconds(5))
    }

    let assistant = store.conversations.first?.messages.last(where: { $0.role == .assistant })
    #expect(assistant?.text == "Partial answer")
    #expect(assistant?.reasoningSummary == "Reasoning summary")
    #expect(model.streamError != nil)
    #expect(assistant?.activities?.contains(where: { $0.title == "Request failed" }) == true)
}

@Test @MainActor func endingPendingApprovalClearsPauseWithoutRunningTool() async {
    let store = AIConversationStore(fixtures: [])
    let model = AIChatViewModel(
        store: store,
        credentials: AIChatCredentialStore(configuration: .fixture),
        mcpStore: MCPServerStore(fixtures: []),
        nativeToolStore: LimaAIToolStore(fixtures: []),
        transport: FixtureAITransport(events: [
            .responseCreated("fixture-approval"),
            .approval(AIToolApprovalRequest(
                serverLabel: "Fixture",
                toolName: "Blocked action",
                arguments: "{}"
            ))
        ])
    )

    model.draft = "Open settings"
    model.send()
    for _ in 0..<300 where model.pendingApproval == nil || model.isStreaming {
        try? await Task.sleep(for: .milliseconds(5))
    }

    #expect(model.canEndTask)
    #expect(model.pendingApproval != nil)
    model.endTask()

    let assistant = store.conversations.first?.messages.last(where: { $0.role == .assistant })
    #expect(model.pendingApproval == nil)
    #expect(!model.canEndTask)
    #expect(assistant?.text == "Task ended before the requested tool was run.")
    #expect(assistant?.activities?.contains(where: { $0.title == "Task ended" }) == true)
    #expect(model.currentTaskState.title == "Task ended")
}

/// Intentionally inert unless all three live-test variables are set by the
/// invoking process. It uses only in-memory Lima stores and the test token
/// environment override, never a production Keychain item or conversation.
@Test @MainActor func optInLiveResponsesPathLeavesVisibleAssistantText() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["LIMA_RUN_LIVE_AI_TESTS"] == "1",
          LimaTestEnvironment.allowsLiveAI(environment: environment),
          environment[AIChatCredentialConfiguration.testAPIKeyVariable]?.isEmpty == false else {
        return
    }

    let conversation = AIConversation(model: "gpt-5.4")
    let store = AIConversationStore(fixtures: [conversation])
    let model = AIChatViewModel(
        store: store,
        credentials: AIChatCredentialStore(configuration: .current(environment: environment)),
        mcpStore: MCPServerStore(fixtures: []),
        nativeToolStore: LimaAIToolStore(fixtures: []),
        transport: AIChatResponsesClient()
    )
    model.draft = "Reply with exactly: Lima works"
    model.send()

    let deadline = Date().addingTimeInterval(90)
    while model.isStreaming, Date() < deadline {
        try await Task.sleep(for: .milliseconds(100))
    }

    #expect(!model.isStreaming)
    let text = store.conversations.first?.messages.last(where: { $0.role == .assistant })?.text
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if text != "Lima works" {
        let diagnostics = model.streamDiagnostics.map(\.developerSummary).joined(separator: " | ")
        Issue.record("Live stream summary: \(model.streamError ?? "none") · diagnostics: \(diagnostics)")
    }
    #expect(text == "Lima works")
}

/// Uses a compact exact-probability task so the live integration test verifies
/// a high-reasoning request reaches a correct visible answer without storing a
/// chain-of-thought or any production conversation.
@Test @MainActor func optInLiveResponsesPathSolvesReasoningTask() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["LIMA_RUN_LIVE_AI_TESTS"] == "1",
          LimaTestEnvironment.allowsLiveAI(environment: environment),
          environment[AIChatCredentialConfiguration.testAPIKeyVariable]?.isEmpty == false else {
        return
    }

    let conversation = AIConversation(model: "gpt-5.4", reasoningEffort: .high)
    let store = AIConversationStore(fixtures: [conversation])
    let model = AIChatViewModel(
        store: store,
        credentials: AIChatCredentialStore(configuration: .current(environment: environment)),
        mcpStore: MCPServerStore(fixtures: []),
        nativeToolStore: LimaAIToolStore(fixtures: []),
        transport: AIChatResponsesClient()
    )
    model.draft = """
    There are three boxes. A has 6 red and 4 blue balls, B has 3 red and 7 blue balls, and C has 5 red and 5 blue balls. Draw one ball uniformly at random from each box. What is the probability that exactly two are red? Reply with exactly the simplified fraction.
    """
    model.send()

    let deadline = Date().addingTimeInterval(90)
    while model.isStreaming, Date() < deadline {
        try await Task.sleep(for: .milliseconds(100))
    }

    #expect(!model.isStreaming)
    let text = store.conversations.first?.messages.last(where: { $0.role == .assistant })?.text
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if text != "9/25" {
        let diagnostics = model.streamDiagnostics.map(\.developerSummary).joined(separator: " | ")
        Issue.record("Live reasoning summary: \(model.streamError ?? "none") · diagnostics: \(diagnostics)")
    }
    #expect(text == "9/25")
}

@Test func aiReasoningEffortUsesFriendlyLabelsAndStableValues() {
    #expect(AIReasoningEffort.medium.rawValue == "medium")
    #expect(AIReasoningEffort.medium.title == "Standard")
    #expect(AIReasoningEffort.high.detail.contains("deliberate"))
}

@Test func aiModelCapabilitiesLimitReasoningToSupportedValues() {
    let gpt6 = AIModelOption(id: "gpt-6-luna")
    #expect(!gpt6.isLegacyOrUnknown)
    #expect(gpt6.supportsReasoning)
    #expect(gpt6.supportedReasoningEfforts == [.none, .low, .medium, .high, .xhigh, .max])

    let unknown = AIModelOption(id: "future-private-model")
    #expect(unknown.isLegacyOrUnknown)
    #expect(!unknown.supportsReasoning)
    #expect(unknown.supportedReasoningEfforts.isEmpty)

    let chat = AIModelOption(id: "gpt-5")
    #expect(chat.supportsReasoning)
    #expect(chat.supportedReasoningEfforts.contains(.high))

    let nonReasoning = AIModelOption(id: "gpt-4o")
    #expect(!nonReasoning.supportsReasoning)
    #expect(nonReasoning.supportedReasoningEfforts.isEmpty)
}

@Test func unknownModelUsesMinimalResponsesPayload() {
    let body = AIChatResponsesClient.replyBody(
        model: "future-private-model",
        input: [["role": "user", "content": [["type": "input_text", "text": "Hello"]]]],
        previousResponseID: nil,
        reasoningEffort: .high,
        tools: []
    )
    #expect(body["model"] as? String == "future-private-model")
    #expect(body["stream"] as? Bool == true)
    #expect(body["reasoning"] == nil)
    #expect(body["store"] == nil)
    #expect(body["instructions"] == nil)
}

@Test @MainActor func promptToolRoutingSendsOnlyRelevantEnabledTools() {
    let toolStore = LimaAIToolStore(fixtures: [
        "search_files", "find_files", "list_directory", "file_metadata", "read_file",
        "search_web", "read_web", "read_screen_context", "list_extensions", "get_lima_status",
        "browser_tabs", "browser_current", "browser_read", "salesforce_read_case_links", "salesforce_resolve_case", "salesforce_resolve_cases",
        "browser_open_tabs", "browser_focus_tab", "browser_navigate_tab"
    ])
    let model = AIChatViewModel(
        store: AIConversationStore(fixtures: []),
        credentials: AIChatCredentialStore(configuration: .fixture),
        mcpStore: MCPServerStore(fixtures: []),
        nativeToolStore: toolStore,
        transport: FixtureAITransport.standard
    )

    #expect(model.routedNativeTools(for: "Explain this query").isEmpty)
    #expect(model.isBrowserPrompt("Open new tabs for these cases"))
    #expect(model.isBrowserPrompt("Click the Continue button"))
    #expect(model.isBrowserPrompt("Submit the form"))
    #expect(!model.isBrowserPrompt("Format this tabular data"))
    #expect(Set(model.routedNativeTools(for: "Inspect the Salesforce cases in my current browser tab").map { $0.id }) == [
        "browser_tabs", "browser_current", "browser_read",
        "salesforce_read_case_links", "salesforce_resolve_case", "salesforce_resolve_cases"
    ])
    #expect(Set(model.routedNativeTools(for: "Open new tabs for the Salesforce cases").map { $0.id }) == [
        "browser_tabs", "browser_current", "browser_read",
        "salesforce_read_case_links", "salesforce_resolve_case", "salesforce_resolve_cases"
    ])
    #expect(Set(model.routedNativeTools(for: "Find and read the Swift source file").map { $0.id }) == [
        "search_files", "find_files", "list_directory", "file_metadata", "read_file"
    ])
}

@Test @MainActor func browserNavigationPromptRoutesInspectionOnly() async throws {
    let model = AIChatViewModel(
        store: AIConversationStore(fixtures: []),
        credentials: AIChatCredentialStore(configuration: .fixture),
        mcpStore: MCPServerStore(fixtures: []),
        nativeToolStore: LimaAIToolStore(fixtures: Set(BrowserBridgeAITools.definitions.map { $0.id })),
        transport: FixtureAITransport.standard
    )

    let routed = Set(model.routedNativeTools(for: "Open new tabs for the Salesforce cases").map { $0.id })
    #expect(!routed.contains("browser_open_tabs"))
    #expect(!routed.contains("browser_focus_tab"))
    #expect(!routed.contains("browser_navigate_tab"))
    #expect(routed.contains("salesforce_read_case_links"))
    #expect(routed.contains("salesforce_resolve_cases"))

    model.draft = "Open new tabs for the Salesforce cases"
    model.send()
    for _ in 0..<100 where model.isStreaming { try await Task.sleep(for: .milliseconds(10)) }

    #expect(!model.isStreaming)
    #expect(model.streamError == nil)
}

@Test @MainActor func browserNavigationDefaultsOffAtEveryAIToolGate() async {
    let navigationIDs = ["browser_open_tabs", "browser_focus_tab", "browser_navigate_tab"]
    let definitions = LimaAIToolRegistry.enabledDefinitions(Set(navigationIDs))
    #expect(definitions.isEmpty)
    for id in navigationIDs {
        let call = AIOutputItem(
            phase: .completed,
            apiType: "function_call",
            callID: "call_\(id)",
            name: id,
            arguments: "{}"
        )
        let bridgeResult = await BrowserBridgeAITools.execute(call)
        #expect(bridgeResult.isError)
        #expect(bridgeResult.output.contains("disabled or still needs your approval"))
        let registryResult = await LimaAIToolRegistry.execute(call)
        #expect(registryResult.isError)
    }
}

@Test @MainActor func computerActionPolicyRetainsPerCategoryConfirmationRules() throws {
    let suite = "RayPlacementTests.computer-action-policy.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let policy = AIComputerActionPolicy(defaults: defaults)
    let navigation = try #require(BrowserBridgeAITools.definitions.first { $0.id == "browser_navigate_tab" })
    let interaction = try #require(BrowserBridgeAITools.definitions.first { $0.id == "browser_type" })
    let localFile = try #require(AILocalComputerActionTools.definitions.first { $0.id == "create_text_file" })
    let terminal = try #require(AILocalComputerActionTools.definitions.first { $0.id == "run_terminal_command" })

    #expect(policy.access(for: .browserNavigation) == .disabled)
    #expect(policy.access(for: .browserInteraction) == .disabled)
    #expect(!policy.browserInteractionExperimentalEnabled)
    #expect(!policy.broadBrowserGrantsExperimentalEnabled)
    #expect(policy.access(for: .localFiles) == .disabled)
    #expect(policy.access(for: .terminal) == .disabled)

    policy.setAccess(.allowWithJournal, for: .browserNavigation)
    #expect(!policy.requiresApproval(for: navigation))
    policy.setBroadBrowserGrantsExperimentalEnabled(true)
    #expect(policy.broadBrowserGrantsExperimentalEnabled)
    #expect(defaults.bool(forKey: AIComputerActionPolicy.broadBrowserGrantsKey))
    #expect(AIComputerActionPolicy(defaults: defaults).broadBrowserGrantsExperimentalEnabled)
    #expect(policy.requiresApproval(for: interaction))
    policy.setBroadBrowserGrantsExperimentalEnabled(false)
    #expect(!policy.broadBrowserGrantsExperimentalEnabled)
    #expect(!defaults.bool(forKey: AIComputerActionPolicy.broadBrowserGrantsKey))
    #expect(!AIComputerActionPolicy(defaults: defaults).broadBrowserGrantsExperimentalEnabled)
    policy.setAccess(.askEveryTime, for: .browserInteraction)
    #expect(policy.access(for: .browserInteraction) == .disabled)
    policy.setBrowserInteractionExperimentalEnabled(true)
    policy.setAccess(.askEveryTime, for: .browserInteraction)
    #expect(policy.access(for: .browserInteraction) == .askEveryTime)
    policy.setAccess(.askEveryTime, for: .localFiles)
    policy.setAccess(.askEveryTime, for: .terminal)
    #expect(policy.requiresApproval(for: interaction))
    #expect(policy.requiresApproval(for: localFile))
    #expect(policy.requiresApproval(for: terminal))
    policy.setBrowserInteractionExperimentalEnabled(false)
    #expect(policy.access(for: .browserInteraction) == .disabled)
    #expect(defaults.string(forKey: "lima.ai.computer-action.browserInteraction") == AIComputerActionAccess.disabled.rawValue)
    #expect(defaults.string(forKey: "lima.ai.computer-action.browserNavigation") == AIComputerActionAccess.allowWithJournal.rawValue)
}

@Test func localCommandRunnerRejectsGitWritesAndEscapingOperands() {
    let directory = URL(fileURLWithPath: "/Users/example/project", isDirectory: true)
    #expect(AILocalCommandRunner.acceptsCommand("git status --short", workingDirectory: directory))
    #expect(AILocalCommandRunner.acceptsCommand("git diff --stat", workingDirectory: directory))
    #expect(!AILocalCommandRunner.acceptsCommand("git branch -D main", workingDirectory: directory))
    #expect(!AILocalCommandRunner.acceptsCommand("git diff --output=changes.txt", workingDirectory: directory))
    #expect(!AILocalCommandRunner.acceptsCommand("git diff --ext-diff", workingDirectory: directory))
    #expect(!AILocalCommandRunner.acceptsCommand("git show HEAD:.env", workingDirectory: directory))
    #expect(!AILocalCommandRunner.acceptsCommand("swift test --package-path=/tmp/other", workingDirectory: directory))
    #expect(!AILocalCommandRunner.acceptsCommand("swift build --scratch-path ../other", workingDirectory: directory))
    #expect(!AILocalCommandRunner.acceptsCommand("xcodebuild -derivedDataPath /tmp/output build", workingDirectory: directory))
}

@Test func localCommandRunnerRejectsSymlinkedScriptAncestors() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LimaCommandSafety-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let scripts = root.appendingPathComponent("scripts", isDirectory: true)
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    try Data("print('safe')\n".utf8).write(to: scripts.appendingPathComponent("task.py"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: scripts)

    #expect(AILocalCommandRunner.approvedScript("scripts/task.py", workingDirectory: root, extensions: ["py"]))
    #expect(!AILocalCommandRunner.approvedScript("alias/task.py", workingDirectory: root, extensions: ["py"]))
    #expect(!AILocalCommandRunner.approvedScript("../task.py", workingDirectory: root, extensions: ["py"]))
}

@Test @MainActor func strictToolSchemasAreProviderReadyAndNormalizeOptionalArguments() throws {
    let definitions = LimaAIToolRegistry.definitions + BrowserBridgeAITools.definitions + AILocalComputerActionTools.definitions
    #expect(definitions.allSatisfy { $0.responsePayload != nil })

    for definition in definitions {
        let payload = try #require(definition.responsePayload)
        let parameters = try #require(payload["parameters"] as? [String: Any])
        #expect(openAIStrictSchemaIssue(in: parameters) == nil)
    }

    let findFiles = try #require(definitions.first { $0.id == "find_files" })
    let payload = try #require(findFiles.responsePayload)
    let parameters = try #require(payload["parameters"] as? [String: Any])
    #expect(Set(try #require(parameters["required"] as? [String])) == ["directory", "query"])

    let properties = try #require(parameters["properties"] as? [String: Any])
    let directory = try #require(properties["directory"] as? [String: Any])
    #expect(directory["type"] as? [String] == ["string", "null"])

    let batchOpen = try #require(definitions.first { $0.id == "browser_open_tabs" })
    #expect(batchOpen.risk == .navigation)
    #expect(batchOpen.responsePayload?["strict"] as? Bool == true)
    let batchParameters = try #require(batchOpen.responsePayload?["parameters"] as? [String: Any])
    let batchProperties = try #require(batchParameters["properties"] as? [String: Any])
    let urls = try #require(batchProperties["urls"] as? [String: Any])
    #expect(urls["maxItems"] as? Int == 50)

    let queueLinks = try #require(definitions.first { $0.id == "salesforce_read_case_links" })
    #expect(queueLinks.risk == .read)
    let replacement = try #require(definitions.first { $0.id == "replace_text_file" })
    let replacementParameters = try #require(replacement.responsePayload?["parameters"] as? [String: Any])
    #expect(Set(try #require(replacementParameters["required"] as? [String])) == ["content", "expected_modified_at", "path"])
    let terminal = try #require(definitions.first { $0.id == "run_terminal_command" })
    #expect(terminal.actionCategory == .terminal)
}

@Test @MainActor func browserURLToolsDoNotUseUnsupportedURIFormat() throws {
    let fields = [
        "browser_open_tabs": "urls",
        "browser_focus_tab": "expected_url",
        "browser_navigate_tab": "url"
    ]
    for definition in BrowserBridgeAITools.definitions where fields[definition.id] != nil {
        let parameters = try #require(definition.responsePayload?["parameters"] as? [String: Any])
        let properties = try #require(parameters["properties"] as? [String: Any])
        let property = try #require(properties[fields[definition.id]!] as? [String: Any])
        let value: [String: Any]
        if definition.id == "browser_open_tabs" {
            value = try #require(property["items"] as? [String: Any])
        } else {
            value = property
        }
        #expect(value["format"] == nil)
        #expect((value["description"] as? String)?.contains("HTTPS") == true)
    }
}

@Test func strictSchemaValidatorRejectsUnsupportedURIFormat() {
    let definition = LimaAIToolDefinition(
        id: "invalid_uri_format",
        name: "invalid_uri_format",
        description: "Regression fixture.",
        parameters: [
            "type": "object",
            "properties": [
                "url": ["type": "string", "format": "uri"]
            ],
            "required": ["url"],
            "additionalProperties": false
        ],
        risk: .read
    )

    #expect(definition.responsePayload == nil)
    #expect(definition.schemaValidationMessage?.contains("Unsupported strict schema format: uri") == true)
}

@Test func strictSchemaValidatorRecursesThroughObjectsArraysAndAnyOf() throws {
    let valid = LimaAIToolDefinition(
        id: "nested_schema",
        name: "nested_schema",
        description: "Regression fixture.",
        parameters: [
            "type": "object",
            "properties": [
                "filter": [
                    "type": "object",
                    "properties": ["date": ["type": "string", "format": "date"]],
                    "required": ["date"],
                    "additionalProperties": false
                ],
                "records": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": ["id": ["type": "integer", "minimum": 0]],
                        "required": ["id"],
                        "additionalProperties": false
                    ]
                ],
                "selector": [
                    "anyOf": [
                        ["type": "string", "format": "email"],
                        ["type": "integer", "minimum": 0]
                    ]
                ]
            ],
            "required": ["filter", "records", "selector"],
            "additionalProperties": false
        ],
        risk: .read
    )
    let validParameters = try #require(valid.responsePayload?["parameters"] as? [String: Any])
    #expect(openAIStrictSchemaIssue(in: validParameters) == nil)

    let invalid = LimaAIToolDefinition(
        id: "nested_uri",
        name: "nested_uri",
        description: "Regression fixture.",
        parameters: [
            "type": "object",
            "properties": [
                "selector": [
                    "anyOf": [
                        ["type": "string", "format": "uri"],
                        ["type": "integer"]
                    ]
                ]
            ],
            "required": ["selector"],
            "additionalProperties": false
        ],
        risk: .read
    )
    #expect(invalid.responsePayload == nil)
    #expect(invalid.schemaValidationMessage?.contains("Unsupported strict schema format: uri") == true)
}

@Test @MainActor func providerFailureRendersSafeActionableTranscript() async {
    let store = AIConversationStore(fixtures: [])
    let model = AIChatViewModel(
        store: store,
        credentials: AIChatCredentialStore(configuration: .fixture),
        mcpStore: MCPServerStore(fixtures: []),
        nativeToolStore: LimaAIToolStore(fixtures: []),
        transport: FixtureAITransport(events: [
            .diagnostic(AIChatDiagnostic(
                stage: .transport,
                httpStatus: 400,
                errorCode: "unsupported_parameter",
                errorParameter: "reasoning.summary",
                message: "The selected model does not support a requested option."
            )),
            .failed("ignored provider response body")
        ])
    )
    _ = model.selectCustomModel("gpt-6-luna")
    model.draft = "Explain this request"
    model.send()
    for _ in 0..<300 where model.isStreaming {
        try? await Task.sleep(for: .milliseconds(5))
    }

    let text = store.conversations.first?.messages.last(where: { $0.role == .assistant })?.text ?? ""
    #expect(text.contains("OpenAI rejected this request"))
    #expect(text.contains("HTTP 400 · gpt-6-luna"))
    #expect(text.contains("Unsupported request option: reasoning.summary."))
    #expect(!text.contains("ignored provider response body"))
}

@Test func gpt54ReasoningProfileRejectsLegacyMinimalAndMax() {
    let option = AIModelOption(id: "gpt-5.4")
    #expect(option.supportedReasoningEfforts == [.none, .low, .medium, .high, .xhigh])
    #expect(option.defaultReasoningEffort == .medium)
    #expect(AIModelOption.fallbackModels.first?.id == "gpt-5.4")

    let body = AIChatResponsesClient.replyBody(
        model: "gpt-5.4",
        input: [],
        previousResponseID: nil,
        reasoningEffort: .minimal,
        tools: []
    )
    let reasoning = body["reasoning"] as? [String: Any]
    #expect(reasoning?["effort"] as? String == AIReasoningEffort.medium.rawValue)
}

@Test func gpt56ReasoningProfileUsesCurrentSupportedValues() {
    let option = AIModelOption(id: "gpt-5.6-terra")
    #expect(option.supportedReasoningEfforts == [.none, .low, .medium, .high, .xhigh, .max])
    #expect(option.defaultReasoningEffort == .medium)

    let body = AIChatResponsesClient.replyBody(
        model: "gpt-5.6-terra",
        input: [],
        previousResponseID: nil,
        reasoningEffort: .minimal,
        tools: []
    )
    let reasoning = body["reasoning"] as? [String: Any]
    #expect(reasoning?["effort"] as? String == AIReasoningEffort.medium.rawValue)
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
        MCPToolDescriptor(serverID: serverID, name: "search", risk: .read, enabled: true, declaredReadOnly: true),
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

@Test func responsesMCPPayloadUsesAuthorizationFieldForStoredCredential() throws {
    let serverID = UUID()
    let server = MCPServer(
        name: "Docs",
        url: "https://example.com/mcp",
        allowedToolNames: ["search"],
        tools: [MCPToolDescriptor(serverID: serverID, name: "search", risk: .read, enabled: true, declaredReadOnly: true)]
    )
    let payload = try #require(
        AIChatResponsesClient.remoteMCPToolPayload(server: server, credential: "token")
    )

    #expect(payload["authorization"] as? String == "Bearer token")
    #expect(payload["headers"] == nil)
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
        agentID: "agent.code-review",
        skillIDs: ["skill.code-review", "extension.review-tools:review"],
        reasoningSummary: "The failure comes from the request body.",
        activities: [AIAgentActivity(kind: .toolCompleted, title: "Read package.json", completed: true)],
        attachments: [AIAttachment(kind: .clipboard, displayName: "Clipboard", text: "hello")],
        messages: [AIChatMessage(role: .user, text: "Explain this")]
    )
    let data = try JSONEncoder().encode(conversation)
    let restored = try JSONDecoder().decode(AIConversation.self, from: data)
    #expect(restored.reasoningEffort == .high)
    #expect(restored.agentID == "agent.code-review")
    #expect(restored.skillIDs == ["skill.code-review", "extension.review-tools:review"])
    #expect(restored.reasoningSummary?.contains("request body") == true)
    #expect(restored.activities.first?.title == "Read package.json")
    #expect(restored.attachments.first?.kind == .clipboard)
}

@Test @MainActor func skillsAndAgentsConfigureTheExistingConversation() {
    let store = AIConversationStore(fixtures: [])
    let model = AIChatViewModel(
        store: store,
        nativeToolStore: LimaAIToolStore(fixtures: ["search_files", "read_file", "search_web", "read_web"]),
        transport: FixtureAITransport.standard
    )

    #expect(AIChatConfigurationCatalog.provider(for: "openai") == .openAI)
    #expect(AIChatConfigurationCatalog.provider(for: "google-gemini") == .gemini)

    model.setSelectedSkills(["skill.writing"])
    #expect(model.selectedConversation?.skillIDs == ["skill.writing"])
    #expect(model.systemInstructions.contains("Skill — Writing"))
    #expect(model.systemInstructions.contains("preserving the author's intent"))

    model.selectAgent("agent.code-review")
    #expect(model.selectedAgentConfiguration?.name == "Code Review")
    #expect(model.selectedSkillIDs == ["skill.code-review"])
    #expect(model.systemInstructions.contains("Agent configuration"))
    #expect(model.systemInstructions.contains("careful code reviewer"))
    #expect(model.reasoningEffort == .high)
}

@Test func conversationInstructionsReachProviderRequestBodies() {
    let instructions = "Read-only safety policy.\nSkill instructions."
    let responseBody = AIChatResponsesClient.replyBody(
        model: "gpt-5",
        input: [],
        previousResponseID: nil,
        reasoningEffort: .medium,
        tools: [],
        systemInstructions: instructions
    )
    #expect(responseBody["instructions"] as? String == instructions)

    let anthropicBody = AnthropicAIProviderClient.body(
        model: "claude-3-7-sonnet-latest",
        history: [],
        tools: [],
        systemInstructions: instructions
    )
    #expect(anthropicBody["system"] as? String == instructions)
}

@Test func assistantTurnPersistsItsOwnReasoningAndActivity() throws {
    let message = AIChatMessage(
        role: .assistant,
        text: "Lima works.",
        reasoningSummary: "Checked the stream boundary.",
        activities: [AIAgentActivity(kind: .toolCompleted, title: "Search Files", completed: true)]
    )

    let restored = try JSONDecoder().decode(AIChatMessage.self, from: JSONEncoder().encode(message))
    #expect(restored.reasoningSummary == "Checked the stream boundary.")
    #expect(restored.activities?.first?.title == "Search Files")
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
    #expect(restored.agentID == nil)
    #expect(restored.skillIDs.isEmpty)
}

@Test func mcpRiskClassificationRequiresApprovalForWritesAndDestructiveTools() {
    #expect(MCPToolRisk.read.requiresApproval == false)
    #expect(MCPToolRisk.write.requiresApproval == true)
    #expect(MCPToolRisk.destructive.requiresApproval == true)
}

@Test func mcpServerAllowlistDefaultsToDiscoveredTools() {
    let serverID = UUID()
    let tools = [
        MCPToolDescriptor(serverID: serverID, name: "read_file", risk: .read, enabled: true, declaredReadOnly: true),
        MCPToolDescriptor(serverID: serverID, name: "delete_file", risk: .destructive, enabled: true)
    ]
    let server = MCPServer(name: "Files", url: "https://example.com/mcp", allowedToolNames: tools.map(\.name), tools: tools)
    #expect(server.enabledTools.map(\.name) == ["read_file", "delete_file"])
    #expect(server.apiLabel == "Files")
}

@Test func mcpServerCanRepresentAllToolsDisabled() {
    let serverID = UUID()
    let tool = MCPToolDescriptor(serverID: serverID, name: "read_file", risk: .read, enabled: true, declaredReadOnly: true)
    let server = MCPServer(name: "Files", url: "https://example.com/mcp", allowedToolNames: [MCPServer.noToolsSentinel], tools: [tool])
    #expect(server.enabledTools.isEmpty)
}

@Test func mcpReadOnlyEligibilityRequiresExplicitDeclarationAndRejectsLegacyGuesses() throws {
    #expect(MCPHTTPClient.risk(for: ["name": "search"], name: "search", description: nil) == .write)
    #expect(MCPHTTPClient.risk(for: ["annotations": ["readOnlyHint": true]], name: "search", description: nil) == .read)
    #expect(MCPHTTPClient.risk(for: ["annotations": ["readOnlyHint": true]], name: "open_tab", description: nil) == .write)
    #expect(MCPHTTPClient.risk(for: ["annotations": ["readOnlyHint": true, "destructiveHint": true]], name: "delete_file", description: nil) == .destructive)

    let id = UUID()
    let verified = MCPToolDescriptor(serverID: id, name: "search", risk: .read, enabled: true, declaredReadOnly: true)
    let legacy = MCPToolDescriptor(serverID: id, name: "list", risk: .read, enabled: true)
    let encodedLegacy = try JSONEncoder().encode(legacy)
    let restoredLegacy = try JSONDecoder().decode(MCPToolDescriptor.self, from: encodedLegacy)
    #expect(restoredLegacy.declaredReadOnly == nil)
    let server = MCPServer(name: "Docs", url: "https://example.com/mcp", tools: [verified, restoredLegacy])
    #expect(AIReadOnlyPolicy.readableMCPTools(for: server).map(\.name) == ["search"])
}

@Test func remoteMCPPayloadOmitsWriteAndDestructiveTools() throws {
    let serverID = UUID()
    let server = MCPServer(
        name: "Files",
        url: "https://example.com/mcp",
        tools: [
            MCPToolDescriptor(serverID: serverID, name: "read_file", risk: .read, enabled: true, declaredReadOnly: true),
            MCPToolDescriptor(serverID: serverID, name: "write_file", risk: .write, enabled: true),
            MCPToolDescriptor(serverID: serverID, name: "delete_file", risk: .destructive, enabled: true)
        ]
    )
    let payload = try #require(AIChatResponsesClient.remoteMCPToolPayload(server: server, credential: nil))
    #expect(payload["allowed_tools"] as? [String] == ["read_file"])
    let approval = try #require(payload["require_approval"] as? [String: [String: [String]]])
    #expect(approval["never"]?["tool_names"] == ["read_file"])
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

@Test func responsesSSEParserReconstructsMultilineJSON() {
    var parser = AIResponsesSSEParser(model: "gpt-5")
    let events = [
        "event: response.output_text.delta",
        #"data: {"type":"response.output_text.delta","#,
        #"data: "delta":"Lima works"}"#,
        ""
    ].flatMap { parser.append(line: $0) }

    #expect(events.contains { if case .textDelta(let text) = $0 { return text == "Lima works" }; return false })
    #expect(events.contains { if case .diagnostic = $0 { return true }; return false } == false)
}

@Test func responsesSSEByteParserPreservesCRLFEventDelimiters() {
    var parser = AIResponsesSSEParser(model: "gpt-5.4")
    let raw = "event: response.output_text.delta\r\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"Lima works\"}\r\n\r\n"
    var events: [AIChatStreamEvent] = []

    for byte in raw.utf8 {
        events += parser.append(byte: byte)
    }
    events += parser.finish()

    #expect(events.contains { if case .textDelta(let text) = $0 { return text == "Lima works" }; return false })
    #expect(events.contains { if case .diagnostic = $0 { return true }; return false } == false)
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
    #expect(events.contains { if case .diagnostic(let diagnostic) = $0 { return diagnostic.outputItemType == "unknown" }; return false })
    #expect(events.contains { if case .failed = $0 { return true }; return false } == false)
}

@Test func responsesDecoderReportsUnknownEventWithoutFailing() {
    let events = responseEvent("response.future_event", ["response_id": "resp_future"])
    #expect(events.count == 1)
    guard case .diagnostic(let diagnostic) = events.first else {
        Issue.record("Expected an unknown-event diagnostic")
        return
    }
    #expect(diagnostic.eventType == "unknown")
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

@Test @MainActor func advertisedNativeToolsAreReadOnly() {
    #expect(LimaAIToolRegistry.definitions.allSatisfy { !$0.risk.requiresApproval })
    #expect(LimaAIToolRegistry.definition(for: "open_lima_settings") == nil)
    #expect(LimaAIToolRegistry.definition(for: "read_screen_context")?.displayName == "Screen context")
    #expect(LimaAIToolRegistry.definition(for: "search_web")?.displayName == "Search the web")
    #expect(["list_directory", "find_files", "search_files", "read_file", "file_metadata"]
        .allSatisfy { LimaAIToolRegistry.definition(for: $0) != nil })
}

@Test @MainActor func fileToolsReturnBoundedNumberedRangesAndSkipHiddenOrLinkedEntries() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let directory = repository
        .appendingPathComponent(".build", isDirectory: true)
        .appendingPathComponent("ai-file-inspection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = directory.appendingPathComponent("sample.txt")
    try Data("alpha\nbeta\ngamma\n".utf8).write(to: file)
    try Data("hidden".utf8).write(to: directory.appendingPathComponent(".hidden.txt"))
    let symbolicLink = directory.appendingPathComponent("sample-link.txt")
    try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: file)

    let firstRange = LimaAIToolRegistry.readTextFile(at: file.path, startLine: 2, length: 1)
    #expect(!firstRange.isError)
    let rangePayload = try #require(
        JSONSerialization.jsonObject(with: Data(firstRange.output.utf8)) as? [String: Any]
    )
    #expect(rangePayload["content"] as? String == "2\tbeta")
    #expect(rangePayload["next_start_line"] as? Int == 3)
    #expect(rangePayload["truncated"] as? Bool == true)
    #expect(LimaAIToolRegistry.integerArgument(named: "start_line", from: #"{"start_line":true}"#) == nil)

    let listing = LimaAIToolRegistry.listDirectory(at: directory.path)
    let listingPayload = try #require(
        JSONSerialization.jsonObject(with: Data(listing.output.utf8)) as? [String: Any]
    )
    let entries = try #require(listingPayload["entries"] as? [[String: Any]])
    let names = entries.compactMap { $0["name"] as? String }
    #expect(names.contains("sample.txt"))
    #expect(!names.contains(".hidden.txt"))
    #expect(!names.contains("sample-link.txt"))

    let metadata = LimaAIToolRegistry.fileMetadata(at: file.path)
    let metadataPayload = try #require(
        JSONSerialization.jsonObject(with: Data(metadata.output.utf8)) as? [String: Any]
    )
    #expect(metadataPayload["name"] as? String == "sample.txt")
    #expect(metadataPayload["kind"] as? String == "file")
    #expect(metadataPayload["size_bytes"] as? Int == 17)
    #expect(LimaAIToolRegistry.readTextFile(at: symbolicLink.path).isError)
    #expect(LimaAIToolRegistry.listDirectory(at: "/etc").isError)
}

@Test @MainActor func extensionHostAdaptersAreAllowlistedAndTextTransformIsPure() async throws {
    let transform = try #require(ExtensionToolHostAdapterRegistry.adapter(for: "transform_text"))
    #expect(transform.requiredCapabilities.isEmpty)
    #expect(ExtensionToolHostAdapterRegistry.adapter(for: "run_shell") == nil)

    let declaration = ExtensionToolDefinition(
        id: "trim",
        title: "Trim text",
        description: "Remove surrounding whitespace.",
        execution: .hostReadOnly,
        hostAdapterID: "transform_text"
    )
    let result = try await transform.execute(
        definition: declaration,
        arguments: .object([
            "operation": .string("trim"),
            "text": .string("  review this  \n")
        ])
    )
    #expect(result == JSONValue.object(["text": JSONValue.string("review this")]))
    let normalizedName = ExtensionToolHostAdapterRegistry.functionName(extensionID: "local.review-tools", toolID: "read_diff")
    #expect(normalizedName.hasPrefix("ext__local_review-tools__read_diff__"))
    #expect(normalizedName != ExtensionToolHostAdapterRegistry.functionName(extensionID: "local_review-tools", toolID: "read_diff"))
    #expect(ExtensionToolHostAdapterRegistry.adapter(for: "read_text_file")?.requiredCapabilities == [.filesystem])
}

@Test @MainActor func extensionToolsRequireExplicitAIOptIn() {
    let identifier = "extension:local.review-tools:read_diff"
    let store = LimaAIToolStore(fixtures: [])
    let definition = LimaAIToolDefinition(
        id: identifier,
        name: "ext__local_review-tools__read_diff__deadbeef",
        description: "Read an approved diff.",
        parameters: ["type": "object"],
        risk: .read
    )

    #expect(!LimaAIToolRegistry.defaultEnabledToolIDs.contains(identifier))
    #expect(!store.isEnabled(definition))
    store.setEnabled(definition, enabled: true)
    #expect(store.isEnabled(definition))
}

@Test @MainActor func extensionHostAdapterRejectsUnapprovedBindings() async {
    let declaration = ExtensionToolDefinition(
        id: "trim",
        title: "Trim text",
        description: "Remove surrounding whitespace.",
        execution: .hostReadOnly,
        hostAdapterID: "transform_text"
    )
    let binding = ExtensionAIToolBinding(
        extensionID: "test.unapproved-\(UUID().uuidString)",
        extensionName: "Unapproved",
        extensionCapabilities: [],
        tool: declaration
    )
    var rejected = false
    do {
        _ = try await ExtensionToolHostAdapterRegistry.execute(
            binding,
            arguments: .object(["operation": .string("trim"), "text": .string(" data ")])
        )
    } catch {
        rejected = true
    }
    #expect(rejected)
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

@Test func aiComposerReturnSendsAndModifiedReturnInsertsNewline() {
    #expect(AIChatComposerKeyboardAction.action(isReturnKey: true, modifiers: []) == .send)
    #expect(AIChatComposerKeyboardAction.action(isReturnKey: true, modifiers: [.command]) == .send)
    #expect(AIChatComposerKeyboardAction.action(isReturnKey: true, modifiers: [.shift]) == .insertNewline)
    #expect(AIChatComposerKeyboardAction.action(isReturnKey: true, modifiers: [.option]) == .insertNewline)
    #expect(AIChatComposerKeyboardAction.action(isReturnKey: false, modifiers: []) == .passthrough)
}

@Test @MainActor func returnWithEmptyDraftDoesNotStartAIWork() {
    let registry = TaskRegistry()
    let store = AIConversationStore(fixtures: [])
    let model = AIChatViewModel(
        store: store,
        credentials: AIChatCredentialStore(configuration: .fixture),
        mcpStore: MCPServerStore(fixtures: []),
        nativeToolStore: LimaAIToolStore(fixtures: []),
        transport: FixtureAITransport(events: []),
        taskRegistry: registry
    )

    model.send()

    #expect(store.conversations.isEmpty)
    #expect(registry.activeTasks.isEmpty)
}

@Test @MainActor func sentContextIsShownOnItsTurnAndNotReusedByTheNextPrompt() async {
    let attachment = AIAttachment(kind: .selection, displayName: "Selected text", text: "First-turn context")
    let store = AIConversationStore(fixtures: [])
    let model = AIChatViewModel(
        store: store,
        credentials: AIChatCredentialStore(configuration: .fixture),
        mcpStore: MCPServerStore(fixtures: []),
        nativeToolStore: LimaAIToolStore(fixtures: []),
        transport: FixtureAITransport(events: [.textDelta("Done"), .completed("context-test")])
    )

    model.add(attachment)
    model.draft = "First prompt"
    model.send()
    #expect(model.attachments.isEmpty)
    #expect(store.conversations.first?.attachments.isEmpty == true)
    #expect(store.conversations.first?.messages.first?.attachments == [attachment])
    for _ in 0..<300 where model.isStreaming {
        try? await Task.sleep(for: .milliseconds(10))
    }

    model.draft = "Second prompt"
    model.send()
    let userTurns = store.conversations.first?.messages.filter { $0.role == .user } ?? []
    #expect(userTurns.count == 2)
    #expect(userTurns.first?.attachments == [attachment])
    #expect(userTurns.last?.attachments == nil)
    #expect(model.attachments.isEmpty)
    for _ in 0..<300 where model.isStreaming {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@Test @MainActor func longChatFixtureRepeatedTurnsCompleteAndMeasureComposerWork() async {
    let history = (0..<80).map { index in
        AIChatMessage(
            role: index.isMultiple(of: 2) ? .user : .assistant,
            text: "Prior turn \(index): " + String(repeating: "context ", count: 500)
        )
    }
    let store = AIConversationStore(fixtures: [AIConversation(title: "Long Chat", messages: history)])
    let registry = TaskRegistry()
    let model = AIChatViewModel(
        store: store,
        credentials: AIChatCredentialStore(configuration: .fixture),
        mcpStore: MCPServerStore(fixtures: []),
        nativeToolStore: LimaAIToolStore(fixtures: []),
        transport: FixtureAITransport.standard,
        taskRegistry: registry
    )
    var sendDurations: [TimeInterval] = []
    for turn in 0..<8 {
        model.draft = "Fixture follow-up \(turn)"
        let startedAt = Date()
        model.send()
        sendDurations.append(Date().timeIntervalSince(startedAt))
        for _ in 0..<300 where model.isStreaming {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isStreaming)
        #expect(model.streamError == nil)
        #expect(registry.activeTasks.isEmpty)
    }
    #expect(store.conversations.first?.messages.count == history.count + 16)
    let longestDuration = sendDurations.max() ?? .infinity
    #expect(longestDuration < 0.1, "Fixture long-chat composer work exceeded the 100 ms responsiveness budget.")
    let longest = Int((longestDuration * 1_000).rounded())
    print("Fixture long-chat composer send: 8 turns, longest synchronous call \(longest) ms; no live provider or UI rendering")
}

@Test @MainActor func returnDuringActiveTaskCannotStartAnotherAIRequest() async {
    let registry = TaskRegistry()
    let store = AIConversationStore(fixtures: [])
    let model = AIChatViewModel(
        store: store,
        credentials: AIChatCredentialStore(configuration: .fixture),
        mcpStore: MCPServerStore(fixtures: []),
        nativeToolStore: LimaAIToolStore(fixtures: []),
        transport: FixtureAITransport(
            events: [.textDelta("partial"), .completed("active-task")],
            interEventDelay: .seconds(2)
        ),
        taskRegistry: registry
    )

    model.draft = "First request"
    model.send()
    model.draft = "Second request"
    model.send()

    #expect(store.conversations.first?.messages.filter { $0.role == .user }.map(\.text) == ["First request"])
    #expect(registry.activeTasks.count == 1)
    model.cancel()
}

@Test @MainActor func launcherEscapeRouteKeepsAIWorkRunningUntilExplicitStop() async {
    let registry = TaskRegistry()
    let store = AIConversationStore(fixtures: [])
    let model = AIChatViewModel(
        store: store,
        credentials: AIChatCredentialStore(configuration: .fixture),
        mcpStore: MCPServerStore(fixtures: []),
        nativeToolStore: LimaAIToolStore(fixtures: []),
        transport: FixtureAITransport(
            events: [.textDelta("partial"), .completed("escape-task")],
            interEventDelay: .seconds(2)
        ),
        taskRegistry: registry
    )
    model.draft = "Keep working"
    model.send()
    guard let taskID = registry.activeTasks.first?.id else {
        Issue.record("Expected a registered AI task before routing Escape.")
        return
    }

    let escape = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "\u{1B}",
        charactersIgnoringModifiers: "\u{1B}",
        isARepeat: false,
        keyCode: 53
    )!

    #expect(LauncherAIKeyboardRoute.action(for: escape) == .navigateBack)
    #expect(model.canEndTask)
    #expect(registry.task(id: taskID)?.state == .running)

    // This is the same explicit cancellation invoked by the Activity Shelf's
    // stop control. Escape routed above never touches the registry entry.
    registry.cancel(taskID)
    for _ in 0..<300 where model.canEndTask {
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(!model.canEndTask)
    #expect(registry.task(id: taskID)?.state == .cancelled)
}

private let openAIStrictSchemaKeywords: Set<String> = [
    "type", "properties", "required", "additionalProperties", "description",
    "enum", "items", "anyOf", "pattern", "minimum", "maximum",
    "exclusiveMinimum", "exclusiveMaximum", "multipleOf", "minItems",
    "maxItems", "format"
]

private let openAIStrictSchemaFormats: Set<String> = [
    "date-time", "time", "date", "duration", "email", "hostname",
    "ipv4", "ipv6", "uuid"
]

private let openAIStrictJSONTypes: Set<String> = [
    "string", "number", "integer", "boolean", "object", "array", "null"
]

private func openAIStrictSchemaIssue(
    in schema: [String: Any],
    path: String = "parameters"
) -> String? {
    if let unsupported = Set(schema.keys).subtracting(openAIStrictSchemaKeywords).sorted().first {
        return "\(path) uses unsupported keyword \(unsupported)"
    }

    let types: [String]
    if let type = schema["type"] as? String {
        types = [type]
    } else if let values = schema["type"] as? [String] {
        types = values
    } else if schema["anyOf"] != nil {
        types = []
    } else {
        return "\(path) omits type"
    }
    if !types.isEmpty && (Set(types).count != types.count || !types.allSatisfy(openAIStrictJSONTypes.contains)) {
        return "\(path) has an invalid type declaration"
    }

    if let format = schema["format"] {
        guard types.contains("string"),
              let format = format as? String,
              openAIStrictSchemaFormats.contains(format) else {
            return "\(path) has unsupported format"
        }
    }

    if types.contains("object") {
        guard let properties = schema["properties"] as? [String: Any],
              schema["additionalProperties"] as? Bool == false,
              let required = schema["required"] as? [String],
              Set(required) == Set(properties.keys) else {
            return "\(path) is not a strict object schema"
        }
        for (name, value) in properties {
            guard let child = value as? [String: Any] else {
                return "\(path).properties.\(name) is not a schema"
            }
            if let issue = openAIStrictSchemaIssue(in: child, path: "\(path).properties.\(name)") {
                return issue
            }
        }
    } else if schema["properties"] != nil || schema["required"] != nil || schema["additionalProperties"] != nil {
        return "\(path) uses object keywords without object type"
    }

    if types.contains("array") {
        guard let items = schema["items"] as? [String: Any] else {
            return "\(path) omits array items"
        }
        if let issue = openAIStrictSchemaIssue(in: items, path: "\(path).items") {
            return issue
        }
    } else if schema["items"] != nil || schema["minItems"] != nil || schema["maxItems"] != nil {
        return "\(path) uses array keywords without array type"
    }

    if let rawBranches = schema["anyOf"] {
        guard let branches = rawBranches as? [Any], !branches.isEmpty else {
            return "\(path).anyOf is invalid"
        }
        for (index, value) in branches.enumerated() {
            guard let branch = value as? [String: Any] else {
                return "\(path).anyOf[\(index)] is not a schema"
            }
            if let issue = openAIStrictSchemaIssue(in: branch, path: "\(path).anyOf[\(index)]") {
                return issue
            }
        }
    }
    return nil
}
