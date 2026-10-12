import AppKit
import SwiftUI

/// Opaque surfaces make hierarchy predictable under any desktop wallpaper.
enum LimaWayfinderPalette {
    enum Role {
        case canvas, navigation, content, raised, field, selection, border, strongBorder, accentInk
    }

    static func color(_ role: Role, dark: Bool, accent: NSColor, highContrast: Bool = false) -> NSColor {
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
            NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
        let canvas = dark ? rgb(0.039, 0.051, 0.088) : rgb(0.927, 0.940, 0.970)
        let content = dark ? rgb(0.063, 0.075, 0.120) : rgb(0.974, 0.980, 0.994)
        let raised = dark ? rgb(0.101, 0.117, 0.169) : rgb(1, 1, 1)
        let navigation = dark ? rgb(0.071, 0.084, 0.135) : rgb(0.943, 0.953, 0.983)
        let selection = content.blended(withFraction: dark ? 0.30 : 0.16, of: accent) ?? content
        switch role {
        case .canvas: return canvas
        case .navigation: return navigation
        case .content: return content
        case .raised: return raised
        case .field: return dark ? rgb(0.083, 0.100, 0.151) : rgb(1, 1, 1)
        case .selection: return selection
        case .border:
            if highContrast { return dark ? rgb(0.51, 0.55, 0.57) : rgb(0.42, 0.46, 0.45) }
            return dark ? rgb(0.244, 0.278, 0.369) : rgb(0.816, 0.843, 0.908)
        case .strongBorder:
            return dark ? rgb(0.43, 0.50, 0.65) : rgb(0.52, 0.58, 0.71)
        case .accentInk:
            // Use the same ink on a card, the rail, and selected rows. Shift
            // light accents darker in Light mode rather than falling to black.
            let backgrounds = [canvas, content, raised, navigation, selection]
            let target: NSColor = dark ? .white : .black
            for step in 0...20 {
                let candidate = accent.blended(withFraction: CGFloat(step) / 20, of: target) ?? target
                if backgrounds.allSatisfy({ LimaContrast.contrast(candidate, against: $0) >= 4.5 }) {
                    return candidate
                }
            }
            return target
        }
    }

    static func dynamic(_ role: Role) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let high = AppContrastMode.current != .standard
                || appearance.name == .accessibilityHighContrastAqua
                || appearance.name == .accessibilityHighContrastDarkAqua
            return color(role, dark: dark, accent: AppAccentTheme.current.nsPrimary, highContrast: high)
        })
    }
}
