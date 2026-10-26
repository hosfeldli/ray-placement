import Foundation

/// User-owned aliases are kept outside manifests so extension updates never
/// overwrite local search vocabulary.
public struct CommandAliasConflict: Equatable, Sendable {
    public let alias: String
    public let commandID: String

    public init(alias: String, commandID: String) {
        self.alias = alias
        self.commandID = commandID
    }
}

public final class CommandAliasStore: @unchecked Sendable {
    private let key = "lima.commandAliases"
    private let disabledKey = "lima.disabledCommandAliases"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var aliases: [String: [String]] {
        defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
    }

    public static func normalize(_ aliases: [String]) -> [String] {
        Array(Set(aliases.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })).sorted()
    }

    /// Reject ambiguous user-owned aliases even when one owner is temporarily
    /// disabled. This prevents re-enabling an alias from silently stealing it.
    public func conflict(for proposed: [String], excluding commandID: String) -> CommandAliasConflict? {
        let proposedAliases = Set(Self.normalize(proposed))
        let existing = aliases
        for ownerID in existing.keys.sorted() where ownerID != commandID {
            if let alias = Self.normalize(existing[ownerID] ?? []).first(where: proposedAliases.contains) {
                return CommandAliasConflict(alias: alias, commandID: ownerID)
            }
        }
        return nil
    }

    @discardableResult
    public func set(_ aliases: [String], for commandID: String) -> CommandAliasConflict? {
        let cleaned = Self.normalize(aliases)
        if let collision = conflict(for: cleaned, excluding: commandID) { return collision }
        var values = self.aliases
        if cleaned.isEmpty {
            values.removeValue(forKey: commandID)
            setEnabled(true, for: commandID)
        } else {
            values[commandID] = cleaned
        }
        defaults.set(values, forKey: key)
        return nil
    }

    public func aliases(for commandID: String) -> [String] { aliases[commandID] ?? [] }

    public func isEnabled(for commandID: String) -> Bool {
        !Set(defaults.stringArray(forKey: disabledKey) ?? []).contains(commandID)
    }

    public func setEnabled(_ enabled: Bool, for commandID: String) {
        var disabled = Set(defaults.stringArray(forKey: disabledKey) ?? [])
        if enabled { disabled.remove(commandID) } else { disabled.insert(commandID) }
        defaults.set(disabled.sorted(), forKey: disabledKey)
    }
}

public enum ExtensionInvocationError: Error, Equatable, Sendable {
    case missingArgument(String)
    case invalidInteger(String)
    case invalidNumber(String)
    case outOfRange(String)
    case invalidChoice(String)
    case unexpectedRemainder
}

public enum ExtensionInvocationParser {
    /// Parses only declared arguments. It never interprets a remainder as a
    /// shell command, which keeps direct invocation bounded and safe.
    public static func parse(_ input: String, descriptor: ExtensionInvocationDescriptor) throws -> [String: String] {
        var tokens = input.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var result: [String: String] = [:]
        for argument in descriptor.arguments ?? [] {
            guard !tokens.isEmpty else {
                if argument.required == true { throw ExtensionInvocationError.missingArgument(argument.id) }
                continue
            }
            let value: String
            if argument.consumeRemainder == true || (descriptor.acceptsRemainder == true && argument.id == descriptor.arguments?.last?.id) {
                value = tokens.joined(separator: " "); tokens.removeAll()
            } else {
                value = tokens.removeFirst()
            }
            switch argument.kind {
            case .integer:
                guard let number = Int(value) else { throw ExtensionInvocationError.invalidInteger(argument.id) }
                try validate(Double(number), argument: argument)
            case .number:
                guard let number = Double(value) else { throw ExtensionInvocationError.invalidNumber(argument.id) }
                try validate(number, argument: argument)
            case .choice:
                guard argument.options?.contains(value) == true else { throw ExtensionInvocationError.invalidChoice(argument.id) }
            default: break
            }
            result[argument.id] = value
        }
        if !tokens.isEmpty && descriptor.acceptsRemainder != true { throw ExtensionInvocationError.unexpectedRemainder }
        return result
    }

    private static func validate(_ value: Double, argument: ExtensionInvocationArgument) throws {
        if let minimum = argument.minimum, value < minimum { throw ExtensionInvocationError.outOfRange(argument.id) }
        if let maximum = argument.maximum, value > maximum { throw ExtensionInvocationError.outOfRange(argument.id) }
    }
}
