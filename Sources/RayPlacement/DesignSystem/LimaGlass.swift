import AppKit
import SwiftUI

/// Test-only injection lets the offscreen audit inspect the opaque fallback
/// without changing the macOS accessibility setting for the user's session.
private struct LimaTestReduceTransparencyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var limaTestReduceTransparency: Bool {
        get { self[LimaTestReduceTransparencyKey.self] }
        set { self[LimaTestReduceTransparencyKey.self] = newValue }
    }
}

/// Glass belongs to structural navigation and controls, never repeated content rows.
enum LimaGlassRegion {
    case toolbar
    case sidebar
    case composer
    case hud

    var fallbackMaterial: NSVisualEffectView.Material {
        switch self {
        case .toolbar: return .headerView
        case .sidebar: return .sidebar
        case .composer: return .popover
        case .hud: return .hudWindow
        }
    }

    /// Distinct structural depths use the same single material layer. The
    /// composer and HUD lead, while the toolbar remains deliberately quieter.
    var prismStrength: Double {
        switch self {
        case .toolbar: return 0.72
        case .sidebar: return 0.94
        case .composer: return 1.36
        case .hud: return 1.20
        }
    }
}

/// Compatibility wrapper for quiet structural surfaces, with no per-panel native blur.
struct LimaGlassContainer<Content: View>: View {
    @ObservedObject private var appearance = AppearancePreferences.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.limaTestReduceTransparency) private var testReduceTransparency

    let region: LimaGlassRegion
    let cornerRadius: CGFloat
    private let content: Content

    init(region: LimaGlassRegion, cornerRadius: CGFloat = LimaRadius.panel,
         @ViewBuilder content: () -> Content) {
        self.region = region
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(region == .sidebar ? LimaTheme.surfaceSecondary : LimaTheme.surfacePrimary, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(LimaTheme.borderSubtle, lineWidth: LimaDesign.hairlineWidth).allowsHitTesting(false))
    }
}

/// Quiet, non-material surface for notes, messages, results, and work areas.
struct LimaContentSurface<Content: View>: View {
    let cornerRadius: CGFloat
    let fill: Color
    private let content: Content

    init(cornerRadius: CGFloat = LimaRadius.panel, fill: Color = LimaTheme.surfacePrimary,
         @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.fill = fill
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(fill, in: shape)
            .clipShape(shape)
    }
}

/// Shared selection language for lists and navigation without another material.
struct LimaSelection: ViewModifier {
    let selected: Bool
    let hovered: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background {
                shape.fill(selected ? LimaColors.selectedFill : (hovered ? LimaColors.hoverFill : .clear))
            }
            .clipShape(shape)
            .overlay(alignment: .leading) {
                if selected {
                    Capsule()
                        .fill(LimaTheme.accentInk)
                        .frame(width: 2)
                        .padding(.vertical, 7)
                }
            }
    }
}

/// Window composition: a calm backdrop with structural glass supplied by child regions.
extension View {
    func limaGlassContainer(region: LimaGlassRegion,
                            cornerRadius: CGFloat = LimaRadius.panel) -> some View {
        LimaGlassContainer(region: region, cornerRadius: cornerRadius) { self }
    }

    func limaContentSurface(cornerRadius: CGFloat = LimaRadius.panel,
                            fill: Color = LimaTheme.surfacePrimary) -> some View {
        LimaContentSurface(cornerRadius: cornerRadius, fill: fill) { self }
    }
}

struct LimaChrome<Content: View>: View {
    let identityLayer: Bool
    private let content: Content

    init(identityLayer: Bool = false, @ViewBuilder content: () -> Content) {
        self.identityLayer = identityLayer
        self.content = content()
    }

    var body: some View {
        ZStack {
            LimaGlassBackdrop(identityLayer: identityLayer)
            content
        }
    }
}

/// One static spectral edge per major window. It adds depth without stacking
/// blurred materials over scrolling content or depending on a particular wallpaper.
struct LimaPrismFrame: View {
    let radius: CGFloat
    @ObservedObject private var appearance = AppearancePreferences.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.limaTestReduceTransparency) private var testReduceTransparency

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(LimaTheme.borderSubtle, lineWidth: LimaDesign.hairlineWidth)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// A deliberate hit target for moving transparent windows. Unlike
/// isMovableByWindowBackground, it cannot steal clicks from editors or buttons.
struct LimaWindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { LimaWindowDragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class LimaWindowDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
