import CoreGraphics
import RayPlacementCore
import Testing
@testable import RayPlacement

@Test func workspaceSizeClassUsesSharedBoundariesAndMetrics() {
    #expect(LimaWorkspaceSizeClass.classify(width: 519.9) == .compact)
    #expect(LimaWorkspaceSizeClass.classify(width: 520) == .regular)
    #expect(LimaWorkspaceSizeClass.classify(width: 760) == .regular)
    #expect(LimaWorkspaceSizeClass.classify(width: 760.1) == .expanded)

    #expect(LimaWorkspaceSizeClass.compact.moduleRailWidth == 44)
    #expect(LimaWorkspaceSizeClass.regular.moduleRailWidth == 46)
    #expect(LimaWorkspaceSizeClass.expanded.moduleRailWidth == 184)
    #expect(LimaWorkspaceSizeClass.compact.contextSidebarWidth == nil)
    #expect(LimaWorkspaceSizeClass.regular.contextSidebarWidth == 188)
    #expect(LimaWorkspaceSizeClass.expanded.contextSidebarWidth == 232)
}

@Test @MainActor func notesFilteringRunsOnlyForActiveModuleAndDiscardsStaleQueries() async {
    let pinned = MarkdownNote(title: "Plan", content: String(repeating: "preface ", count: 100) + "quartzmarker", isPinned: true)
    let regular = MarkdownNote(title: "Other", content: "ordinary content")
    let model = NotesWorkspacePresentationModel()
    model.setNotes([pinned, regular])
    model.setQuery("quartzmarker")
    await model.waitForFilteringForTesting()
    #expect(model.filteredNotes.isEmpty)

    model.setActive(true)
    await model.waitForFilteringForTesting()
    #expect(model.filteredNotes.map(\.id) == [pinned.id])
    model.setQuery("no-match")
    model.setQuery("quartzmarker")
    await model.waitForFilteringForTesting()
    #expect(model.filteredNotes.map(\.id) == [pinned.id])

    model.setFilter(.favorites)
    await model.waitForFilteringForTesting()
    #expect(model.filteredNotes.isEmpty)
    model.setFilter(.pinned)
    await model.waitForFilteringForTesting()
    #expect(model.filteredNotes.map(\.id) == [pinned.id])

    model.setActive(false)
    model.setNotes([regular])
    #expect(model.filteredNotes.map(\.id) == [pinned.id])
    model.setActive(true)
    await model.waitForFilteringForTesting()
    #expect(model.filteredNotes.isEmpty)
}
