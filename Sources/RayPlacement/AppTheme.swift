import AppKit
import SwiftUI

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
        window.appearance = SettingsStore.shared.appearance.nsAppearance
        window.isMovableByWindowBackground = movableByBackground
        window.hasShadow = shadow
        window.setAccessibilityLabel(accessibilityLabel)
        if let minSize { window.minSize = minSize }
    }
}

@MainActor
enum LimaAppKitDesign {
    static var windowBackground: NSColor { NSColor.windowBackgroundColor.withAlphaComponent(0.94) }
    static var editorBackground: NSColor { NSColor.textBackgroundColor.withAlphaComponent(0.24) }
    static var recessedBackground: NSColor { NSColor.textBackgroundColor.withAlphaComponent(0.14) }
    static var surfaceBackground: NSColor { NSColor.controlBackgroundColor.withAlphaComponent(0.62) }
    static var separator: NSColor { NSColor.separatorColor.withAlphaComponent(0.72) }
    static var strongSeparator: NSColor { NSColor.separatorColor.withAlphaComponent(0.92) }
    static var accent: NSColor { SettingsStore.shared.accentTheme.nsPrimary }
    static var accentSoft: NSColor { accent.withAlphaComponent(0.16) }
    static var focus: NSColor { accent.withAlphaComponent(0.82) }
    static var selection: NSColor { accent.withAlphaComponent(0.25) }
    static var tableHeaderBackground: NSColor { (windowBackground.blended(withFraction: 0.22, of: accent) ?? windowBackground).withAlphaComponent(0.98) }
    static var tableAlternateBackground: NSColor { editorBackground.blended(withFraction: 0.18, of: windowBackground) ?? editorBackground }
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
