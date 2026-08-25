import AppKit
import SwiftUI

enum AppAccentTheme: String, CaseIterable, Identifiable {
    case violet
    case blue
    case cyan
    case green
    case orange
    case rose

    var id: String { rawValue }

    var title: String {
        switch self {
        case .violet: return "Violet"
        case .blue: return "Blue"
        case .cyan: return "Cyan"
        case .green: return "Green"
        case .orange: return "Orange"
        case .rose: return "Rose"
        }
    }

    var primary: Color { Color(nsColor: nsPrimary) }
    var secondary: Color { Color(nsColor: nsSecondary) }
    var tertiary: Color { Color(nsColor: nsTertiary) }

    var nsPrimary: NSColor {
        switch self {
        case .violet: return NSColor(calibratedRed: 0.46, green: 0.34, blue: 0.96, alpha: 1)
        case .blue: return NSColor(calibratedRed: 0.15, green: 0.45, blue: 0.96, alpha: 1)
        case .cyan: return NSColor(calibratedRed: 0.02, green: 0.64, blue: 0.78, alpha: 1)
        case .green: return NSColor(calibratedRed: 0.12, green: 0.62, blue: 0.39, alpha: 1)
        case .orange: return NSColor(calibratedRed: 0.93, green: 0.43, blue: 0.12, alpha: 1)
        case .rose: return NSColor(calibratedRed: 0.90, green: 0.24, blue: 0.47, alpha: 1)
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
            colors: [primary.opacity(0.86), secondary.opacity(0.72), tertiary.opacity(0.54)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

enum LiquidGlassDepth {
    case recessed
    case raised
    case floating
}

struct LiquidGlassBackdrop: View {
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.colorScheme) private var colorScheme
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    var body: some View {
        ZStack {
            VisualEffectView(material: material, blendingMode: blendingMode)
            Color(colorScheme == .dark ? .black : .white)
                .opacity(colorScheme == .dark ? 0.22 : 0.18)
            RadialGradient(
                colors: [settings.accentTheme.primary.opacity(colorScheme == .dark ? 0.20 : 0.13), .clear],
                center: .topLeading,
                startRadius: 4,
                endRadius: 520
            )
            RadialGradient(
                colors: [settings.accentTheme.secondary.opacity(colorScheme == .dark ? 0.14 : 0.085), .clear],
                center: .bottomTrailing,
                startRadius: 8,
                endRadius: 470
            )
            LinearGradient(
                colors: [Color.white.opacity(colorScheme == .dark ? 0.025 : 0.16), .clear, Color.black.opacity(colorScheme == .dark ? 0.10 : 0.025)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

private struct LiquidGlassSurfaceModifier: ViewModifier {
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    let depth: LiquidGlassDepth
    let selected: Bool
    let accentOpacity: Double

    private var baseOpacity: Double {
        switch (depth, colorScheme) {
        case (.recessed, .dark): return 0.12
        case (.recessed, _): return 0.27
        case (.raised, .dark): return 0.20
        case (.raised, _): return 0.46
        case (.floating, .dark): return 0.27
        case (.floating, _): return 0.56
        }
    }

    private var shadow: (color: Color, radius: CGFloat, y: CGFloat) {
        switch depth {
        case .recessed: return (.clear, 0, 0)
        case .raised: return (.black.opacity(colorScheme == .dark ? 0.18 : 0.09), 15, 7)
        case .floating: return (.black.opacity(colorScheme == .dark ? 0.30 : 0.15), 28, 14)
        }
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(Color(colorScheme == .dark ? .black : .white).opacity(baseOpacity))
                    shape.fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.055 : 0.26),
                                settings.accentTheme.primary.opacity((selected ? 0.17 : accentOpacity) * (colorScheme == .dark ? 1.0 : 0.72)),
                                settings.accentTheme.secondary.opacity(selected ? 0.105 : accentOpacity * 0.40),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.26 : 0.78),
                            settings.accentTheme.primary.opacity(selected ? 0.50 : 0.20),
                            Color.white.opacity(colorScheme == .dark ? 0.06 : 0.24),
                            Color.black.opacity(colorScheme == .dark ? 0.30 : 0.10)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: selected ? 1.2 : 0.8
                )
            }
            .shadow(color: shadow.color, radius: shadow.radius, y: shadow.y)
            .shadow(
                color: selected ? settings.accentTheme.primary.opacity(colorScheme == .dark ? 0.20 : 0.12) : .clear,
                radius: selected ? 16 : 0,
                y: selected ? 7 : 0
            )
    }
}

extension View {
    func liquidGlass(
        cornerRadius: CGFloat,
        depth: LiquidGlassDepth = .raised,
        selected: Bool = false,
        accentOpacity: Double = 0.035
    ) -> some View {
        modifier(LiquidGlassSurfaceModifier(
            cornerRadius: cornerRadius,
            depth: depth,
            selected: selected,
            accentOpacity: accentOpacity
        ))
    }
}

struct LiquidGlassIconButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    var size: CGFloat = 30
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .foregroundStyle(prominent ? Color.white : Color.primary.opacity(0.84))
            .background {
                Circle().fill(prominent ? AnyShapeStyle(SettingsStore.shared.accentTheme.gradient) : AnyShapeStyle(.ultraThinMaterial))
            }
            .overlay {
                Circle().strokeBorder(
                    Color.white.opacity(colorScheme == .dark ? 0.22 : 0.62),
                    lineWidth: 0.75
                )
            }
            .shadow(color: .black.opacity(prominent ? 0.18 : 0.09), radius: prominent ? 9 : 5, y: prominent ? 4 : 2)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

struct GlassHairline: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: [.clear, Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.10), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 0.7)
    }
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
