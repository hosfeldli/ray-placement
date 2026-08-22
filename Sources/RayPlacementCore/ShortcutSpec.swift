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

    private static func displayName(for key: String) -> String {
        if key.hasPrefix("kc"), let separator = key.firstIndex(of: ":") {
            let label = String(key[key.index(after: separator)...])
            return displayName(for: label)
        }
        switch key {
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
