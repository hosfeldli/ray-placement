import AppKit
import Foundation
import ImageIO
import RayPlacementCore
import SQLite3
import UniformTypeIdentifiers

enum ScreenshotImageFormat: String, Codable, CaseIterable, Sendable {
    case png
    case jpeg

    var fileExtension: String { self == .png ? "png" : "jpg" }
    var typeIdentifier: String { self == .png ? UTType.png.identifier : UTType.jpeg.identifier }
}

enum ScreenshotCategory: String, Codable, CaseIterable, Sendable {
    case browser
    case development
    case documents
    case charts
    case personal
    case uncategorized

    static func suggested(bundleID: String?, application: String?) -> Self {
        let source = (bundleID ?? application ?? "").lowercased()
        if ["safari", "chrome", "firefox", "arc", "edge"].contains(where: source.contains) { return .browser }
        if ["xcode", "terminal", "iterm", "visualstudiocode", "cursor"].contains(where: source.contains) { return .development }
        if ["numbers", "excel"].contains(where: source.contains) { return .charts }
        if ["pages", "preview", "word", "acrobat"].contains(where: source.contains) { return .documents }
        return .uncategorized
    }
}

enum ScreenshotCaptureKind: String, Codable, Sendable {
    case region
    case window
    case application
    case display
}

struct ScreenshotRecord: Identifiable, Sendable {
    let id: UUID
    let capturedAt: Date
    let imageURL: URL
    let thumbnailURL: URL?
    let format: ScreenshotImageFormat
    let captureKind: ScreenshotCaptureKind
    let sourceApplication: String?
    let sourceBundleID: String?
    let windowTitle: String?
    let category: ScreenshotCategory
    let tags: [String]
    let recognizedText: String?
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int
    let isPinned: Bool
}

struct ScreenshotMetadata: Sendable {
    let captureKind: ScreenshotCaptureKind
    let sourceApplication: String?
    let sourceBundleID: String?
    let windowTitle: String?

    init(captureKind: ScreenshotCaptureKind,
         sourceApplication: String? = nil,
         sourceBundleID: String? = nil,
         windowTitle: String? = nil) {
        self.captureKind = captureKind
        self.sourceApplication = sourceApplication
        self.sourceBundleID = sourceBundleID
        self.windowTitle = windowTitle
    }
}

struct ScreenshotRetentionPolicy: Sendable {
    var maximumBytes: Int64 = 2_000_000_000
    var maximumAge: TimeInterval = 90 * 24 * 60 * 60
}

enum ScreenshotHistoryError: Error, LocalizedError {
    case invalidImage
    case imageTooLarge
    case outsideRetention
    case invalidRetention
    case database(String)
    case notFound
    case invalidTag

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "The screenshot is not a valid PNG or JPEG image."
        case .imageTooLarge: return "The screenshot exceeds the library's image limit."
        case .outsideRetention: return "The screenshot is older than the library's retention setting."
        case .invalidRetention: return "The screenshot retention limits must be positive."
        case .database(let message): return "Screenshot History could not update its index: \(message)"
        case .notFound: return "The screenshot is no longer in history."
        case .invalidTag: return "Tags must be short, nonempty text."
        }
    }
}

/// Persistent, user-facing screenshots. This is deliberately unrelated to
/// BrowserScreenshotStore's short-lived, private AI viewport captures.
actor ScreenshotHistoryStore {
    static let didChange = Notification.Name("Lima.screenshotHistoryDidChange")

    let rootURL: URL
    private let imagesURL: URL
    private let thumbnailsURL: URL
    private let databaseURL: URL
    private var database: OpaquePointer?
    private let files = PrivateFileStore()
    private var retention: ScreenshotRetentionPolicy

    init(rootURL: URL? = nil, retention: ScreenshotRetentionPolicy = .init()) throws {
        let root = rootURL ?? ApplicationPaths.applicationSupport
            .appendingPathComponent("Screenshots", isDirectory: true)
        self.rootURL = root
        imagesURL = root.appendingPathComponent("Images", isDirectory: true)
        thumbnailsURL = root.appendingPathComponent("Thumbnails", isDirectory: true)
        databaseURL = root.appendingPathComponent("screenshot-index.sqlite")
        self.retention = retention
        try files.prepareDirectory(imagesURL)
        try files.prepareDirectory(thumbnailsURL)
        var opened: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &opened,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            if let opened { sqlite3_close(opened) }
            throw ScreenshotHistoryError.database(message)
        }
        database = opened
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
        try Self.execute(opened, """
            CREATE TABLE IF NOT EXISTS captures (
                id TEXT PRIMARY KEY,
                captured_at REAL NOT NULL,
                file_extension TEXT NOT NULL,
                capture_kind TEXT NOT NULL,
                source_application TEXT,
                source_bundle_id TEXT,
                window_title TEXT,
                category TEXT NOT NULL,
                tags_json TEXT NOT NULL,
                recognized_text TEXT,
                pixel_width INTEGER NOT NULL,
                pixel_height INTEGER NOT NULL,
                byte_count INTEGER NOT NULL,
                is_pinned INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS captures_recent ON captures(captured_at DESC);
            """)
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func setRetention(_ policy: ScreenshotRetentionPolicy) throws {
        guard policy.maximumBytes > 0, policy.maximumAge > 0 else {
            throw ScreenshotHistoryError.invalidRetention
        }
        retention = policy
        try enforceRetention()
    }

    func importImage(_ data: Data, format: ScreenshotImageFormat,
                     metadata: ScreenshotMetadata, at date: Date = Date(),
                     recognizeText: Bool = false) throws -> ScreenshotRecord {
        guard !data.isEmpty else { throw ScreenshotHistoryError.invalidImage }
        guard data.count <= 50_000_000, Int64(data.count) <= retention.maximumBytes else {
            throw ScreenshotHistoryError.imageTooLarge
        }
        guard date >= Date().addingTimeInterval(-retention.maximumAge) else {
            throw ScreenshotHistoryError.outsideRetention
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              type as String == format.typeIdentifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw ScreenshotHistoryError.invalidImage
        }
        guard Int64(width) * Int64(height) <= 80_000_000 else {
            throw ScreenshotHistoryError.imageTooLarge
        }
        guard CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw ScreenshotHistoryError.invalidImage
        }

        let id = UUID()
        let imageURL = imagesURL.appendingPathComponent(id.uuidString + "." + format.fileExtension)
        let thumbnailURL = thumbnailsURL.appendingPathComponent(id.uuidString + ".jpg")
        try files.write(data: data, to: imageURL, backupExisting: false)
        var savedThumbnail: URL?
        if let thumbnail = Self.makeThumbnail(from: source) {
            do {
                try files.write(data: thumbnail, to: thumbnailURL, backupExisting: false)
                savedThumbnail = thumbnailURL
            } catch {
                try? FileManager.default.removeItem(at: imageURL)
                throw error
            }
        }
        let category = ScreenshotCategory.suggested(
            bundleID: metadata.sourceBundleID, application: metadata.sourceApplication
        )
        let record = ScreenshotRecord(
            id: id, capturedAt: date, imageURL: imageURL, thumbnailURL: savedThumbnail,
            format: format, captureKind: metadata.captureKind,
            sourceApplication: metadata.sourceApplication,
            sourceBundleID: metadata.sourceBundleID, windowTitle: metadata.windowTitle,
            category: category, tags: [], recognizedText: nil,
            pixelWidth: width, pixelHeight: height, byteCount: data.count, isPinned: false
        )
        do {
            try insert(record)
            try enforceRetention()
        } catch {
            try? update("DELETE FROM captures WHERE id = ?", values: [id.uuidString])
            try? FileManager.default.removeItem(at: imageURL)
            if let savedThumbnail { try? FileManager.default.removeItem(at: savedThumbnail) }
            throw error
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        if recognizeText {
            // Vision work must never delay clipboard publication or focus restoration.
            Task.detached(priority: .utility) { [self] in
                guard let text = try? ScreenshotTextRecognizer.recognize(data) else { return }
                try? await setRecognizedText(text, for: id)
            }
        }
        return record
    }

    func setRecognizedText(_ text: String?, for id: UUID) throws {
        guard try record(id: id) != nil else { throw ScreenshotHistoryError.notFound }
        let bounded = text.map { String($0.prefix(20_000)) }
        let statement = try prepare("UPDATE captures SET recognized_text = ? WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        Self.bind(bounded, to: statement, at: 1)
        Self.bind(id.uuidString, to: statement, at: 2)
        try stepDone(statement)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func record(id: UUID) throws -> ScreenshotRecord? {
        try fetch(where: "WHERE id = ?", values: [id.uuidString], limit: 1).first
    }

    func recent(limit: Int = 100) throws -> [ScreenshotRecord] {
        try fetch(where: "", values: [], limit: limit)
    }

    func search(_ query: String, limit: Int = 100) throws -> [ScreenshotRecord] {
        let tokens = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return try recent(limit: limit) }
        let fields = ["source_application", "source_bundle_id", "window_title", "category", "tags_json", "recognized_text", "capture_kind"]
        let clause = "(" + fields.map { "LOWER(COALESCE(\($0), '')) LIKE ? ESCAPE '\\'" }.joined(separator: " OR ") + ")"
        let whereClause = "WHERE " + Array(repeating: clause, count: tokens.count).joined(separator: " AND ")
        let values = tokens.flatMap { token -> [String] in
            let escaped = token.lowercased().replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            return Array(repeating: "%" + escaped + "%", count: fields.count)
        }
        return try fetch(where: whereClause, values: values, limit: limit)
    }

    func setTags(_ tags: [String], for id: UUID) throws {
        let clean = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard clean.count <= 20,
              clean.allSatisfy({ !$0.isEmpty && $0.count <= 50 && !$0.contains("\0") }) else {
            throw ScreenshotHistoryError.invalidTag
        }
        guard try record(id: id) != nil else { throw ScreenshotHistoryError.notFound }
        let unique = Array(Set(clean)).sorted()
        let json = String(data: try JSONEncoder().encode(unique), encoding: .utf8)!
        try update("UPDATE captures SET tags_json = ? WHERE id = ?", values: [json, id.uuidString])
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func setPinned(_ pinned: Bool, for id: UUID) throws {
        guard try record(id: id) != nil else { throw ScreenshotHistoryError.notFound }
        try update("UPDATE captures SET is_pinned = ? WHERE id = ?",
                   values: [pinned ? "1" : "0", id.uuidString])
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func delete(id: UUID) throws {
        guard let record = try record(id: id) else { throw ScreenshotHistoryError.notFound }
        // Remove private bytes before removing the index row. If file deletion
        // fails, preserve the row so the user can retry instead of hiding data.
        if FileManager.default.fileExists(atPath: record.imageURL.path) {
            try FileManager.default.removeItem(at: record.imageURL)
        }
        if let thumbnailURL = record.thumbnailURL,
           FileManager.default.fileExists(atPath: thumbnailURL.path) {
            try FileManager.default.removeItem(at: thumbnailURL)
        }
        try update("DELETE FROM captures WHERE id = ?", values: [id.uuidString])
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func imageData(for id: UUID) throws -> (Data, ScreenshotImageFormat) {
        guard let record = try record(id: id) else { throw ScreenshotHistoryError.notFound }
        return (try Data(contentsOf: record.imageURL), record.format)
    }

    private func enforceRetention(now: Date = Date()) throws {
        let records = try recent(limit: 100_000)
        var bytes = records.reduce(Int64(0)) { $0 + Int64($1.byteCount) }
        let cutoff = now.addingTimeInterval(-retention.maximumAge)
        for record in records.reversed() where !record.isPinned {
            if record.capturedAt < cutoff || bytes > retention.maximumBytes {
                try delete(id: record.id)
                bytes -= Int64(record.byteCount)
            }
        }
    }

    private func insert(_ record: ScreenshotRecord) throws {
        let sql = """
            INSERT INTO captures (id, captured_at, file_extension, capture_kind,
                source_application, source_bundle_id, window_title, category, tags_json,
                recognized_text, pixel_width, pixel_height, byte_count, is_pinned)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        Self.bind(record.id.uuidString, to: statement, at: 1)
        sqlite3_bind_double(statement, 2, record.capturedAt.timeIntervalSince1970)
        Self.bind(record.format.fileExtension, to: statement, at: 3)
        Self.bind(record.captureKind.rawValue, to: statement, at: 4)
        Self.bind(record.sourceApplication, to: statement, at: 5)
        Self.bind(record.sourceBundleID, to: statement, at: 6)
        Self.bind(record.windowTitle, to: statement, at: 7)
        Self.bind(record.category.rawValue, to: statement, at: 8)
        Self.bind("[]", to: statement, at: 9)
        sqlite3_bind_null(statement, 10)
        sqlite3_bind_int(statement, 11, Int32(record.pixelWidth))
        sqlite3_bind_int(statement, 12, Int32(record.pixelHeight))
        sqlite3_bind_int64(statement, 13, Int64(record.byteCount))
        sqlite3_bind_int(statement, 14, 0)
        try stepDone(statement)
    }

    private func update(_ sql: String, values: [String]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() { Self.bind(value, to: statement, at: Int32(offset + 1)) }
        try stepDone(statement)
    }

    private func fetch(where condition: String, values: [String], limit: Int) throws -> [ScreenshotRecord] {
        let statement = try prepare("""
            SELECT id, captured_at, file_extension, capture_kind, source_application,
                   source_bundle_id, window_title, category, tags_json, recognized_text,
                   pixel_width, pixel_height, byte_count, is_pinned
            FROM captures \(condition) ORDER BY captured_at DESC LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() { Self.bind(value, to: statement, at: Int32(offset + 1)) }
        sqlite3_bind_int(statement, Int32(values.count + 1), Int32(max(1, min(limit, 100_000))))
        var result: [ScreenshotRecord] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw databaseError() }
            guard let idText = Self.text(statement, 0), let id = UUID(uuidString: idText),
                  let ext = Self.text(statement, 2),
                  let format = ScreenshotImageFormat(fileExtension: ext),
                  let captureKindText = Self.text(statement, 3),
                  let captureKind = ScreenshotCaptureKind(rawValue: captureKindText) else {
                throw ScreenshotHistoryError.database("Invalid screenshot index row")
            }
            let imageURL = imagesURL.appendingPathComponent(id.uuidString + "." + ext)
            let thumb = thumbnailsURL.appendingPathComponent(id.uuidString + ".jpg")
            let tagsData = (Self.text(statement, 8) ?? "[]").data(using: .utf8) ?? Data()
            let tags = (try? JSONDecoder().decode([String].self, from: tagsData)) ?? []
            result.append(ScreenshotRecord(
                id: id,
                capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                imageURL: imageURL,
                thumbnailURL: FileManager.default.fileExists(atPath: thumb.path) ? thumb : nil,
                format: format,
                captureKind: captureKind,
                sourceApplication: Self.text(statement, 4),
                sourceBundleID: Self.text(statement, 5),
                windowTitle: Self.text(statement, 6),
                category: ScreenshotCategory(rawValue: Self.text(statement, 7) ?? "") ?? .uncategorized,
                tags: tags,
                recognizedText: Self.text(statement, 9),
                pixelWidth: Int(sqlite3_column_int(statement, 10)),
                pixelHeight: Int(sqlite3_column_int(statement, 11)),
                byteCount: Int(sqlite3_column_int64(statement, 12)),
                isPinned: sqlite3_column_int(statement, 13) != 0
            ))
        }
        return result
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else { throw ScreenshotHistoryError.database("Database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw databaseError() }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func databaseError() -> ScreenshotHistoryError {
        .database(database.map { String(cString: sqlite3_errmsg($0)) } ?? "Database is closed")
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw ScreenshotHistoryError.database(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func bind(_ value: String?, to statement: OpaquePointer, at index: Int32) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: bytes)
    }

    private static func makeThumbnail(from source: CGImageSource) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 360
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

private extension ScreenshotImageFormat {
    init?(fileExtension: String) {
        switch fileExtension {
        case "png": self = .png
        case "jpg": self = .jpeg
        default: return nil
        }
    }
}

/// Publishes image bytes, not a path or text representation, to the pasteboard.
@MainActor
enum ScreenshotClipboard {
    static func copy(_ data: Data, format: ScreenshotImageFormat,
                     to pasteboard: NSPasteboard = .general) -> Bool {
        if format == .png { return copyPNG(data, to: pasteboard) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            png, UTType.png.identifier as CFString, 1, nil
        ) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return false }
        return copyPNG(png as Data, to: pasteboard)
    }

    static func copyPNG(_ data: Data, to pasteboard: NSPasteboard = .general) -> Bool {
        guard data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else { return false }
        pasteboard.clearContents()
        return pasteboard.setData(data, forType: .png)
    }
}
