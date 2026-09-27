import Foundation

/// User-owned aliases are kept outside manifests so extension updates never
/// overwrite local search vocabulary.
public final class CommandAliasStore: @unchecked Sendable {
    private let key = "lima.commandAliases"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var aliases: [String: [String]] {
        defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
    }

    public func set(_ aliases: [String], for commandID: String) {
        var values = self.aliases
        let cleaned = Array(Set(aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })).sorted()
        if cleaned.isEmpty { values.removeValue(forKey: commandID) } else { values[commandID] = cleaned }
        defaults.set(values, forKey: key)
    }

    public func aliases(for commandID: String) -> [String] { aliases[commandID] ?? [] }
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
