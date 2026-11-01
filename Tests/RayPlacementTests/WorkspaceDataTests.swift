import AppKit
import Foundation
import RayPlacementCore
import Testing
@testable import RayPlacement

private func workspaceDataCall(_ name: String, _ args: [String: Any]) throws -> AIOutputItem {
    AIOutputItem(phase: .completed, apiType: "function_call", callID: UUID().uuidString,
        name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self))
}

@Test @MainActor func workspaceDataChunksUnicodeAndRejectsInvalidOffsets() throws {
    let text = String(repeating: "👩🏽‍💻é", count: 10000)
    let records = [LimaDataAITools.Record(reference: "context:test", source: "context", title: "Capture",
                                         text: text, createdAt: Date())]
    let first = LimaDataAITools.execute(try workspaceDataCall("lima_data_read", ["reference": "context:test", "offset": 0]), suppliedRecords: records)
    let data = try #require(first.output.data(using: .utf8))
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect((json["text"] as? String)?.count == 16000)
    #expect(json["next_offset"] as? Int == 16000)
    #expect(json["untrusted_content"] as? Bool == true)
    let second = LimaDataAITools.execute(try workspaceDataCall("lima_data_read", ["reference": "context:test", "offset": 16000]), suppliedRecords: records)
    #expect(!second.isError)
    for value: Any in [-1, true, 0.5, 21000] {
        #expect(LimaDataAITools.execute(try workspaceDataCall("lima_data_read", ["reference": "context:test", "offset": value]), suppliedRecords: records).isError)
    }
}

@Test @MainActor func workspaceDataDoesNotFlattenPrivateOrFileContext() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let shelf = ContextShelfStore(storageURL: url, loadPersisted: false)
    let source = ContextShelfSource.application(name: "Fixture", bundleIdentifier: nil)
    // An inconsistent record must fail closed even if its payload is plain text.
    shelf.add(ContextShelfItem(id: UUID(), kind: .mailReference, title: "Private mail",
        preview: "Secret", payload: .text("Secret"), source: source, createdAt: Date(), isPinned: false))
    shelf.add(ContextShelfItem(id: UUID(), kind: .file, title: "Saved file",
        preview: "A file", payload: .file(path: "/private/secret.txt", displayName: "secret.txt"),
        source: source, createdAt: Date(), isPinned: false))
    let records = LimaDataAITools.records(shelf: shelf, dictations: [], clipboard: [])
    #expect(records.count == 1)
    let record = try #require(records.first)
    #expect(!record.contentAvailable)
    let output = LimaDataAITools.execute(try workspaceDataCall("lima_data_read", ["reference": record.reference, "offset": 0]), suppliedRecords: records)
    #expect(!output.output.contains("/private/secret.txt"))
    #expect(!output.output.contains("Secret"))
    #expect(output.output.contains("native tool"))
}

@Test @MainActor func quickTextCaptureHasDurableSearchableReference() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("shelf.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let shelf = ContextShelfStore(storageURL: url, loadPersisted: false)
    let capture = ScreenshotCapturedImage(pngData: Data(), pixelWidth: 100, pixelHeight: 100,
        metadata: ScreenshotMetadata(captureKind: .region))
    let reference = try await QuickCaptureArchive.save(capture, payload: .text("Reservation release midnight"), shelf: shelf)
    let restored = ContextShelfStore(storageURL: url)
    #expect(restored.items.count == 1)
    #expect(restored.items.first?.isPinned == true)
    #expect(reference == "context:" + (try #require(restored.items.first)).id.uuidString)
    let output = LimaDataAITools.execute(try workspaceDataCall("lima_data_search", ["source": "context", "query": "midnight"]),
        suppliedRecords: LimaDataAITools.records(shelf: restored, dictations: [], clipboard: []))
    #expect(output.output.contains(reference))
}

@Test @MainActor func workspaceDataUsesRegisteredAccessPolicy() throws {
    for definition in LimaDataAITools.definitions {
        #expect(definition.responsePayload != nil)
        #expect(definition.actionCategory == .workspaceData)
        #expect(LimaAIToolRegistry.defaultEnabledToolIDs.contains(definition.id))
    }
}

@Test @MainActor func quickImageCapturePersistsPixelsAndNativeReference() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 6,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    let history = try ScreenshotHistoryStore(rootURL: root.appendingPathComponent("history"))
    let shelfURL = root.appendingPathComponent("context.json")
    let shelf = ContextShelfStore(storageURL: shelfURL, loadPersisted: false)
    let capture = ScreenshotCapturedImage(pngData: png, pixelWidth: 8, pixelHeight: 6,
        metadata: ScreenshotMetadata(captureKind: .region))
    let ref = try await QuickCaptureArchive.save(capture, payload: .image(png), shelf: shelf, history: history)
    let id = try #require(UUID(uuidString: String(ref.dropFirst("capture:".count))))
    #expect(try await history.imageData(for: id).0 == png)
    let restored = ContextShelfStore(storageURL: shelfURL)
    let records = LimaDataAITools.records(shelf: restored, dictations: [], clipboard: [])
    #expect(records.first?.captureReference == ref)
    #expect(records.first?.contentAvailable == false)
}

@Test func boundedSearchMatchesFullRankingForLargeCatalog() async {
    let docs = (0..<5000).map { i in
        UniversalSearchDocument(id: "note:\(i)", kind: .note, title: "Quartz \(i)",
            subtitle: "Fixture", searchText: i.isMultiple(of: 3) ? "quartz project" : "project quartz note",
            scoreBonus: Double(i % 47))
    }
    let scored: [(String, Double)] = docs.map { doc in
        let base = FuzzyMatcher.scoreNormalized(doc.normalizedSearchText, query: "quartz") ?? -Double.infinity
        return (doc.id, base + doc.scoreBonus)
    }
    let ordered = scored.sorted { a, b in
        if a.1 != b.1 { return a.1 > b.1 }
        return a.0 < b.0
    }
    let expected = ordered.prefix(20).map { $0.0 }
    let result = await UniversalSearchEngine().search("note: quartz", revision: 1,
        snapshot: UniversalSearchSnapshot(documents: docs))
    #expect(result.map(\.id) == expected)
}

@Test func boundedSearchPunctuationDoesNotMatchUnrelatedCommands() async {
    let item = LauncherItem(id: "builtin.fixture", title: "Ordinary command", subtitle: "",
        icon: .system("star"), keywords: [], action: .copyText("fixture"))
    let input = LauncherSearchDocumentInput(item: item, userAliases: [], extensionAliases: [], rankingBonus: 0)
    let result = await LauncherSearchEngine().search(LauncherSearchRequest(rawQuery: "?!", generation: 1),
        catalog: SearchCatalogSnapshot(revision: 1, inputs: [input]))
    #expect(result.hits.isEmpty)
}
