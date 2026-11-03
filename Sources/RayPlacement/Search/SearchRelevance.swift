import Foundation
import RayPlacementCore

/// One score scale for commands, applications, and saved content. History can
/// break ties inside a relevance band, but cannot turn a body hit into a title hit.
enum SearchRelevance {
    static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func tokens(_ value: String) -> [String] {
        value.split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    static func score(title: String, fields: [String], body: String, query: String) -> Double? {
        let title = normalize(title), query = normalize(query)
        guard !query.isEmpty else { return 0 }
        let fields = fields.map(normalize)
        let queryWords = tokens(query)
        let titleWords = tokens(title)
        func covers(_ words: [String]) -> Bool {
            !queryWords.isEmpty && queryWords.allSatisfy { token in words.contains { $0.hasPrefix(token) } }
        }
        let detail = min(900, max(0, FuzzyMatcher.scoreNormalized(title, query: query) ?? 0) / 12)
        if title == query { return 100_000 + detail }
        if title.hasPrefix(query) { return 80_000 + detail }
        if covers(titleWords) { return 70_000 + detail }
        if title.contains(query) { return 60_000 + detail }
        if fields.contains(query) { return 50_000 + detail }
        if covers(fields.flatMap(tokens)) { return 40_000 + detail }
        // Long content must contain actual words, never scattered subsequence letters.
        let normalizedBody = normalize(body)
        if normalizedBody.contains(query) || covers(tokens(normalizedBody)) { return 20_000 + detail }
        // Retain useful short title abbreviations without fuzzy-matching entire notes.
        if query.count >= 2, title.count <= max(32, query.count * 4),
           let fuzzy = FuzzyMatcher.scoreNormalized(title, query: query),
           fuzzy >= Double(query.count * 70) {
            return 5_000 + min(900, fuzzy / 12)
        }
        return nil
    }

    static func bonus(_ value: Double) -> Double { min(800, max(0, value)) }
    static func functionPriority(_ id: String) -> Double {
        ["builtin.", "extension.", "app.", "macro.", "direct.", "context."].contains { id.hasPrefix($0) } ? 1_000 : 0
    }
}
