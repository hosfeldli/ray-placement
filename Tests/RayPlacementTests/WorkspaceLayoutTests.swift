import CoreGraphics
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
