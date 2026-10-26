import Foundation
import Testing
@testable import RayPlacement
import RayPlacementCore

@MainActor
@Test func contextShelfStoresTextAndSuppressesRapidDuplicates() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("context-shelf-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("shelf.json")
    let store = ContextShelfStore(storageURL: url, loadPersisted: false)
    let source = ContextShelfSource.application(name: "Safari", bundleIdentifier: "com.apple.Safari")

    let firstID = store.addText(
        "A selected paragraph with enough detail to preview.",
        title: "Selection",
        kind: .selectedText,
        source: source
    )
    let duplicateID = store.addText(
        "A selected paragraph with enough detail to preview.",
        title: "Selection",
        kind: .selectedText,
        source: source
    )

    #expect(store.count == 1)
    #expect(firstID == duplicateID)
    #expect(store.selectedIDs.contains(firstID))
}

@MainActor
@Test func contextShelfPersistsOnlyPinnedItems() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("context-shelf-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("shelf.json")
    defer { try? FileManager.default.removeItem(at: url) }
    let source = ContextShelfSource.application(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit")
    let store = ContextShelfStore(storageURL: url, loadPersisted: false)
    let unpinnedID = store.addText("temporary", title: "Temporary", kind: .selectedText, source: source)
    let pinnedID = store.addText("keep me", title: "Pinned", kind: .plainText, source: source)
    #expect(store.items.contains { $0.id == pinnedID })
    store.togglePinned(id: pinnedID)
    #expect(store.items.first { $0.id == pinnedID }?.isPinned == true)

    let restored = ContextShelfStore(storageURL: url)
    #expect(!restored.items.contains { $0.id == unpinnedID })
    #expect(restored.items.contains { $0.id == pinnedID && $0.isPinned })
}

@MainActor
@Test func contextShelfTransientCapturesDoNotRewriteUnchangedPinnedSnapshot() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("context-shelf-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("shelf.json")
    let source = ContextShelfSource(type: .lima, capturedAt: Date())
    let store = ContextShelfStore(storageURL: url, loadPersisted: false)
    let pinnedID = store.addText("keep", title: "Pinned", kind: .plainText, source: source)
    store.togglePinned(id: pinnedID)

    let oldDate = Date(timeIntervalSince1970: 978_307_200)
    try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
    for index in 0..<10 {
        _ = store.addText("transient \(index)", title: "Capture", kind: .clipboard, source: source)
    }
    let afterCaptures = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    #expect(afterCaptures.timeIntervalSince1970 < 1_000_000_000)
    #expect(ContextShelfStore(storageURL: url).items.map(\.id) == [pinnedID])

    let secondID = store.addText("also keep", title: "Second", kind: .plainText, source: source)
    store.togglePinned(id: secondID)
    let afterPin = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    #expect(afterPin.timeIntervalSince1970 > 1_000_000_000)
    #expect(Set(ContextShelfStore(storageURL: url).items.map(\.id)) == Set([pinnedID, secondID]))
}

@MainActor
@Test func contextShelfEvictsOldestUnpinnedItemButKeepsPinnedItems() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("context-shelf-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("shelf.json")
    let store = ContextShelfStore(storageURL: url, loadPersisted: false)
    let source = ContextShelfSource(type: .lima, capturedAt: Date())
    let pinnedID = store.addText("pinned", title: "Pinned", kind: .plainText, source: source)
    store.togglePinned(id: pinnedID)

    for index in 0..<31 {
        _ = store.addText("item \(index)", title: "Item \(index)", kind: .plainText, source: source)
    }

    #expect(store.items.contains { $0.id == pinnedID })
    #expect(store.items.filter { !$0.isPinned }.count == 30)
}

@Test func contextShelfPayloadRoundTrips() throws {
    let payloads: [ContextShelfPayload] = [
        .text("hello"),
        .file(path: "/tmp/report.txt", displayName: "report.txt"),
        .note(noteID: UUID(), title: "Project Lima"),
        .terminal(command: "git status", output: "On branch main"),
        .dictation(transcript: "Remember this"),
        .mailReference(MailMessageReference(
            accountID: "synthetic-work", mailboxID: "inbox", messageID: 42,
            internetMessageID: "<fixture@example.invalid>",
            subject: "Fixture", sender: "Fixture Sender",
            receivedAt: Date(timeIntervalSince1970: 1_000),
            capturedAt: Date(timeIntervalSince1970: 2_000)
        ))
    ]

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    for payload in payloads {
        let data = try encoder.encode(payload)
        #expect(try decoder.decode(ContextShelfPayload.self, from: data) == payload)
    }
}


@MainActor
@Test func contextShelfFormatterAndRegistryExposeSharedActions() throws {
    let item = ContextShelfItem(
        id: UUID(),
        kind: .selectedText,
        title: "Selection",
        preview: "A paragraph",
        payload: .text("A paragraph"),
        source: .application(name: "Safari", bundleIdentifier: "com.apple.Safari"),
        createdAt: Date(),
        isPinned: false
    )

    #expect(ContextShelfMarkdownFormatter.format(item) == "> Selected from Safari\n\nA paragraph")
    #expect(ContextShelfMarkdownFormatter.plainText(item) == "A paragraph")
    let actions = ContextShelfActionRegistry(registerDefaults: true).actions(for: [item])
    #expect(actions.contains { $0.id == "copy" })
    #expect(actions.contains { $0.id == "copy-markdown" })
    #expect(actions.contains { $0.id == "append-quick-note" })
    #expect(actions.contains { $0.id == "send-to-note" })
}

@MainActor
@Test func shelfToNoteReportsOnlyCompletedScopedWrites() {
    let full = MarkdownNote(
        title: "Full",
        content: String(repeating: "x", count: NotesStore.maximumCharactersPerNote)
    )
    let notes = NotesStore(visualFixtures: [full])
    let source = ContextShelfSource(type: .lima, capturedAt: Date())
    let text = ContextShelfItem(
        id: UUID(), kind: .plainText, title: "Text", preview: "More text",
        payload: .text("More text"), source: source, createdAt: Date(), isPinned: false
    )
    #expect(!notes.appendShelfItems([text], to: full.id))
    #expect(notes.notes.first(where: { $0.id == full.id })?.content == full.content)
    #expect(notes.createNoteFromShelf([text]) != nil)

    let oversized = [0, 1].map { index in
        ContextShelfItem(
            id: UUID(), kind: .plainText, title: "Large \(index)", preview: "Large",
            payload: .text(String(repeating: "a", count: 100_001)),
            source: source, createdAt: Date(), isPinned: false
        )
    }
    let countBefore = notes.notes.count
    #expect(notes.createNoteFromShelf(oversized) == nil)
    #expect(notes.notes.count == countBefore)

    let mail = ContextShelfItem(
        id: UUID(), kind: .mailReference, title: "Mail", preview: "Metadata",
        payload: .mailReference(MailMessageReference(
            accountID: UUID().uuidString, mailboxID: "inbox", messageID: 7,
            internetMessageID: nil, subject: "Unselected mail", sender: "Sender",
            receivedAt: Date(), capturedAt: Date()
        )),
        source: source, createdAt: Date(), isPinned: false
    )
    #expect(notes.createNoteFromShelf([text, mail]) == nil)
    #expect(notes.notes.count == countBefore)
}

@MainActor
@Test func contextShelfUndoRestoresRemovedAndClearedItems() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("context-shelf-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = ContextShelfStore(storageURL: directory.appendingPathComponent("shelf.json"), loadPersisted: false)
    let source = ContextShelfSource(type: .lima, capturedAt: Date())
    let first = store.addText("first", title: "First", kind: .plainText, source: source)
    let second = store.addText("second", title: "Second", kind: .plainText, source: source)

    _ = store.remove(id: first)
    #expect(!store.items.contains { $0.id == first })
    #expect(store.lastRemoved.count == 1)
    store.undoLastRemove()
    #expect(store.items.contains { $0.id == first })
    #expect(store.lastRemoved.isEmpty)

    store.togglePinned(id: second)
    _ = store.clear()
    #expect(!store.items.contains { $0.id == first })
    #expect(store.items.contains { $0.id == second })
    store.undoClear()
    #expect(store.items.contains { $0.id == first })
    #expect(store.items.contains { $0.id == second && $0.isPinned == true })
}

@MainActor
@Test func contextShelfMailReferencesStayMetadataOnlyAndPurgeOnDisconnect() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mail-shelf-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("shelf.json")
    let store = ContextShelfStore(storageURL: url, loadPersisted: false)
    let source = ContextShelfSource(type: .lima, capturedAt: Date())
    let textID = store.addText("Keep this", title: "Other context", kind: .plainText, source: source)
    let reference = MailMessageReference(
        accountID: "synthetic-work", mailboxID: "inbox", messageID: 42,
        internetMessageID: "<fixture@example.invalid>",
        subject: "Review *draft*", sender: "Fixture Sender",
        receivedAt: Date(timeIntervalSince1970: 1_000),
        capturedAt: Date(timeIntervalSince1970: 2_000)
    )
    let firstID = ContextShelfIntegration.addMailReference(reference, store: store)
    let duplicateID = ContextShelfIntegration.addMailReference(reference, store: store)
    #expect(firstID == duplicateID)
    let item = try #require(store.items.first { $0.id == firstID })
    #expect(item.textValue == nil)
    #expect(ContextShelfMarkdownFormatter.format(item).contains("body not stored"))
    #expect(ContextShelfMarkdownFormatter.format(item).contains("\\*draft\\*"))
    #expect(ContextShelfExtensionContext.exportableItems(store.items).count == 1)
    store.togglePinned(id: firstID)
    let saved = try String(contentsOf: url, encoding: .utf8)
    #expect(!saved.contains("Keep this"))
    #expect(saved.contains("mailReference"))
    store.removeMailReferences()
    #expect(store.items.map(\.id) == [textID])
    let savedAfterDisconnect = try String(contentsOf: url, encoding: .utf8)
    #expect(!savedAfterDisconnect.contains("mailReference"))
}

@MainActor
@Test func contextShelfReloadScrubsRevokedAndMalformedMailReferences() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mail-shelf-reload-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("shelf.json")
    let store = ContextShelfStore(storageURL: url, loadPersisted: false)
    let ordinaryID = store.addText("Keep this", title: "Ordinary", kind: .plainText,
                                   source: ContextShelfSource(type: .lima, capturedAt: Date()))
    store.togglePinned(id: ordinaryID)

    func reference(account: String, subject: String) -> MailMessageReference {
        MailMessageReference(accountID: account, mailboxID: "inbox", messageID: 42,
                             internetMessageID: nil, subject: subject, sender: "Fixture Sender",
                             receivedAt: Date(timeIntervalSince1970: 1_000),
                             capturedAt: Date(timeIntervalSince1970: 2_000))
    }
    let permittedID = ContextShelfIntegration.addMailReference(
        reference(account: "synthetic-work", subject: "Permitted fixture"), store: store)
    store.togglePinned(id: permittedID)
    let revokedID = ContextShelfIntegration.addMailReference(
        reference(account: "synthetic-personal", subject: "Revoked fixture"), store: store)
    store.togglePinned(id: revokedID)
    let malformed = ContextShelfItem(
        id: UUID(), kind: .mailReference, title: "Malformed fixture", preview: "",
        payload: .text("Not a Mail payload"),
        source: ContextShelfSource(type: .lima, capturedAt: Date()),
        createdAt: Date(), isPinned: true
    )
    #expect(malformed.isMailReference)
    _ = store.add(malformed)

    let selected = MailCapabilityPolicy(readEnabled: true,
                                        selectedAccountIDs: ["synthetic-work"], allowsAIRead: false)
    let restored = ContextShelfStore(storageURL: url, mailPolicy: selected)
    #expect(Set(restored.items.map(\.id)) == [ordinaryID, permittedID])
    let savedAfterScopeChange = try String(contentsOf: url, encoding: .utf8)
    #expect(!savedAfterScopeChange.contains("Revoked fixture"))
    #expect(!savedAfterScopeChange.contains("Malformed fixture"))
    let disconnected = ContextShelfStore(storageURL: url, mailPolicy: .disabled)
    #expect(disconnected.items.map(\.id) == [ordinaryID])
    let savedAfterDisconnect = try String(contentsOf: url, encoding: .utf8)
    #expect(!savedAfterDisconnect.contains("mailReference"))
}

@MainActor
@Test func contextShelfMailPurgeClearsUndoBuffer() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mail-shelf-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ContextShelfStore(storageURL: directory.appendingPathComponent("shelf.json"), loadPersisted: false)
    let reference = MailMessageReference(
        accountID: "synthetic-work", mailboxID: "inbox", messageID: 9,
        internetMessageID: nil, subject: "Fixture", sender: "Sender",
        receivedAt: Date(timeIntervalSince1970: 1_000),
        capturedAt: Date(timeIntervalSince1970: 2_000)
    )
    let id = ContextShelfIntegration.addMailReference(reference, store: store)
    _ = store.remove(id: id)
    #expect(store.lastRemoved.count == 1)
    store.removeMailReferences(accountIDs: ["synthetic-work"])
    #expect(store.lastRemoved.isEmpty)
    store.undoLastRemove()
    #expect(store.items.isEmpty)
}

@MainActor
@Test func contextShelfExtensionEnvironmentUsesVersionedContract() throws {
    let environment = ContextShelfExtensionContext.environment()
    #expect(environment["LIMA_CONTEXT_SHELF_VERSION"] == "1")
    #expect(environment["LIMA_CONTEXT_SHELF_JSON"]?.contains("\"version\":1") == true)
    #expect(environment["LIMA_CONTEXT_SHELF_MARKDOWN"] != nil)
}

@MainActor
@Test func contextShelfExtensionEnvironmentBoundsLargePayloadsAndExcludesMail() throws {
    let source = ContextShelfSource(type: .lima, capturedAt: Date())
    let largeText = "\0" + String(repeating: "\"\n\\", count: 4_000)
    let ordinary = (0..<50).map { index in
        ContextShelfItem(
            id: UUID(), kind: .plainText, title: "Item \(index)", preview: "Large",
            payload: .text(largeText), source: source, createdAt: Date(), isPinned: true
        )
    }
    let mail = ContextShelfItem(
        id: UUID(), kind: .mailReference, title: "PRIVATE_MAIL_METADATA", preview: "Private",
        payload: .text("PRIVATE_MAIL_PAYLOAD"), source: source, createdAt: Date(), isPinned: true
    )
    let environment = ContextShelfExtensionContext.environment(
        items: [mail] + ordinary, selectedItems: Array(ordinary.prefix(30))
    )
    let json = try #require(environment["LIMA_CONTEXT_SHELF_JSON"])
    let markdown = try #require(environment["LIMA_CONTEXT_SHELF_MARKDOWN"])
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(ContextShelfExtensionContext.self, from: Data(json.utf8))

    #expect(json.utf8.count < 128_000)
    #expect(markdown.utf8.count <= 10_100)
    #expect(!json.contains("PRIVATE_MAIL_"))
    #expect(!markdown.contains("PRIVATE_MAIL_"))
    #expect(!json.contains("\0"))
    #expect(!markdown.contains("\0"))
    #expect(!decoded.items.isEmpty)
    #expect(decoded.items.count <= ContextShelfExtensionContext.maximumItems)
    #expect(decoded.omittedItemCount == ordinary.count - decoded.items.count)
    #expect(decoded.items.allSatisfy { $0.truncated })
    #expect(markdown.contains("additional Shelf item(s) omitted"))
}
