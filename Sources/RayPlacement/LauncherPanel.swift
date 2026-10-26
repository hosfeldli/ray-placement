import AppKit

enum LauncherSearchPhase: Equatable, Sendable {
    case idle
    case active

    init(query: String) {
        self = UniversalSearchCoordinator.parse(query).query.isEmpty ? .idle : .active
    }
}

// The terminal needs more room than the command launcher, but remains a
// floating workspace rather than becoming a full-screen window.
enum LauncherPanelLayout {
    static let terminalSize = NSSize(width: 920, height: 620)

    static func searchSize(density: AppInterfaceDensity) -> NSSize {
        switch density {
        case .compact: return NSSize(width: 720, height: 500)
        case .balanced: return NSSize(width: 760, height: 520)
        case .comfortable: return NSSize(width: 840, height: 580)
        }
    }

    static func idleSearchSize(density: AppInterfaceDensity) -> NSSize {
        // Keep the input's horizontal position unchanged when results appear.
        let width = searchSize(density: density).width
        switch density {
        case .compact: return NSSize(width: width, height: 146)
        case .balanced: return NSSize(width: width, height: 150)
        case .comfortable: return NSSize(width: width, height: 158)
        }
    }

    static func resizedFrame(_ current: NSRect, to size: NSSize,
                             anchorTop: Bool) -> NSRect {
        NSRect(
            x: current.midX - size.width / 2,
            y: anchorTop ? current.maxY - size.height : current.midY - size.height / 2,
            width: size.width, height: size.height
        )
    }

    static func size(
        for mode: LauncherMode,
        density: AppInterfaceDensity,
        searchPhase: LauncherSearchPhase = .idle
    ) -> NSSize {
        if mode == .terminal { return terminalSize }

        let width = density.launcherWidth
        let standardHeight = density.launcherHeight
        if mode == .contextShelf { return NSSize(width: width, height: min(640, max(standardHeight, 520))) }
        switch mode {
        case .root:
            // Empty Search stays vertically compact, but shares the results
            // width. The controller anchors its top edge as it expands.
            return searchPhase == .idle
                ? idleSearchSize(density: density) : searchSize(density: density)
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

/// A Search panel expands at most once during a visible presentation. Clearing
/// a query, receiving delayed results, or returning from a picker cannot move
/// the search field by collapsing the physical window.
struct LauncherPanelPresentationSizing {
    private(set) var hasExpandedSearch = false

    mutating func reset() {
        hasExpandedSearch = false
    }

    mutating func size(
        for mode: LauncherMode,
        density: AppInterfaceDensity,
        searchPhase: LauncherSearchPhase
    ) -> NSSize {
        guard mode == .root else {
            return LauncherPanelLayout.size(for: mode, density: density, searchPhase: searchPhase)
        }
        if searchPhase == .active { hasExpandedSearch = true }
        return hasExpandedSearch
            ? LauncherPanelLayout.searchSize(density: density)
            : LauncherPanelLayout.idleSearchSize(density: density)
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
