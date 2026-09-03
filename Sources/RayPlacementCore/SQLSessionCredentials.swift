import Foundation

/// Session-only storage. Never included in workspace serialization or logs.
@MainActor
public final class SQLSessionCredentials {
    private var passwords: [UUID: String] = [:]
    public init() {}
    public func password(for id: UUID, load: () -> String?) -> String? {
        if let cached = passwords[id] { return cached }
        guard let password = load() else { return nil }
        passwords[id] = password
        return password
    }
    public func set(_ password: String, for id: UUID) { passwords[id] = password }
    public func remove(_ id: UUID) { passwords.removeValue(forKey: id) }
    public func clear() { passwords.removeAll() }
}

public enum SQLSchemaSearch {
    public static func tables(_ tables: [SQLTable], query: String, owner: String = "", kind: String = "TABLE") -> [SQLTable] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func rank(_ table: SQLTable) -> Int {
            if query.isEmpty { return 0 }
            let name = table.name.lowercased(), qualified = table.qualifiedName.lowercased()
            if name == query || qualified == query { return 0 }
            if name.hasPrefix(query) { return 1 }
            if qualified.contains(query) { return 2 }
            return 3
        }
        return tables.filter { table in
            (owner.isEmpty || table.schema == owner) && table.kind.uppercased().contains(kind) &&
            (query.isEmpty || table.qualifiedName.lowercased().contains(query) || table.columns.contains { $0.name.lowercased().contains(query) })
        }.sorted {
            let a = rank($0), b = rank($1)
            return a == b ? $0.qualifiedName.localizedStandardCompare($1.qualifiedName) == .orderedAscending : a < b
        }
    }
}

/// Built once per metadata revision. Search is a linear bucket pass rather
/// than sorting/lowercasing the entire catalog for every SwiftUI update.
public struct SQLSchemaIndex: Sendable {
    private struct Entry: Sendable {
        var table: SQLTable
        var name: String
        var qualified: String
        var columns: [String]
    }
    private var entries: [Entry]
    private var procedures: [SQLProcedure]
    public let owners: [String]
    public let tablesByID: [String: SQLTable]

    public init(snapshot: SQLSchemaSnapshot) {
        let sorted = snapshot.tables.sorted { $0.qualifiedName.localizedStandardCompare($1.qualifiedName) == .orderedAscending }
        entries = sorted.map { Entry(table: $0, name: $0.name.lowercased(), qualified: $0.qualifiedName.lowercased(), columns: $0.columns.map { $0.name.lowercased() }) }
        procedures = snapshot.procedures
        owners = Array(Set(snapshot.tables.map(\.schema) + snapshot.procedures.map(\.schema))).sorted()
        tablesByID = Dictionary(sorted.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func tables(query: String, owner: String, kind: String, filter: SQLSchemaFilter = .permissive) -> [SQLTable] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tokens = normalizedQuery.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var buckets = [[SQLTable]](repeating: [], count: 4)

        for entry in entries where (owner.isEmpty || entry.table.schema == owner) && entry.table.kind.uppercased().contains(kind) && !filter.isHidden(entry.table) {
            guard tokens.isEmpty || tokens.allSatisfy({ token in
                entry.name.contains(token) || entry.qualified.contains(token) || entry.columns.contains { $0.contains(token) }
            }) else { continue }

            if tokens.isEmpty || (tokens.count == 1 && (entry.name == normalizedQuery || entry.qualified == normalizedQuery)) {
                buckets[0].append(entry.table)
            } else if tokens.allSatisfy({ entry.name.hasPrefix($0) }) {
                buckets[1].append(entry.table)
            } else if tokens.allSatisfy({ entry.qualified.contains($0) }) {
                buckets[2].append(entry.table)
            } else {
                buckets[3].append(entry.table)
            }
        }
        return buckets.flatMap { $0 }
    }

    public func hiddenTableCount(filter: SQLSchemaFilter) -> Int {
        entries.reduce(into: 0) { if filter.isHidden($1.table) { $0 += 1 } }
    }

    public func procedures(query: String, owner: String) -> [SQLProcedure] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return procedures.filter { (owner.isEmpty || $0.schema == owner) && (query.isEmpty || $0.qualifiedName.lowercased().contains(query)) }
    }
}
