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

@Test @MainActor func aiResponseCaptureCreatesEditableSourceLabeledNote() throws {
    let notes = NotesStore(visualFixtures: [])
    let report = "# Release report\n\n| Area | Status |\n| --- | --- |\n| Notes | Ready |"
    let identifier = try CaptureNoteService.save(
        report,
        source: .aiResponse(conversationTitle: "Lima 4.0\nstatus"),
        in: notes
    )
    #expect(notes.selectedNoteID == identifier)
    #expect(notes.selectedNote?.title == "AI Response · Lima 4.0 status")
    #expect(notes.selectedNote?.content == report)
    notes.updateContent(report + "\n\nUser edit")
    #expect(notes.selectedNote?.content.hasSuffix("User edit") == true)
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

@Test @MainActor func captureCommandsAreVisibleAfterTypingAndInCommandSearch() async {
    let model = LauncherViewModel(clipboard: ClipboardHistoryService(fixtures: []), scanApplications: false)
    #expect(model.results.isEmpty)
    model.query = "capture"
    await model.waitForLocalSearchForTesting()
    let ids = Set(model.results.map(\.id))
    #expect(ids.contains("builtin.capture-clipboard-note"))
    #expect(ids.contains("builtin.capture-selection-note"))
    #expect(ids.contains("builtin.capture-dictation-note"))

    model.query = "command: capture"
    await model.waitForLocalSearchForTesting()
    let scopedIDs = Set(model.results.map(\.id))
    #expect(scopedIDs.contains("builtin.capture-clipboard-note"))
    #expect(scopedIDs.contains("builtin.capture-selection-note"))
    #expect(scopedIDs.contains("builtin.capture-dictation-note"))
}

@Test @MainActor func hiddenWorkspaceModulesRemainAvailableInCommandSearch() async {
    let model = LauncherViewModel(clipboard: ClipboardHistoryService(fixtures: []), scanApplications: false)
    let commandIDs = Set(model.commandDescriptors.map(\.id))
    for id in ["builtin.grammar", "builtin.transcripts", "builtin.formatter"] {
        #expect(commandIDs.contains(id))
    }
    for (query, id) in [
        ("command: grammar", "builtin.grammar"),
        ("command: transcripts", "builtin.transcripts"),
        ("command: formatter", "builtin.formatter")
    ] {
        model.query = query
        await model.waitForLocalSearchForTesting()
        #expect(model.results.contains { $0.id == id })
    }
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
        registry.flushPendingWrites()
    }

    registry.update { $0.activeModule = "ai" }
    profiles.activate(first)
    #expect(registry.state.activeModule == "notes")
    profiles.activate(second)
    #expect(registry.state.activeModule == "ai")
    // A shutdown-style flush must not wait for the debounce timer to retain
    // the most recent module selection.
    registry.flushPendingWrites()
    let persisted = PrivateFileStore().loadJSON(
        WorkspaceState.self,
        from: ApplicationPaths.applicationSupport.appendingPathComponent("workspace-state.json")
    )
    #expect(persisted.value?.activeModule == "ai")
}

@Test func workspacePersistenceFlushesTheNewestQueuedSnapshot() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lima-workspace-persistence-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("workspace-state.json")
    let persistence = WorkspaceStatePersistence(url: url)
    var first = WorkspaceState()
    first.activeModule = "notes"
    var newest = first
    newest.activeModule = "ai"

    persistence.write(first) { _ in }
    persistence.write(newest) { _ in }
    persistence.flush()

    let loaded = PrivateFileStore().loadJSON(WorkspaceState.self, from: url)
    #expect(loaded.result.state == .loaded)
    #expect(loaded.value?.activeModule == "ai")
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
}

@Test @MainActor func retiredWorkflowsAreArchivedByteForByteAndNeverExecuted() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Lima-Workflow-Archive-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = LegacyWorkflowArchive(applicationSupport: root)
    let definition = WorkflowDefinition(name: "User definition", steps: [
        .init(commandID: "builtin.workflow.open-notes")
    ])
    let original = try JSONEncoder().encode([definition])
    try original.write(to: archive.sourceURL)
    #expect(archive.hasSavedDefinitions)

    let first = try #require(try archive.archiveIfNeeded())
    #expect(try Data(contentsOf: first) == original)
    #expect(archive.archivedFiles().count == 1)
    let second = try archive.archiveIfNeeded()
    #expect(second?.resolvingSymlinksInPath() == first.resolvingSymlinksInPath())
    #expect(archive.archivedFiles().count == 1)
    #expect(try Data(contentsOf: archive.sourceURL) == original)

    let exported = root.appendingPathComponent("export.json")
    try archive.exportLatest(to: exported)
    #expect(try Data(contentsOf: exported) == original)
    try archive.removeLegacyCopies()
    #expect(!FileManager.default.fileExists(atPath: archive.sourceURL.path))
    #expect(archive.archivedFiles().isEmpty)
    #expect(try Data(contentsOf: exported) == original)
}

@Test @MainActor func changedOrMalformedLegacyDefinitionsGetAdditionalInactiveSnapshots() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Lima-Workflow-Archive-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = LegacyWorkflowArchive(applicationSupport: root)
    let firstBytes = Data("[{\"name\":".utf8)
    try firstBytes.write(to: archive.sourceURL)
    let first = try #require(try archive.archiveIfNeeded())
    #expect(archive.hasSavedDefinitions)
    let secondBytes = Data("[{\"different\":true}]".utf8)
    try secondBytes.write(to: archive.sourceURL)
    let second = try #require(try archive.archiveIfNeeded())
    #expect(first != second)
    #expect(archive.archivedFiles().count == 2)
    #expect(try Data(contentsOf: first) == firstBytes)
    #expect(try Data(contentsOf: second) == secondBytes)
}

@Test func mainThreadProbeQueuesOnlyOneCallbackAtATime() {
    let gate = MainThreadProbeGate()
    #expect(gate.claim())
    #expect(!gate.claim())
    gate.release()
    #expect(gate.claim())
    gate.release()
}

@Test @MainActor func developerTraceOmitsSampleDetails() {
    let secret = "private-prompt-\(UUID().uuidString)"
    PerformanceMonitor.shared.record(.aiRequest, duration: 0.012, detail: secret)
    let trace = PerformanceMonitor.shared.redactedTrace()
    #expect(trace.contains(LimaPerformanceMetric.aiRequest.title))
    #expect(!trace.contains(secret))
    #expect(PerformanceMonitor.shared.samples.count <= PerformanceMonitor.maximumSamples)
}
