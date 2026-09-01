import AppKit
import Foundation
import RayPlacementCore
import Security
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SQLWorkspaceWindowController: NSWindowController {
    private let model = SQLWorkspaceModel()
    private var hasPresented = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 790),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "SQL Workspace"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 920, height: 600)
        window.setAccessibilityLabel("RayPlacement SQL workspace")
        self.init(window: window)
        window.contentView = NSHostingView(rootView: LimaTypographyRoot(content: SQLWorkspaceView(model: model)))
    }

    func present() {
        if !hasPresented {
            window?.center()
            hasPresented = true
        }
        if let window { WorkspaceWindowCoordinator.shared.present(window) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func shutdown() { model.cancel() }
}

private enum SQLCredentialVault {
    private static let service = "com.rayplacement.sql.connection"

    static func password(for profileID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ password: String, for profileID: UUID) throws {
        let account = profileID.uuidString
        let data = Data(password.utf8)
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = match
            item.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SQLWorkspaceError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw SQLWorkspaceError.keychain(status)
        }
    }

    static func delete(profileID: UUID) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString
        ] as CFDictionary)
    }
}

private enum SQLWorkspaceError: LocalizedError {
    case missingClient(SQLDatabaseDriver, String)
    case missingSecret
    case invalidConnection
    case invalidPort
    case commandFailed(String)
    case keychain(OSStatus)
    case readOnly

    var errorDescription: String? {
        switch self {
        case .missingClient(let driver, let path):
            return "\(driver.title) client not found at \(path). Install its command-line client or set its location in this connection."
        case .missingSecret: return "Save a password for this connection in the Keychain first."
        case .invalidConnection: return "Complete the connection name, host, database/service, and username."
        case .invalidPort: return "Enter a port from 1 to 65535 using plain digits (for example, 1521)."
        case .commandFailed(let message): return message
        case .keychain(let status): return "Keychain could not save this connection (status \(status))."
        case .readOnly: return "Read-only mode only runs SELECT, WITH, SHOW, DESCRIBE, or EXPLAIN statements."
        }
    }
}

private enum SQLCommandLineClient {
    static func execute(profile: SQLConnectionProfile, password: String, sql: String, timeout: TimeInterval = 3600) async throws -> SQLResultSet {
        let output = try await raw(profile: profile, password: password, sql: sql, timeout: timeout)
        return parse(output, driver: profile.driver)
    }

    static func raw(profile: SQLConnectionProfile, password: String, sql: String, timeout: TimeInterval = 3600) async throws -> String {
        let client = try resolvedClient(for: profile)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = client
                let input: String
                switch profile.driver {
                case .mysql:
                    process.arguments = ["--batch", "--raw", "--host", profile.host, "--port", String(profile.port), "--user", profile.username, profile.database]
                    var environment = ProcessInfo.processInfo.environment
                    environment["MYSQL_PWD"] = password
                    process.environment = environment
                    input = sql.hasSuffix(";") ? sql + "\n" : sql + ";\n"
                case .oracle:
                    // Starting disconnected prevents sqlplus from interpreting the
                    // first line of the supplied script as a login value.
                    process.arguments = ["-L", "-S", "/nolog"]
                    let oracleUser = SQLOracleConnectionSyntax.identifier(for: profile.username)
                    let escapedPassword = password.replacingOccurrences(of: "\"", with: "\\\"")
                    input = """
                    WHENEVER OSERROR EXIT FAILURE ROLLBACK
                    WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
                    SET HEADING ON FEEDBACK OFF VERIFY OFF ECHO OFF PAGESIZE 50000 LINESIZE 32767 TRIMSPOOL ON
                    SET MARKUP CSV ON DELIMITER | QUOTE ON
                    SET LONG 1000000 LONGCHUNKSIZE 1000000
                    SET ARRAYSIZE 500
                    CONNECT \(oracleUser)/\"\(escapedPassword)\"@//\(profile.host):\(profile.port)/\(profile.database)
                    \(sql.hasSuffix(";") ? sql : sql + ";")
                    EXIT
                    """
                }

                do {
                    let captured = try SQLClientProcess.run(process, input: Data(input.utf8), timeout: timeout)
                    let out = String(decoding: captured.stdout, as: UTF8.self)
                    let err = String(decoding: captured.stderr, as: UTF8.self)
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: out)
                    } else {
                        let detail = failureDetail(stdout: out, stderr: err)
                        continuation.resume(throwing: SQLWorkspaceError.commandFailed(detail.isEmpty ? "Database client exited with status \(process.terminationStatus)." : detail))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func isPotentiallyDestructive(_ sql: String) -> Bool {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return ["INSERT", "UPDATE", "DELETE", "MERGE", "DROP", "ALTER", "TRUNCATE", "CREATE", "GRANT", "REVOKE", "CALL", "BEGIN", "DECLARE"].contains { trimmed.hasPrefix($0) }
    }

    static func isReadOnly(_ sql: String) -> Bool {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return ["SELECT", "WITH", "SHOW", "DESCRIBE", "DESC", "EXPLAIN"].contains { trimmed.hasPrefix($0) }
    }

    private static func resolvedClient(for profile: SQLConnectionProfile) throws -> URL {
        let fileManager = FileManager.default
        let candidates = [profile.commandPath] + {
            switch profile.driver {
            case .mysql: return ["/opt/homebrew/bin/mysql", "/usr/local/bin/mysql", "/usr/bin/mysql"]
            case .oracle: return ["/opt/homebrew/bin/sqlplus", "/usr/local/bin/sqlplus", "/usr/bin/sqlplus"]
            }
        }()
        guard let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
            throw SQLWorkspaceError.missingClient(profile.driver, profile.commandPath)
        }
        return URL(fileURLWithPath: path)
    }

    /// Oracle reports many connection errors to standard output. Only surface
    /// recognizable client error lines so query results and credentials never
    /// end up in a status message.
    private static func failureDetail(stdout: String, stderr: String) -> String {
        let standardError = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !standardError.isEmpty { return standardError }
        let recognizable = stdout
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                let uppercased = line.uppercased()
                return uppercased.contains("ORA-") || uppercased.contains("SP2-") ||
                    uppercased.contains("ACCESS DENIED") || uppercased.contains("ERROR ") ||
                    uppercased.contains("CONNECTION REFUSED")
            }
            .prefix(4)
        return recognizable.joined(separator: "\n")
    }

    private static func parse(_ output: String, driver: SQLDatabaseDriver) -> SQLResultSet {
        if driver == .oracle { return SQLOracleOutput.parse(output) }
        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let header = lines.first else { return SQLResultSet() }
        let columns = header.components(separatedBy: "\t")
        let rows = lines.dropFirst().map { line in
            var row = line.components(separatedBy: "\t")
            if row.count < columns.count { row += Array(repeating: "", count: columns.count - row.count) }
            return Array(row.prefix(columns.count))
        }
        return SQLResultSet(columns: columns, rows: rows)
    }
}

private enum SQLSchemaDiscovery {
    typealias ProgressHandler = @MainActor @Sendable (_ completed: Int, _ total: Int, _ activity: String) -> Void
    typealias CheckpointHandler = @MainActor @Sendable (SQLSchemaSnapshot) -> Void

    static func discover(profile: SQLConnectionProfile, password: String, progress: @escaping ProgressHandler, checkpoint: @escaping CheckpointHandler) async throws -> SQLSchemaSnapshot {
        var totalSteps = 6
        var completed = 0
        let owners = profile.driver == .oracle ? (profile.discoverySchemas ?? []) : []

        await progress(0, totalSteps, "Reading tables and views")
        let tableSQL = tablesQuery(for: profile.driver)
        // A wrapper applies the owner restriction to both arms of the UNION.
        let scopedTables = owners.isEmpty ? tableSQL : SQLOracleDiscovery.scoped("SELECT * FROM (\(tableSQL)) ORDER BY OWNER, TABLE_NAME", owner: "OWNER", schemas: owners, hasWhere: false)
        let tableResult = try await run(profile, password, query: scopedTables)
        var tables = tableResult.rows.compactMap { row -> SQLTable? in
            guard row.count >= 3 else { return nil }
            return SQLTable(schema: clean(row[0]), name: clean(row[1]), kind: clean(row[2]), description: nullable(row, 3))
        }
        let tableIndex = Dictionary(uniqueKeysWithValues: tables.indices.map { (tables[$0].qualifiedName, $0) })
        completed = 1
        await checkpoint(SQLSchemaSnapshot(profileID: profile.id, tables: tables, discoveryComplete: false))

        func applyColumns(_ result: SQLResultSet) {
            for row in result.rows where row.count >= 7 {
                let tableName = qualified(schema: row[0], table: row[1])
                guard let index = tableIndex[tableName] else { continue }
                tables[index].columns.append(SQLColumn(
                    name: clean(row[2]), dataType: clean(row[3]), nullable: clean(row[4]).uppercased() == "Y" || clean(row[4]).uppercased() == "YES",
                    ordinal: Int(clean(row[5])) ?? 0, defaultValue: nullable(row, 6), description: nullable(row, 7)
                ))
            }
        }

        if profile.driver == .oracle {
            var pending = SQLOracleDiscovery.batches(for: tables)
            totalSteps = 5 + max(1, pending.count)
            var loadedTables = 0
            if pending.isEmpty { completed += 1 }
            while !pending.isEmpty {
                try Task.checkCancellation()
                let batch = pending.removeFirst()
                let label = "Columns · \(batch.schema) · \(loadedTables)/\(tables.count) tables · reading \(batch.tables.first ?? "") (\(batch.tables.count) tables)"
                await progress(completed, totalSteps, label)
                let query = SQLOracleDiscovery.filtered(columnsQuery(for: .oracle), predicate: batch.predicate, hasWhere: false)
                do {
                    applyColumns(try await run(profile, password, query: query))
                    loadedTables += batch.tables.count
                    completed += 1
                    await checkpoint(SQLSchemaSnapshot(profileID: profile.id, tables: tables, discoveryComplete: false))
                } catch is SQLClientProcess.Timeout {
                    guard !batch.split.isEmpty else {
                        throw SQLWorkspaceError.commandFailed("Column discovery timed out for \(batch.schema).\(batch.tables[0]). Completed tables are retained. Edit the connection's Discovery schemas to narrow the scan, or ask your DBA to check catalog access for this table.")
                    }
                    totalSteps += 1
                    pending.insert(contentsOf: batch.split, at: 0)
                    await progress(completed, totalSteps, "\(batch.schema) batch timed out · retrying smaller table batches")
                }
            }
        } else {
            await progress(completed, totalSteps, "Reading columns")
            applyColumns(try await run(profile, password, query: columnsQuery(for: .mysql)))
            completed += 1
            await checkpoint(SQLSchemaSnapshot(profileID: profile.id, tables: tables, discoveryComplete: false))
        }

        await progress(completed, totalSteps, "Reading indexes")
        let indexResult = try await run(profile, password, query: SQLOracleDiscovery.scoped(indexesQuery(for: profile.driver), owner: "i.TABLE_OWNER", schemas: owners, hasWhere: true))
        for row in indexResult.rows where row.count >= 6 {
            let tableName = qualified(schema: row[0], table: row[1])
            guard let index = tableIndex[tableName] else { continue }
            tables[index].indexes.append(SQLIndex(table: tableName, name: clean(row[2]), column: clean(row[5]), ordinal: Int(clean(row[4])) ?? 0, unique: clean(row[3]) == "0" || clean(row[3]).uppercased() == "UNIQUE"))
        }

        completed += 1
        await checkpoint(SQLSchemaSnapshot(profileID: profile.id, tables: tables, discoveryComplete: false))
        await progress(completed, totalSteps, "Reading constraints")
        let constraints = try await run(profile, password, query: SQLOracleDiscovery.scoped(constraintsQuery(for: profile.driver), owner: "OWNER", schemas: owners, hasWhere: true))
        for row in constraints.rows where row.count >= 4 {
            let tableName = qualified(schema: row[0], table: row[1])
            guard let index = tableIndex[tableName] else { continue }
            tables[index].constraints.append("\(clean(row[2])) · \(clean(row[3]))")
        }

        completed += 1
        await checkpoint(SQLSchemaSnapshot(profileID: profile.id, tables: tables, discoveryComplete: false))
        await progress(completed, totalSteps, "Mapping relationships")
        let foreignKeyResult = try await run(profile, password, query: SQLOracleDiscovery.scoped(foreignKeysQuery(for: profile.driver), owner: "c.OWNER", schemas: owners, hasWhere: true))
        let foreignKeys = foreignKeyResult.rows.compactMap { row -> SQLForeignKey? in
            guard row.count >= 7 else { return nil }
            return SQLForeignKey(
                name: clean(row[2]), sourceTable: qualified(schema: row[0], table: row[1]), sourceColumn: clean(row[3]),
                destinationTable: qualified(schema: row[4], table: row[5]), destinationColumn: clean(row[6])
            )
        }

        completed += 1
        await checkpoint(SQLSchemaSnapshot(profileID: profile.id, tables: tables, foreignKeys: foreignKeys, discoveryComplete: false))
        await progress(completed, totalSteps, "Reading procedures and functions")
        let procedureResult = try await run(profile, password, query: SQLOracleDiscovery.scoped(proceduresQuery(for: profile.driver), owner: "OWNER", schemas: owners, hasWhere: true))
        let procedures = procedureResult.rows.compactMap { row -> SQLProcedure? in
            guard row.count >= 3 else { return nil }
            return SQLProcedure(schema: clean(row[0]), name: clean(row[1]), kind: clean(row[2]), description: nullable(row, 3))
        }
        tables.sort { $0.qualifiedName.localizedStandardCompare($1.qualifiedName) == .orderedAscending }
        await progress(totalSteps, totalSteps, "Finalizing schema")
        return SQLSchemaSnapshot(profileID: profile.id, tables: tables, foreignKeys: foreignKeys, procedures: procedures)
    }

    private static func run(_ profile: SQLConnectionProfile, _ password: String, query: String) async throws -> SQLResultSet {
        try Task.checkCancellation()
        return try await SQLCommandLineClient.execute(profile: profile, password: password, sql: query, timeout: 120)
    }

    private static func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func nullable(_ row: [String], _ index: Int) -> String? {
        guard row.indices.contains(index) else { return nil }
        let value = clean(row[index])
        return value.isEmpty || value == "NULL" || value == "\\N" ? nil : value
    }
    private static func qualified(schema: String, table: String) -> String {
        let schema = clean(schema); let table = clean(table)
        return schema.isEmpty ? table : "\(schema).\(table)"
    }

    private static func tablesQuery(for driver: SQLDatabaseDriver) -> String {
        switch driver {
        case .mysql:
            return "SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE, IFNULL(TABLE_COMMENT, '') AS DESCRIPTION FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = DATABASE() ORDER BY TABLE_SCHEMA, TABLE_NAME"
        case .oracle:
            return "SELECT t.OWNER, t.TABLE_NAME, 'TABLE' AS KIND, NVL(c.COMMENTS, '') AS DESCRIPTION FROM ALL_TABLES t LEFT JOIN ALL_TAB_COMMENTS c ON c.OWNER=t.OWNER AND c.TABLE_NAME=t.TABLE_NAME UNION ALL SELECT v.OWNER, v.VIEW_NAME, 'VIEW' AS KIND, NVL(c.COMMENTS, '') AS DESCRIPTION FROM ALL_VIEWS v LEFT JOIN ALL_TAB_COMMENTS c ON c.OWNER=v.OWNER AND c.TABLE_NAME=v.VIEW_NAME ORDER BY 1, 2"
        }
    }
    private static func columnsQuery(for driver: SQLDatabaseDriver) -> String {
        switch driver {
        case .mysql:
            return "SELECT c.TABLE_SCHEMA, c.TABLE_NAME, c.COLUMN_NAME, c.COLUMN_TYPE, c.IS_NULLABLE, c.ORDINAL_POSITION, IFNULL(c.COLUMN_DEFAULT, ''), IFNULL(c.COLUMN_COMMENT, '') FROM INFORMATION_SCHEMA.COLUMNS c WHERE c.TABLE_SCHEMA = DATABASE() ORDER BY c.TABLE_SCHEMA, c.TABLE_NAME, c.ORDINAL_POSITION"
        case .oracle:
            return "SELECT c.OWNER, c.TABLE_NAME, c.COLUMN_NAME, c.DATA_TYPE || CASE WHEN c.DATA_LENGTH IS NOT NULL THEN '(' || c.DATA_LENGTH || ')' ELSE '' END, CASE WHEN c.NULLABLE='Y' THEN 'Y' ELSE 'N' END, c.COLUMN_ID, c.DATA_DEFAULT, NVL(m.COMMENTS, '') FROM ALL_TAB_COLUMNS c LEFT JOIN ALL_COL_COMMENTS m ON m.OWNER=c.OWNER AND m.TABLE_NAME=c.TABLE_NAME AND m.COLUMN_NAME=c.COLUMN_NAME ORDER BY c.OWNER, c.TABLE_NAME, c.COLUMN_ID"
        }
    }
    private static func indexesQuery(for driver: SQLDatabaseDriver) -> String {
        switch driver {
        case .mysql:
            return "SELECT TABLE_SCHEMA, TABLE_NAME, INDEX_NAME, NON_UNIQUE, SEQ_IN_INDEX, COLUMN_NAME FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA = DATABASE() ORDER BY TABLE_SCHEMA, TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX"
        case .oracle:
            return "SELECT i.TABLE_OWNER, i.TABLE_NAME, i.INDEX_NAME, i.UNIQUENESS, c.COLUMN_POSITION, c.COLUMN_NAME FROM ALL_INDEXES i JOIN ALL_IND_COLUMNS c ON c.INDEX_OWNER=i.OWNER AND c.INDEX_NAME=i.INDEX_NAME WHERE i.TABLE_OWNER NOT IN ('SYS','SYSTEM') ORDER BY i.TABLE_OWNER, i.TABLE_NAME, i.INDEX_NAME, c.COLUMN_POSITION"
        }
    }
    private static func constraintsQuery(for driver: SQLDatabaseDriver) -> String {
        switch driver {
        case .mysql:
            return "SELECT TABLE_SCHEMA, TABLE_NAME, CONSTRAINT_NAME, CONSTRAINT_TYPE FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS WHERE TABLE_SCHEMA = DATABASE() ORDER BY TABLE_SCHEMA, TABLE_NAME, CONSTRAINT_NAME"
        case .oracle:
            return "SELECT OWNER, TABLE_NAME, CONSTRAINT_NAME, CONSTRAINT_TYPE FROM ALL_CONSTRAINTS WHERE OWNER NOT IN ('SYS','SYSTEM') ORDER BY OWNER, TABLE_NAME, CONSTRAINT_NAME"
        }
    }
    private static func foreignKeysQuery(for driver: SQLDatabaseDriver) -> String {
        switch driver {
        case .mysql:
            return "SELECT k.TABLE_SCHEMA, k.TABLE_NAME, k.CONSTRAINT_NAME, k.COLUMN_NAME, k.REFERENCED_TABLE_SCHEMA, k.REFERENCED_TABLE_NAME, k.REFERENCED_COLUMN_NAME FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE k WHERE k.TABLE_SCHEMA = DATABASE() AND k.REFERENCED_TABLE_NAME IS NOT NULL ORDER BY k.TABLE_SCHEMA, k.TABLE_NAME, k.CONSTRAINT_NAME, k.ORDINAL_POSITION"
        case .oracle:
            return "SELECT c.OWNER, c.TABLE_NAME, c.CONSTRAINT_NAME, cc.COLUMN_NAME, r.OWNER, r.TABLE_NAME, rc.COLUMN_NAME FROM ALL_CONSTRAINTS c JOIN ALL_CONS_COLUMNS cc ON cc.OWNER=c.OWNER AND cc.CONSTRAINT_NAME=c.CONSTRAINT_NAME JOIN ALL_CONSTRAINTS r ON r.OWNER=c.R_OWNER AND r.CONSTRAINT_NAME=c.R_CONSTRAINT_NAME JOIN ALL_CONS_COLUMNS rc ON rc.OWNER=r.OWNER AND rc.CONSTRAINT_NAME=r.CONSTRAINT_NAME AND rc.POSITION=cc.POSITION WHERE c.CONSTRAINT_TYPE='R' ORDER BY c.OWNER, c.TABLE_NAME, c.CONSTRAINT_NAME, cc.POSITION"
        }
    }
    private static func proceduresQuery(for driver: SQLDatabaseDriver) -> String {
        switch driver {
        case .mysql:
            return "SELECT ROUTINE_SCHEMA, ROUTINE_NAME, ROUTINE_TYPE, IFNULL(ROUTINE_COMMENT, '') FROM INFORMATION_SCHEMA.ROUTINES WHERE ROUTINE_SCHEMA = DATABASE() ORDER BY ROUTINE_SCHEMA, ROUTINE_NAME"
        case .oracle:
            return "SELECT OWNER, NVL(PROCEDURE_NAME, OBJECT_NAME), CASE WHEN PROCEDURE_NAME IS NULL THEN OBJECT_TYPE ELSE 'PROCEDURE' END, '' FROM ALL_PROCEDURES WHERE OWNER NOT IN ('SYS','SYSTEM') AND OBJECT_NAME IS NOT NULL ORDER BY OWNER, OBJECT_NAME, PROCEDURE_NAME"
        }
    }
}

private struct SQLLocalCollection: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var source: String
    var updatedAt = Date()
    var documents: [[String: String]]
}

@MainActor
private final class SQLWorkspaceModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable { case canvas = "Canvas", sql = "Free SQL", storage = "Storage"; var id: String { rawValue } }
    enum SchemaSection: String, CaseIterable, Identifiable { case tables = "Tables", views = "Views", procedures = "Procedures"; var id: String { rawValue } }

    @Published var mode: Mode = .canvas
    @Published var schemaSection: SchemaSection = .tables { didSet { searchSchema() } }
    @Published var connections: [SQLConnectionProfile] = []
    @Published var selectedConnectionID: UUID?
    @Published var schema: SQLSchemaSnapshot? { didSet { rebuildSchemaIndex() } }
    @Published var schemaSearch = "" { didSet { searchSchema(debounce: true) } }
    @Published var schemaOwner = "" { didSet { searchSchema() } }
    @Published var showFilteredTables = false { didSet { searchSchema() } }
    @Published private(set) var visibleTables: [SQLTable] = []
    @Published private(set) var visibleProcedures: [SQLProcedure] = []
    @Published private(set) var schemaOwners: [String] = []
    @Published private(set) var schemaRevision = 0
    @Published private(set) var isSearchingSchema = false
    @Published private(set) var filteredTableCount = 0
    @Published var selectedTableID: String?
    @Published var queryText = ""
    @Published var visualQuery = SQLVisualQuery()
    @Published var result = SQLResultSet()
    @Published private(set) var resultRevision = 0
    @Published var status = "Choose a connection to discover its schema."
    @Published var isBusy = false
    @Published var discoveryCompletedSteps = 0
    @Published var discoveryTotalSteps = 0
    @Published var discoveryActivity = ""
    @Published var showsConnectionEditor = false
    @Published var connectionDraft = SQLConnectionProfile(name: "New Connection", environment: "Development", driver: .mysql, host: "", database: "", username: "")
    @Published var secretDraft = ""
    @Published var isEditingConnection = false
    @Published var pendingConnectionDeletionID: UUID?
    @Published var requiresWriteConfirmation = false
    @Published var exportCollectionName = "Query exports"
    @Published var exportStart = 1
    @Published var exportEnd = 250
    @Published var collections: [SQLLocalCollection] = []
    @Published var selectedCollectionID: UUID?
    @Published var savedQueries: [SQLSavedQuery] = []
    @Published var savedQueryName = ""
    private var runningTask: Task<Void, Never>?
    private var cachedSchemas: [UUID: SQLSchemaSnapshot] = [:]
    private var blockDrafts: [UUID: SQLVisualQuery] = [:]
    private let sessionCredentials = SQLSessionCredentials()
    private var schemaIndex: SQLSchemaIndex?
    private var indexedProfileID: UUID?
    private var indexingTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    private func rebuildSchemaIndex() {
        indexingTask?.cancel()
        searchTask?.cancel()
        if indexedProfileID != schema?.profileID || schema == nil {
            schemaIndex = nil
            visibleTables = []; visibleProcedures = []; schemaOwners = []
        }
        indexedProfileID = schema?.profileID
        guard let snapshot = schema else { isSearchingSchema = false; return }
        isSearchingSchema = true
        indexingTask = Task { [weak self] in
            let index = await Task.detached(priority: .userInitiated) { SQLSchemaIndex(snapshot: snapshot) }.value
            guard !Task.isCancelled, let self else { return }
            self.schemaIndex = index
            self.schemaOwners = index.owners
            self.filteredTableCount = self.selectedConnection.map { index.hiddenTableCount(filter: SQLSchemaFilter(profile: $0)) } ?? 0
            self.schemaRevision += 1
            self.searchSchema()
        }
    }

    private func searchSchema(debounce: Bool = false) {
        searchTask?.cancel()
        guard let index = schemaIndex else { return }
        let query = schemaSearch, owner = schemaOwner, section = schemaSection
        let filter = showFilteredTables ? SQLSchemaFilter.permissive : selectedConnection.map(SQLSchemaFilter.init(profile:)) ?? .permissive
        isSearchingSchema = true
        searchTask = Task { [weak self] in
            if debounce { do { try await Task.sleep(nanoseconds: 90_000_000) } catch { return } }
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                (index.tables(query: query, owner: owner, kind: section == .views ? "VIEW" : "TABLE", filter: filter), index.procedures(query: query, owner: owner))
            }.value
            guard !Task.isCancelled, let self else { return }
            self.visibleTables = result.0
            self.visibleProcedures = result.1
            self.isSearchingSchema = false
        }
    }

    private func password(for id: UUID) -> String? {
        sessionCredentials.password(for: id) { SQLCredentialVault.password(for: id) }
    }

    func lockSession() {
        sessionCredentials.clear()
        secretDraft = ""
        status = "Session locked. The next query will request Keychain access."
    }

    struct SQLSavedQuery: Codable, Identifiable, Hashable {
        var id = UUID()
        var name: String
        var sql: String
        var updatedAt = Date()
    }

    init() { load() }

    var selectedConnection: SQLConnectionProfile? { connections.first { $0.id == selectedConnectionID } }
    var selectedTable: SQLTable? { selectedTableID.flatMap { schemaIndex?.tablesByID[$0] } }
    var canvasIssue: String? {
        guard !visualQuery.tables.isEmpty else { return "Add a source table to begin." }
        do { _ = try (visualQuery.blocks ?? SQLQueryBlocks()).sql(tables: visualQuery.tables, limit: visualQuery.limit, driver: selectedConnection?.driver ?? .mysql); return nil }
        catch { return error.localizedDescription }
    }
    var joinSuggestions: [SQLJoinSuggestion] {
        guard let schema else { return [] }
        return schema.joins(for: visualQuery.tables, filter: selectedConnection.map(SQLSchemaFilter.init(profile:)) ?? .permissive)
    }
    var activeCollection: SQLLocalCollection? { collections.first { $0.id == selectedCollectionID } }
    var pendingConnectionDeletion: SQLConnectionProfile? { connections.first { $0.id == pendingConnectionDeletionID } }
    var discoveryProgress: Double {
        guard discoveryTotalSteps > 0 else { return 0 }
        return Double(discoveryCompletedSteps) / Double(discoveryTotalSteps)
    }

    func newConnection() {
        guard !isBusy else { return }
        isEditingConnection = false
        connectionDraft = SQLConnectionProfile(name: "New Connection", environment: "Development", driver: .mysql, host: "", database: "", username: "")
        secretDraft = ""
        showsConnectionEditor = true
    }

    func editConnection(_ profile: SQLConnectionProfile) {
        guard !isBusy else { return }
        isEditingConnection = true
        connectionDraft = profile
        secretDraft = password(for: profile.id) ?? ""
        showsConnectionEditor = true
    }

    func saveConnection(test: Bool = false) {
        guard !isBusy else { return }
        let profile = normalized(connectionDraft)
        guard !profile.name.isEmpty, !profile.host.isEmpty, !profile.database.isEmpty, !profile.username.isEmpty else { status = SQLWorkspaceError.invalidConnection.localizedDescription; return }
        guard SQLNetworkPort.validRange.contains(profile.port) else { status = SQLWorkspaceError.invalidPort.localizedDescription; return }
        guard !secretDraft.isEmpty else { status = SQLWorkspaceError.missingSecret.localizedDescription; return }
        do {
            try SQLCredentialVault.save(secretDraft, for: profile.id)
            sessionCredentials.set(secretDraft, for: profile.id)
            secretDraft = ""
            if let index = connections.firstIndex(where: { $0.id == profile.id }) { connections[index] = profile } else { connections.append(profile) }
            if let id = selectedConnectionID { blockDrafts[id] = visualQuery }
            selectedConnectionID = profile.id
            visualQuery = blockDrafts[profile.id] ?? SQLVisualQuery()
            schema = cachedSchemas[profile.id]
            schemaOwner = ""
            selectedTableID = schema?.tables.first?.id
            save()
            status = test ? "Testing \(profile.name)…" : "Saved \(profile.name). Password is in the macOS Keychain."
            if test { execute(sql: testSQL(for: profile.driver), readOnly: true, completion: { self.status = "Connected to \(profile.name)." }) }
            else { showsConnectionEditor = false }
        } catch { status = error.localizedDescription }
    }

    func deleteConnection(_ profile: SQLConnectionProfile) {
        guard !isBusy else { return }
        connections.removeAll { $0.id == profile.id }
        cachedSchemas.removeValue(forKey: profile.id)
        blockDrafts.removeValue(forKey: profile.id)
        SQLCredentialVault.delete(profileID: profile.id)
        sessionCredentials.remove(profile.id)
        if selectedConnectionID == profile.id {
            selectedConnectionID = connections.first?.id
            schema = selectedConnectionID.flatMap { cachedSchemas[$0] }
            visualQuery = selectedConnectionID.flatMap { blockDrafts[$0] } ?? SQLVisualQuery()
            schemaOwner = ""
            selectedTableID = schema?.tables.first?.id
        }
        save()
        status = "Removed \(profile.name) and its Keychain password."
    }

    func requestDeleteConnection(_ profile: SQLConnectionProfile) { pendingConnectionDeletionID = profile.id }

    func alwaysShow(_ table: SQLTable) {
        guard let id = selectedConnectionID, let index = connections.firstIndex(where: { $0.id == id }) else { return }
        var values = connections[index].tableIncludeOverrides ?? []
        if !values.contains(where: { $0.caseInsensitiveCompare(table.qualifiedName) == .orderedSame }) { values.append(table.qualifiedName) }
        connections[index].tableIncludeOverrides = values.sorted()
        filteredTableCount = schemaIndex?.hiddenTableCount(filter: SQLSchemaFilter(profile: connections[index])) ?? 0
        save()
        searchSchema()
        status = "Always showing \(table.qualifiedName)."
    }
    func confirmDeleteConnection() {
        guard let profile = pendingConnectionDeletion else { return }
        pendingConnectionDeletionID = nil
        deleteConnection(profile)
    }

    func discover() {
        guard !isBusy else { return }
        guard let profile = selectedConnection else { status = "Choose or add a connection first."; return }
        guard let password = password(for: profile.id) else { status = SQLWorkspaceError.missingSecret.localizedDescription; return }
        isBusy = true
        discoveryCompletedSteps = 0
        discoveryTotalSteps = 6
        discoveryActivity = "Preparing discovery"
        status = "Discovery 0 of 6 · Preparing connection…"
        runningTask = Task { [weak self] in
            do {
                let snapshot = try await SQLSchemaDiscovery.discover(profile: profile, password: password, progress: { [weak self] completed, total, activity in
                    guard let self else { return }
                    self.discoveryCompletedSteps = completed
                    self.discoveryTotalSteps = total
                    self.discoveryActivity = activity
                    self.status = "Discovery \(completed) of \(total) · \(activity)…"
                }, checkpoint: { [weak self] snapshot in
                    guard let self else { return }
                    self.cachedSchemas[profile.id] = snapshot
                    if self.selectedConnectionID == profile.id {
                        self.schema = snapshot
                        if self.selectedTableID == nil { self.selectedTableID = snapshot.tables.first?.id }
                    }
                })
                guard !Task.isCancelled else { return }
                self?.schema = snapshot
                self?.cachedSchemas[profile.id] = snapshot
                self?.selectedTableID = snapshot.tables.first?.id
                self?.status = "Discovered \(snapshot.tables.count) tables/views, \(snapshot.foreignKeys.count) relationships, and \(snapshot.procedures.count) procedures."
                self?.discoveryCompletedSteps = self?.discoveryTotalSteps ?? 0
                self?.discoveryActivity = "Schema ready"
                self?.isBusy = false
                self?.save()
            } catch {
                if let self {
                    let activity = self.discoveryActivity.isEmpty ? "preparing discovery" : self.discoveryActivity.lowercased()
                    self.status = "Discovery stopped while \(activity): \(error.localizedDescription)"
                    self.discoveryActivity = "Discovery stopped"
                    self.isBusy = false
                    if self.cachedSchemas[profile.id]?.discoveryComplete == false {
                        self.status += " Completed discovery data has been saved."
                    }
                    self.save()
                }
            }
        }
    }

    func runFreeSQL() {
        if SQLCommandLineClient.isPotentiallyDestructive(queryText) { requiresWriteConfirmation = true; return }
        execute(sql: queryText, readOnly: false)
    }

    func runConfirmedWrite() { requiresWriteConfirmation = false; execute(sql: queryText, readOnly: false) }
    func runReadOnly() { execute(sql: queryText, readOnly: true) }
    func runCanvas() {
        guard let driver = selectedConnection?.driver else { status = "Choose a connection first."; return }
        do {
            queryText = try (visualQuery.blocks ?? SQLQueryBlocks()).sql(tables: visualQuery.tables, limit: visualQuery.limit, driver: driver)
            execute(sql: queryText, readOnly: true)
        } catch { status = error.localizedDescription }
    }

    func saveBlocks() {
        guard selectedConnectionID != nil else { return }
        if save() { status = "Saved this connection’s query blocks." }
    }

    func addTable(_ table: SQLTable) {
        if !visualQuery.tables.contains(table.qualifiedName) { visualQuery.tables.append(table.qualifiedName) }
        let projection = "\(table.qualifiedName).*"
        if !visualQuery.projections.contains(projection) { visualQuery.projections.append(projection) }
        selectedTableID = table.id
        status = "Added \(table.qualifiedName) to the canvas."
    }

    func addJoin(_ join: SQLJoinSuggestion) {
        if !visualQuery.tables.contains(join.fromTable) { visualQuery.tables.append(join.fromTable) }
        if !visualQuery.tables.contains(join.toTable) { visualQuery.tables.append(join.toTable) }
        if !visualQuery.joins.contains(join) { visualQuery.joins.append(join) }
        var blocks = visualQuery.blocks ?? SQLQueryBlocks()
        // Suggestions can point either way: keep the existing source in FROM.
        let reverse = visualQuery.tables.first == join.toTable
        let target = reverse ? join.fromTable : join.toTable
        if !blocks.joins.contains(where: { $0.table == target }) {
            blocks.joins.append(SQLJoinBlock(table: target, condition: SQLFilterBlock(field: "\(join.fromTable).\(join.fromColumn)", valueType: .expression, value: "\(join.toTable).\(join.toColumn)")))
        }
        visualQuery.blocks = blocks
    }

    func insertProcedure(_ procedure: SQLProcedure) {
        queryText = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !queryText.isEmpty { queryText += "\n\n" }
        queryText += procedure.invocation
        mode = .sql
        status = "Inserted \(procedure.qualifiedName). Fill in arguments before running it."
    }

    func insertDroppedSQL(_ text: String) {
        queryText = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        queryText += (queryText.isEmpty ? "" : "\n") + text
        mode = .sql
    }

    func saveCurrentQuery() {
        let name = savedQueryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sql = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !sql.isEmpty else { status = "Name and write a query before saving it."; return }
        savedQueries.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        savedQueries.insert(SQLSavedQuery(name: name, sql: sql), at: 0)
        savedQueryName = ""
        save()
        status = "Saved query \(name)."
    }

    func loadQuery(_ saved: SQLSavedQuery) { queryText = saved.sql; mode = .sql; status = "Loaded \(saved.name)." }

    func exportResultRange() {
        guard !result.columns.isEmpty else { status = "Run a query before exporting rows."; return }
        let name = exportCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { status = "Name the local collection."; return }
        let start = max(0, exportStart - 1)
        let end = min(result.rows.count, max(start, exportEnd))
        let documents = result.rows[start..<end].map(document(from:))
        let source = selectedConnection.map { "\($0.name) · \($0.environment)" } ?? "Query result"
        if let index = collections.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            collections[index].documents += documents
            collections[index].source = source
            collections[index].updatedAt = Date()
            selectedCollectionID = collections[index].id
        } else {
            let collection = SQLLocalCollection(name: name, source: source, documents: documents)
            collections.insert(collection, at: 0)
            selectedCollectionID = collection.id
        }
        save()
        mode = .storage
        status = "Exported \(documents.count) row\(documents.count == 1 ? "" : "s") to local document collection \(name)."
    }

    func deleteCollection(_ collection: SQLLocalCollection) {
        collections.removeAll { $0.id == collection.id }
        if selectedCollectionID == collection.id { selectedCollectionID = collections.first?.id }
        save()
    }

    func cancel() { runningTask?.cancel(); isBusy = false; save(); lockSession() }

    private func execute(sql: String, readOnly: Bool, completion: (() -> Void)? = nil) {
        guard !isBusy else { return }
        discoveryTotalSteps = 0
        let clean = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { status = "Write a query first."; return }
        guard !readOnly || SQLCommandLineClient.isReadOnly(clean) else { status = SQLWorkspaceError.readOnly.localizedDescription; return }
        guard let profile = selectedConnection else { status = "Choose a connection first."; return }
        guard let password = password(for: profile.id) else { status = SQLWorkspaceError.missingSecret.localizedDescription; return }
        isBusy = true; status = "Running on \(profile.name)…"
        runningTask = Task { [weak self] in
            do {
                let result = try await SQLCommandLineClient.execute(profile: profile, password: password, sql: clean)
                guard !Task.isCancelled else { return }
                self?.result = result
                self?.resultRevision += 1
                self?.exportStart = 1
                self?.exportEnd = min(250, result.rows.count)
                self?.status = result.columns.isEmpty ? "Statement completed." : "Returned \(result.rows.count) rows."
                self?.isBusy = false
                completion?()
            } catch {
                self?.status = error.localizedDescription
                self?.isBusy = false
            }
        }
    }

    private func normalized(_ profile: SQLConnectionProfile) -> SQLConnectionProfile {
        var profile = profile
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.environment = profile.environment.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.database = profile.database.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.commandPath = profile.commandPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let owners = (profile.discoverySchemas ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        profile.discoverySchemas = owners.isEmpty ? nil : Array(Set(owners)).sorted()
        let exclusions = (profile.tableExclusionTerms ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        profile.tableExclusionTerms = exclusions.isEmpty ? nil : Array(Set(exclusions)).sorted()
        let includes = (profile.tableIncludeOverrides ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        profile.tableIncludeOverrides = includes.isEmpty ? nil : Array(Set(includes)).sorted()
        if profile.port <= 0 { profile.port = profile.driver.defaultPort }
        if profile.commandPath.isEmpty { profile.commandPath = profile.driver.defaultCommand }
        return profile
    }

    private func testSQL(for driver: SQLDatabaseDriver) -> String { driver == .mysql ? "SELECT 1 AS connected" : "SELECT 1 AS connected FROM dual" }

    private func document(from row: [String]) -> [String: String] {
        var document: [String: String] = [:]
        var keyCounts: [String: Int] = [:]
        for (index, originalKey) in result.columns.enumerated() {
            let count = keyCounts[originalKey, default: 0]
            keyCounts[originalKey] = count + 1
            let key = count == 0 ? originalKey : "\(originalKey)_\(count + 1)"
            document[key] = row.indices.contains(index) ? row[index] : ""
        }
        return document
    }

    private struct SavedWorkspace: Codable {
        var connections: [SQLConnectionProfile]
        var selectedConnectionID: UUID?
        var snapshots: [UUID: SQLSchemaSnapshot]
        var savedQueries: [SQLSavedQuery]
        var collections: [SQLLocalCollection]
        var blockDrafts: [UUID: SQLVisualQuery]?
    }

    private var workspaceURL: URL { ApplicationPaths.applicationSupport.appendingPathComponent("sql-workspace.json") }

    private func load() {
        guard let data = try? Data(contentsOf: workspaceURL), let saved = try? JSONDecoder().decode(SavedWorkspace.self, from: data) else { return }
        connections = saved.connections
        selectedConnectionID = saved.selectedConnectionID ?? connections.first?.id
        cachedSchemas = saved.snapshots
        schema = selectedConnectionID.flatMap { saved.snapshots[$0] }
        savedQueries = saved.savedQueries
        collections = saved.collections
        blockDrafts = saved.blockDrafts ?? [:]
        visualQuery = selectedConnectionID.flatMap { blockDrafts[$0] } ?? SQLVisualQuery()
        selectedCollectionID = collections.first?.id
    }

    @discardableResult private func save() -> Bool {
        do {
            if let id = selectedConnectionID { blockDrafts[id] = visualQuery }
            try ApplicationPaths.prepare()
            let data = try JSONEncoder().encode(SavedWorkspace(connections: connections, selectedConnectionID: selectedConnectionID, snapshots: cachedSchemas, savedQueries: savedQueries, collections: collections, blockDrafts: blockDrafts))
            try data.write(to: workspaceURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: workspaceURL.path)
            return true
        } catch { status = "Could not save SQL workspace: \(error.localizedDescription)"; return false }
    }

    func selectConnection(_ id: UUID) {
        guard !isBusy else { return }
        if let current = selectedConnectionID { blockDrafts[current] = visualQuery }
        selectedConnectionID = id
        visualQuery = blockDrafts[id] ?? SQLVisualQuery()
        schemaOwner = ""
        schema = cachedSchemas[id]
        selectedTableID = schema?.tables.first?.id
        save()
        status = schema == nil ? "Selected \(selectedConnection?.name ?? "connection"). Refresh discovery to load its schema." : "Loaded cached schema for \(selectedConnection?.name ?? "connection")."
    }
}

private struct SQLWorkspaceView: View {
    @ObservedObject var model: SQLWorkspaceModel
    @ObservedObject private var settings = SettingsStore.shared
    @State private var showsBlockSQL = true
    @State private var showsSchemaBrowser = true
    @State private var showsInspector = true
    @FocusState private var schemaSearchFocused: Bool

    var body: some View {
        ZStack {
            LiquidGlassBackdrop(material: .underWindowBackground, blendingMode: .behindWindow)
            VStack(spacing: 8) {
                toolbar
                workspaceContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .layoutPriority(1)
                statusBar
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .tint(settings.accentTheme.primary)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showsConnectionEditor, onDismiss: { model.secretDraft = "" }) { SQLConnectionEditor(model: model) }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in model.lockSession() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in model.lockSession() }
        .alert("Run a write statement?", isPresented: $model.requiresWriteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Run Statement", role: .destructive) { model.runConfirmedWrite() }
        } message: {
            Text("This statement may change the connected database. Review the selected environment and SQL before continuing.")
        }
        .alert("Remove connection?", isPresented: Binding(
            get: { model.pendingConnectionDeletion != nil },
            set: { if !$0 { model.pendingConnectionDeletionID = nil } }
        )) {
            Button("Cancel", role: .cancel) { model.pendingConnectionDeletionID = nil }
            Button("Remove", role: .destructive) { model.confirmDeleteConnection() }
        } message: {
            Text("This removes the saved connection metadata and its Keychain password from this Mac. It does not change the database.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "cylinder.split.1x2.fill")
                .foregroundStyle(settings.accentTheme.gradient)
                .frame(width: 29, height: 29)
                .background(.ultraThinMaterial, in: PrismaticPanelShape(cut: 6))
            VStack(alignment: .leading, spacing: 0) {
                Text("SQL Workspace").limaFont(.system(size: 14, weight: .semibold, design: .rounded))
                Text(model.selectedConnection?.environment ?? "No environment")
                    .limaFont(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
            }
            Menu {
                ForEach(model.connections) { connection in
                    Button("\(connection.name) · \(connection.environment)") {
                        model.selectConnection(connection.id)
                    }
                }
                Divider()
                Button("New Connection…", action: model.newConnection)
            } label: {
                HStack(spacing: 5) {
                    Text(model.selectedConnection?.name ?? "Choose connection").lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").limaFont(.caption2)
                }
                .limaFont(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 9).frame(height: 28)
                .background(Color.white.opacity(0.07), in: PrismaticPanelShape(cut: 5))
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: true, vertical: false)
            Button(action: model.discover) {
                Label(model.isBusy ? "Working" : "Discover", systemImage: model.isBusy ? "arrow.triangle.2.circlepath" : "rectangle.stack.badge.magnifyingglass")
            }
            .disabled(model.isBusy || model.selectedConnection == nil)
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer()
            Button { showsSchemaBrowser.toggle() } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(.borderless).help("Toggle schema browser · ⌘⌥1").keyboardShortcut("1", modifiers: [.command, .option])
            Button { showsInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(.borderless).help("Toggle table details · ⌘⌥2").keyboardShortcut("2", modifiers: [.command, .option])
            Picker("Mode", selection: $model.mode) {
                ForEach(SQLWorkspaceModel.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 268)
            Menu {
                Button("New Connection…", action: model.newConnection)
                Button("Lock credential session", action: model.lockSession).disabled(model.isBusy)
                if !model.connections.isEmpty { Divider() }
                ForEach(model.connections) { connection in
                    Menu("\(connection.name) · \(connection.environment)") {
                        Button("Edit…") { model.editConnection(connection) }
                        Button("Remove", role: .destructive) { model.requestDeleteConnection(connection) }
                    }
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 26, height: 26)
            }
            .help("Manage connections and secure storage")
            .menuStyle(.borderlessButton)
            .frame(width: 28, height: 28)
        }
        .padding(.horizontal, 11).frame(height: 46)
        .liquidGlass(cornerRadius: 12, depth: .raised, accentOpacity: 0.025)
    }

    @ViewBuilder private var workspaceContent: some View {
        if model.selectedConnection == nil {
            connectionSetup
        } else {
            HSplitView {
                if showsSchemaBrowser { schemaSidebar.frame(minWidth: 210, idealWidth: 255, maxWidth: 340) }
                mainContent.frame(minWidth: 420)
                if showsInspector { inspector.frame(minWidth: 235, idealWidth: 285, maxWidth: 360) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var connectionSetup: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 20)
            Image(systemName: "cylinder.split.1x2")
                .limaFont(.system(size: 30, weight: .medium))
                .foregroundStyle(settings.accentTheme.gradient)
                .frame(width: 68, height: 68)
                .background(.ultraThinMaterial, in: PrismaticPanelShape(cut: 13))
            Text("Connect a database").limaFont(.system(size: 17, weight: .semibold, design: .rounded))
            Text("Add a named MySQL or Oracle environment. RayPlacement keeps the password in Keychain and discovers only what that account can see.")
                .limaFont(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            HStack(spacing: 8) {
                Label("MySQL", systemImage: "cylinder")
                Label("Oracle", systemImage: "cylinder")
            }
            .limaFont(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            Button("Add Connection…", action: model.newConnection)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .liquidGlass(cornerRadius: 14, depth: .raised, accentOpacity: 0.016)
    }

    private var schemaSidebar: some View {
        VStack(spacing: 8) {
            Picker("Schema", selection: $model.schemaSection) {
                ForEach(SQLWorkspaceModel.SchemaSection.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            Picker("Owner", selection: $model.schemaOwner) {
                Text("All owners").tag("")
                ForEach(model.schemaOwners, id: \.self) { Text($0).tag($0) }
            }.controlSize(.small)
            HStack(spacing: 6) {
                Button { schemaSearchFocused = true } label: { Image(systemName: "magnifyingglass").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).keyboardShortcut("f", modifiers: [.command]).help("Find a table or column · ⌘F")
                TextField("Tables, columns…", text: $model.schemaSearch).textFieldStyle(.plain).focused($schemaSearchFocused)
                if !model.schemaSearch.isEmpty {
                    Button { model.schemaSearch = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help("Clear search")
                }
                if model.isSearchingSchema { ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12) }
            }.padding(.horizontal, 9).frame(height: 30)
                .background(Color.white.opacity(0.045), in: PrismaticPanelShape(cut: 5))
            if model.schemaSection != .procedures, model.filteredTableCount > 0 {
                HStack(spacing: 6) {
                    Toggle("Show \(model.filteredTableCount) filtered", isOn: $model.showFilteredTables)
                        .toggleStyle(.checkbox).controlSize(.small).limaFont(.caption2)
                    Spacer()
                    Text("TEMP / short affix").limaFont(.caption2).foregroundStyle(.tertiary)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.schemaSection == .procedures {
                        ForEach(model.visibleProcedures) { procedure in procedureRow(procedure) }
                    } else {
                        ForEach(model.visibleTables) { table in tableRow(table) }
                    }
                }.padding(.vertical, 3)
            }
            if model.schema == nil {
                emptyState("rectangle.stack.badge.magnifyingglass", "Discover your schema", "Choose a connection, then Discover.")
            } else if !model.isSearchingSchema {
                HStack {
                    let count = model.schemaSection == .procedures ? model.visibleProcedures.count : model.visibleTables.count
                    Text("\(count) \(count == 1 ? "match" : "matches")").limaFont(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    if count == 0 { Button("Clear filters") { model.schemaSearch = ""; model.schemaOwner = "" }.buttonStyle(.borderless).limaFont(.caption) }
                }
            }
        }
        .padding(9)
        .liquidGlass(cornerRadius: 12, depth: .recessed, accentOpacity: 0.012)
    }

    private func tableRow(_ table: SQLTable) -> some View {
        Button {
            model.selectedTableID = table.id
        } label: {
            HStack(spacing: 7) {
                Image(systemName: table.kind.uppercased() == "VIEW" ? "eye" : "tablecells")
                    .limaFont(.system(size: 10, weight: .semibold)).foregroundStyle(settings.accentTheme.tertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(table.name).lineLimit(1).limaFont(.system(size: 11.5, weight: .medium))
                    Text(table.schema).lineLimit(1).limaFont(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("\(table.columns.count)").limaFont(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 7).frame(height: 34)
            .background(model.selectedTableID == table.id ? settings.accentTheme.primary.opacity(0.13) : .clear, in: PrismaticPanelShape(cut: 5))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Add to canvas") { model.addTable(table) }
            Button("Insert in SQL") { model.insertDroppedSQL(table.qualifiedName) }
            if model.selectedConnection.map({ SQLSchemaFilter(profile: $0).isHidden(table) }) == true {
                Button("Always show this table") { model.alwaysShow(table) }
            }
        }
        .onDrag { NSItemProvider(object: table.qualifiedName as NSString) }
    }

    private func procedureRow(_ procedure: SQLProcedure) -> some View {
        Button { model.insertProcedure(procedure) } label: {
            HStack(spacing: 7) {
                Image(systemName: "function").limaFont(.system(size: 10, weight: .bold)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(procedure.name).lineLimit(1).limaFont(.system(size: 11.5, weight: .medium))
                    Text("\(procedure.schema) · \(procedure.kind)").lineLimit(1).limaFont(.system(size: 9)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 7).frame(height: 34)
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var mainContent: some View {
        switch model.mode {
        case .canvas: canvas
        case .sql: sqlEditor
        case .storage: storage
        }
    }

    private var canvas: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Query blocks", systemImage: "point.3.connected.trianglepath.dotted")
                    .limaFont(.system(size: 12.5, weight: .semibold))
                Spacer()
                Button(action: model.saveBlocks) { Image(systemName: "bookmark") }.help("Save query blocks for this connection").buttonStyle(.bordered).controlSize(.small)
                Button("Edit SQL") { model.queryText = model.visualQuery.sql(for: model.selectedConnection?.driver ?? .mysql); model.mode = .sql }
                    .buttonStyle(.bordered).controlSize(.small)
                Button(action: model.runCanvas) { Label("Run query", systemImage: "play.fill") }.buttonStyle(.borderedProminent).controlSize(.small)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(model.canvasIssue != nil || model.isBusy)
                    .help(model.canvasIssue ?? "Run read-only query · ⌘Return")
            }
            if let issue = model.canvasIssue, !model.visualQuery.tables.isEmpty {
                Label(issue, systemImage: "exclamationmark.circle").limaFont(.system(size: 10.5)).foregroundStyle(.orange).lineLimit(2).help(issue)
            }
            VSplitView {
                SQLBlockCanvasEditor(query: $model.visualQuery, tables: model.schema?.tables ?? [], driver: model.selectedConnection?.driver ?? .mysql, schemaRevision: model.schemaRevision)
                    .frame(minHeight: 230, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 5) {
                    DisclosureGroup("Generated SQL", isExpanded: $showsBlockSQL) {
                        ScrollView {
                            Text(model.visualQuery.sql(for: model.selectedConnection?.driver ?? .mysql))
                                .limaFont(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }.frame(maxHeight: 130)
                    }
                    resultsView
                }.frame(minHeight: 145)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .liquidGlass(cornerRadius: 12, depth: .raised, accentOpacity: 0.016)
        .onAppear { if model.visualQuery.blocks == nil { model.visualQuery.blocks = SQLQueryBlocks() } }
    }

    private var sqlEditor: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Label("Free SQL", systemImage: "chevron.left.forwardslash.chevron.right").limaFont(.system(size: 12.5, weight: .semibold))
                Spacer()
                TextField("Save query as", text: $model.savedQueryName).textFieldStyle(.roundedBorder).frame(width: 140)
                Button(action: model.saveCurrentQuery) { Image(systemName: "bookmark") }.buttonStyle(.bordered).controlSize(.small)
                Button("Read-only", action: model.runReadOnly).buttonStyle(.bordered).controlSize(.small).disabled(model.isBusy)
                Button("Run", action: model.runFreeSQL).buttonStyle(.borderedProminent).controlSize(.small).disabled(model.isBusy)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.queryText)
                    .limaFont(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(7)
                if model.queryText.isEmpty {
                    Text("Drop a table or write SQL…").limaFont(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary).padding(14)
                }
            }
            .frame(minHeight: 195)
            .background(Color.black.opacity(0.24), in: PrismaticPanelShape(cut: 7))
            .onDrop(of: [.plainText], isTargeted: nil) { providers in
                providers.first?.loadObject(ofClass: NSString.self) { value, _ in
                    if let text = value as? String { DispatchQueue.main.async { model.insertDroppedSQL(text) } }
                }
                return true
            }
            if !model.savedQueries.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) { ForEach(model.savedQueries) { saved in Button(saved.name) { model.loadQuery(saved) }.buttonStyle(.bordered).controlSize(.mini) } }
                }
            }
            resultsView
        }
        .padding(10).liquidGlass(cornerRadius: 12, depth: .raised, accentOpacity: 0.016)
    }

    private var resultsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Results").limaFont(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if !model.result.rows.isEmpty {
                    Text("\(model.result.rows.count) rows").limaFont(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    Button("Export range", action: model.exportResultRange).buttonStyle(.bordered).controlSize(.mini)
                }
            }
            if model.result.columns.isEmpty {
                Text("Results appear here.").limaFont(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                SQLResultTableView(result: model.result, revision: model.resultRevision)
                    .frame(minHeight: 150, maxHeight: 310)
                    .clipShape(PrismaticPanelShape(cut: 7))
                    .overlay(PrismaticPanelShape(cut: 7).stroke(Color.white.opacity(0.075), lineWidth: 0.7).allowsHitTesting(false))
            }
        }
    }

    private var storage: some View {
        VStack(alignment: .leading, spacing: 9) {
            storageHeader
            storageExportControls
            storageBody
        }
        .padding(10).liquidGlass(cornerRadius: 12, depth: .raised, accentOpacity: 0.016)
    }

    private var storageHeader: some View {
        HStack {
            Label("Local document store", systemImage: "shippingbox.fill").limaFont(.system(size: 12.5, weight: .semibold))
            Text("Saved locally · no remote service").limaFont(.caption2).foregroundStyle(.secondary)
            Spacer()
            Button("Reveal file") { NSWorkspace.shared.activateFileViewerSelecting([ApplicationPaths.applicationSupport.appendingPathComponent("sql-workspace.json")]) }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }

    private var storageExportControls: some View {
        HStack(spacing: 7) {
            TextField("Collection name", text: $model.exportCollectionName).textFieldStyle(.roundedBorder)
            Text("Rows").limaFont(.caption).foregroundStyle(.secondary)
            TextField("1", value: $model.exportStart, format: .number).frame(width: 44).textFieldStyle(.roundedBorder)
            Text("–").foregroundStyle(.secondary)
            TextField("250", value: $model.exportEnd, format: .number).frame(width: 52).textFieldStyle(.roundedBorder)
            Button("Export current result", action: model.exportResultRange).buttonStyle(.borderedProminent).controlSize(.small)
        }
    }

    private var storageBody: some View {
        HSplitView {
            List(selection: $model.selectedCollectionID) {
                ForEach(model.collections) { collection in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(collection.name).limaFont(.system(size: 12, weight: .medium))
                        Text("\(collection.documents.count) documents · \(collection.source)").limaFont(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }.tag(collection.id)
                }
                .onDelete { offsets in offsets.map { model.collections[$0] }.forEach(model.deleteCollection) }
            }.frame(minWidth: 190)
            if let collection = model.activeCollection { collectionDetail(collection) }
            else { emptyState("shippingbox", "No local collection", "Export query results to create one.") }
        }
    }

    private func collectionDetail(_ collection: SQLLocalCollection) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                Text(collection.name).limaFont(.system(size: 15, weight: .semibold))
                Text("\(collection.documents.count) documents · updated \(collection.updatedAt.formatted(date: .abbreviated, time: .shortened))").limaFont(.caption).foregroundStyle(.secondary)
                ForEach(Array(collection.documents.prefix(50).enumerated()), id: \.offset) { index, document in documentCard(index: index, document: document) }
            }.padding(10)
        }
    }

    private func documentCard(index: Int, document: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("#\(index + 1)").limaFont(.caption2.weight(.bold)).foregroundStyle(settings.accentTheme.tertiary)
            ForEach(document.keys.sorted(), id: \.self) { key in
                HStack(alignment: .top, spacing: 7) {
                    Text(key).limaFont(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                    Text(document[key] ?? "").limaFont(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                }
            }
        }.padding(8).background(Color.white.opacity(0.045), in: PrismaticPanelShape(cut: 6))
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let table = model.selectedTable {
                HStack {
                    VStack(alignment: .leading, spacing: 2) { Text(table.name).limaFont(.system(size: 13, weight: .semibold)); Text(table.schema).limaFont(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Button(action: { model.addTable(table) }) { Image(systemName: "plus.square.on.square") }.buttonStyle(.bordered).controlSize(.mini).help("Add to canvas")
                }
                if let description = table.description, !description.isEmpty { Text(description).limaFont(.caption).foregroundStyle(.secondary) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Columns").limaFont(.caption.weight(.semibold)).foregroundStyle(settings.accentTheme.tertiary)
                        ForEach(table.columns) { column in
                            HStack(alignment: .top, spacing: 5) {
                                Image(systemName: column.nullable ? "circle" : "key.fill").limaFont(.system(size: 8)).foregroundStyle(column.nullable ? Color.secondary : Color.yellow)
                                VStack(alignment: .leading, spacing: 1) { Text(column.name).limaFont(.system(size: 10.5, weight: .medium, design: .monospaced)); Text(column.dataType).limaFont(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary) }
                            }.contextMenu { Button("Insert column") { model.insertDroppedSQL("\(table.qualifiedName).\(column.name)") } }
                        }
                        if !table.indexes.isEmpty { Divider(); Text("Indexes").limaFont(.caption.weight(.semibold)).foregroundStyle(settings.accentTheme.tertiary); ForEach(table.indexes) { index in Text("\(index.unique ? "UNIQUE " : "")\(index.name) · \(index.column)").limaFont(.system(size: 9.5, design: .monospaced)).foregroundStyle(.secondary) } }
                        if !table.constraints.isEmpty { Divider(); Text("Constraints").limaFont(.caption.weight(.semibold)).foregroundStyle(settings.accentTheme.tertiary); ForEach(table.constraints, id: \.self) { Text($0).limaFont(.caption2).foregroundStyle(.secondary) } }
                    }.padding(.vertical, 2)
                }
            } else {
                emptyState("tablecells", "Select a table", "Details, keys, and columns appear here.")
            }
            Divider()
            Text("Compatible joins").limaFont(.caption.weight(.semibold)).foregroundStyle(settings.accentTheme.tertiary)
            if model.joinSuggestions.isEmpty { Text("Add a table to see foreign-key joins.").limaFont(.caption2).foregroundStyle(.secondary) }
            else { ScrollView { VStack(alignment: .leading, spacing: 5) { ForEach(model.joinSuggestions) { join in Button { model.addJoin(join) } label: { HStack(spacing: 7) { Image(systemName: "arrow.up.left.and.arrow.down.right").foregroundStyle(.teal); VStack(alignment: .leading, spacing: 2) { Text(join.toTable).limaFont(.system(size: 10.5, weight: .semibold, design: .monospaced)); Text(join.label).limaFont(.system(size: 8.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2) }; Spacer(minLength: 0); Image(systemName: "plus").limaFont(.system(size: 8)).foregroundStyle(.secondary) } .frame(maxWidth: .infinity, alignment: .leading).padding(7).background(Color.white.opacity(0.05), in: PrismaticPanelShape(cut: 5)) }.buttonStyle(.plain).onDrag { NSItemProvider(object: join.toTable as NSString) }.help("Click to add this join, or drag the related table onto the canvas") } } } }
        }
        .padding(9).liquidGlass(cornerRadius: 12, depth: .recessed, accentOpacity: 0.012)
    }

    private var statusBar: some View {
        VStack(spacing: model.isBusy ? 4 : 0) {
            HStack(spacing: 7) {
                if model.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Circle()
                        .fill(model.status.lowercased().contains("could not") || model.status.lowercased().contains("not found") ? Color.orange : settings.accentTheme.tertiary)
                        .frame(width: 5, height: 5)
                }
                Text(model.status).limaFont(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if model.isBusy, model.discoveryTotalSteps > 0 {
                    Text("\(model.discoveryCompletedSteps)/\(model.discoveryTotalSteps)")
                        .limaFont(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(settings.accentTheme.tertiary)
                } else if let schema = model.schema {
                    Text("\(schema.discoveryComplete == false ? "Partial schema" : "Schema cached") \(schema.discoveredAt.formatted(date: .omitted, time: .shortened))").limaFont(.caption2).foregroundStyle(.secondary)
                }
            }
            if model.isBusy, model.discoveryTotalSteps > 0 {
                ProgressView(value: model.discoveryProgress)
                    .tint(settings.accentTheme.primary)
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: model.isBusy ? 34 : 27)
        .background(Color.black.opacity(0.16), in: PrismaticPanelShape(cut: 6))
    }

    private func emptyState(_ symbol: String, _ title: String, _ description: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol).limaFont(.system(size: 18, weight: .medium)).foregroundStyle(.secondary)
            Text(title).limaFont(.system(size: 11.5, weight: .semibold))
            Text(description).limaFont(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }
}

private struct SQLConnectionEditor: View {
    @ObservedObject var model: SQLWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var portText = ""
    @State private var discoverySchemasText = ""
    @State private var exclusionTermsText = ""
    @State private var includeOverridesText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack { Label(model.isEditingConnection ? "Edit connection" : "New connection", systemImage: "cylinder.split.1x2").limaFont(.title3.weight(.semibold)); Spacer(); Button(action: { dismiss() }) { Image(systemName: "xmark") }.buttonStyle(.borderless) }
            Grid(horizontalSpacing: 10, verticalSpacing: 9) {
                row("Name") { TextField("Operations MySQL", text: $model.connectionDraft.name) }
                row("Environment") { TextField("Development", text: $model.connectionDraft.environment) }
                row("Engine") { Picker("Engine", selection: $model.connectionDraft.driver) { ForEach(SQLDatabaseDriver.allCases) { Text($0.title).tag($0) } }.labelsHidden().pickerStyle(.segmented) }
                row("Host") { TextField("db.example.com", text: $model.connectionDraft.host) }
                row("Port") {
                    TextField("1521", text: $portText)
                        .limaFont(.system(size: 12, design: .monospaced))
                        .onChange(of: portText) { value in
                            let digits = value.filter(\.isWholeNumber)
                            if digits != value {
                                portText = digits
                                return
                            }
                            model.connectionDraft.port = SQLNetworkPort.parsePlainDigits(value) ?? 0
                        }
                        .onChange(of: model.connectionDraft.driver) { driver in
                            if portText.isEmpty {
                                portText = String(driver.defaultPort)
                                model.connectionDraft.port = driver.defaultPort
                            }
                        }
                        .help("Use plain digits only, such as 1521. Ports are not formatted with commas.")
                }
                row(model.connectionDraft.driver == .oracle ? "Service" : "Database") { TextField(model.connectionDraft.driver == .oracle ? "service_name" : "database", text: $model.connectionDraft.database) }
                row("Username") { TextField("Username", text: $model.connectionDraft.username) }
                row("Password") { SecureField("Stored in macOS Keychain", text: $model.secretDraft) }
                row("Client") { TextField(model.connectionDraft.driver.defaultCommand, text: $model.connectionDraft.commandPath).limaFont(.system(size: 11, design: .monospaced)) }
                if model.connectionDraft.driver == .oracle {
                    row("Discovery schemas") {
                        HStack {
                            TextField("All accessible · or HR, SALES", text: $discoverySchemasText)
                                .onChange(of: discoverySchemasText) { value in
                                    model.connectionDraft.discoverySchemas = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                                }
                                .help("Optional exact schema owner names, separated by commas. Leave empty to discover all accessible schemas.")
                            Button("My schema") { discoverySchemasText = model.connectionDraft.username.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
                                .help("Limit discovery to the schema matching this username.")
                        }
                    }
                }
            }
            DisclosureGroup("Schema clutter filters") {
                VStack(alignment: .leading, spacing: 9) {
                    Toggle("Hide names containing TEMP", isOn: Binding(
                        get: { model.connectionDraft.hideTemporaryTables ?? true },
                        set: { model.connectionDraft.hideTemporaryTables = $0 }
                    ))
                    Toggle("Hide names with 1–2 characters before or after an underscore", isOn: Binding(
                        get: { model.connectionDraft.hideShortAffixTables ?? true },
                        set: { model.connectionDraft.hideShortAffixTables = $0 }
                    ))
                    TextField("Additional contains terms, comma separated", text: $exclusionTermsText)
                        .onChange(of: exclusionTermsText) { value in
                            model.connectionDraft.tableExclusionTerms = commaValues(value)
                        }
                    TextField("Always show exact table names", text: $includeOverridesText)
                        .onChange(of: includeOverridesText) { value in
                            model.connectionDraft.tableIncludeOverrides = commaValues(value)
                        }
                    Text("Filtered tables can still be revealed in the schema sidebar. Use a table’s menu to keep an incorrectly matched table visible.")
                        .limaFont(.caption2).foregroundStyle(.secondary)
                }
                .padding(.top, 7)
            }
            Text("The workspace saves connection metadata locally with restricted permissions. Passwords are stored separately in this Mac’s Keychain and are excluded from query history, schema files, and usage logs.")
                .limaFont(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { model.saveConnection(); dismiss() }.buttonStyle(.bordered); Button("Save & Test") { model.saveConnection(test: true); dismiss() }.buttonStyle(.borderedProminent) }
        }
        .padding(20).frame(width: 560)
        .background(LiquidGlassBackdrop(material: .underWindowBackground, blendingMode: .behindWindow))
        .preferredColorScheme(.dark)
        .onAppear {
            portText = String(model.connectionDraft.port)
            discoverySchemasText = (model.connectionDraft.discoverySchemas ?? []).joined(separator: ", ")
            exclusionTermsText = (model.connectionDraft.tableExclusionTerms ?? []).joined(separator: ", ")
            includeOverridesText = (model.connectionDraft.tableIncludeOverrides ?? []).joined(separator: ", ")
        }
    }

    private func row<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow { Text(name).limaFont(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 83, alignment: .trailing); content().textFieldStyle(.roundedBorder) }
    }

    private func commaValues(_ value: String) -> [String]? {
        let values = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return values.isEmpty ? nil : values
    }
}
