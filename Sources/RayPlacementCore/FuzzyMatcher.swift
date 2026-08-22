import Foundation

public enum FuzzyMatcher {
    /// Scores a candidate against a query. Higher is better; nil means no match.
    public static func score(_ candidate: String, query: String) -> Double? {
        let candidate = candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let query = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        guard !query.isEmpty else { return 0 }
        if candidate == query { return 10_000 }
        if candidate.hasPrefix(query) { return 7_500 - Double(candidate.count - query.count) }
        if let range = candidate.range(of: query) {
            let offset = candidate.distance(from: candidate.startIndex, to: range.lowerBound)
            return 5_000 - Double(offset * 8) - Double(candidate.count - query.count)
        }

        var queryIndex = query.startIndex
        var candidateIndex = candidate.startIndex
        var score = 0.0
        var streak = 0.0
        var lastMatchOffset: Int?
        var offset = 0

        while queryIndex < query.endIndex, candidateIndex < candidate.endIndex {
            if query[queryIndex] == candidate[candidateIndex] {
                streak += 1
                score += 90 + streak * 25
                if candidateIndex == candidate.startIndex || isWordBoundary(in: candidate, at: candidateIndex) {
                    score += 140
                }
                if let lastMatchOffset {
                    score -= Double(max(0, offset - lastMatchOffset - 1)) * 5
                }
                lastMatchOffset = offset
                query.formIndex(after: &queryIndex)
            } else {
                streak = 0
            }
            candidate.formIndex(after: &candidateIndex)
            offset += 1
        }

        guard queryIndex == query.endIndex else { return nil }
        return score - Double(candidate.count) * 0.35
    }

    private static func isWordBoundary(in value: String, at index: String.Index) -> Bool {
        guard index > value.startIndex else { return true }
        let previous = value[value.index(before: index)]
        return previous == " " || previous == "-" || previous == "_" || previous == "." || previous == "/"
    }
}
