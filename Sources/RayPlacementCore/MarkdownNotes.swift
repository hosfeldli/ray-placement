import Foundation

public struct MarkdownNote: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var content: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var isPinned: Bool
    public var isFavorite: Bool

    public init(
        id: UUID = UUID(),
        title: String = "Untitled Note",
        content: String = "",
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        isPinned: Bool = false,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isPinned = isPinned
        self.isFavorite = isFavorite
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, content, createdAt, modifiedAt, isPinned, isFavorite
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        content = try container.decode(String.self, forKey: .content)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(content, forKey: .content)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(isFavorite, forKey: .isFavorite)
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
    case table(headers: [String], alignments: [MarkdownTableAlignment], rows: [[String]])
    case divider
}

public enum MarkdownTableAlignment: String, Equatable, Sendable {
    case leading
    case center
    case trailing
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

        var lineIndex = 0
        while lineIndex < lines.count {
            let line = lines[lineIndex]
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
                lineIndex += 1
                continue
            }
            if insideCode {
                codeLines.append(line)
                lineIndex += 1
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                lineIndex += 1
                continue
            }
            if lineIndex + 1 < lines.count,
               let tableHeader = tableHeader(
                   headerLine: line,
                   delimiterLine: lines[lineIndex + 1]
               ) {
                flushParagraph()
                var rows: [[String]] = []
                lineIndex += 2
                while lineIndex < lines.count {
                    let candidate = lines[lineIndex]
                    guard !candidate.trimmingCharacters(in: .whitespaces).isEmpty,
                          candidate.contains("|") else { break }
                    var cells = tableCells(from: candidate)
                    guard !cells.isEmpty else { break }
                    if cells.count < tableHeader.headers.count {
                        cells += Array(repeating: "", count: tableHeader.headers.count - cells.count)
                    } else if cells.count > tableHeader.headers.count {
                        cells = Array(cells.prefix(tableHeader.headers.count))
                    }
                    rows.append(cells)
                    lineIndex += 1
                }
                blocks.append(.table(
                    headers: tableHeader.headers,
                    alignments: tableHeader.alignments,
                    rows: rows
                ))
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.divider)
                lineIndex += 1
                continue
            }
            if let heading = heading(from: trimmed) {
                flushParagraph()
                blocks.append(heading)
                lineIndex += 1
                continue
            }
            if let task = task(from: trimmed) {
                flushParagraph()
                blocks.append(task)
                lineIndex += 1
                continue
            }
            if let numbered = numbered(from: trimmed) {
                flushParagraph()
                blocks.append(numbered)
                lineIndex += 1
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                blocks.append(.bullet(String(trimmed.dropFirst(2))))
                lineIndex += 1
                continue
            }
            if trimmed.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst(2))))
                lineIndex += 1
                continue
            }
            paragraphLines.append(line)
            lineIndex += 1
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

    private static func tableHeader(
        headerLine: String,
        delimiterLine: String
    ) -> (headers: [String], alignments: [MarkdownTableAlignment])? {
        guard headerLine.contains("|"), delimiterLine.contains("|") else { return nil }
        let headers = tableCells(from: headerLine)
        let delimiters = tableCells(from: delimiterLine)
        guard !headers.isEmpty, headers.count == delimiters.count else { return nil }
        var alignments: [MarkdownTableAlignment] = []
        for rawDelimiter in delimiters {
            let delimiter = rawDelimiter.trimmingCharacters(in: .whitespaces)
            let leadingColon = delimiter.hasPrefix(":")
            let trailingColon = delimiter.hasSuffix(":")
            let dashes = delimiter.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard dashes.count >= 3, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            if leadingColon && trailingColon {
                alignments.append(.center)
            } else if trailingColon {
                alignments.append(.trailing)
            } else {
                alignments.append(.leading)
            }
        }
        return (headers, alignments)
    }

    private static func tableCells(from line: String) -> [String] {
        var source = line.trimmingCharacters(in: .whitespaces)
        if source.hasPrefix("|") { source.removeFirst() }
        if source.hasSuffix("|") { source.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaping = false
        for character in source {
            if escaping {
                current.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaping { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }
}
