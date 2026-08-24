import Foundation

/// Extracts only the generated assistant text from llama.cpp's simple console output.
///
/// llama.cpp may abbreviate a long displayed prompt with `... (truncated)`, even
/// when `--no-display-prompt` is supplied in conversation mode. Parsing the exact
/// echoed prompt alone therefore drops valid generations from longer formatter
/// and summary requests.
public enum QwenConsoleParser {
    public static func response(from console: String, prompt: String) -> String? {
        let normalized = console
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let responseEnd = ["\n[ Prompt:", "\n\nExiting...", "\nExiting..."]
            .compactMap { normalized.range(of: $0, options: .backwards)?.lowerBound }
            .min() ?? normalized.endIndex
        let beforeStatistics = normalized[..<responseEnd]

        let responseStart: String.Index
        if let promptRange = beforeStatistics.range(of: prompt, options: .backwards) {
            responseStart = promptRange.upperBound
        } else if let truncation = beforeStatistics.range(of: "... (truncated)", options: .backwards),
                  let lineEnd = beforeStatistics[truncation.upperBound...].firstIndex(of: "\n") {
            responseStart = beforeStatistics.index(after: lineEnd)
        } else if let finalPromptLine = prompt
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  let tailRange = beforeStatistics.range(of: finalPromptLine, options: .backwards),
                  let lineEnd = beforeStatistics[tailRange.upperBound...].firstIndex(of: "\n") {
            responseStart = beforeStatistics.index(after: lineEnd)
        } else {
            return nil
        }

        let response = normalized[responseStart..<responseEnd]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return response.isEmpty ? nil : response
    }
}
