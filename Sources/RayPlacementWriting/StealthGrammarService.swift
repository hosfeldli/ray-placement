import Foundation

/// Masks text that a correction engine must never rewrite. The mask is shared
/// by the local and optional developer BYOK paths so both paths have the same
/// safety boundary before a replacement is attempted.
public struct StealthProtectedText: Equatable, Sendable {
    public let maskedText: String
    public let leadingWhitespace: String
    public let trailingWhitespace: String
    private let replacements: [String: String]

    init(maskedText: String, leadingWhitespace: String, trailingWhitespace: String, replacements: [String: String]) {
        self.maskedText = maskedText
        self.leadingWhitespace = leadingWhitespace
        self.trailingWhitespace = trailingWhitespace
        self.replacements = replacements
    }

    public func restore(_ corrected: String) -> String? {
        guard !corrected.contains("```") else { return nil }
        var result = corrected
        for (token, original) in replacements {
            guard result.components(separatedBy: token).count == 2 else { return nil }
            result = result.replacingOccurrences(of: token, with: original)
        }
        guard !replacements.keys.contains(where: { result.contains($0) }) else { return nil }
        return leadingWhitespace + result + trailingWhitespace
    }

    public var protectedValues: [String] { Array(replacements.values) }
}

public enum StealthGrammarService {
    private static let correctableCapitalizedWords: Set<String> = [
        "teh", "thier", "wierd", "whot", "grammer", "recieve", "seperate",
        "definately", "occured", "untill", "alot", "dscernable", "naviattion",
        "performace", "effciency", "imrpove", "cna", "unistaller", "continu",
        "speach", "highltinged", "highlighing", "recieved", "recieved", "eror",
        "mistke", "adress", "begining", "calender", "comming", "enviroment",
        "occassion", "untill", "tomorow", "writting", "seperately", "becuase",
        "beleive", "freind", "goverment", "langauge"
    ]
    private static let commonTitleWords: Set<String> = [
        "a", "an", "and", "another", "are", "as", "at", "be", "but", "can", "could",
        "did", "do", "does", "for", "from", "hello", "hey", "hi", "how", "i", "if",
        "in", "is", "it", "my", "no", "not", "of", "on", "or", "our", "please",
        "should", "so", "some", "that", "the", "their", "there", "these", "they", "this",
        "those", "to", "was", "we", "were", "what", "when", "where", "which", "who",
        "why", "will", "with", "would", "you", "your"
    ]
    // Private-use sentinels are intentionally invisible to normal language
    // rules and are not valid user prose. The numeric portion is regenerated
    // until the complete token is absent from the source text.
    private static let tokenPrefix = "\u{E000}LIMA_KEEP_"
    private static let tokenSuffix = "_\u{E001}"

    /// Protects URLs, email addresses, code-like values, acronyms, title-case
    /// terms, and every user-supplied ignore-list term. Title-case protection is
    /// intentionally conservative: a possible name is safer left unchanged
    /// than silently spell-corrected into a different name.
    public static func protect(_ source: String, ignoreList: String) -> StealthProtectedText {
        let leading = String(source.prefix { $0.isWhitespace })
        var trailing = String(source.reversed().prefix { $0.isWhitespace }.reversed())
        // When the entire input is whitespace, the leading and trailing slices
        // overlap. Treat the complete value as leading whitespace so restore()
        // remains lossless instead of duplicating it.
        if leading.count + trailing.count > source.count {
            trailing = ""
        }
        let bodyStart = source.index(source.startIndex, offsetBy: leading.count)
        let bodyEnd = source.index(source.endIndex, offsetBy: -trailing.count)
        let body = bodyStart <= bodyEnd ? String(source[bodyStart..<bodyEnd]) : ""

        var ranges: [NSRange] = []
        let fullRange = NSRange(body.startIndex..<body.endIndex, in: body)
        let patterns = [
            #"(?i)\b(?:https?://|ftp://|www\.)[^\s<>\"']+"#,
            #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            #"`[^`\n]+`|```[\s\S]*?```"#,
            #"(?<![A-Za-z0-9])(?:~?/|/|\./|\.\./)[^\s]+"#,
            #"\b(?:v?\d+(?:\.\d+){1,}[A-Za-z0-9.-]*)\b"#,
            #"\b[A-Z]{2,}[A-Z0-9_./:+-]*\b"#,
            #"\b[A-Za-z][A-Za-z0-9_]*[A-Z][A-Za-z0-9_]*\b"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            ranges += expression.matches(in: body, range: fullRange).map(\.range)
        }

        // Preserve exact ignore-list entries, including phrases and hyphenated
        // terms. Longest entries win so a phrase is masked as one unit.
        let ignored = ignoreList
            .components(separatedBy: .newlines)
            .flatMap { line -> [String] in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return [] }
                if trimmed.contains(",") {
                    return trimmed.split(separator: ",").flatMap { part in
                        let value = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
                        return [value] + value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                    }
                }
                return [trimmed] + trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        for term in ignored {
            let escaped = NSRegularExpression.escapedPattern(for: term)
            let pattern = "(?i)(?<![A-Za-z0-9_])" + escaped + "(?![A-Za-z0-9_])"
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            ranges += expression.matches(in: body, range: fullRange).map(\.range)
        }

        // Title-case words are treated as possible proper nouns. This also
        // shields product names such as RayPlacement and macOS-like tokens.
        if let expression = try? NSRegularExpression(pattern: #"\b[A-Z][a-z]{2,}\b"#) {
            ranges += expression.matches(in: body, range: fullRange)
                .filter { match in
                    let word = (body as NSString).substring(with: match.range)
                    let lowercased = word.lowercased()
                    return !commonTitleWords.contains(lowercased)
                        && !correctableCapitalizedWords.contains(lowercased)
                }
                .map(\.range)
        }

        let merged = merge(ranges)
        var replacements: [String: String] = [:]
        var output = ""
        var cursor = 0
        for (index, range) in merged.enumerated() {
            guard range.location >= cursor,
                  NSMaxRange(range) <= (body as NSString).length else { continue }
            let prefix = (body as NSString).substring(with: NSRange(location: cursor, length: range.location - cursor))
            let original = (body as NSString).substring(with: range)
            var token = ""
            var tokenIndex = index
            repeat {
                token = "\(tokenPrefix)\(String(format: "%04d", tokenIndex))\(tokenSuffix)"
                tokenIndex += 1
            } while body.contains(token) || replacements[token] != nil
            output += prefix + token
            replacements[token] = original
            cursor = NSMaxRange(range)
        }
        output += (body as NSString).substring(from: cursor)
        return StealthProtectedText(
            maskedText: output,
            leadingWhitespace: leading,
            trailingWhitespace: trailing,
            replacements: replacements
        )
    }

    public static func isSafeReplacement(_ source: String, _ replacement: String) -> Bool {
        guard !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard replacement.count <= max(source.count * 4, source.count + 2_000) else { return false }
        guard newlineSignature(source) == newlineSignature(replacement) else { return false }
        guard !replacement.contains("```"), !replacement.contains("<CORRECTED>") else { return false }
        guard !replacement.unicodeScalars.contains(where: { scalar in
            let value = scalar.value
            return (value <= 0x1F && value != 0x09 && value != 0x0A && value != 0x0D) || value == 0x7F
        }) else { return false }
        return true
    }

    private static func newlineSignature(_ value: String) -> [UInt32] {
        value.unicodeScalars.compactMap { scalar in
            switch scalar.value {
            case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029:
                return scalar.value
            default:
                return nil
            }
        }
    }

    private static func merge(_ ranges: [NSRange]) -> [NSRange] {
        ranges
            .filter { $0.location != NSNotFound && $0.length > 0 }
            .sorted { first, second in
                if first.location == second.location { return first.length > second.length }
                return first.location < second.location
            }
            .reduce(into: [NSRange]()) { result, range in
                guard let previous = result.last else {
                    result.append(range)
                    return
                }
                if NSIntersectionRange(previous, range).length > 0 || NSMaxRange(previous) >= range.location {
                    result[result.count - 1] = NSUnionRange(previous, range)
                } else {
                    result.append(range)
                }
            }
    }
}
