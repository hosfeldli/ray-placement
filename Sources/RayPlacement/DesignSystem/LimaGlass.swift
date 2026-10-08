import AppKit
import SwiftUI

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
}

/// One material view per structural region. The current toolchain's macOS 15 SDK
/// uses NSVisualEffectView; a future SDK can replace only this adapter with the
/// native glass container while leaving callers and content surfaces unchanged.
struct LimaGlassContainer<Content: View>: View {
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
            .background {
                ZStack {
                    LimaTheme.surfacePrimary
                        .opacity(reduceTransparency ? 1 : settings.glassStyle.baseOpacity)
                    if !reduceTransparency {
                        VisualEffectView(material: region.fallbackMaterial, blendingMode: .withinWindow)
                            .opacity(settings.glassStyle.materialOpacity)
                    }
                }
                .clipShape(shape)
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(LimaDesign.controlBorder, lineWidth: LimaDesign.borderWidth)
                    .allowsHitTesting(false)
            }
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
