import Foundation

public struct MarkdownNote: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var content: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var isPinned: Bool

    public init(
        id: UUID = UUID(),
        title: String = "Untitled Note",
        content: String = "",
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isPinned = isPinned
    }

    public var displayTitle: String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTitle.isEmpty { return cleanTitle }
        let firstContentLine = content
            .split(whereSeparator: { $0.isNewline })
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        return firstContentLine?.isEmpty == false ? firstContentLine! : "Untitled Note"
    }

    public var preview: String {
        let firstContentLine = content
            .split(whereSeparator: { $0.isNewline })
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "#>*_`- []"))
        return firstContentLine ?? "Empty note"
    }
}

public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case numbered(number: Int, text: String)
    case task(checked: Bool, text: String)
    case quote(String)
    case code(language: String?, text: String)
    case divider
}

public enum MarkdownBlockParser {
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var insideCode = false

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if insideCode {
                    blocks.append(.code(language: codeLanguage, text: codeLines.joined(separator: "\n")))
                    codeLines.removeAll(keepingCapacity: true)
                    codeLanguage = nil
                    insideCode = false
                } else {
                    flushParagraph()
                    let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeLanguage = language.isEmpty ? nil : language
                    insideCode = true
                }
                continue
            }
            if insideCode {
                codeLines.append(line)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.divider)
                continue
            }
            if let heading = heading(from: trimmed) {
                flushParagraph()
                blocks.append(heading)
                continue
            }
            if let task = task(from: trimmed) {
                flushParagraph()
                blocks.append(task)
                continue
            }
            if let numbered = numbered(from: trimmed) {
                flushParagraph()
                blocks.append(numbered)
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                blocks.append(.bullet(String(trimmed.dropFirst(2))))
                continue
            }
            if trimmed.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst(2))))
                continue
            }
            paragraphLines.append(line)
        }
        if insideCode {
            blocks.append(.code(language: codeLanguage, text: codeLines.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    private static func heading(from line: String) -> MarkdownBlock? {
        let prefix = line.prefix { $0 == "#" }
        guard (1...6).contains(prefix.count), line.dropFirst(prefix.count).hasPrefix(" ") else { return nil }
        return .heading(
            level: prefix.count,
            text: String(line.dropFirst(prefix.count + 1))
        )
    }

    private static func task(from line: String) -> MarkdownBlock? {
        guard line.count >= 6, line.hasPrefix("- [") else { return nil }
        let marker = line[line.index(line.startIndex, offsetBy: 3)]
        let close = line[line.index(line.startIndex, offsetBy: 4)]
        guard close == "]", marker == " " || marker == "x" || marker == "X" else { return nil }
        let textIndex = line.index(line.startIndex, offsetBy: 5)
        let text = line[textIndex...].trimmingCharacters(in: .whitespaces)
        return .task(checked: marker != " ", text: text)
    }

    private static func numbered(from line: String) -> MarkdownBlock? {
        guard let delimiter = line.firstIndex(where: { $0 == "." || $0 == ")" }) else { return nil }
        let numberText = line[..<delimiter]
        guard let number = Int(numberText) else { return nil }
        let afterDelimiter = line.index(after: delimiter)
        guard afterDelimiter < line.endIndex, line[afterDelimiter] == " " else { return nil }
        return .numbered(number: number, text: String(line[line.index(after: afterDelimiter)...]))
    }
}
