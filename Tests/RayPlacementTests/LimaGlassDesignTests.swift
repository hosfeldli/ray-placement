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

@Test func glassStyleOptionsKeepContentAndMaterialIntensityOrdered() {
    #expect(AppGlassStyle.allCases == [.system, .subtle, .standard, .clear])
    #expect(AppGlassStyle.subtle.baseOpacity > AppGlassStyle.clear.baseOpacity)
    #expect(AppGlassStyle.subtle.materialOpacity < AppGlassStyle.standard.materialOpacity)
    #expect(AppGlassStyle.standard.materialOpacity < AppGlassStyle.clear.materialOpacity)
    #expect(AppGlassStyle.clear.backdropTintOpacity < AppGlassStyle.system.backdropTintOpacity)
    #expect(AppGlassStyle.system.backdropTintOpacity < AppGlassStyle.subtle.backdropTintOpacity)
    #expect(AppGlassStyle.system.launcherShellOpacity < AppGlassStyle.system.baseOpacity)
    #expect(AppGlassStyle.clear.launcherShellOpacity < AppGlassStyle.subtle.launcherShellOpacity)
    #expect(LimaRadius.launcherWindow <= LimaRadius.majorSurface + 2)
    #expect(LimaRadius.searchField < LimaRadius.launcherWindow)
}

@Test func glassDepthHierarchyUsesOpaqueReduceTransparencyFallbacks() {
    let depths = LimaGlassDepth.allCases
    let regularOpacities = depths.map { $0.backgroundOpacity(reduceTransparency: false) }

    #expect(regularOpacities[0] < regularOpacities[1])
    #expect(regularOpacities[1] < regularOpacities[2])
    #expect(depths.allSatisfy { $0.backgroundOpacity(reduceTransparency: true) == 1 })
}
