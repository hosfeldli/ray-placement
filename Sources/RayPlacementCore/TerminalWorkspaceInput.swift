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
    ///
    /// An active SSH session is allowed to report localhost or the local
    /// machine name. Some VM images use those names even though the shell is
    /// reached through an SSH alias or forwarded port.
    public static func remoteDirectory(_ value: String, allowLocalHost: Bool = false) -> RemoteDirectory? {
        guard let url = URL(string: value), url.isFileURL,
              url.path.hasPrefix("/") else { return nil }
        guard let host = url.host, !host.isEmpty else { return nil }
        guard allowLocalHost || (host != "localhost" && host != ProcessInfo.processInfo.hostName) else { return nil }
        return RemoteDirectory(host: host, path: url.path)
    }

    /// Parse a guest-reported OSC 7 path while an SSH session is already
    /// active. Guests may emit `file:///home/user` with no hostname, or report
    /// localhost/their own guest name; the SSH alias remains the connection
    /// identity in all of those cases.
    public static func remotePath(_ value: String) -> String? {
        guard let url = URL(string: value), url.isFileURL, url.path.hasPrefix("/") else { return nil }
        return url.path
    }

    /// Extract the destination from an interactive SSH command. This uses a
    /// shell-aware tokenizer and accepts the command wrappers commonly used
    /// with VM tooling (`command`, `exec`, `sudo`, and `env`).
    public static func sshDestination(from command: String) -> String? {
        if let arguments = sshProcessArguments(from: command),
           let separator = arguments.firstIndex(of: "--"),
           arguments.index(after: separator) < arguments.endIndex {
            return arguments[arguments.index(after: separator)]
        }
        // Destination recognition is intentionally broader than replay-safe
        // probe arguments. An SSH command may contain a valid but unsupported
        // forwarding/configuration option; it still represents an active VM
        // session even when that option must not be replayed by the explorer.
        return sshDestinationOnly(from: command)
    }

    /// Return safe arguments for the read-only SSH probes used by the remote
    /// explorer. The result includes `--` and the destination, so it can be
    /// appended with a remote command without invoking a local shell.
    public static func sshProcessArguments(from command: String) -> [String]? {
        guard let tokens = shellTokens(command),
              let sshIndex = sshCommandIndex(tokens) else { return nil }

        var options: [String] = []
        var index = sshIndex + 1
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                index += 1
                break
            }
            guard token.hasPrefix("-"), token != "-" else { break }

            switch token {
            case "-4", "-6", "-A", "-a", "-C", "-K", "-k", "-q", "-T":
                options.append(token)
                index += 1
            case "-f", "-g", "-M", "-N", "-n", "-s", "-t", "-tt":
                // These affect the original interactive connection, but must
                // not be replayed with a read-only remote inspection command.
                index += 1
            case "-F", "-I", "-i", "-J", "-l", "-o", "-p":
                guard let parsed = optionWithValue(token, tokens: tokens, index: index) else { return nil }
                options.append(contentsOf: parsed.values)
                index = parsed.nextIndex
            default:
                // Common verbosity/display flags do not affect the connection
                // and are safe to omit from a probe. This also covers -vvv.
                if isSSHFlagToken(token) {
                    index += 1
                    continue
                }
                // Attached forms of the common value options are safe to
                // normalize. Other options are intentionally not replayed by
                // a read-only probe (for example ProxyCommand or forwarding).
                guard let parsed = attachedOption(token) else { return nil }
                switch parsed.kind {
                case .identity, .config, .jump, .login, .port:
                    options += parsed.values
                    index += 1
                case .unsupported:
                    return nil
                }
            }
        }

        guard index < tokens.count else { return nil }
        let destination = tokens[index]
        guard isSafeSSHIdentifier(destination, allowingColon: true) else { return nil }
        return options + ["--", destination]
    }

    public static func primaryCommand(in command: String) -> String? {
        shellTokens(command)?.first
    }

    private enum AttachedOptionKind {
        case identity, config, jump, login, port, unsupported
    }

    private struct AttachedOption {
        let kind: AttachedOptionKind
        let values: [String]
    }

    private struct ParsedOption {
        let values: [String]
        let nextIndex: Int
    }

    private static func sshCommandIndex(_ tokens: [String]) -> Int? {
        guard !tokens.isEmpty else { return nil }
        var index = 0

        // `command ssh`, `exec ssh`, and `sudo ssh` still launch an SSH
        // process. Strip only these known wrappers; do not search arbitrary
        // command lines for the word "ssh".
        while index < tokens.count {
            let token = tokens[index]
            let executable = URL(fileURLWithPath: token).lastPathComponent
            if executable == "command" || executable == "exec" {
                index += 1
                if index < tokens.count, tokens[index] == "--" { index += 1 }
                continue
            }
            if executable == "sudo" {
                index += 1
                // Support common sudo wrappers, including `sudo -u user ssh`
                // and `sudo -n ssh`, without consuming SSH's own options.
                while index < tokens.count {
                    let option = tokens[index]
                    if option == "--" { index += 1; break }
                    if option == "-n" || option == "-H" || option == "-E" || option == "-C" || option == "-b" || option == "-S" || option == "-V" || option == "-v" {
                        index += 1
                    } else if option == "-u" || option == "-g" || option == "-h" || option == "-p" || option == "-r" || option == "-R" {
                        guard index + 1 < tokens.count else { return nil }
                        index += 2
                    } else if option.hasPrefix("-") && option.count > 2 {
                        index += 1
                    } else {
                        break
                    }
                }
                continue
            }
            if executable == "env" {
                index += 1
                if index < tokens.count, tokens[index] == "--" { index += 1 }
                while index < tokens.count, isEnvironmentAssignment(tokens[index]) { index += 1 }
                continue
            }
            break
        }

        guard index < tokens.count else { return nil }
        let executable = URL(fileURLWithPath: tokens[index]).lastPathComponent
        return executable == "ssh" ? index : nil
    }

    private static func sshDestinationOnly(from command: String) -> String? {
        guard let tokens = shellTokens(command),
              let sshIndex = sshCommandIndex(tokens) else { return nil }
        var index = sshIndex + 1
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                index += 1
                break
            }
            guard token.hasPrefix("-"), token != "-" else { break }
            if let nextIndex = sshOptionValueEnd(token, tokens: tokens, index: index) {
                index = nextIndex
            } else if isSSHFlagToken(token) {
                index += 1
            } else {
                return nil
            }
        }
        guard index < tokens.count,
              isSafeSSHIdentifier(tokens[index], allowingColon: true) else { return nil }
        return tokens[index]
    }

    private static func sshOptionValueEnd(_ token: String, tokens: [String], index: Int) -> Int? {
        let valueOptions = ["-B", "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L", "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w"]
        for option in valueOptions {
            if token == option { return index + 1 < tokens.count ? index + 2 : nil }
            if token.hasPrefix(option), token.count > option.count { return index + 1 }
        }
        return nil
    }

    private static func isSSHFlagToken(_ token: String) -> Bool {
        guard token.count > 1, token.hasPrefix("-") else { return false }
        let flags = CharacterSet(charactersIn: "46AaC fFgKMNnqstTtVvXxYy")
        let body = token.dropFirst()
        return !body.isEmpty && body.unicodeScalars.allSatisfy(flags.contains)
    }

    private static func optionWithValue(_ token: String, tokens: [String], index: Int) -> ParsedOption? {
        guard index + 1 < tokens.count else { return nil }
        let value = tokens[index + 1]
        switch token {
        case "-F", "-I", "-i":
            guard isSafeArgument(value) else { return nil }
        case "-J":
            guard isSafeJumpHosts(value) else { return nil }
        case "-l":
            guard isSafeSSHIdentifier(value) else { return nil }
        case "-o":
            guard isSafeReadOnlySSHOption(value) else { return nil }
        case "-p":
            guard let port = Int(value), (1...65_535).contains(port) else { return nil }
            return ParsedOption(values: [token, String(port)], nextIndex: index + 2)
        default:
            return nil
        }
        return ParsedOption(values: [token, value], nextIndex: index + 2)
    }

    private static func attachedOption(_ token: String) -> AttachedOption? {
        let options: [(String, AttachedOptionKind)] = [
            ("-F", .config), ("-I", .config), ("-i", .identity),
            ("-J", .jump), ("-l", .login), ("-p", .port), ("-o", .unsupported)
        ]
        for (prefix, kind) in options where token.hasPrefix(prefix) && token.count > prefix.count {
            let value = String(token.dropFirst(prefix.count))
            switch kind {
            case .config, .identity:
                guard isSafeArgument(value) else { return nil }
            case .jump:
                guard isSafeJumpHosts(value) else { return nil }
            case .login:
                guard isSafeSSHIdentifier(value) else { return nil }
            case .port:
                guard let port = Int(value), (1...65_535).contains(port) else { return nil }
            case .unsupported:
                break
            }
            return AttachedOption(kind: kind, values: [prefix, value])
        }
        return nil
    }

    private static func shellTokens(_ command: String) -> [String]? {
        var tokens: [String] = []
        var token = ""
        var quote: Character?
        var escaping = false

        for character in command {
            if escaping {
                token.append(character)
                escaping = false
                continue
            }
            if character == "\\" && quote != "'" {
                escaping = true
                continue
            }
            if quote != nil {
                if character == quote! {
                    quote = nil
                } else {
                    token.append(character)
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
            } else if character.isWhitespace {
                if !token.isEmpty { tokens.append(token); token.removeAll(keepingCapacity: true) }
            } else {
                token.append(character)
            }
        }

        guard !escaping, quote == nil else { return nil }
        if !token.isEmpty { tokens.append(token) }
        return tokens
    }


    private static func isEnvironmentAssignment(_ value: String) -> Bool {
        guard let equals = value.firstIndex(of: "=") else { return false }
        let name = value[..<equals]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        return !name.isEmpty && name.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isSafeArgument(_ value: String) -> Bool {
        !value.isEmpty && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func isSafeSSHIdentifier(_ value: String, allowingColon: Bool = false) -> Bool {
        var characters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@%[]"
        if allowingColon { characters += ":" }
        let allowed = CharacterSet(charactersIn: characters)
        return !value.isEmpty && value.unicodeScalars.allSatisfy(allowed.contains) && !value.hasPrefix("-")
    }

    private static func isSafeJumpHosts(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@%:,[]")
        return !value.isEmpty && value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isSafeReadOnlySSHOption(_ value: String) -> Bool {
        let allowedKeys = [
            "ConnectTimeout", "GlobalKnownHostsFile", "HostKeyAlias", "IdentitiesOnly",
            "IdentityFile", "PreferredAuthentications", "PubkeyAuthentication", "Port",
            "StrictHostKeyChecking", "User", "UserKnownHostsFile", "RequestTTY",
            "ServerAliveInterval", "ServerAliveCountMax"
        ]
        guard let separator = value.firstIndex(of: "=") else { return false }
        let key = String(value[..<separator])
        let optionValue = String(value[value.index(after: separator)...])
        return allowedKeys.contains(key) && isSafeArgument(optionValue)
    }
}
