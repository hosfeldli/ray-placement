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
        let canvas = dark ? rgb(0.078, 0.086, 0.118) : rgb(0.935, 0.947, 0.976)
        let content = dark ? rgb(0.108, 0.122, 0.163) : rgb(0.970, 0.976, 0.992)
        let raised = dark ? rgb(0.153, 0.169, 0.218) : rgb(1, 1, 1)
        let navigation = dark ? rgb(0.120, 0.133, 0.178) : rgb(0.941, 0.953, 0.984)
        let selection = content.blended(withFraction: dark ? 0.22 : 0.12, of: accent) ?? content
        switch role {
        case .canvas: return canvas
        case .navigation: return navigation
        case .content: return content
        case .raised: return raised
        case .field: return dark ? rgb(0.126, 0.141, 0.188) : rgb(1, 1, 1)
        case .selection: return selection
        case .border:
            if highContrast { return dark ? rgb(0.51, 0.55, 0.57) : rgb(0.42, 0.46, 0.45) }
            return dark ? rgb(0.265, 0.286, 0.357) : rgb(0.837, 0.859, 0.914)
        case .strongBorder:
            return dark ? rgb(0.47, 0.51, 0.61) : rgb(0.55, 0.60, 0.71)
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
