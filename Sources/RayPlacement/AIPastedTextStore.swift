import Foundation

/// Bound preview metadata by UTF-8 bytes, not extended grapheme clusters.
/// One user-perceived character can contain megabytes of combining scalars.
enum AITextPreview {
    static let maximumBytes = 240

    static func make(_ text: String) -> String {
        String(decoding: text.utf8.prefix(maximumBytes), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

/// Large clipboard text is stored outside conversation JSON. The attachment UUID
/// is the only disk reference; callers cannot supply an arbitrary file path.
enum AIPastedTextStore {
    static let maximumProviderBytes = 96_000

    static func save(_ text: String) throws -> AIAttachment {
        let id = UUID()
        let directory = storageDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = directory.appendingPathComponent("\(id.uuidString).txt")
        let data = Data(text.utf8)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let lines = text.utf8.reduce(into: 1) { count, byte in
            if byte == 10 { count += 1 }
        }
        return AIAttachment(
            id: id,
            kind: .pastedText,
            displayName: "Pasted Text",
            mimeType: "text/plain",
            byteCount: data.count,
            lineCount: lines,
            previewText: AITextPreview.make(text)
        )
    }

    static func providerText(for attachment: AIAttachment) throws -> String {
        guard attachment.kind == .pastedText else {
            throw failure("This is not a pasted-text attachment.")
        }
        let url = storageDirectory.appendingPathComponent("\(attachment.id.uuidString).txt")
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw failure("The pasted text is no longer available.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumProviderBytes + 1) ?? Data()
        let truncated = data.count > maximumProviderBytes
        var prefix = Data(data.prefix(maximumProviderBytes))
        while !prefix.isEmpty && String(data: prefix, encoding: .utf8) == nil {
            prefix.removeLast()
        }
        guard let text = String(data: prefix, encoding: .utf8) else {
            throw failure("The pasted text could not be read as UTF-8.")
        }
        return truncated ? text + "\n[Attachment content truncated by Lima.]" : text
    }

    private static var storageDirectory: URL {
        if let testURL = LimaTestEnvironment.storageURL(relativePath: "AI/attachments") {
            return testURL
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lima", isDirectory: true)
            .appendingPathComponent("AI", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "LimaAIPastedText", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// A large or log-like paste becomes a context attachment, not editor state.
enum AILargePastePolicy {
    static func shouldAttach(_ text: String) -> Bool {
        if text.utf8.count >= 8_000 || text.count >= 6_000 { return true }
        var lines = 0
        for character in text where character == "\n" {
            lines += 1
            if lines >= 50 { return true }
        }
        return false
    }
}
