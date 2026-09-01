import Foundation

public enum SQLDatabaseDriver: String, Codable, CaseIterable, Identifiable, Sendable {
    case mysql
    case oracle

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mysql: return "MySQL"
        case .oracle: return "Oracle"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .mysql: return 3306
        case .oracle: return 1521
        }
    }

    public var defaultCommand: String {
        switch self {
        case .mysql: return "/usr/local/bin/mysql"
        case .oracle: return "/usr/local/bin/sqlplus"
        }
    }
}

/// Network ports are identifiers, not quantities: keep their display and
/// validation free of locale-dependent number formatting such as `1,521`.
public enum SQLNetworkPort {
    public static let validRange = 1...65_535

    public static func parsePlainDigits(_ value: String) -> Int? {
        guard !value.isEmpty,
              value.allSatisfy({ $0.isWholeNumber }),
              let port = Int(value),
              validRange.contains(port) else { return nil }
        return port
    }
}

public enum SQLOracleConnectionSyntax {
    /// Ordinary Oracle account names must remain unquoted so Oracle applies its
    /// standard uppercase normalization. Quoting `lima_test` would instead ask
    /// Oracle to find a distinct, lowercase account and fail authentication.
    public static func identifier(for username: String) -> String {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSimple = !trimmed.isEmpty && trimmed.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" || $0 == "#"
        }
        if isSimple { return trimmed }
        return "\"\(trimmed.replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}

public struct SQLConnectionProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var environment: String
    public var driver: SQLDatabaseDriver
    public var host: String
    public var port: Int
    /// Database for MySQL; service name for Oracle.
    public var database: String
    public var username: String
    /// An optional explicit location for mysql or sqlplus. Credentials are not
    /// part of this profile and are stored only in Keychain.
    public var commandPath: String
    /// Empty/nil keeps all accessible schemas. Names are exact Oracle owners.
    public var discoverySchemas: [String]?
    /// Optional clutter filters. Nil preserves the new safe defaults when
    /// decoding older profiles.
    public var hideTemporaryTables: Bool?
    public var hideShortAffixTables: Bool?
    public var tableExclusionTerms: [String]?
    public var tableIncludeOverrides: [String]?

    public init(
        id: UUID = UUID(),
        name: String,
        environment: String,
        driver: SQLDatabaseDriver,
        host: String,
        port: Int? = nil,
        database: String,
        username: String,
        commandPath: String? = nil,
        discoverySchemas: [String]? = nil,
        hideTemporaryTables: Bool? = true,
        hideShortAffixTables: Bool? = true,
        tableExclusionTerms: [String]? = nil,
        tableIncludeOverrides: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.environment = environment
        self.driver = driver
        self.host = host
        self.port = port ?? driver.defaultPort
        self.database = database
        self.username = username
        self.commandPath = commandPath ?? driver.defaultCommand
        self.discoverySchemas = discoverySchemas
        self.hideTemporaryTables = hideTemporaryTables
        self.hideShortAffixTables = hideShortAffixTables
        self.tableExclusionTerms = tableExclusionTerms
        self.tableIncludeOverrides = tableIncludeOverrides
    }

    public var displayLocation: String { "\(host):\(port)/\(database)" }
}

public struct SQLSchemaFilter: Equatable, Sendable {
    public var hideTemporaryTables: Bool
    public var hideShortAffixTables: Bool
    public var exclusionTerms: [String]
    public var includeOverrides: Set<String>

    public init(profile: SQLConnectionProfile) {
        hideTemporaryTables = profile.hideTemporaryTables ?? true
        hideShortAffixTables = profile.hideShortAffixTables ?? true
        exclusionTerms = (profile.tableExclusionTerms ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }.filter { !$0.isEmpty }
        includeOverrides = Set((profile.tableIncludeOverrides ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }.filter { !$0.isEmpty })
    }

    public static let permissive = SQLSchemaFilter(
        hideTemporaryTables: false,
        hideShortAffixTables: false,
        exclusionTerms: [],
        includeOverrides: []
    )

    public init(hideTemporaryTables: Bool, hideShortAffixTables: Bool, exclusionTerms: [String], includeOverrides: Set<String>) {
        self.hideTemporaryTables = hideTemporaryTables
        self.hideShortAffixTables = hideShortAffixTables
        self.exclusionTerms = exclusionTerms
        self.includeOverrides = includeOverrides
    }

    public func isHidden(_ table: SQLTable) -> Bool {
        let name = table.name.uppercased()
        let qualified = table.qualifiedName.uppercased()
        if includeOverrides.contains(name) || includeOverrides.contains(qualified) { return false }
        if hideTemporaryTables && name.contains("TEMP") { return true }
        if hideShortAffixTables {
            if let underscore = name.firstIndex(of: "_") {
                let prefixLength = name.distance(from: name.startIndex, to: underscore)
                if (1...2).contains(prefixLength) { return true }
            }
            if let underscore = name.lastIndex(of: "_") {
                let suffixLength = name.distance(from: name.index(after: underscore), to: name.endIndex)
                if (1...2).contains(suffixLength) { return true }
            }
        }
        return exclusionTerms.contains { name.contains($0) || qualified.contains($0) }
    }
}

public struct SQLColumn: Codable, Identifiable, Hashable, Sendable {
    public var id: String { "\(name)|\(ordinal)" }
    public var name: String
    public var dataType: String
    public var nullable: Bool
    public var ordinal: Int
    public var defaultValue: String?
    public var description: String?

    public init(name: String, dataType: String, nullable: Bool, ordinal: Int, defaultValue: String? = nil, description: String? = nil) {
        self.name = name
        self.dataType = dataType
        self.nullable = nullable
        self.ordinal = ordinal
        self.defaultValue = defaultValue
        self.description = description
    }
}

public struct SQLForeignKey: Codable, Identifiable, Hashable, Sendable {
    public var id: String { "\(name)|\(sourceTable)|\(sourceColumn)|\(destinationTable)|\(destinationColumn)" }
    public var name: String
    public var sourceTable: String
    public var sourceColumn: String
    public var destinationTable: String
    public var destinationColumn: String

    public init(name: String, sourceTable: String, sourceColumn: String, destinationTable: String, destinationColumn: String) {
        self.name = name
        self.sourceTable = sourceTable
        self.sourceColumn = sourceColumn
        self.destinationTable = destinationTable
        self.destinationColumn = destinationColumn
    }
}

public struct SQLIndex: Codable, Identifiable, Hashable, Sendable {
    public var id: String { "\(table)|\(name)|\(column)" }
    public var table: String
    public var name: String
    public var column: String
    public var ordinal: Int
    public var unique: Bool

    public init(table: String, name: String, column: String, ordinal: Int, unique: Bool) {
        self.table = table
        self.name = name
        self.column = column
        self.ordinal = ordinal
        self.unique = unique
    }
}

public struct SQLTable: Codable, Identifiable, Hashable, Sendable {
    public var id: String { qualifiedName }
    public var schema: String
    public var name: String
    public var kind: String
    public var description: String?
    public var columns: [SQLColumn]
    public var indexes: [SQLIndex]
    public var constraints: [String]

    public init(
        schema: String,
        name: String,
        kind: String = "TABLE",
        description: String? = nil,
        columns: [SQLColumn] = [],
        indexes: [SQLIndex] = [],
        constraints: [String] = []
    ) {
        self.schema = schema
        self.name = name
        self.kind = kind
        self.description = description
        self.columns = columns
        self.indexes = indexes
        self.constraints = constraints
    }

    public var qualifiedName: String {
        schema.isEmpty ? name : "\(schema).\(name)"
    }
}

public struct SQLProcedure: Codable, Identifiable, Hashable, Sendable {
    public var id: String { "\(schema).\(name).\(kind)" }
    public var schema: String
    public var name: String
    public var kind: String
    public var description: String?

    public init(schema: String, name: String, kind: String, description: String? = nil) {
        self.schema = schema
        self.name = name
        self.kind = kind
        self.description = description
    }

    public var qualifiedName: String { schema.isEmpty ? name : "\(schema).\(name)" }

    public var invocation: String {
        switch kind.uppercased() {
        case "FUNCTION": return "SELECT \(qualifiedName)();"
        default: return "CALL \(qualifiedName)();"
        }
    }
}

public struct SQLSchemaSnapshot: Codable, Hashable, Sendable {
    public var profileID: UUID
    public var discoveredAt: Date
    public var tables: [SQLTable]
    public var foreignKeys: [SQLForeignKey]
    public var procedures: [SQLProcedure]
    /// Nil in older caches means the legacy, completed snapshot.
    public var discoveryComplete: Bool?

    public init(profileID: UUID, discoveredAt: Date = Date(), tables: [SQLTable] = [], foreignKeys: [SQLForeignKey] = [], procedures: [SQLProcedure] = [], discoveryComplete: Bool = true) {
        self.profileID = profileID
        self.discoveredAt = discoveredAt
        self.tables = tables
        self.foreignKeys = foreignKeys
        self.procedures = procedures
        self.discoveryComplete = discoveryComplete
    }

    public func joins(for tableNames: [String], filter: SQLSchemaFilter = .permissive) -> [SQLJoinSuggestion] {
        let selected = Set(tableNames)
        let tablesByName = Dictionary(tables.map { ($0.qualifiedName.uppercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let viable: [SQLJoinSuggestion] = foreignKeys.compactMap { key -> SQLJoinSuggestion? in
            let sourceSelected = selected.contains(key.sourceTable)
            let destinationSelected = selected.contains(key.destinationTable)
            guard sourceSelected != destinationSelected else { return nil }
            guard let source = tablesByName[key.sourceTable.uppercased()],
                  let destination = tablesByName[key.destinationTable.uppercased()],
                  !filter.isHidden(source), !filter.isHidden(destination),
                  source.columns.contains(where: { $0.name.caseInsensitiveCompare(key.sourceColumn) == .orderedSame }),
                  destination.columns.contains(where: { $0.name.caseInsensitiveCompare(key.destinationColumn) == .orderedSame }) else { return nil }
            return SQLJoinSuggestion(
                name: key.name,
                fromTable: sourceSelected ? key.sourceTable : key.destinationTable,
                fromColumn: sourceSelected ? key.sourceColumn : key.destinationColumn,
                toTable: sourceSelected ? key.destinationTable : key.sourceTable,
                toColumn: sourceSelected ? key.destinationColumn : key.sourceColumn
            )
        }
        let unique = viable.reduce(into: [SQLJoinSuggestion]()) { result, suggestion in
            if !result.contains(where: { $0.id.caseInsensitiveCompare(suggestion.id) == .orderedSame }) { result.append(suggestion) }
        }
        return unique.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }
}

public struct SQLJoinSuggestion: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(fromTable)|\(fromColumn)|\(toTable)|\(toColumn)" }
    public var name: String
    public var fromTable: String
    public var fromColumn: String
    public var toTable: String
    public var toColumn: String

    public init(name: String, fromTable: String, fromColumn: String, toTable: String, toColumn: String) {
        self.name = name
        self.fromTable = fromTable
        self.fromColumn = fromColumn
        self.toTable = toTable
        self.toColumn = toColumn
    }

    public var label: String { "\(fromTable).\(fromColumn) = \(toTable).\(toColumn)" }
}

public struct SQLResultSet: Codable, Hashable, Sendable {
    public var columns: [String]
    public var rows: [[String]]

    public init(columns: [String] = [], rows: [[String]] = []) {
        self.columns = columns
        self.rows = rows
    }
}

public enum SQLResultFilter {
    /// Returns indices instead of copying rows, keeping large result sets cheap
    /// to display and allowing any number of returned columns.
    public static func matchingRowIndices(rows: [[String]], filters: [Int: String]) -> [Int] {
        let needles = filters.compactMapValues { value -> String? in
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : clean.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        guard !needles.isEmpty else { return Array(rows.indices) }
        return rows.indices.filter { rowIndex in
            let row = rows[rowIndex]
            return needles.allSatisfy { column, needle in
                guard row.indices.contains(column) else { return false }
                return row[column].folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(needle)
            }
        }
    }
}

public struct SQLVisualQuery: Codable, Hashable, Sendable {
    public var tables: [String]
    public var projections: [String]
    public var joins: [SQLJoinSuggestion]
    public var predicate: String
    public var limit: Int
    public var blocks: SQLQueryBlocks?

    public init(tables: [String] = [], projections: [String] = [], joins: [SQLJoinSuggestion] = [], predicate: String = "", limit: Int = 250) {
        self.tables = tables
        self.projections = projections
        self.joins = joins
        self.predicate = predicate
        self.limit = limit
    }

    public func sql(for driver: SQLDatabaseDriver) -> String {
        if let blocks {
            do { return try blocks.sql(tables: tables, limit: limit, driver: driver) }
            catch { return "-- \(error.localizedDescription)" }
        }
        guard let first = tables.first else { return "-- Add a table from Schema to begin." }
        let select = projections.isEmpty ? "\(first).*" : projections.joined(separator: ",\n  ")
        var text = "SELECT\n  \(select)\nFROM \(first)"
        var included = Set([first])
        for join in joins where included.contains(join.fromTable) && !included.contains(join.toTable) {
            text += "\nJOIN \(join.toTable) ON \(join.fromTable).\(join.fromColumn) = \(join.toTable).\(join.toColumn)"
            included.insert(join.toTable)
        }
        for table in tables.dropFirst() where !included.contains(table) {
            text += "\nCROSS JOIN \(table)"
        }
        let cleanPredicate = predicate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanPredicate.isEmpty { text += "\nWHERE \(cleanPredicate)" }
        switch driver {
        case .mysql: text += "\nLIMIT \(max(1, limit));"
        case .oracle: text += "\nFETCH FIRST \(max(1, limit)) ROWS ONLY"
        }
        return text
    }
}
