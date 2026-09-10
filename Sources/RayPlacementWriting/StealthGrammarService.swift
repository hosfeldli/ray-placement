import Foundation

/// Masks text that a correction engine must never rewrite. The mask is shared
/// by the local and optional developer BYOK paths so both paths have the same
/// safety boundary before a replacement is attempted.
public struct StealthProtectedText: Equatable, Sendable {
    public let maskedText: String
    public let leadingWhitespace: String
    public let trailingWhitespace: String
    private let replacements: [String: String]
    private let sourceBody: String
    private let protectedRanges: [NSRange]

    init(maskedText: String, leadingWhitespace: String, trailingWhitespace: String, replacements: [String: String], sourceBody: String = "", protectedRanges: [NSRange] = []) {
        self.maskedText = maskedText
        self.leadingWhitespace = leadingWhitespace
        self.trailingWhitespace = trailingWhitespace
        self.replacements = replacements
        self.sourceBody = sourceBody
        self.protectedRanges = protectedRanges
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

    public func apply(_ corrections: [StealthGrammarSegmentCorrection]) throws -> String {
        let correctedBody = try StealthGrammarService.apply(corrections, segments: editableSegments(), to: sourceBody)
        return leadingWhitespace + correctedBody + trailingWhitespace
    }

    public func apply(_ changes: [StealthGrammarAnchoredChange]) throws -> String {
        let correctedBody = try StealthGrammarService.apply(changes, segments: editableSegments(), to: sourceBody)
        return leadingWhitespace + correctedBody + trailingWhitespace
    }


    /// Returns editable spans in original UTF-16 coordinates. Protected values
    /// are omitted entirely; the model never receives sentinel tokens or ranges.
    public func editableSegments() -> [StealthEditableSegment] {
        guard !sourceBody.isEmpty else { return [] }
        let protected = protectedRanges.sorted { $0.location < $1.location }
        var result: [StealthEditableSegment] = []
        var cursor = 0
        var index = 0
        for range in protected {
            guard range.location >= cursor else { continue }
            let length = range.location - cursor
            if length > 0 {
                result.append(StealthEditableSegment(id: "s\(index)", text: (sourceBody as NSString).substring(with: NSRange(location: cursor, length: length)), start: cursor, length: length))
                index += 1
            }
            cursor = NSMaxRange(range)
        }
        if cursor < (sourceBody as NSString).length {
            let length = (sourceBody as NSString).length - cursor
            result.append(StealthEditableSegment(id: "s\(index)", text: (sourceBody as NSString).substring(with: NSRange(location: cursor, length: length)), start: cursor, length: length))
        }
        return result
    }
}


/// A local edit is expressed in UTF-16 offsets so Foundation can apply it
/// safely after a provider correction has been mapped by segment ID.
public struct StealthEditableSegment: Codable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let start: Int
    public let length: Int
    public init(id: String, text: String, start: Int, length: Int) {
        self.id = id; self.text = text; self.start = start; self.length = length
    }
}

public struct StealthGrammarSegmentCorrection: Codable, Equatable, Sendable {
    public let id: String
    public let corrected: String
    public init(id: String, corrected: String) { self.id = id; self.corrected = corrected }
}

/// A small, anchored proofread change. The provider chooses only the text to
/// replace; Lima locates it in the original segment and preserves everything
/// else byte-for-byte.
public struct StealthGrammarAnchoredChange: Codable, Equatable, Sendable {
    public let segmentID: String
    public let find: String
    public let replacement: String
    public let before: String?
    public let after: String?

    public init(segmentID: String, find: String, replacement: String, before: String? = nil, after: String? = nil) {
        self.segmentID = segmentID
        self.find = find
        self.replacement = replacement
        self.before = before
        self.after = after
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
            replacements: replacements,
            sourceBody: body,
            protectedRanges: merged
        )
    }


    /// Validates and applies provider edits to the exact text sent to the
    /// provider. Protected tokens are rejected before any replacement is made;
    /// the caller can then restore the protected values byte-for-byte.
    public static func apply(_ changes: [StealthGrammarAnchoredChange], segments: [StealthEditableSegment], to source: String) throws -> String {
        let byID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        var edits: [StealthGrammarEdit] = []
        var usedLocations = Set<String>()
        for change in changes {
            guard !change.find.isEmpty, let segment = byID[change.segmentID] else {
                throw StealthGrammarEditError.invalidRange
            }
            let segmentText = segment.text as NSString
            var searchStart = 0
            var matches: [NSRange] = []
            while searchStart <= segmentText.length {
                let range = segmentText.range(of: change.find, options: [], range: NSRange(location: searchStart, length: segmentText.length - searchStart))
                if range.location == NSNotFound { break }
                matches.append(range)
                searchStart = max(range.location + max(range.length, 1), searchStart + 1)
            }
            if let before = change.before {
                matches = matches.filter { range in
                    let start = max(0, range.location - (before as NSString).length)
                    return segmentText.substring(with: NSRange(location: start, length: range.location - start)) == before
                }
            }
            if let after = change.after {
                matches = matches.filter { range in
                    let end = min(segmentText.length, NSMaxRange(range) + (after as NSString).length)
                    return segmentText.substring(with: NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range))) == after
                }
            }
            guard matches.count == 1, let match = matches.first else {
                throw StealthGrammarEditError.invalidRange
            }
            let absolute = NSRange(location: segment.start + match.location, length: match.length)
            let key = "\(absolute.location):\(absolute.length)"
            guard usedLocations.insert(key).inserted else { throw StealthGrammarEditError.overlappingEdits }
            guard isSafeAnchoredReplacement(change.find, change.replacement) else {
                throw StealthGrammarEditError.unsafeReplacement
            }
            edits.append(StealthGrammarEdit(start: absolute.location, length: absolute.length, replacement: change.replacement))
        }
        return try apply(edits, to: source)
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
        return replacement.utf8.count <= max(128, source.utf8.count + 32)
    }

    public static func apply(_ corrections: [StealthGrammarSegmentCorrection], segments: [StealthEditableSegment], to source: String) throws -> String {
        let byID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        var edits: [StealthGrammarEdit] = []
        for correction in corrections {
            guard let segment = byID[correction.id] else { throw StealthGrammarEditError.invalidRange }
            guard isSafeReplacement(segment.text, correction.corrected) else { throw StealthGrammarEditError.unsafeReplacement }
            edits.append(StealthGrammarEdit(start: segment.start, length: segment.length, replacement: correction.corrected))
        }
        return try apply(edits, to: source)
    }

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

    private static func rangesOverlap(_ first: NSRange, _ second: NSRange) -> Bool {
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
