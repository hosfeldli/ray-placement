import Foundation
import SQLite3
import Testing
@testable import RayPlacement

private func typedBody(_ text: String) -> Data {
    var bytes: [UInt8] = [4, 11] + Array("streamtyped".utf8) + [0x81, 0xe8, 3, 0x84, 1, 0x40, 0x84, 0x84, 0x84, 18]
    bytes += Array("NSAttributedString".utf8) + [0, 0x84, 0x84, 8]
    bytes += Array("NSObject".utf8) + [0, 0x85, 0x92, 0x84, 0x84, 0x84, 8]
    bytes += Array("NSString".utf8) + [1, 0x95, 0x84, 1, 0x2b]
    let body = Array(text.utf8)
    if body.count < 128 { bytes.append(UInt8(body.count)) }
    else if body.count <= 65535 { bytes += [0x81, UInt8(body.count & 255), UInt8(body.count >> 8)] }
    else { bytes += [0x82, UInt8(body.count & 255), UInt8((body.count >> 8) & 255), UInt8(body.count >> 16), 0] }
    bytes += body + [0x86, 0x84]
    return Data(bytes)
}

@Test func messagesDecodeRichBodiesWithoutTruncatingUnicodeOrLeakingArchiveMetadata() {
    for text in ["2 people at 7?", "A + B = 100%", String(repeating: "🙂 café\n", count: 160), String(repeating: "x", count: 65536)] {
        #expect(MessagesBodyDecoder.decode(typedBody(text)) == text)
    }
    var truncated = typedBody("Exact message")
    truncated.removeLast(4)
    #expect(MessagesBodyDecoder.decode(truncated) == nil)
    #expect(MessagesBodyDecoder.decode(Data("NSString random printable garbage".utf8)) == nil)
    #expect(MessagesBodyDecoder.decode(typedBody("a\0b")) == nil)
    #expect(MessagesBodyDecoder.decode(Data(repeating: 0, count: 300_000)) == nil)
}

@Test func messagesStillDecodeSecureKeyedArchiveBodies() throws {
    let body = try NSKeyedArchiver.archivedData(withRootObject: "A keyed message" as NSString, requiringSecureCoding: true)
    #expect(MessagesBodyDecoder.decode(body) == "A keyed message")
}

@Test func messagesReadSearchesDecodedBodiesAndKeepsConversationScope() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("fixture.db")
    var opened: OpaquePointer?
    #expect(sqlite3_open(url.path, &opened) == SQLITE_OK)
    let db = try #require(opened)
    defer { sqlite3_close(db) }
    let now = Date().timeIntervalSinceReferenceDate
    let schema = """
        CREATE TABLE chat (guid TEXT, display_name TEXT, service_name TEXT);
        CREATE TABLE message (guid TEXT, date REAL, text TEXT, attributedBody BLOB, is_from_me INTEGER, handle_id INTEGER, service TEXT);
        CREATE TABLE handle (id TEXT);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE attachment (guid TEXT);
        CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
        INSERT INTO chat VALUES ('selected', '', 'iMessage'), ('excluded', 'Other group', 'iMessage');
        INSERT INTO handle VALUES ('+15550102030');
        INSERT INTO chat_handle_join VALUES (1, 1);
        INSERT INTO message VALUES ('rich', \(now), '', X'\(typedBody("Dinner café 100% ready").map { String(format: "%02x", $0) }.joined())', 0, 1, 'iMessage');
        INSERT INTO message VALUES ('private', \(now), 'Dinner café 100% private', NULL, 0, 1, 'iMessage');
        INSERT INTO chat_message_join VALUES (1, 1), (2, 2);
        """
    #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
    let reader = MessagesReadAdapter(databaseURL: url)
    let chats = try await reader.listChats(limit: 10, selectedGUIDs: ["selected"])
    #expect(chats.count == 1)
    #expect(chats.first?.title == "+15550102030")
    let matches = try await reader.search(text: "café", after: Date(timeIntervalSinceReferenceDate: now - 60),
        before: Date(timeIntervalSinceReferenceDate: now + 60), limit: 10, permittedGUIDs: ["selected"])
    #expect(matches.map(\.guid) == ["rich"])
    #expect(matches.first?.contentStatus == "attributed_text")
    let literal = try await reader.search(text: "%", after: Date(timeIntervalSinceReferenceDate: now - 60),
        before: Date(timeIntervalSinceReferenceDate: now + 60), limit: 10, permittedGUIDs: ["selected"])
    #expect(literal.map(\.guid) == ["rich"])
    #expect(try await reader.search(text: "private", after: Date(timeIntervalSinceReferenceDate: now - 60),
        before: Date(timeIntervalSinceReferenceDate: now + 60), limit: 10, permittedGUIDs: ["selected"]).isEmpty)
}
