import Foundation
import Testing
@testable import RayPlacementCore

@Test @MainActor func sqlCredentialsLoadOncePerConnectionAndCanBeLocked() {
    let session = SQLSessionCredentials(), a = UUID(), b = UUID()
    var loads = 0
    func load() -> String? { loads += 1; return "test-only" }
    #expect(session.password(for: a, load: load) == "test-only")
    #expect(session.password(for: a, load: load) == "test-only")
    #expect(loads == 1)
    _ = session.password(for: b, load: load)
    #expect(loads == 2)
    session.set("changed", for: a)
    #expect(session.password(for: a, load: load) == "changed")
    session.remove(a)
    _ = session.password(for: a, load: load)
    #expect(loads == 3)
    session.clear()
    _ = session.password(for: b, load: load)
    #expect(loads == 4)
    let missing = UUID()
    #expect(session.password(for: missing, load: { nil }) == nil)
    #expect(session.password(for: missing, load: load) == "test-only")
}

@Test func schemaSearchRanksExactNamesAheadOfPrefixesAndColumnsAndFiltersOwners() {
    let tables = [SQLTable(schema: "A", name: "ORDERS_ARCHIVE", kind: "TABLE"),
                  SQLTable(schema: "Z", name: "ORDERS", kind: "TABLE"),
                  SQLTable(schema: "B", name: "ORDERS", kind: "TABLE"),
                  SQLTable(schema: "A", name: "CUSTOMERS", kind: "TABLE", columns: [SQLColumn(name: "ORDERS", dataType: "NUMBER", nullable: true, ordinal: 1)])]
    #expect(SQLSchemaSearch.tables(tables, query: " orders ").map(\.qualifiedName) == ["B.ORDERS", "Z.ORDERS", "A.ORDERS_ARCHIVE", "A.CUSTOMERS"])
    #expect(SQLSchemaSearch.tables(tables, query: "orders", owner: "Z").map(\.qualifiedName) == ["Z.ORDERS"])
    #expect(SQLSchemaSearch.tables(tables, query: "z.orders").first?.schema == "Z")
}

@Test func indexedSchemaSearchMatchesExistingRankingAndSeparatesOwners() {
    let tables = (0..<300).map { SQLTable(schema: "OWNER\($0 % 3)", name: "TABLE\($0)", kind: $0 % 7 == 0 ? "VIEW" : "TABLE", columns: [SQLColumn(name: "VALUE", dataType: "NUMBER", nullable: true, ordinal: 1)]) }
    let index = SQLSchemaIndex(snapshot: SQLSchemaSnapshot(profileID: UUID(), tables: tables))
    for query in ["", "table1", "TABLE10", "value", "owner1.table", "missing"] {
        for owner in ["", "OWNER1"] {
            for kind in ["TABLE", "VIEW"] {
                #expect(index.tables(query: query, owner: owner, kind: kind) == SQLSchemaSearch.tables(tables, query: query, owner: owner, kind: kind))
            }
        }
    }
    #expect(index.owners == ["OWNER0", "OWNER1", "OWNER2"])
    #expect(index.tablesByID[tables[25].id] == tables[25])
}

@Test func schemaIndexLargeCatalogBenchmark() {
    let tables = (0..<10_000).map { SQLTable(schema: "APP", name: "T\($0)", kind: "TABLE") }
    let index = SQLSchemaIndex(snapshot: SQLSchemaSnapshot(profileID: UUID(), tables: tables))
    let queries = ["", "T1", "T500", "missing", "APP"]
    let start = ContinuousClock.now
    for query in queries { _ = SQLSchemaSearch.tables(tables, query: query) }
    let oldTime = start.duration(to: .now)
    let indexedStart = ContinuousClock.now
    for query in queries { _ = index.tables(query: query, owner: "", kind: "TABLE") }
    print("10,000-table navigation benchmark, five searches: original \(oldTime), indexed \(indexedStart.duration(to: .now))")
    #expect(index.tables(query: "T500", owner: "APP", kind: "TABLE").first?.name == "T500")
}

@Test func sqlResultFiltersEveryReturnedColumnWithoutRowOrFieldCaps() {
    let rows = (0..<2_000).map { row in
        (0..<180).map { column in column == 179 ? "tail-\(row)" : "r\(row)-c\(column)" }
    }
    #expect(SQLResultFilter.matchingRowIndices(rows: rows, filters: [0: "R1999-C0", 179: "TAIL-1999"]) == [1_999])
    #expect(SQLResultFilter.matchingRowIndices(rows: rows, filters: [179: "tail-"]).count == 2_000)
}

@Test func nestedFiltersPreserveBooleanPrecedenceAndEscapeText() throws {
    let filter = SQLFilterBlock(kind: .all, children: [
        SQLFilterBlock(field: "name", value: "O'Brien"),
        SQLFilterBlock(kind: .any, children: [SQLFilterBlock(field: "amount", comparison: .between, valueType: .number, value: "10", upperValue: "20"), SQLFilterBlock(kind: .not, children: [SQLFilterBlock(field: "archived", comparison: .isNull)])])
    ])
    #expect(try filter.sql() == "(name = 'O''Brien' AND (amount BETWEEN 10 AND 20 OR NOT (archived IS NULL)))")
    #expect(try SQLFilterBlock(field: "city", comparison: .inside, value: "New York\nA,B\nO'Brien").sql() == "city IN ('New York', 'A,B', 'O''Brien')")
    #expect(throws: SQLBlockError.self) { try SQLFilterBlock(field: "amount", valueType: .number, value: "1; DELETE FROM t").sql() }
    #expect(throws: SQLBlockError.self) { try SQLFilterBlock(kind: .all).sql() }
    #expect(throws: SQLBlockError.self) { try SQLFilterBlock(kind: .expression, field: "1=1; DELETE FROM t").sql() }
}

private func aggregateQuery() -> SQLQueryBlocks {
    var blocks = SQLQueryBlocks()
    blocks.joins = [SQLJoinBlock(table: "ALL_TABLES", condition: SQLFilterBlock(kind: .all, children: [
        SQLFilterBlock(field: "ALL_TAB_COLUMNS.OWNER", valueType: .expression, value: "ALL_TABLES.OWNER"),
        SQLFilterBlock(field: "ALL_TAB_COLUMNS.TABLE_NAME", valueType: .expression, value: "ALL_TABLES.TABLE_NAME")
    ]))]
    blocks.filters = [SQLFilterBlock(field: "ALL_TAB_COLUMNS.OWNER", value: "SYSTEM")]
    blocks.groupBy = ["ALL_TAB_COLUMNS.OWNER"]
    var count = SQLAggregateBlock(); count.alias = "Column count"
    blocks.aggregates = [count]
    blocks.having = [SQLFilterBlock(field: "COUNT(*)", comparison: .greater, valueType: .number, value: "0")]
    var sort = SQLSortBlock(); sort.field = "COUNT(*)"; sort.descending = true; blocks.sorts = [sort]
    return blocks
}

@Test func blocksGenerateJoinsAggregationHavingSortAndDialectLimits() throws {
    let blocks = aggregateQuery()
    let oracle = try blocks.sql(tables: ["ALL_TAB_COLUMNS"], limit: 10, driver: .oracle)
    #expect(oracle.contains("INNER JOIN ALL_TABLES ON (ALL_TAB_COLUMNS.OWNER = ALL_TABLES.OWNER AND ALL_TAB_COLUMNS.TABLE_NAME = ALL_TABLES.TABLE_NAME)"))
    #expect(oracle.contains("COUNT(*) AS \"Column count\""))
    #expect(oracle.contains("GROUP BY ALL_TAB_COLUMNS.OWNER\nHAVING (COUNT(*) > 0)\nORDER BY COUNT(*) DESC\nFETCH FIRST 10 ROWS ONLY"))
    #expect(try blocks.sql(tables: ["ALL_TAB_COLUMNS"], limit: 10, driver: .mysql).hasSuffix("LIMIT 10;"))
    var invalid = blocks
    invalid.columns = ["ALL_TAB_COLUMNS.COLUMN_NAME"]
    #expect(throws: SQLBlockError.self) { try invalid.sql(tables: ["ALL_TAB_COLUMNS"], limit: 10, driver: .oracle) }
    invalid = blocks; invalid.joins[0].style = .full
    #expect(throws: SQLBlockError.self) { try invalid.sql(tables: ["ALL_TAB_COLUMNS"], limit: 10, driver: .mysql) }
    invalid = blocks; invalid.joins.append(invalid.joins[0])
    #expect(throws: SQLBlockError.self) { try invalid.sql(tables: ["ALL_TAB_COLUMNS"], limit: 10, driver: .oracle) }
}

@Test func allFilterOperatorsCompileAndAggregateWildcardsAreChecked() throws {
    for comparison in SQLFilterBlock.Comparison.allCases {
        let node = SQLFilterBlock(field: "value", comparison: comparison, valueType: .number, value: "1", upperValue: "2")
        #expect(try node.sql().contains(comparison.rawValue))
    }
    var aggregate = SQLAggregateBlock(); aggregate.function = .sum
    #expect(throws: SQLBlockError.self) { try aggregate.sql() }
    aggregate.field = "amount"; aggregate.distinct = true
    #expect(try aggregate.sql() == "SUM(DISTINCT amount)")
}

@Test func mysqlTextWithBackslashesDoesNotDependOnSQLMode() throws {
    let filter = SQLFilterBlock(field: "path", value: "C:\\data")
    #expect(try filter.sql(driver: .mysql) == "path = CONVERT(X'433a5c64617461' USING utf8mb4)")
    #expect(try filter.sql(driver: .oracle) == "path = 'C:\\data'")
    var aggregate = SQLAggregateBlock(); aggregate.alias = "a`b"
    #expect(try aggregate.sql(driver: .mysql) == "COUNT(*) AS `a``b`")
}

@Test func blockQueriesRoundTripAndOldVisualQueriesStillDecode() throws {
    var query = SQLVisualQuery(tables: ["ALL_TAB_COLUMNS"])
    query.blocks = aggregateQuery()
    let decoded = try JSONDecoder().decode(SQLVisualQuery.self, from: JSONEncoder().encode(query))
    #expect(decoded == query)
    var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(query)) as? [String: Any])
    old.removeValue(forKey: "blocks")
    #expect(try JSONDecoder().decode(SQLVisualQuery.self, from: JSONSerialization.data(withJSONObject: old)).blocks == nil)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LIMA_ORACLE_TEST_CONTAINER"] != nil))
func generatedBlockQueryExecutesOnOracle() throws {
    let sql = try aggregateQuery().sql(tables: ["ALL_TAB_COLUMNS"], limit: 10, driver: .oracle)
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["docker", "exec", "-i", ProcessInfo.processInfo.environment["LIMA_ORACLE_TEST_CONTAINER"]!, "sqlplus", "-s", "/", "as", "sysdba"]
    let input = "WHENEVER SQLERROR EXIT SQL.SQLCODE\nSET MARKUP CSV ON DELIMITER | QUOTE ON\nSET FEEDBACK OFF\n\(sql);\nEXIT\n"
    let output = try SQLClientProcess.run(process, input: Data(input.utf8), timeout: 120)
    #expect(process.terminationStatus == 0)
    let result = SQLOracleOutput.parse(String(decoding: output.stdout, as: UTF8.self))
    #expect(result.rows.count == 1)
    #expect(result.rows.first?.first == "SYSTEM")
    #expect((Int(result.rows.first?.last ?? "") ?? 0) > 0)
}
