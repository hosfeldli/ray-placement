import AppKit
import RayPlacementCore
import Testing
@testable import RayPlacement

@Test func searchWindowIsCompactUntilTypingAndStableWhileSearching() {
    for density in AppInterfaceDensity.allCases {
        let idle = LauncherPanelLayout.size(for: .root, density: density, resultCount: 0)
        let populated = LauncherPanelLayout.size(for: .root, density: density, resultCount: 24, query: "notes")
        let emptyResults = LauncherPanelLayout.size(for: .root, density: density, resultCount: 0, query: "unlikely")
        #expect(idle == LauncherPanelLayout.idleSearchSize(density: density))
        #expect(LauncherPanelLayout.size(for: .root, density: density, query: "note: ") == idle)
        #expect(populated == emptyResults)
        #expect(populated == LauncherPanelLayout.searchSize(density: density))
        #expect(idle.height < populated.height)
        let canShowInspector = LauncherSearchDesign.canShowInspector(at: populated.width)
        #expect(canShowInspector == (density == .comfortable))
        if canShowInspector {
            #expect(populated.width - LauncherSearchDesign.inspectorWidth - 48 >= 380)
        }
        switch density {
        case .compact: #expect(idle == NSSize(width: 680, height: 138))
        case .balanced: #expect(idle == NSSize(width: 720, height: 146))
        case .comfortable: #expect(idle == NSSize(width: 760, height: 158))
        }
        #expect(LauncherPanelLayout.size(for: .files, density: density).width == density.launcherWidth)
        #expect(LauncherPanelLayout.size(for: .terminal, density: density) == LauncherPanelLayout.terminalSize)
    }
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

@Test @MainActor func idleSearchHasNoHiddenKeyboardActions() {
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
    #expect(model.results.contains { $0.id == "builtin.notes" })
    model.query = ""
    #expect(model.results.isEmpty)
    #expect(model.selectedItem == nil)
}

@Test @MainActor func searchActionMenuOwnsKeyboardSelectionAndExecution() throws {
    let model = LauncherViewModel(clipboard: .shared, scanApplications: false)
    let recorder = SearchExecutionRecorder()
    model.delegate = recorder
    model.query = "notes"
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

@Test @MainActor func searchPreviewNeverExecutesUntilExplicitAction() throws {
    let model = LauncherViewModel(clipboard: .shared, scanApplications: false)
    let recorder = SearchExecutionRecorder()
    model.delegate = recorder
    model.query = "notes"
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
