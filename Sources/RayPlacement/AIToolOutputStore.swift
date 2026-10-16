import Foundation

struct AIToolOutputReference: Codable, Hashable, Sendable {
    let id: UUID
    let byteCount: Int
    let lineCount: Int
    let preview: String
}

struct AIPreparedToolOutput: Sendable {
    let providerText: String
    let reference: AIToolOutputReference?
}

enum AIToolOutputScope: Sendable {
    case general
    case browser(tabID: UUID)
}

struct AIBrowserResultChunk: Codable, Sendable {
    let id: UUID
    let tabID: UUID
    let offset: Int
    let nextOffset: Int
    let byteCount: Int
    let eof: Bool
    let text: String
}

enum AIToolOutputReadError: LocalizedError {
    case unavailable
    case invalidRange
    case damaged

    var errorDescription: String? {
        switch self {
        case .unavailable: "This Browser result is no longer available. Read the page again."
        case .invalidRange: "The Browser result offset or byte limit is invalid."
        case .damaged: "The stored Browser result changed or is not valid UTF-8. Read the page again."
        }
    }
}

/// Keeps megabyte-scale terminal/browser output out of published conversation
/// metadata and provider continuations. Only bounded text crosses back to UI.
actor AIToolOutputStore {
    static let shared = AIToolOutputStore()
    static let inlineLimit = 96_000
    static let providerHeadBytes = 40_000
    static let providerTailBytes = 8_000
    private struct BrowserStoredReference {
        let reference: AIToolOutputReference
        let tabID: UUID
    }
    private var browserReferences: [UUID: BrowserStoredReference] = [:]
    private var browserReferenceOrder: [UUID] = []

    func prepare(_ output: String, scope: AIToolOutputScope = .general) throws -> AIPreparedToolOutput {
        let data = Data(output.utf8)
        guard data.count > Self.inlineLimit else {
            return AIPreparedToolOutput(providerText: output, reference: nil)
        }
        let id = UUID()
        let directory = Self.storageDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let filename: String
        if case .browser = scope {
            filename = "browser-\(id.uuidString).txt"
        } else {
            filename = "\(id.uuidString).txt"
        }
        let url = directory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        let lines = data.reduce(into: 1) { count, byte in if byte == 10 { count += 1 } }
        let reference = AIToolOutputReference(
            id: id, byteCount: data.count, lineCount: lines,
            preview: AITextPreview.make(output)
        )
        if case .browser(let tabID) = scope {
            browserReferences[id] = BrowserStoredReference(reference: reference, tabID: tabID)
            browserReferenceOrder.append(id)
            if browserReferenceOrder.count > 256 {
                removeBrowserReference(browserReferenceOrder.removeFirst())
            }
        }
        let head = Self.validUTF8Prefix(Data(data.prefix(Self.providerHeadBytes)))
        let tail = Self.validUTF8Suffix(Data(data.suffix(Self.providerTailBytes)))
        let retrievalHint: String
        if case .browser = scope {
            retrievalHint = " Use browser_result_read with result_id \(id.uuidString), starting at offset 0, to retrieve omitted bytes."
        } else {
            retrievalHint = ""
        }
        let providerText = """
        [Lima saved the complete tool output locally as \(id.uuidString). \(data.count) bytes, \(lines) lines. Only the beginning and end are included here.\(retrievalHint)]
        \(head)
        [\u{2026} middle of tool output omitted \u{2026}]
        \(tail)
        """
        return AIPreparedToolOutput(providerText: providerText, reference: reference)
    }

    func readBrowserChunk(id: UUID, offset: Int, maximumBytes: Int = 16_384) throws -> AIBrowserResultChunk {
        guard let stored = browserReferences[id],
              let url = Self.fileURL(for: stored.reference) else { throw AIToolOutputReadError.unavailable }
        let reference = stored.reference
        guard offset >= 0, offset <= reference.byteCount,
              (256...16_384).contains(maximumBytes) else { throw AIToolOutputReadError.invalidRange }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size == reference.byteCount else { throw AIToolOutputReadError.damaged }
        if offset == reference.byteCount {
            return AIBrowserResultChunk(id: id, tabID: stored.tabID, offset: offset, nextOffset: offset,
                                        byteCount: reference.byteCount, eof: true, text: "")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let amount = min(maximumBytes + 3, reference.byteCount - offset)
        let data = try handle.read(upToCount: amount) ?? Data()
        guard !data.isEmpty else { throw AIToolOutputReadError.damaged }
        var length = min(maximumBytes, data.count)
        while length > 0 && String(data: data.prefix(length), encoding: .utf8) == nil {
            length -= 1
        }
        guard length > 0,
              let text = String(data: data.prefix(length), encoding: .utf8) else {
            throw AIToolOutputReadError.damaged
        }
        let nextOffset = offset + length
        return AIBrowserResultChunk(id: id, tabID: stored.tabID, offset: offset, nextOffset: nextOffset,
                                    byteCount: reference.byteCount,
                                    eof: nextOffset == reference.byteCount, text: text)
    }

    func removeBrowserResults(for tabID: UUID) {
        let ids = browserReferenceOrder.filter { browserReferences[$0]?.tabID == tabID }
        for id in ids { removeBrowserReference(id) }
        browserReferenceOrder.removeAll { browserReferences[$0] == nil }
    }

    func clearBrowserResults(includeOrphans: Bool = false) {
        for id in browserReferenceOrder { removeBrowserReference(id) }
        browserReferenceOrder.removeAll()
        guard includeOrphans,
              let files = try? FileManager.default.contentsOfDirectory(
                at: Self.storageDirectory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ) else { return }
        // Browser blobs are ephemeral. Clear files left by an earlier process
        // without touching general conversation/tool blobs in the same folder.
        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix("browser-"), name.hasSuffix(".txt"),
                  UUID(uuidString: String(name.dropFirst(8).dropLast(4))) != nil,
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func removeBrowserReference(_ id: UUID) {
        guard let stored = browserReferences.removeValue(forKey: id),
              let url = Self.fileURL(for: stored.reference) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated static func fileURL(for reference: AIToolOutputReference) -> URL? {
        for name in ["browser-\(reference.id.uuidString).txt", "\(reference.id.uuidString).txt"] {
            let url = storageDirectory.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            return url
        }
        return nil
    }

    private nonisolated static var storageDirectory: URL {
        if let testURL = LimaTestEnvironment.storageURL(relativePath: "AI/blobs") {
            return testURL
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lima", isDirectory: true)
            .appendingPathComponent("AI", isDirectory: true)
            .appendingPathComponent("blobs", isDirectory: true)
    }

    private nonisolated static func validUTF8Prefix(_ data: Data) -> String {
        var data = data
        while !data.isEmpty && String(data: data, encoding: .utf8) == nil { data.removeLast() }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private nonisolated static func validUTF8Suffix(_ data: Data) -> String {
        var data = data
        while !data.isEmpty && String(data: data, encoding: .utf8) == nil { data.removeFirst() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
