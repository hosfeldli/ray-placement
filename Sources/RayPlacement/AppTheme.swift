import AppKit
import SwiftUI

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

enum LimaDesign {
    // Shared geometry. Keeping these values here prevents each workspace from
    // developing its own spacing and control language.
    static let windowPadding: CGFloat = 10
    static let panelGap: CGFloat = 8
    static let sectionGap: CGFloat = 12
    static let controlGap: CGFloat = 6
    static let space1: CGFloat = 4
    static let space2: CGFloat = 6
    static let space3: CGFloat = 8
    static let space4: CGFloat = 10
    static let space5: CGFloat = 12
    static let space6: CGFloat = 16
    static let space7: CGFloat = 20
    static let space8: CGFloat = 24
    static let controlHeight: CGFloat = 30
    static let compactControlHeight: CGFloat = 26
    static let toolbarHeight: CGFloat = 44
    static let sectionHeaderHeight: CGFloat = 42
    static let compactCorner: CGFloat = 8
    static let standardCorner: CGFloat = 12
    static let panelCorner: CGFloat = 16
    static let windowCorner: CGFloat = 18
    static let toolbarPadding: CGFloat = 12
    static let statusHeight: CGFloat = 28
    static let compactStatusHeight: CGFloat = 24
    static let iconButtonSize: CGFloat = 28
    static let titleIconSize: CGFloat = 29
    static let listRowHeight: CGFloat = 34
    static let editorInset: CGFloat = 10
    static let hairlineWidth: CGFloat = 0.7
    static let borderWidth: CGFloat = 0.6
    static let focusWidth: CGFloat = 1.1
    static let tableRowHeight: CGFloat = 25
    static let tableHeaderHeight: CGFloat = 52
    static let inspectorDividerWidth: CGFloat = 5

    // Shared contrast and depth. Surfaces should separate by tone and border,
    // not by a stack of competing gradients and shadows.
    static var surfaceOpacity: Double { AppContrastMode.current.surfaceOpacity }
    static var recessedOpacity: Double { AppContrastMode.current.recessedOpacity }
    static var floatingOpacity: Double { AppContrastMode.current.floatingOpacity }
    static var borderOpacity: Double { AppContrastMode.current.borderOpacity }
    static var selectedBorderOpacity: Double { AppContrastMode.current.selectedBorderOpacity }

    // Shared semantic surfaces. Use these for controls and editor regions
    // instead of inventing another local opacity for each workspace.
    static var controlFill: Color { Color.white.opacity(AppContrastMode.current.controlFillOpacity) }
    static var controlHoverFill: Color { Color.white.opacity(AppContrastMode.current.controlHoverFillOpacity) }
    static var selectedFill: Color { Color.white.opacity(AppContrastMode.current.selectedFillOpacity) }
    static var recessedFill: Color { Color.black.opacity(AppContrastMode.current.recessedFillOpacity) }
    static var editorFill: Color { Color.black.opacity(AppContrastMode.current.editorFillOpacity) }
    static var statusFill: Color { Color.black.opacity(AppContrastMode.current.statusFillOpacity) }
    static var separator: Color { Color.white.opacity(AppContrastMode.current.separatorOpacity) }
    static var controlBorder: Color { Color.white.opacity(AppContrastMode.current.controlBorderOpacity) }
    static var controlHoverBorder: Color { Color.white.opacity(AppContrastMode.current.controlHoverBorderOpacity) }
    static var activeControlFill: Color { Color.white.opacity(AppContrastMode.current.activeControlFillOpacity) }
    static var activeControlBorder: Color { Color.white.opacity(AppContrastMode.current.activeControlBorderOpacity) }
    static var primaryText: Color { Color.white.opacity(AppContrastMode.current.primaryTextOpacity) }
    static var secondaryText: Color { Color.white.opacity(AppContrastMode.current.secondaryTextOpacity) }
    static var tertiaryText: Color { Color.white.opacity(AppContrastMode.current.tertiaryTextOpacity) }
    static var disabledText: Color { Color.white.opacity(AppContrastMode.current.disabledTextOpacity) }
    static let disabledOpacity: Double = 0.46
    static var focusFill: Color { Color.white.opacity(AppContrastMode.current.focusFillOpacity) }
    static var focusBorder: Color { Color.white.opacity(AppContrastMode.current.focusBorderOpacity) }
    static var highContrastBorder: Color { Color.white.opacity(AppContrastMode.current.highContrastBorderOpacity) }
    static var highContrastFocus: Color { Color.white.opacity(AppContrastMode.current.highContrastFocusOpacity) }

    // Semantic colors are deliberately distinct from the selected accent. They
    // communicate state consistently in every workspace and remain readable in
    // the graphite and monochrome accent themes.
    static let success = Color.green
    static let warning = Color.orange
    static let danger = Color.red
    static let info = Color.cyan
    static var neutral: Color { Color.white.opacity(AppContrastMode.current.neutralOpacity) }

    static func spring(_ response: Double = 0.24) -> Animation {
        .interactiveSpring(response: response, dampingFraction: 0.86)
    }

    static var reducedAnimation: Animation { .easeOut(duration: 0.16) }
}

enum LiquidGlassDepth {
    case recessed
    case raised
    case floating
}

/// A deliberately asymmetric bevel. It keeps the workspace crystalline and
/// gives adjacent panels a crisp, machined silhouette instead of soft pills.
struct PrismaticPanelShape: InsettableShape {
    var cut: CGFloat = 7
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let c = min(max(2, cut - insetAmount), min(r.width, r.height) * 0.22)
        var path = Path()
        path.move(to: CGPoint(x: r.minX + c * 1.18, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - c * 0.64, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY + c * 0.64))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c * 1.05))
        path.addLine(to: CGPoint(x: r.maxX - c * 1.05, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + c * 0.48, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY - c * 0.48))
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + c * 1.18))
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
    @ObservedObject private var usage = UsageMonitor.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    var body: some View {
        ZStack {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
                Color.black.opacity(0.16)
                settings.accentTheme.primary.opacity(0.035)
            } else {
                VisualEffectView(material: material, blendingMode: blendingMode)
                Color.black.opacity(0.53)
                PrismaticAmbientLayer(theme: settings.accentTheme, suppressed: !usage.activeTasks.isEmpty)
                RadialGradient(
                    colors: [settings.accentTheme.primary.opacity(0.075), .clear],
                    center: .init(x: 0.12, y: 0.02),
                    startRadius: 4,
                    endRadius: 600
                )
                RadialGradient(
                    colors: [settings.accentTheme.secondary.opacity(0.045), .clear],
                    center: .init(x: 0.88, y: 0.96),
                    startRadius: 8,
                    endRadius: 540
                )
                LinearGradient(
                    colors: [Color.white.opacity(0.048), .clear, settings.accentTheme.tertiary.opacity(0.032), Color.black.opacity(0.16)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .ignoresSafeArea()
    }
}

/// Two oversized, low-opacity planes create movement behind windows without a
/// timer, canvas, blur, or per-frame state update. Core Animation interpolates
/// the transforms and stops them entirely when Reduce Motion is enabled.
private struct PrismaticAmbientLayer: View {
    let theme: AppAccentTheme
    let suppressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drifting = false

    private var canAnimate: Bool {
        !suppressed && !reduceMotion && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        GeometryReader { proxy in
            let wide = max(proxy.size.width * 0.72, 420)
            let tall = max(proxy.size.height * 0.66, 310)
            ZStack {
                PrismaticPanelShape(cut: 88)
                    .fill(
                        LinearGradient(
                            colors: [theme.primary.opacity(0.20), theme.secondary.opacity(0.085), .clear],
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

                PrismaticPanelShape(cut: 71)
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
                withAnimation(.easeInOut(duration: 24).repeatForever(autoreverses: true)) {
                    drifting = true
                }
            }
            .onChange(of: suppressed) { isSuppressed in
                if isSuppressed {
                    withAnimation(.linear(duration: 0.12)) { drifting = false }
                } else if canAnimate {
                    withAnimation(.easeInOut(duration: 24).repeatForever(autoreverses: true)) {
                        drifting = true
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct LiquidGlassSurfaceModifier: ViewModifier {
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let cornerRadius: CGFloat
    let depth: LiquidGlassDepth
    let selected: Bool
    let accentOpacity: Double

    private var baseOpacity: Double {
        switch depth {
        case .recessed: return LimaDesign.recessedOpacity
        case .raised: return LimaDesign.surfaceOpacity
        case .floating: return LimaDesign.floatingOpacity
        }
    }

    private var shadow: (color: Color, radius: CGFloat, y: CGFloat) {
        switch depth {
        case .recessed: return (.clear, 0, 0)
        case .raised: return (.black.opacity(0.18), 10, 4)
        case .floating: return (.black.opacity(0.24), 16, 6)
        }
    }

    func body(content: Content) -> some View {
        let shape = PrismaticPanelShape(cut: min(11, max(5, cornerRadius * 0.52)))
        content
            .background {
                if reduceTransparency {
                    shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
                } else {
                    shape
                        .fill(.thinMaterial)
                        .overlay {
                            shape.fill(Color.black.opacity(baseOpacity))
                        }
                        .overlay {
                            shape.fill(
                                LinearGradient(
                                    colors: [
                                        settings.accentTheme.primary.opacity(selected ? 0.16 : accentOpacity),
                                        .clear,
                                        settings.accentTheme.tertiary.opacity(selected ? 0.07 : accentOpacity * 0.28)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        }
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(selected ? 0.42 : LimaDesign.borderOpacity),
                            settings.accentTheme.primary.opacity(selected ? LimaDesign.selectedBorderOpacity : accentOpacity * 1.8),
                            Color.black.opacity(0.28)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: selected ? 0.9 : 0.6
                )
            }
            .overlay(alignment: .topLeading) {
                LinearGradient(
                    colors: [Color.white.opacity(selected ? 0.22 : 0.10), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 0.7)
                .padding(.leading, min(16, cornerRadius))
                .padding(.trailing, cornerRadius * 1.5)
            }
            .overlay(alignment: .leading) {
                if selected {
                    Rectangle()
                        .fill(settings.accentTheme.primary.opacity(0.78))
                        .frame(width: 1.5)
                        .padding(.vertical, min(9, cornerRadius * 0.5))
                }
            }
            .shadow(color: shadow.color, radius: shadow.radius, y: shadow.y)
            .shadow(
                color: selected ? settings.accentTheme.primary.opacity(0.18) : .clear,
                radius: selected ? 9 : 0,
                y: selected ? 3 : 0
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .foregroundStyle(prominent ? Color.white : Color.primary.opacity(0.84))
            .background {
                PrismaticPanelShape(cut: max(4, size * 0.18))
                    .fill(prominent ? AnyShapeStyle(SettingsStore.shared.accentTheme.gradient) : AnyShapeStyle(Color.black.opacity(0.24)))
                if !prominent && !reduceTransparency {
                    PrismaticPanelShape(cut: max(4, size * 0.18))
                        .fill(.ultraThinMaterial)
                }
            }
            .overlay {
                PrismaticPanelShape(cut: max(4, size * 0.18)).strokeBorder(
                    prominent ? Color.white.opacity(0.44) : LimaDesign.controlBorder,
                    lineWidth: prominent ? 0.8 : LimaDesign.borderWidth
                )
            }
            .shadow(color: .black.opacity(prominent ? 0.12 : 0.045), radius: prominent ? 6 : 3, y: prominent ? 2 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .offset(y: configuration.isPressed ? 0.5 : 0)
            .brightness(configuration.isPressed ? -0.03 : 0)
            .opacity(isEnabled ? 1 : LimaDesign.disabledOpacity)
            .limaAnimation(LimaDesign.spring(0.20), value: configuration.isPressed)
    }
}

struct LimaToolbarIconButtonStyle: ButtonStyle {
    var tint: Color = .primary
    var size: CGFloat = LimaDesign.iconButtonSize
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .limaFont(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(configuration.isPressed ? tint : Color.primary.opacity(0.78))
            .frame(width: size, height: size)
            .background(
                configuration.isPressed ? LimaDesign.controlHoverFill : LimaDesign.controlFill,
                in: PrismaticPanelShape(cut: 5)
            )
            .overlay {
                PrismaticPanelShape(cut: 5)
                    .stroke(configuration.isPressed ? tint.opacity(0.42) : LimaDesign.controlBorder, lineWidth: LimaDesign.borderWidth)
            }
            .brightness(configuration.isPressed ? -0.04 : 0)
            .opacity(isEnabled ? 1 : LimaDesign.disabledOpacity)
            .limaAnimation(LimaDesign.spring(0.18), value: configuration.isPressed)
    }
}

struct LimaToolbarTextButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .limaFont(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Color.primary.opacity(0.82))
            .padding(.horizontal, 10)
            .frame(minHeight: LimaDesign.compactControlHeight)
            .background {
                if prominent {
                    PrismaticPanelShape(cut: 6).fill(SettingsStore.shared.accentTheme.gradient)
                } else {
                    PrismaticPanelShape(cut: 6).fill(configuration.isPressed ? LimaDesign.controlHoverFill : LimaDesign.controlFill)
                }
            }
            .overlay {
                PrismaticPanelShape(cut: 6)
                    .stroke(prominent ? Color.white.opacity(0.30) : LimaDesign.controlBorder, lineWidth: LimaDesign.borderWidth)
            }
            .brightness(configuration.isPressed ? -0.04 : 0)
            .opacity(isEnabled ? 1 : LimaDesign.disabledOpacity)
            .limaAnimation(LimaDesign.spring(0.18), value: configuration.isPressed)
    }
}


struct LimaButtonStyle: ButtonStyle {
    var prominent = false
    var compact = false
    var destructive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = PrismaticPanelShape(cut: compact ? 5 : 6)
        let accent = destructive ? LimaDesign.danger : SettingsStore.shared.accentTheme.primary
        configuration.label
            .limaFont(.system(size: compact ? 10.5 : 11.5, weight: .semibold))
            .foregroundStyle(prominent || destructive ? Color.white : Color.primary.opacity(0.86))
            .padding(.horizontal, compact ? 8 : 10)
            .frame(minHeight: compact ? LimaDesign.compactControlHeight : LimaDesign.controlHeight)
            .background {
                if prominent {
                    shape.fill(SettingsStore.shared.accentTheme.gradient)
                } else if destructive {
                    shape.fill(accent.opacity(0.78))
                } else if reduceTransparency {
                    shape.fill(LimaDesign.controlFill)
                } else {
                    shape.fill(LimaDesign.controlFill)
                    shape.fill(.thinMaterial)
                }
            }
            .overlay {
                shape.strokeBorder(
                    prominent || destructive ? Color.white.opacity(0.34) : LimaDesign.controlBorder,
                    lineWidth: LimaDesign.borderWidth
                )
            }
            .brightness(configuration.isPressed ? -0.045 : 0)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(isEnabled ? 1 : LimaDesign.disabledOpacity)
            .limaAnimation(LimaDesign.spring(0.18), value: configuration.isPressed)
    }
}

private struct LimaInputSurfaceModifier: ViewModifier {
    let height: CGFloat
    let monospaced: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .limaFont(monospaced ? .system(size: 12, design: .monospaced) : .subheadline)
            .padding(.horizontal, 9)
            .frame(minHeight: height)
            .background(LimaDesign.controlFill, in: PrismaticPanelShape(cut: 6))
            .overlay {
                PrismaticPanelShape(cut: 6)
                    .stroke(LimaDesign.controlBorder, lineWidth: LimaDesign.borderWidth)
            }
    }
}

private struct LimaEditorSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(LimaDesign.editorFill, in: PrismaticPanelShape(cut: cornerRadius))
            .overlay {
                PrismaticPanelShape(cut: cornerRadius)
                    .stroke(LimaDesign.controlBorder, lineWidth: LimaDesign.borderWidth)
            }
    }
}

extension View {
    func limaButton(prominent: Bool = false, compact: Bool = false, destructive: Bool = false) -> some View {
        buttonStyle(LimaButtonStyle(prominent: prominent, compact: compact, destructive: destructive))
    }

    func limaInputSurface(height: CGFloat = LimaDesign.controlHeight, monospaced: Bool = false) -> some View {
        modifier(LimaInputSurfaceModifier(height: height, monospaced: monospaced))
    }

    func limaEditorSurface(cornerRadius: CGFloat = LimaDesign.compactCorner) -> some View {
        modifier(LimaEditorSurfaceModifier(cornerRadius: cornerRadius))
    }
}

struct GlassHairline: View {
    var body: some View {
        LinearGradient(
            colors: [.clear, LimaDesign.separator, .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 0.7)
    }
}

struct LimaToolbarTitle: View {
    @ObservedObject private var settings = SettingsStore.shared
    let symbol: String
    let title: String
    let subtitle: String?

    init(symbol: String, title: String, subtitle: String? = nil) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .limaFont(.system(size: 13, weight: .semibold))
                .foregroundStyle(settings.accentTheme.gradient)
                .frame(width: LimaDesign.titleIconSize, height: LimaDesign.titleIconSize)
                .background {
                    PrismaticPanelShape(cut: 7)
                        .fill(LimaDesign.controlFill)
                    PrismaticPanelShape(cut: 7)
                        .fill(settings.accentTheme.primary.opacity(0.075))
                }
                .overlay {
                    PrismaticPanelShape(cut: 7)
                        .stroke(LimaDesign.controlBorder, lineWidth: LimaDesign.borderWidth)
                }
            VStack(alignment: .leading, spacing: subtitle == nil ? 0 : 1) {
                Text(title)
                    .limaFont(.system(size: 14.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .limaFont(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

struct LimaStatusLine: View {
    let text: String
    let symbol: String
    let tint: Color
    let detail: String?
    let compact: Bool

    init(_ text: String, symbol: String = "circle.fill", tint: Color = .primary, detail: String? = nil, compact: Bool = false) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
        self.detail = detail
        self.compact = compact
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .limaFont(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
            Text(text)
                .limaFont(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .limaFont(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? 7 : 10)
        .frame(minHeight: compact ? LimaDesign.compactStatusHeight : LimaDesign.statusHeight)
        .background(LimaDesign.recessedFill, in: PrismaticPanelShape(cut: 6))
        .overlay {
            PrismaticPanelShape(cut: 6)
                .stroke(LimaDesign.separator, lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

struct LimaSectionLabel: View {
    let title: String
    let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(title.uppercased())
                .limaFont(.system(size: 9.5, weight: .bold, design: .rounded))
                .tracking(0.85)
                .foregroundStyle(.secondary)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .limaFont(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct LimaAnimationModifier<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

private struct LimaToolbarModifier: ViewModifier {
    let depth: LiquidGlassDepth
    let accentOpacity: Double

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .frame(minHeight: LimaDesign.toolbarHeight)
            .liquidGlass(cornerRadius: LimaDesign.standardCorner, depth: depth, accentOpacity: accentOpacity)
    }
}

struct LimaBadge: View {
    let text: String
    let symbol: String?
    let tint: Color

    init(_ text: String, symbol: String? = nil, tint: Color = .primary) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .limaFont(.system(size: 8.5, weight: .bold))
            }
            Text(text)
                .limaFont(.system(size: 8.5, weight: .bold, design: .rounded))
                .tracking(0.55)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(tint.opacity(0.10), in: PrismaticPanelShape(cut: 5))
        .overlay {
            PrismaticPanelShape(cut: 5)
                .stroke(tint.opacity(0.24), lineWidth: LimaDesign.borderWidth)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct LimaControlSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let depth: LiquidGlassDepth
    let selected: Bool
    let accentOpacity: Double

    func body(content: Content) -> some View {
        content.liquidGlass(
            cornerRadius: cornerRadius,
            depth: depth,
            selected: selected,
            accentOpacity: accentOpacity
        )
    }
}

extension View {
    func limaAnimation<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(LimaAnimationModifier(animation: animation, value: value))
    }

    func limaControlSurface(
        cornerRadius: CGFloat = LimaDesign.compactCorner,
        depth: LiquidGlassDepth = .recessed,
        selected: Bool = false,
        accentOpacity: Double = 0.008
    ) -> some View {
        modifier(LimaControlSurfaceModifier(
            cornerRadius: cornerRadius,
            depth: depth,
            selected: selected,
            accentOpacity: accentOpacity
        ))
    }

    func limaToolbar(
        depth: LiquidGlassDepth = .raised,
        accentOpacity: Double = 0.028
    ) -> some View {
        modifier(LimaToolbarModifier(depth: depth, accentOpacity: accentOpacity))
    }
}


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
        window.appearance = NSAppearance(named: .darkAqua)
        window.isMovableByWindowBackground = movableByBackground
        window.hasShadow = shadow
        window.setAccessibilityLabel(accessibilityLabel)
        if let minSize { window.minSize = minSize }
    }
}

@MainActor
enum LimaAppKitDesign {
    static var windowBackground: NSColor {
        NSColor.windowBackgroundColor.withAlphaComponent(0.94)
    }

    static var editorBackground: NSColor {
        NSColor.textBackgroundColor.withAlphaComponent(0.24)
    }

    static var recessedBackground: NSColor {
        NSColor.textBackgroundColor.withAlphaComponent(0.14)
    }

    static var surfaceBackground: NSColor {
        NSColor.controlBackgroundColor.withAlphaComponent(0.62)
    }

    static var separator: NSColor {
        NSColor.separatorColor.withAlphaComponent(0.72)
    }

    static var strongSeparator: NSColor {
        NSColor.separatorColor.withAlphaComponent(0.92)
    }

    static var accent: NSColor {
        SettingsStore.shared.accentTheme.nsPrimary
    }

    static var accentSoft: NSColor {
        accent.withAlphaComponent(0.16)
    }

    static var focus: NSColor {
        accent.withAlphaComponent(0.82)
    }

    static var selection: NSColor {
        accent.withAlphaComponent(0.25)
    }

    static var tableHeaderBackground: NSColor {
        (windowBackground.blended(withFraction: 0.22, of: accent) ?? windowBackground).withAlphaComponent(0.98)
    }

    static var tableAlternateBackground: NSColor {
        editorBackground.blended(withFraction: 0.18, of: windowBackground) ?? editorBackground
    }

    static var primaryText: NSColor { .labelColor }
    static var secondaryText: NSColor { .secondaryLabelColor }
    static var tertiaryText: NSColor { .tertiaryLabelColor }
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
