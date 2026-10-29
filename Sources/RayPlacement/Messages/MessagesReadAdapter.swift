import Foundation
import SQLite3

/// SQLite is an undocumented Messages implementation detail. This adapter only
/// issues fixed, parameterized, bounded SELECTs against a read-only snapshot.
actor MessagesReadAdapter {
    private let databaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Messages/chat.db")

    private struct Schema {
        let chat: Set<String>
        let message: Set<String>
        let handle: Set<String>
        let attachment: Set<String>
        let chatMessageJoin: Set<String>
        let chatHandleJoin: Set<String>
        let messageAttachmentJoin: Set<String>

        init(_ db: OpaquePointer) throws {
            chat = try Self.columns("chat", db)
            message = try Self.columns("message", db)
            handle = try Self.columns("handle", db)
            attachment = try Self.columns("attachment", db)
            chatMessageJoin = try Self.columns("chat_message_join", db)
            chatHandleJoin = try Self.columns("chat_handle_join", db)
            messageAttachmentJoin = try Self.columns("message_attachment_join", db)
            guard chat.contains("guid"),
                  message.isSuperset(of: ["date", "guid"]),
                  chatMessageJoin.isSuperset(of: ["chat_id", "message_id"]) else {
                throw MessagesCapabilityError.schemaUnsupported
            }
        }

        private static func columns(_ table: String, _ db: OpaquePointer) throws -> Set<String> {
            // All names are fixed here; no caller-supplied SQL identifier is accepted.
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw MessagesCapabilityError.schemaUnsupported }
            defer { sqlite3_finalize(statement) }
            var result: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = MessagesReadAdapter.text(statement, 1, maximum: 128) {
                    result.insert(name)
                }
            }
            return result
        }
    }

    private enum Bind {
        case text(String), double(Double), int(Int)
    }

    func listChats(limit: Int, selectedGUIDs: Set<String>? = nil) throws -> [MessagesConversation] {
        guard (1...100).contains(limit),
              (selectedGUIDs?.count ?? 0) <= 500,
              selectedGUIDs?.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }) ?? true else {
            throw MessagesCapabilityError.invalidRequest
        }
        if selectedGUIDs?.isEmpty == true { return [] }
        return try withSnapshot { db, schema in
            let title = schema.chat.contains("display_name") ? "c.display_name" : "NULL"
            let service = schema.chat.contains("service_name") ? "c.service_name" : "NULL"
            let groupCount = schema.chatHandleJoin.isSuperset(of: ["chat_id", "handle_id"])
                ? "(SELECT COUNT(*) FROM chat_handle_join ch WHERE ch.chat_id = c.ROWID)"
                : "0"
            let selected = selectedGUIDs?.sorted() ?? []
            let scope = selectedGUIDs == nil ? "" :
                "WHERE c.guid IN (\(Array(repeating: "?", count: selected.count).joined(separator: ",")))"
            let sql = """
                SELECT c.guid, \(title), \(service), MAX(m.date), \(groupCount)
                FROM chat c
                JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
                JOIN message m ON m.ROWID = cmj.message_id
                \(scope)
                GROUP BY c.ROWID
                ORDER BY MAX(m.date) DESC LIMIT ?
                """
            return try rows(db, sql, selected.map(Bind.text) + [.int(limit)]) { row in
                guard let guid = Self.text(row, 0, maximum: 512), !guid.isEmpty else { return nil }
                let name = Self.text(row, 1, maximum: 200)
                return MessagesConversation(
                    guid: guid,
                    title: name?.isEmpty == false ? name! : "Conversation",
                    service: Self.text(row, 2, maximum: 80),
                    lastMessageAt: Self.date(row, 3),
                    isGroup: sqlite3_column_int(row, 4) > 1
                )
            }
        }
    }

    func messages(in chatGUID: String, after: Date, before: Date,
                  limit: Int) throws -> [MessagesMessage] {
        guard !chatGUID.isEmpty, chatGUID.utf8.count <= 512,
              (1...100).contains(limit) else { throw MessagesCapabilityError.invalidRequest }
        return try withSnapshot { db, schema in
            try messageRows(db, schema, chatGUIDs: [chatGUID], query: nil,
                            after: after, before: before, limit: limit)
        }
    }

    func message(_ messageGUID: String, in chatGUID: String,
                 after: Date, before: Date) throws -> MessagesMessage {
        guard !messageGUID.isEmpty, messageGUID.utf8.count <= 512,
              !chatGUID.isEmpty, chatGUID.utf8.count <= 512 else {
            throw MessagesCapabilityError.invalidRequest
        }
        return try withSnapshot { db, schema in
            guard let message = try messageRows(
                db, schema, chatGUIDs: [chatGUID], query: nil,
                after: after, before: before, limit: 1,
                messageGUID: messageGUID
            ).first else {
                throw MessagesCapabilityError.messageUnavailable
            }
            return message
        }
    }

    func search(text query: String, after: Date, before: Date, limit: Int,
                permittedGUIDs: Set<String>) throws -> [MessagesMessage] {
        guard query.utf8.count <= 256, (1...50).contains(limit),
              permittedGUIDs.count <= 500,
              permittedGUIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }) else {
            throw MessagesCapabilityError.invalidRequest
        }
        guard !permittedGUIDs.isEmpty else { return [] }
        return try withSnapshot { db, schema in
            try messageRows(db, schema, chatGUIDs: permittedGUIDs.sorted(),
                            query: query.isEmpty ? nil : query,
                            after: after, before: before, limit: limit)
        }
    }

    func participants(in chatGUID: String) throws -> [String] {
        guard !chatGUID.isEmpty, chatGUID.utf8.count <= 512 else {
            throw MessagesCapabilityError.invalidRequest
        }
        return try withSnapshot { db, schema in
            guard schema.chatHandleJoin.isSuperset(of: ["chat_id", "handle_id"]),
                  schema.handle.contains("id") else {
                throw MessagesCapabilityError.schemaUnsupported
            }
            let participants: [String] = try rows(db, """
                SELECT DISTINCT h.id FROM chat c
                JOIN chat_handle_join ch ON ch.chat_id = c.ROWID
                JOIN handle h ON h.ROWID = ch.handle_id
                WHERE c.guid = ? LIMIT 33
                """, [.text(chatGUID)]) { row in
                    Self.text(row, 0, maximum: 320) ?? ""
                }
            guard participants.count <= 32,
                  participants.allSatisfy({ address in
                    !address.isEmpty && !address.unicodeScalars.contains {
                        CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
                    }
                  }) else {
                throw MessagesCapabilityError.schemaUnsupported
            }
            return participants
        }
    }

    func attachments(for messageGUID: String, in chatGUID: String) throws -> [MessagesAttachment] {
        guard !messageGUID.isEmpty, messageGUID.utf8.count <= 512,
              !chatGUID.isEmpty, chatGUID.utf8.count <= 512 else {
            throw MessagesCapabilityError.invalidRequest
        }
        return try withSnapshot { db, schema in
            guard schema.messageAttachmentJoin.isSuperset(of: ["message_id", "attachment_id"]),
                  schema.attachment.contains("guid") else {
                throw MessagesCapabilityError.schemaUnsupported
            }
            let filename = schema.attachment.contains("filename") ? "a.filename" : "NULL"
            let mime = schema.attachment.contains("mime_type") ? "a.mime_type" : "NULL"
            let size = schema.attachment.contains("total_bytes") ? "a.total_bytes" : "NULL"
            return try rows(db, """
                SELECT a.guid, \(filename), \(mime), \(size)
                FROM chat c
                JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
                JOIN message m ON m.ROWID = cmj.message_id
                JOIN message_attachment_join maj ON maj.message_id = m.ROWID
                JOIN attachment a ON a.ROWID = maj.attachment_id
                WHERE c.guid = ? AND m.guid = ? LIMIT 21
                """, [.text(chatGUID), .text(messageGUID)]) { row in
                    guard let guid = Self.text(row, 0, maximum: 512) else { return nil }
                    return MessagesAttachment(
                        guid: guid, messageGUID: messageGUID,
                        filename: Self.text(row, 1, maximum: 512).map { URL(fileURLWithPath: $0).lastPathComponent },
                        mimeType: Self.text(row, 2, maximum: 160),
                        byteCount: sqlite3_column_type(row, 3) == SQLITE_NULL ? nil :
                            max(0, sqlite3_column_int64(row, 3))
                    )
                }.prefix(20).map { $0 }
        }
    }

    private func messageRows(_ db: OpaquePointer, _ schema: Schema,
                             chatGUIDs: [String], query: String?,
                             after: Date, before: Date, limit: Int,
                             messageGUID: String? = nil) throws -> [MessagesMessage] {
        guard after < before else { throw MessagesCapabilityError.invalidRequest }
        let senderJoin = schema.message.contains("handle_id") && schema.handle.contains("id")
            ? "LEFT JOIN handle h ON h.ROWID = m.handle_id" : ""
        let sender = senderJoin.isEmpty ? "NULL" : "h.id"
        let body = schema.message.contains("text") ? "m.text" : "NULL"
        let rich = schema.message.contains("attributedBody") ? "m.attributedBody" : "NULL"
        let mine = schema.message.contains("is_from_me") ? "m.is_from_me" : "0"
        let service = schema.message.contains("service") ? "m.service" : "NULL"
        let placeholders = Array(repeating: "?", count: chatGUIDs.count).joined(separator: ",")
        // Messages has used seconds and higher-resolution Apple-reference dates.
        // Normalize only known magnitudes; reject nonsensical values on decode.
        let dateExpression = """
            (CASE WHEN ABS(m.date) >= 100000000000000000 THEN m.date / 1000000000.0
                  WHEN ABS(m.date) >= 100000000000000 THEN m.date / 1000000.0
                  WHEN ABS(m.date) >= 100000000000 THEN m.date / 1000.0
                  ELSE m.date END)
            """
        var binds: [Bind] = chatGUIDs.map(Bind.text)
        binds += [.double(after.timeIntervalSinceReferenceDate),
                  .double(before.timeIntervalSinceReferenceDate)]
        var filter = ""
        if let query {
            guard schema.message.contains("text") else { throw MessagesCapabilityError.schemaUnsupported }
            // Escape LIKE metacharacters. Search remains scoped by chat and time.
            let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            filter = "AND m.text LIKE ? ESCAPE '\\'"
            binds.append(.text("%\(escaped)%"))
        }
        if let messageGUID {
            filter += " AND m.guid = ?"
            binds.append(.text(messageGUID))
        }
        binds.append(.int(limit))
        let sql = """
            SELECT c.guid, m.guid, \(sender), m.date, \(body), \(rich), \(mine), \(service)
            FROM chat c
            JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            JOIN message m ON m.ROWID = cmj.message_id
            \(senderJoin)
            WHERE c.guid IN (\(placeholders))
              AND \(dateExpression) >= ? AND \(dateExpression) <= ?
              \(filter)
            ORDER BY m.date DESC LIMIT ?
            """
        return try rows(db, sql, binds) { row in
            guard let chat = Self.text(row, 0, maximum: 512),
                  let guid = Self.text(row, 1, maximum: 512),
                  let date = Self.date(row, 3) else { return nil }
            let plain = Self.text(row, 4, maximum: 64 * 1_024)
            let attributed = Self.blob(row, 5, maximum: 256 * 1_024)
            let decoded = plain ?? attributed.flatMap(Self.decodeAttributedBody)
            let status: String
            if decoded != nil { status = plain != nil ? "plain_text" : "attributed_text" }
            else if attributed != nil { status = "unsupported_attributed_body" }
            else { status = "content_unavailable" }
            return MessagesMessage(
                guid: guid, conversationGUID: chat,
                senderAddress: Self.text(row, 2, maximum: 320),
                sentAt: date, text: decoded, contentStatus: status,
                isFromMe: sqlite3_column_int(row, 6) != 0,
                service: Self.text(row, 7, maximum: 80)
            )
        }
    }

    private func withSnapshot<T>(_ body: (OpaquePointer, Schema) throws -> T) throws -> T {
        var opened: OpaquePointer?
        let status = sqlite3_open_v2(databaseURL.path, &opened,
                                     SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let db = opened else {
            if let opened { sqlite3_close(opened) }
            // A missing or inaccessible file does not itself prove Full Disk
            // Access status. Report only explicit SQLite authorization errors.
            throw status == SQLITE_AUTH || status == SQLITE_PERM
                ? MessagesCapabilityError.permissionDenied : .databaseUnavailable
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        guard sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, "BEGIN DEFERRED", nil, nil, nil) == SQLITE_OK else {
            throw MessagesCapabilityError.databaseUnavailable
        }
        do {
            let schema = try Schema(db)
            let result = try body(db, schema)
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw MessagesCapabilityError.databaseUnavailable
            }
            return result
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func rows<T>(_ db: OpaquePointer, _ sql: String, _ binds: [Bind],
                         _ map: (OpaquePointer) -> T?) throws -> [T] {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK,
              let statement = prepared else { throw MessagesCapabilityError.schemaUnsupported }
        defer { sqlite3_finalize(statement) }
        for (index, bind) in binds.enumerated() {
            let i = Int32(index + 1)
            let status: Int32
            switch bind {
            case .text(let value):
                status = value.withCString { pointer in
                    sqlite3_bind_text(statement, i, pointer, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            case .double(let value): status = sqlite3_bind_double(statement, i, value)
            case .int(let value): status = sqlite3_bind_int(statement, i, Int32(value))
            }
            guard status == SQLITE_OK else { throw MessagesCapabilityError.invalidRequest }
        }
        var result: [T] = []
        var steps = 0
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw MessagesCapabilityError.databaseUnavailable }
            steps += 1
            guard steps <= 1_000 else { throw MessagesCapabilityError.invalidRequest }
            if let item = map(statement) { result.append(item) }
        }
    }

    private static func text(_ row: OpaquePointer, _ index: Int32, maximum: Int) -> String? {
        guard sqlite3_column_type(row, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(row, index) else { return nil }
        let count = Int(sqlite3_column_bytes(row, index))
        guard count >= 0, count <= maximum else { return nil }
        return String(data: Data(bytes: pointer, count: count), encoding: .utf8)
    }

    private static func blob(_ row: OpaquePointer, _ index: Int32, maximum: Int) -> Data? {
        guard sqlite3_column_type(row, index) == SQLITE_BLOB,
              let pointer = sqlite3_column_blob(row, index) else { return nil }
        let count = Int(sqlite3_column_bytes(row, index))
        guard count > 0, count <= maximum else { return nil }
        return Data(bytes: pointer, count: count)
    }

    private static func date(_ row: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(row, index) != SQLITE_NULL else { return nil }
        let raw = sqlite3_column_double(row, index)
        guard raw.isFinite else { return nil }
        let magnitude = abs(raw)
        let seconds: Double
        if magnitude >= 100_000_000_000_000_000 { seconds = raw / 1_000_000_000 }
        else if magnitude >= 100_000_000_000_000 { seconds = raw / 1_000_000 }
        else if magnitude >= 100_000_000_000 { seconds = raw / 1_000 }
        else { seconds = raw }
        guard seconds.isFinite,
              (-31_557_600_000...31_557_600_000).contains(seconds) else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    private static func decodeAttributedBody(_ data: Data) -> String? {
        // Only a bounded secure keyed archive is accepted. Legacy typedstream
        // and unknown serialized formats are reported as partial data, not run
        // through a general-purpose object unarchiver.
        guard data.count <= 256 * 1_024, data.starts(with: Data("bplist".utf8)),
              let object = try? NSKeyedUnarchiver.unarchivedObject(
                ofClasses: [NSAttributedString.self, NSString.self], from: data
              ) else { return nil }
        let value = (object as? NSAttributedString)?.string ?? (object as? String)
        guard let value, value.utf8.count <= 64 * 1_024 else { return nil }
        return value
    }
}
