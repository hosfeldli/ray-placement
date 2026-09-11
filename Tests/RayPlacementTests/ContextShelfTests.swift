import Foundation
import Testing
@testable import RayPlacement

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
        .dictation(transcript: "Remember this")
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
@Test func contextShelfExtensionEnvironmentUsesVersionedContract() throws {
    let environment = ContextShelfExtensionContext.environment()
    #expect(environment["LIMA_CONTEXT_SHELF_VERSION"] == "1")
    #expect(environment["LIMA_CONTEXT_SHELF_JSON"]?.contains("\"version\":1") == true)
    #expect(environment["LIMA_CONTEXT_SHELF_MARKDOWN"] != nil)
}
