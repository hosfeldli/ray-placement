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

@Test func writingCheckRejectsEmptyInput() {
    #expect(throws: WritingCheckService.CheckError.self) {
        try WritingCheckService().check("   \n")
    }
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

@Test func int8RewriteCreatesFocusedDifference() throws {
    let review = try WritingCheckService().review(
        sourceText: "This are a bad sentence.",
        rewrittenText: "This is a bad sentence."
    )

    #expect(review.issues.count == 1)
    #expect(review.suggestedText == "This is a bad sentence.")
    #expect(review.hasSuggestedChanges)
}

@Test func deepRewriteNormalizesDifficultGreeting() throws {
    let service = WritingCheckService()
    let source = "Hi; whot where you thinking, about"
    let modelOutput = "Hi; what are you thinking about?"
    let normalized = service.normalizeModelRewrite(modelOutput)
    #expect(normalized == "Hi, what are you thinking about?")

    let review = try service.review(
        sourceText: source,
        rewrittenText: normalized,
        providerTitle: WritingProvider.qwen3Deep.title
    )
    #expect(review.suggestedText == "Hi, what are you thinking about?")
    #expect(review.hasSuggestedChanges)
    #expect(review.issues.first?.message.contains("Qwen3 1.7B Q8") == true)
}

@Test func qualityFloorCorrectsTheFullHighlightedSentence() throws {
    let service = WritingCheckService()
    let source = "Hi; whot where you thinking, about"
    let harperJSON = #"[{"file":"<stdin>","lint_count":1,"lints":[{"rule":"SpellCheck","kind":"Spelling","span":{"char_start":4,"char_end":8},"line":1,"column":5,"message":"Possible misspelling","priority":63,"suggestions":["Replace with: “what”"],"matched_text":"whot"}]}]"#.data(using: .utf8)!

    let harperReview = try service.review(sourceText: source, harperJSON: harperJSON)
    let corrected = service.normalizeProofreadRewrite(harperReview.suggestedText)

    #expect(corrected == "Hi, what were you thinking about?")
    #expect(
        service.normalizeProofreadRewrite(
            "Hi, what were you thinking about?",
            preservingBoundaryFrom: "\n  \(source)  \n"
        ) == "\n  Hi, what were you thinking about?  \n"
    )
}
