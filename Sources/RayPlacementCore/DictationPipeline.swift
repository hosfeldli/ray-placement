import Foundation

/// The destination selected for committed dictation text. A target does not own
/// capture or transcription; it only receives stable text deltas from the shared pipeline.
public enum DictationTarget: Equatable, Sendable {
    case conversation(UUID)
    case note(UUID)
    case aiPrompt
    case launcherQuery
    case externalApplication(processIdentifier: Int32, bundleIdentifier: String?)
}

/// Updates emitted by the shared transcription pipeline. External targets must
/// act only on `committedDelta`; partials are revisable previews, and the final
/// event is informational rather than another insertion.
public enum DictationTranscriptEvent: Equatable, Sendable {
    case partial(String)
    case committedDelta(String)
    case completed(String)

    /// The only payload that is safe to insert into an external text field.
    public var insertableDelta: String? {
        guard case .committedDelta(let text) = self else { return nil }
        return text
    }
}

/// Reconciles a recovered whole-audio transcript against the immutable text
/// already delivered by live recognition.
public enum TranscriptReconciliation {
    /// Returns only the suffix not already committed by live recognition. Word
    /// matching ignores case and punctuation changes between Speech passes. If
    /// they cannot be reconciled, preserve committed text rather than risk duplication.
    public static func uncommittedSuffix(committed: String, recovered: String) -> String {
        let prior = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        let recognized = recovered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recognized.isEmpty else { return "" }
        guard !prior.isEmpty else { return recognized }

        let priorWords = wordTokens(in: prior)
        let recoveredWords = wordTokens(in: recognized)
        guard !recoveredWords.isEmpty else { return "" }
        guard !priorWords.isEmpty else { return recognized }
        let priorValues = priorWords.map(\.value)
        let recoveredValues = recoveredWords.map(\.value)

        if recoveredValues.count <= priorValues.count,
           Array(priorValues.prefix(recoveredValues.count)) == recoveredValues {
            return ""
        }

        let overlap = longestSuffixPrefixOverlap(priorValues, recoveredValues)
        guard overlap > 0 else { return "" }
        let suffixStart = recoveredWords[overlap - 1].range.upperBound
        let suffix = String(recognized[suffixStart...])
        guard !suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        guard let first = suffix.first, !first.isWhitespace, !first.isPunctuation else { return suffix }
        return " " + suffix
    }

    private static func wordTokens(in text: String) -> [(value: String, range: Range<String.Index>)] {
        var result: [(value: String, range: Range<String.Index>)] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, !isWordCharacter(text[index]) {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }
            let start = index
            while index < text.endIndex, isWordCharacter(text[index]) {
                index = text.index(after: index)
            }
            let range = start..<index
            result.append((String(text[range]).lowercased(), range))
        }
        return result
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    private static func longestSuffixPrefixOverlap(_ committed: [String], _ recovered: [String]) -> Int {
        let pattern = recovered
        guard !pattern.isEmpty, !committed.isEmpty else { return 0 }

        var failure = Array(repeating: 0, count: pattern.count)
        if pattern.count > 1 {
            var prefixLength = 0
            for index in 1..<pattern.count {
                while prefixLength > 0, pattern[index] != pattern[prefixLength] {
                    prefixLength = failure[prefixLength - 1]
                }
                if pattern[index] == pattern[prefixLength] { prefixLength += 1 }
                failure[index] = prefixLength
            }
        }

        var matched = 0
        for word in committed {
            while matched > 0, (matched == pattern.count || pattern[matched] != word) {
                matched = failure[matched - 1]
            }
            if matched < pattern.count, pattern[matched] == word { matched += 1 }
        }
        return matched
    }
}

/// Separates the changing recognition preview from text that has been committed
/// and must remain immutable.
public struct TranscriptAssemblyUpdate: Equatable, Sendable {
    public let partialText: String
    public let committedDelta: String
    public let committedText: String

    public init(partialText: String, committedDelta: String, committedText: String) {
        self.partialText = partialText
        self.committedDelta = committedDelta
        self.committedText = committedText
    }
}

public struct TranscriptAssembler: Sendable {
    public private(set) var partialText = ""
    public private(set) var committedText = ""

    private let heldWordCount: Int
    private var previousPartial = ""

    public init(heldWordCount: Int = 2) {
        self.heldWordCount = max(0, heldWordCount)
    }

    /// Feed the recognizer's full, revisable hypothesis. Only a common stable
    /// prefix is committed; the final words remain a mutable preview.
    @discardableResult
    public mutating func receivePartial(_ hypothesis: String) -> TranscriptAssemblyUpdate {
        let candidate = Self.clean(hypothesis)
        guard !candidate.isEmpty else {
            previousPartial = ""
            partialText = ""
            return update(delta: "")
        }

        let common = previousPartial.isEmpty ? "" : Self.commonPrefix(previousPartial, candidate)
        previousPartial = candidate

        if let stable = Self.stableWordPrefix(common, holdingBack: heldWordCount),
           stable.hasPrefix(committedText),
           stable.count > committedText.count {
            let delta = String(stable.dropFirst(committedText.count))
            committedText = stable
            partialText = Self.remaining(candidate, after: committedText)
            return update(delta: delta)
        }

        partialText = Self.remaining(candidate, after: committedText)
        return update(delta: "")
    }

    /// Commit the final recognizer hypothesis without revising already
    /// committed output. Overlap is removed when the recognizer revised its
    /// leading words after an earlier stable-prefix commit.
    @discardableResult
    public mutating func finish(with finalHypothesis: String? = nil) -> TranscriptAssemblyUpdate {
        let candidate = Self.clean(finalHypothesis ?? previousPartial)
        guard !candidate.isEmpty else {
            partialText = ""
            previousPartial = ""
            return update(delta: "")
        }

        let delta: String
        if candidate.hasPrefix(committedText) {
            delta = String(candidate.dropFirst(committedText.count))
        } else {
            let overlap = Self.longestSuffixPrefixOverlap(committedText, candidate)
            delta = String(candidate.dropFirst(overlap))
        }

        let cleanDelta = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanDelta.isEmpty {
            if committedText.isEmpty {
                committedText = cleanDelta
            } else {
                committedText += " " + cleanDelta
            }
        }

        partialText = ""
        previousPartial = ""
        return update(delta: cleanDelta)
    }

    public mutating func reset() {
        partialText = ""
        committedText = ""
        previousPartial = ""
    }

    private func update(delta: String) -> TranscriptAssemblyUpdate {
        TranscriptAssemblyUpdate(
            partialText: partialText,
            committedDelta: delta,
            committedText: committedText
        )
    }

    private static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func commonPrefix(_ lhs: String, _ rhs: String) -> String {
        var end = lhs.startIndex
        var left = lhs.startIndex
        var right = rhs.startIndex
        while left < lhs.endIndex, right < rhs.endIndex, lhs[left] == rhs[right] {
            left = lhs.index(after: left)
            right = rhs.index(after: right)
            end = left
        }
        return String(lhs[..<end])
    }

    private static func stableWordPrefix(_ text: String, holdingBack: Int) -> String? {
        var wordRanges: [Range<String.Index>] = []
        var index = text.startIndex

        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace {
                index = text.index(after: index)
            }
            wordRanges.append(start..<index)
        }

        let stableWordCount = wordRanges.count - holdingBack
        guard stableWordCount > 0 else { return nil }
        let end = wordRanges[stableWordCount - 1].upperBound
        return String(text[..<end])
    }

    private static func remaining(_ candidate: String, after committed: String) -> String {
        guard candidate.hasPrefix(committed) else { return candidate }
        return String(candidate.dropFirst(committed.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func longestSuffixPrefixOverlap(_ committed: String, _ candidate: String) -> Int {
        let left = Array(committed)
        let right = Array(candidate)
        let maximum = min(left.count, right.count)
        guard maximum > 0 else { return 0 }

        for count in stride(from: maximum, through: 1, by: -1) {
            if left.suffix(count).elementsEqual(right.prefix(count)) { return count }
        }
        return 0
    }
}
