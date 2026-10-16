import Foundation
import RayPlacementCore

struct BrowserScreenshotResult: Codable, Sendable {
    let tabID: UUID
    let fileURL: URL
    let mediaType: String
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int
    let authorityRevision: UInt64
    let readRevision: UInt64
}

/// Short-lived, process-local Browser captures. Never put image bytes in chat
/// state or provider tool-result text; callers receive a private file reference.
actor BrowserScreenshotStore {
    static let shared = BrowserScreenshotStore()

    private let directory: URL
    private var entries: [(tabID: UUID, url: URL)] = []
    private let maximumCaptures = 8

    init(directory: URL? = nil) {
        self.directory = directory ?? (LimaTestEnvironment.dataRoot ??
            FileManager.default.temporaryDirectory)
            .appendingPathComponent("Lima-Browser-Screenshots", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func save(_ data: Data, for tabID: UUID, width: Int, height: Int,
              authorityRevision: UInt64, readRevision: UInt64) throws -> BrowserScreenshotResult {
        guard !data.isEmpty, data.count <= 4_000_000,
              (1...1280).contains(width), (1...900).contains(height) else {
            throw BrowserRuntimeError.unsupportedAction
        }
        let url = directory.appendingPathComponent(UUID().uuidString + ".jpg")
        try PrivateFileStore().write(data: data, to: url, backupExisting: false)
        entries.append((tabID, url))
        while entries.count > maximumCaptures {
            let old = entries.removeFirst()
            try? FileManager.default.removeItem(at: old.url)
        }
        return BrowserScreenshotResult(
            tabID: tabID, fileURL: url, mediaType: "image/jpeg",
            pixelWidth: width, pixelHeight: height, byteCount: data.count,
            authorityRevision: authorityRevision, readRevision: readRevision
        )
    }

    /// Read pixels only for a capture still owned by this process and tab.
    /// Base64 is formed on this actor, never in SwiftUI or persisted chat state.
    func providerBase64(for capture: BrowserScreenshotResult) throws -> String {
        guard capture.mediaType == "image/jpeg",
              (1...4_000_000).contains(capture.byteCount),
              entries.contains(where: { $0.tabID == capture.tabID && $0.url == capture.fileURL }) else {
            throw BrowserRuntimeError.screenshotProtected
        }
        let data = try Data(contentsOf: capture.fileURL)
        guard data.count == capture.byteCount, data.count >= 3,
              data[0] == 0xFF, data[1] == 0xD8, data[2] == 0xFF else {
            throw BrowserRuntimeError.screenshotProtected
        }
        return data.base64EncodedString()
    }

    func remove(for tabID: UUID) {
        let removed = entries.filter { $0.tabID == tabID }
        entries.removeAll { $0.tabID == tabID }
        for entry in removed { try? FileManager.default.removeItem(at: entry.url) }
    }

    func clear() {
        for entry in entries { try? FileManager.default.removeItem(at: entry.url) }
        entries.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }
}
