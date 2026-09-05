import AppKit
import CoreGraphics

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

@MainActor
final class AccessoryMouseBindingManager {
    typealias Handler = (_ action: AccessoryMouseAction, _ sourceApplication: NSRunningApplication?) -> Void

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var bindings: [Int: AccessoryMouseAction] = [:]
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
            guard let button = Int(key), (3...8).contains(button),
                  let action = AccessoryMouseAction(rawValue: value), action != .none else { return nil }
            return (button, action)
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
        guard let action = bindings[event.buttonNumber] else { return false }
        let source = NSWorkspace.shared.frontmostApplication
        handler?(action, source)
        return consume
    }
}
