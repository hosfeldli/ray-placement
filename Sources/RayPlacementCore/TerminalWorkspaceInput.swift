import Foundation

public enum TerminalWorkspaceInput {
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    public static func isSafeSingleLine(_ value: String) -> Bool {
        !value.isEmpty && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    public static func localDirectory(_ value: String) -> String? {
        if value.hasPrefix("/") { return value }
        guard let url = URL(string: value), url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost" || url.host == ProcessInfo.processInfo.hostName else { return nil }
        return url.path.hasPrefix("/") ? url.path : nil
    }
}
