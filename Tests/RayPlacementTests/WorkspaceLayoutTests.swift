import CoreGraphics
import RayPlacementCore
import Testing
@testable import RayPlacement

@Test func workspaceSizeClassUsesSharedBoundariesAndMetrics() {
    #expect(LimaWorkspaceSizeClass.classify(width: 519.9) == .compact)
    #expect(LimaWorkspaceSizeClass.classify(width: 520) == .regular)
    #expect(LimaWorkspaceSizeClass.classify(width: 760) == .regular)
    #expect(LimaWorkspaceSizeClass.classify(width: 760.1) == .expanded)

    #expect(LimaWorkspaceSizeClass.compact.moduleRailWidth == 60)
    #expect(LimaWorkspaceSizeClass.regular.moduleRailWidth == 60)
    #expect(LimaWorkspaceSizeClass.expanded.moduleRailWidth == 208)
    #expect(LimaWorkspaceSizeClass.compact.contextSidebarWidth == nil)
    #expect(LimaWorkspaceSizeClass.regular.contextSidebarWidth == 188)
    #expect(LimaWorkspaceSizeClass.expanded.contextSidebarWidth == 232)
}

@Test func workspaceChromeProtectsBrowserBeforeSidecarAndKeepsResizeBounded() {
    let narrow = LimaWorkspaceChromeLayout.resolve(width: 1_119, sidecarRequested: true,
                                                   isDocked: false, preferredSidecarWidth: 380)
    #expect(!narrow.showsSidecar)
    let threshold = LimaWorkspaceChromeLayout.resolve(width: 1_120, sidecarRequested: true,
                                                      isDocked: false, preferredSidecarWidth: 480)
    #expect(threshold.showsSidecar)
    #expect(threshold.collapsesRail)
    #expect(threshold.sidecarWidth <= 356)
    let enlargedRail = LimaWorkspaceChromeLayout.resolve(width: 1_380, sidecarRequested: true,
                                                         isDocked: false, preferredSidecarWidth: 480)
    #expect(!enlargedRail.collapsesRail)
    #expect(enlargedRail.sidecarWidth <= 360)
    #expect(1_380 - 316 - enlargedRail.sidecarWidth - 54 >= 650)
    let wide = LimaWorkspaceChromeLayout.resolve(width: 1_600, sidecarRequested: true,
                                                 isDocked: false, preferredSidecarWidth: 420)
    #expect(wide.showsSidecar)
    #expect(!wide.collapsesRail)
    #expect(wide.sidecarWidth == 420)
    #expect(!LimaWorkspaceChromeLayout.resolve(width: 1_600, sidecarRequested: true,
                                               isDocked: true, preferredSidecarWidth: 380).showsSidecar)
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
