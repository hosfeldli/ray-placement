import AppKit
import Foundation

public struct WritingIssue: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case spelling = "Spelling"
        case grammar = "Grammar"
    }

    public let id: String
    public let kind: Kind
    public let range: NSRange
    public let original: String
    public let message: String
    public let suggestions: [String]

    public init(kind: Kind, range: NSRange, original: String, message: String, suggestions: [String]) {
        self.kind = kind
        self.range = range
        self.original = original
        self.message = message
        self.suggestions = suggestions
        self.id = "\(kind.rawValue)-\(range.location)-\(range.length)-\(original)"
    }
}

public struct WritingReview: Equatable, Sendable {
    public let sourceText: String
    public let suggestedText: String
    public let issues: [WritingIssue]

    public init(sourceText: String, suggestedText: String, issues: [WritingIssue]) {
        self.sourceText = sourceText
        self.suggestedText = suggestedText
        self.issues = issues
    }

    public var hasSuggestedChanges: Bool { suggestedText != sourceText }
}

public final class WritingCheckService {
    public enum CheckError: LocalizedError {
        case emptyText
        case textTooLong(Int)
        case invalidProviderResponse

        public var errorDescription: String? {
            switch self {
            case .emptyText:
                return "Select some text, then run Check Spelling & Grammar again."
            case .textTooLong(let limit):
                return "Writing checks are limited to \(limit.formatted()) characters at a time."
            case .invalidProviderResponse:
                return "The local writing engine returned an unreadable response."
            }
        }
    }

    public let characterLimit = 50_000

    public init() {}

    public func review(sourceText: String, harperJSON: Data) throws -> WritingReview {
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CheckError.emptyText
        }
        guard sourceText.count <= characterLimit else { throw CheckError.textTooLong(characterLimit) }

        let files: [HarperFileResult]
        do {
            files = try JSONDecoder().decode([HarperFileResult].self, from: harperJSON)
        } catch {
            throw CheckError.invalidProviderResponse
        }

        let issues = files.flatMap(\.lints).compactMap { lint -> WritingIssue? in
            guard let range = utf16Range(in: sourceText, start: lint.span.charStart, end: lint.span.charEnd) else {
                return nil
            }
            let original = (sourceText as NSString).substring(with: range)
            let suggestions = lint.suggestions.compactMap(parseHarperSuggestion)
            let lowerKind = lint.kind.lowercased()
            let lowerRule = lint.rule.lowercased()
            let kind: WritingIssue.Kind = lowerKind.contains("spell") || lowerRule.contains("spell")
                ? .spelling
                : .grammar
            return WritingIssue(
                kind: kind,
                range: range,
                original: original,
                message: lint.message,
                suggestions: Array(suggestions.prefix(5))
            )
        }.sorted {
            if $0.range.location == $1.range.location { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.range.location < $1.range.location
        }

        return WritingReview(
            sourceText: sourceText,
            suggestedText: applyingSuggestions(to: sourceText, issues: issues),
            issues: issues
        )
    }

    public func review(
        sourceText: String,
        rewrittenText: String,
        engineTitle: String = "local writing checker"
    ) throws -> WritingReview {
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CheckError.emptyText
        }
        let rewritten = rewrittenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rewritten.isEmpty else { throw CheckError.invalidProviderResponse }
        guard sourceText != rewritten else {
            return WritingReview(sourceText: sourceText, suggestedText: sourceText, issues: [])
        }

        let difference = differingRange(source: sourceText, suggestion: rewritten)
        let issue = WritingIssue(
            kind: .grammar,
            range: difference.sourceRange,
            original: difference.original.isEmpty ? "Insertion" : difference.original,
            message: "Suggested correction from \(engineTitle)",
            suggestions: [difference.replacement]
        )
        return WritingReview(sourceText: sourceText, suggestedText: rewritten, issues: [issue])
    }

    public func normalizeRewrite(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("<CORRECTED>"), result.hasSuffix("</CORRECTED>") {
            result.removeFirst("<CORRECTED>".count)
            result.removeLast("</CORRECTED>".count)
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if result.hasPrefix("Corrected text:") {
            result.removeFirst("Corrected text:".count)
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Even capable local models occasionally preserve a semicolon after a
        // greeting. A greeting is not an independent clause, so normalize it.
        if let expression = try? NSRegularExpression(
            pattern: #"^(\s*(?:hi|hello|hey))\s*;\s+"#,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "$1, "
            )
        }
        return result
    }

    /// Gives the local rule pipeline a final high-confidence punctuation pass.
    public func normalizeProofreadRewrite(_ text: String) -> String {
        var result = normalizeRewrite(text)
        result = replacing(
            #"\bwhere\s+(you|we|they)\s+([\p{L}'’-]+ing)\b"#,
            in: result,
            with: "were $1 $2",
            options: [.caseInsensitive]
        )
        result = replacing(
            #",\s+(about|for|to|with|from|of|in|on)(?=\s*(?:[?.!]|$))"#,
            in: result,
            with: " $1",
            options: [.caseInsensitive]
        )
        result = replacing(#"[ \t]+([,.;:!?])"#, in: result, with: "$1")
        result = replacing(#"[ \t]{2,}"#, in: result, with: " ")

        let interrogativeGreeting = #"^(?:hi|hello|hey),\s+(?:what|why|where|when|who|whom|whose|how|which|do|does|did|are|is|can|could|would|will|should)\b"#
        if let expression = try? NSRegularExpression(pattern: interrogativeGreeting, options: [.caseInsensitive]),
           expression.firstMatch(in: result, range: NSRange(result.startIndex..<result.endIndex, in: result)) != nil,
           let last = result.last,
           !"?.!".contains(last) {
            result.append("?")
        }
        return result
    }

    public func normalizeProofreadRewrite(_ text: String, preservingBoundaryFrom source: String) -> String {
        let corrected = normalizeProofreadRewrite(text)
        let leading = source.prefix { $0.isWhitespace }
        let trailing = source.reversed().prefix { $0.isWhitespace }.reversed()
        return String(leading) + corrected + String(trailing)
    }

    func applyingSuggestions(to text: String, issues: [WritingIssue]) -> String {
        let mutable = NSMutableString(string: text)
        var occupiedRanges: [NSRange] = []
        for issue in issues.reversed() {
            guard let suggestion = issue.suggestions.first,
                  suggestion != issue.original,
                  NSMaxRange(issue.range) <= mutable.length,
                  !occupiedRanges.contains(where: { NSIntersectionRange($0, issue.range).length > 0 }) else { continue }
            mutable.replaceCharacters(in: issue.range, with: suggestion)
            occupiedRanges.append(issue.range)
        }
        return mutable as String
    }

    private func utf16Range(in text: String, start: Int, end: Int) -> NSRange? {
        guard start >= 0, end >= start else { return nil }
        let scalars = text.unicodeScalars
        guard let scalarStart = scalars.index(scalars.startIndex, offsetBy: start, limitedBy: scalars.endIndex),
              let scalarEnd = scalars.index(scalars.startIndex, offsetBy: end, limitedBy: scalars.endIndex),
              let stringStart = scalarStart.samePosition(in: text),
              let stringEnd = scalarEnd.samePosition(in: text) else { return nil }
        return NSRange(stringStart..<stringEnd, in: text)
    }

    private func parseHarperSuggestion(_ raw: String) -> String? {
        if raw.localizedCaseInsensitiveContains("remove") { return "" }
        if let opening = raw.firstIndex(of: "“"),
           let closing = raw[raw.index(after: opening)...].firstIndex(of: "”") {
            return String(raw[raw.index(after: opening)..<closing])
        }
        if let opening = raw.firstIndex(of: "\""),
           let closing = raw[raw.index(after: opening)...].firstIndex(of: "\"") {
            return String(raw[raw.index(after: opening)..<closing])
        }
        return nil
    }

    private func replacing(
        _ pattern: String,
        in source: String,
        with template: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return source }
        return expression.stringByReplacingMatches(
            in: source,
            range: NSRange(source.startIndex..<source.endIndex, in: source),
            withTemplate: template
        )
    }

    private func differingRange(source: String, suggestion: String) -> (sourceRange: NSRange, original: String, replacement: String) {
        var sourceStart = source.startIndex
        var suggestionStart = suggestion.startIndex
        while sourceStart < source.endIndex,
              suggestionStart < suggestion.endIndex,
              source[sourceStart] == suggestion[suggestionStart] {
            source.formIndex(after: &sourceStart)
            suggestion.formIndex(after: &suggestionStart)
        }

        var sourceEnd = source.endIndex
        var suggestionEnd = suggestion.endIndex
        while sourceEnd > sourceStart, suggestionEnd > suggestionStart {
            let priorSource = source.index(before: sourceEnd)
            let priorSuggestion = suggestion.index(before: suggestionEnd)
            guard source[priorSource] == suggestion[priorSuggestion] else { break }
            sourceEnd = priorSource
            suggestionEnd = priorSuggestion
        }

        return (
            NSRange(sourceStart..<sourceEnd, in: source),
            String(source[sourceStart..<sourceEnd]),
            String(suggestion[suggestionStart..<suggestionEnd])
        )
    }
}

private struct HarperFileResult: Decodable {
    let lints: [HarperLint]
}

private struct HarperLint: Decodable {
    struct Span: Decodable {
        let charStart: Int
        let charEnd: Int

        enum CodingKeys: String, CodingKey {
            case charStart = "char_start"
            case charEnd = "char_end"
        }
    }

    let rule: String
    let kind: String
    let span: Span
    let message: String
    let suggestions: [String]
}

public enum PlainTextPasteboardService {
    public enum PasteboardError: LocalizedError {
        case noText

        public var errorDescription: String? {
            "The clipboard does not contain text to paste."
        }
    }

    @discardableResult
    public static func rewriteAsPlainText(_ pasteboard: NSPasteboard = .general) throws -> String {
        try rewriteAsPlainText(pasteboard as any PlainTextPasteboard)
    }

    @discardableResult
    static func rewriteAsPlainText(_ pasteboard: any PlainTextPasteboard) throws -> String {
        guard let text = pasteboard.string(forType: .string) else { throw PasteboardError.noText }
        _ = pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { throw PasteboardError.noText }
        return text
    }
}

protocol PlainTextPasteboard: AnyObject {
    func string(forType dataType: NSPasteboard.PasteboardType) -> String?
    func clearContents() -> Int
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
}

extension NSPasteboard: PlainTextPasteboard {}
