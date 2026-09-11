import AppKit
import SwiftUI

@MainActor
enum LimaWindowChrome {
    static func configure(
        _ window: NSWindow,
        title: String,
        accessibilityLabel: String,
        minSize: NSSize? = nil,
        movableByBackground: Bool = true,
        shadow: Bool = true
    ) {
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = SettingsStore.shared.appearance.nsAppearance
        window.isMovableByWindowBackground = movableByBackground
        window.hasShadow = shadow
        window.setAccessibilityLabel(accessibilityLabel)
        if let minSize { window.minSize = minSize }
    }
}

@MainActor
struct NotesAppearancePalette {
    let isDark: Bool
    let background: NSColor
    let elevatedSurface: NSColor
    let recessedSurface: NSColor
    let textPrimary: NSColor
    let textSecondary: NSColor
    let textTertiary: NSColor
    let accent: NSColor
    let accentHover: NSColor
    let accentSoft: NSColor
    let focusRing: NSColor
    let separator: NSColor
    let strongSeparator: NSColor
    let taskUnchecked: NSColor
    let taskChecked: NSColor
    let taskHover: NSColor
    let taskCompletedText: NSColor
    let tableHeader: NSColor
    let tableGrid: NSColor
    let tableOuterBorder: NSColor
    let codeBackground: NSColor
    let codeText: NSColor
    let quoteBackground: NSColor
    let quoteText: NSColor
    let chartBackground: NSColor
    let chartGrid: NSColor
    let chartText: NSColor

    init(theme: NotesVisualTheme = .prism, appearance suppliedAppearance: NSAppearance? = nil) {
        let appearance = suppliedAppearance ?? NSApp?.effectiveAppearance ?? SettingsStore.shared.appearance.nsAppearance
        let resolvedAppearance = appearance ?? NSAppearance(named: .aqua)!
        isDark = resolvedAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        // AppKit's semantic colors are dynamic. Creating them outside the
        // supplied appearance can resolve them against the process/window
        // appearance before `resolved(...)` gets a chance to run, which made
        // an explicitly light table inherit dark-mode colors in screenshots.
        // Resolve every system-derived palette input under the same appearance
        // that will be used for the table renderer.
        if isDark {
            // Resolve the table's dark surfaces explicitly instead of relying
            // on AppKit control colors, which can be near-black and can also
            // vary with the active material. The editor fields use this same
            // primary text role, so this prevents black text on dark gray cells.
            background = NSColor(calibratedWhite: 0.115, alpha: 1)
            elevatedSurface = NSColor(calibratedWhite: 0.185, alpha: 1)
            recessedSurface = NSColor(calibratedWhite: 0.085, alpha: 1)
            textPrimary = NSColor(calibratedWhite: 0.94, alpha: 1)
            textSecondary = NSColor(calibratedWhite: 0.76, alpha: 1)
            textTertiary = NSColor(calibratedWhite: 0.62, alpha: 1)
        } else {
            background = Self.resolved(NSColor.textBackgroundColor, appearance: resolvedAppearance)
            elevatedSurface = Self.resolved(NSColor.controlBackgroundColor, appearance: resolvedAppearance)
            recessedSurface = Self.blend(background, with: elevatedSurface, fraction: 0.08)
            textPrimary = Self.resolved(NSColor.textColor, appearance: resolvedAppearance)
            textSecondary = Self.resolved(NSColor.secondaryLabelColor, appearance: resolvedAppearance)
            textTertiary = Self.resolved(NSColor.tertiaryLabelColor, appearance: resolvedAppearance)
        }

        let baseAccent = Self.themeAccent(theme, dark: isDark)
        accent = baseAccent
        accentHover = Self.blend(baseAccent, with: isDark ? .white : .black, fraction: isDark ? 0.12 : 0.08)
        accentSoft = baseAccent.withAlphaComponent(isDark ? 0.16 : 0.10)
        focusRing = baseAccent.withAlphaComponent(isDark ? 0.96 : 0.84)
        separator = Self.resolved(NSColor.separatorColor, appearance: resolvedAppearance)
            .withAlphaComponent(isDark ? 0.76 : 0.62)
        strongSeparator = Self.blend(separator, with: textPrimary, fraction: isDark ? 0.42 : 0.30)

        taskUnchecked = Self.blend(separator, with: textPrimary, fraction: isDark ? 0.18 : 0.10)
        taskChecked = baseAccent
        taskHover = accentSoft
        taskCompletedText = textSecondary

        // Dark mode uses deliberately stronger blends than Light mode. The
        // values are semantic, not calibrated RGBs, so native appearance and
        // accessibility settings remain the source of truth.
        tableHeader = isDark
            ? NSColor(calibratedWhite: 0.205, alpha: 1)
            : Self.blend(background, with: baseAccent, fraction: 0.035)
        tableGrid = isDark
            ? NSColor(calibratedWhite: 0.36, alpha: 1)
            : separator.withAlphaComponent(0.58)
        tableOuterBorder = isDark
            ? NSColor(calibratedWhite: 0.56, alpha: 1)
            : Self.blend(separator, with: textPrimary, fraction: 0.42)

        codeBackground = Self.blend(background, with: elevatedSurface, fraction: isDark ? 0.28 : 0.12)
        codeText = textPrimary
        quoteBackground = Self.blend(background, with: baseAccent, fraction: isDark ? 0.13 : 0.065)
        quoteText = textSecondary
        chartBackground = Self.blend(background, with: elevatedSurface, fraction: isDark ? 0.26 : 0.06)
        chartGrid = separator.withAlphaComponent(isDark ? 0.72 : 0.52)
        chartText = textPrimary
    }

    static func resolved(_ color: NSColor, appearance: NSAppearance) -> NSColor {
        var resolved = color
        appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.deviceRGB) ?? color }
        return resolved
    }

    private static func blend(_ color: NSColor, with other: NSColor, fraction: CGFloat) -> NSColor {
        color.blended(withFraction: min(max(fraction, 0), 1), of: other) ?? color
    }

    private static func themeAccent(_ theme: NotesVisualTheme, dark: Bool) -> NSColor {
        switch theme {
        case .prism:
            return NSColor(calibratedRed: dark ? 0.62 : 0.46, green: dark ? 0.42 : 0.27, blue: dark ? 0.98 : 0.84, alpha: 1)
        case .graphite:
            return NSColor(calibratedRed: dark ? 0.72 : 0.34, green: dark ? 0.78 : 0.42, blue: dark ? 0.84 : 0.52, alpha: 1)
        case .midnight:
            return NSColor(calibratedRed: dark ? 0.32 : 0.12, green: dark ? 0.60 : 0.38, blue: 1, alpha: 1)
        case .aurora:
            return NSColor(calibratedRed: dark ? 0.08 : 0.02, green: dark ? 0.76 : 0.48, blue: dark ? 0.66 : 0.36, alpha: 1)
        case .ink:
            return NSColor(calibratedRed: dark ? 0.96 : 0.72, green: dark ? 0.48 : 0.25, blue: dark ? 0.14 : 0.05, alpha: 1)
        }
    }
}

@MainActor
enum LimaAppKitDesign {
    private static var notesPalette: NotesAppearancePalette { NotesAppearancePalette(theme: SettingsStore.shared.notesVisualTheme) }

    static var windowBackground: NSColor { NSColor.windowBackgroundColor.withAlphaComponent(0.94) }
    static var editorBackground: NSColor { notesPalette.background }
    static var recessedBackground: NSColor { notesPalette.recessedSurface }
    static var surfaceBackground: NSColor { notesPalette.elevatedSurface }
    static var separator: NSColor { notesPalette.separator }
    static var strongSeparator: NSColor { notesPalette.strongSeparator }
    static var accent: NSColor { notesPalette.accent }
    static var accentSoft: NSColor { notesPalette.accentSoft }
    static var focus: NSColor { notesPalette.focusRing }
    static var taskHover: NSColor { notesPalette.taskHover }
    static var tableHeaderBackground: NSColor { notesPalette.tableHeader }
    static var tableGrid: NSColor { notesPalette.tableGrid }
    static var tableOuterBorder: NSColor { notesPalette.tableOuterBorder }
    static var taskUnchecked: NSColor { notesPalette.taskUnchecked }
    static var taskChecked: NSColor { notesPalette.taskChecked }
    static var taskCompletedText: NSColor { notesPalette.taskCompletedText }
    static var codeBackground: NSColor { notesPalette.codeBackground }
    static var quoteBackground: NSColor { notesPalette.quoteBackground }
    static var chartBackground: NSColor { notesPalette.chartBackground }
    static var chartGrid: NSColor { notesPalette.chartGrid }
    static var chartText: NSColor { notesPalette.chartText }
    static var primaryText: NSColor { notesPalette.textPrimary }
    static var secondaryText: NSColor { notesPalette.textSecondary }
    static var tertiaryText: NSColor { notesPalette.textTertiary }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}
