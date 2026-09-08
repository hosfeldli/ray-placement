import AppKit
import SwiftUI

extension AppAppearance {
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    var swiftUIColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

private enum LimaContrast {
    private static let white = NSColor(calibratedWhite: 1, alpha: 1)
    private static let black = NSColor(calibratedWhite: 0, alpha: 1)

    static func foreground(over backgrounds: [NSColor]) -> NSColor {
        let whiteContrast = backgrounds.map { contrast(white, against: $0) }.min() ?? 1
        let blackContrast = backgrounds.map { contrast(black, against: $0) }.min() ?? 1
        return whiteContrast >= blackContrast ? white : black
    }

    static func contrast(_ foreground: NSColor, against background: NSColor) -> CGFloat {
        let foregroundLuminance = luminance(foreground)
        let backgroundLuminance = luminance(background)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0.5 }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        func linearize(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
    }
}

enum AppAccentTheme: String, CaseIterable, Identifiable {
    case violet
    case blue
    case cyan
    case green
    case orange
    case rose
    case aurora
    case graphite
    case solarized
    case mint
    case crimson
    case monochrome

    var id: String { rawValue }

    nonisolated static var current: AppAccentTheme {
        let rawValue = UserDefaults.standard.string(forKey: "accentTheme") ?? ""
        return AppAccentTheme(rawValue: rawValue) ?? .violet
    }

    var title: String {
        switch self {
        case .violet: return "Violet Glass"
        case .blue: return "Deep Ocean"
        case .cyan: return "Electric Aqua"
        case .green: return "Graphite Lime"
        case .orange: return "Terminal Amber"
        case .rose: return "Prism Rose"
        case .aurora: return "Aurora Field"
        case .graphite: return "Obsidian Prism"
        case .solarized: return "Solarized Signal"
        case .mint: return "Mint Circuit"
        case .crimson: return "Crimson Pulse"
        case .monochrome: return "Monochrome High"
        }
    }

    var primary: Color { Color(nsColor: nsPrimary) }
    var secondary: Color { Color(nsColor: nsSecondary) }
    var tertiary: Color { Color(nsColor: nsTertiary) }

    // Foreground tokens are selected against the complete surface they cover.
    // This prevents light accents, such as Aurora and Monochrome, from being
    // rendered as pale text/icons on a light surface or as white text on a
    // light accent fill.
    var readablePrimary: Color { Color(nsColor: readable(nsPrimary)) }
    var readableNSPrimary: NSColor { readable(nsPrimary) }
    var readableSecondary: Color { Color(nsColor: readable(nsSecondary)) }
    var readableTertiary: Color { Color(nsColor: readable(nsTertiary)) }
    var onPrimary: Color { Color(nsColor: LimaContrast.foreground(over: [nsPrimary])) }
    var onSecondary: Color { Color(nsColor: LimaContrast.foreground(over: [nsSecondary])) }
    var onTertiary: Color { Color(nsColor: LimaContrast.foreground(over: [nsTertiary])) }
    var onGradient: Color {
        Color(nsColor: LimaContrast.foreground(over: [nsPrimary, nsSecondary]))
    }

    private func readable(_ color: NSColor) -> NSColor {
        let surface = NSColor.windowBackgroundColor
        return LimaContrast.contrast(color, against: surface) >= 4.5
            ? color
            : LimaContrast.foreground(over: [surface])
    }

    var nsPrimary: NSColor {
        switch self {
        case .violet: return NSColor(calibratedRed: 0.46, green: 0.34, blue: 0.96, alpha: 1)
        case .blue: return NSColor(calibratedRed: 0.15, green: 0.45, blue: 0.96, alpha: 1)
        case .cyan: return NSColor(calibratedRed: 0.02, green: 0.64, blue: 0.78, alpha: 1)
        case .green: return NSColor(calibratedRed: 0.12, green: 0.62, blue: 0.39, alpha: 1)
        case .orange: return NSColor(calibratedRed: 0.93, green: 0.43, blue: 0.12, alpha: 1)
        case .rose: return NSColor(calibratedRed: 0.90, green: 0.24, blue: 0.47, alpha: 1)
        case .aurora: return NSColor(calibratedRed: 0.52, green: 0.93, blue: 0.42, alpha: 1)
        case .graphite: return NSColor(calibratedRed: 0.62, green: 0.72, blue: 0.79, alpha: 1)
        case .solarized: return NSColor(calibratedRed: 0.15, green: 0.52, blue: 0.82, alpha: 1)
        case .mint: return NSColor(calibratedRed: 0.08, green: 0.72, blue: 0.55, alpha: 1)
        case .crimson: return NSColor(calibratedRed: 0.96, green: 0.22, blue: 0.38, alpha: 1)
        case .monochrome: return NSColor(calibratedRed: 0.94, green: 0.96, blue: 0.98, alpha: 1)
        }
    }

    var nsSecondary: NSColor {
        switch self {
        case .violet: return NSColor(calibratedRed: 0.68, green: 0.31, blue: 0.92, alpha: 1)
        case .blue: return NSColor(calibratedRed: 0.34, green: 0.31, blue: 0.94, alpha: 1)
        case .cyan: return NSColor(calibratedRed: 0.10, green: 0.48, blue: 0.92, alpha: 1)
        case .green: return NSColor(calibratedRed: 0.02, green: 0.60, blue: 0.65, alpha: 1)
        case .orange: return NSColor(calibratedRed: 0.91, green: 0.24, blue: 0.24, alpha: 1)
        case .rose: return NSColor(calibratedRed: 0.66, green: 0.27, blue: 0.89, alpha: 1)
        case .aurora: return NSColor(calibratedRed: 0.05, green: 0.72, blue: 0.78, alpha: 1)
        case .graphite: return NSColor(calibratedRed: 0.32, green: 0.40, blue: 0.58, alpha: 1)
        case .solarized: return NSColor(calibratedRed: 0.71, green: 0.54, blue: 0.02, alpha: 1)
        case .mint: return NSColor(calibratedRed: 0.08, green: 0.58, blue: 0.62, alpha: 1)
        case .crimson: return NSColor(calibratedRed: 0.99, green: 0.45, blue: 0.54, alpha: 1)
        case .monochrome: return NSColor(calibratedRed: 0.70, green: 0.76, blue: 0.84, alpha: 1)
        }
    }

    var nsTertiary: NSColor {
        switch self {
        case .violet: return NSColor(calibratedRed: 0.03, green: 0.65, blue: 0.80, alpha: 1)
        case .blue: return NSColor(calibratedRed: 0.00, green: 0.66, blue: 0.82, alpha: 1)
        case .cyan: return NSColor(calibratedRed: 0.18, green: 0.72, blue: 0.55, alpha: 1)
        case .green: return NSColor(calibratedRed: 0.50, green: 0.69, blue: 0.13, alpha: 1)
        case .orange: return NSColor(calibratedRed: 0.96, green: 0.66, blue: 0.10, alpha: 1)
        case .rose: return NSColor(calibratedRed: 0.95, green: 0.40, blue: 0.24, alpha: 1)
        case .aurora: return NSColor(calibratedRed: 0.77, green: 0.90, blue: 0.16, alpha: 1)
        case .graphite: return NSColor(calibratedRed: 0.38, green: 0.86, blue: 0.92, alpha: 1)
        case .solarized: return NSColor(calibratedRed: 0.16, green: 0.63, blue: 0.60, alpha: 1)
        case .mint: return NSColor(calibratedRed: 0.68, green: 0.88, blue: 0.30, alpha: 1)
        case .crimson: return NSColor(calibratedRed: 0.98, green: 0.68, blue: 0.18, alpha: 1)
        case .monochrome: return NSColor(calibratedRed: 0.42, green: 0.52, blue: 0.64, alpha: 1)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(
            colors: [primary, secondary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var ambientGradient: LinearGradient {
        LinearGradient(
            colors: [primary.opacity(0.92), secondary.opacity(0.70), tertiary.opacity(0.48)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

enum AppContrastMode: String, CaseIterable, Identifiable {
    case standard
    case high
    case maximum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .high: return "High"
        case .maximum: return "Maximum"
        }
    }

    var detail: String {
        switch self {
        case .standard: return "Balanced surfaces, borders, and accent glow."
        case .high: return "Stronger panel separation and clearer controls."
        case .maximum: return "Maximum separation for demanding visual conditions."
        }
    }

    var surfaceOpacity: Double {
        switch self { case .standard: return 0.29; case .high: return 0.34; case .maximum: return 0.39 }
    }

    var recessedOpacity: Double {
        switch self { case .standard: return 0.22; case .high: return 0.27; case .maximum: return 0.32 }
    }

    var floatingOpacity: Double {
        switch self { case .standard: return 0.35; case .high: return 0.41; case .maximum: return 0.47 }
    }

    var borderOpacity: Double {
        switch self { case .standard: return 0.16; case .high: return 0.23; case .maximum: return 0.30 }
    }

    var selectedBorderOpacity: Double {
        switch self { case .standard: return 0.52; case .high: return 0.66; case .maximum: return 0.80 }
    }

    var controlFillOpacity: Double {
        switch self { case .standard: return 0.055; case .high: return 0.075; case .maximum: return 0.10 }
    }

    var controlHoverFillOpacity: Double {
        switch self { case .standard: return 0.075; case .high: return 0.10; case .maximum: return 0.14 }
    }

    var selectedFillOpacity: Double {
        switch self { case .standard: return 0.075; case .high: return 0.10; case .maximum: return 0.14 }
    }

    var recessedFillOpacity: Double {
        switch self { case .standard: return 0.20; case .high: return 0.25; case .maximum: return 0.30 }
    }

    var editorFillOpacity: Double {
        switch self { case .standard: return 0.28; case .high: return 0.33; case .maximum: return 0.38 }
    }

    var statusFillOpacity: Double {
        switch self { case .standard: return 0.16; case .high: return 0.21; case .maximum: return 0.26 }
    }

    var separatorOpacity: Double {
        switch self { case .standard: return 0.10; case .high: return 0.16; case .maximum: return 0.22 }
    }

    var controlBorderOpacity: Double {
        switch self { case .standard: return 0.14; case .high: return 0.22; case .maximum: return 0.30 }
    }

    var controlHoverBorderOpacity: Double {
        switch self { case .standard: return 0.24; case .high: return 0.34; case .maximum: return 0.44 }
    }

    var activeControlFillOpacity: Double {
        switch self { case .standard: return 0.095; case .high: return 0.13; case .maximum: return 0.17 }
    }

    var activeControlBorderOpacity: Double {
        switch self { case .standard: return 0.34; case .high: return 0.44; case .maximum: return 0.54 }
    }

    var primaryTextOpacity: Double {
        switch self { case .standard: return 0.94; case .high: return 0.97; case .maximum: return 1.0 }
    }

    var secondaryTextOpacity: Double {
        switch self { case .standard: return 0.62; case .high: return 0.73; case .maximum: return 0.82 }
    }

    var tertiaryTextOpacity: Double {
        switch self { case .standard: return 0.42; case .high: return 0.54; case .maximum: return 0.66 }
    }

    var disabledTextOpacity: Double {
        switch self { case .standard: return 0.30; case .high: return 0.38; case .maximum: return 0.46 }
    }

    var focusFillOpacity: Double {
        switch self { case .standard: return 0.045; case .high: return 0.07; case .maximum: return 0.10 }
    }

    var focusBorderOpacity: Double {
        switch self { case .standard: return 0.34; case .high: return 0.48; case .maximum: return 0.64 }
    }

    var highContrastBorderOpacity: Double {
        switch self { case .standard: return 0.46; case .high: return 0.62; case .maximum: return 0.78 }
    }

    var highContrastFocusOpacity: Double {
        switch self { case .standard: return 0.72; case .high: return 0.86; case .maximum: return 1.0 }
    }

    var neutralOpacity: Double {
        switch self { case .standard: return 0.58; case .high: return 0.70; case .maximum: return 0.80 }
    }

    nonisolated static var current: AppContrastMode {
        let rawValue = UserDefaults.standard.string(forKey: "contrastMode") ?? ""
        return AppContrastMode(rawValue: rawValue) ?? .standard
    }
}

/// Dynamic semantic colors shared by every Lima workspace. These resolve through
/// AppKit so explicit Light, Dark, and System appearance settings remain correct
/// even when a view is hosted outside the main application window.
enum LimaColors {
    static var windowBackground: Color { Color(nsColor: .windowBackgroundColor) }
    static var sidebarBackground: Color { Color(nsColor: .controlBackgroundColor) }
    static var raisedSurface: Color { Color(nsColor: .controlBackgroundColor) }
    static var recessedSurface: Color { Color(nsColor: .textBackgroundColor) }
    static var editorBackground: Color { Color(nsColor: .textBackgroundColor) }
    static var hoverFill: Color { Color(nsColor: .selectedContentBackgroundColor).opacity(0.38) }
    static var selectedFill: Color { Color(nsColor: .selectedContentBackgroundColor).opacity(0.62) }
    static var primaryText: Color { Color(nsColor: .labelColor) }
    static var secondaryText: Color { Color(nsColor: .secondaryLabelColor) }
    static var tertiaryText: Color { Color(nsColor: .tertiaryLabelColor) }
    static var separator: Color { Color(nsColor: .separatorColor) }
    static var border: Color { Color(nsColor: .separatorColor) }
    static var focusedBorder: Color { Color(nsColor: .controlAccentColor) }
    static var accent: Color { Color(nsColor: AppAccentTheme.current.nsPrimary) }
    static var onAccent: Color { AppAccentTheme.current.onPrimary }
    static var accentSoft: Color { accent.opacity(0.12) }
    static var success: Color { Color(nsColor: .systemGreen) }
    static var warning: Color { Color(nsColor: .systemOrange) }
    static var danger: Color { Color(nsColor: .systemRed) }
    static var onDanger: Color {
        Color(nsColor: LimaContrast.foreground(over: [NSColor.systemRed]))
    }
    static var dangerSoft: Color { danger.opacity(0.11) }
    static var info: Color { Color(nsColor: .systemBlue) }
    static var shadow: Color { Color(nsColor: .shadowColor) }

    @MainActor
    static var effectiveAppearance: NSAppearance? {
        SettingsStore.shared.appearance.nsAppearance ?? NSApp?.effectiveAppearance
    }
}
