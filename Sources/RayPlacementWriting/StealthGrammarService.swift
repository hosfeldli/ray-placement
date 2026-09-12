import Foundation

/// Masks text that a correction engine must never rewrite. The mask is shared
/// by the local and optional developer BYOK paths so both paths have the same
/// safety boundary before a replacement is attempted.
public struct StealthProtectedText: Equatable, Sendable {
    public let maskedText: String
    public let leadingWhitespace: String
    public let trailingWhitespace: String
    private let replacements: [String: String]
    private let contextReplacements: [String: String]
    private let contextTokens: [String]
    private let sourceBody: String

    /// A complete document with protected values replaced by ordinary, stable
    /// placeholders. Unlike `maskedText`, this value intentionally retains all
    /// surrounding grammar context and is the only representation sent to an
    /// external proofreader.
    public let contextText: String

    init(
        maskedText: String,
        leadingWhitespace: String,
        trailingWhitespace: String,
        replacements: [String: String],
        sourceBody: String = "",
        contextText: String? = nil,
        contextReplacements: [String: String] = [:],
        contextTokens: [String]? = nil
    ) {
        self.maskedText = maskedText
        self.leadingWhitespace = leadingWhitespace
        self.trailingWhitespace = trailingWhitespace
        self.replacements = replacements
        self.contextReplacements = contextReplacements
        self.contextTokens = contextTokens ?? Array(contextReplacements.keys)
        self.sourceBody = sourceBody
        self.contextText = contextText ?? (leadingWhitespace + maskedText + trailingWhitespace)
    }

    public func restore(_ corrected: String) -> String? {
        guard !corrected.contains("```") else { return nil }
        // A provider must preserve the exact token sequence. Checking only
        // token counts would allow two protected values to be swapped.
        guard tokenSequence(in: corrected) == tokenSequence(in: maskedText) else { return nil }
        var result = corrected
        for (token, original) in replacements {
            guard result.components(separatedBy: token).count == 2 else { return nil }
            result = result.replacingOccurrences(of: token, with: original)
        }
        guard !replacements.keys.contains(where: { result.contains($0) }) else { return nil }
        return leadingWhitespace + result + trailingWhitespace
    }

    private func tokenSequence(in value: String) -> [String] {
        // Embed the private-use sentinels as literal Unicode scalars. Using
        // a regex-level \u{...} escape is not portable across the Foundation
        // ICU implementations used by supported macOS versions.
        let pattern = "\u{E000}LIMA_KEEP_[0-9]+_\u{E001}"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.matches(in: value, range: range).map {
            (value as NSString).substring(with: $0.range)
        }
    }

    public var protectedValues: [String] { Array(replacements.values) }

    /// Restores the ordinary placeholders used by the external document
    /// protocol. The complete placeholder sequence must remain unchanged, so
    /// the provider cannot edit, duplicate, remove, or reorder protected text.
    public func restoreContext(_ corrected: String) -> String? {
        guard !corrected.contains("```") else { return nil }
        guard contextTokens.allSatisfy({ token in
            contextText.components(separatedBy: token).count == 2
                && corrected.components(separatedBy: token).count == 2
        }) else { return nil }
        let expected = contextTokenSequence(in: contextText, tokens: contextTokens)
        guard contextTokenSequence(in: corrected, tokens: contextTokens) == expected else { return nil }
        var result = corrected
        for token in contextTokens {
            guard let original = contextReplacements[token] else { return nil }
            result = result.replacingOccurrences(of: token, with: original)
        }
        return result
    }



    private func contextTokenSequence(in value: String, tokens: [String]) -> [String] {
        let source = value as NSString
        return tokens.compactMap { token -> (location: Int, token: String)? in
            let range = source.range(of: token)
            guard range.location != NSNotFound else { return nil }
            return (range.location, token)
        }
        .sorted { $0.location < $1.location }
        .map(\.token)
    }

    /// Applies document-level atomic changes. Every candidate is validated and
    /// mapped independently; malformed, ambiguous, overlapping, unsafe, or
    /// placeholder-touching candidates are skipped without discarding valid
    /// corrections returned alongside them.
    public func applyingDocumentChanges(_ changes: [StealthGrammarDocumentChange]) -> StealthGrammarApplyReport {
        var accepted: [(range: NSRange, replacement: String, find: String)] = []
        var rejected = 0
        let source = contextText as NSString

        for change in changes {
            guard StealthGrammarService.isValidDocumentChange(change),
                  !StealthGrammarService.containsContextPlaceholder(change.find),
                  !StealthGrammarService.containsContextPlaceholder(change.replacement) else {
                rejected += 1
                continue
            }

            var matches: [NSRange] = []
            var cursor = 0
            while cursor <= source.length {
                let available = source.length - cursor
                let match = source.range(of: change.find, options: [], range: NSRange(location: cursor, length: available))
                guard match.location != NSNotFound else { break }
                matches.append(match)
                cursor = max(NSMaxRange(match), cursor + 1)
            }
            if let before = change.before {
                matches = matches.filter { range in
                    guard range.location >= (before as NSString).length else { return false }
                    let start = range.location - (before as NSString).length
                    return source.substring(with: NSRange(location: start, length: range.location - start)) == before
                }
            }
            if let after = change.after {
                matches = matches.filter { range in
                    let length = (after as NSString).length
                    guard NSMaxRange(range) + length <= source.length else { return false }
                    return source.substring(with: NSRange(location: NSMaxRange(range), length: length)) == after
                }
            }

            guard matches.count == 1, let match = matches.first,
                  StealthGrammarService.isSafeDocumentReplacement(change.find, change.replacement),
                  !StealthGrammarService.intersectsContextPlaceholder(match, in: source as String),
                  !accepted.contains(where: { StealthGrammarService.rangesOverlap($0.range, match) }) else {
                rejected += 1
                continue
            }
            accepted.append((match, change.replacement, change.find))
        }

        func candidateText(for edits: [(range: NSRange, replacement: String, find: String)]) -> String {
            let mutable = NSMutableString(string: contextText)
            for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
                mutable.replaceCharacters(in: edit.range, with: edit.replacement)
            }
            return mutable as String
        }

        // A valid edit can still create a bad interaction with a neighboring
        // edit. Greedily retain the largest safe subset so one document-level
        // anomaly does not discard otherwise independent corrections.
        var safeAccepted: [(range: NSRange, replacement: String, find: String)] = []
        for edit in accepted {
            let tentative = safeAccepted + [edit]
            let tentativeText = candidateText(for: tentative)
            let allowedPunctuationDeletions = tentative.reduce(into: 0) { total, edit in
                let sourcePunctuation = edit.find.unicodeScalars.filter { CharacterSet.punctuationCharacters.contains($0) }.count
                let replacementPunctuation = edit.replacement.unicodeScalars.filter { CharacterSet.punctuationCharacters.contains($0) }.count
                total += max(0, sourcePunctuation - replacementPunctuation)
            }
            if StealthGrammarService.isDocumentSane(
                contextText,
                tentativeText,
                allowedPunctuationDeletions: allowedPunctuationDeletions
            ) {
                safeAccepted.append(edit)
            } else {
                rejected += 1
            }
        }

        let restoredContext = candidateText(for: safeAccepted)
        let restored = restoreContext(restoredContext) ?? (leadingWhitespace + sourceBody + trailingWhitespace)
        return StealthGrammarApplyReport(
            text: restored,
            appliedCount: safeAccepted.count,
            rejectedCount: rejected
        )
    }
}

/// An atomic provider proposal against the complete sanitized document.
public struct StealthGrammarDocumentChange: Codable, Equatable, Sendable {
    public let find: String
    public let replacement: String
    public let before: String?
    public let after: String?

    public init(find: String, replacement: String, before: String? = nil, after: String? = nil) {
        self.find = find
        self.replacement = replacement
        self.before = before
        self.after = after
    }
}

public struct StealthGrammarApplyReport: Equatable, Sendable {
    public let text: String
    public let appliedCount: Int
    public let rejectedCount: Int

    public init(text: String, appliedCount: Int, rejectedCount: Int) {
        self.text = text
        self.appliedCount = appliedCount
        self.rejectedCount = rejectedCount
    }
}

public struct StealthGrammarEdit: Codable, Equatable, Sendable {
    public let start: Int
    public let length: Int
    public let replacement: String

    public init(start: Int, length: Int, replacement: String) {
        self.start = start
        self.length = length
        self.replacement = replacement
    }
}

public enum StealthGrammarEditError: LocalizedError, Equatable, Sendable {
    case invalidRange
    case overlappingEdits
    case protectedTextChanged
    case unsafeReplacement

    public var errorDescription: String? {
        switch self {
        case .invalidRange: return "The provider returned an edit outside the original text."
        case .overlappingEdits: return "The provider returned overlapping grammar edits."
        case .protectedTextChanged: return "The provider attempted to change protected text."
        case .unsafeReplacement: return "The provider returned an unsafe grammar replacement."
        }
    }
}

public enum StealthGrammarService {
    private static func protectedTokenRanges(in value: String) -> [NSRange] {
        let pattern = "\u{E000}LIMA_KEEP_[0-9]+_\u{E001}"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.matches(in: value, range: range).map(\.range)
    }
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
                    let prefix = (body as NSString).substring(with: NSRange(location: 0, length: match.range.location))
                    let preceding = prefix.trimmingCharacters(in: .whitespacesAndNewlines).last
                    let sentenceInitial = preceding == nil
                        || preceding == "."
                        || preceding == "!"
                        || preceding == "?"
                        || preceding == ":"
                        || preceding == "\n"
                    return !sentenceInitial
                        && !commonTitleWords.contains(lowercased)
                        && !correctableCapitalizedWords.contains(lowercased)
                }
                .map(\.range)
        }

        let merged = merge(ranges)
        var replacements: [String: String] = [:]
        var contextReplacements: [String: String] = [:]
        var output = ""
        var contextOutput = ""
        var cursor = 0
        var contextCounters: [String: Int] = [:]
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

            contextOutput += prefix
            let category = contextCategory(for: original, body: body)
            var counter = contextCounters[category, default: 0]
            var contextToken = "[\(category)_\(counter)]"
            while body.contains(contextToken) || contextReplacements[contextToken] != nil {
                counter += 1
                contextToken = "[\(category)_\(counter)]"
            }
            contextCounters[category] = counter + 1
            contextOutput += contextToken
            contextReplacements[contextToken] = original
            cursor = NSMaxRange(range)
        }
        let remaining = (body as NSString).substring(from: cursor)
        output += remaining
        contextOutput += remaining
        return StealthProtectedText(
            maskedText: output,
            leadingWhitespace: leading,
            trailingWhitespace: trailing,
            replacements: replacements,
            sourceBody: body,
            contextText: leading + contextOutput + trailing,
            contextReplacements: contextReplacements,
            contextTokens: contextReplacements.keys.sorted { left, right in
                (contextOutput as NSString).range(of: left).location < (contextOutput as NSString).range(of: right).location
            }
        )
    }


    /// Validates and applies provider edits to the exact text sent to the
    /// provider. Protected tokens are rejected before any replacement is made;
    /// the caller can then restore the protected values byte-for-byte.
    public static func apply(_ edits: [StealthGrammarEdit], to source: String) throws -> String {
        let sourceLength = (source as NSString).length
        let tokenRanges = protectedTokenRanges(in: source)
        var ranges: [NSRange] = []
        ranges.reserveCapacity(edits.count)

        for edit in edits {
            guard edit.start >= 0, edit.length >= 0,
                  edit.start <= sourceLength,
                  edit.length <= sourceLength - edit.start else {
                throw StealthGrammarEditError.invalidRange
            }
            let range = NSRange(location: edit.start, length: edit.length)
            let touchesProtected = tokenRanges.contains { tokenRange in
                if edit.length == 0 {
                    return edit.start >= tokenRange.location && edit.start <= NSMaxRange(tokenRange)
                }
                return NSIntersectionRange(tokenRange, range).length > 0
            }
            guard !touchesProtected else { throw StealthGrammarEditError.protectedTextChanged }
            guard isSafeReplacement((source as NSString).substring(with: range), edit.replacement)
                    || (edit.length == 0 && !edit.replacement.isEmpty && edit.replacement.utf8.count <= 32) else {
                throw StealthGrammarEditError.unsafeReplacement
            }
            guard !ranges.contains(where: { rangesOverlap($0, range) }) else {
                throw StealthGrammarEditError.overlappingEdits
            }
            ranges.append(range)
        }

        let mutable = NSMutableString(string: source)
        for (edit, range) in zip(edits, ranges).sorted(by: { $0.1.location > $1.1.location }) {
            mutable.replaceCharacters(in: range, with: edit.replacement)
        }
        return mutable as String
    }

    static func rangesOverlap(_ first: NSRange, _ second: NSRange) -> Bool {
        // NSIntersectionRange treats two zero-length ranges as non-overlapping.
        // Insertions at the same point, or inside a replacement range, still
        // conflict because applying both edits would be order-dependent.
        if first.length == 0 && second.length == 0 {
            return first.location == second.location
        }
        if first.length == 0 {
            return first.location > second.location && first.location < NSMaxRange(second)
        }
        if second.length == 0 {
            return second.location > first.location && second.location < NSMaxRange(first)
        }
        return NSIntersectionRange(first, second).length > 0
    }

    public static func isSafeReplacement(_ source: String, _ replacement: String) -> Bool {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // A proofreading response may be a little longer, but it must not
        // become a rewrite or a generated explanation.
        let sourceBytes = source.utf8.count
        let replacementBytes = replacement.utf8.count
        // Proofreading may insert a small amount of punctuation or expand a
        // contraction, but it must not turn into a generated paragraph.
        let allowedExpansion = max(8, min(96, sourceBytes / 5))
        guard replacementBytes <= sourceBytes + allowedExpansion else { return false }
        let distance = editDistance(source, replacement)
        let allowedDistance = max(4, min(96, max(sourceBytes, replacementBytes) * 28 / 100))
        guard distance <= allowedDistance else { return false }
        guard newlineSignature(source) == newlineSignature(replacement) else { return false }
        guard markdownStructure(source) == markdownStructure(replacement) else { return false }
        guard immutableMarkdownSegments(source) == immutableMarkdownSegments(replacement) else { return false }
        guard !replacement.contains("<CORRECTED>"), !isChattyResponse(replacement) else { return false }
        guard !replacement.unicodeScalars.contains(where: { scalar in
            let value = scalar.value
            return (value <= 0x1F && value != 0x09 && value != 0x0A && value != 0x0D) || value == 0x7F
        }) else { return false }
        return true
    }

    public static func isChattyResponse(_ value: String) -> Bool {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefixes = [
            "here is the corrected", "here's the corrected", "corrected text:",
            "the corrected text is", "i corrected", "i would change", "sure,",
            "<corrected>", "<proofread>", "answer:", "revision:"
        ]
        return prefixes.contains(where: clean.hasPrefix)
            || clean.hasSuffix("</corrected>")
            || clean.hasSuffix("</proofread>")
    }

    private static func markdownStructure(_ value: String) -> [String] {
        let lines = value.components(separatedBy: .newlines)
        var structure: [String] = []
        for line in lines {
            let leading = String(line.prefix { $0 == " " || $0 == "\t" })
            let body = String(line.dropFirst(leading.count))
            if body.hasPrefix("#") {
                structure.append("heading:\(leading.count):\(body.prefix { $0 == "#" }.count)")
            } else if body.hasPrefix(">") {
                structure.append("quote:\(leading.count)")
            } else if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
                structure.append("bullet:\(leading.count):\(body.first!)")
            } else if body.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil {
                structure.append("ordered:\(leading.count)")
            } else {
                structure.append("text")
            }
        }
        return structure
    }

    private static func immutableMarkdownSegments(_ value: String) -> [String] {
        let patterns = [
            #"```[\s\S]*?```"#,
            #"`[^`\n]+`"#,
            #"!?(?:\[[^]\n]*\])\([^)]*\)"#
        ]
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return patterns.reduce(into: [String]()) { result, pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
            result.append(contentsOf: expression.matches(in: value, range: range).map {
                (value as NSString).substring(with: $0.range)
            })
        }
    }

    private static func editDistance(_ source: String, _ replacement: String) -> Int {
        let a = Array(source.utf8)
        let b = Array(replacement.utf8)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for (i, left) in a.enumerated() {
            var current = [i + 1]
            current.reserveCapacity(b.count + 1)
            for (j, right) in b.enumerated() {
                let cost = left == right ? 0 : 1
                current.append(min(current[j] + 1, previous[j + 1] + 1, previous[j] + cost))
            }
            previous = current
        }
        return previous[b.count]
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

    private static func contextCategory(for value: String, body: String) -> String {
        if value.range(of: #"(?i)^(https?://|ftp://|www\.)"#, options: .regularExpression) != nil { return "URL" }
        if value.contains("@") { return "EMAIL" }
        if value.hasPrefix("`") { return "CODE" }
        if value.range(of: #"^(~?/|/|\./|\.\./)"#, options: .regularExpression) != nil { return "PATH" }
        if value.range(of: #"^v?\d+(?:\.\d+){1,}"#, options: .regularExpression) != nil { return "VERSION" }
        if value.range(of: #"^[A-Z]{2,}[A-Z0-9_./:+-]*$"#, options: .regularExpression) != nil { return "ACRONYM" }
        if value.range(of: #"^[A-Z][a-z]{2,}$"#, options: .regularExpression) != nil { return "NAME" }
        return "TERM"
    }

    static func isValidDocumentChange(_ change: StealthGrammarDocumentChange) -> Bool {
        // Empty replacements are permitted only for an explicitly nominated
        // punctuation target. The safety validator below rejects whitespace,
        // word, structural, and placeholder deletion.
        guard !change.find.isEmpty,
              change.find.count <= 120,
              change.replacement.count <= 120,
              change.find.split(whereSeparator: { $0.isWhitespace }).count <= 15,
              change.find.rangeOfCharacter(from: .newlines) == nil,
              change.replacement.rangeOfCharacter(from: .newlines) == nil else { return false }
        // A normal proofread edit is a small span. Longer sentence-like or
        // multi-sentence rewrites are intentionally rejected even when they
        // happen to be grammatically valid.
        let sentencePunctuation = change.find.contains { ".!?".contains($0) }
        if sentencePunctuation && change.find.split(whereSeparator: { $0.isWhitespace }).count > 6 {
            return false
        }
        let requiresAnchor = change.find.count < 6
            || change.find.split(whereSeparator: { $0.isWhitespace }).count == 1
        let punctuationOnlyDeletion = change.replacement.isEmpty
            && change.find.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
        guard !requiresAnchor || change.before != nil || change.after != nil || punctuationOnlyDeletion else {
            return false
        }
        return !(change.before?.contains("\n\n\n") ?? false)
            && !(change.after?.contains("\n\n\n") ?? false)
    }

    private static func isSafeAnchoredReplacement(_ source: String, _ replacement: String) -> Bool {
        guard !source.isEmpty, !replacement.isEmpty,
              !replacement.contains("\n\n\n"),
              !isChattyResponse(replacement) else { return false }
        // An anchored change may alter the selected word or punctuation, but it
        // may not silently consume a boundary space. Explicitly anchored space
        // changes remain possible because `find` includes that exact space.
        let sourceLeading = source.prefix { $0.isWhitespace }
        let sourceTrailing = source.reversed().prefix { $0.isWhitespace }
        let replacementLeading = replacement.prefix { $0.isWhitespace }
        let replacementTrailing = replacement.reversed().prefix { $0.isWhitespace }
        guard sourceLeading.count == replacementLeading.count,
              sourceTrailing.count == replacementTrailing.count else { return false }
        let allowedExpansion = max(8, min(48, source.utf8.count / 2))
        return replacement.utf8.count <= source.utf8.count + allowedExpansion
    }

    static func isDocumentSane(
        _ source: String,
        _ corrected: String,
        allowedPunctuationDeletions: Int
    ) -> Bool {
        guard !corrected.contains("\n\n\n"),
              internalWordSeparatorWhitespaceCount(in: corrected)
                >= internalWordSeparatorWhitespaceCount(in: source) else { return false }

        let sourceRepeatedWhitespace = repeatedWhitespaceRunCounts(in: source)
        let correctedRepeatedWhitespace = repeatedWhitespaceRunCounts(in: corrected)
        for (length, count) in correctedRepeatedWhitespace where count > sourceRepeatedWhitespace[length, default: 0] {
            return false
        }

        let sourceAllCaps = allCapsWordCounts(in: source)
        let correctedAllCaps = allCapsWordCounts(in: corrected)
        for (word, count) in correctedAllCaps where count > sourceAllCaps[word, default: 0] {
            return false
        }

        let sourceRepeatedWords = adjacentRepeatedWordCounts(in: source)
        let correctedRepeatedWords = adjacentRepeatedWordCounts(in: corrected)
        for (word, count) in correctedRepeatedWords where count > sourceRepeatedWords[word, default: 0] {
            return false
        }

        let sourcePunctuation = source.unicodeScalars.filter { CharacterSet.punctuationCharacters.contains($0) }.count
        let correctedPunctuation = corrected.unicodeScalars.filter { CharacterSet.punctuationCharacters.contains($0) }.count
        let removedPunctuation = max(0, sourcePunctuation - correctedPunctuation)
        guard removedPunctuation <= allowedPunctuationDeletions else { return false }
        return true
    }

    private static func repeatedWhitespaceRunCounts(in value: String) -> [Int: Int] {
        let scalars = Array(value.unicodeScalars)
        var result: [Int: Int] = [:]
        var index = 0
        while index < scalars.count {
            guard scalars[index] == " " || scalars[index] == "\t" else {
                index += 1
                continue
            }
            let start = index
            while index < scalars.count && (scalars[index] == " " || scalars[index] == "\t") {
                index += 1
            }
            let length = index - start
            if length >= 2 { result[length, default: 0] += 1 }
        }
        return result
    }

    private static func allCapsWordCounts(in value: String) -> [String: Int] {
        guard let expression = try? NSRegularExpression(pattern: #"\b[A-Z]{3,}\b"#) else { return [:] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.matches(in: value, range: range).reduce(into: [:]) { result, match in
            let word = (value as NSString).substring(with: match.range)
            result[word, default: 0] += 1
        }
    }

    private static func adjacentRepeatedWordCounts(in value: String) -> [String: Int] {
        guard let expression = try? NSRegularExpression(pattern: #"\b([A-Za-z][A-Za-z'-]*)\s+\1\b"#, options: .caseInsensitive) else { return [:] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.matches(in: value, range: range).reduce(into: [:]) { result, match in
            guard match.numberOfRanges > 1 else { return }
            let word = (value as NSString).substring(with: match.range(at: 1)).lowercased()
            result[word, default: 0] += 1
        }
    }

    static func isSafeDocumentReplacement(_ source: String, _ replacement: String) -> Bool {
        let boundarySafe: Bool
        if replacement.isEmpty {
            // An empty replacement is valid only when the complete target is
            // punctuation. This makes `find: "!!!", replacement: ""` an
            // explicit punctuation edit while preventing accidental word or
            // separator deletion.
            boundarySafe = !source.isEmpty
                && !source.contains("\n")
                && !source.contains("\r")
                && source.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
        } else {
            boundarySafe = isSafeAnchoredReplacement(source, replacement)
        }
        guard boundarySafe,
              !replacement.contains("\n\n\n"),
              markdownStructure(source) == markdownStructure(replacement),
              immutableMarkdownSegments(source) == immutableMarkdownSegments(replacement) else { return false }

        let sourceSeparators = internalWordSeparatorWhitespaceCount(in: source)
        let replacementSeparators = internalWordSeparatorWhitespaceCount(in: replacement)
        // A document edit must not silently collapse spaces between words. The
        // provider may nominate whitespace explicitly in `find`, but even then
        // the conservative proofread path preserves the original separator.
        guard replacementSeparators >= sourceSeparators else { return false }

        let sourcePunctuation = source.unicodeScalars.filter { CharacterSet.punctuationCharacters.contains($0) }.count
        let replacementPunctuation = replacement.unicodeScalars.filter { CharacterSet.punctuationCharacters.contains($0) }.count
        let removedPunctuation = sourcePunctuation - replacementPunctuation
        let isExplicitPunctuationTarget = !source.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains)
        guard removedPunctuation <= 1 || isExplicitPunctuationTarget else { return false }
        return true
    }

    private static func internalWordSeparatorWhitespaceCount(in value: String) -> Int {
        let scalars = Array(value.unicodeScalars)
        guard !scalars.isEmpty else { return 0 }
        var count = 0
        var index = 0
        while index < scalars.count {
            guard CharacterSet.whitespacesAndNewlines.contains(scalars[index]) else {
                index += 1
                continue
            }
            let start = index
            while index < scalars.count && CharacterSet.whitespacesAndNewlines.contains(scalars[index]) {
                index += 1
            }
            guard start > 0, index < scalars.count,
                  CharacterSet.alphanumerics.contains(scalars[start - 1]),
                  CharacterSet.alphanumerics.contains(scalars[index]) else { continue }
            count += index - start
        }
        return count
    }

    static func containsContextPlaceholder(_ value: String) -> Bool {
        let pattern = #"\[(?:URL|EMAIL|CODE|PATH|VERSION|ACRONYM|NAME|TERM)_[0-9]+\]"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    static func intersectsContextPlaceholder(_ range: NSRange, in source: String) -> Bool {
        let pattern = #"\[(?:URL|EMAIL|CODE|PATH|VERSION|ACRONYM|NAME|TERM)_[0-9]+\]"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return true }
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression.matches(in: source, range: fullRange).contains { NSIntersectionRange($0.range, range).length > 0 }
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
