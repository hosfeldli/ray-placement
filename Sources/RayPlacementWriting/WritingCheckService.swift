import AppKit
import Foundation

public enum WritingProvider: String, CaseIterable, Identifiable, Sendable {
    case harper
    case coeditInt8
    case qwen3Deep

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .harper: return "Harper"
        case .coeditInt8: return "T5-small CoEdit INT8"
        case .qwen3Deep: return "Qwen3 1.7B Q8 (Deep)"
        }
    }

    public var detail: String {
        switch self {
        case .harper:
            return "Fast rule-based grammar and spelling suggestions with detailed explanations."
        case .coeditInt8:
            return "A local 60.5M-parameter ONNX model that rewrites English text."
        case .qwen3Deep:
            return "A stronger 1.7B-parameter local proofreader. It loads only for a check, follows the CPU limit in Settings → Performance, has a time limit, and exits immediately afterward."
        }
    }
}

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

    public func check(_ text: String) throws -> WritingReview {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CheckError.emptyText
        }
        guard text.count <= characterLimit else { throw CheckError.textTooLong(characterLimit) }

        let checker = NSSpellChecker.shared
        let documentTag = NSSpellChecker.uniqueSpellDocumentTag()
        let language = checker.userPreferredLanguages.first ?? checker.availableLanguages.first
        defer { checker.closeSpellDocument(withTag: documentTag) }

        let source = text as NSString
        var issues = spellingIssues(in: text, source: source, checker: checker, documentTag: documentTag, language: language)
        issues.append(contentsOf: grammarIssues(in: text, source: source, checker: checker, documentTag: documentTag, language: language))
        issues.sort {
            if $0.range.location == $1.range.location { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.range.location < $1.range.location
        }

        return WritingReview(
            sourceText: text,
            suggestedText: applyingSuggestions(to: text, issues: issues),
            issues: issues
        )
    }

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
        providerTitle: String = "Local rewrite model"
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
            message: "Suggested rewrite from \(providerTitle)",
            suggestions: [difference.replacement]
        )
        return WritingReview(sourceText: sourceText, suggestedText: rewritten, issues: [issue])
    }

    public func normalizeModelRewrite(_ text: String) -> String {
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

    private func spellingIssues(
        in text: String,
        source: NSString,
        checker: NSSpellChecker,
        documentTag: Int,
        language: String?
    ) -> [WritingIssue] {
        var issues: [WritingIssue] = []
        var offset = 0

        while offset < source.length {
            var wordCount = 0
            let range = checker.checkSpelling(
                of: text,
                startingAt: offset,
                language: language,
                wrap: false,
                inSpellDocumentWithTag: documentTag,
                wordCount: &wordCount
            )
            guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= source.length else { break }
            let word = source.substring(with: range)
            let suggestions = Array((checker.guesses(
                forWordRange: range,
                in: text,
                language: language,
                inSpellDocumentWithTag: documentTag
            ) ?? []).prefix(5))
            issues.append(WritingIssue(
                kind: .spelling,
                range: range,
                original: word,
                message: "Possible misspelling",
                suggestions: suggestions
            ))
            offset = max(offset + 1, NSMaxRange(range))
        }
        return issues
    }

    private func grammarIssues(
        in text: String,
        source: NSString,
        checker: NSSpellChecker,
        documentTag: Int,
        language: String?
    ) -> [WritingIssue] {
        var issues: [WritingIssue] = []
        var offset = 0

        while offset < source.length {
            var rawDetails: NSArray?
            let sentenceRange = checker.checkGrammar(
                of: text,
                startingAt: offset,
                language: language,
                wrap: false,
                inSpellDocumentWithTag: documentTag,
                details: &rawDetails
            )
            guard sentenceRange.location != NSNotFound,
                  sentenceRange.length > 0,
                  NSMaxRange(sentenceRange) <= source.length else { break }

            let details = rawDetails as? [[String: Any]] ?? []
            for detail in details {
                let relativeRange = (detail[NSGrammarRange] as? NSValue)?.rangeValue
                    ?? NSRange(location: 0, length: sentenceRange.length)
                let range = NSRange(
                    location: sentenceRange.location + relativeRange.location,
                    length: relativeRange.length
                )
                guard range.location >= 0, range.length > 0, NSMaxRange(range) <= source.length else { continue }
                let original = source.substring(with: range)
                let message = detail[NSGrammarUserDescription] as? String ?? "Possible grammar issue"
                let corrections = Array((detail[NSGrammarCorrections] as? [String] ?? []).prefix(5))
                issues.append(WritingIssue(
                    kind: .grammar,
                    range: range,
                    original: original,
                    message: message,
                    suggestions: corrections
                ))
            }
            offset = max(offset + 1, NSMaxRange(sentenceRange))
        }
        return issues
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
