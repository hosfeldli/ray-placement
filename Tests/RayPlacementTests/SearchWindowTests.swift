import AppKit
import Combine
import RayPlacementCore
import SwiftUI
import Testing
@testable import RayPlacement

@Test func searchWindowKeepsWidthAndTopAnchorWhileResultsExpand() {
    for density in AppInterfaceDensity.allCases {
        let idle = LauncherPanelLayout.size(for: .root, density: density, searchPhase: .idle)
        let active = LauncherPanelLayout.size(for: .root, density: density, searchPhase: .active)
        #expect(idle == LauncherPanelLayout.idleSearchSize(density: density))
        #expect(active == LauncherPanelLayout.searchSize(density: density))
        #expect(idle.height < active.height)
        #expect(idle.width == active.width)
        let original = NSRect(x: 100, y: 400, width: idle.width, height: idle.height)
        let expanded = LauncherPanelLayout.resizedFrame(original, to: active, anchorTop: true)
        #expect(expanded.minX == original.minX)
        #expect(expanded.maxY == original.maxY)
        #expect(LauncherSearchPhase(query: "note: ") == .idle)
        #expect(LauncherSearchPhase(query: "notes") == .active)
        let canShowInspector = LauncherSearchDesign.canShowInspector(at: active.width)
        #expect(canShowInspector == (density == .comfortable))
        if canShowInspector {
            #expect(active.width - LauncherSearchDesign.inspectorWidth - 48 >= 380)
        }
        switch density {
        case .compact: #expect(idle == NSSize(width: 720, height: 146))
        case .balanced: #expect(idle == NSSize(width: 760, height: 150))
        case .comfortable: #expect(idle == NSSize(width: 840, height: 158))
        }
        #expect(LauncherPanelLayout.size(for: .files, density: density).width == density.launcherWidth)
        #expect(LauncherPanelLayout.size(for: .terminal, density: density) == LauncherPanelLayout.terminalSize)
    }
}

@Test func searchResultsOnlyScrollWhenKeyboardSelectionLeavesViewport() {
    let viewport: CGFloat = 300
    #expect(LauncherSearchDesign.scrollAnchor(
        for: CGRect(x: 0, y: 40, width: 500, height: 64), viewportHeight: viewport
    ) == nil)
    #expect(LauncherSearchDesign.scrollAnchor(
        for: CGRect(x: 0, y: -1, width: 500, height: 64), viewportHeight: viewport
    ) == .top)
    #expect(LauncherSearchDesign.scrollAnchor(
        for: CGRect(x: 0, y: 250, width: 500, height: 64), viewportHeight: viewport
    ) == .bottom)
    #expect(LauncherSearchDesign.scrollAnchor(for: nil, viewportHeight: viewport) == .center)
}

@Test @MainActor func searchPhasePublishesOnlyIdleActiveTransitions() {
    let model = LauncherViewModel(clipboard: .shared, scanApplications: false)
    var phases: [LauncherSearchPhase] = []
    let subscription = model.$searchPhase.dropFirst().sink { phases.append($0) }
    defer { subscription.cancel() }

    #expect(model.searchPhase == .idle)
    model.query = "n"
    #expect(model.searchPhase == .active)
    model.query = "no"
    model.query = "note: "
    #expect(model.searchPhase == .idle)
    model.query = "note: n"
    model.query = "note: no"
    model.query = ""
    #expect(model.searchPhase == .idle)
    #expect(phases == [.active, .idle, .active, .idle])
}

@Test @MainActor func searchFieldKeepsNativeControlAcrossPhaseChanges() {
    let model = LauncherViewModel(clipboard: .shared, scanApplications: false)
    let view = LauncherSearchWorkspace(
        model: model,
        aiChatModel: AIChatVisualFixtures.model(for: .empty),
        openWorkspace: { _ in }, openSettings: {}, createNote: {}, dismiss: {}
    )
    let host = NSHostingView(rootView: view)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 760, height: 150),
        styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.contentView = host
    host.layoutSubtreeIfNeeded()

    func fields(in view: NSView) -> [NSTextField] {
        let current: [NSTextField]
        if let field = view as? NSTextField, field.isEditable { current = [field] }
        else { current = [] }
        return current + view.subviews.flatMap { fields(in: $0) }
    }

    func topLeft(of field: NSTextField) -> CGPoint {
        let rect = field.convert(field.bounds, to: host)
        return CGPoint(x: rect.minX, y: host.isFlipped ? rect.minY : host.bounds.maxY - rect.maxY)
    }

    let before = fields(in: host)
    #expect(before.count == 1)
    let idlePosition = before.first.map(topLeft)
    model.query = "notes"
    window.setContentSize(NSSize(width: 760, height: 520))
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    host.layoutSubtreeIfNeeded()
    let active = fields(in: host)
    #expect(active.count == 1)
    #expect(active.first === before.first)
    if let idlePosition, let activeField = active.first {
        let activePosition = topLeft(of: activeField)
        #expect(abs(activePosition.x - idlePosition.x) <= 1)
        #expect(abs(activePosition.y - idlePosition.y) <= 1)
    }

    model.query = ""
    window.setContentSize(NSSize(width: 760, height: 150))
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    host.layoutSubtreeIfNeeded()
    let idleAgain = fields(in: host)
    #expect(idleAgain.count == 1)
    #expect(idleAgain.first === before.first)
}

@Test @MainActor func queryRefreshKeepsVisibleRowsInertAndSelectionByID() async throws {
    let model = LauncherViewModel(
        clipboard: ClipboardHistoryService(fixtures: []), scanApplications: false
    )
    model.query = "notes"
    await model.waitForLocalSearchForTesting()
    let initialIndex = try #require(model.results.firstIndex { $0.id == "builtin.notes" })
    model.select(initialIndex)
    #expect(model.selectedItem?.id == "builtin.notes")

    model.query = "note"
    let retained = try #require(model.results.first { $0.id == "builtin.notes" })
    #expect(!model.isActionable(retained))
    #expect(model.selectedItem?.id == "builtin.notes")
    await model.waitForLocalSearchForTesting()
    #expect(model.selectedItem?.id == "builtin.notes")
    let refreshed = try #require(model.results.first { $0.id == "builtin.notes" })
    #expect(model.isActionable(refreshed))
}

@Test @MainActor func screenshotStudioIsAnExplicitSearchAction() async throws {
    let model = LauncherViewModel(
        clipboard: ClipboardHistoryService(fixtures: []), scanApplications: false
    )
    model.query = "screenshot"
    await model.waitForLocalSearchForTesting()
    let item = try #require(model.results.first { $0.id == "builtin.screenshot-studio" })
    #expect(LauncherSearchDesign.primaryTitle(for: item) == "Open")
    guard case .system(.openScreenshotStudio) = item.action else {
        Issue.record("Screenshot Search must open a picker, not capture directly")
        return
    }
}

@Test @MainActor func directRegionCaptureCommandsStaySeparateFromScreenshotStudio() async throws {
    let model = LauncherViewModel(
        clipboard: ClipboardHistoryService(fixtures: []), scanApplications: false
    )
    model.query = "Quick Capture Region"
    await model.waitForLocalSearchForTesting()
    let image = try #require(model.results.first { $0.id == "builtin.quick-capture-region" })
    guard case .system(.quickCaptureRegion) = image.action else {
        Issue.record("Quick Capture must start the direct region flow")
        return
    }
    model.query = "Text Reader Region"
    await model.waitForLocalSearchForTesting()
    let text = try #require(model.results.first { $0.id == "builtin.text-reader-region" })
    guard case .system(.textReaderRegion) = text.action else {
        Issue.record("Text Reader must start the local OCR region flow")
        return
    }
}

@Test @MainActor func audioOutputIsAnExplicitPickerAction() async throws {
    let model = LauncherViewModel(
        clipboard: ClipboardHistoryService(fixtures: []), scanApplications: false
    )
    model.query = "audio"
    await model.waitForLocalSearchForTesting()
    let item = try #require(model.results.first { $0.id == "builtin.audio-output" })
    #expect(LauncherSearchDesign.primaryTitle(for: item) == "Open")
    guard case .system(.openAudioOutput) = item.action else {
        Issue.record("Audio Search must open a picker, not switch devices directly")
        return
    }
}

@Test @MainActor func hiddenSearchDefersRankingUntilPresented() async {
    let model = LauncherViewModel(clipboard: ClipboardHistoryService(fixtures: []), scanApplications: false)
    model.setSearchPresented(false)
    model.query = "notes"
    #expect(model.searchPhase == .active)
    #expect(model.results.isEmpty)
    model.setContextualSelection("selected words")
    #expect(model.results.isEmpty)
    model.resetContextualSelection()
    #expect(model.results.isEmpty)

    model.setSearchPresented(true)
    await model.waitForLocalSearchForTesting()
    #expect(model.results.contains { $0.id == "builtin.notes" })

    model.setSearchPresented(false)
    #expect(model.results.isEmpty)
    model.query = "files"
    #expect(model.results.isEmpty)
}

@Test @MainActor func clipboardUpdatesRebuildOnlyClipboardSearchDocuments() async throws {
    let clipboard = ClipboardHistoryService(fixtures: [ClipboardEntry(text: "First source")])
    let model = LauncherViewModel(clipboard: clipboard, scanApplications: false)
    model.query = "notes"
    await model.waitForLocalSearchForTesting()
    let builtins = model.searchDocumentBuildCountForTesting("builtins")
    let notes = model.searchDocumentBuildCountForTesting("notes")
    let clips = model.searchDocumentBuildCountForTesting("clipboard")
    #expect(builtins == 1)
    #expect(notes == 1)
    #expect(clips == 1)

    model.setSearchPresented(false)
    let added = ClipboardEntry(text: "quartz-source-marker")
    try clipboard.replace(with: [added])
    #expect(model.searchDocumentBuildCountForTesting("clipboard") == clips)
    model.query = "quartz-source-marker"
    model.setSearchPresented(true)
    await model.waitForLocalSearchForTesting()

    #expect(model.results.contains { $0.id == "clipboard.\(added.id)" })
    #expect(model.searchDocumentBuildCountForTesting("clipboard") == clips + 1)
    #expect(model.searchDocumentBuildCountForTesting("builtins") == builtins)
    #expect(model.searchDocumentBuildCountForTesting("notes") == notes)
}

@Test @MainActor func expandedWorkspaceShortcutParticipatesInConflictChecks() {
    let manager = CommandManager.shared
    manager.validateShortcuts([])
    let assignment = manager.shortcutRegistry.assignments.first { $0.id == "builtin.expanded-workspace" }
    #expect(assignment?.title == "Open Workspace")
    #expect(assignment?.shortcut?.storageString == ShortcutSpec(string: SettingsStore.shared.expandedWorkspaceShortcut)?.storageString)
    if let shortcut = assignment?.shortcut?.storageString {
        #expect(manager.shortcutRegistry.owners(of: shortcut).contains { $0.id == "builtin.expanded-workspace" })
    }
}

@Test @MainActor func regionCaptureShortcutsParticipateInConflictChecks() {
    let manager = CommandManager.shared
    manager.validateShortcuts([])
    let assignments = manager.shortcutRegistry.assignments
    let image = assignments.first { $0.id == "builtin.quick-capture-region" }
    let text = assignments.first { $0.id == "builtin.text-reader-region" }
    #expect(image?.title == "Quick Capture Region")
    #expect(text?.title == "Text Reader Region")
    #expect(image?.shortcut?.storageString == ShortcutSpec(string: SettingsStore.shared.quickCaptureRegionShortcut)?.storageString)
    #expect(text?.shortcut?.storageString == ShortcutSpec(string: SettingsStore.shared.textReaderRegionShortcut)?.storageString)
}

@Test func searchWindowKeepsDetailsOnDemandAtCompactWidths() {
    #expect(!LauncherSearchDesign.canShowInspector(at: 779))
    #expect(LauncherSearchDesign.canShowInspector(at: 780))
    #expect(LauncherSearchDesign.inspectorWidth == 250)
}

@Test func searchResultLabelsReflectActualActions() {
    func item(_ action: LauncherAction, id: String = "test") -> LauncherItem {
        LauncherItem(id: id, title: "Example", subtitle: "Local action", icon: .system("doc.text"), keywords: [], action: action)
    }
    #expect(LauncherSearchDesign.primaryTitle(for: item(.copyText("Text"))) == "Copy")
    #expect(LauncherSearchDesign.primaryTitle(for: item(.pasteText("Text"))) == "Paste")
    #expect(LauncherSearchDesign.primaryTitle(for: item(.system(.openNotes))) == "Open")
    #expect(LauncherSearchDesign.primaryTitle(for: item(.enterMode(.files))) == "Open")
    #expect(LauncherSearchDesign.primaryTitle(for: item(.checkSelectedText)) == "Review")
    #expect(LauncherSearchDesign.title(for: item(.system(.openNotes), id: "builtin.notes")) == "Open Notes")
}

@MainActor
private final class SearchExecutionRecorder: LauncherViewModelDelegate {
    var executedIDs: [String] = []
    var executedActions: [LauncherAction] = []
    func launcherViewModel(_ viewModel: LauncherViewModel, perform action: LauncherAction, item: LauncherItem) {
        executedIDs.append(item.id)
        executedActions.append(action)
    }
    func launcherViewModelDidReloadExtensions(_ viewModel: LauncherViewModel) {}
    func launcherViewModelDidRequestHide(_ viewModel: LauncherViewModel) {}
}

@Test @MainActor func idleSearchHasNoHiddenKeyboardActions() async {
    let model = LauncherViewModel(clipboard: .shared, scanApplications: false)
    let recorder = SearchExecutionRecorder()
    model.delegate = recorder
    #expect(model.results.isEmpty)
    #expect(model.selectedItem == nil)
    model.executeSelected()
    model.executeVisibleItem(at: 0)
    model.openActionPanel()
    #expect(recorder.executedIDs.isEmpty)
    #expect(model.actionPanelItem == nil)
    model.query = "note: "
    #expect(model.results.isEmpty)
    #expect(!model.isSearching)
    model.query = "notes"
    await model.waitForLocalSearchForTesting()
    #expect(model.results.contains { $0.id == "builtin.notes" })
    model.query = ""
    #expect(model.results.isEmpty)
    #expect(model.selectedItem == nil)
}

@Test @MainActor func searchActionMenuOwnsKeyboardSelectionAndExecution() async throws {
    let model = LauncherViewModel(clipboard: .shared, scanApplications: false)
    let recorder = SearchExecutionRecorder()
    model.delegate = recorder
    model.query = "notes"
    await model.waitForLocalSearchForTesting()
    let index = try #require(model.results.firstIndex { $0.id == "builtin.notes" })
    model.select(index)
    model.openActionPanel()
    let item = try #require(model.actionPanelItem)
    let actions = model.actionPanelActions(for: item)
    let pinIndex = try #require(actions.firstIndex { $0.id == "favorite" })
    model.moveActionPanelSelection(by: pinIndex)
    #expect(model.actionPanelSelectedIndex == pinIndex)
    #expect(model.selectedIndex == index)
    #expect(recorder.executedIDs.isEmpty)
    model.executeSelectedPanelAction()
    #expect(model.actionPanelItem == nil)
    #expect(model.actionPanelSelectedIndex == 0)
    #expect(recorder.executedActions.count == 1)
    if case .toggleFavorite(let id) = recorder.executedActions.first {
        #expect(id == "builtin.notes")
    } else {
        Issue.record("Menu Return must run its selected action, not the primary result.")
    }
    model.openActionPanel()
    model.moveActionPanelSelection(by: -100)
    #expect(model.actionPanelSelectedIndex == 0)
    model.moveActionPanelSelection(by: 100)
    #expect(model.actionPanelSelectedIndex == actions.count - 1)
    model.closeActionPanel()
    model.executeSelectedPanelAction()
    #expect(recorder.executedActions.count == 1)
}

@Test @MainActor func searchPreviewNeverExecutesUntilExplicitAction() async throws {
    let model = LauncherViewModel(clipboard: .shared, scanApplications: false)
    let recorder = SearchExecutionRecorder()
    model.delegate = recorder
    model.query = "notes"
    await model.waitForLocalSearchForTesting()
    let index = try #require(model.results.firstIndex { $0.id == "builtin.notes" })
    model.select(index)
    #expect(model.selectedItem?.id == "builtin.notes")
    #expect(recorder.executedIDs.isEmpty)
    model.openActionPanel()
    #expect(model.actionPanelItem?.id == "builtin.notes")
    #expect(recorder.executedIDs.isEmpty)
    model.closeActionPanel()
    model.executeSelected()
    #expect(recorder.executedIDs == ["builtin.notes"])
}

@Test func universalSearchActorUsesImmutableSnapshotsAndRejectsOlderRevisions() async {
    let engine = UniversalSearchEngine()
    let first = UniversalSearchSnapshot(documents: [
        UniversalSearchDocument(id: "note:first", kind: .note, title: "Quartz",
                                subtitle: "First", searchText: "Quartz marker")
    ])
    let second = UniversalSearchSnapshot(documents: [
        UniversalSearchDocument(id: "note:second", kind: .note, title: "Quartz",
                                subtitle: "Second", searchText: "Quartz marker"),
        UniversalSearchDocument(id: "clipboard:third", kind: .clipboard, title: "Quartz",
                                subtitle: "Clipboard", searchText: "Quartz marker")
    ])

    let initial = await engine.search("note: quartz", revision: 1, snapshot: first)
    #expect(initial.map(\.id) == ["note:first"])
    let updated = await engine.search("note: quartz", revision: 2, snapshot: second)
    #expect(updated.map(\.id) == ["note:second"])
    let stale = await engine.search("note: quartz", revision: 1, snapshot: first)
    #expect(stale.map(\.id) == ["note:second"])
    let clipboard = await engine.search("clipboard: quartz", revision: 2, snapshot: second)
    #expect(clipboard.map(\.id) == ["clipboard:third"])
    #expect(await engine.search("file: quartz", revision: 2, snapshot: second) == [])
}

@Test func normalizedFuzzyScoringPreservesExistingRanking() {
    let candidate = "Résumé notes and commands"
    let query = "resume"
    let normalizedCandidate = candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    let normalizedQuery = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    #expect(FuzzyMatcher.score(candidate, query: query)
        == FuzzyMatcher.scoreNormalized(normalizedCandidate, query: normalizedQuery))
}
