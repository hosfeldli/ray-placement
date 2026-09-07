import AppKit

// The terminal needs more room than the command launcher, but remains a
// floating workspace rather than becoming a full-screen window.
enum LauncherPanelLayout {
    static let terminalSize = NSSize(width: 920, height: 620)

    static func size(for mode: LauncherMode, density: AppInterfaceDensity) -> NSSize {
        if mode == .terminal { return terminalSize }
        return NSSize(width: density.launcherWidth, height: density.launcherHeight)
    }
}

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        title = "Lima"
        setAccessibilityLabel("Lima launcher")
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle, .canJoinAllApplications]
    }
}
