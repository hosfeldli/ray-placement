import Foundation
import RayPlacementCore

/// Captured on the MainActor without normalization. Actions, icons, and
/// closures never cross into the actor; only immutable searchable values do.
struct LauncherSearchDocumentInput: Sendable {
    let id: String
    let title: String
    let subtitle: String
    let searchText: String
    let keywords: [String]
    let userAliases: [String]
    let extensionAliases: [String]
    let rankingBonus: Double

    init(item: LauncherItem, searchText: String? = nil,
         userAliases: [String], extensionAliases: [String], rankingBonus: Double) {
        id = item.id
        title = item.title
        subtitle = item.subtitle
        self.searchText = searchText ?? item.searchableText
        keywords = item.keywords
        self.userAliases = userAliases
        self.extensionAliases = extensionAliases
        self.rankingBonus = rankingBonus
    }
}

/// Normalized exactly once per catalog revision, inside LauncherSearchEngine.
private struct LauncherSearchDocument {
    let id: String
    let title: String
    let normalizedTitle: String
    let normalizedSearchText: String
    let normalizedFields: [String]
    let normalizedUserAliases: Set<String>
    let normalizedExtensionAliases: Set<String>
    let normalizedKeywords: Set<String>
    let rankingBonus: Double

    init(_ input: LauncherSearchDocumentInput) {
        id = input.id
        title = input.title
        normalizedTitle = Self.normalize(input.title)
        normalizedSearchText = Self.normalize(input.searchText)
        normalizedFields = ([input.title, input.subtitle] + input.keywords).map(Self.normalize)
        normalizedUserAliases = Set(input.userAliases.map { $0.lowercased() })
        normalizedExtensionAliases = Set(input.extensionAliases.map { $0.lowercased() })
        normalizedKeywords = Set(input.keywords.map { $0.lowercased() })
        rankingBonus = input.rankingBonus
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

struct SearchCatalogSnapshot: Sendable {
    let revision: UInt64
    let inputs: [LauncherSearchDocumentInput]
    static let empty = SearchCatalogSnapshot(revision: 0, inputs: [])
}

struct LauncherSearchRequest: Sendable {
    let rawQuery: String
    let generation: Int
}

struct LauncherSearchHit: Sendable {
    let id: String
    let title: String
    let score: Double
    let aliasKind: LimaAliasKind
}

struct LauncherSearchResponse: Sendable {
    let generation: Int
    let hits: [LauncherSearchHit]
}

actor LauncherSearchEngine {
    private var catalogRevision: UInt64 = 0
    private var documents: [LauncherSearchDocument] = []

    func search(_ request: LauncherSearchRequest,
                catalog incomingCatalog: SearchCatalogSnapshot) -> LauncherSearchResponse {
        if incomingCatalog.revision > catalogRevision {
            documents = incomingCatalog.inputs.map(LauncherSearchDocument.init)
            catalogRevision = incomingCatalog.revision
        }
        let (prefix, query) = UniversalSearchCoordinator.parse(request.rawQuery)
        guard !query.isEmpty, !Task.isCancelled else {
            return LauncherSearchResponse(generation: request.generation, hits: [])
        }
        let normalizedQuery = query.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current
        )
        let aliasQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tokens = normalizedQuery.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        var ranked: [LauncherSearchHit] = []
        for document in documents {
            if Task.isCancelled { break }
            guard Self.includes(document.id, for: prefix) else { continue }
            if document.id.hasPrefix("clipboard."), prefix == nil, query.count < 2 { continue }
            let titleScore = FuzzyMatcher.scoreNormalized(document.normalizedTitle, query: normalizedQuery)
            let wholeScore = FuzzyMatcher.scoreNormalized(document.normalizedSearchText, query: normalizedQuery)
            let tokenScores = tokens.map { token in
                document.normalizedFields.compactMap {
                    FuzzyMatcher.scoreNormalized($0, query: token)
                }.max() ?? -.infinity
            }
            let baseScore: Double
            if tokenScores.allSatisfy(\.isFinite) {
                let titleIntent: Double = document.normalizedTitle == normalizedQuery ? 100_000
                    : (document.normalizedTitle.hasPrefix(normalizedQuery) ? 24 : 0)
                baseScore = max(titleScore ?? -.infinity, wholeScore ?? -.infinity,
                                14_000 + tokenScores.reduce(0, +) + titleIntent)
            } else {
                baseScore = max(titleScore ?? -.infinity, wholeScore ?? -.infinity)
            }
            guard baseScore.isFinite else { continue }
            let provenance: (LimaAliasKind, Double)
            if document.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == aliasQuery {
                provenance = (.exactTitle, 100_000)
            } else if document.normalizedUserAliases.contains(aliasQuery) {
                provenance = (.userAlias, 1_200)
            } else if document.id.hasPrefix("extension."), document.normalizedExtensionAliases.contains(aliasQuery) {
                provenance = (.extensionAlias, 900)
            } else if (document.id.hasPrefix("builtin.") || document.id.hasPrefix("context.")),
                      document.normalizedKeywords.contains(aliasQuery) {
                provenance = (.builtInAlias, 600)
            } else {
                provenance = (.exactTitle, 0)
            }
            ranked.append(LauncherSearchHit(
                id: document.id, title: document.title,
                score: baseScore + provenance.1 + document.rankingBonus,
                aliasKind: provenance.0
            ))
        }
        ranked.sort { first, second in
            if first.score == second.score {
                return first.title.localizedStandardCompare(second.title) == .orderedAscending
            }
            return first.score > second.score
        }
        return LauncherSearchResponse(generation: request.generation,
                                      hits: Array(ranked.prefix(24)))
    }

    private static func includes(_ id: String, for prefix: String?) -> Bool {
        switch prefix {
        case nil: return true
        case "app": return id.hasPrefix("app.")
        case "command": return id.hasPrefix("builtin.") || id.hasPrefix("extension.") || id.hasPrefix("macro.")
        case "clipboard": return id.hasPrefix("clipboard.")
        default: return false
        }
    }
}
