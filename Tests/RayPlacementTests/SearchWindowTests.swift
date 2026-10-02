import AppKit
import Testing
@testable import RayPlacement

@Test func searchWindowKeepsMockupProportionsAsResultsChange() {
    for density in AppInterfaceDensity.allCases {
        let idle = LauncherPanelLayout.size(for: .root, density: density, resultCount: 0)
        let populated = LauncherPanelLayout.size(for: .root, density: density, resultCount: 24, query: "notes")
        #expect(idle == populated)
        #expect(idle == LauncherPanelLayout.searchSize(density: density))
        #expect(LauncherSearchDesign.showsInspector(at: idle.width))
        #expect(idle.width - LauncherSearchDesign.railWidth(for: idle.width) - LauncherSearchDesign.inspectorWidth - 80 >= 380)
        #expect(LauncherPanelLayout.size(for: .files, density: density).width == density.launcherWidth)
        #expect(LauncherPanelLayout.size(for: .terminal, density: density) == LauncherPanelLayout.terminalSize)
    }
}

@Test func searchWindowCollapsesOptionalPanesOnConstrainedScreens() {
    #expect(LauncherSearchDesign.railWidth(for: 420) == 52)
    #expect(LauncherSearchDesign.railWidth(for: 800) == 52)
    #expect(LauncherSearchDesign.railWidth(for: 1040) == 164)
    #expect(!LauncherSearchDesign.showsInspector(at: 899))
    #expect(LauncherSearchDesign.showsInspector(at: 900))
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

@Test @MainActor func searchActionMenuOwnsKeyboardSelectionAndExecution() throws {
    let model = LauncherViewModel(clipboard: .shared, scanApplications: false)
    let recorder = SearchExecutionRecorder()
    model.delegate = recorder
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
