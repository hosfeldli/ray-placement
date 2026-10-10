import Foundation
import RayPlacementCore
import Testing
@testable import RayPlacement

@Test func explicitTestModeIsolatesWorkspacePathsAndPreferences() throws {
    guard LimaTestEnvironment.isEnabled else { return }
    let root = try #require(LimaTestEnvironment.dataRoot)
    #expect(ApplicationPaths.applicationSupport == root.appendingPathComponent("Application Support", isDirectory: true))
    #expect(ApplicationPaths.notes.deletingLastPathComponent() == ApplicationPaths.applicationSupport)
    #expect(ApplicationPaths.extensions.deletingLastPathComponent() == ApplicationPaths.applicationSupport)
    #expect(LimaTestEnvironment.userDefaults !== UserDefaults.standard)
    let key = "workspace-fixture-isolation." + UUID().uuidString
    defer { LimaTestEnvironment.userDefaults.removeObject(forKey: key) }
    LimaTestEnvironment.userDefaults.set("fixture-only", forKey: key)
    #expect(LimaTestEnvironment.userDefaults.string(forKey: key) == "fixture-only")
    #expect(UserDefaults.standard.object(forKey: key) == nil)
}

@Test func optionalPanesPreserveEditorWidth() {
    #expect(LimaWorkspaceMetrics.sidebarWidth(contentWidth: 600, preferred: 232) == 0)
    #expect(LimaWorkspaceMetrics.sidebarWidth(contentWidth: 668, preferred: 232) == 232)
    #expect(LimaWorkspaceMetrics.sidebarWidth(contentWidth: 1400, preferred: nil) == 0)
    #expect(!LimaWorkspaceMetrics.showsInspector(contentWidth: 711))
    #expect(LimaWorkspaceMetrics.showsInspector(contentWidth: 712))
    #expect(!LimaWorkspaceMetrics.showsInspector(contentWidth: 943, sidebarWidth: 232))
    #expect(LimaWorkspaceMetrics.showsInspector(contentWidth: 944, sidebarWidth: 232))
}

@Test func homeRecentItemsSortRealWorkAndSkipEmptyChats() {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let olderNote = MarkdownNote(title: "Older note", content: "Saved work", modifiedAt: base)
    let newerNote = MarkdownNote(title: "Newer note", content: "More work", modifiedAt: base.addingTimeInterval(120))
    let conversation = AIConversation(
        title: "Project discussion",
        updatedAt: base.addingTimeInterval(60),
        messages: [AIChatMessage(role: .user, text: "Decide the next step")]
    )
    let emptyChat = AIConversation(title: "New Chat", updatedAt: base.addingTimeInterval(180))
    let recent = HomeRecentItem.sorted(
        notes: [olderNote, newerNote],
        conversations: [emptyChat, conversation]
    )
    #expect(recent.map(\.title) == ["Newer note", "Project discussion", "Older note"])
    #expect(recent.map(\.id).count == Set(recent.map(\.id)).count)
}

@Test func noteFiltersUseLocalCalendarAndRealMetadata() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    let today = calendar.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 0, minute: 5))!
    let yesterday = calendar.date(byAdding: .minute, value: -10, to: today)!
    var note = MarkdownNote(title: "Planning", content: "Local text")
    note.modifiedAt = yesterday
    #expect(NotesWorkspaceFilter.all.includes(note))
    #expect(!NotesWorkspaceFilter.today.includes(note, now: today, calendar: calendar))
    note.modifiedAt = today
    #expect(NotesWorkspaceFilter.today.includes(note, now: today, calendar: calendar))
    #expect(!NotesWorkspaceFilter.pinned.includes(note))
    #expect(!NotesWorkspaceFilter.favorites.includes(note))
    note.isPinned = true
    note.isFavorite = true
    #expect(NotesWorkspaceFilter.pinned.includes(note))
    #expect(NotesWorkspaceFilter.favorites.includes(note))
}

@Test func installedExtensionFiltersSearchNamesIDsAndCommands() {
    #expect(ExtensionWorkspaceFilter.matches(query: "FORMAT json", name: "Format Tools", id: "local.formatter", commandTitles: ["Format JSON"]))
    #expect(ExtensionWorkspaceFilter.matches(query: "local.formatter", name: "Format Tools", id: "local.formatter", commandTitles: []))
    #expect(!ExtensionWorkspaceFilter.matches(query: "calendar", name: "Format Tools", id: "local.formatter", commandTitles: []))
    #expect(ExtensionWorkspaceFilter.enabled.includes(enabled: true, bundled: false))
    #expect(!ExtensionWorkspaceFilter.disabled.includes(enabled: true, bundled: false))
    #expect(ExtensionWorkspaceFilter.builtIn.includes(enabled: false, bundled: true))
    #expect(!ExtensionWorkspaceFilter.local.includes(enabled: true, bundled: true))
}

@MainActor
private func draftTestModel() -> AIChatViewModel {
    AIChatViewModel(
        store: AIConversationStore(fixtures: []),
        credentials: AIChatCredentialStore(configuration: .fixture),
        nativeToolStore: LimaAIToolStore(fixtures: []),
        transport: FixtureAITransport(events: []),
        taskRegistry: TaskRegistry(),
        workspaceStore: AIWorkspaceStore(fixtures: [])
    )
}

@Test @MainActor func noteActionsOnlyPrepareDraftsAndRefreshTheSnapshot() {
    let model = draftTestModel()
    var note = MarkdownNote(title: "Planning", content: "First version")
    model.draft = "Keep this unsent text."
    let unrelated = AIAttachment(kind: .selection, displayName: "Selection", text: "Selected text")
    model.add(unrelated)
    #expect(model.prepareNoteDraft(note, prompt: "Summarize."))
    #expect(model.draft == "Keep this unsent text.\n\nSummarize.")
    #expect(model.attachments.count == 2)
    #expect(model.attachments.first { $0.id == note.id }?.text == "First version")
    note.content = "Edited version"
    #expect(model.prepareNoteDraft(note, prompt: " "))
    #expect(model.attachments.count == 2)
    #expect(model.attachments.first { $0.id == note.id }?.text == "Edited version")
    #expect(model.attachments.contains(unrelated))
    #expect(model.store.conversations.isEmpty)
    #expect(!model.canEndTask)
    model.appendDraftPrompt("   ")
    #expect(model.draft == "Keep this unsent text.\n\nSummarize.")
}

@Test @MainActor func workspaceShortcutsPreserveDraftAndRequireUsefulContext() {
    let model = draftTestModel()
    model.draft = "Keep my instructions."
    #expect(!model.prepareWorkspaceAction(.summarize))
    #expect(model.draft == "Keep my instructions.")
    #expect(model.prepareWorkspaceAction(.brainstorm))
    #expect(model.draft.contains("Keep my instructions."))
    #expect(model.attachments.isEmpty)
    model.add(AIAttachment(kind: .selection, displayName: "Selection", text: "A useful source."))
    for action in AIWorkspaceAction.allCases {
        #expect(model.prepareWorkspaceAction(action))
        #expect(model.draft.contains(action.instruction))
    }
    #expect(model.attachments.count == 1)
    #expect(model.store.conversations.isEmpty)
    #expect(!model.canEndTask)
    let draft = model.draft
    model.applyVisualFixture(isStreaming: true)
    for action in AIWorkspaceAction.allCases {
        #expect(!model.prepareWorkspaceAction(action))
    }
    #expect(model.draft == draft)
}

@Test func workspaceShortcutsHaveUniqueUsefulDefinitions() {
    #expect(Set(AIWorkspaceAction.allCases.map(\.id)).count == AIWorkspaceAction.allCases.count)
    #expect(AIWorkspaceAction.allCases.allSatisfy { !$0.title.isEmpty && !$0.symbol.isEmpty && !$0.instruction.isEmpty })
}

@Test @MainActor func noteActionsCannotMutateAnActiveTask() {
    let model = draftTestModel()
    model.draft = "Untouched"
    let context = AIAttachment(kind: .clipboard, displayName: "Existing", text: "Keep")
    model.add(context)
    model.applyVisualFixture(isStreaming: true)
    #expect(model.canEndTask)
    #expect(!model.prepareNoteDraft(MarkdownNote(title: "Note", content: "Private"), prompt: "Summarize"))
    model.appendDraftPrompt("Do not append")
    #expect(model.draft == "Untouched")
    #expect(model.attachments == [context])
    #expect(model.store.conversations.isEmpty)
}
