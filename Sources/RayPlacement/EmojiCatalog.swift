import Foundation

struct EmojiEntry: Identifiable, Sendable {
    let id: String
    let emoji: String
    let name: String
    let group: String
    let keywords: [String]
    let searchableText: String
}

enum EmojiCatalog {
    /// Unicode's fully-qualified RGI keyboard set. Parsing is intentionally lazy:
    /// the ~650 KB source is touched only when the picker is first opened.
    static let entries: [EmojiEntry] = loadEntries()

    private static func loadEntries() -> [EmojiEntry] {
        guard let url = resourceURL(),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            return fallbackEntries
        }

        var group = "Emoji"
        var subgroup = ""
        var result: [EmojiEntry] = []
        result.reserveCapacity(4_000)

        for rawLine in source.split(whereSeparator: \Character.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("# group: ") {
                group = String(line.dropFirst("# group: ".count))
                continue
            }
            if line.hasPrefix("# subgroup: ") {
                subgroup = String(line.dropFirst("# subgroup: ".count))
                continue
            }
            guard line.contains("; fully-qualified"),
                  let hash = line.firstIndex(of: "#") else { continue }

            let codeField = line[..<hash]
                .split(separator: ";", maxSplits: 1)
                .first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let annotation = line[line.index(after: hash)...]
                .trimmingCharacters(in: .whitespaces)
            let pieces = annotation.split(maxSplits: 2, whereSeparator: \Character.isWhitespace)
            guard pieces.count == 3 else { continue }

            let emoji = String(pieces[0])
            let name = String(pieces[2])
            let searchIndex = [name, group, subgroup].joined(separator: " ").lowercased()
            let words = searchIndex
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
            result.append(EmojiEntry(
                id: codeField.replacingOccurrences(of: " ", with: "-"),
                emoji: emoji,
                name: name.prefix(1).uppercased() + name.dropFirst(),
                group: group,
                keywords: Array(Set(words)).sorted(),
                searchableText: searchIndex
            ))
        }
        return result.isEmpty ? fallbackEntries : result
    }

    private static func resourceURL() -> URL? {
        if let bundled = Bundle.main.url(
            forResource: "emoji-test",
            withExtension: "txt",
            subdirectory: "Emoji"
        ) {
            return bundled
        }
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let development = repositoryRoot.appendingPathComponent("Packaging/Emoji/emoji-test.txt")
        return FileManager.default.fileExists(atPath: development.path) ? development : nil
    }

    private static let fallbackEntries: [EmojiEntry] = [
        fallback("1F600", "😀", "Grinning Face", "Smileys & Emotion", "happy smile joy"),
        fallback("1F602", "😂", "Face with Tears of Joy", "Smileys & Emotion", "laugh funny joy"),
        fallback("2764-FE0F", "❤️", "Red Heart", "Smileys & Emotion", "love favorite"),
        fallback("1F44D", "👍", "Thumbs Up", "People & Body", "yes good like approve"),
        fallback("1F389", "🎉", "Party Popper", "Activities", "celebrate congratulations"),
        fallback("2705", "✅", "Check Mark Button", "Symbols", "done yes complete"),
        fallback("1F525", "🔥", "Fire", "Travel & Places", "hot trending great"),
        fallback("2728", "✨", "Sparkles", "Activities", "magic shine new"),
        fallback("1F680", "🚀", "Rocket", "Travel & Places", "launch fast ship"),
        fallback("1F4A1", "💡", "Light Bulb", "Objects", "idea insight")
    ]

    private static func fallback(
        _ id: String,
        _ emoji: String,
        _ name: String,
        _ group: String,
        _ keywords: String
    ) -> EmojiEntry {
        EmojiEntry(
            id: id,
            emoji: emoji,
            name: name,
            group: group,
            keywords: keywords.split(separator: " ").map(String.init),
            searchableText: "\(name) \(group) \(keywords)".lowercased()
        )
    }
}
