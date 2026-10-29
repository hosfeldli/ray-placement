import AppKit
import CryptoKit
import Foundation

/// A reviewed, revision-aware bridge from local files or web references into
/// managed Note Markdown. It never fetches a URL or reads a path supplied only
/// by Note content.
@MainActor
enum AINotesAttachment {
    nonisolated private static let maximumFileBytes = 20_000_000
    nonisolated private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "tif", "tiff", "heic", "webp", "bmp"
    ]
    nonisolated private static let documentExtensions: Set<String> = [
        "pdf", "txt", "md", "csv", "json", "xml", "edi", "log", "rtf",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "html", "htm"
    ]

    static func execute(_ call: AIOutputItem, store: NotesStore) async -> LimaAIToolExecution {
        guard let raw = call.arguments?.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              Set(arguments.keys).subtracting(["screenshot_id"]) == Set([
                "note_id", "expected_content_sha256", "source_kind", "source_path",
                "source_url", "label", "expected_modified_at", "expected_size_bytes"
              ]),
              let rawID = arguments["note_id"] as? String,
              let noteID = UUID(uuidString: rawID),
              let expectedHash = arguments["expected_content_sha256"] as? String,
              isSHA256(expectedHash),
              let kind = arguments["source_kind"] as? String,
              ["image", "file", "reference", "screenshot"].contains(kind),
              let label = arguments["label"] as? String,
              validLabel(label) else {
            return failure("Attach to Note needs a Note ID, its current read_note hash, a plain label, and exact source details.")
        }

        guard isCurrent(noteID, expectedHash: expectedHash, store: store) else {
            return failure("The Note changed or disappeared. Read it again before attaching.", next: "read_note")
        }

        var importedReference: String?
        let markdown: String
        if kind == "reference" {
            guard arguments["screenshot_id"] == nil || arguments["screenshot_id"] is NSNull,
                  arguments["source_path"] is NSNull,
                  arguments["expected_modified_at"] is NSNull,
                  arguments["expected_size_bytes"] is NSNull,
                  let rawURL = arguments["source_url"] as? String,
                  validWebURL(rawURL) else {
                return failure("A source reference needs one absolute HTTP or HTTPS URL and no local file path.")
            }
            markdown = "[\(label)](\(rawURL))"
        } else if kind == "screenshot" {
            guard arguments["source_path"] is NSNull,
                  arguments["source_url"] is NSNull,
                  arguments["expected_modified_at"] is NSNull,
                  arguments["expected_size_bytes"] is NSNull,
                  let rawCaptureID = arguments["screenshot_id"] as? String,
                  let captureID = UUID(uuidString: rawCaptureID) else {
                return failure("A saved screenshot attachment needs its exact screenshot_info ID and no file path or URL.")
            }
            do {
                let (data, format) = try await NativeCapabilityRouter.shared.screenshotImageForNote(id: captureID)
                guard isCurrent(noteID, expectedHash: expectedHash, store: store) else {
                    return failure("The Note changed while the screenshot was read. Read it again before attaching.", next: "read_note")
                }
                guard let reference = MarkdownNoteAssetStore.importManagedData(
                    data, pathExtension: format.fileExtension, isImage: true
                ) else {
                    return failure("Lima could not import the saved screenshot into managed Note assets.")
                }
                importedReference = reference
                markdown = "![\(label)](\(reference))"
            } catch {
                return failure(error.localizedDescription, next: "screenshot_info")
            }
        } else {
            guard arguments["screenshot_id"] == nil || arguments["screenshot_id"] is NSNull,
                  arguments["source_url"] is NSNull,
                  let path = arguments["source_path"] as? String,
                  let modifiedAt = arguments["expected_modified_at"] as? String,
                  let size = arguments["expected_size_bytes"] as? Int else {
                return failure("A local attachment needs its absolute path, modified_at, and size_bytes from file_metadata.")
            }
            do {
                let data = try await Task.detached(priority: .utility) {
                    try readReviewedFile(
                        at: path, expectedModifiedAt: modifiedAt,
                        expectedSize: size, isImage: kind == "image"
                    )
                }.value
                // The file read happens off the main actor. The Note may have
                // changed during that await, so recheck before creating an asset.
                guard isCurrent(noteID, expectedHash: expectedHash, store: store) else {
                    return failure("The Note changed while the file was read. Read it again before attaching.", next: "read_note")
                }
                let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
                guard let reference = MarkdownNoteAssetStore.importManagedData(
                    data, pathExtension: ext, isImage: kind == "image"
                ) else {
                    return failure("Lima could not import that bounded attachment into managed Note assets.")
                }
                importedReference = reference
                markdown = kind == "image"
                    ? "![\(label)](\(reference))"
                    : "[\(label)](\(reference))"
            } catch {
                return failure(error.localizedDescription, next: "file_metadata")
            }
        }

        do {
            let count = try store.appendAIReportMarkdown(
                to: noteID, expectedContentSHA256: expectedHash, content: markdown
            )
            guard let note = store.notes.first(where: { $0.id == noteID }) else {
                return failure("The edited Note is no longer available.", next: "read_note")
            }
            let hash = SHA256.hash(data: Data(note.content.utf8))
                .map { String(format: "%02x", $0) }.joined()
            return .json([
                "completed": true,
                "result": "attached",
                "note_id": noteID.uuidString,
                "source_kind": kind,
                "asset_reference": importedReference as Any? ?? NSNull(),
                "total_characters": count,
                "content_sha256": hash,
                "undo": "previous content is available in the Note revision history",
                "autosave": "scheduled"
            ])
        } catch {
            if let importedReference {
                MarkdownNoteAssetStore.discardUnlinkedImport(importedReference)
            }
            return failure(error.localizedDescription, next: "read_note")
        }
    }

    nonisolated private static func readReviewedFile(
        at path: String, expectedModifiedAt: String,
        expectedSize: Int, isImage: Bool
    ) throws -> Data {
        guard path.hasPrefix("/"), expectedSize > 0, expectedSize <= maximumFileBytes else {
            throw attachmentError("Attach to Note needs a regular file of 1 to 20 MB at an absolute path.")
        }
        let requested = URL(fileURLWithPath: path).standardizedFileURL
        let resolved = requested.resolvingSymlinksInPath()
        let ext = requested.pathExtension.lowercased()
        let allowed = isImage ? imageExtensions : documentExtensions
        guard allowed.contains(ext),
              !hiddenComponent(in: requested), !hiddenComponent(in: resolved),
              !LimaAIToolRegistry.isSensitivePath(requested),
              !LimaAIToolRegistry.isSensitivePath(resolved) else {
            throw attachmentError("This file type or location is not available for Note attachments.")
        }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey
        ]
        let before = try requested.resourceValues(forKeys: keys)
        guard before.isRegularFile == true, before.isSymbolicLink != true,
              before.fileSize == expectedSize,
              let beforeDate = before.contentModificationDate,
              modifiedAtString(beforeDate) == expectedModifiedAt else {
            throw attachmentError("The file changed since file_metadata. Inspect it again before attaching.")
        }
        let handle = try FileHandle(forReadingFrom: requested)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
        let extra = try handle.read(upToCount: 1) ?? Data()
        let after = try requested.resourceValues(forKeys: keys)
        guard data.count == expectedSize, data.count <= maximumFileBytes,
              extra.isEmpty, after.isRegularFile == true,
              after.isSymbolicLink != true,
              after.fileSize == expectedSize,
              let afterDate = after.contentModificationDate,
              modifiedAtString(afterDate) == expectedModifiedAt else {
            throw attachmentError("The file changed during import. Inspect it again before attaching.")
        }
        return data
    }

    nonisolated private static func modifiedAtString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    nonisolated private static func hiddenComponent(in url: URL) -> Bool {
        url.pathComponents.dropFirst().contains { $0.hasPrefix(".") }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func validLabel(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == trimmed && (1...120).contains(value.count)
            && value.rangeOfCharacter(from: .controlCharacters) == nil
            && !value.contains("[") && !value.contains("]")
            && !value.contains("\\")
    }

    private static func validWebURL(_ value: String) -> Bool {
        guard value.count <= 2_048,
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !value.contains("("), !value.contains(")"),
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        return true
    }

    private static func isCurrent(_ id: UUID, expectedHash: String, store: NotesStore) -> Bool {
        guard let note = store.notes.first(where: { $0.id == id }) else { return false }
        let currentHash = SHA256.hash(data: Data(note.content.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return currentHash == expectedHash
    }

    nonisolated private static func attachmentError(_ message: String) -> NSError {
        NSError(domain: "LimaNotesAttachment", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }

    private static func failure(_ message: String, next: String? = nil) -> LimaAIToolExecution {
        .json([
            "completed": false,
            "error": message,
            "retry_safe": true,
            "next_action": next as Any? ?? NSNull()
        ], isError: true)
    }
}
