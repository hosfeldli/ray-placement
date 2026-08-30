import Foundation

public enum SQLOracleOutput {
    /// SQLPlus MARKUP CSV preserves embedded delimiters, quotes, and newlines,
    /// including LONG metadata such as DATA_DEFAULT.
    public static func parse(_ output: String) -> SQLResultSet {
        guard let header = output.range(of: "\"", options: [], range: output.startIndex..<output.endIndex) else { return SQLResultSet() }
        let characters = Array(output[header.lowerBound...])
        var records: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if quoted, index + 1 < characters.count, characters[index + 1] == "\"" {
                    field.append("\""); index += 1
                } else { quoted.toggle() }
            } else if character == "|", !quoted {
                row.append(field); field = ""
            } else if (character == "\n" || character == "\r\n" || character == "\r"), !quoted {
                row.append(field)
                if row.count > 1 || !field.isEmpty { records.append(row) }
                row = []; field = ""
            } else { field.append(character) }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); records.append(row) }
        guard let columns = records.first else { return SQLResultSet() }
        let rows = records.dropFirst().filter { $0.count == columns.count }
        return SQLResultSet(columns: columns, rows: Array(rows))
    }
}
