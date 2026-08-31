import Foundation

public enum TerminalWorkspaceInput {
    public struct RemoteDirectory: Equatable, Sendable {
        public let host: String
        public let path: String

        public init(host: String, path: String) {
            self.host = host
            self.path = path
        }
    }

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

    /// Remote shells commonly emit OSC 7 as file://host/path. Keep this
    /// separate from local paths so Finder actions can never target a VM path.
    public static func remoteDirectory(_ value: String) -> RemoteDirectory? {
        guard let url = URL(string: value), url.isFileURL,
              let host = url.host, !host.isEmpty, host != "localhost",
              host != ProcessInfo.processInfo.hostName,
              url.path.hasPrefix("/") else { return nil }
        return RemoteDirectory(host: host, path: url.path)
    }

    /// Extract a conservative OpenSSH destination without attempting to
    /// interpret ProxyCommand or arbitrary option values.
    public static func sshDestination(from command: String) -> String? {
        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.first == "ssh" else { return nil }
        var index = 1
        let optionsWithValue: Set<String> = ["-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L", "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w"]
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" { index += 1; break }
            if !token.hasPrefix("-") { break }
            if optionsWithValue.contains(token) { index += 2 } else { index += 1 }
        }
        guard index < tokens.count else { return nil }
        let destination = tokens[index]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@%:")
        guard !destination.isEmpty,
              destination.unicodeScalars.allSatisfy(allowed.contains),
              !destination.hasPrefix("-") else { return nil }
        return destination
    }

    public static func primaryCommand(in command: String) -> String? {
        command.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }
}
