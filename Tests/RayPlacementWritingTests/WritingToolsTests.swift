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


@Test func documentGrammarChangesReplaceAcrossProtectedContext() {
    let source = "This are a grammer sentence with Lima and https://example.com."
    let protected = StealthGrammarService.protect(source, ignoreList: "Lima")
    let report = protected.applyingDocumentChanges([
        StealthGrammarDocumentChange(find: "are", replacement: "is", before: "This ", after: " a"),
        StealthGrammarDocumentChange(find: "grammer", replacement: "grammar", before: "a ", after: " sentence")
    ])

    #expect(report.text == "This is a grammar sentence with Lima and https://example.com.")
    #expect(report.appliedCount == 2)
    #expect(report.rejectedCount == 0)
}

@Test func documentGrammarChangesRequireAnchorsForShortFinds() {
    let protected = StealthGrammarService.protect("This are repeated. Those are repeated.", ignoreList: "")
    let report = protected.applyingDocumentChanges([
        StealthGrammarDocumentChange(find: "are", replacement: "is"),
        StealthGrammarDocumentChange(find: "are", replacement: "is", before: "This ", after: " repeated")
    ])

    #expect(report.text == "This is repeated. Those are repeated.")
    #expect(report.appliedCount == 1)
    #expect(report.rejectedCount == 1)
}

@Test func documentGrammarSanityRejectsDuplicationAndCapitalizationExplosions() {
    let duplicateSource = "The application works."
    let duplicateProtected = StealthGrammarService.protect(duplicateSource, ignoreList: "")
    let duplicateReport = duplicateProtected.applyingDocumentChanges([
        StealthGrammarDocumentChange(
            find: "application",
            replacement: "application application",
            before: "The ",
            after: " works"
        )
    ])
    #expect(duplicateReport.text == duplicateSource)
    #expect(duplicateReport.appliedCount == 0)
    #expect(duplicateReport.rejectedCount == 1)

    let capitalizationSource = "This is fine."
    let capitalizationProtected = StealthGrammarService.protect(capitalizationSource, ignoreList: "")
    let capitalizationReport = capitalizationProtected.applyingDocumentChanges([
        StealthGrammarDocumentChange(find: "This", replacement: "THIS", after: " is")
    ])
    #expect(capitalizationReport.text == capitalizationSource)
    #expect(capitalizationReport.appliedCount == 0)
    #expect(capitalizationReport.rejectedCount == 1)
}

@Test func sentenceInitialCapitalizationIsNotAutomaticallyProtected() {
    let protected = StealthGrammarService.protect(
        "Apple are ready. The API is available.",
        ignoreList: ""
    )

    #expect(!protected.contextText.contains("[NAME_0] are ready."))
    #expect(protected.contextText.contains("[ACRONYM_0] is available."))
    #expect(protected.restoreContext(protected.contextText) == "Apple are ready. The API is available.")
}

@Test func documentGrammarChangesRejectOversizedOrSentenceWideEdits() {
    let source = "This is a short sentence. Another sentence follows."
    let protected = StealthGrammarService.protect(source, ignoreList: "")
    let longFind = String(repeating: "word ", count: 16).trimmingCharacters(in: .whitespaces)
    let report = protected.applyingDocumentChanges([
        StealthGrammarDocumentChange(find: longFind, replacement: "short"),
        StealthGrammarDocumentChange(
            find: "This is a short sentence. Another sentence follows.",
            replacement: "A rewritten paragraph."
        )
    ])

    #expect(report.text == source)
    #expect(report.appliedCount == 0)
    #expect(report.rejectedCount == 2)
}

@Test func documentGrammarChangesPreserveContextProtectedValuesAndWhitespace() {
    let cases = [
        ("This are wrong.", "This is wrong."),
        ("I dont know.", "I don't know.")
    ]
    for (source, expected) in cases {
        let protected = StealthGrammarService.protect(source, ignoreList: "")
        let report = protected.applyingDocumentChanges([
            StealthGrammarDocumentChange(
                find: source == "This are wrong." ? "are" : "dont",
                replacement: source == "This are wrong." ? "is" : "don't",
                before: source == "This are wrong." ? "This " : "I ",
                after: source == "This are wrong." ? " wrong." : " know."
            )
        ])
        #expect(report.text == expected)
        #expect(report.appliedCount == 1)
    }

    let spacing = "Hello  world"
    let spacingProtected = StealthGrammarService.protect(spacing, ignoreList: "")
    #expect(spacingProtected.applyingDocumentChanges([]).text == spacing)

    let punctuation = "Hello, world!"
    let punctuationProtected = StealthGrammarService.protect(punctuation, ignoreList: "")
    #expect(punctuationProtected.applyingDocumentChanges([
        StealthGrammarDocumentChange(find: "world", replacement: "there", before: "Hello, ", after: "!")
    ]).text == "Hello, there!")
}

@Test func documentGrammarChangesPreserveNamesAndURLsByteForByte() {
    let source = "Lima are ready. See https://example.com/a?x=1 today."
    let protected = StealthGrammarService.protect(source, ignoreList: "Lima")
    #expect(protected.contextText.contains("[NAME_0]"))
    #expect(protected.contextText.contains("[URL_0]"))
    let result = protected.applyingDocumentChanges([
        StealthGrammarDocumentChange(find: "are ready", replacement: "is ready")
    ])
    #expect(result.text == "Lima is ready. See https://example.com/a?x=1 today.")
}

@Test func documentGrammarChangesApplyValidEditsAndSkipMalformedOrAmbiguousOnes() {
    let source = "This are wrong. This are repeated."
    let protected = StealthGrammarService.protect(source, ignoreList: "")
    let report = protected.applyingDocumentChanges([
        StealthGrammarDocumentChange(find: "are", replacement: "is", before: "This ", after: " wrong"),
        StealthGrammarDocumentChange(find: "are", replacement: "were"),
        StealthGrammarDocumentChange(find: "This are", replacement: ""),
        StealthGrammarDocumentChange(find: "[TERM_0]", replacement: "bad")
    ])
    #expect(report.text == "This is wrong. This are repeated.")
    #expect(report.appliedCount == 1)
    #expect(report.rejectedCount == 3)
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


@Test func deterministicExternalGrammarCompatibilityCorpusPreservesDocumentInvariants() {
    let source = "This are wrong. I dont know. He go to work every day. Hello, how are you? Hello world. Hello  world. Hello, world! Lima are ready. The API dont work. This is **very** good. - [ ] This are broken 😀. “This are quoted.” See https://example.com/a?x=1 today."
    let protected = StealthGrammarService.protect(source, ignoreList: "Lima")

    #expect(protected.contextText.contains("[NAME_0]"))
    #expect(protected.contextText.contains("[ACRONYM_0]"))
    #expect(protected.contextText.contains("[URL_0]"))
    #expect(protected.contextText.contains("[NAME_0] are ready."))
    #expect(protected.contextText.contains("https://") == false)
    #expect(protected.contextText.contains("Hello, how are you?"))
    #expect(protected.contextText.contains("This is **very** good."))
    #expect(protected.contextText.contains("😀"))
    #expect(protected.contextText.contains("“This are quoted.”"))

    let report = protected.applyingDocumentChanges([
        StealthGrammarDocumentChange(find: "are", replacement: "is", before: "This ", after: " wrong."),
        StealthGrammarDocumentChange(find: "dont", replacement: "don't", before: "I ", after: " know."),
        StealthGrammarDocumentChange(find: "go", replacement: "goes", before: "He ", after: " to"),
        StealthGrammarDocumentChange(find: "are", replacement: "is", before: "[NAME_0] ", after: " ready."),
        StealthGrammarDocumentChange(find: "dont", replacement: "doesn't", before: "[ACRONYM_0] ", after: " work."),
        StealthGrammarDocumentChange(find: "are", replacement: "is", before: "This ", after: " broken"),
        StealthGrammarDocumentChange(find: "are", replacement: "is", before: "This ", after: " quoted.")
    ])

    #expect(report.text == "This is wrong. I don't know. He goes to work every day. Hello, how are you? Hello world. Hello  world. Hello, world! Lima is ready. The API doesn't work. This is **very** good. - [ ] This is broken 😀. “This is quoted.” See https://example.com/a?x=1 today.")
    #expect(report.appliedCount == 7)
    #expect(report.rejectedCount == 0)
    #expect(report.text.components(separatedBy: "https://example.com/a?x=1").count == 2)
    #expect(report.text.contains("Hello world."))
    #expect(report.text.contains("Hello  world."))
    #expect(report.text.contains("Hello, world!"))
    #expect(report.text.contains("**very**"))
    #expect(report.text.contains("😀"))
    #expect(report.text.contains("“This is quoted.”"))
}

@Test func documentGrammarChangesRejectEmbeddedNewlines() {
    let source = "This is fine."
    let protected = StealthGrammarService.protect(source, ignoreList: "")
    let report = protected.applyingDocumentChanges([
        StealthGrammarDocumentChange(
            find: "is",
            replacement: "is\nvery",
            before: "This ",
            after: " fine."
        )
    ])

    #expect(report.text == source)
    #expect(report.appliedCount == 0)
    #expect(report.rejectedCount == 1)
}

@Test func documentGrammarAllowsOnlyExplicitPunctuationDeletion() {
    let protected = StealthGrammarService.protect("Keep this!!!", ignoreList: "")
    let report = protected.applyingDocumentChanges([
        StealthGrammarDocumentChange(find: "!!!", replacement: ""),
        StealthGrammarDocumentChange(find: " ", replacement: ""),
        StealthGrammarDocumentChange(find: "this", replacement: "this ")
    ])

    #expect(report.text == "Keep this")
    #expect(report.appliedCount == 1)
    #expect(report.rejectedCount == 2)
}

@Test func documentGrammarChangesRejectBoundaryAndStructuralDestruction() {
    let protected = StealthGrammarService.protect("Keep two words, punctuation!!!", ignoreList: "")

    let report = protected.applyingDocumentChanges([
        StealthGrammarDocumentChange(find: "two words", replacement: "twowords"),
        StealthGrammarDocumentChange(find: "punctuation!!!", replacement: "punctuation"),
        StealthGrammarDocumentChange(find: "Keep", replacement: "# Keep")
    ])

    #expect(report.appliedCount == 0)
    #expect(report.rejectedCount == 3)
    #expect(report.text == "Keep two words, punctuation!!!")
}
