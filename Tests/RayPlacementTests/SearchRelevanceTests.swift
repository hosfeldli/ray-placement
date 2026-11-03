import Testing
import RayPlacementCore
@testable import RayPlacement

@Test func searchRelevanceKeepsLiteralTitleMatchesAboveHistoryAndContent() async throws {
    let definitions: [(String, String, String, Double)] = [
        ("note.body", "Meeting log", "We should open settings tomorrow", 800),
        ("builtin.settings", "Settings", "Configure Lima", 0),
        ("builtin.search-settings", "Search Settings", "Configure search", 0),
        ("note.fuzzy", "Some terrific ideas near great sunsets", "Unrelated", 800)
    ]
    let inputs = definitions.map { id, title, subtitle, bonus in
        LauncherSearchDocumentInput(item: LauncherItem(id: id, title: title, subtitle: subtitle,
            icon: .system("star"), keywords: [], action: .copyText("fixture")),
            userAliases: [], extensionAliases: [], rankingBonus: bonus)
    }
    let hits = await LauncherSearchEngine().search(.init(rawQuery: "settings", generation: 1),
        catalog: .init(revision: 1, inputs: inputs)).hits
    #expect(hits.first?.id == "builtin.settings")
    #expect(hits.firstIndex { $0.id == "builtin.search-settings" }! < hits.firstIndex { $0.id == "note.body" }!)
    #expect(!hits.contains { $0.id == "note.fuzzy" })
    #expect(SearchRelevance.score(title: "Unrelated note", fields: [],
        body: "some terrific ideas near great sunsets", query: "settings") == nil)
}

@Test func searchRelevanceUsesTheSameScaleAcrossProviders() async throws {
    let command = LauncherItem(id: "builtin.fixture", title: "Screenshot Studio", subtitle: "",
        icon: .system("camera"), keywords: ["capture"], action: .copyText("fixture"))
    let local = await LauncherSearchEngine().search(.init(rawQuery: "screenshot", generation: 1),
        catalog: .init(revision: 1, inputs: [.init(item: command, userAliases: [], extensionAliases: [], rankingBonus: 0)]))
    let content = await UniversalSearchEngine().search("screenshot", revision: 1, snapshot: .init(documents: [
        .init(id: "note:body", kind: .note, title: "Meeting", subtitle: "", searchText: "screenshot", scoreBonus: 800),
        .init(id: "note:title", kind: .note, title: "Screenshot", subtitle: "", searchText: "Screenshot")
    ]))
    #expect(content.first?.id == "note:title")
    #expect(try #require(local.hits.first?.score) > #require(content.first { $0.id == "note:body" }?.score))
    #expect(try #require(content.first?.score) > #require(local.hits.first?.score))
}

@Test func notesScopeShowsNotesBeforeTypingAndSearchesTheirBody() async {
    let engine = UniversalSearchEngine()
    let snapshot = UniversalSearchSnapshot(documents: [
        .init(id: "note:one", kind: .note, title: "Trip", subtitle: "", searchText: "Café reservation confirmation"),
        .init(id: "note:two", kind: .note, title: "Work", subtitle: "", searchText: "Planning next week"),
        .init(id: "terminal", kind: .terminal, title: "Terminal", subtitle: "", searchText: "reservation")
    ])
    let recent = await engine.search("note: ", revision: 1, snapshot: snapshot)
    #expect(recent.map(\.id) == ["note:one", "note:two"])
    let body = await engine.search("note: cafe reservation", revision: 1, snapshot: snapshot)
    #expect(body.map(\.id) == ["note:one"])
    #expect(await engine.search("note: nonexistent", revision: 1, snapshot: snapshot).isEmpty)
}

@MainActor private final class MicrophoneSearchRecorder: LauncherViewModelDelegate {
    var actions: [LauncherAction] = []
    func launcherViewModel(_ viewModel: LauncherViewModel, perform action: LauncherAction, item: LauncherItem) { actions.append(action) }
    func launcherViewModelDidReloadExtensions(_ viewModel: LauncherViewModel) {}
    func launcherViewModelDidRequestHide(_ viewModel: LauncherViewModel) {}
}

@Test @MainActor func searchQuickActionsScopeNotesAndRequestRecordingWithoutASelection() {
    let model = LauncherViewModel(clipboard: ClipboardHistoryService(fixtures: []), scanApplications: false)
    let recorder = MicrophoneSearchRecorder()
    model.delegate = recorder
    model.query = "trip"
    model.searchNotes()
    #expect(model.query == "note: trip")
    #expect(model.placeholder == "Search your notes…")
    model.query = ""
    model.startRecordingFromSearch()
    #expect(recorder.actions.count == 1)
    guard case .system(.startNoteDictation) = recorder.actions.first else {
        Issue.record("Microphone must start recording independently of selected results")
        return
    }
}
