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



@Test func structuredGrammarEditsApplyValidUTF16Replacement() throws {
    let source = "This are a café."
    let start = (source as NSString).range(of: "are").location
    let result = try StealthGrammarService.apply(
        [StealthGrammarEdit(start: start, length: 3, replacement: "is")],
        to: source
    )

    #expect(result == "This is a café.")
}

@Test func structuredGrammarEditsRejectOutOfRangeEdits() {
    #expect(throws: StealthGrammarEditError.invalidRange) {
        try StealthGrammarService.apply(
            [StealthGrammarEdit(start: 100, length: 1, replacement: "x")],
            to: "Short text"
        )
    }
}

@Test func structuredGrammarEditsRejectOverlappingEditsAndDuplicateInsertions() {
    #expect(throws: StealthGrammarEditError.overlappingEdits) {
        try StealthGrammarService.apply([
            StealthGrammarEdit(start: 0, length: 4, replacement: "A"),
            StealthGrammarEdit(start: 2, length: 2, replacement: "B")
        ], to: "abcd")
    }
    #expect(throws: StealthGrammarEditError.overlappingEdits) {
        try StealthGrammarService.apply([
            StealthGrammarEdit(start: 1, length: 0, replacement: "A"),
            StealthGrammarEdit(start: 1, length: 0, replacement: "B")
        ], to: "abcd")
    }
}

@Test func structuredGrammarEditsRejectProtectedTokenChanges() {
    let protected = StealthGrammarService.protect(
        "Keep https://example.com unchanged.",
        ignoreList: ""
    )
    let tokenStart = (protected.maskedText as NSString).range(of: "\u{E000}LIMA_KEEP_").location

    #expect(throws: StealthGrammarEditError.protectedTextChanged) {
        try StealthGrammarService.apply(
            [StealthGrammarEdit(start: tokenStart, length: 1, replacement: "X")],
            to: protected.maskedText
        )
    }
}

@Test func structuredGrammarEditsSupportSafeInsertion() throws {
    let source = "This is a sentence"
    let result = try StealthGrammarService.apply(
        [StealthGrammarEdit(start: (source as NSString).length, length: 0, replacement: ".")],
        to: source
    )

    #expect(result == "This is a sentence.")
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

@Test func technicalCorpusProtectsNamesAcronymsURLsPathsAndCode() {
    let source = "Lima sends EDI/TMS data through https://example.com/api/v3, writes to /Users/liam/project/config.json, and preserves `swift test` plus Liam's APIKey."
    let protected = StealthGrammarService.protect(
        source,
        ignoreList: "Lima EDI TMS APIKey"
    )

    #expect(protected.restore(protected.maskedText) == source)
    #expect(!protected.maskedText.contains("https://example.com/api/v3"))
    #expect(!protected.maskedText.contains("/Users/liam/project/config.json"))
    #expect(!protected.maskedText.contains("swift test"))
    #expect(protected.protectedValues.contains { $0.contains("EDI") && $0.contains("TMS") })
    #expect(protected.protectedValues.contains("APIKey"))
}

@Test func technicalCorpusDoesNotTreatCorrectProseAsUnsafeRewrite() {
    let source = "The local checker leaves already-correct prose unchanged."

    #expect(StealthGrammarService.isSafeReplacement(source, source))
    let chatty = "Here is the corrected text: The local checker leaves already-correct prose unchanged."
    #expect(!StealthGrammarService.isSafeReplacement(source, chatty))
    #expect(StealthGrammarService.isChattyResponse(chatty))
}

@Test func safeReplacementRejectsExpansionAndLargeEdits() {
    let source = "Fix the typo."
    let generated = "Fix the typo. Here is a lengthy explanation of the changes I made and why they are helpful."
    let unrelated = "A completely different paragraph about another subject."

    #expect(!StealthGrammarService.isSafeReplacement(source, generated))
    #expect(!StealthGrammarService.isSafeReplacement(source, unrelated))
}

@Test func safeReplacementPreservesMarkdownAndCodeStructure() {
    let source = "# Deploy Lima\n\nRun `swift test` before release.\n\n[Docs](https://example.com/docs)"
    let valid = "# Deploy Lima\n\nRun `swift test` before release!\n\n[Docs](https://example.com/docs)"
    let changedCode = "# Deploy Lima\n\nRun `swift build` before release!\n\n[Docs](https://example.com/docs)"
    let changedLink = "# Deploy Lima\n\nRun `swift test` before release!\n\n[Docs](https://example.com/other)"

    #expect(StealthGrammarService.isSafeReplacement(source, valid))
    #expect(!StealthGrammarService.isSafeReplacement(source, changedCode))
    #expect(!StealthGrammarService.isSafeReplacement(source, changedLink))
}

@Test func protectedTextRejectsTokenMutationAndReordering() {
    let source = "keep Lima and https://example.com exactly unchanged."
    let protected = StealthGrammarService.protect(source, ignoreList: "Lima")
    let tokens = protected.maskedText
        .split(separator: " ")
        .filter { $0.contains("LIMA_KEEP_") }
        .map(String.init)
    #expect(tokens.count == 2)

    let mutated = protected.maskedText.replacingOccurrences(of: "LIMA_KEEP_", with: "LIMA_CHANGED_")
    #expect(protected.restore(mutated) == nil)

    let reversed = protected.maskedText.replacingOccurrences(of: tokens[0], with: "__TEMP__")
        .replacingOccurrences(of: tokens[1], with: tokens[0])
        .replacingOccurrences(of: "__TEMP__", with: tokens[1])
    #expect(protected.restore(reversed) == nil)
}


@Test func editableGrammarSegmentsExcludeProtectedValuesAndMapByID() throws {
    let source = "This are a grammer sentence with Lima and https://example.com."
    let protected = StealthGrammarService.protect(source, ignoreList: "Lima")
    let segments = protected.editableSegments()

    #expect(segments.count == 2)
    #expect(segments.allSatisfy { !$0.text.contains("Lima") && !$0.text.contains("https://") })
    #expect(segments.map(\.id) == ["s0", "s1"])

    let corrected = try protected.apply([
        StealthGrammarSegmentCorrection(id: "s0", corrected: "This is a grammar sentence with ")
    ])
    #expect(corrected == "This is a grammar sentence with Lima and https://example.com.")
}

@Test func editableGrammarSegmentsRejectUnknownIDs() {
    let protected = StealthGrammarService.protect("This is text.", ignoreList: "")
    #expect(throws: StealthGrammarEditError.invalidRange) {
        _ = try protected.apply([StealthGrammarSegmentCorrection(id: "unknown", corrected: "changed")])
    }
}


@Test func anchoredGrammarEditsRejectAmbiguousMatchesAndHonorContext() throws {
    let segments = [StealthEditableSegment(id: "s0", text: "This is a test. This is another test.", start: 0, length: 37)]
    #expect(throws: StealthGrammarEditError.invalidRange) {
        try StealthGrammarService.apply([
            StealthGrammarAnchoredChange(segmentID: "s0", find: "test", replacement: "check")
        ], segments: segments, to: segments[0].text)
    }
    let result = try StealthGrammarService.apply([
        StealthGrammarAnchoredChange(segmentID: "s0", find: "test", replacement: "check", before: "a ", after: ".")
    ], segments: segments, to: segments[0].text)
    #expect(result == "This is a check. This is another test.")
}

@Test func anchoredGrammarEditsPreserveWhitespaceBoundaries() {
    let segments = [StealthEditableSegment(id: "s0", text: "Fix teh typo", start: 0, length: 12)]
    #expect(throws: StealthGrammarEditError.unsafeReplacement) {
        try StealthGrammarService.apply([
            StealthGrammarAnchoredChange(segmentID: "s0", find: "teh", replacement: " teh ")
        ], segments: segments, to: segments[0].text)
    }
}

@Test func writingReviewCanRejectOneOfSeveralChanges() {
    let source = "teh eror"
    let issues = [
        WritingIssue(kind: .spelling, range: NSRange(location: 0, length: 3), original: "teh", message: "", suggestions: ["the"]),
        WritingIssue(kind: .spelling, range: NSRange(location: 4, length: 4), original: "eror", message: "", suggestions: ["error"])
    ]
    let review = WritingReview(sourceText: source, suggestedText: "the error", issues: issues)
    #expect(review.applying([issues[0].id], rejecting: [issues[1].id]).suggestedText == "the eror")
}
