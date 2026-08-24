import Foundation

public struct TabularData: Equatable, Sendable {
    public let rows: [[String]]

    public init(rows: [[String]]) {
        let width = rows.map(\.count).max() ?? 0
        self.rows = rows.map { row in
            row + Array(repeating: "", count: max(0, width - row.count))
        }
    }

    public var columnCount: Int { rows.first?.count ?? 0 }
}

public enum TabularDataParser {
    public static func parse(text: String, html: String? = nil) -> TabularData? {
        if let html, let table = parseHTML(html) { return table }

        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        if normalized.contains("\t"), let table = normalizedRows(
            normalized.components(separatedBy: "\n").map {
                $0.components(separatedBy: "\t")
            }
        ) { return table }

        if case .table(let headers, _, let rows)? = MarkdownBlockParser.parse(normalized).first(where: {
            if case .table = $0 { return true }
            return false
        }) {
            return TabularData(rows: [headers] + rows)
        }

        if normalized.contains(",") {
            let rows = parseCSV(normalized)
            if let table = normalizedRows(rows), table.rows.count > 1 { return table }
        }
        return nil
    }

    private static func normalizedRows(_ rawRows: [[String]]) -> TabularData? {
        var rows = rawRows.map { row in
            row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        while rows.last?.allSatisfy(\.isEmpty) == true { rows.removeLast() }
        guard !rows.isEmpty,
              let width = rows.map(\.count).max(),
              width > 1 else { return nil }
        return TabularData(rows: rows)
    }

    private static func parseCSV(_ source: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var quoted = false
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if character == "\"" {
                let next = source.index(after: index)
                if quoted, next < source.endIndex, source[next] == "\"" {
                    cell.append("\"")
                    index = next
                } else {
                    quoted.toggle()
                }
            } else if character == ",", !quoted {
                row.append(cell)
                cell = ""
            } else if character == "\n", !quoted {
                row.append(cell)
                rows.append(row)
                row = []
                cell = ""
            } else {
                cell.append(character)
            }
            index = source.index(after: index)
        }
        row.append(cell)
        rows.append(row)
        return rows
    }

    private static func parseHTML(_ html: String) -> TabularData? {
        let rowMatches = matches(#"(?is)<tr\b[^>]*>(.*?)</tr>"#, in: html)
        guard !rowMatches.isEmpty else { return nil }
        let rows = rowMatches.compactMap { rowHTML -> [String]? in
            let cells = matches(#"(?is)<t[hd]\b[^>]*>(.*?)</t[hd]>"#, in: rowHTML)
                .map(cleanHTMLCell)
            return cells.isEmpty ? nil : cells
        }
        return normalizedRows(rows)
    }

    private static func matches(_ pattern: String, in source: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression.matches(in: source, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[range])
        }
    }

    private static func cleanHTMLCell(_ source: String) -> String {
        var value = source
            .replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<[^>]+>"#, with: "", options: .regularExpression)
        let entities = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'"
        ]
        for (entity, replacement) in entities {
            value = value.replacingOccurrences(of: entity, with: replacement)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
