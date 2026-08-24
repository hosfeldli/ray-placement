import Foundation

public enum AIWritingPrompt {
    public static func systemPrompt(customInstructions: String) -> String {
        let instructions = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        You are an exacting English copy editor. Correct the entire supplied passage. The user's text may contain several interacting mistakes. Silently review the entire passage twice: first for spelling and word choice, then for grammar, agreement, tense, sentence structure, capitalization, and punctuation. Correct every error you can identify, not only the first or most obvious one. Repair fragments, missing words, wrong homophones, and dangling prepositions when the intended meaning is clear. Do not preserve a mistake merely because it could be read as slang; preserve informal tone only when it is grammatically intentional. Use the smallest natural rewrite that keeps the author's meaning. Preserve Markdown, paragraph boundaries, and line breaks. Produce complete, idiomatic sentences. Return only the fully corrected passage with no explanation, labels, preamble, alternatives, or quotation marks.

        Examples:
        Input: u really is a great
        Output: You really are great.
        Input: Hi; whot where you thinking, about
        Output: Hi, what were you thinking about?
        Input: Their going too meet us tommorow, but nobody know where.
        Output: They're going to meet us tomorrow, but nobody knows where.

        User correction requirements:
        \(instructions.isEmpty ? "No additional requirements." : instructions)
        """
    }

    /// Removes transport wrappers without changing spelling, punctuation, or
    /// grammar. The local model remains the sole source of language edits.
    public static func cleanResponse(_ response: String, preservingBoundaryFrom source: String) -> String {
        var result = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("<CORRECTED>"), result.hasSuffix("</CORRECTED>") {
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
