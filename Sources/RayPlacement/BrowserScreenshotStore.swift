import Foundation
import RayPlacementCore

struct BrowserScreenshotResult: Codable, Sendable {
    let captureID: UUID
    let capturedAt: Date
    let tabID: UUID
    let fileURL: URL
    let mediaType: String
    let pixelWidth: Int
    let pixelHeight: Int
    /// CSS-point size of the captured viewport, used to map image pixels to WebKit.
    let pointWidth: Double
    let pointHeight: Double
    let byteCount: Int
    let authorityRevision: UInt64
    let readRevision: UInt64
    var redactionCount: Int = 0
}

/// Short-lived, process-local Browser captures. Never put image bytes in chat
/// state or provider tool-result text; callers receive a private file reference.
actor BrowserScreenshotStore {
    static let shared = BrowserScreenshotStore()

    private let directory: URL
    private var entries: [BrowserScreenshotResult] = []
    private let maximumCaptures = 8

    init(directory: URL? = nil) {
        self.directory = directory ?? (LimaTestEnvironment.dataRoot ??
            FileManager.default.temporaryDirectory)
            .appendingPathComponent("Lima-Browser-Screenshots", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func save(_ data: Data, for tabID: UUID, width: Int, height: Int,
              pointWidth: Double, pointHeight: Double,
              authorityRevision: UInt64, readRevision: UInt64,
              redactionCount: Int = 0) throws -> BrowserScreenshotResult {
        guard !data.isEmpty, data.count <= 4_000_000,
              (1...1280).contains(width), (1...900).contains(height),
              pointWidth.isFinite, pointHeight.isFinite,
              pointWidth > 0, pointHeight > 0,
              (0...240).contains(redactionCount) else {
            throw BrowserRuntimeError.unsupportedAction
        }
        let captureID = UUID()
        let url = directory.appendingPathComponent(captureID.uuidString + ".jpg")
        try PrivateFileStore().write(data: data, to: url, backupExisting: false)
        let capture = BrowserScreenshotResult(
            captureID: captureID, capturedAt: Date(),
            tabID: tabID, fileURL: url, mediaType: "image/jpeg",
            pixelWidth: width, pixelHeight: height,
            pointWidth: pointWidth, pointHeight: pointHeight,
            byteCount: data.count, authorityRevision: authorityRevision,
            readRevision: readRevision, redactionCount: redactionCount
        )
        entries.append(capture)
        while entries.count > maximumCaptures {
            let old = entries.removeFirst()
            try? FileManager.default.removeItem(at: old.fileURL)
        }
        return capture
    }

    func capture(id: UUID) -> BrowserScreenshotResult? {
        entries.first { $0.captureID == id }
    }

    /// Read pixels only for a capture still owned by this process and tab.
    /// Base64 is formed on this actor, never in SwiftUI or persisted chat state.
    func providerBase64(for capture: BrowserScreenshotResult) throws -> String {
        guard capture.mediaType == "image/jpeg",
              (1...4_000_000).contains(capture.byteCount),
              entries.contains(where: { $0.captureID == capture.captureID &&
                  $0.tabID == capture.tabID && $0.fileURL == capture.fileURL }) else {
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
        for entry in removed { try? FileManager.default.removeItem(at: entry.fileURL) }
    }

    func clear() {
        for entry in entries { try? FileManager.default.removeItem(at: entry.fileURL) }
        entries.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }
}
