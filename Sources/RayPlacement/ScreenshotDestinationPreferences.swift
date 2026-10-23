import Foundation

enum ScreenshotDestination: String, CaseIterable, Identifiable, Sendable {
    case clipboard
    case file
    case clipboardAndHistory
    case fileAndHistory
    case all

    var id: String { rawValue }
    var title: String {
        switch self {
        case .clipboard: "Clipboard only"
        case .file: "File only"
        case .clipboardAndHistory: "Clipboard + History"
        case .fileAndHistory: "File + History"
        case .all: "Clipboard + File + History"
        }
    }
    var includesClipboard: Bool { self == .clipboard || self == .clipboardAndHistory || self == .all }
    var includesFile: Bool { self == .file || self == .fileAndHistory || self == .all }
    var includesHistory: Bool { self == .clipboardAndHistory || self == .fileAndHistory || self == .all }
}

/// The file target is chosen in an NSOpenPanel, persisted as a security-scoped
/// bookmark, and resolved afresh for each user-initiated capture.
enum ScreenshotFileDestination {
    enum DestinationError: LocalizedError {
        case folderUnavailable
        case staleBookmark

        var errorDescription: String? {
            switch self {
            case .folderUnavailable: "Choose an available screenshot save folder in Screenshot Studio."
            case .staleBookmark: "The screenshot save folder moved or its access expired. Choose it again."
            }
        }
    }

    static func bookmark(for folder: URL) throws -> Data {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw DestinationError.folderUnavailable }
        return try folder.bookmarkData(options: [.withSecurityScope],
                                       includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func folderName(for bookmark: Data) -> String? {
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark,
                                    options: [.withSecurityScope], relativeTo: nil,
                                    bookmarkDataIsStale: &stale), !stale else { return nil }
        return folder.lastPathComponent
    }

    static func save(_ sourcePNG: Data, format: ScreenshotImageFormat,
                     bookmark: Data, capturedAt: Date = Date()) throws -> URL {
        var stale = false
        let folder = try URL(resolvingBookmarkData: bookmark,
                             options: [.withSecurityScope], relativeTo: nil,
                             bookmarkDataIsStale: &stale)
        guard !stale else { throw DestinationError.staleBookmark }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw DestinationError.folderUnavailable }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let output = try ScreenshotImageExport.data(
            sourcePNG, sourceFormat: .png, destinationFormat: format
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "Lima Screenshot \(formatter.string(from: capturedAt)) \(UUID().uuidString).\(format.fileExtension)"
        let url = folder.appendingPathComponent(name, isDirectory: false)
        try output.write(to: url, options: .atomic)
        return url
    }
}
