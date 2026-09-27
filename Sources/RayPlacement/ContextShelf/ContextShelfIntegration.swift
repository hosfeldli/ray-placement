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
}

/// Versioned environment contract exposed to approved extensions that request
/// the `contextShelf` capability. Shell extensions receive this JSON in
/// `LIMA_CONTEXT_SHELF_JSON`; they can also use the plain-text field for simple
/// tools without a JSON parser.
struct ContextShelfExtensionContext: Codable, Sendable {
    static let version = 1
    let version: Int
    let items: [Item]

    struct Item: Codable, Sendable {
        let id: UUID
        let kind: String
        let title: String
        let markdown: String
        let source: String
        let createdAt: Date
        let pinned: Bool
    }

    @MainActor
    static func current() -> ContextShelfExtensionContext {
        ContextShelfExtensionContext(
            version: version,
            items: ContextShelfStore.shared.items.map {
                Item(id: $0.id, kind: $0.kind.rawValue, title: $0.title,
                     markdown: ContextShelfMarkdownFormatter.format($0),
                     source: ContextShelfMarkdownFormatter.previewSource(for: $0),
                     createdAt: $0.createdAt, pinned: $0.isPinned)
            }
        )
    }

    @MainActor
    static func environment() -> [String: String] {
        let context = current()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(context)) ?? Data("{\"version\":1,\"items\":[]}".utf8)
        let selected = ContextShelfStore.shared.selectedItems
        return [
            "LIMA_CONTEXT_SHELF_VERSION": String(version),
            "LIMA_CONTEXT_SHELF_JSON": String(decoding: data, as: UTF8.self),
            "LIMA_CONTEXT_SHELF_MARKDOWN": ContextShelfMarkdownFormatter.format(selected.isEmpty ? ContextShelfStore.shared.items : selected)
        ]
    }
}
