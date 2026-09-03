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

    /// Normalize paths accepted by the remote explorer. A bare relative path
    /// is interpreted from the remote user's home directory; an empty value
    /// returns the remote home marker.
    public static func normalizedRemotePath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "~" }
        if trimmed == "~" || trimmed.hasPrefix("~/") || trimmed.hasPrefix("/") { return trimmed }
        return "~/" + trimmed
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
        sshProcessArguments(from: command).flatMap { arguments in
            guard let separator = arguments.firstIndex(of: "--"), arguments.distance(from: separator, to: arguments.endIndex) == 2 else { return nil }
            return arguments[arguments.index(after: separator)]
        }
    }

    /// Return safe arguments for the read-only SSH probes used by the remote
    /// explorer. The result includes `--` and the destination, so it can be
    /// appended with a remote command without invoking a local shell.
    public static func sshProcessArguments(from command: String) -> [String]? {
        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.first == "ssh" else { return nil }

        var options: [String] = []
        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                index += 1
                break
            }
            guard token.hasPrefix("-"), token != "-" else { break }

            switch token {
            case "-4", "-6", "-A", "-a", "-C", "-K", "-k", "-q":
                options.append(token)
                index += 1
            case "-F", "-I", "-i":
                guard let value = nextValue(tokens, index: index), isSafeArgument(value) else { return nil }
                options += [token, value]
                index += 2
            case "-J":
                guard let value = nextValue(tokens, index: index), isSafeJumpHosts(value) else { return nil }
                options += [token, value]
                index += 2
            case "-l":
                guard let value = nextValue(tokens, index: index), isSafeSSHIdentifier(value) else { return nil }
                options += [token, value]
                index += 2
            case "-o":
                guard let value = nextValue(tokens, index: index), isSafeReadOnlySSHOption(value) else { return nil }
                options += [token, value]
                index += 2
            case "-p":
                guard let value = nextValue(tokens, index: index), let port = Int(value), (1...65_535).contains(port) else { return nil }
                options += [token, String(port)]
                index += 2
            default:
                // Do not replay forwarding, command, or arbitrary config
                // options while probing a VM's filesystem.
                return nil
            }
        }

        guard index < tokens.count else { return nil }
        let destination = tokens[index]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@%:[]")
        guard !destination.isEmpty,
              destination.unicodeScalars.allSatisfy(allowed.contains),
              !destination.hasPrefix("-") else { return nil }
        return options + ["--", destination]
    }

    public static func primaryCommand(in command: String) -> String? {
        command.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    private static func nextValue(_ tokens: [String], index: Int) -> String? {
        let next = index + 1
        guard next < tokens.count else { return nil }
        return tokens[next]
    }

    private static func isSafeArgument(_ value: String) -> Bool {
        !value.isEmpty && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func isSafeSSHIdentifier(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@%")
        return !value.isEmpty && value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isSafeJumpHosts(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@%:,[]")
        return !value.isEmpty && value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isSafeReadOnlySSHOption(_ value: String) -> Bool {
        let allowedKeys = [
            "ConnectTimeout", "GlobalKnownHostsFile", "HostKeyAlias", "IdentitiesOnly",
            "IdentityFile", "PreferredAuthentications", "PubkeyAuthentication", "Port",
            "StrictHostKeyChecking", "User", "UserKnownHostsFile"
        ]
        guard let separator = value.firstIndex(of: "=") else { return false }
        let key = String(value[..<separator])
        let optionValue = String(value[value.index(after: separator)...])
        return allowedKeys.contains(key) && isSafeArgument(optionValue)
    }
}
