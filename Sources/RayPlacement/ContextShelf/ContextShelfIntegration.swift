import AppKit
import Foundation
import RayPlacementCore
import UniformTypeIdentifiers

@MainActor
enum ContextShelfIntegration {
    static let itemUTType = UTType(exportedAs: "com.rayplacement.context-shelf-item")

    static func addClipboard(_ text: String, sourceApplication: String? = nil) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let source = ContextShelfSource(
            type: .clipboard,
            applicationName: sourceApplication,
            bundleIdentifier: nil,
            commandID: nil,
            extensionID: nil,
            noteID: nil,
            capturedAt: Date()
        )
        _ = ContextShelfStore.shared.addText(clean, title: "Clipboard", kind: .clipboard, source: source)
    }

    static func addURL(_ url: URL, sourceApplication: String? = nil) {
        let source = ContextShelfSource(
            type: .application,
            applicationName: sourceApplication,
            bundleIdentifier: nil,
            commandID: nil,
            extensionID: nil,
            noteID: nil,
            capturedAt: Date()
        )
        _ = ContextShelfStore.shared.addText(
            url.absoluteString,
            title: url.host ?? url.absoluteString,
            kind: .plainText,
            source: source
        )
    }

    static func addFile(_ url: URL, sourceApplication: String? = nil) {
        let source = ContextShelfSource(
            type: .file,
            applicationName: sourceApplication ?? "Finder",
            bundleIdentifier: nil,
            commandID: nil,
            extensionID: nil,
            noteID: nil,
            capturedAt: Date()
        )
        let item = ContextShelfItem(
            id: UUID(), kind: .file, title: url.lastPathComponent,
            preview: url.path, payload: .file(path: url.path, displayName: url.lastPathComponent),
            source: source, createdAt: Date(), isPinned: false
        )
        _ = ContextShelfStore.shared.add(item)
    }

    static func addTerminalOutput(_ output: String, command: String? = nil, sessionName: String? = nil) {
        let clean = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let source = ContextShelfSource(
            type: .terminal, applicationName: "Lima Terminal", bundleIdentifier: Bundle.main.bundleIdentifier,
            commandID: command, extensionID: nil, noteID: nil, capturedAt: Date()
        )
        let title = command.map { "Terminal · \($0)" } ?? "Terminal · \(sessionName ?? "Output")"
        let item = ContextShelfItem(
            id: UUID(), kind: .terminalOutput, title: title,
            preview: ContextShelfTextFormatting.preview(for: clean),
            payload: .terminal(command: command, output: clean), source: source,
            createdAt: Date(), isPinned: false
        )
        _ = ContextShelfStore.shared.add(item)
    }

    static func addDictation(_ transcript: String, conversationID: UUID? = nil) {
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let source = ContextShelfSource(
            type: .dictation, applicationName: "Lima Dictation", bundleIdentifier: Bundle.main.bundleIdentifier,
            commandID: nil, extensionID: nil, noteID: conversationID, capturedAt: Date()
        )
        let item = ContextShelfItem(
            id: UUID(), kind: .dictation, title: "Dictation",
            preview: ContextShelfTextFormatting.preview(for: clean), payload: .dictation(transcript: clean),
            source: source, createdAt: Date(), isPinned: false
        )
        _ = ContextShelfStore.shared.add(item)
    }

    static func addExtensionOutput(_ output: String, extensionID: String, commandID: String, title: String) {
        let clean = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let source = ContextShelfSource(
            type: .extensionOutput, applicationName: nil, bundleIdentifier: Bundle.main.bundleIdentifier,
            commandID: commandID, extensionID: extensionID, noteID: nil, capturedAt: Date()
        )
        let item = ContextShelfItem(
            id: UUID(), kind: .extensionOutput, title: title,
            preview: ContextShelfTextFormatting.preview(for: clean), payload: .text(clean),
            source: source, createdAt: Date(), isPinned: false
        )
        _ = ContextShelfStore.shared.add(item)
    }

    /// Store only a previously authorized Mail reference. The caller must use
    /// MailCapabilityService.referenceForShelf immediately before this handoff.
    @discardableResult
    static func addMailReference(_ reference: MailMessageReference,
                                 store: ContextShelfStore? = nil) -> UUID {
        let now = Date()
        let source = ContextShelfSource.application(
            name: "Apple Mail", bundleIdentifier: "com.apple.mail", capturedAt: now
        )
        let item = ContextShelfItem(
            id: UUID(), kind: .mailReference,
            title: reference.subject.isEmpty ? "(No subject)" : reference.subject,
            preview: "From: \(reference.sender) · \(reference.receivedAt.formatted(date: .abbreviated, time: .shortened))",
            payload: .mailReference(reference), source: source,
            createdAt: now, isPinned: false
        )
        return (store ?? .shared).add(item)
    }
}

/// Versioned environment contract exposed to approved extensions that request
/// the `contextShelf` capability. Shell extensions receive this JSON in
/// `LIMA_CONTEXT_SHELF_JSON`; they can also use the plain-text field for simple
/// tools without a JSON parser.
struct ContextShelfExtensionContext: Codable, Sendable {
    static let version = 1
    static let maximumItems = 20
    static let maximumMarkdownBytes = 10_000
    static let maximumItemMarkdownBytes = 3_000
    let version: Int
    let items: [Item]
    let omittedItemCount: Int

    struct Item: Codable, Sendable {
        let id: UUID
        let kind: String
        let title: String
        let markdown: String
        let source: String
        let createdAt: Date
        let pinned: Bool
        let truncated: Bool
    }

    @MainActor
    static func current() -> ContextShelfExtensionContext {
        boundedContext(from: ContextShelfStore.shared.items)
    }

    /// Legacy contextShelf extensions receive bounded text and file items,
    /// never Mail references. Mail access needs a separate scoped resolver.
    @MainActor
    static func exportableItems(_ items: [ContextShelfItem]) -> [Item] {
        boundedContext(from: items).items
    }

    @MainActor
    private static func boundedContext(from items: [ContextShelfItem]) -> ContextShelfExtensionContext {
        var exported: [Item] = []
        var remainingBytes = maximumMarkdownBytes
        var omitted = 0
        for item in items where !item.isMailReference {
            guard exported.count < maximumItems, remainingBytes >= 128 else {
                omitted += 1
                continue
            }
            let budget = min(maximumItemMarkdownBytes, remainingBytes)
            let markdown = boundedMarkdown(ContextShelfMarkdownFormatter.format(item), maximumBytes: budget)
            let title = prefixUTF8(item.title, maximumBytes: 128)
            let source = prefixUTF8(ContextShelfMarkdownFormatter.previewSource(for: item), maximumBytes: 128)
            exported.append(Item(
                id: item.id, kind: item.kind.rawValue, title: title.text,
                markdown: markdown.text, source: source.text,
                createdAt: item.createdAt, pinned: item.isPinned,
                truncated: markdown.truncated || title.truncated || source.truncated
            ))
            remainingBytes -= markdown.text.utf8.count
        }
        return ContextShelfExtensionContext(version: version, items: exported, omittedItemCount: omitted)
    }

    private static func boundedMarkdown(_ markdown: String, maximumBytes: Int) -> (text: String, truncated: Bool) {
        let full = prefixUTF8(markdown, maximumBytes: maximumBytes)
        guard full.truncated else { return full }
        let suffix = "\n\n[truncated]"
        let head = prefixUTF8(markdown, maximumBytes: maximumBytes - suffix.utf8.count)
        return (head.text + suffix, true)
    }

    private static func prefixUTF8(_ text: String, maximumBytes: Int) -> (text: String, truncated: Bool) {
        var result = ""
        var usedBytes = 0
        for character in text {
            // Process environment values cannot contain a NUL byte.
            let safeCharacter = character == "\0" ? "�" : String(character)
            let byteCount = safeCharacter.utf8.count
            guard usedBytes + byteCount <= maximumBytes else { return (result, true) }
            result.append(contentsOf: safeCharacter)
            usedBytes += byteCount
        }
        return (result, false)
    }

    @MainActor
    static func environment() -> [String: String] {
        let store = ContextShelfStore.shared
        return environment(items: store.items, selectedItems: store.selectedItems)
    }

    @MainActor
    static func environment(items: [ContextShelfItem], selectedItems: [ContextShelfItem]) -> [String: String] {
        let context = boundedContext(from: items)
        let selectedContext = selectedItems.isEmpty ? context : boundedContext(from: selectedItems)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(context)) ?? Data("{\"version\":1,\"items\":[],\"omittedItemCount\":0}".utf8)
        var markdown = selectedContext.items.map(\.markdown).joined(separator: "\n\n")
        if selectedContext.omittedItemCount > 0 {
            if !markdown.isEmpty { markdown += "\n\n" }
            markdown += "[\(selectedContext.omittedItemCount) additional Shelf item(s) omitted]"
        }
        return [
            "LIMA_CONTEXT_SHELF_VERSION": String(version),
            "LIMA_CONTEXT_SHELF_JSON": String(decoding: data, as: UTF8.self),
            "LIMA_CONTEXT_SHELF_MARKDOWN": markdown
        ]
    }
}
