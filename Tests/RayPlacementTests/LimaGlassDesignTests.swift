import Testing
@testable import RayPlacement

@Test func semanticQAIdentifiersAreCentralizedAndStable() {
    let stableIDs = [
        LimaQAIdentifiers.Launcher.searchField,
        LimaQAIdentifiers.Launcher.results,
        LimaQAIdentifiers.Launcher.result,
        LimaQAIdentifiers.Launcher.selectedResult,
        LimaQAIdentifiers.Workspace.sidebar,
        LimaQAIdentifiers.Workspace.searchField,
        LimaQAIdentifiers.Workspace.module(.notes),
        LimaQAIdentifiers.Workspace.module(.ai),
        LimaQAIdentifiers.Notes.list,
        LimaQAIdentifiers.Notes.search,
        LimaQAIdentifiers.Notes.editor,
        LimaQAIdentifiers.Notes.new,
        LimaQAIdentifiers.AI.composer,
        LimaQAIdentifiers.AI.send,
        LimaQAIdentifiers.AI.stop,
        LimaQAIdentifiers.AI.activity,
        LimaQAIdentifiers.Context.search,
        LimaQAIdentifiers.Context.list,
        LimaQAIdentifiers.Settings.browserBridge
    ]

    #expect(LimaQAIdentifiers.Workspace.module(.notes) == "workspace.module.notes")
    #expect(Set(stableIDs).count == stableIDs.count)
    #expect(LimaGlassDepth.allCases.count == 3)
}

@Test func glassDepthHierarchyUsesOpaqueReduceTransparencyFallbacks() {
    let depths = LimaGlassDepth.allCases
    let regularOpacities = depths.map { $0.backgroundOpacity(reduceTransparency: false) }

    #expect(regularOpacities[0] < regularOpacities[1])
    #expect(regularOpacities[1] < regularOpacities[2])
    #expect(depths.allSatisfy { $0.backgroundOpacity(reduceTransparency: true) == 1 })
}
