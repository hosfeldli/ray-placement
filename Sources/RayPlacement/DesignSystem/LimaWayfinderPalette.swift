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
        let canvas = dark ? rgb(0.075, 0.083, 0.087) : rgb(0.941, 0.941, 0.925)
        let content = dark ? rgb(0.108, 0.118, 0.122) : rgb(0.980, 0.980, 0.968)
        let raised = dark ? rgb(0.164, 0.176, 0.180) : rgb(1, 1, 0.993)
        let navigation = dark ? rgb(0.092, 0.103, 0.108) : rgb(0.914, 0.925, 0.916)
        let selection = content.blended(withFraction: dark ? 0.22 : 0.12, of: accent) ?? content
        switch role {
        case .canvas: return canvas
        case .navigation: return navigation
        case .content: return content
        case .raised: return raised
        case .field: return dark ? rgb(0.067, 0.075, 0.080) : rgb(1, 1, 0.997)
        case .selection: return selection
        case .border:
            if highContrast { return dark ? rgb(0.51, 0.55, 0.57) : rgb(0.42, 0.46, 0.45) }
            return dark ? rgb(0.25, 0.28, 0.29) : rgb(0.76, 0.79, 0.77)
        case .strongBorder:
            return dark ? rgb(0.46, 0.50, 0.52) : rgb(0.52, 0.56, 0.54)
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
