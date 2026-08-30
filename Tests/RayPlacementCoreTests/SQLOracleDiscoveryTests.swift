import Foundation
import Testing
@testable import RayPlacementCore

@Test func oracleColumnBatchesCoverEachTableOnceAndNeverMixOwners() {
    let tables = (0..<61).map { SQLTable(schema: "SALES", name: "T\($0)", kind: "TABLE") }
        + [SQLTable(schema: "HR", name: "PEOPLE", kind: "TABLE"), SQLTable(schema: "SALES", name: "T0", kind: "TABLE")]
    let batches = SQLOracleDiscovery.batches(for: tables)
    #expect(batches.count == 4)
    #expect(batches.allSatisfy { !$0.tables.isEmpty && $0.tables.count <= 25 })
    let actual = batches.flatMap { batch in batch.tables.map { "\(batch.schema).\($0)" } }
    #expect(actual.count == 62)
    #expect(Set(actual) == Set(tables.map(\.qualifiedName)))
    #expect(SQLOracleDiscovery.batches(for: []).isEmpty)
}

@Test func oracleTimedOutBatchSplitsWithoutLosingOrRepeatingTables() {
    var pending = [SQLOracleDiscovery.Batch(schema: "HR", tables: (0..<25).map { "T\($0)" })]
    var leaves: [String] = []
    while !pending.isEmpty {
        let next = pending.removeFirst()
        if next.split.isEmpty { leaves += next.tables }
        else { pending.insert(contentsOf: next.split, at: 0) }
    }
    #expect(leaves == (0..<25).map { "T\($0)" })
}

@Test func oracleDiscoveryFiltersAreEscapedAndAppliedBeforeSorting() {
    let batch = SQLOracleDiscovery.Batch(schema: "Owner's", tables: ["A'B", "C"])
    #expect(batch.predicate == "c.OWNER = 'Owner''s' AND c.TABLE_NAME IN ('A''B', 'C')")
    #expect(SQLOracleDiscovery.filtered("SELECT * FROM columns c ORDER BY c.COLUMN_ID", predicate: batch.predicate, hasWhere: false)
        == "SELECT * FROM columns c WHERE \(batch.predicate) ORDER BY c.COLUMN_ID")
    let original = "SELECT * FROM indexes WHERE ACTIVE = 1 ORDER BY NAME"
    #expect(SQLOracleDiscovery.scoped(original, owner: "OWNER", schemas: [], hasWhere: true) == original)
    #expect(SQLOracleDiscovery.scoped(original, owner: "OWNER", schemas: ["HR"], hasWhere: true)
        == "SELECT * FROM indexes WHERE ACTIVE = 1 AND (OWNER IN ('HR')) ORDER BY NAME")
    let many = SQLOracleDiscovery.scoped("SELECT * FROM tables", owner: "OWNER", schemas: (0..<1100).map { "S\($0)" }, hasWhere: false)
    #expect(many.components(separatedBy: "OWNER IN (").count - 1 == 3)
}

@Test func discoveryScopeAndPartialCacheRemainBackwardCompatible() throws {
    let profile = SQLConnectionProfile(name: "Test", environment: "Development", driver: .oracle, host: "localhost", database: "FREEPDB1", username: "lima_test", discoverySchemas: ["LIMA_TEST"])
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
    object.removeValue(forKey: "discoverySchemas")
    let oldProfile = try JSONDecoder().decode(SQLConnectionProfile.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(oldProfile.discoverySchemas == nil)
    #expect(try JSONDecoder().decode(SQLConnectionProfile.self, from: JSONEncoder().encode(profile)).discoverySchemas == ["LIMA_TEST"])
    let partial = SQLSchemaSnapshot(profileID: profile.id, tables: [SQLTable(schema: "HR", name: "EMPLOYEES", kind: "TABLE")], discoveryComplete: false)
    #expect(try JSONDecoder().decode(SQLSchemaSnapshot.self, from: JSONEncoder().encode(partial)).discoveryComplete == false)
    var snapshot = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(partial)) as? [String: Any])
    snapshot.removeValue(forKey: "discoveryComplete")
    #expect(try JSONDecoder().decode(SQLSchemaSnapshot.self, from: JSONSerialization.data(withJSONObject: snapshot)).discoveryComplete == nil)
}

/// Opt-in, read-only integration using the existing local Oracle fixture.
/// It executes the app's actual column query with the production batch filter.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LIMA_ORACLE_TEST_CONTAINER"] != nil))
func oracleBatchedColumnsMatchUnbatchedMetadataInLocalDatabase() throws {
    let container = try #require(ProcessInfo.processInfo.environment["LIMA_ORACLE_TEST_CONTAINER"])
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(contentsOf: root.appendingPathComponent("Sources/RayPlacement/SQLWorkspaceWindowController.swift"), encoding: .utf8)
    let line = try #require(source.components(separatedBy: .newlines).first { $0.contains("return \"SELECT c.OWNER") && $0.contains("FROM ALL_TAB_COLUMNS") })
    let query = String(line.trimmingCharacters(in: .whitespaces).dropFirst("return \"".count).dropLast())
    func execute(_ sql: String) throws -> SQLResultSet {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker", "exec", "-i", container, "sqlplus", "-s", "/", "as", "sysdba"]
        let input = "WHENEVER SQLERROR EXIT SQL.SQLCODE\nSET FEEDBACK OFF\nSET MARKUP CSV ON DELIMITER | QUOTE ON\nSET LONG 1000000 LONGCHUNKSIZE 1000000\nSET ARRAYSIZE 500\n\(sql);\nEXIT\n"
        let output = try SQLClientProcess.run(process, input: Data(input.utf8), timeout: 120)
        #expect(process.terminationStatus == 0)
        let text = String(decoding: output.stdout, as: UTF8.self)
        #expect(!text.contains("ORA-"))
        return SQLOracleOutput.parse(text)
    }
    let baseline = try execute(SQLOracleDiscovery.scoped(query, owner: "c.OWNER", schemas: ["SYSTEM"], hasWhere: false))
    #expect(!baseline.rows.isEmpty)
    let tables = Set(baseline.rows.map { $0[1] }).map { SQLTable(schema: "SYSTEM", name: $0, kind: "TABLE") }
    let batches = SQLOracleDiscovery.batches(for: tables)
    #expect(batches.count > 1)
    let batched = try batches.flatMap { try execute(SQLOracleDiscovery.filtered(query, predicate: $0.predicate, hasWhere: false)).rows }
    #expect(Set(batched) == Set(baseline.rows))
    #expect(batched.count == baseline.rows.count)

    // Validate the saved owner filter against the other production queries,
    // including the UNION used for tables/views and existing WHERE clauses.
    let catalogStart = try #require(source.range(of: "private static func tablesQuery"))
    let catalogEnd = try #require(source.range(of: "private struct SQLLocalCollection"))
    var oracle = false
    var queries: [String] = []
    for rawLine in source[catalogStart.lowerBound..<catalogEnd.lowerBound].components(separatedBy: .newlines) {
        let value = rawLine.trimmingCharacters(in: .whitespaces)
        if value == "case .oracle:" { oracle = true }
        else if oracle && value.hasPrefix("return \"") {
            queries.append(String(value.dropFirst("return \"".count).dropLast()))
            oracle = false
        }
    }
    #expect(queries.count == 6)
    let ownerColumns = ["OWNER", "c.OWNER", "i.TABLE_OWNER", "OWNER", "c.OWNER", "OWNER"]
    for (index, catalog) in queries.enumerated() {
        let statement = index == 0 ? "SELECT * FROM (\(catalog)) ORDER BY OWNER, TABLE_NAME" : catalog
        let scoped = SQLOracleDiscovery.scoped(statement, owner: ownerColumns[index], schemas: ["LIMA_TEST"], hasWhere: index >= 2)
        let result = try execute(scoped)
        #expect(result.rows.allSatisfy { $0.first == "LIMA_TEST" })
    }
}
