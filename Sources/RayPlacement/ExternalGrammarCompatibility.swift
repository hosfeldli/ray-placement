import RayPlacementWriting

/// Deterministic, provider-facing smoke validation for the external grammar
/// contract. It intentionally checks only high-confidence corrections and
/// byte-sensitive invariants; stylistic rewrites are not part of compatibility.
enum ExternalGrammarCompatibility {
    static let corpus = "This are wrong. I dont know. Hello world. Hello  world. Hello, world! Lima are ready. See https://example.com/a?x=1 today."

    static func validate(
        source: String,
        protected: StealthProtectedText,
        edits: [StealthGrammarDocumentChange]
    ) -> Bool {
        let report = protected.applyingDocumentChanges(edits)
        let corrected = report.text
        let url = "https://example.com/a?x=1"

        guard report.appliedCount >= 2,
              corrected.contains("This is wrong."),
              corrected.contains("I don't know."),
              corrected.contains("Hello world."),
              corrected.contains("Hello  world."),
              corrected.contains("Hello, world!"),
              corrected.contains("Lima is ready."),
              corrected.components(separatedBy: url).count == 2,
              !corrected.contains("[NAME_"),
              !corrected.contains("[URL_"),
              StealthGrammarService.isSafeReplacement(source, corrected) else {
            return false
        }
        return true
    }
}
