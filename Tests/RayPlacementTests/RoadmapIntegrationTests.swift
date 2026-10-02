import Foundation
import Testing
import RayPlacementCore
@testable import RayPlacement

@Test @MainActor func captureToNotesNamesAndSelectsTheSavedContent() throws {
    let notes = NotesStore(visualFixtures: [])
    let selection = try CaptureNoteService.save(
        "  Selected words  ",
        source: .selection(applicationName: "Safari\nWindow"),
        in: notes
    )
    #expect(notes.selectedNoteID == selection)
    #expect(notes.selectedNote?.title == "Captured Selection · Safari Window")
    #expect(notes.selectedNote?.content == "Selected words")

    let clipboard = try CaptureNoteService.save("Clipboard text", source: .clipboard, in: notes)
    #expect(notes.selectedNoteID == clipboard)
    #expect(notes.selectedNote?.title == "Captured Clipboard")
    #expect(notes.selectedNote?.content == "Clipboard text")
    #expect(notes.notes.count == 2)
}

@Test @MainActor func captureToNotesRejectsEmptyAndOversizedInputWithoutChangingSelection() throws {
    let notes = NotesStore(visualFixtures: [])
    let first = try CaptureNoteService.save("Keep me", source: .clipboard, in: notes)
    #expect((try? CaptureNoteService.save("  \n ", source: .clipboard, in: notes)) == nil)
    #expect((try? CaptureNoteService.save(
        String(repeating: "x", count: NotesStore.maximumCharactersPerNote + 1),
        source: .clipboard,
        in: notes
    )) == nil)
    #expect(notes.selectedNoteID == first)
    #expect(notes.notes.count == 1)
}

@Test @MainActor func captureCommandsAreVisibleInRootAndCommandSearch() {
    let model = LauncherViewModel(clipboard: ClipboardHistoryService(fixtures: []), scanApplications: false)
    let ids = Set(model.results.map(\.id))
    #expect(ids.contains("builtin.capture-clipboard-note"))
    #expect(ids.contains("builtin.capture-selection-note"))
    #expect(ids.contains("builtin.capture-dictation-note"))

    model.query = "command: capture"
    let scopedIDs = Set(model.results.map(\.id))
    #expect(scopedIDs.contains("builtin.capture-clipboard-note"))
    #expect(scopedIDs.contains("builtin.capture-selection-note"))
    #expect(scopedIDs.contains("builtin.capture-dictation-note"))
}

@Test @MainActor func contextSearchFindsBoundedPayloadAndUsesStableRoutingID() async {
    let id = UUID()
    let entries = [
        LimaContextSearchProvider.Entry(
            id: id, title: "Offer", preview: "First paragraph",
            text: "Hidden deepmarker in the selected text", kind: "selectedText", pinned: true
        )
    ]
    let matches = await LimaContextSearchProvider(entries: entries).search(query: "deepmarker")
    #expect(matches.count == 1)
    #expect(matches.first?.id == "context:\(id.uuidString)")
    #expect(matches.first?.kind == .context)
    #expect(matches.first?.subtitle.contains("Pinned") == true)
    #expect(UniversalSearchCoordinator.parse("shelf: deepmarker").prefix == "context")
    #expect(UniversalSearchCoordinator.parse("context: deepmarker").query == "deepmarker")
}

@Test @MainActor func workspaceActivationRestoresTheSelectedModule() {
    let profiles = WorkspaceProfileStore.shared
    let registry = WorkspaceStateRegistry.shared
    let originalState = registry.state
    let originalProfile = profiles.activeProfile
    let first = profiles.create(name: "Fixture First")
    registry.update { $0.activeModule = "notes" }
    let second = profiles.create(name: "Fixture Second")
    defer {
        if let originalProfile { profiles.activate(originalProfile) }
        profiles.delete(first)
        profiles.delete(second)
        registry.update { $0 = originalState }
    }

    registry.update { $0.activeModule = "ai" }
    profiles.activate(first)
    #expect(registry.state.activeModule == "notes")
    profiles.activate(second)
    #expect(registry.state.activeModule == "ai")
}

@Test @MainActor func workflowBuiltinsShareRootCommandIDsAndResolveOlderChains() {
    let canonical: [LimaWorkflowBuiltin: String] = [
        .openNotes: "builtin.notes",
        .openAI: "builtin.ai-chat",
        .openContext: "builtin.context-shelf",
        .openTerminal: "builtin.terminal",
        .createNote: "builtin.create-note",
        .captureClipboard: "builtin.capture-clipboard-note"
    ]
    let legacy: [String: LimaWorkflowBuiltin] = [
        "builtin.workflow.open-notes": .openNotes,
        "builtin.workflow.open-ai": .openAI,
        "builtin.workflow.open-context": .openContext,
        "builtin.workflow.open-terminal": .openTerminal,
        "builtin.workflow.create-note": .createNote,
        "builtin.workflow.capture-clipboard": .captureClipboard
    ]
    let catalog = LimaWorkflowCommandCatalog.available(extensions: [])
    for (command, id) in canonical {
        #expect(command.rawValue == id)
        #expect(catalog.contains { $0.id == id })
    }
    for (oldID, command) in legacy {
        #expect(LimaWorkflowCommandCatalog.resolve(oldID, extensions: [])?.id == command.rawValue)
    }
    let search = LauncherViewModel(clipboard: ClipboardHistoryService(fixtures: []), scanApplications: false)
    search.query = "new note"
    #expect(search.results.contains { $0.id == "builtin.create-note" })
}

@Test @MainActor func workflowRunsRegisteredStepsInOrderAndHonorsFailurePolicy() async {
    let catalog = LimaWorkflowCommandCatalog.available(extensions: [])
    #expect(catalog.contains { $0.id == LimaWorkflowBuiltin.captureClipboard.rawValue })
    #expect(LimaWorkflowCommandCatalog.resolve(LimaWorkflowBuiltin.createNote.rawValue, extensions: []) != nil)

    let workflow = WorkflowDefinition(name: "Fixture", steps: [
        .init(commandID: "one"),
        .init(commandID: "two", continueOnFailure: true),
        .init(commandID: "three")
    ])
    var seen: [String] = []
    let report = await WorkflowExecutor().execute(workflow, confirm: true) { id in
        seen.append(id)
        if id == "two" {
            throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected failure"])
        }
    }
    #expect(seen == ["one", "two", "three"])
    #expect(report.steps.map(\.succeeded) == [true, false, true])
}

@Test @MainActor func cancelledWorkflowDoesNotStartACommand() async {
    let workflow = WorkflowDefinition(name: "Cancelled", steps: [.init(commandID: "never")])
    let task = Task { @MainActor in
        withUnsafeCurrentTask { $0?.cancel() }
        return await WorkflowExecutor().execute(workflow, confirm: true) { _ in
            Issue.record("A cancelled workflow must not dispatch its next step.")
        }
    }
    let report = await task.value
    #expect(report.steps.count == 1)
    #expect(report.steps.first?.succeeded == false)
    #expect(report.steps.first?.message == "Cancelled")
}

@Test @MainActor func developerTraceOmitsSampleDetails() {
    let secret = "private-prompt-\(UUID().uuidString)"
    PerformanceMonitor.shared.record("Fixture request", duration: 0.012, detail: secret)
    let trace = PerformanceMonitor.shared.redactedTrace()
    #expect(trace.contains("Fixture request"))
    #expect(!trace.contains(secret))
    #expect(PerformanceMonitor.shared.samples.count <= PerformanceMonitor.maximumSamples)
}
