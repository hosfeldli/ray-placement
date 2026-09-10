import Foundation
import RayPlacementCore

struct LimaNotesSearchProvider: LimaSearchProvider {
    let notes: [MarkdownNote]
    var kind: LimaSearchKind { .note }

    func search(query: String) async -> [LimaSearchResult] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.compactMap { note in
            let haystack = "\(note.displayTitle) \(note.content) \(note.tags.joined(separator: " "))"
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
            guard let score = FuzzyMatcher.score("\(conversation.title) \(conversation.transcript)", query: clean) else { return nil }
            return LimaSearchResult(
                id: "dictation:\(conversation.id.uuidString)", kind: .dictation,
                title: conversation.title, subtitle: conversation.preview,
                score: score
            )
        }.sorted { $0.score > $1.score }.prefix(20).map { $0 }
    }
}

struct LimaTerminalSearchProvider: LimaSearchProvider {
    let sessions: [TerminalSession]
    var kind: LimaSearchKind { .terminal }

    func search(query: String) async -> [LimaSearchResult] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessions.compactMap { session in
            guard let score = FuzzyMatcher.score("\(session.name) \(session.cwd) \(session.history.joined(separator: " "))", query: clean) else { return nil }
            return LimaSearchResult(
                id: "terminal:\(session.id.uuidString)", kind: .terminal,
                title: session.name, subtitle: session.cwd,
                keywords: session.history, score: score
            )
        }.sorted { $0.score > $1.score }.prefix(20).map { $0 }
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

@MainActor
final class UniversalSearchCoordinator {
    static let shared = UniversalSearchCoordinator()

    func search(_ rawQuery: String) async -> [LimaSearchResult] {
        let (prefix, query) = Self.parse(rawQuery)
        let notes = LimaNotesSearchProvider(notes: NotesStore.shared.notes)
        let dictation = LimaDictationSearchProvider(conversations: DictationConversationStore.shared.conversations)
        let terminal = LimaTerminalSearchProvider(sessions: TerminalSessionStore.shared.sessions)
        let workflows = LimaWorkflowSearchProvider(workflows: WorkflowStore.shared.workflows)
        let providers: [any LimaSearchProvider]
        switch prefix {
        case "note": providers = [notes]
        case "dictation": providers = [dictation]
        case "terminal": providers = [terminal]
        case "workflow", "command": providers = [workflows]
        default: providers = [notes, dictation, terminal, workflows]
        }
        var results: [LimaSearchResult] = []
        for provider in providers {
            results += await provider.search(query: query)
        }
        return results.sorted { $0.score > $1.score }.prefix(24).map { $0 }
    }

    static func parse(_ rawQuery: String) -> (prefix: String?, query: String) {
        let clean = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let known = ["note", "dictation", "terminal", "workflow", "command"]
        for prefix in known where clean.lowercased().hasPrefix(prefix + ":") {
            return (prefix, String(clean.dropFirst(prefix.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (nil, clean)
    }
}
