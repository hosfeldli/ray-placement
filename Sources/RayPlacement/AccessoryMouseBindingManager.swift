import AppKit
import CoreGraphics
import RayPlacementCore

/// Actions that Lima can perform directly when an accessory mouse button is pressed.
enum AccessoryMouseAction: String, CaseIterable, Identifiable {
    case none
    case previousDesktop
    case nextDesktop
    case missionControl
    case applicationWindows
    case previousWindow
    case back
    case forward
    case launcher
    case notes
    case quickNote
    case dictation
    case terminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "No action"
        case .previousDesktop: return "Previous Desktop"
        case .nextDesktop: return "Next Desktop"
        case .missionControl: return "Mission Control"
        case .applicationWindows: return "Application Windows"
        case .previousWindow: return "Next App Window"
        case .back: return "Back"
        case .forward: return "Forward"
        case .launcher: return "Open Lima"
        case .notes: return "Notes"
        case .quickNote: return "Quick Note"
        case .dictation: return "Toggle Dictation"
        case .terminal: return "Developer Terminal"
        }
    }
}

enum AccessoryMouseBindingKind: String, CaseIterable, Identifiable {
    case none
    case action
    case shortcut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "No action"
        case .action: return "Lima or macOS action"
        case .shortcut: return "Keyboard shortcut"
        }
    }
}

/// The persisted target for an accessory mouse button. Existing action values
/// remain valid; recorded shortcuts use the `shortcut:` prefix.
enum AccessoryMouseBinding: Equatable {
    case none
    case action(AccessoryMouseAction)
    case shortcut(String)

    init(storageValue: String?) {
        guard let storageValue, !storageValue.isEmpty else {
            self = .none
            return
        }
        if storageValue.hasPrefix("shortcut:") {
            self = .shortcut(String(storageValue.dropFirst("shortcut:".count)))
        } else if let action = AccessoryMouseAction(rawValue: storageValue), action != .none {
            self = .action(action)
        } else {
            self = .none
        }
    }

    var storageValue: String? {
        switch self {
        case .none:
            return nil
        case .action(let action):
            return action == .none ? nil : action.rawValue
        case .shortcut(let shortcut):
            return "shortcut:\(shortcut)"
        }
    }

    var kind: AccessoryMouseBindingKind {
        switch self {
        case .none: return .none
        case .action: return .action
        case .shortcut: return .shortcut
        }
    }
}

@MainActor
final class AccessoryMouseBindingManager {
    typealias Handler = (_ binding: AccessoryMouseBinding, _ sourceApplication: NSRunningApplication?) -> Void

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var bindings: [Int: AccessoryMouseBinding] = [:]
    private var handler: Handler?

    func start(bindings: [String: String], handler: @escaping Handler) {
        self.handler = handler
        update(bindings: bindings)
        guard globalMonitor == nil, localMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            Task { @MainActor in self?.handle(event, consume: false) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event, consume: true) ? nil : event
        }
    }

    func update(bindings rawBindings: [String: String]) {
        bindings = Dictionary(uniqueKeysWithValues: rawBindings.compactMap { key, value in
            guard let button = Int(key), (3...8).contains(button) else { return nil }
            let binding = AccessoryMouseBinding(storageValue: value)
            guard binding != .none else { return nil }
            if case .shortcut(let shortcut) = binding, ShortcutSpec(string: shortcut) == nil {
                return nil
            }
            return (button, binding)
        })
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        bindings.removeAll()
        handler = nil
    }

    @discardableResult
    private func handle(_ event: NSEvent, consume: Bool) -> Bool {
        guard let binding = bindings[event.buttonNumber] else { return false }
        let source = NSWorkspace.shared.frontmostApplication
        handler?(binding, source)
        return consume
    }
}
