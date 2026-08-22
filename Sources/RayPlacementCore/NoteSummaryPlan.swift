import Foundation

public enum NoteSummaryPlan {
    public static let maximumChunkCharacters = 6_000

    public static func chunks(_ text: String, maximumCharacters: Int = maximumChunkCharacters) -> [String] {
        guard maximumCharacters > 0 else { return [] }
        var chunks: [String] = []
        var current = ""
        let paragraphs = text.components(separatedBy: "\n\n")
        for paragraph in paragraphs {
            if paragraph.count > maximumCharacters {
                if !current.isEmpty { chunks.append(current); current = "" }
                var remainder = paragraph[...]
                while !remainder.isEmpty {
                    let end = remainder.index(
                        remainder.startIndex,
                        offsetBy: maximumCharacters,
                        limitedBy: remainder.endIndex
                    ) ?? remainder.endIndex
                    chunks.append(String(remainder[..<end]))
                    remainder = remainder[end...]
                }
                continue
            }
            let candidate = current.isEmpty ? paragraph : current + "\n\n" + paragraph
            if candidate.count > maximumCharacters {
                if !current.isEmpty { chunks.append(current) }
                current = paragraph
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.isEmpty && !text.isEmpty ? [text] : chunks
    }
}
