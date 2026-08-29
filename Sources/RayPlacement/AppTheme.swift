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
            colors: [primary.opacity(0.92), secondary.opacity(0.70), tertiary.opacity(0.48)],
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

/// A compact, asymmetric chamfer used throughout RayPlacement. The uneven cuts
/// keep the interface crystalline without turning every control into a capsule.
struct PrismaticPanelShape: InsettableShape {
    var cut: CGFloat = 7
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let c = min(max(2, cut - insetAmount), min(r.width, r.height) * 0.22)
        var path = Path()
        path.move(to: CGPoint(x: r.minX + c, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - c * 0.45, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY + c * 0.45))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        path.addLine(to: CGPoint(x: r.maxX - c, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + c * 0.35, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY - c * 0.35))
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> PrismaticPanelShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

struct LiquidGlassBackdrop: View {
    @ObservedObject private var settings = SettingsStore.shared
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    var body: some View {
        ZStack {
            VisualEffectView(material: material, blendingMode: blendingMode)
            Color.black.opacity(0.58)
            PrismaticAmbientLayer(theme: settings.accentTheme)
            RadialGradient(
                colors: [settings.accentTheme.primary.opacity(0.18), .clear],
                center: .init(x: 0.12, y: 0.02),
                startRadius: 4,
                endRadius: 600
            )
            RadialGradient(
                colors: [settings.accentTheme.secondary.opacity(0.10), .clear],
                center: .init(x: 0.88, y: 0.96),
                startRadius: 8,
                endRadius: 540
            )
            LinearGradient(
                colors: [Color.white.opacity(0.060), .clear, settings.accentTheme.tertiary.opacity(0.038), Color.black.opacity(0.30)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

/// Two oversized, low-opacity planes create movement behind windows without a
/// timer, canvas, blur, or per-frame state update. Core Animation interpolates
/// the transforms and stops them entirely when Reduce Motion is enabled.
private struct PrismaticAmbientLayer: View {
    let theme: AppAccentTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drifting = false

    private var canAnimate: Bool {
        !reduceMotion && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        GeometryReader { proxy in
            let wide = max(proxy.size.width * 0.72, 420)
            let tall = max(proxy.size.height * 0.66, 310)
            ZStack {
                PrismaticPanelShape(cut: 74)
                    .fill(
                        LinearGradient(
                            colors: [theme.primary.opacity(0.17), theme.secondary.opacity(0.065), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: wide, height: tall)
                    .rotationEffect(.degrees(drifting ? 12 : -6))
                    .offset(
                        x: drifting ? proxy.size.width * 0.17 : -proxy.size.width * 0.09,
                        y: drifting ? -proxy.size.height * 0.12 : proxy.size.height * 0.08
                    )

                PrismaticPanelShape(cut: 62)
                    .fill(
                        LinearGradient(
                            colors: [.clear, theme.tertiary.opacity(0.11), theme.primary.opacity(0.048)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: wide * 0.76, height: tall * 0.72)
                    .rotationEffect(.degrees(drifting ? -15 : 9))
                    .offset(
                        x: drifting ? -proxy.size.width * 0.15 : proxy.size.width * 0.14,
                        y: drifting ? proxy.size.height * 0.13 : -proxy.size.height * 0.09
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onAppear {
                guard canAnimate else { return }
                withAnimation(.easeInOut(duration: 22).repeatForever(autoreverses: true)) {
                    drifting = true
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct LiquidGlassSurfaceModifier: ViewModifier {
    @ObservedObject private var settings = SettingsStore.shared
    let cornerRadius: CGFloat
    let depth: LiquidGlassDepth
    let selected: Bool
    let accentOpacity: Double

    private var baseOpacity: Double {
        switch depth {
        case .recessed: return 0.38
        case .raised: return 0.43
        case .floating: return 0.49
        }
    }

    private var shadow: (color: Color, radius: CGFloat, y: CGFloat) {
        switch depth {
        case .recessed: return (.clear, 0, 0)
        case .raised: return (.black.opacity(0.28), 18, 8)
        case .floating: return (.black.opacity(0.42), 32, 15)
        }
    }

    func body(content: Content) -> some View {
        let shape = PrismaticPanelShape(cut: min(12, max(5, cornerRadius * 0.56)))
        content
            .background {
                ZStack {
                    shape.fill(.thinMaterial)
                    shape.fill(Color.black.opacity(baseOpacity))
                    shape.fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.085), settings.accentTheme.primary.opacity(selected ? 0.24 : accentOpacity), settings.accentTheme.tertiary.opacity(selected ? 0.13 : accentOpacity * 0.34), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    shape.fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                Color.white.opacity(selected ? 0.15 : 0.075),
                                settings.accentTheme.tertiary.opacity(selected ? 0.10 : 0.038),
                                .clear
                            ],
                            startPoint: .bottomLeading,
                            endPoint: .topTrailing
                        )
                    )
                    .blendMode(.screen)
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.24),
                            settings.accentTheme.primary.opacity(selected ? 0.62 : 0.24),
                            Color.white.opacity(0.085),
                            Color.black.opacity(0.38)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: selected ? 1.1 : 0.7
                )
            }
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(LinearGradient(
                        colors: [.clear, settings.accentTheme.tertiary.opacity(selected ? 0.80 : 0.28), settings.accentTheme.primary.opacity(selected ? 0.88 : 0.34), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .frame(width: selected ? 2 : 1)
                    .padding(.vertical, min(10, cornerRadius * 0.55))
            }
            .overlay(alignment: .topLeading) {
                LinearGradient(
                    colors: [Color.white.opacity(selected ? 0.33 : 0.16), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 0.8)
                .padding(.leading, min(18, cornerRadius * 1.1))
                .padding(.trailing, cornerRadius * 1.8)
            }
            .overlay {
                shape.strokeBorder(
                    Color.black.opacity(0.34),
                    lineWidth: 0.45
                )
                .padding(1.05)
            }
            .shadow(color: shadow.color, radius: shadow.radius * 0.62, y: shadow.y * 0.55)
            .shadow(
                color: selected ? settings.accentTheme.primary.opacity(0.24) : .clear,
                radius: selected ? 12 : 0,
                y: selected ? 5 : 0
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
    var size: CGFloat = 30
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .foregroundStyle(prominent ? Color.white : Color.primary.opacity(0.84))
            .background {
                PrismaticPanelShape(cut: max(4, size * 0.18))
                    .fill(prominent ? AnyShapeStyle(SettingsStore.shared.accentTheme.gradient) : AnyShapeStyle(Color.black.opacity(0.30)))
                PrismaticPanelShape(cut: max(4, size * 0.18))
                    .fill(prominent ? AnyShapeStyle(.clear) : AnyShapeStyle(.ultraThinMaterial))
            }
            .overlay {
                PrismaticPanelShape(cut: max(4, size * 0.18)).strokeBorder(
                    Color.white.opacity(0.27),
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
    var body: some View {
        LinearGradient(
            colors: [.clear, Color.white.opacity(0.18), .clear],
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
