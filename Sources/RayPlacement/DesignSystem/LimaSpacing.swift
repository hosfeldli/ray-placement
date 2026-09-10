import AppKit
import CoreGraphics
import SwiftUI

enum LimaSpacing {
    static let xxs: CGFloat = 3
    static let xs: CGFloat = 5
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let section: CGFloat = 20
    static let toolbar: CGFloat = 44
    static let control: CGFloat = 30
    static let compactControl: CGFloat = 26
    static let listRow: CGFloat = 40
    static let compactListRow: CGFloat = 34
}

enum LimaRadius {
    // Keep geometry semantic so nested surfaces always read as a hierarchy.
    static let launcherWindow: CGFloat = 26
    static let majorSurface: CGFloat = 16
    static let searchField: CGFloat = 14
    static let card: CGFloat = 12
    static let control: CGFloat = 8
    static let compactControl: CGFloat = 6
    static let pill: CGFloat = 999

    // Compatibility aliases for existing feature views. New launcher and
    // settings work should use the semantic names above.
    static let small: CGFloat = compactControl
    static let panel: CGFloat = card
    static let window: CGFloat = majorSurface
}

enum LimaDesign {
    static let windowPadding: CGFloat = 10
    static let panelGap: CGFloat = LimaSpacing.sm
    static let sectionGap: CGFloat = LimaSpacing.md
    static let controlGap: CGFloat = LimaSpacing.xs
    static let space1: CGFloat = 4
    static let space2: CGFloat = 6
    static let space3: CGFloat = 8
    static let space4: CGFloat = 10
    static let space5: CGFloat = 12
    static let space6: CGFloat = 16
    static let space7: CGFloat = 20
    static let space8: CGFloat = 24
    static let controlHeight: CGFloat = LimaSpacing.control
    static let compactControlHeight: CGFloat = LimaSpacing.compactControl
    static let toolbarHeight: CGFloat = LimaSpacing.toolbar
    static let sectionHeaderHeight: CGFloat = 42
    static let compactCorner: CGFloat = LimaRadius.control
    static let standardCorner: CGFloat = LimaRadius.panel
    static let panelCorner: CGFloat = 16
    static let windowCorner: CGFloat = LimaRadius.window
    static let toolbarPadding: CGFloat = LimaSpacing.md
    static let statusHeight: CGFloat = 28
    static let compactStatusHeight: CGFloat = 24
    static let iconButtonSize: CGFloat = 28
    static let titleIconSize: CGFloat = 29
    static let listRowHeight: CGFloat = LimaSpacing.compactListRow
    static let editorInset: CGFloat = 10
    // AppKit and SwiftUI draw in points, while client displays commonly use a
    // 2x backing scale. A half-point standard border is one physical pixel on
    // Retina displays and remains a deliberately quiet hairline elsewhere.
    // Keeping every ordinary border at this value prevents fractional 1.2–1.6
    // pixel antialiasing from producing the inconsistent screen edges seen in
    // the previous implementation.
    static let hairlineWidth: CGFloat = 0.5
    static let borderWidth: CGFloat = 0.5
    static let focusWidth: CGFloat = 1.0
    static let tableRowHeight: CGFloat = 25
    static let tableHeaderHeight: CGFloat = 52
    static let inspectorDividerWidth: CGFloat = 5

    static var usesLightPalette: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
    }

    static var surfaceOpacity: Double { AppContrastMode.current.surfaceOpacity }
    static var recessedOpacity: Double { AppContrastMode.current.recessedOpacity }
    static var floatingOpacity: Double { AppContrastMode.current.floatingOpacity }
    static var borderOpacity: Double { AppContrastMode.current.borderOpacity }
    static var selectedBorderOpacity: Double { AppContrastMode.current.selectedBorderOpacity }

    static var windowBackground: Color { LimaColors.windowBackground }
    static var sidebarBackground: Color { LimaColors.sidebarBackground }
    static var controlFill: Color { LimaColors.raisedSurface }
    static var controlHoverFill: Color { LimaColors.hoverFill }
    static var selectedFill: Color { LimaColors.selectedFill }
    static var recessedFill: Color { LimaColors.recessedSurface }
    static var editorFill: Color { LimaColors.editorBackground }
    static var statusFill: Color { LimaColors.raisedSurface }
    static var separator: Color { LimaColors.separator.opacity(AppContrastMode.current.separatorOpacity > 0.13 ? 0.95 : 0.72) }
    static var controlBorder: Color { LimaColors.border }
    static var controlHoverBorder: Color { LimaColors.focusedBorder.opacity(0.66) }
    static var activeControlFill: Color { LimaColors.accentSoft }
    static var activeControlBorder: Color { LimaColors.focusedBorder.opacity(0.78) }
    static var primaryText: Color { LimaColors.primaryText }
    static var secondaryText: Color { LimaColors.secondaryText }
    static var tertiaryText: Color { LimaColors.tertiaryText }
    static var disabledText: Color { LimaColors.tertiaryText.opacity(0.72) }
    static let disabledOpacity: Double = 0.46
    static var focusFill: Color { LimaColors.accentSoft }
    static var focusBorder: Color { LimaColors.focusedBorder }
    static var highContrastBorder: Color { LimaColors.primaryText.opacity(0.62) }
    static var highContrastFocus: Color { LimaColors.focusedBorder }
    static var surfaceHighlight: Color { LimaColors.primaryText.opacity(0.10) }
    static var surfaceBorder: Color { LimaColors.border }
    static var success: Color { LimaColors.success }
    static var warning: Color { LimaColors.warning }
    static var danger: Color { LimaColors.danger }
    static var info: Color { LimaColors.info }
    static var neutral: Color { LimaColors.secondaryText }

    static func spring(_ response: Double = 0.24) -> Animation {
        .interactiveSpring(response: response, dampingFraction: 0.86)
    }

    static var reducedAnimation: Animation { LimaMotion.quick }
}
