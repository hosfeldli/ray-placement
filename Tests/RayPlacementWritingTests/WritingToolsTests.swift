import AppKit
import Testing
@testable import RayPlacementWriting

@Test func plainTextPasteboardStripsRichRepresentations() throws {
    let pasteboard = FakePasteboard(text: "Plain words")

    let text = try PlainTextPasteboardService.rewriteAsPlainText(pasteboard)

    #expect(text == "Plain words")
    #expect(pasteboard.didClear)
    #expect(pasteboard.writtenText == "Plain words")
    #expect(pasteboard.writtenType == .string)
}

private final class FakePasteboard: PlainTextPasteboard {
    private let text: String?
    private(set) var didClear = false
    private(set) var writtenText: String?
    private(set) var writtenType: NSPasteboard.PasteboardType?

    init(text: String?) {
        self.text = text
    }

    func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        dataType == .string ? text : nil
    }

    func clearContents() -> Int {
        didClear = true
        return 1
    }

    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        writtenText = string
        writtenType = dataType
        return true
    }
}

@Test func writingCheckAppliesSuggestionsWithoutShiftingEarlierRanges() {
    let text = "A mistke and an eror."
    let issues = [
        WritingIssue(kind: .spelling, range: NSRange(location: 2, length: 6), original: "mistke", message: "Possible misspelling", suggestions: ["mistake"]),
        WritingIssue(kind: .spelling, range: NSRange(location: 16, length: 4), original: "eror", message: "Possible misspelling", suggestions: ["error"])
    ]

    let result = WritingCheckService().applyingSuggestions(to: text, issues: issues)

    #expect(result == "A mistake and an error.")
}

@Test func harperJSONCreatesDetailedReview() throws {
    let source = "I has an apple."
    let json = #"[{"file":"<stdin>","lint_count":1,"lints":[{"rule":"PronounVerbAgreement","kind":"Agreement","span":{"char_start":2,"char_end":5},"line":1,"column":3,"message":"The verb must agree with the pronoun.","priority":127,"suggestions":["Replace with: “have”"],"matched_text":"has"}]}]"#.data(using: .utf8)!

    let review = try WritingCheckService().review(sourceText: source, harperJSON: json)

    #expect(review.issues.count == 1)
    #expect(review.issues.first?.original == "has")
    #expect(review.issues.first?.suggestions == ["have"])
    #expect(review.suggestedText == "I have an apple.")
}

@Test func ruleBasedRewriteCreatesFocusedDifference() throws {
    let review = try WritingCheckService().review(
        sourceText: "This are a bad sentence.",
        rewrittenText: "This is a bad sentence."
    )

    #expect(review.issues.count == 1)
    #expect(review.suggestedText == "This is a bad sentence.")
    #expect(review.hasSuggestedChanges)
}


@Test func stealthProtectionPreservesRiskyTermsAndIgnoreListPhrases() {
    let source = "  This are a grammer sentence about RayPlacement API at https://example.com/a?x=1, with /Users/liam/project and Lima editor.  "
    let protected = StealthGrammarService.protect(
        source,
        ignoreList: "RayPlacement API\nLima editor"
    )

    #expect(protected.maskedText.contains("\u{E000}LIMA_KEEP_"))
    #expect(!protected.maskedText.contains("https://example.com"))
    #expect(!protected.maskedText.contains("RayPlacement"))
    #expect(protected.restore(protected.maskedText) == source)
}

@Test func stealthProtectionRestoresEveryProtectedValueExactlyOnce() {
    let source = "RayPlacement API https://example.com/a?x=1 /Users/liam/project v3.12.1"
    let protected = StealthGrammarService.protect(source, ignoreList: "RayPlacement")

    let restored = protected.restore(protected.maskedText)

    #expect(restored == source)
    #expect(protected.protectedValues.contains("RayPlacement"))
    #expect(protected.protectedValues.contains("API"))
    #expect(protected.protectedValues.contains("https://example.com/a?x=1"))
    #expect(protected.protectedValues.contains("/Users/liam/project"))
    #expect(protected.protectedValues.contains("v3.12.1"))
}

@Test func stealthProtectionRejectsMalformedOrDangerousReplacement() {
    let source = "This is a sentence.\nAnother line."

    #expect(StealthGrammarService.isSafeReplacement(source, "This was a sentence.\nAnother line."))
    #expect(!StealthGrammarService.isSafeReplacement(source, ""))
    #expect(!StealthGrammarService.isSafeReplacement(source, "```text\nThis was a sentence.\nAnother line.\n```"))
    #expect(!StealthGrammarService.isSafeReplacement(source, "This was a sentence."))
}

@Test func stealthProtectionRestoresWhitespaceOnlyInputWithoutDuplication() {
    let source = "  \n\t  "
    let protected = StealthGrammarService.protect(source, ignoreList: "")

    #expect(protected.restore(protected.maskedText) == source)
}

@Test func stealthProtectionUsesNonLinguisticCollisionSafeTokens() {
    let source = "The literal \u{E000}LIMA_KEEP_0000_\u{E001} stays, while API and https://example.com remain protected."
    let protected = StealthGrammarService.protect(source, ignoreList: "API")

    #expect(protected.maskedText.contains("\u{E000}LIMA_KEEP_0001_\u{E001}"))
    #expect(protected.restore(protected.maskedText) == source)
}


@Test func providerNormalizationRemovesOnlyTransportWrappers() {
    let service = WritingCheckService()
    #expect(service.normalizeRewrite("<CORRECTED>Hi; there</CORRECTED>") == "Hi, there")
    #expect(service.normalizeRewrite("\"This is quoted prose.\"") == "This is quoted prose.")
    #expect(service.normalizeRewrite("He said \"hello\".") == "He said \"hello\".")
}
