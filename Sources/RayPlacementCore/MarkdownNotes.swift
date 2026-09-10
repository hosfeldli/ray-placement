import Foundation

public struct NoteRevision: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let content: String
    public let timestamp: Date

    public init(id: UUID = UUID(), title: String, content: String, timestamp: Date = Date()) {
        self.id = id
        self.title = title
        self.content = content
        self.timestamp = timestamp
    }
}

public enum MarkdownNoteTemplate: String, CaseIterable, Identifiable, Sendable {
    case blank
    case meetingNotes
    case projectBrief
    case dailyPlan

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .blank: return "Blank"
        case .meetingNotes: return "Meeting Notes"
        case .projectBrief: return "Project Brief"
        case .dailyPlan: return "Daily Plan"
        }
    }

    public var noteTitle: String {
        switch self {
        case .blank: return "Untitled Note"
        case .meetingNotes: return "Meeting Notes"
        case .projectBrief: return "Project Brief"
        case .dailyPlan: return "Daily Plan"
        }
    }

    public var detail: String {
        switch self {
        case .blank: return "Start with an empty page"
        case .meetingNotes: return "Agenda, discussion, decisions, and action items"
        case .projectBrief: return "Scope, success criteria, and dependencies"
        case .dailyPlan: return "Priorities, notes, and completed work"
        }
    }

    public var content: String {
        switch self {
        case .blank: return ""
        case .meetingNotes:
            return """
            # Meeting Notes

            **Date:** \(Date().formatted(date: .abbreviated, time: .omitted))
            **Attendees:**

            ## Agenda
            -

            ## Discussion
            -

            ## Decisions
            -

            ## Action Items
            - [ ]
            """
        case .projectBrief:
            return """
            # Project Brief

            ## Objective


            ## Scope
            - In scope:
            - Out of scope:

            ## Success Criteria
            - [ ]

            ## Risks and Dependencies
            -
            """
        case .dailyPlan:
            return """
            # Daily Plan — \(Date().formatted(date: .abbreviated, time: .omitted))

            ## Top Priorities
            - [ ]
            - [ ]
            - [ ]

            ## Notes


            ## Done
            -
            """
        }
    }
}

public enum MarkdownNoteLinks {
    /// Returns unique wiki-link targets in source order. Both `[[Title]]` and
    /// `[[UUID]]` are accepted; display titles are resolved by NotesStore.
    public static func targets(in markdown: String) -> [String] {
        let pattern = #"\[\[([^\]\n]+)\]\]"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        var result: [String] = []
        for match in expression.matches(in: markdown, range: range) {
            guard let valueRange = Range(match.range(at: 1), in: markdown) else { continue }
            let value = String(markdown[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty && !result.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
                result.append(value)
            }
        }
        return result
    }

    public static func normalizedTags(_ tags: [String]) -> [String] {
        var result: [String] = []
        for tag in tags {
            let clean = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "#", with: "")
            guard !clean.isEmpty else { continue }
            let value = String(clean.prefix(40))
            if !result.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
                result.append(value)
            }
        }
        return Array(result.prefix(20))
    }
}

public enum MediaDurationNormalization {
    public static func seconds(from raw: Double, source: String) -> Double {
        guard raw.isFinite, raw > 0 else { return 0 }
        var duration = raw
        if source.lowercased() == "spotify" && duration > 10_000 {
            duration /= 1_000
        }
        while duration > 86_400 { duration /= 1_000 }
        return duration
    }
}

public struct MarkdownNote: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var content: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var isPinned: Bool
    public var isFavorite: Bool
    public var speakerNames: [Int: String]
    public var tags: [String]
    public var revisionHistory: [NoteRevision]

    public init(
        id: UUID = UUID(),
        title: String = "Untitled Note",
        content: String = "",
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        isPinned: Bool = false,
        isFavorite: Bool = false,
        speakerNames: [Int: String] = [:],
        tags: [String] = [],
        revisionHistory: [NoteRevision] = []
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isPinned = isPinned
        self.isFavorite = isFavorite
        self.speakerNames = speakerNames
        self.tags = tags
        self.revisionHistory = revisionHistory
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, content, createdAt, modifiedAt, isPinned, isFavorite, speakerNames, tags, revisionHistory
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
        speakerNames = try container.decodeIfPresent([Int: String].self, forKey: .speakerNames) ?? [:]
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        revisionHistory = try container.decodeIfPresent([NoteRevision].self, forKey: .revisionHistory) ?? []
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
        try container.encode(speakerNames, forKey: .speakerNames)
        try container.encode(tags, forKey: .tags)
        try container.encode(revisionHistory, forKey: .revisionHistory)
    }

    public var displayTitle: String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTitle.isEmpty { return cleanTitle }
        let firstContentLine = Self.normalizedContent(content)
            .split(whereSeparator: { $0.isNewline })
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        return firstContentLine?.isEmpty == false ? firstContentLine! : "Untitled Note"
    }

    public var preview: String {
        let firstContentLine = Self.normalizedContent(content)
            .split(whereSeparator: { $0.isNewline })
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "#>*_`- []"))
        return firstContentLine ?? "Empty note"
    }

    /// Removes placeholder rows that render as empty content while preserving
    /// genuinely editable blank checklist rows.
    public static func normalizedContent(_ content: String) -> String {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var retained: [String] = []
        var index = 0

        while index < lines.count {
            let original = lines[index]
            let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
            if isDoneHeading(trimmed) {
                var end = index + 1
                var meaningful = false
                while end < lines.count {
                    let next = lines[end].trimmingCharacters(in: .whitespacesAndNewlines)
                    if isHeading(next) { break }
                    if !next.isEmpty && !isPlaceholderLine(next) { meaningful = true }
                    end += 1
                }
                if !meaningful {
                    index = end
                    continue
                }
            }
            if !isPlaceholderLine(trimmed) { retained.append(original) }
            index += 1
        }
        return retained.joined(separator: "\n")
    }

    private static func isHeading(_ line: String) -> Bool {
        line.range(of: #"^#{1,6}\s+.+$"#, options: .regularExpression) != nil
    }

    private static func isDoneHeading(_ line: String) -> Bool {
        guard let match = line.range(of: #"^#{1,6}\s+(.+?)\s*$"#, options: .regularExpression) else { return false }
        let heading = String(line[match]).replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
        return heading.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Done") == .orderedSame
    }

    private static func isPlaceholderLine(_ line: String) -> Bool {
        if line == "-" || line == "*" || line == "+" { return true }
        return line.range(of: #"^-\s+\[[ xX]\]\s+-\s*$"#, options: .regularExpression) != nil
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
        guard line.count >= 5, line.hasPrefix("- [") else { return nil }
        let marker = line[line.index(line.startIndex, offsetBy: 3)]
        let close = line[line.index(line.startIndex, offsetBy: 4)]
        guard close == "]", marker == " " || marker == "x" || marker == "X" else { return nil }
        let textIndex = line.index(line.startIndex, offsetBy: 5)
        let text = line[textIndex...].trimmingCharacters(in: .whitespaces)
        guard text != "-" else { return nil }
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
