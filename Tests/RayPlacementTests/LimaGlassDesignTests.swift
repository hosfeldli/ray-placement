import Foundation
import Testing
import RayPlacementCore
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
        LimaQAIdentifiers.Settings.browser
    ]

    #expect(LimaQAIdentifiers.Workspace.module(.notes) == "workspace.module.notes")
    #expect(Set(stableIDs).count == stableIDs.count)
    #expect(LimaGlassDepth.allCases.count == 3)
}

@Test func glassStyleOptionsKeepContentAndMaterialIntensityOrdered() {
    #expect(AppGlassStyle.allCases == [.system, .subtle, .standard, .clear, .prism, .deepPrism])
    #expect(AppGlassStyle.subtle.baseOpacity > AppGlassStyle.clear.baseOpacity)
    #expect(AppGlassStyle.subtle.materialOpacity < AppGlassStyle.standard.materialOpacity)
    #expect(AppGlassStyle.standard.materialOpacity < AppGlassStyle.clear.materialOpacity)
    #expect(AppGlassStyle.clear.backdropTintOpacity < AppGlassStyle.system.backdropTintOpacity)
    #expect(AppGlassStyle.system.backdropTintOpacity < AppGlassStyle.subtle.backdropTintOpacity)
    #expect(AppGlassStyle.system.launcherShellOpacity < AppGlassStyle.system.baseOpacity)
    #expect(AppGlassStyle.clear.launcherShellOpacity < AppGlassStyle.subtle.launcherShellOpacity)
    #expect(AppGlassStyle.prism.baseOpacity < AppGlassStyle.standard.baseOpacity)
    #expect(AppGlassStyle.prism.materialOpacity > AppGlassStyle.standard.materialOpacity)
    #expect(AppGlassStyle.prism.prismaticEdgeOpacity >= 0.25)
    #expect(AppGlassStyle.deepPrism.prismaticEdgeOpacity > AppGlassStyle.prism.prismaticEdgeOpacity)
    #expect(AppGlassStyle.clear.prismaticEdgeOpacity == 0)
    #expect(LimaGlassRegion.toolbar.prismStrength < LimaGlassRegion.sidebar.prismStrength)
    #expect(LimaGlassRegion.sidebar.prismStrength < LimaGlassRegion.composer.prismStrength)
    #expect(LimaGlassRegion.hud.prismStrength > LimaGlassRegion.sidebar.prismStrength)
    #expect(AppGlassStyle.deepPrism.title == "Deep Prism")
    #expect(LimaRadius.launcherWindow <= LimaRadius.majorSurface + 2)
    #expect(LimaRadius.searchField < LimaRadius.launcherWindow)
}

@Test func workspaceConfigurationCanHideRegroupAndReorderEveryModule() {
    var configuration = WorkspaceConfiguration.defaultConfiguration
    #expect(configuration.workspaceModules == [.ai, .notes, .dictation])
    #expect(configuration.toolModules.isEmpty)
    #expect(configuration.hiddenModules == [.browser, .grammar, .extensions, .clipboard, .terminal, .formatter])

    configuration.move(.notes, in: .workspace, by: -2)
    #expect(configuration.workspaceModules == [.notes, .ai, .dictation])
    configuration.setSection(.workspace, for: .grammar)
    #expect(configuration.workspaceModules.last == .grammar)
    #expect(!configuration.hiddenModules.contains(.grammar))
    configuration.setSection(.hidden, for: .notes)
    #expect(configuration.hiddenModules.contains(.notes))
    #expect(Set(configuration.workspaceModules + configuration.toolModules + configuration.hiddenModules) == Set(LimaWorkspaceModule.userFacingModules))
}

@Test func workspaceConfigurationMigratesLegacyGroupsAndKeepsPresentationDefaults() throws {
    let legacy = Data(#"{"workspaceModules":["home","notes"],"toolModules":["terminal"]}"#.utf8)
    let layout = try JSONDecoder().decode(WorkspaceConfiguration.self, from: legacy)
    #expect(layout.workspaceModules == [.home, .notes])
    #expect(layout.toolModules == [.terminal, .grammar])
    #expect(layout.sections.count == 2)
    #expect(layout.railPresentation == .adaptive)
    #expect(layout.railWidth == .standard)
    #expect(layout.startupModule == .ai)
    #expect(try JSONDecoder().decode(WorkspaceConfiguration.self, from: JSONEncoder().encode(layout)) == layout)

    // Once written in the new format, deliberately hiding Grammar must stick.
    var customized = layout
    customized.hideModule(.grammar)
    let restored = try JSONDecoder().decode(WorkspaceConfiguration.self, from: JSONEncoder().encode(customized))
    #expect(restored.sectionID(for: .grammar) == nil)
}

@Test func workspaceStockRailMigratesWithoutOverwritingCustomization() throws {
    var previous = WorkspaceConfiguration(sections: [
        WorkspaceSectionConfiguration(id: WorkspaceSectionConfiguration.workspaceID, name: "Workspace",
                                      modules: [.home, .notes, .ai, .browser, .context]),
        WorkspaceSectionConfiguration(id: WorkspaceSectionConfiguration.toolsID, name: "Tools",
                                      modules: [.clipboard, .workflows, .extensions, .terminal, .grammar])
    ])
    previous.railWidth = .wide
    previous.setShortcutKey("Q", for: .ai)
    func previousVersion(_ layout: WorkspaceConfiguration) throws -> Data {
        let data = try JSONEncoder().encode(layout)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["layoutVersion"] = 2
        return try JSONSerialization.data(withJSONObject: object)
    }
    let migrated = try JSONDecoder().decode(WorkspaceConfiguration.self, from: previousVersion(previous))
    #expect(migrated.sections == WorkspaceConfiguration.defaultConfiguration.sections)
    #expect(migrated.railWidth == .wide)
    #expect(migrated.shortcutKey(for: .ai) == "Q")

    previous.sections[0].name = "My Work"
    let customized = try JSONDecoder().decode(WorkspaceConfiguration.self, from: previousVersion(previous))
    #expect(customized.sections == previous.sections)
}

@Test func retiredWorkflowLayoutEntriesAndShortcutsAreDroppedSafely() throws {
    let legacy = Data(#"{"workspaceModules":["workflows","home"],"toolModules":["extensions"],"startupModule":"workflows","shortcutOverrides":{"workflows":"7"}}"#.utf8)
    let layout = try JSONDecoder().decode(WorkspaceConfiguration.self, from: legacy)
    #expect(!layout.visibleModules.contains(.workflows))
    #expect(!layout.hiddenModules.contains(.workflows))
    #expect(layout.startupModule == .ai)
    #expect(layout.shortcutOverrides["workflows"] == nil)
}

@Test func workspaceCustomSectionsOwnOrderingVisibilityAndStartup() throws {
    var layout = WorkspaceConfiguration.defaultConfiguration
    let addedSectionID = layout.addSection(named: "Writing")
    let writingID = try #require(addedSectionID)
    layout.moveModule(.notes, to: writingID)
    layout.moveModule(.grammar, to: writingID)
    layout.moveModule(.ai, to: writingID)
    layout.moveModule(.ai, in: writingID, by: -2)
    layout.moveSection(writingID, by: -2)
    layout.startupModule = .ai
    layout.railPresentation = .iconsAndLabels
    layout.railWidth = .wide
    layout.showsKeyboardShortcuts = true
    #expect(layout.sections.first?.id == writingID)
    #expect(layout.sections.first?.modules == [.ai, .notes, .grammar])
    #expect(!layout.hiddenModules.contains(.grammar))
    #expect(try JSONDecoder().decode(WorkspaceConfiguration.self, from: JSONEncoder().encode(layout)) == layout)

    layout.hideModule(.ai)
    #expect(layout.startupModule != .ai)
    layout.deleteSection(writingID)
    #expect(layout.sectionID(for: .notes) != nil)
    #expect(layout.sectionID(for: .grammar) != nil)
}

@Test func workspaceLayoutNormalizationRemovesDuplicateModulesAndSections() {
    let id = WorkspaceSectionConfiguration.workspaceID
    let layout = WorkspaceConfiguration(sections: [
        WorkspaceSectionConfiguration(id: id, name: "", modules: [.home, .notes, .notes]),
        WorkspaceSectionConfiguration(id: id, name: "Duplicate", modules: [.ai]),
        WorkspaceSectionConfiguration(name: "Tools", modules: [.home, .terminal])
    ], startupModule: .ai)
    #expect(layout.sections.count == 2)
    #expect(layout.visibleModules == [.home, .notes, .terminal])
    #expect(layout.startupModule == .ai)
    #expect(layout.sections.first?.name == "Section")
}

@Test func workspaceProfilesDecodeLegacySnapshotsAndCarryNewLayout() throws {
    let legacy = WorkspaceProfile(name: "Legacy")
    let encoded = try JSONEncoder().encode(legacy)
    var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    json.removeValue(forKey: "workspaceConfigurationData")
    let oldData = try JSONSerialization.data(withJSONObject: json)
    #expect(try JSONDecoder().decode(WorkspaceProfile.self, from: oldData).workspaceConfigurationData == nil)

    let layoutData = try JSONEncoder().encode(WorkspaceConfiguration.defaultConfiguration)
    let profile = WorkspaceProfile(name: "Writing", workspaceConfigurationData: layoutData)
    let restored = try JSONDecoder().decode(WorkspaceProfile.self, from: JSONEncoder().encode(profile))
    #expect(restored.workspaceConfigurationData == layoutData)
}

@Test func homeLayoutDefaultsPreserveExistingWorkspaceBehavior() throws {
    let home = HomeWorkspaceConfiguration.defaultConfiguration
    #expect(home.sectionOrder == [.continueWork, .recent, .quickActions, .pinned, .activeTasks])
    #expect(home.isVisible(.continueWork))
    #expect(home.isVisible(.recent))
    #expect(home.isVisible(.quickActions))
    #expect(home.isVisible(.pinned))
    #expect(!home.isVisible(.activeTasks))
    #expect(home.showsRecentNotes && home.showsRecentAI)

    let legacy = Data(#"{"workspaceModules":["home","notes"],"toolModules":["terminal"]}"#.utf8)
    let layout = try JSONDecoder().decode(WorkspaceConfiguration.self, from: legacy)
    #expect(layout.home == home)
}

@Test func homeLayoutReordersVisibilityAndPersistsInWorkspaceSnapshot() throws {
    var layout = WorkspaceConfiguration.defaultConfiguration
    layout.home.move(.activeTasks, by: -4)
    layout.home.setVisible(true, for: .activeTasks)
    layout.home.setVisible(false, for: .continueWork)
    layout.home.showsRecentNotes = false
    #expect(layout.home.sectionOrder.first == .activeTasks)
    #expect(layout.home.isVisible(.activeTasks))
    #expect(!layout.home.isVisible(.continueWork))
    #expect(!layout.home.showsRecentNotes && layout.home.showsRecentAI)
    #expect(try JSONDecoder().decode(WorkspaceConfiguration.self, from: JSONEncoder().encode(layout)) == layout)
}

@Test func homeLayoutNormalizationRestoresMissingSectionsWithoutDuplicating() {
    let home = HomeWorkspaceConfiguration(
        sectionOrder: [.recent, .recent],
        hiddenSections: [.pinned, .pinned],
        showsRecentNotes: false
    )
    #expect(home.sectionOrder.count == HomeWorkspaceSection.allCases.count)
    #expect(home.sectionOrder.first == .recent)
    #expect(home.hiddenSections == [.pinned])
    #expect(home.normalized == home)
}

@Test func workspaceShortcutCustomizationSwapsCollisionsAndPersists() throws {
    var layout = WorkspaceConfiguration.defaultConfiguration
    #expect(layout.shortcutKey(for: .home) == "1")
    #expect(layout.shortcutKey(for: .notes) == "2")
    #expect(layout.shortcutAlias(for: .context) == "C")

    layout.setShortcutKey("2", for: .home)
    #expect(layout.shortcutKey(for: .home) == "2")
    #expect(layout.shortcutKey(for: .notes) == "1")
    layout.setShortcutKey("c", for: .terminal)
    #expect(layout.shortcutKey(for: .terminal) == "C")
    #expect(layout.shortcutAlias(for: .context) == nil)
    #expect(Set(LimaWorkspaceModule.allCases.map { layout.shortcutKey(for: $0) }).count == LimaWorkspaceModule.allCases.count)
    #expect(try JSONDecoder().decode(WorkspaceConfiguration.self, from: JSONEncoder().encode(layout)) == layout)

    layout.setShortcutKey("0", for: .home)
    #expect(layout.shortcutKey(for: .home) == "2")
}

@Test func workspaceShortcutNormalizationRejectsInvalidSavedOverrides() {
    let layout = WorkspaceConfiguration(
        workspaceModules: [.home, .notes],
        toolModules: [.terminal],
        shortcutOverrides: ["home": "0", "notes": "not a key", "unknown": "Z"]
    )
    #expect(layout.shortcutOverrides.isEmpty)
    #expect(layout.shortcutKey(for: .home) == "1")
    #expect(layout.shortcutKey(for: .notes) == "2")
}

@Test func glassDepthHierarchyUsesOpaqueReduceTransparencyFallbacks() {
    let depths = LimaGlassDepth.allCases
    let regularOpacities = depths.map { $0.backgroundOpacity(reduceTransparency: false) }

    #expect(regularOpacities[0] < regularOpacities[1])
    #expect(regularOpacities[1] < regularOpacities[2])
    #expect(depths.allSatisfy { $0.backgroundOpacity(reduceTransparency: true) == 1 })
}
