import Foundation
import RayPlacementCore

/// Immutable, bounded, action-free search data. UI stores are read only while
/// constructing a snapshot, never from an actor search operation.
struct UniversalSearchDocument: Sendable {
    let id: String
    let kind: LimaSearchKind
    let title: String
    let subtitle: String
    let keywords: [String]
    let normalizedSearchText: String
    let scoreBonus: Double

    init(id: String, kind: LimaSearchKind, title: String, subtitle: String,
         keywords: [String] = [], searchText: String, scoreBonus: Double = 0) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.normalizedSearchText = searchText.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current
        )
        self.scoreBonus = scoreBonus
    }
}

struct UniversalSearchSnapshot: Sendable {
    let documents: [UniversalSearchDocument]
    static let empty = UniversalSearchSnapshot(documents: [])
}

/// Fuzzy matching lives off MainActor. Revisions prevent a cancelled older
/// query from replacing a newer catalog after asynchronous actor hops.
actor UniversalSearchEngine {
    private var snapshot: UniversalSearchSnapshot = .empty
    private var revision: UInt64 = 0

    func search(_ raw: String, revision incomingRevision: UInt64,
                snapshot incomingSnapshot: UniversalSearchSnapshot) -> [LimaSearchResult] {
        if incomingRevision > revision {
            snapshot = incomingSnapshot
            revision = incomingRevision
        }
        let (prefix, query) = UniversalSearchCoordinator.parse(raw)
        guard !query.isEmpty, !Task.isCancelled else { return [] }
        let normalizedQuery = query.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current
        )
        var grouped: [LimaSearchKind: SearchTopResults<LimaSearchResult>] = [:]
        let precedes: (LimaSearchResult, LimaSearchResult) -> Bool = {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.id < $1.id
        }
        for document in snapshot.documents {
            if Task.isCancelled { return [] }
            guard Self.includes(document.kind, for: prefix) else { continue }
            if (document.kind == .aiConversation || document.kind == .clipboard), query.count < 2 {
                continue
            }
            guard let score = FuzzyMatcher.scoreNormalized(
                document.normalizedSearchText, query: normalizedQuery
            ) else { continue }
            grouped[document.kind, default: SearchTopResults(limit: Self.limit(for: document.kind), precedes: precedes)].insert(LimaSearchResult(
                id: document.id, kind: document.kind, title: document.title,
                subtitle: document.subtitle, keywords: document.keywords,
                score: score + document.scoreBonus
            ))
        }
        let order: [LimaSearchKind] = [
            .note, .dictation, .aiConversation, .terminal, .command,
            .workspace, .context, .clipboard
        ]
        var results: [LimaSearchResult] = []
        for kind in order {
            guard let matches = grouped[kind] else { continue }
            results += matches.elements
        }
        return Array(results.sorted(by: precedes).prefix(24))
    }

    private static func includes(_ kind: LimaSearchKind, for prefix: String?) -> Bool {
        switch prefix {
        case nil: return true
        case "note": return kind == .note
        case "dictation": return kind == .dictation
        case "chat": return kind == .aiConversation
        case "terminal": return kind == .terminal
        case "command": return kind == .command
        case "workspace": return kind == .workspace
        case "context": return kind == .context
        case "clipboard": return kind == .clipboard
        default: return false
        }
    }

    private static func limit(for kind: LimaSearchKind) -> Int {
        switch kind {
        case .aiConversation, .context: return 12
        case .clipboard: return 8
        case .terminal: return 1
        default: return 20
        }
    }
}
