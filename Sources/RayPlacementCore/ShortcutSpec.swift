import Foundation

public struct ShortcutSpec: Codable, Equatable, Hashable, Sendable {
    public enum Modifier: String, Codable, CaseIterable, Sendable {
        case command
        case option
        case control
        case shift
    }

    public var modifiers: Set<Modifier>
    public var key: String

    public init(modifiers: Set<Modifier>, key: String) {
        self.modifiers = modifiers
        self.key = key.lowercased()
    }

    public init?(string: String) {
        let parts = string
            .lowercased()
            .replacingOccurrences(of: "⌘", with: "command+")
            .replacingOccurrences(of: "⌥", with: "option+")
            .replacingOccurrences(of: "⌃", with: "control+")
            .replacingOccurrences(of: "⇧", with: "shift+")
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let key = parts.last, !key.isEmpty else { return nil }

        var modifiers = Set<Modifier>()
        for component in parts.dropLast() {
            switch component {
            case "cmd", "command": modifiers.insert(.command)
            case "opt", "option", "alt": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            case "shift": modifiers.insert(.shift)
            default: return nil
            }
        }
        guard !modifiers.isEmpty else { return nil }
        let normalizedKey = key == " " ? "space" : String(key)
        if normalizedKey.hasPrefix("kc"), Self.recordedKeyCode(for: normalizedKey) == nil {
            return nil
        }
        self.init(modifiers: modifiers, key: normalizedKey)
    }

    public var storageString: String {
        let ordered = Modifier.allCases.filter(modifiers.contains).map(\.rawValue)
        return (ordered + [key]).joined(separator: "+")
    }

    /// Canonical physical-key identity used for conflict detection. A recorded
    /// key-code shortcut and its legacy character spelling must collide.
    public var conflictKey: String {
        let physicalKey = Self.recordedKeyCode(for: key) ?? Self.standardKeyCodes[key]
        let keyIdentity = physicalKey.map { "kc\($0)" } ?? key
        let orderedModifiers = Modifier.allCases.filter(modifiers.contains).map(\.rawValue)
        return (orderedModifiers + [keyIdentity]).joined(separator: "+")
    }

    public var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        result += Self.displayName(for: key)
        return result
    }

    public static func recordedKeyCode(for key: String) -> UInt32? {
        guard key.hasPrefix("kc"), let separator = key.firstIndex(of: ":") else { return nil }
        let numberStart = key.index(key.startIndex, offsetBy: 2)
        let number = key[numberStart..<separator]
        let label = key[key.index(after: separator)...]
        guard !number.isEmpty,
              !label.isEmpty,
              number.allSatisfy(\.isNumber),
              let keyCode = UInt32(number),
              keyCode <= 127 else { return nil }
        return keyCode
    }

    private static let standardKeyCodes: [String: UInt32] = [
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

    private static func displayName(for key: String) -> String {
        if key.hasPrefix("kc"), let separator = key.firstIndex(of: ":") {
            let label = String(key[key.index(after: separator)...])
            return displayName(for: label)
        }
        switch key {
        case "command": return " twice"
        case "space": return "Space"
        case "return", "enter": return "↩"
        case "escape", "esc": return "Esc"
        case "tab": return "⇥"
        case "up": return "↑"
        case "down": return "↓"
        case "left": return "←"
        case "right": return "→"
        default: return key.uppercased()
        }
    }
}

public struct ShortcutAssignment: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let shortcut: ShortcutSpec?

    public init(id: String, title: String, shortcut: String?) {
        self.id = id
        self.title = title
        self.shortcut = shortcut.flatMap(ShortcutSpec.init(string:))
    }
}

/// Snapshot-based shortcut index for conflict checks and reverse lookup.
public struct ShortcutRegistry: Sendable {
    public private(set) var assignments: [ShortcutAssignment]

    public init(assignments: [ShortcutAssignment] = []) {
        self.assignments = assignments
    }

    public mutating func set(_ assignment: ShortcutAssignment) {
        assignments.removeAll { $0.id == assignment.id }
        assignments.append(assignment)
    }

    public func conflict(for shortcut: String, excluding assignmentID: String) -> ShortcutAssignment? {
        guard let parsed = ShortcutSpec(string: shortcut) else { return nil }
        return assignments.first {
            $0.id != assignmentID && $0.shortcut?.conflictKey == parsed.conflictKey
        }
    }

    public func owners(of shortcut: String) -> [ShortcutAssignment] {
        guard let parsed = ShortcutSpec(string: shortcut) else { return [] }
        return assignments.filter { $0.shortcut?.conflictKey == parsed.conflictKey }
    }

    public func reverseLookup(_ shortcut: String) -> ShortcutAssignment? {
        owners(of: shortcut).first
    }

    public var conflicts: [[ShortcutAssignment]] {
        let grouped = Dictionary(grouping: assignments.compactMap { assignment -> (String, ShortcutAssignment)? in
            guard let shortcut = assignment.shortcut else { return nil }
            return (shortcut.conflictKey, assignment)
        }, by: \.0)
        return grouped.values
            .filter { $0.count > 1 }
            .map { $0.map(\.1).sorted { $0.id < $1.id } }
            .sorted { ($0.first?.shortcut?.storageString ?? "") < ($1.first?.shortcut?.storageString ?? "") }
    }
}
