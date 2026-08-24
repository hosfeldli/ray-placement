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

@Test func aiPromptIncludesUserCorrectionRequirements() {
    let prompt = AIWritingPrompt.systemPrompt(
        customInstructions: "Keep RayPlacement and Qwen capitalized. Prefer US English."
    )
    #expect(prompt.contains("Correct the entire supplied passage"))
    #expect(prompt.contains("Keep RayPlacement and Qwen capitalized"))
    #expect(prompt.contains("Return only the fully corrected passage"))
}

@Test func aiResponseCleanupDoesNotApplyRuleBasedGrammarEdits() {
    let source = "\n  Hi; whot where you thinking, about  \n"
    let cleaned = AIWritingPrompt.cleanResponse(
        "Corrected text: Hi; whot where you thinking, about",
        preservingBoundaryFrom: source
    )
    #expect(cleaned == source)
}

@Test func qwenConsoleParserHandlesTruncatedLongPromptEcho() {
    let prompt = """
    # Document
    ST*990*A~B1*X*Y~SE*9*B~

    Correct every deterministic error and return only the complete corrected document.
    """
    let console = """
    Loading model...

    > # Document
    ST*990*A~B1*X*Y~SE*9*B~

    Correct every deterministic error and retu ... (truncated)
    ST*990*A~B1*X*Y~SE*3*A~

    [ Prompt: 190.0 t/s | Generation: 33.0 t/s ]

    Exiting...
    """

    #expect(QwenConsoleParser.response(from: console, prompt: prompt) == "ST*990*A~B1*X*Y~SE*3*A~")
}

@Test func qwenConsoleParserPreservesMultilineGeneratedDocument() {
    let prompt = "Format this JSON"
    let console = """
    > Format this JSON
    {
      "a": 1,
      "b": 2
    }

    [ Prompt: 100.0 t/s | Generation: 20.0 t/s ]
    """

    #expect(QwenConsoleParser.response(from: console, prompt: prompt) == "{\n  \"a\": 1,\n  \"b\": 2\n}")
}
