import Foundation

public struct SQLFilterBlock: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case condition = "Condition", all = "AND", any = "OR", not = "NOT", expression = "SQL expression" }
    public enum Comparison: String, Codable, CaseIterable, Sendable {
        case equal = "=", unequal = "<>", greater = ">", less = "<", atLeast = ">=", atMost = "<=", like = "LIKE", notLike = "NOT LIKE", inside = "IN", outside = "NOT IN", between = "BETWEEN", isNull = "IS NULL", notNull = "IS NOT NULL"
    }
    public enum ValueType: String, Codable, CaseIterable, Sendable { case text = "Text", number = "Number", expression = "Column / SQL" }
    public var id = UUID()
    public var kind: Kind = .condition
    public var field = ""
    public var comparison: Comparison = .equal
    public var valueType: ValueType = .text
    public var value = ""
    public var upperValue = ""
    public var children: [SQLFilterBlock] = []
    public init(kind: Kind = .condition, field: String = "", comparison: Comparison = .equal, valueType: ValueType = .text, value: String = "", upperValue: String = "", children: [SQLFilterBlock] = []) {
        self.kind = kind; self.field = field; self.comparison = comparison; self.valueType = valueType
        self.value = value; self.upperValue = upperValue; self.children = children
    }

    public func sql(driver: SQLDatabaseDriver = .oracle) throws -> String {
        switch kind {
        case .all, .any, .not:
            guard !children.isEmpty else { throw SQLBlockError.invalid("Add a condition to the \(kind.rawValue) group.") }
            let expression = try children.map { try $0.sql(driver: driver) }.joined(separator: kind == .any ? " OR " : " AND ")
            return (kind == .not ? "NOT " : "") + "(\(expression))"
        case .expression: return try SQLBlockError.expression(field, label: "filter expression")
        case .condition:
            let column = try SQLBlockError.expression(field, label: "filter column")
            switch comparison {
            case .isNull, .notNull: return "\(column) \(comparison.rawValue)"
            case .inside, .outside:
                let values = value.components(separatedBy: .newlines).filter { !$0.isEmpty }
                guard !values.isEmpty else { throw SQLBlockError.invalid("IN needs at least one value (one per line).") }
                return try "\(column) \(comparison.rawValue) (\(values.map { try literal($0, driver: driver) }.joined(separator: ", ")))"
            case .between: return try "\(column) BETWEEN \(literal(value, driver: driver)) AND \(literal(upperValue, driver: driver))"
            default: return try "\(column) \(comparison.rawValue) \(literal(value, driver: driver))"
            }
        }
    }

    private func literal(_ text: String, driver: SQLDatabaseDriver) throws -> String {
        switch valueType {
        case .text:
            // MySQL's backslash escaping varies by SQL mode. Hex text avoids
            // ambiguity for paths/control characters under either mode.
            if driver == .mysql && (text.contains("\\") || text.contains("\0")) {
                return "CONVERT(X'" + text.utf8.map { String(format: "%02x", $0) }.joined() + "' USING utf8mb4)"
            }
            return "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
        case .number:
            let number = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard number.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil else { throw SQLBlockError.invalid("Enter a valid numeric filter value.") }
            return number
        case .expression: return try SQLBlockError.expression(text, label: "value expression")
        }
    }
}

public struct SQLJoinBlock: Codable, Hashable, Identifiable, Sendable {
    public enum Style: String, Codable, CaseIterable, Sendable { case inner = "INNER", left = "LEFT", right = "RIGHT", full = "FULL OUTER", cross = "CROSS" }
    public var id = UUID()
    public var table: String
    public var style: Style = .inner
    public var condition = SQLFilterBlock()
    public init(table: String = "", style: Style = .inner, condition: SQLFilterBlock = SQLFilterBlock()) { self.table = table; self.style = style; self.condition = condition }
}

public struct SQLAggregateBlock: Codable, Hashable, Identifiable, Sendable {
    public enum Function: String, Codable, CaseIterable, Sendable { case count = "COUNT", sum = "SUM", average = "AVG", minimum = "MIN", maximum = "MAX" }
    public var id = UUID()
    public var function: Function = .count
    public var field = "*"
    public var distinct = false
    public var alias = ""
    public init() {}
    public func sql(driver: SQLDatabaseDriver = .oracle) throws -> String {
        let expression = try SQLBlockError.expression(field, label: "aggregate column")
        if expression == "*" && (function != .count || distinct) { throw SQLBlockError.invalid("Choose a column for this aggregate; only COUNT accepts * without DISTINCT.") }
        guard !alias.contains("\0") else { throw SQLBlockError.invalid("Result names cannot contain a null character.") }
        let quote = driver == .mysql ? "`" : "\""
        let suffix = alias.isEmpty ? "" : " AS \(quote)\(alias.replacingOccurrences(of: quote, with: quote + quote))\(quote)"
        return "\(function.rawValue)(\(distinct ? "DISTINCT " : "")\(expression))\(suffix)"
    }
}

public struct SQLSortBlock: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var field = ""
    public var descending = false
    public init() {}
}

public enum SQLBlockError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
    static func expression(_ text: String, label: String) throws -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw invalid("Choose or enter a \(label).") }
        // Blocks compile one SELECT. Multi-statement scripts belong in Free SQL.
        guard !clean.contains(";"), !clean.contains("--"), !clean.contains("/*"), !clean.contains("\0") else { throw invalid("Use Free SQL for statements or comments; blocks accept single expressions.") }
        return clean
    }
}

public struct SQLQueryBlocks: Codable, Hashable, Sendable {
    public var columns: [String] = []
    public var distinct = false
    public var joins: [SQLJoinBlock] = []
    public var filters: [SQLFilterBlock] = []
    public var groupBy: [String] = []
    public var aggregates: [SQLAggregateBlock] = []
    public var having: [SQLFilterBlock] = []
    public var sorts: [SQLSortBlock] = []
    public init() {}

    public func sql(tables: [String], limit: Int, driver: SQLDatabaseDriver) throws -> String {
        guard let first = tables.first else { throw SQLBlockError.invalid("Add a source table.") }
        let source = try SQLBlockError.expression(first, label: "source table")
        let groups = try groupBy.map { try SQLBlockError.expression($0, label: "grouping column") }
        let selected = try columns.map { try SQLBlockError.expression($0, label: "selected column") }
        if !aggregates.isEmpty || !groups.isEmpty {
            guard selected.allSatisfy({ groups.contains($0) }) else { throw SQLBlockError.invalid("Every selected non-aggregate column must also be in Group by.") }
        }
        var projection = selected.isEmpty ? groups : selected
        projection += try aggregates.map { try $0.sql(driver: driver) }
        if projection.isEmpty { projection = ["\(source).*"] }
        var text = "SELECT\(distinct ? " DISTINCT" : "")\n  \(projection.joined(separator: ",\n  "))\nFROM \(source)"
        var included = Set([source])
        for join in joins {
            let table = try SQLBlockError.expression(join.table, label: "joined table")
            guard included.insert(table).inserted else { throw SQLBlockError.invalid("Table \(table) is already joined. Use Free SQL for self-joins with aliases.") }
            if join.style == .full && driver == .mysql { throw SQLBlockError.invalid("MySQL does not support FULL OUTER JOIN. Choose another join or use a UNION in Free SQL.") }
            text += "\n\(join.style.rawValue) JOIN \(table)"
            if join.style != .cross { text += try " ON \(join.condition.sql(driver: driver))" }
        }
        for table in tables.dropFirst() where !included.contains(table) {
            text += "\nCROSS JOIN \(try SQLBlockError.expression(table, label: "source table"))"
        }
        if !filters.isEmpty { text += try "\nWHERE " + filters.map { "(\(try $0.sql(driver: driver)))" }.joined(separator: " AND ") }
        if !groups.isEmpty { text += "\nGROUP BY " + groups.joined(separator: ", ") }
        if !having.isEmpty {
            guard !groups.isEmpty || !aggregates.isEmpty else { throw SQLBlockError.invalid("Add grouping or aggregation before a HAVING filter.") }
            text += try "\nHAVING " + having.map { "(\(try $0.sql(driver: driver)))" }.joined(separator: " AND ")
        }
        if !sorts.isEmpty {
            text += try "\nORDER BY " + sorts.map { "\(try SQLBlockError.expression($0.field, label: "sort column")) \($0.descending ? "DESC" : "ASC")" }.joined(separator: ", ")
        }
        text += driver == .mysql ? "\nLIMIT \(max(1, limit));" : "\nFETCH FIRST \(max(1, limit)) ROWS ONLY"
        return text
    }
}
