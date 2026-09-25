import AppKit

/// Compatibility facade for workspace controllers that have not yet adopted a
/// typed surface ID. New code should call LimaSurfaceCoordinator directly.
@MainActor
final class WorkspaceWindowCoordinator {
    static let shared = WorkspaceWindowCoordinator()

    func present(_ window: NSWindow, joinWorkspace: Bool = true) {
        let surface = surfaceID(for: window)
        LimaSurfaceCoordinator.shared.present(
            surface,
            window: window,
            module: module(for: surface),
            activate: false,
            remembersFrame: joinWorkspace
        )
    }

    func popOut(_ window: NSWindow?) {
        guard let window else { return }
        let surface = surfaceID(for: window)
        LimaSurfaceCoordinator.shared.present(
            surface,
            window: window,
            module: module(for: surface),
            activate: false
        )
    }

    private func surfaceID(for window: NSWindow) -> LimaSurfaceID {
        let title = window.title.lowercased()
        if title.contains("formatter") { return .formatter }
        if title.contains("terminal") { return .terminal }
        if title.contains("setting") { return .settings }
        if title.contains("extension") || title.contains("command") { return .commandCenter }
        return .workspace
    }

    private func module(for surface: LimaSurfaceID) -> LimaWorkspaceModule? {
        switch surface {
        case .workspace: return .notes
        case .formatter: return .formatter
        case .terminal: return .terminal
        default: return nil
        }
    }
}
