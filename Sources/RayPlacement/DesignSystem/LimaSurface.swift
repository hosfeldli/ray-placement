import AppKit
import SwiftUI

enum LiquidGlassDepth {
    case recessed
    case raised
    case floating
}

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

struct LiquidGlassBackdrop: View {
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var identityLayer = false

    var body: some View {
        ZStack {
            if reduceTransparency {
                LimaColors.windowBackground
            } else {
                VisualEffectView(material: material, blendingMode: blendingMode)
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

private struct LiquidGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let depth: LiquidGlassDepth
    let selected: Bool

    private var fill: Color {
        switch depth {
        case .recessed: return LimaDesign.recessedFill
        case .raised: return LimaDesign.controlFill
        case .floating: return LimaDesign.sidebarBackground
        }
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
    func liquidGlass(
        cornerRadius: CGFloat,
        depth: LiquidGlassDepth = .raised,
        selected: Bool = false,
        accentOpacity: Double = 0.035
    ) -> some View {
        modifier(LiquidGlassSurfaceModifier(cornerRadius: cornerRadius, depth: depth, selected: selected))
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
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background {
            shape.fill(selected ? LimaColors.selectedFill : (hovered ? LimaColors.hoverFill : .clear))
        }
        .clipShape(shape)
        .overlay(alignment: .leading) {
            if selected {
                Capsule()
                    .fill(LimaColors.accent)
                    .frame(width: 2)
                    .padding(.vertical, 7)
            }
        }
    }
}

struct LimaSurfaceModifier: ViewModifier {
    let fill: Color
    let radius: CGFloat
    let border: Color?
    let shadow: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(fill, in: shape)
            // Keep the surface perimeter authoritative. Child backgrounds and
            // overlays must not escape the same geometry as the border.
            .clipShape(shape)
            .overlay {
                if let border {
                    shape.strokeBorder(border, lineWidth: LimaDesign.borderWidth)
                }
            }
            .shadow(color: shadow ? LimaColors.shadow.opacity(0.28) : .clear, radius: shadow ? 10 : 0, y: shadow ? 3 : 0)
    }
}
