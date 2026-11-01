import Foundation

/// Saves only explicit user captures, after clipboard delivery. Images remain
/// under Screenshot History's retention and reviewed AI image-handoff policy.
@MainActor
enum QuickCaptureArchive {
    static func save(_ capture: ScreenshotCapturedImage, payload: QuickRegionCapturePayload,
                     shelf suppliedShelf: ContextShelfStore? = nil,
                     history suppliedHistory: ScreenshotHistoryStore? = nil) async throws -> String {
        let shelf = suppliedShelf ?? .shared
        var source = ContextShelfSource.application(name: capture.metadata.sourceApplication,
                                                    bundleIdentifier: capture.metadata.sourceBundleID)
        switch payload {
        case .text(let text):
            let id = shelf.addText(text, title: "Captured text", kind: .selectedText,
                                   source: source, isPinned: true)
            return "context:" + id.uuidString
        case .image:
            let history: ScreenshotHistoryStore
            if let suppliedHistory { history = suppliedHistory }
            else { history = try await Task.detached(priority: .utility) { try ScreenshotHistoryStore() }.value }
            let record = try await history.importImage(capture.pngData, format: .png, metadata: capture.metadata)
            source.commandID = "capture:" + record.id.uuidString
            let item = ContextShelfItem(id: UUID(), kind: .file, title: "Captured image",
                preview: "Screenshot · \(record.pixelWidth) × \(record.pixelHeight) · \(source.commandID!)",
                payload: .file(path: record.imageURL.path, displayName: "Captured image.png"),
                source: source, createdAt: record.capturedAt, isPinned: true)
            shelf.add(item)
            return "capture:" + record.id.uuidString
        }
    }
}
