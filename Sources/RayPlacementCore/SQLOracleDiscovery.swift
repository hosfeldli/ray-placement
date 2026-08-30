import Foundation

public enum SQLOracleDiscovery {
    public struct Batch: Sendable {
        public let schema: String
        public let tables: [String]

        public init(schema: String, tables: [String]) {
            self.schema = schema
            self.tables = tables
        }

        public var predicate: String {
            "c.OWNER = \(SQLOracleDiscovery.literal(schema)) AND c.TABLE_NAME IN (\(tables.map(SQLOracleDiscovery.literal).joined(separator: ", ")))"
        }

        public var split: [Batch] {
            guard tables.count > 1 else { return [] }
            let middle = tables.count / 2
            return [Batch(schema: schema, tables: Array(tables[..<middle])), Batch(schema: schema, tables: Array(tables[middle...]))]
        }
    }

    public static func batches(for tables: [SQLTable], size: Int = 25) -> [Batch] {
        let limit = max(1, min(size, 500))
        let groups = Dictionary(grouping: tables, by: \.schema)
        return groups.keys.sorted().flatMap { schema in
            let names = Array(Set(groups[schema, default: []].map(\.name))).sorted()
            return stride(from: 0, to: names.count, by: limit).map { start in
                Batch(schema: schema, tables: Array(names[start..<min(start + limit, names.count)]))
            }
        }
    }

    public static func literal(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// The statements are internal catalog queries with a final ORDER BY.
    /// Keep the owner/table predicate inside the catalog query so Oracle can
    /// filter its dictionary access before joining comments or sorting rows.
    public static func filtered(_ query: String, predicate: String, hasWhere: Bool) -> String {
        guard let order = query.range(of: " ORDER BY ", options: .backwards) else {
            return query + (hasWhere ? " AND " : " WHERE ") + predicate
        }
        return String(query[..<order.lowerBound]) + (hasWhere ? " AND " : " WHERE ") + predicate + query[order.lowerBound...]
    }

    public static func scoped(_ query: String, owner: String, schemas: [String], hasWhere: Bool) -> String {
        guard !schemas.isEmpty else { return query }
        let groups = stride(from: 0, to: schemas.count, by: 500).map { start in
            "\(owner) IN (\(schemas[start..<min(start + 500, schemas.count)].map(literal).joined(separator: ", ")))"
        }
        return filtered(query, predicate: "(" + groups.joined(separator: " OR ") + ")", hasWhere: hasWhere)
    }
}
