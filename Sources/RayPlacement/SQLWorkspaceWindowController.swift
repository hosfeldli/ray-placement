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
        window.contentView = NSHostingView(rootView: SQLWorkspaceView(model: model))
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
    case commandFailed(String)
    case keychain(OSStatus)
    case readOnly

    var errorDescription: String? {
        switch self {
        case .missingClient(let driver, let path):
            return "\(driver.title) client not found at \(path). Install its command-line client or set its location in this connection."
        case .missingSecret: return "Save a password for this connection in the Keychain first."
        case .invalidConnection: return "Complete the connection name, host, database/service, and username."
        case .commandFailed(let message): return message
        case .keychain(let status): return "Keychain could not save this connection (status \(status))."
        case .readOnly: return "Read-only mode only runs SELECT, WITH, SHOW, DESCRIBE, or EXPLAIN statements."
        }
    }
}

private enum SQLCommandLineClient {
    static func execute(profile: SQLConnectionProfile, password: String, sql: String) async throws -> SQLResultSet {
        let output = try await raw(profile: profile, password: password, sql: sql)
        return parse(output, driver: profile.driver)
    }

    static func raw(profile: SQLConnectionProfile, password: String, sql: String) async throws -> String {
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
                    process.arguments = ["-L", "-S"]
                    let escapedUser = profile.username.replacingOccurrences(of: "\"", with: "\\\"")
                    let escapedPassword = password.replacingOccurrences(of: "\"", with: "\\\"")
                    input = """
                    SET HEADING ON FEEDBACK OFF VERIFY OFF ECHO OFF PAGESIZE 50000 LINESIZE 32767 TRIMSPOOL ON
                    SET COLSEP '\\t'
                    CONNECT \"\(escapedUser)\"/\"\(escapedPassword)\"@//\(profile.host):\(profile.port)/\(profile.database)
                    \(sql.hasSuffix(";") ? sql : sql + ";")
                    EXIT
                    """
                }

                let stdout = Pipe()
                let stderr = Pipe()
                let stdin = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = stdin
                process.terminationHandler = { task in
                    let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    if task.terminationStatus == 0 {
                        continuation.resume(returning: out)
                    } else {
                        let detail = err.trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(throwing: SQLWorkspaceError.commandFailed(detail.isEmpty ? "Database client exited with status \(task.terminationStatus)." : detail))
                    }
                }
                do {
                    try process.run()
                    stdin.fileHandleForWriting.write(Data(input.utf8))
                    try? stdin.fileHandleForWriting.close()
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

    private static func parse(_ output: String, driver: SQLDatabaseDriver) -> SQLResultSet {
        var lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if driver == .oracle {
            lines.removeAll { line in
                let stripped = line.trimmingCharacters(in: .whitespaces)
                return stripped.hasPrefix("Connected to:") || stripped.hasPrefix("Disconnected from") || stripped.allSatisfy { $0 == "-" || $0 == " " || $0 == "\t" }
            }
        }
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
    static func discover(profile: SQLConnectionProfile, password: String) async throws -> SQLSchemaSnapshot {
        let tableResult = try await run(profile, password, query: tablesQuery(for: profile.driver))
        var tables = tableResult.rows.compactMap { row -> SQLTable? in
            guard row.count >= 3 else { return nil }
            return SQLTable(schema: clean(row[0]), name: clean(row[1]), kind: clean(row[2]), description: nullable(row, 3))
        }
        var tableIndex = Dictionary(uniqueKeysWithValues: tables.indices.map { (tables[$0].qualifiedName, $0) })

        let columns = try await run(profile, password, query: columnsQuery(for: profile.driver))
        for row in columns.rows where row.count >= 7 {
            let tableName = qualified(schema: row[0], table: row[1])
            guard let index = tableIndex[tableName] else { continue }
            tables[index].columns.append(SQLColumn(
                name: clean(row[2]), dataType: clean(row[3]), nullable: clean(row[4]).uppercased() == "Y" || clean(row[4]).uppercased() == "YES",
                ordinal: Int(clean(row[5])) ?? 0, defaultValue: nullable(row, 6), description: nullable(row, 7)
            ))
        }

        let indexResult = try await run(profile, password, query: indexesQuery(for: profile.driver))
        for row in indexResult.rows where row.count >= 6 {
            let tableName = qualified(schema: row[0], table: row[1])
            guard let index = tableIndex[tableName] else { continue }
            tables[index].indexes.append(SQLIndex(table: tableName, name: clean(row[2]), column: clean(row[5]), ordinal: Int(clean(row[4])) ?? 0, unique: clean(row[3]) == "0" || clean(row[3]).uppercased() == "UNIQUE"))
        }

        let constraints = try await run(profile, password, query: constraintsQuery(for: profile.driver))
        for row in constraints.rows where row.count >= 4 {
            let tableName = qualified(schema: row[0], table: row[1])
            guard let index = tableIndex[tableName] else { continue }
            tables[index].constraints.append("\(clean(row[2])) · \(clean(row[3]))")
        }

        let foreignKeyResult = try await run(profile, password, query: foreignKeysQuery(for: profile.driver))
        let foreignKeys = foreignKeyResult.rows.compactMap { row -> SQLForeignKey? in
            guard row.count >= 7 else { return nil }
            return SQLForeignKey(
                name: clean(row[2]), sourceTable: qualified(schema: row[0], table: row[1]), sourceColumn: clean(row[3]),
                destinationTable: qualified(schema: row[4], table: row[5]), destinationColumn: clean(row[6])
            )
        }

        let procedureResult = try await run(profile, password, query: proceduresQuery(for: profile.driver))
        let procedures = procedureResult.rows.compactMap { row -> SQLProcedure? in
            guard row.count >= 3 else { return nil }
            return SQLProcedure(schema: clean(row[0]), name: clean(row[1]), kind: clean(row[2]), description: nullable(row, 3))
        }
        tables.sort { $0.qualifiedName.localizedStandardCompare($1.qualifiedName) == .orderedAscending }
        tableIndex = Dictionary(uniqueKeysWithValues: tables.indices.map { (tables[$0].qualifiedName, $0) })
        return SQLSchemaSnapshot(profileID: profile.id, tables: tables, foreignKeys: foreignKeys, procedures: procedures)
    }

    private static func run(_ profile: SQLConnectionProfile, _ password: String, query: String) async throws -> SQLResultSet {
        try await SQLCommandLineClient.execute(profile: profile, password: password, sql: query)
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
            return "SELECT c.OWNER, c.TABLE_NAME, c.COLUMN_NAME, c.DATA_TYPE || CASE WHEN c.DATA_LENGTH IS NOT NULL THEN '(' || c.DATA_LENGTH || ')' ELSE '' END, CASE WHEN c.NULLABLE='Y' THEN 'Y' ELSE 'N' END, c.COLUMN_ID, NVL(TO_CHAR(c.DATA_DEFAULT), ''), NVL(m.COMMENTS, '') FROM ALL_TAB_COLUMNS c LEFT JOIN ALL_COL_COMMENTS m ON m.OWNER=c.OWNER AND m.TABLE_NAME=c.TABLE_NAME AND m.COLUMN_NAME=c.COLUMN_NAME ORDER BY c.OWNER, c.TABLE_NAME, c.COLUMN_ID"
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
    @Published var schemaSection: SchemaSection = .tables
    @Published var connections: [SQLConnectionProfile] = []
    @Published var selectedConnectionID: UUID?
    @Published var schema: SQLSchemaSnapshot?
    @Published var schemaSearch = ""
    @Published var selectedTableID: String?
    @Published var queryText = ""
    @Published var visualQuery = SQLVisualQuery()
    @Published var result = SQLResultSet()
    @Published var status = "Choose a connection to discover its schema."
    @Published var isBusy = false
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

    struct SQLSavedQuery: Codable, Identifiable, Hashable {
        var id = UUID()
        var name: String
        var sql: String
        var updatedAt = Date()
    }

    init() { load() }

    var selectedConnection: SQLConnectionProfile? { connections.first { $0.id == selectedConnectionID } }
    var selectedTable: SQLTable? { schema?.tables.first { $0.id == selectedTableID } }
    var visibleTables: [SQLTable] {
        guard let schema else { return [] }
        let wanted: String = schemaSection == .views ? "VIEW" : "TABLE"
        let query = schemaSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return schema.tables.filter { table in
            table.kind.uppercased().contains(wanted) && (query.isEmpty || table.qualifiedName.lowercased().contains(query) || table.columns.contains { $0.name.lowercased().contains(query) })
        }
    }
    var visibleProcedures: [SQLProcedure] {
        guard let schema else { return [] }
        let query = schemaSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return schema.procedures.filter { query.isEmpty || $0.qualifiedName.lowercased().contains(query) }
    }
    var joinSuggestions: [SQLJoinSuggestion] { schema?.joins(for: visualQuery.tables) ?? [] }
    var activeCollection: SQLLocalCollection? { collections.first { $0.id == selectedCollectionID } }
    var pendingConnectionDeletion: SQLConnectionProfile? { connections.first { $0.id == pendingConnectionDeletionID } }

    func newConnection() {
        isEditingConnection = false
        connectionDraft = SQLConnectionProfile(name: "New Connection", environment: "Development", driver: .mysql, host: "", database: "", username: "")
        secretDraft = ""
        showsConnectionEditor = true
    }

    func editConnection(_ profile: SQLConnectionProfile) {
        isEditingConnection = true
        connectionDraft = profile
        secretDraft = SQLCredentialVault.password(for: profile.id) ?? ""
        showsConnectionEditor = true
    }

    func saveConnection(test: Bool = false) {
        let profile = normalized(connectionDraft)
        guard !profile.name.isEmpty, !profile.host.isEmpty, !profile.database.isEmpty, !profile.username.isEmpty else { status = SQLWorkspaceError.invalidConnection.localizedDescription; return }
        guard !secretDraft.isEmpty else { status = SQLWorkspaceError.missingSecret.localizedDescription; return }
        do {
            try SQLCredentialVault.save(secretDraft, for: profile.id)
            if let index = connections.firstIndex(where: { $0.id == profile.id }) { connections[index] = profile } else { connections.append(profile) }
            selectedConnectionID = profile.id
            save()
            status = test ? "Testing \(profile.name)…" : "Saved \(profile.name). Password is in the macOS Keychain."
            if test { execute(sql: testSQL(for: profile.driver), readOnly: true, completion: { self.status = "Connected to \(profile.name)." }) }
            else { showsConnectionEditor = false }
        } catch { status = error.localizedDescription }
    }

    func deleteConnection(_ profile: SQLConnectionProfile) {
        connections.removeAll { $0.id == profile.id }
        cachedSchemas.removeValue(forKey: profile.id)
        SQLCredentialVault.delete(profileID: profile.id)
        if selectedConnectionID == profile.id { selectedConnectionID = connections.first?.id; schema = nil }
        save()
        status = "Removed \(profile.name) and its Keychain password."
    }

    func requestDeleteConnection(_ profile: SQLConnectionProfile) { pendingConnectionDeletionID = profile.id }
    func confirmDeleteConnection() {
        guard let profile = pendingConnectionDeletion else { return }
        pendingConnectionDeletionID = nil
        deleteConnection(profile)
    }

    func discover() {
        guard let profile = selectedConnection else { status = "Choose or add a connection first."; return }
        guard let password = SQLCredentialVault.password(for: profile.id) else { status = SQLWorkspaceError.missingSecret.localizedDescription; return }
        isBusy = true; status = "Discovering tables, columns, keys, indexes, and procedures…"
        runningTask = Task { [weak self] in
            do {
                let snapshot = try await SQLSchemaDiscovery.discover(profile: profile, password: password)
                guard !Task.isCancelled else { return }
                self?.schema = snapshot
                self?.cachedSchemas[profile.id] = snapshot
                self?.selectedTableID = snapshot.tables.first?.id
                self?.status = "Discovered \(snapshot.tables.count) tables/views, \(snapshot.foreignKeys.count) relationships, and \(snapshot.procedures.count) procedures."
                self?.isBusy = false
                self?.save()
            } catch {
                self?.status = error.localizedDescription
                self?.isBusy = false
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
        queryText = visualQuery.sql(for: driver)
        mode = .sql
        runReadOnly()
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

    func cancel() { runningTask?.cancel(); isBusy = false }

    private func execute(sql: String, readOnly: Bool, completion: (() -> Void)? = nil) {
        let clean = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { status = "Write a query first."; return }
        guard !readOnly || SQLCommandLineClient.isReadOnly(clean) else { status = SQLWorkspaceError.readOnly.localizedDescription; return }
        guard let profile = selectedConnection else { status = "Choose a connection first."; return }
        guard let password = SQLCredentialVault.password(for: profile.id) else { status = SQLWorkspaceError.missingSecret.localizedDescription; return }
        isBusy = true; status = "Running on \(profile.name)…"
        runningTask = Task { [weak self] in
            do {
                let result = try await SQLCommandLineClient.execute(profile: profile, password: password, sql: clean)
                guard !Task.isCancelled else { return }
                self?.result = result
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
        selectedCollectionID = collections.first?.id
    }

    private func save() {
        do {
            try ApplicationPaths.prepare()
            let data = try JSONEncoder().encode(SavedWorkspace(connections: connections, selectedConnectionID: selectedConnectionID, snapshots: cachedSchemas, savedQueries: savedQueries, collections: collections))
            try data.write(to: workspaceURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: workspaceURL.path)
        } catch { status = "Could not save SQL workspace: \(error.localizedDescription)" }
    }

    func selectConnection(_ id: UUID) {
        selectedConnectionID = id
        schema = cachedSchemas[id]
        selectedTableID = schema?.tables.first?.id
        save()
        status = schema == nil ? "Selected \(selectedConnection?.name ?? "connection"). Refresh discovery to load its schema." : "Loaded cached schema for \(selectedConnection?.name ?? "connection")."
    }
}

private struct SQLWorkspaceView: View {
    @ObservedObject var model: SQLWorkspaceModel
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        ZStack {
            LiquidGlassBackdrop(material: .underWindowBackground, blendingMode: .behindWindow)
            VStack(spacing: 8) {
                toolbar
                workspaceContent
                statusBar
            }
            .padding(10)
        }
        .tint(settings.accentTheme.primary)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showsConnectionEditor) { SQLConnectionEditor(model: model) }
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
                Text("SQL Workspace").font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(model.selectedConnection?.environment ?? "No environment")
                    .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
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
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .font(.system(size: 11.5, weight: .medium))
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
            Picker("Mode", selection: $model.mode) {
                ForEach(SQLWorkspaceModel.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 268)
            Menu {
                Button("New Connection…", action: model.newConnection)
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
                schemaSidebar.frame(minWidth: 210, idealWidth: 255, maxWidth: 340)
                mainContent.frame(minWidth: 420)
                inspector.frame(minWidth: 235, idealWidth: 285, maxWidth: 360)
            }
        }
    }

    private var connectionSetup: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 20)
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(settings.accentTheme.gradient)
                .frame(width: 68, height: 68)
                .background(.ultraThinMaterial, in: PrismaticPanelShape(cut: 13))
            Text("Connect a database").font(.system(size: 17, weight: .semibold, design: .rounded))
            Text("Add a named MySQL or Oracle environment. RayPlacement keeps the password in Keychain and discovers only what that account can see.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            HStack(spacing: 8) {
                Label("MySQL", systemImage: "cylinder")
                Label("Oracle", systemImage: "cylinder")
            }
            .font(.caption.weight(.medium))
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
            TextField("Filter schema", text: $model.schemaSearch).textFieldStyle(.plain)
                .padding(.horizontal, 9).frame(height: 28)
                .background(Color.white.opacity(0.06), in: PrismaticPanelShape(cut: 5))
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
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(settings.accentTheme.tertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(table.name).lineLimit(1).font(.system(size: 11.5, weight: .medium))
                    Text(table.schema).lineLimit(1).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("\(table.columns.count)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 7).frame(height: 34)
            .background(model.selectedTableID == table.id ? settings.accentTheme.primary.opacity(0.13) : .clear, in: PrismaticPanelShape(cut: 5))
        }
        .buttonStyle(.plain)
        .onDrag { NSItemProvider(object: table.qualifiedName as NSString) }
        .contextMenu { Button("Add to canvas") { model.addTable(table) }; Button("Insert in SQL") { model.insertDroppedSQL(table.qualifiedName) } }
    }

    private func procedureRow(_ procedure: SQLProcedure) -> some View {
        Button { model.insertProcedure(procedure) } label: {
            HStack(spacing: 7) {
                Image(systemName: "function").font(.system(size: 10, weight: .bold)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(procedure.name).lineLimit(1).font(.system(size: 11.5, weight: .medium))
                    Text("\(procedure.schema) · \(procedure.kind)").lineLimit(1).font(.system(size: 9)).foregroundStyle(.secondary)
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
                Label("Visual query", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Button("Run", action: model.runCanvas).buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(model.visualQuery.tables.isEmpty || model.isBusy)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(model.visualQuery.tables, id: \.self) { table in
                        HStack(spacing: 5) {
                            Image(systemName: "tablecells").font(.caption2)
                            Text(table).font(.system(size: 10.5, design: .monospaced)).lineLimit(1)
                            Button { model.visualQuery.tables.removeAll { $0 == table }; model.visualQuery.projections.removeAll { $0 == "\(table).*" } } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                                .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8).frame(height: 27)
                        .background(settings.accentTheme.primary.opacity(0.13), in: PrismaticPanelShape(cut: 5))
                    }
                    if model.visualQuery.tables.isEmpty { Text("Drag a table here or use Add to canvas").font(.caption).foregroundStyle(.secondary) }
                }.padding(.horizontal, 3)
            }
            .padding(8).frame(minHeight: 44)
            .background(Color.white.opacity(0.045), in: PrismaticPanelShape(cut: 7))
            .onDrop(of: [.plainText], isTargeted: nil) { providers in
                let tables = model.schema?.tables ?? []
                providers.first?.loadObject(ofClass: NSString.self) { value, _ in
                    guard let text = value as? String, let table = tables.first(where: { $0.qualifiedName == text }) else { return }
                    DispatchQueue.main.async { model.addTable(table) }
                }
                return true
            }
            HStack(spacing: 8) {
                Text("WHERE").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                TextField("Optional filter, e.g. status = 'OPEN'", text: $model.visualQuery.predicate).textFieldStyle(.plain)
                Text("Limit").font(.caption2).foregroundStyle(.secondary)
                TextField("250", value: $model.visualQuery.limit, format: .number).frame(width: 46).textFieldStyle(.roundedBorder)
            }.padding(9).background(Color.white.opacity(0.045), in: PrismaticPanelShape(cut: 7))
            VStack(alignment: .leading, spacing: 5) {
                Text("Generated SQL").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(model.visualQuery.sql(for: model.selectedConnection?.driver ?? .mysql))
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(Color.black.opacity(0.20), in: PrismaticPanelShape(cut: 7))
            }
            resultsView
        }
        .padding(10).liquidGlass(cornerRadius: 12, depth: .raised, accentOpacity: 0.016)
    }

    private var sqlEditor: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Label("Free SQL", systemImage: "chevron.left.forwardslash.chevron.right").font(.system(size: 12.5, weight: .semibold))
                Text("Any statement is allowed after write confirmation.").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                TextField("Save query as", text: $model.savedQueryName).textFieldStyle(.roundedBorder).frame(width: 140)
                Button(action: model.saveCurrentQuery) { Image(systemName: "bookmark") }.buttonStyle(.bordered).controlSize(.small)
                Button("Read-only", action: model.runReadOnly).buttonStyle(.bordered).controlSize(.small).disabled(model.isBusy)
                Button("Run", action: model.runFreeSQL).buttonStyle(.borderedProminent).controlSize(.small).disabled(model.isBusy)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.queryText)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(7)
                if model.queryText.isEmpty {
                    Text("Drop a table or write SQL…").font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary).padding(14)
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
                Text("Results").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if !model.result.rows.isEmpty {
                    Text("\(model.result.rows.count) rows").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    Button("Export range", action: model.exportResultRange).buttonStyle(.bordered).controlSize(.mini)
                }
            }
            if model.result.columns.isEmpty {
                Text("Results appear here.").font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                        GridRow { ForEach(model.result.columns, id: \.self) { Text($0).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(settings.accentTheme.tertiary) } }
                        Divider()
                        ForEach(Array(model.result.rows.prefix(100).enumerated()), id: \.offset) { _, row in
                            GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, value in Text(value).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled).lineLimit(1) } }
                        }
                    }.padding(8)
                }.frame(minHeight: 130, maxHeight: 255).background(Color.black.opacity(0.16), in: PrismaticPanelShape(cut: 7))
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
            Label("Local document store", systemImage: "shippingbox.fill").font(.system(size: 12.5, weight: .semibold))
            Text("Saved locally · no remote service").font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Button("Reveal file") { NSWorkspace.shared.activateFileViewerSelecting([ApplicationPaths.applicationSupport.appendingPathComponent("sql-workspace.json")]) }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }

    private var storageExportControls: some View {
        HStack(spacing: 7) {
            TextField("Collection name", text: $model.exportCollectionName).textFieldStyle(.roundedBorder)
            Text("Rows").font(.caption).foregroundStyle(.secondary)
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
                        Text(collection.name).font(.system(size: 12, weight: .medium))
                        Text("\(collection.documents.count) documents · \(collection.source)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
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
                Text(collection.name).font(.system(size: 15, weight: .semibold))
                Text("\(collection.documents.count) documents · updated \(collection.updatedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(collection.documents.prefix(50).enumerated()), id: \.offset) { index, document in documentCard(index: index, document: document) }
            }.padding(10)
        }
    }

    private func documentCard(index: Int, document: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("#\(index + 1)").font(.caption2.weight(.bold)).foregroundStyle(settings.accentTheme.tertiary)
            ForEach(document.keys.sorted(), id: \.self) { key in
                HStack(alignment: .top, spacing: 7) {
                    Text(key).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                    Text(document[key] ?? "").font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                }
            }
        }.padding(8).background(Color.white.opacity(0.045), in: PrismaticPanelShape(cut: 6))
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let table = model.selectedTable {
                HStack {
                    VStack(alignment: .leading, spacing: 2) { Text(table.name).font(.system(size: 13, weight: .semibold)); Text(table.schema).font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Button(action: { model.addTable(table) }) { Image(systemName: "plus.square.on.square") }.buttonStyle(.bordered).controlSize(.mini).help("Add to canvas")
                }
                if let description = table.description, !description.isEmpty { Text(description).font(.caption).foregroundStyle(.secondary) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Columns").font(.caption.weight(.semibold)).foregroundStyle(settings.accentTheme.tertiary)
                        ForEach(table.columns) { column in
                            HStack(alignment: .top, spacing: 5) {
                                Image(systemName: column.nullable ? "circle" : "key.fill").font(.system(size: 8)).foregroundStyle(column.nullable ? Color.secondary : Color.yellow)
                                VStack(alignment: .leading, spacing: 1) { Text(column.name).font(.system(size: 10.5, weight: .medium, design: .monospaced)); Text(column.dataType).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary) }
                            }.contextMenu { Button("Insert column") { model.insertDroppedSQL("\(table.qualifiedName).\(column.name)") } }
                        }
                        if !table.indexes.isEmpty { Divider(); Text("Indexes").font(.caption.weight(.semibold)).foregroundStyle(settings.accentTheme.tertiary); ForEach(table.indexes) { index in Text("\(index.unique ? "UNIQUE " : "")\(index.name) · \(index.column)").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.secondary) } }
                        if !table.constraints.isEmpty { Divider(); Text("Constraints").font(.caption.weight(.semibold)).foregroundStyle(settings.accentTheme.tertiary); ForEach(table.constraints, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) } }
                    }.padding(.vertical, 2)
                }
            } else {
                emptyState("tablecells", "Select a table", "Details, keys, and columns appear here.")
            }
            Divider()
            Text("Compatible joins").font(.caption.weight(.semibold)).foregroundStyle(settings.accentTheme.tertiary)
            if model.joinSuggestions.isEmpty { Text("Add a table to see foreign-key joins.").font(.caption2).foregroundStyle(.secondary) }
            else { ScrollView { VStack(alignment: .leading, spacing: 5) { ForEach(model.joinSuggestions) { join in Button { model.addJoin(join) } label: { VStack(alignment: .leading, spacing: 2) { Text(join.toTable).font(.system(size: 10.5, weight: .semibold, design: .monospaced)); Text(join.label).font(.system(size: 8.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2) } .frame(maxWidth: .infinity, alignment: .leading).padding(7).background(Color.white.opacity(0.05), in: PrismaticPanelShape(cut: 5)) }.buttonStyle(.plain) } } } }
        }
        .padding(9).liquidGlass(cornerRadius: 12, depth: .recessed, accentOpacity: 0.012)
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            if model.isBusy { ProgressView().controlSize(.small) } else { Circle().fill(model.status.lowercased().contains("could not") || model.status.lowercased().contains("not found") ? Color.orange : settings.accentTheme.tertiary).frame(width: 5, height: 5) }
            Text(model.status).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if let schema = model.schema { Text("Schema cached \(schema.discoveredAt.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 10).frame(height: 27)
        .background(Color.black.opacity(0.16), in: PrismaticPanelShape(cut: 6))
    }

    private func emptyState(_ symbol: String, _ title: String, _ description: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 11.5, weight: .semibold))
            Text(description).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }
}

private struct SQLConnectionEditor: View {
    @ObservedObject var model: SQLWorkspaceModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack { Label(model.isEditingConnection ? "Edit connection" : "New connection", systemImage: "cylinder.split.1x2").font(.title3.weight(.semibold)); Spacer(); Button(action: { dismiss() }) { Image(systemName: "xmark") }.buttonStyle(.borderless) }
            Grid(horizontalSpacing: 10, verticalSpacing: 9) {
                row("Name") { TextField("Operations MySQL", text: $model.connectionDraft.name) }
                row("Environment") { TextField("Development", text: $model.connectionDraft.environment) }
                row("Engine") { Picker("Engine", selection: $model.connectionDraft.driver) { ForEach(SQLDatabaseDriver.allCases) { Text($0.title).tag($0) } }.labelsHidden().pickerStyle(.segmented) }
                row("Host") { TextField("db.example.com", text: $model.connectionDraft.host) }
                row("Port") { TextField("Port", value: $model.connectionDraft.port, format: .number) }
                row(model.connectionDraft.driver == .oracle ? "Service" : "Database") { TextField(model.connectionDraft.driver == .oracle ? "service_name" : "database", text: $model.connectionDraft.database) }
                row("Username") { TextField("Username", text: $model.connectionDraft.username) }
                row("Password") { SecureField("Stored in macOS Keychain", text: $model.secretDraft) }
                row("Client") { TextField(model.connectionDraft.driver.defaultCommand, text: $model.connectionDraft.commandPath).font(.system(size: 11, design: .monospaced)) }
            }
            Text("The workspace saves connection metadata locally with restricted permissions. Passwords are stored separately in this Mac’s Keychain and are excluded from query history, schema files, and usage logs.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { model.saveConnection(); dismiss() }.buttonStyle(.bordered); Button("Save & Test") { model.saveConnection(test: true); dismiss() }.buttonStyle(.borderedProminent) }
        }
        .padding(20).frame(width: 560)
        .background(LiquidGlassBackdrop(material: .underWindowBackground, blendingMode: .behindWindow))
        .preferredColorScheme(.dark)
    }

    private func row<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow { Text(name).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 83, alignment: .trailing); content().textFieldStyle(.roundedBorder) }
    }
}
