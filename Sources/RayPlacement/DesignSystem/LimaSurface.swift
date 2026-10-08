import AppKit
import SwiftUI

/// Interior surfaces never add another native blur; the window owns its single backdrop.
enum LimaGlassDepth: CaseIterable {
    case recessed
    case raised
    case floating

    /// Interior glass uses a restrained translucent fill; floating controls are
    /// denser for legibility. Reduced Transparency switches every level to an
    /// opaque system-aware palette color.
    func backgroundOpacity(reduceTransparency: Bool) -> Double {
        guard !reduceTransparency else { return 1 }
        switch self {
        case .recessed: return 0.76
        case .raised: return 0.88
        case .floating: return 0.94
        }
    }
}

/// Source-compatible name used by existing feature views.
typealias LiquidGlassDepth = LimaGlassDepth

/// The crystalline silhouette is intentionally retained for the launcher and
/// a small number of identity surfaces. Ordinary controls use rounded native
/// geometry instead.
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

struct LimaGlassBackdrop: View {
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var identityLayer = false
    var tintOpacity: Double? = nil

    var body: some View {
        ZStack {
            if reduceTransparency {
                LimaTheme.windowBackground
            } else {
                VisualEffectView(material: material, blendingMode: blendingMode)
                LimaTheme.windowBackground
                    .opacity(tintOpacity ?? settings.glassStyle.backdropTintOpacity)
                if identityLayer {
                    LinearGradient(
                        colors: [settings.accentTheme.primary.opacity(0.035), .clear, settings.accentTheme.tertiary.opacity(0.018)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea()
    }
}

typealias LiquidGlassBackdrop = LimaGlassBackdrop

private struct LiquidGlassSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let cornerRadius: CGFloat
    let depth: LiquidGlassDepth
    let selected: Bool

    private var fill: Color {
        let base: Color
        switch depth {
        case .recessed: base = LimaDesign.recessedFill
        case .raised: base = LimaDesign.controlFill
        case .floating: base = LimaTheme.floatingWindowBackground
        }
        return base.opacity(depth.backgroundOpacity(reduceTransparency: reduceTransparency))
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(fill, in: shape)
            // Clip child content before drawing the perimeter. Without this,
            // material, gradients, and focused controls can bleed through the
            // rounded edge and appear as doubled or broken borders.
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(selected ? LimaDesign.focusBorder : LimaDesign.controlBorder, lineWidth: selected ? LimaDesign.focusWidth : LimaDesign.borderWidth)
            }
            .overlay(alignment: .leading) {
                if selected {
                    Capsule()
                        .fill(LimaDesign.focusBorder)
                        .frame(width: 2)
                        .padding(.vertical, min(10, cornerRadius))
                }
            }
    }
}

extension View {
    /// Lightweight interior glass. Apply a native material only once through `LimaGlassBackdrop` per window.
    func limaGlassSurface(
        cornerRadius: CGFloat,
        depth: LimaGlassDepth = .raised,
        selected: Bool = false
    ) -> some View {
        modifier(LiquidGlassSurfaceModifier(cornerRadius: cornerRadius, depth: depth, selected: selected))
    }

    func limaGlassPanel(cornerRadius: CGFloat = LimaRadius.panel, depth: LimaGlassDepth = .raised) -> some View {
        limaGlassSurface(cornerRadius: cornerRadius, depth: depth)
    }

    func limaGlassField(cornerRadius: CGFloat = LimaRadius.control, selected: Bool = false) -> some View {
        limaGlassSurface(cornerRadius: cornerRadius, depth: .recessed, selected: selected)
    }

    func limaGlassSidebar(cornerRadius: CGFloat = 0) -> some View {
        limaGlassSurface(cornerRadius: cornerRadius, depth: .recessed)
    }

    func limaGlassInspector(cornerRadius: CGFloat = LimaRadius.panel) -> some View {
        limaGlassSurface(cornerRadius: cornerRadius, depth: .floating)
    }

    func limaGlassHUD(cornerRadius: CGFloat = LimaRadius.panel) -> some View {
        limaGlassSurface(cornerRadius: cornerRadius, depth: .floating)
    }

    func limaGlassSelection(cornerRadius: CGFloat = LimaRadius.control) -> some View {
        limaGlassSurface(cornerRadius: cornerRadius, depth: .raised, selected: true)
    }

    /// Compatibility entry point for established Liquid Glass call sites.
    func liquidGlass(
        cornerRadius: CGFloat,
        depth: LiquidGlassDepth = .raised,
        selected: Bool = false,
        accentOpacity: Double = 0.035
    ) -> some View {
        _ = accentOpacity // Retained for source compatibility; accent is reserved for selection and focus.
        return limaGlassSurface(cornerRadius: cornerRadius, depth: depth, selected: selected)
    }

    func limaNativeSurface(
        fill: Color = LimaColors.raisedSurface,
        radius: CGFloat = LimaRadius.panel,
        border: Color? = LimaColors.border,
        shadow: Bool = false
    ) -> some View {
        modifier(LimaSurfaceModifier(fill: fill, radius: radius, border: border, shadow: shadow))
    }

    func limaSelection(_ selected: Bool, hovered: Bool = false, radius: CGFloat = LimaRadius.control) -> some View {
        modifier(LimaSelection(selected: selected, hovered: hovered, radius: radius))
    }
}

struct LimaSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let fill: Color
    let radius: CGFloat
    let border: Color?
    let shadow: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let surfaceFill = fill.opacity(LimaGlassDepth.raised.backgroundOpacity(reduceTransparency: reduceTransparency))
        return content
            .background(surfaceFill, in: shape)
            // Keep the surface perimeter authoritative. Child backgrounds and
            // overlays must not escape the same geometry as the border.
            .clipShape(shape)
            .overlay {
                if let border {
                    shape.strokeBorder(border, lineWidth: LimaDesign.borderWidth)
                }
            }
            .shadow(color: shadow ? LimaTheme.shadowFloating : .clear, radius: shadow ? 12 : 0, y: shadow ? 4 : 0)
    }
}
