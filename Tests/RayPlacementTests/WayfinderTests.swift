import AppKit
import Testing
@testable import RayPlacement

@Test func workspaceReturnTogglesWithoutReplacingPreviousOnReselection() {
    var navigation = LimaWorkspaceNavigation()
    #expect(navigation.current == .ai)
    #expect(navigation.previous == nil)
    navigation.select(.home)
    #expect(navigation.previous == nil)
    navigation.select(.notes)
    #expect(navigation.previous == .ai)
    navigation.select(.ai)
    #expect(navigation.previous == .notes)
    navigation.select(.ai)
    #expect(navigation.previous == .notes)
    navigation.select(navigation.previous!)
    #expect(navigation.current == .notes)
    #expect(navigation.previous == .ai)
    navigation.select(.terminal)
    navigation.select(.formatter)
    #expect(navigation.previous == .terminal)
}

@Test func workspaceDestinationsHaveStableDistinctShortcuts() {
    let modules = LimaWorkspaceModule.allCases
    #expect(Set(modules.map(\.shortcutNumber)).count == modules.count)
    #expect(modules.map(\.shortcutNumber) == ["1", "2", "3", "B", "4", "5", "6", "8", "9", "T", "F"])
    #expect(LimaWorkspaceModule.context.shortcutAlias == "C")
    #expect(LimaWorkspaceModule.notes.shortcutAlias == nil)
    #expect(LimaWorkspaceModule.workspaceDestinations == [.ai, .notes, .dictation])
    #expect(LimaWorkspaceModule.toolDestinations.isEmpty)
    #expect(LimaWorkspaceModule.primaryDestinations == LimaWorkspaceModule.workspaceDestinations + LimaWorkspaceModule.toolDestinations)
    #expect(LimaWorkspaceModule.primaryDestinations == [.ai, .notes, .dictation])
    #expect(LimaWorkspaceModule.hiddenDestinations == [.home, .browser, .terminal, .context, .extensions, .clipboard, .grammar, .formatter])
    #expect(Set(LimaWorkspaceModule.primaryDestinations).isDisjoint(with: LimaWorkspaceModule.hiddenDestinations))
    #expect(modules.allSatisfy { !$0.title.isEmpty && !$0.symbol.isEmpty })
    #expect(!modules.contains(.workflows))
    var navigation = LimaWorkspaceNavigation()
    navigation.select(.workflows)
    #expect(navigation.current == .ai)
}

@Test func wayfinderAccentInkMeetsTextContrastForEveryAccentAndAppearance() {
    for theme in AppAccentTheme.allCases {
        for dark in [false, true] {
            let ink = LimaWayfinderPalette.color(.accentInk, dark: dark, accent: theme.nsPrimary)
            for role: LimaWayfinderPalette.Role in [.canvas, .navigation, .content, .raised, .field, .selection] {
                let surface = LimaWayfinderPalette.color(role, dark: dark, accent: theme.nsPrimary)
                #expect(LimaContrast.contrast(ink, against: surface) >= 4.5)
                #expect(surface.alphaComponent == 1)
            }
        }
    }
}

@Test func wayfinderHighContrastStrengthensSurfaceBoundaries() {
    for dark in [false, true] {
        let accent = AppAccentTheme.violet.nsPrimary
        let surface = LimaWayfinderPalette.color(.content, dark: dark, accent: accent)
        let standard = LimaWayfinderPalette.color(.border, dark: dark, accent: accent)
        let high = LimaWayfinderPalette.color(.border, dark: dark, accent: accent, highContrast: true)
        #expect(LimaContrast.contrast(high, against: surface) > LimaContrast.contrast(standard, against: surface))
    }
}
