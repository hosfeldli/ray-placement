import Foundation
import Testing
import RayPlacementCore
@testable import RayPlacement

private func contextCall(_ name: String, _ arguments: [String: String]) throws -> AIOutputItem {
    let data = try JSONEncoder().encode(arguments)
    return AIOutputItem(phase: .added, apiType: "function_call", callID: UUID().uuidString,
                        name: name, arguments: String(decoding: data, as: UTF8.self))
}

@MainActor
private func functionalModel(workspace: AIWorkspaceStore? = nil,
                             projectID: UUID? = nil, tools: Set<String> = []) -> AIChatViewModel {
    AIChatViewModel(store: AIConversationStore(fixtures: [AIConversation(projectID: projectID)]),
        credentials: AIChatCredentialStore(configuration: .fixture),
        mcpStore: MCPServerStore(fixtures: []),
        nativeToolStore: LimaAIToolStore(fixtures: tools), transport: FixtureAITransport.standard,
        taskRegistry: TaskRegistry(), workspaceStore: workspace ?? AIWorkspaceStore(fixtures: []))
}

@Test @MainActor func memoryToolsAreReadOnlyAndUserControlsRemainScoped() throws {
    let store = AIWorkspaceStore(fixtures: [])
    let project = try #require(store.createProject(name: "Current"))
    let other = try #require(store.createProject(name: "Other"))
    let hidden = try #require(store.createMemory(title: "Hidden", content: "Other project only", projectID: other.id))
    let model = functionalModel(
        workspace: store,
        projectID: project.id,
        tools: ["memory_search", "memory_save", "memory_forget"]
    )

    #expect(LimaAIToolRegistry.definition(for: "memory_save") == nil)
    #expect(LimaAIToolRegistry.definition(for: "memory_forget") == nil)
    #expect(LimaAIToolRegistry.enabledDefinitions(["memory_search", "memory_save", "memory_forget"]).map(\.id) == ["memory_search"])

    let deniedSave = AIContextTools.memory(
        try contextCall("memory_save", ["id": "", "title": "Preference", "content": "Use concise summaries", "scope": "project"]),
        store: store,
        projectID: project.id
    )
    #expect(deniedSave.isError)
    #expect(store.memories(for: project.id).isEmpty)

    let memory = try #require(model.saveMemory(title: "Preference", content: "Use concise summaries"))
    #expect(memory.projectID == project.id)
    #expect(model.updateMemory(memory.id, title: "Preference", content: "Use detailed summaries"))
    let searched = AIContextTools.memory(
        try contextCall("memory_search", ["query": "summaries"]),
        store: store,
        projectID: project.id
    )
    #expect(searched.output.contains(memory.id.uuidString))
    #expect(!searched.output.contains(hidden.id.uuidString))
    #expect(AIContextTools.memory(
        try contextCall("memory_forget", ["id": memory.id.uuidString]),
        store: store,
        projectID: project.id
    ).isError)
    #expect(!model.forgetMemory(hidden.id))
    #expect(model.forgetMemory(memory.id))
    #expect(store.memories.count == 1)
}

@Test @MainActor func memoryReadRejectsMalformedAndMutationRequests() throws {
    let store = AIWorkspaceStore(fixtures: [])
    #expect(AIContextTools.arguments(String(repeating: "x", count: 32_001)) == nil)
    #expect(AIContextTools.arguments("{\"query\":12}") == nil)
    for (name, args) in [
        ("memory_save", ["id": "", "title": "Bad", "content": "Valid", "scope": "global"]),
        ("memory_forget", ["id": UUID().uuidString])
    ] {
        #expect(AIContextTools.memory(try contextCall(name, args), store: store, projectID: nil).isError)
    }
    #expect(AIContextTools.memory(try contextCall("memory_search", ["query": "", "extra": "no"]), store: store, projectID: nil).isError)
    #expect(store.memories.isEmpty)
}

@Test @MainActor func memoryOffOmitsContextAndReviewActionsRemainScoped() throws {
    let store = AIWorkspaceStore(fixtures: [])
    let current = try #require(store.createProject(name: "Current"))
    let other = try #require(store.createProject(name: "Other"))
    let visible = try #require(store.createMemory(title: "Preference", content: "uniqueMemorySentinel", projectID: current.id))
    let hidden = try #require(store.createMemory(title: "Other", content: "hidden", projectID: other.id))
    let model = functionalModel(workspace: store, projectID: current.id)
    #expect(!model.systemInstructions.contains("uniqueMemorySentinel"))
    #expect(model.updateMemory(visible.id, title: "Edited", content: "Updated"))
    #expect(!model.updateMemory(hidden.id, title: "No", content: "No"))
    #expect(!model.forgetMemory(hidden.id))
    model.applyVisualFixture(isStreaming: true)
    #expect(!model.forgetMemory(visible.id))
    #expect(!model.updateMemory(visible.id, title: "No", content: "No"))
    #expect(model.saveMemory(title: "No", content: "No") == nil)
    model.applyVisualFixture(isStreaming: false)
    #expect(model.forgetMemory(visible.id))
    #expect(store.memories.count == 1)
}

@Test @MainActor func contextHandoffsRefreshSnapshotsWithoutSending() {
    let model = functionalModel()
    let id = UUID()
    let first = LimaContextValue(id: id, kind: .note, title: "Selected note", value: "Original")
    let edited = LimaContextValue(id: id, kind: .note, title: "Selected note", value: "Updated full content")
    model.draft = "Existing unsent draft."
    #expect(model.prepareContextDraft(first, prompt: "Summarize."))
    #expect(model.prepareContextDraft(edited, prompt: ""))
    #expect(model.attachments.count == 1)
    #expect(model.attachments.first?.text == "Updated full content")
    #expect(model.draft == "Existing unsent draft.\n\nSummarize.")
    #expect(model.selectedConversation?.messages.isEmpty == true)
    model.applyVisualFixture(isStreaming: true)
    #expect(!model.prepareContextDraft(first, prompt: "Do not send"))
    #expect(model.attachments.first?.text == "Updated full content")
}

@Test @MainActor func contextActionsAreCompatibleAndUseSelectedPayload() {
    let context = LimaContextValue(kind: .note, title: "Note", value: "Full selected content")
    let actions = LimaCompatibilityRegistry.shared.actions(for: context)
    #expect(actions.allSatisfy { $0.supports(context) })
    #expect(!actions.contains { $0.id == "use-with" || $0.id == "terminal" })
    for action in actions where action.id == "ai" || action.id == "proofread" {
        if case .prepareAIContext(let actual, _) = action.action { #expect(actual == context) }
        else { Issue.record("AI actions must prepare the selected context without sending.") }
    }
    if case .addContextToShelf(let actual) = actions.first(where: { $0.id == "shelf" })?.action {
        #expect(actual == context)
    } else { Issue.record("Shelf must receive the selected content, not a fresh external selection.") }
}

@Test @MainActor func searchScopesNormalizeAliasesAndKeepURLsIntact() {
    for (raw, expected) in [("NOTES: plan", "note"), ("apps: Safari", "app"),
                            ("commands: notes", "command"), ("clipboard: text", "clipboard"),
                            ("workflow: morning", "workflow"), ("dictation: meeting", "dictation"),
                            ("chats: release", "chat"), ("ai: release", "chat")] {
        #expect(UniversalSearchCoordinator.parse(raw).prefix == expected)
    }
    #expect(UniversalSearchCoordinator.parse("https://example.com").prefix == nil)
    #expect(UniversalSearchCoordinator.parse("notes:  ").query.isEmpty)
}

@Test @MainActor func scopedClipboardKeepsDeepMatchesAndDraftActions() throws {
    let entry = ClipboardEntry(text: String(repeating: "A short preface. ", count: 20) + "quartzmarker")
    let olderEntries = (0..<120).map { ClipboardEntry(text: "Unrelated clip \($0)") } + [entry]
    let model = LauncherViewModel(clipboard: ClipboardHistoryService(fixtures: olderEntries), scanApplications: false)
    model.query = "quartzmarker"
    #expect(model.results.contains { $0.id == "clipboard.\(entry.id)" })
    model.query = "clipboard: quartzmarker"
    let match = try #require(model.results.first { $0.id == "clipboard.\(entry.id)" })
    #expect(!match.title.contains("quartzmarker"))
    #expect(model.results.filter { $0.id == match.id }.count == 1)
    let actions = model.actionPanelActions(for: match)
    let ai = try #require(actions.first { $0.id == "use-with.ai" })
    if case .prepareAIContext(let context, _) = ai.action { #expect(context.value == entry.text) }
    else { Issue.record("Clipboard action must prepare full text.") }
    model.openActionPanel()
    model.query = "commands: notes"
    #expect(model.actionPanelItem == nil)
    #expect(!model.results.contains { $0.id.hasPrefix("clipboard.") })
}

@Test func noteProviderMatchesBeyondPreviewAndCapsResults() async {
    let notes = (0..<25).map { MarkdownNote(title: "Note \($0)", content: String(repeating: "preface ", count: 100) + "quartzmarker") }
    let results = await LimaNotesSearchProvider(notes: notes).search(query: "quartzmarker")
    #expect(results.count == 20)
    #expect(Set(results.map(\.id)).count == results.count)
    #expect(results.allSatisfy { $0.kind == .note && $0.id.hasPrefix("note:") })
}

@Test func dictationSearchScansOnlyRecentTranscriptSegments() async {
    let conversation = DictationConversation(segments: [
        "zzzxxyy " + String(repeating: "earlier meeting content ", count: 2_000),
        "Latest decision: bluequartzmarker"
    ])
    let provider = LimaDictationSearchProvider(conversations: [conversation])
    let recent = await provider.search(query: "bluequartzmarker")
    #expect(recent.first?.id == "dictation:\(conversation.id.uuidString)")
    #expect((await provider.search(query: "zzzxxyy")).isEmpty)
}

@Test func aiConversationSearchUsesStableIDsAndBoundedVisibleTurns() async {
    let conversation = AIConversation(
        title: "Release planning",
        messages: [
            AIChatMessage(role: .user, text: "oldquartzmarker"),
            AIChatMessage(role: .assistant, text: "Unrelated earlier reply"),
            AIChatMessage(role: .user, text: "Discuss current launch"),
            AIChatMessage(role: .assistant, text: "Check final design audit"),
            AIChatMessage(role: .user, text: "New context: bluequartzmarker")
        ]
    )
    let provider = LimaAIConversationSearchProvider(conversations: [conversation])
    let results = await provider.search(query: "bluequartzmarker")
    #expect(results.count == 1)
    #expect(results.first?.id == "conversation:\(conversation.id.uuidString)")
    #expect(results.first?.kind == .aiConversation)
    #expect((await provider.search(query: "oldquartzmarker")).isEmpty)
    #expect((await provider.search(query: "b")).isEmpty)
}

@Test @MainActor func grammarRoutingIsAPIFirstButHonorsExplicitLocal() {
    #expect(RuleBasedWritingChecker.shouldUseAPI(mode: .externalAPI))
    #expect(!RuleBasedWritingChecker.shouldUseAPI(mode: .local))
    #expect(!RuleBasedWritingChecker.shouldUseAPI(mode: .externalAPI, forceLocal: true))
    #expect(!RuleBasedWritingChecker.shouldUseAPI(mode: .local, forceLocal: true))
}

@Test @MainActor func grammarDefaultsPreserveExplicitAndLegacyChoices() {
    #expect(SettingsStore.resolvedGrammarMode(storedValue: nil, legacyAPIEnabled: nil) == .externalAPI)
    #expect(SettingsStore.resolvedGrammarMode(storedValue: "invalid", legacyAPIEnabled: nil) == .externalAPI)
    #expect(SettingsStore.resolvedGrammarMode(storedValue: nil, legacyAPIEnabled: false) == .local)
    #expect(SettingsStore.resolvedGrammarMode(storedValue: nil, legacyAPIEnabled: true) == .externalAPI)
    #expect(SettingsStore.resolvedGrammarMode(storedValue: GrammarEngineMode.local.rawValue, legacyAPIEnabled: true) == .local)
    #expect(SettingsStore.resolvedGrammarMode(storedValue: GrammarEngineMode.externalAPI.rawValue, legacyAPIEnabled: false) == .externalAPI)
}

@Test @MainActor func disabledMemoryAndUnknownAgentsCannotReceiveSavedContext() throws {
    let store = AIWorkspaceStore(fixtures: [], memories: [AIMemory(title: "Preference", content: "sentinelUserContext")])
    let model = functionalModel(workspace: store, tools: AIContextTools.memoryIDs)
    #expect(model.systemInstructions.contains("sentinelUserContext"))
    var conversation = try #require(model.selectedConversation)
    conversation.agentID = "unavailable-agent"
    model.store.update(conversation)
    #expect(!model.systemInstructions.contains("sentinelUserContext"))
    #expect(model.routedNativeTools(for: "Remember this").isEmpty)
}

@Test @MainActor func currentPageIntentUsesOnlyEnabledGrantedBrowserTools() {
    let ids: Set<String> = ["browser_tabs", "browser_current", "browser_read"]
    let model = functionalModel(tools: ids)
    #expect(model.isBrowserPrompt("Inspect the links on this page"))
    #expect(model.isBrowserPrompt("Read my current webpage"))
    #expect(Set(model.routedNativeTools(for: "Read my current webpage").map(\.id)).isSubset(of: ids))
    #expect(model.routedNativeTools(for: "Read my current webpage").contains { $0.id == "browser_current" })
}

@Test func subagentsRequireCompleteBoundedToolFreeAnswers() async {
    let model = AIModelOption(id: "fixture")
    let good = await AISubagentRunner.run(client: FixtureAITransport.standard, apiKey: "fixture", model: model, task: "Analyze supplied text.")
    #expect(!good.isError)
    #expect(good.output.contains("unverifiedAnalysis"))
    let cases: [[AIChatStreamEvent]] = [
        [.textDelta("Partial")],
        [.completed(nil)],
        [.textDelta(String(repeating: "x", count: 12_001)), .completed(nil)],
        [.outputItem(AIOutputItem(phase: .added, apiType: "function_call", callID: "child", name: "memory_save")), .completed(nil)],
        [.failed("Fixture failure")]
    ]
    for events in cases {
        let result = await AISubagentRunner.run(client: FixtureAITransport(events: events), apiKey: "fixture", model: model, task: "Analyze")
        #expect(result.isError)
    }
    for task in [" ", String(repeating: "x", count: 16_001)] {
        let result = await AISubagentRunner.run(client: FixtureAITransport.standard, apiKey: "fixture", model: model, task: task)
        #expect(result.isError)
    }
}

@Test func subagentTimeoutEndsWaitingForProvider() async {
    let transport = FixtureAITransport(events: [.textDelta("Late"), .completed(nil)], interEventDelay: .seconds(5))
    let result = await AISubagentRunner.run(client: transport, apiKey: "fixture",
        model: AIModelOption(id: "fixture"), task: "Analyze", timeout: .milliseconds(10))
    #expect(result.isError)
    #expect(result.output.contains("timed out"))
}

@Test func subagentCancellationCannotReturnSuccess() async {
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return await AISubagentRunner.run(client: FixtureAITransport.standard, apiKey: "fixture",
                                         model: AIModelOption(id: "fixture"), task: "Analyze")
    }
    let result = await task.value
    #expect(result.isError)
    #expect(result.output.contains("cancelled"))
}
