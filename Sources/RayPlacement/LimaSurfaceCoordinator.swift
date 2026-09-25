import AppKit
import Foundation

enum LimaSurfaceID: String, CaseIterable, Codable, Hashable {
    case launcher
    case workspace
    case formatter
    case terminal
    case settings
    case commandCenter
    case activityShelf
    case quickNote
    case modal
}

enum LimaWorkspaceModule: String, CaseIterable, Codable, Hashable {
    case notes
    case ai
    case dictation
    case terminal
    case formatter
}

enum LimaEscapeAction: Equatable {
    case navigateBack
    case dismissSurface
    case clearSelection
    case none
}

/// Centralizes Lima-owned window presentation. This intentionally does not
/// manage the user's other application windows; that remains WindowManager's
/// Accessibility-scoped responsibility.
@MainActor
final class LimaSurfaceCoordinator: NSObject, NSWindowDelegate {
    static let shared = LimaSurfaceCoordinator()

    private final class WeakWindow {
        weak var value: NSWindow?
        init(_ value: NSWindow) { self.value = value }
    }

    private var windows: [LimaSurfaceID: WeakWindow] = [:]
    private var modules: [LimaSurfaceID: LimaWorkspaceModule] = [:]

    private override init() {
        super.init()
    }

    func register(
        _ window: NSWindow,
        for id: LimaSurfaceID,
        module: LimaWorkspaceModule? = nil,
        remembersFrame: Bool = true
    ) {
        windows = windows.filter { $0.value.value != nil }
        if let existing = windows[id]?.value, existing !== window {
            // A singleton controller should normally reuse its window. When a
            // caller replaces one, retire the old presentation before adopting
            // the new instance so duplicate workspace windows cannot linger.
            existing.orderOut(nil)
        }
        windows[id] = WeakWindow(window)
        if let module { modules[id] = module }
        window.tabbingIdentifier = ""
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        // Keep the controller’s existing NSWindowDelegate intact. Several
        // Lima surfaces use delegate callbacks for their own editing and close
        // lifecycles; presentation coordination must not replace those hooks.
        if remembersFrame {
            let identifier = frameIdentifier(for: id)
            if window.frameAutosaveName.isEmpty {
                window.setFrameAutosaveName(identifier)
            }
            WorkspaceStateRegistry.shared.restore(window: window, identifier: identifier)
        }
    }

    func present(
        _ id: LimaSurfaceID,
        window: NSWindow,
        module: LimaWorkspaceModule? = nil,
        activate: Bool = true,
        remembersFrame: Bool = true
    ) {
        register(window, for: id, module: module, remembersFrame: remembersFrame)
        dismissConflictingTransientSurfaces(for: id)
        if let module {
            CrashRecoveryStore.shared.update { snapshot in
                snapshot.activeSurface = id.rawValue
                snapshot.activeWorkspaceModule = module.rawValue
            }
        } else {
            CrashRecoveryStore.shared.update { $0.activeSurface = id.rawValue }
        }
        window.makeKeyAndOrderFront(nil)
        if activate { NSApp.activate(ignoringOtherApps: true) }
    }

    func dismiss(_ id: LimaSurfaceID) {
        windows[id]?.value?.orderOut(nil)
    }

    func toggle(
        _ id: LimaSurfaceID,
        window: NSWindow,
        module: LimaWorkspaceModule? = nil,
        activate: Bool = true
    ) {
        if windows[id]?.value?.isVisible == true {
            dismiss(id)
        } else {
            present(id, window: window, module: module, activate: activate)
        }
    }

    func focus(_ id: LimaSurfaceID) {
        guard let window = windows[id]?.value else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func window(for id: LimaSurfaceID) -> NSWindow? {
        windows[id]?.value
    }

    func currentModule(for id: LimaSurfaceID) -> LimaWorkspaceModule? {
        modules[id]
    }

    func escapeAction(
        for id: LimaSurfaceID,
        canNavigateBack: Bool,
        hasSelection: Bool
    ) -> LimaEscapeAction {
        if canNavigateBack { return .navigateBack }
        if hasSelection { return .clearSelection }
        switch id {
        case .launcher, .quickNote, .modal:
            return .dismissSurface
        default:
            return .none
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value.value === window })?.key else { return }
        WorkspaceStateRegistry.shared.remember(window: window, identifier: frameIdentifier(for: id))
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        windowDidMove(notification)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value.value === window })?.key else { return }
        WorkspaceStateRegistry.shared.remember(window: window, identifier: frameIdentifier(for: id))
    }

    private func dismissConflictingTransientSurfaces(for presenting: LimaSurfaceID) {
        // A transient search or quick-note surface should never stack over a
        // modal/settings handoff, but independent workspaces remain available.
        switch presenting {
        case .settings, .commandCenter, .modal:
            dismiss(.launcher)
        case .workspace, .formatter, .terminal:
            dismiss(.launcher)
        case .launcher:
            dismiss(.modal)
        case .activityShelf, .quickNote:
            break
        }
    }

    private func frameIdentifier(for id: LimaSurfaceID) -> String {
        "Lima.Surface.\(id.rawValue)"
    }
}
