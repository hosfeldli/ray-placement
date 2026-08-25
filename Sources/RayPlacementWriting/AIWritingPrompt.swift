import Foundation

public enum AIWritingPrompt {
    public static func systemPrompt(customInstructions: String) -> String {
        let instructions = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        You are a deterministic English correction engine. Correct the entire supplied passage. Silently inspect every word and sentence for spelling, word choice, agreement, tense, missing words, sentence structure, capitalization, and punctuation. Correct every error, not only the first or most obvious one. Repair fragments, wrong homophones, and dangling prepositions when the intended meaning is clear. Do not preserve a mistake merely because it could be read as slang; preserve informal tone only when it is grammatically intentional. Use the smallest natural rewrite that keeps the author's meaning. Preserve Markdown, paragraph boundaries, and line breaks. Produce complete, idiomatic sentences.

        Return exactly <RP_CORRECTED> followed by the fully corrected passage and then <RP_END>. Never include an explanation, label, preamble, alternative, quotation marks around the passage, or text outside those tags.

        Examples:
        Input: u really is a great
        Output: <RP_CORRECTED>You really are great.<RP_END>
        Input: Hi; whot where you thinking, about
        Output: <RP_CORRECTED>Hi, what were you thinking about?<RP_END>
        Input: Their going too meet us tommorow, but nobody know where.
        Output: <RP_CORRECTED>They're going to meet us tomorrow, but nobody knows where.<RP_END>

        User correction requirements:
        \(instructions.isEmpty ? "No additional requirements." : instructions)
        """
    }

    public static func auditSystemPrompt(customInstructions: String) -> String {
        let instructions = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        You are the final quality gate for an English correction. Compare the original passage with a draft correction. Rewrite the draft wherever needed so every spelling, word-choice, agreement, tense, missing-word, sentence-structure, capitalization, and punctuation error is fixed. Preserve the original meaning, tone, Markdown, paragraph boundaries, and line breaks. Never reintroduce an error from the original. Return the original unchanged only when it was already completely correct.

        Return exactly <RP_CORRECTED> followed by the final corrected passage and then <RP_END>. Never include analysis, an explanation, labels, alternatives, quotation marks around the passage, or text outside those tags.

        User correction requirements:
        \(instructions.isEmpty ? "No additional requirements." : instructions)
        """
    }

    public static func auditPrompt(original: String, draft: String) -> String {
        """
        <RP_ORIGINAL>
        \(original)
        </RP_ORIGINAL>
        <RP_DRAFT>
        \(draft)
        </RP_DRAFT>
        Audit the draft against the original and return the final correction in the required tags.
        """
    }

    public static func taggedResponse(_ response: String) -> String? {
        guard let start = response.range(of: "<RP_CORRECTED>", options: .backwards),
              let end = response.range(of: "<RP_END>", range: start.upperBound..<response.endIndex),
              start.upperBound <= end.lowerBound else { return nil }
        var value = String(response[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Some chat templates helpfully close the opening tag even though the
        // protocol uses a distinct end marker. Treat that as transport, never
        // as user-visible corrected text.
        if value.hasSuffix("</RP_CORRECTED>") {
            value.removeLast("</RP_CORRECTED>".count)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    public static func isPlausibleCorrection(_ candidate: String, for source: String) -> Bool {
        let clean = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        let lower = clean.lowercased()
        let refusalMarkers = ["i can't", "i cannot", "as an ai", "unable to comply", "here is the corrected"]
        guard !refusalMarkers.contains(where: lower.contains) else { return false }
        guard !clean.contains("<RP_"), !clean.contains("</RP_") else { return false }
        let sourceLength = max(source.count, 1)
        guard clean.count <= max(1_024, sourceLength * 4) else { return false }
        return true
    }

    /// Removes transport wrappers without changing spelling, punctuation, or
    /// grammar. The local model remains the sole source of language edits.
    public static func cleanResponse(_ response: String, preservingBoundaryFrom source: String) -> String {
        var result = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if let tagged = taggedResponse(result) {
            result = tagged
        } else if result.hasPrefix("<CORRECTED>"), result.hasSuffix("</CORRECTED>") {
            result.removeFirst("<CORRECTED>".count)
            result.removeLast("</CORRECTED>".count)
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if result.hasPrefix("Corrected text:") {
            result.removeFirst("Corrected text:".count)
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let leading = source.prefix { $0.isWhitespace }
        let trailing = source.reversed().prefix { $0.isWhitespace }.reversed()
        return String(leading) + result + String(trailing)
    }
}
