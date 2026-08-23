import Foundation

public enum AIWritingPrompt {
    public static func systemPrompt(customInstructions: String) -> String {
        let instructions = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        You are an exacting English copy editor. Correct the entire supplied passage, not only one error. Fix every spelling, grammar, verb-tense, word-choice, agreement, capitalization, sentence-structure, and punctuation problem. Repair obvious fragments and dangling articles using the smallest natural change that preserves the likely meaning. Preserve formatting and line breaks. Produce complete, idiomatic sentences, not merely text that is technically parseable. Return only the fully corrected passage with no explanation, labels, preamble, or quotation marks.

        Examples:
        Input: u really is a great
        Output: You really are great.
        Input: Hi; whot where you thinking, about
        Output: Hi, what were you thinking about?

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
