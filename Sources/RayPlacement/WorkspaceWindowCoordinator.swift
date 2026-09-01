import AppKit

/// Keeps RayPlacement tools as independent, resizable workspaces. This avoids
/// macOS tab bars while still letting the launcher act as the central navigator.
@MainActor
final class WorkspaceWindowCoordinator {
    static let shared = WorkspaceWindowCoordinator()

    private struct WeakWindow {
        weak var value: NSWindow?
    }

    private var windows: [WeakWindow] = []
    func present(_ window: NSWindow, joinWorkspace: Bool = true) {
        register(window, rememberFrame: joinWorkspace)
        window.makeKeyAndOrderFront(nil)
    }

    func popOut(_ window: NSWindow?) {
        window?.makeKeyAndOrderFront(nil)
    }

    private func register(_ window: NSWindow, rememberFrame: Bool = true) {
        windows.removeAll { $0.value == nil }
        if !windows.contains(where: { $0.value === window }) { windows.append(WeakWindow(value: window)) }
        window.tabbingIdentifier = ""
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        if rememberFrame, !window.title.isEmpty, window.frameAutosaveName.isEmpty {
            let safeTitle = window.title
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
            window.setFrameAutosaveName("Lima.Workspace.\(safeTitle)")
        }
    }
}
