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

    func search(_ rawQuery: String) async -> [LimaSearchResult] {
        let (prefix, query) = Self.parse(rawQuery)
        let notes = LimaNotesSearchProvider(notes: NotesStore.shared.notes)
        let dictation = LimaDictationSearchProvider(conversations: DictationConversationStore.shared.conversations)
        let aiConversations = LimaAIConversationSearchProvider(conversations: AIConversationStore.shared.conversations)
        let terminal = LimaTerminalSearchProvider()
        let workflows = LimaWorkflowSearchProvider(workflows: WorkflowStore.shared.workflows)
        let workspaces = LimaWorkspaceSearchProvider(profiles: WorkspaceProfileStore.shared.profiles)
        let context = LimaContextSearchProvider(entries: ContextShelfStore.shared.items.map { item in
            .init(id: item.id, title: item.title, preview: item.preview,
                  text: String((item.textValue ?? "").prefix(8_000)),
                  kind: item.kind.rawValue, pinned: item.isPinned)
        })
        let clipboard = LimaClipboardSearchProvider(entries: SettingsStore.shared.clipboardEnabled
            ? ClipboardHistoryService.shared.entries.map { .init(id: $0.id, text: $0.text, pinned: $0.pinned) }
            : [])
        let providers: [any LimaSearchProvider]
        switch prefix {
        case "note": providers = [notes]
        case "dictation": providers = [dictation]
        case "chat": providers = [aiConversations]
        case "terminal": providers = [terminal]
        case "workflow", "command": providers = [workflows]
        case "workspace": providers = [workspaces]
        case "context": providers = [context]
        case "app", "file": providers = []
        case "clipboard": providers = [clipboard]
        default: providers = [notes, dictation, aiConversations, terminal, workflows, workspaces, context, clipboard]
        }
        let results = await withTaskGroup(
            of: (Int, [LimaSearchResult]).self,
            returning: [LimaSearchResult].self
        ) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask {
                    guard !Task.isCancelled else { return (index, []) }
                    return (index, await provider.search(query: query))
                }
            }

            var batches = Array(repeating: [LimaSearchResult](), count: providers.count)
            for await (index, batch) in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return []
                }
                batches[index] = batch
            }
            return batches.flatMap { $0 }
        }
        guard !Task.isCancelled else { return [] }
        return results.sorted { $0.score > $1.score }.prefix(24).map { $0 }
    }

    static func parse(_ rawQuery: String) -> (prefix: String?, query: String) {
        let clean = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let known = ["note", "notes", "dictation", "terminal", "workflow", "command", "commands", "workspace", "workspaces", "context", "shelf", "chat", "chats", "ai", "app", "apps", "clipboard", "file", "files"]
        for prefix in known where clean.lowercased().hasPrefix(prefix + ":") {
            let canonical = ["notes": "note", "commands": "command", "workspaces": "workspace", "shelf": "context", "chats": "chat", "ai": "chat", "apps": "app", "files": "file"][prefix] ?? prefix
            return (canonical, String(clean.dropFirst(prefix.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (nil, clean)
    }
}
