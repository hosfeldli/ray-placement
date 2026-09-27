import RayPlacementWriting

/// Deterministic, provider-facing smoke validation for the external grammar
/// contract. It intentionally checks only high-confidence corrections and
/// byte-sensitive invariants; stylistic rewrites are not part of compatibility.
enum ExternalGrammarCompatibility {
    static let corpus = "This are wrong. I dont know. He go to work every day. Hello, how are you? Hello world. Hello  world. Hello, world! Lima are ready. The API dont work. This is **very** good. - [ ] This are broken 😀. “This are quoted.” See https://example.com/a?x=1 today."

    static func validate(
        source: String,
        protected: StealthProtectedText,
        report: StealthGrammarApplyReport
    ) -> Bool {
        let corrected = report.text
        let url = "https://example.com/a?x=1"
        guard corrected.contains("This is wrong."),
              corrected.contains("I don't know."),
              corrected.contains("He goes to work every day."),
              corrected.contains("Hello, how are you?"),
              corrected.contains("Hello world."),
              corrected.contains("Hello  world."),
              corrected.contains("Hello, world!"),
              corrected.contains("Lima is ready."),
              corrected.contains("The API doesn't work."),
              corrected.contains("This is **very** good."),
              corrected.contains("- [ ] This is broken 😀."),
              corrected.contains("“This is quoted.”"),
              corrected.components(separatedBy: url).count == 2,
              StealthGrammarService.isSafeReplacement(source, corrected),
              report.appliedCount >= 7 else {
            return false
        }
        // The application layer has already restored placeholders. Confirm
        // that the protected byte sequences remain present in the final text.
        return protected.protectedValues.allSatisfy { corrected.contains($0) }
    }
}
