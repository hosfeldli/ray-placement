import AppKit

// The terminal needs more room than the command launcher, but remains a
// floating workspace rather than becoming a full-screen window.
enum LauncherPanelLayout {
    static let terminalSize = NSSize(width: 920, height: 620)

    static func size(
        for mode: LauncherMode,
        density: AppInterfaceDensity,
        resultCount: Int = 0,
        query: String = ""
    ) -> NSSize {
        if mode == .terminal { return terminalSize }

        let width = density.launcherWidth
        let standardHeight = density.launcherHeight
        if mode == .contextShelf { return NSSize(width: width, height: min(640, max(standardHeight, 520))) }
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        switch mode {
        case .root where cleanQuery.isEmpty && resultCount <= 6:
            // Search, a handful of quick actions, and the quiet footer fit in
            // a compact panel without leaving the screenshot-sized void that
            // the old fixed-height launcher created. Grow only as rows are
            // added so six idle actions do not get clipped by the compact size.
            let idleHeight = 176 + CGFloat(resultCount) * 39
            return NSSize(width: width, height: min(standardHeight, max(286, idleHeight)))
        case .output, .writingReview:
            return NSSize(width: width, height: min(640, max(standardHeight + 84, 540)))
        case .extensionSurface(let session):
            return NSSize(width: width, height: min(640, max(standardHeight, session.preferredHeight)))
        case .surface(let session):
            return NSSize(width: session.surface.preferredSize.width, height: min(700, max(standardHeight, session.surface.preferredSize.height)))
        case .picker(.emoji), .picker(.applications), .picker(.displays), .picker(.timezone), .files, .clipboard, .history:
            return NSSize(width: width, height: standardHeight)
        default:
            return NSSize(width: width, height: standardHeight)
        }
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
