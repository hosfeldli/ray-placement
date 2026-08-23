import AppKit
import Carbon
import Foundation
import RayPlacementCore

final class HotKeyManager {
    struct Registration {
        let identifier: String
        let shortcut: ShortcutSpec
        let reference: EventHotKeyRef
        let handler: (NSRunningApplication?) -> Void
    }

    enum RegistrationError: LocalizedError {
        case invalidKey(String)
        case duplicate(ShortcutSpec)
        case registrationFailed(ShortcutSpec, OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidKey(let key): return "Unsupported shortcut key: \(key)"
            case .duplicate(let shortcut): return "\(shortcut.displayString) is already assigned to another RayPlacement command."
            case .registrationFailed(let shortcut, let status): return "Could not register \(shortcut.displayString) (system status \(status))."
            }
        }
    }

    private let signature: OSType = 0x5259504C // RYPL
    private var nextID: UInt32 = 1
    private var registrations: [UInt32: Registration] = [:]
    private var eventHandler: EventHandlerRef?

    init() {
        installEventHandler()
    }

    deinit {
        unregisterAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func register(identifier: String, shortcut: ShortcutSpec, handler: @escaping () -> Void) throws {
        try registerFromApplication(identifier: identifier, shortcut: shortcut) { _ in handler() }
    }

    func registerFromApplication(
        identifier: String,
        shortcut: ShortcutSpec,
        handler: @escaping (NSRunningApplication?) -> Void
    ) throws {
        guard let keyCode = Self.keyCode(for: shortcut.key) else {
            throw RegistrationError.invalidKey(shortcut.key)
        }
        if let existing = registrations.first(where: { $0.value.identifier == identifier && $0.value.shortcut == shortcut }) {
            registrations[existing.key] = Registration(
                identifier: identifier,
                shortcut: shortcut,
                reference: existing.value.reference,
                handler: handler
            )
            return
        }
        guard !registrations.values.contains(where: { $0.identifier != identifier && $0.shortcut == shortcut }) else {
            throw RegistrationError.duplicate(shortcut)
        }

        let id = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            carbonModifiers(for: shortcut),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            throw RegistrationError.registrationFailed(shortcut, status)
        }
        // Keep the previous registration alive until its replacement succeeds.
        unregister(identifier: identifier)
        registrations[id] = Registration(identifier: identifier, shortcut: shortcut, reference: reference, handler: handler)
    }

    func unregister(identifier: String) {
        let ids = registrations.compactMap { $0.value.identifier == identifier ? $0.key : nil }
        for id in ids {
            if let registration = registrations.removeValue(forKey: id) {
                UnregisterEventHotKey(registration.reference)
            }
        }
    }

    func unregisterAll(prefix: String? = nil) {
        let ids = registrations.compactMap { id, registration in
            prefix == nil || registration.identifier.hasPrefix(prefix!) ? id : nil
        }
        for id in ids {
            if let registration = registrations.removeValue(forKey: id) {
                UnregisterEventHotKey(registration.reference)
            }
        }
    }

    private func installEventHandler() {
        var type = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                let application = NSWorkspace.shared.frontmostApplication
                manager.registrations[hotKeyID.id]?.handler(application)
                return noErr
            },
            1,
            &type,
            pointer,
            &eventHandler
        )
    }

    private func carbonModifiers(for shortcut: ShortcutSpec) -> UInt32 {
        var value: UInt32 = 0
        if shortcut.modifiers.contains(.command) { value |= UInt32(cmdKey) }
        if shortcut.modifiers.contains(.option) { value |= UInt32(optionKey) }
        if shortcut.modifiers.contains(.control) { value |= UInt32(controlKey) }
        if shortcut.modifiers.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }

    private static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
        "enter": 36, "l": 37, "j": 38, "k": 40, ";": 41, "\\": 42, ",": 43,
        "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49,
        "`": 50, "delete": 51, "escape": 53, "esc": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "left": 123, "right": 124, "down": 125, "up": 126
    ]

    private static func keyCode(for key: String) -> UInt32? {
        if key.hasPrefix("kc") { return ShortcutSpec.recordedKeyCode(for: key) }
        return keyCodes[key]
    }
}
