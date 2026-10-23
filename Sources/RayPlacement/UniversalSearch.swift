import Combine
import Foundation
import RayPlacementCore

struct LimaNotesSearchProvider: LimaSearchProvider {
    let notes: [MarkdownNote]
    var kind: LimaSearchKind { .note }

    func search(query: String) async -> [LimaSearchResult] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.compactMap { note in
            // Bound per-keystroke work even when a note contains a very large transcript.
            let haystack = "\(note.displayTitle) \(note.content.prefix(20_000)) \(note.tags.joined(separator: " "))"
            guard let score = FuzzyMatcher.score(haystack, query: clean) else { return nil }
            return LimaSearchResult(
                id: "note:\(note.id.uuidString)", kind: .note,
                title: note.displayTitle, subtitle: note.preview,
                keywords: note.tags, score: score
            )
        }.sorted { $0.score > $1.score }.prefix(20).map { $0 }
    }
}

struct LimaDictationSearchProvider: LimaSearchProvider {
    let conversations: [DictationConversation]
    var kind: LimaSearchKind { .dictation }

    func search(query: String) async -> [LimaSearchResult] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return conversations.compactMap { conversation in
            // Dictation transcripts can grow for hours. Search the most recent
            // bounded content so each root-search keystroke has predictable work.
            var remaining = 20_000
            var recentSegments: [String] = []
            for segment in conversation.segments.reversed() {
                guard remaining > 0 else { break }
                let text = String(segment.suffix(remaining))
                recentSegments.append(text)
                remaining -= text.count + 2
            }
            let recentTranscript = recentSegments.reversed().joined(separator: "\n\n")
            guard let score = FuzzyMatcher.score("\(conversation.title) \(recentTranscript)", query: clean) else { return nil }
            return LimaSearchResult(
                id: "dictation:\(conversation.id.uuidString)", kind: .dictation,
                title: conversation.title, subtitle: conversation.preview,
                score: score
            )
        }.sorted { $0.score > $1.score }.prefix(20).map { $0 }
    }
}

struct LimaAIConversationSearchProvider: LimaSearchProvider {
    let conversations: [AIConversation]
    var kind: LimaSearchKind { .aiConversation }

    func search(query: String) async -> [LimaSearchResult] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2 else { return [] }
        return conversations.compactMap { conversation in
            // Search recent visible turns, not unbounded transcripts, tool payloads,
            // attachment bytes, or provider-internal reasoning.
            let recentText = conversation.messages.suffix(4)
                .map { String($0.text.prefix(800)) }
                .joined(separator: " ")
            guard let score = FuzzyMatcher.score("\(conversation.title) \(recentText)", query: clean) else { return nil }
            return LimaSearchResult(
                id: "conversation:\(conversation.id.uuidString)", kind: .aiConversation,
                title: conversation.title,
                subtitle: "AI Chat · \(conversation.provider.title) · \(conversation.preview)",
                keywords: ["AI chat", conversation.provider.title], score: score
            )
        }.sorted { $0.score > $1.score }.prefix(12).map { $0 }
    }
}

struct LimaTerminalSearchProvider: LimaSearchProvider {
    var kind: LimaSearchKind { .terminal }

    func search(query: String) async -> [LimaSearchResult] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let score = FuzzyMatcher.score("terminal shell command line developer", query: clean) else { return [] }
        return [
            LimaSearchResult(
                id: "terminal",
                kind: .terminal,
                title: "Terminal",
                subtitle: "Open Lima’s single shell",
                keywords: ["shell", "command line", "developer"],
                score: score
            )
        ]
    }
}


struct LimaWorkflowSearchProvider: LimaSearchProvider {
    let workflows: [WorkflowDefinition]
    var kind: LimaSearchKind { .command }

    func search(query: String) async -> [LimaSearchResult] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return workflows.compactMap { workflow in
            let haystack = "\(workflow.name) \(workflow.steps.map(\.commandID).joined(separator: " "))"
            guard let score = FuzzyMatcher.score(haystack, query: clean) else { return nil }
            return LimaSearchResult(
                id: "workflow:\(workflow.id.uuidString)", kind: .command,
                title: workflow.name, subtitle: "Workflow · \(workflow.steps.count) step\(workflow.steps.count == 1 ? "" : "s")",
                keywords: workflow.steps.map(\.commandID), score: score
            )
        }.sorted { $0.score > $1.score }.prefix(20).map { $0 }
    }
}

struct LimaWorkspaceSearchProvider: LimaSearchProvider {
    let profiles: [WorkspaceProfile]
    var kind: LimaSearchKind { .workspace }

    func search(query: String) async -> [LimaSearchResult] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return profiles.compactMap { profile in
            guard let score = FuzzyMatcher.score(profile.name, query: clean) else { return nil }
            return LimaSearchResult(
                id: "workspace:\(profile.id.uuidString)", kind: .workspace,
                title: profile.name, subtitle: "Workspace",
                keywords: ["workspace", "project"], score: score + (profile.favorite ? 15 : 0)
            )
        }.sorted { $0.score > $1.score }.prefix(20).map { $0 }
    }
}

struct LimaClipboardSearchProvider: LimaSearchProvider {
    struct Entry: Sendable {
        let id: UUID
        let text: String
        let pinned: Bool
    }
    let entries: [Entry]
    var kind: LimaSearchKind { .clipboard }

    func search(query: String) async -> [LimaSearchResult] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2 else { return [] }
        return entries.compactMap { entry in
            let preview = String(entry.text.prefix(8_000))
            guard let score = FuzzyMatcher.score(preview, query: clean) else { return nil }
            return LimaSearchResult(
                id: "clipboard:\(entry.id.uuidString)", kind: .clipboard,
                title: String(preview.replacingOccurrences(of: "\\n", with: " ").prefix(100)),
                subtitle: "Clipboard history · Copy",
                score: score + (entry.pinned ? 15 : 0)
            )
        }.sorted { $0.score > $1.score }.prefix(8).map { $0 }
    }
}

struct LimaContextSearchProvider: LimaSearchProvider {
    struct Entry: Sendable {
        let id: UUID
        let title: String
        let preview: String
        let text: String
        let kind: String
        let pinned: Bool
    }

    let entries: [Entry]
    var kind: LimaSearchKind { .context }

    func search(query: String) async -> [LimaSearchResult] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.compactMap { entry in
            let haystack = "\(entry.title) \(entry.preview) \(entry.text)"
            guard let score = FuzzyMatcher.score(haystack, query: clean) else { return nil }
            return LimaSearchResult(
                id: "context:\(entry.id.uuidString)", kind: .context,
                title: entry.title, subtitle: "Context Shelf · \(entry.pinned ? "Pinned " : "")\(entry.kind)",
                keywords: ["context", "shelf", entry.kind], score: score + (entry.pinned ? 15 : 0)
            )
        }.sorted { $0.score > $1.score }.prefix(12).map { $0 }
    }
}

@MainActor
final class UniversalSearchCoordinator {
    static let shared = UniversalSearchCoordinator()

    private let engine = UniversalSearchEngine()
    private var snapshot: UniversalSearchSnapshot = .empty
    private var snapshotRevision: UInt64 = 0
    private var snapshotDirty = true
    private var observers: [AnyCancellable] = []
    private var screenshotLibrary: ScreenshotHistoryStore?

    private init() {
        // Collection-specific events invalidate the catalog. Search remains
        // completely idle while the launcher is hidden; the next visible
        // query takes one bounded snapshot and updates the background actor.
        observers = [
            NotesStore.shared.$notes.sink { [weak self] _ in self?.snapshotDirty = true },
            DictationConversationStore.shared.$conversations.sink { [weak self] _ in self?.snapshotDirty = true },
            AIConversationStore.shared.$conversationSummaries.sink { [weak self] _ in self?.snapshotDirty = true },
            WorkflowStore.shared.$workflows.sink { [weak self] _ in self?.snapshotDirty = true },
            WorkspaceProfileStore.shared.$profiles.sink { [weak self] _ in self?.snapshotDirty = true },
            ContextShelfStore.shared.$items.sink { [weak self] _ in self?.snapshotDirty = true },
            ClipboardHistoryService.shared.$entries.sink { [weak self] _ in self?.snapshotDirty = true },
            SettingsStore.shared.$clipboardEnabled.sink { [weak self] _ in self?.snapshotDirty = true }
        ]
    }

    func search(_ rawQuery: String) async -> [LimaSearchResult] {
        if snapshotDirty {
            snapshot = buildSnapshot()
            snapshotRevision &+= 1
            snapshotDirty = false
        }
        let indexed = await engine.search(rawQuery, revision: snapshotRevision, snapshot: snapshot)
        let captures = await screenshotResults(for: rawQuery)
        return Array((indexed + captures).sorted { $0.score > $1.score }.prefix(24))
    }

    func screenshotImageData(for id: UUID) async throws -> (Data, ScreenshotImageFormat) {
        guard let library = try await openScreenshotLibrary() else {
            throw ScreenshotHistoryError.notFound
        }
        return try await library.imageData(for: id)
    }

    private func openScreenshotLibrary() async throws -> ScreenshotHistoryStore? {
        if let screenshotLibrary { return screenshotLibrary }
        let root = ApplicationPaths.applicationSupport
            .appendingPathComponent("Screenshots", isDirectory: true)
        let index = root.appendingPathComponent("screenshot-index.sqlite")
        guard FileManager.default.fileExists(atPath: index.path) else { return nil }
        let opened = try await Task.detached(priority: .utility) {
            try ScreenshotHistoryStore(rootURL: root)
        }.value
        screenshotLibrary = opened
        return opened
    }

    private func screenshotResults(for rawQuery: String) async -> [LimaSearchResult] {
        let parsed = Self.parse(rawQuery)
        guard parsed.prefix == nil || parsed.prefix == "screenshot" else { return [] }
        let raw = parsed.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        let lookup: String
        if parsed.prefix == "screenshot" || lower == "screenshot" || lower == "screenshots" {
            lookup = parsed.prefix == "screenshot" ? raw : ""
        } else if lower.hasPrefix("screenshot ") {
            lookup = String(raw.dropFirst("screenshot ".count))
        } else if lower.hasPrefix("screenshots ") {
            lookup = String(raw.dropFirst("screenshots ".count))
        } else {
            lookup = raw
        }
        guard raw.count >= 2 else { return [] }
        do {
            guard let library = try await openScreenshotLibrary() else { return [] }
            let records = try await library.search(lookup, limit: 12)
            return records.map { record in
                let title = record.windowTitle ?? record.sourceApplication ?? "Screenshot"
                let metadata = "\(title) \(record.sourceApplication ?? "") \(record.category.rawValue) \(record.tags.joined(separator: " "))"
                let score = lookup.isEmpty ? 0 : (FuzzyMatcher.score(metadata, query: lookup) ?? 500)
                return LimaSearchResult(
                    id: "screenshot:\(record.id.uuidString)", kind: .screenshot,
                    title: title,
                    subtitle: "Screenshot · \(record.sourceApplication ?? record.captureKind.rawValue.capitalized) · \(record.capturedAt.formatted(date: .abbreviated, time: .shortened))",
                    keywords: ["screenshot", record.category.rawValue] + record.tags,
                    score: score + (record.isPinned ? 15 : 0)
                )
            }
        } catch {
            return []
        }
    }

    private func buildSnapshot() -> UniversalSearchSnapshot {
        var documents: [UniversalSearchDocument] = []
        for note in NotesStore.shared.notes {
            documents.append(UniversalSearchDocument(
                id: "note:\(note.id.uuidString)", kind: .note,
                title: note.displayTitle, subtitle: note.preview,
                keywords: note.tags,
                searchText: "\(note.displayTitle) \(note.content.prefix(20_000)) \(note.tags.joined(separator: " "))"
            ))
        }
        for conversation in DictationConversationStore.shared.conversations {
            var remaining = 20_000
            var segments: [String] = []
            for segment in conversation.segments.reversed() {
                guard remaining > 0 else { break }
                let text = String(segment.suffix(remaining))
                segments.append(text)
                remaining -= text.count + 2
            }
            let recentText = segments.reversed().joined(separator: "\n\n")
            documents.append(UniversalSearchDocument(
                id: "dictation:\(conversation.id.uuidString)", kind: .dictation,
                title: conversation.title, subtitle: conversation.preview,
                searchText: "\(conversation.title) \(recentText)"
            ))
        }
        for conversation in AIConversationStore.shared.conversations {
            let recentText = conversation.messages.suffix(4)
                .map { String($0.text.prefix(800)) }
                .joined(separator: " ")
            documents.append(UniversalSearchDocument(
                id: "conversation:\(conversation.id.uuidString)", kind: .aiConversation,
                title: conversation.title,
                subtitle: "AI Chat · \(conversation.provider.title) · \(conversation.preview)",
                keywords: ["AI chat", conversation.provider.title],
                searchText: "\(conversation.title) \(recentText)"
            ))
        }
        documents.append(UniversalSearchDocument(
            id: "terminal", kind: .terminal, title: "Terminal",
            subtitle: "Open Lima’s single shell",
            keywords: ["shell", "command line", "developer"],
            searchText: "terminal shell command line developer"
        ))
        for workflow in WorkflowStore.shared.workflows {
            let commands = workflow.steps.map(\.commandID)
            documents.append(UniversalSearchDocument(
                id: "workflow:\(workflow.id.uuidString)", kind: .command,
                title: workflow.name,
                subtitle: "Workflow · \(workflow.steps.count) step\(workflow.steps.count == 1 ? "" : "s")",
                keywords: commands,
                searchText: "\(workflow.name) \(commands.joined(separator: " "))"
            ))
        }
        for profile in WorkspaceProfileStore.shared.profiles {
            documents.append(UniversalSearchDocument(
                id: "workspace:\(profile.id.uuidString)", kind: .workspace,
                title: profile.name, subtitle: "Workspace",
                keywords: ["workspace", "project"], searchText: profile.name,
                scoreBonus: profile.favorite ? 15 : 0
            ))
        }
        for item in ContextShelfStore.shared.items {
            let body = String((item.textValue ?? "").prefix(8_000))
            documents.append(UniversalSearchDocument(
                id: "context:\(item.id.uuidString)", kind: .context,
                title: item.title,
                subtitle: "Context Shelf · \(item.isPinned ? "Pinned " : "")\(item.kind.rawValue)",
                keywords: ["context", "shelf", item.kind.rawValue],
                searchText: "\(item.title) \(item.preview) \(body)",
                scoreBonus: item.isPinned ? 15 : 0
            ))
        }
        if SettingsStore.shared.clipboardEnabled {
            for entry in ClipboardHistoryService.shared.entries {
                let preview = String(entry.text.prefix(8_000))
                documents.append(UniversalSearchDocument(
                    id: "clipboard:\(entry.id.uuidString)", kind: .clipboard,
                    title: String(preview.replacingOccurrences(of: "\n", with: " ").prefix(100)),
                    subtitle: "Clipboard history · Copy", searchText: preview,
                    scoreBonus: entry.pinned ? 15 : 0
                ))
            }
        }
        return UniversalSearchSnapshot(documents: documents)
    }

    nonisolated static func parse(_ rawQuery: String) -> (prefix: String?, query: String) {
        let clean = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let known = ["note", "notes", "dictation", "terminal", "workflow", "command", "commands", "workspace", "workspaces", "context", "shelf", "chat", "chats", "ai", "app", "apps", "clipboard", "file", "files", "screenshot", "screenshots"]
        for prefix in known where clean.lowercased().hasPrefix(prefix + ":") {
            let canonical = ["notes": "note", "commands": "command", "workspaces": "workspace", "shelf": "context", "chats": "chat", "ai": "chat", "apps": "app", "files": "file", "screenshots": "screenshot"][prefix] ?? prefix
            return (canonical, String(clean.dropFirst(prefix.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (nil, clean)
    }
}
