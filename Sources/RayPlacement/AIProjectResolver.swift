import Foundation

enum AIWorkIntent: String, Codable, Sendable {
    case informational
    case transient
    case durableExistingWork
    case durableNewWork

    static func classify(_ request: String) -> Self {
        let value = request.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let durableVerbs = ["build", "create", "implement", "fix", "add", "update",
                            "modify", "refactor", "clone", "develop", "make", "repair"]
        let politePrefixes = ["please ", "can you ", "could you ", "would you ",
                              "i need you to ", "i want you to "]
        let actionStart = politePrefixes.first(where: { value.hasPrefix($0) })
            .map { String(value.dropFirst($0.count)) } ?? value
        func mentionsAction(_ verb: String) -> Bool {
            actionStart.hasPrefix(verb + " ") || actionStart == verb
                || value.contains(" then " + verb + " ")
                || value.contains(" and " + verb + " ")
                || value.contains(". " + verb + " ")
                || value.contains("; " + verb + " ")
        }
        let durableAction = durableVerbs.contains(where: mentionsAction)
        let existingAction = ["fix", "update", "modify", "refactor", "repair"]
            .contains(where: mentionsAction)
        if !durableAction,
           ["format ", "summarize ", "convert ", "calculate ", "run this ",
            "check this ", "translate ", "rewrite "].contains(where: actionStart.hasPrefix) {
            return .transient
        }
        let implicitlyRequestsProject =
            ["i need a ", "i need an ", "i want a ", "i want an ", "i'd like a "]
                .contains(where: value.hasPrefix)
            && ["website", "web app", "application", "dashboard", "project", "repository",
                "codebase", "utility", "program", "tracker"].contains(where: value.contains)
        guard durableAction || implicitlyRequestsProject else {
            // Project creation is an explicit durable-work action. Unknown
            // phrasing, even when it mentions an existing app, is not enough
            // to manufacture one during chat or research.
            return .informational
        }
        if existingAction || value.contains("my ") || value.contains("existing ")
            || value.contains("current ") || value.contains(" in lima")
            || value.contains("the lima ") {
            return .durableExistingWork
        }
        return .durableNewWork
    }
}

struct AIProjectCandidate: Sendable, Equatable {
    let projectID: UUID
    let name: String
    let lifecycle: String
    let score: Double
    let reasons: [String]
}

enum AIProjectResolution: Sendable, Equatable {
    case existing(projectID: UUID, confidence: Double)
    case archived(projectID: UUID, confidence: Double)
    case removed(projectID: UUID, confidence: Double)
    case ambiguous(candidates: [AIProjectCandidate])
    case createNew(suggestedName: String)
    case noProjectNeeded
}

/// Ranks bounded registry metadata, never source contents. A close pair is
/// deliberately ambiguous rather than selecting a possibly wrong project.
actor AIProjectResolver {
    static let shared = AIProjectResolver()

    func search(query: String, projects: [AIProject],
                removed: [AIRemovedProject] = [],
                includeArchived: Bool = true,
                includeRemoved: Bool = false) -> [AIProjectCandidate] {
        let query = String(query.prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var entries = projects.filter { includeArchived || $0.lifecycle == .active }
            .map { ($0, $0.lifecycle.rawValue) }
        if includeRemoved {
            entries += removed.map { ($0.project, "removed") }
        }
        return entries.compactMap { project, lifecycle -> AIProjectCandidate? in
            let name = Self.normalized(project.name)
            let searched = Self.normalized(query)
            let queryTokens = Set(Self.tokens(query))
            let nameTokens = Set(Self.tokens(project.name))
            let remote = project.repository?.remoteURL ?? ""
            let repoName = Self.repositoryName(remote)
            let repoTokens = Set(Self.tokens(repoName))
            let instructionTokens = Set(Self.tokens(String(project.instructions.prefix(500))))
            let stackTokens = Set(project.detectedStack.flatMap(Self.tokens))
            var score = 0.0
            var reasons: [String] = []
            if name == searched {
                score = 0.98
                reasons.append("project name matches exactly")
            } else if !searched.isEmpty && name.contains(searched) {
                score = max(score, 0.82)
                reasons.append("project name contains the query")
            }
            if !repoName.isEmpty && Self.normalized(repoName) == searched {
                score = max(score, 0.95)
                reasons.append("repository name matches exactly")
            }
            // A normal task query includes verbs and feature names. Match a
            // distinctive whole Project/repository name within that request.
            if Self.isDistinctive(name), Self.containsPhrase(name, in: searched) {
                score = max(score, 0.96)
                reasons.append("project name appears in the request")
            }
            let normalizedRepository = Self.normalized(repoName)
            if Self.isDistinctive(normalizedRepository),
               Self.containsPhrase(normalizedRepository, in: searched) {
                score = max(score, 0.94)
                reasons.append("repository name appears in the request")
            }
            func overlap(_ tokens: Set<String>, weight: Double, reason: String) {
                guard !queryTokens.isEmpty, !tokens.isEmpty else { return }
                let shared = queryTokens.intersection(tokens).count
                guard shared > 0 else { return }
                let coverage = Double(shared) / Double(tokens.count)
                score = max(score, weight * coverage)
                reasons.append(reason)
            }
            overlap(nameTokens, weight: 0.88, reason: "project name terms match")
            overlap(repoTokens, weight: 0.84, reason: "repository terms match")
            overlap(instructionTokens, weight: 0.58, reason: "project instructions match")
            overlap(stackTokens, weight: 0.52, reason: "detected stack matches")
            guard score >= 0.35 else { return nil }
            return AIProjectCandidate(projectID: project.id, name: project.name,
                                      lifecycle: lifecycle, score: score,
                                      reasons: Array(reasons.prefix(4)))
        }
        .sorted { $0.score == $1.score ? $0.name < $1.name : $0.score > $1.score }
        .prefix(12)
        .map { $0 }
    }

    func resolve(intent: AIWorkIntent, query: String, projects: [AIProject],
                 removed: [AIRemovedProject] = [],
                 includeRemoved: Bool = false) -> AIProjectResolution {
        guard intent == .durableExistingWork || intent == .durableNewWork else {
            return .noProjectNeeded
        }
        let matches = search(query: query, projects: projects, removed: removed,
                             includeRemoved: includeRemoved)
        guard let first = matches.first else {
            return .createNew(suggestedName: String(query.prefix(120)))
        }
        let second = matches.dropFirst().first
        if let second, second.score >= 0.55,
           (first.score - second.score < 0.14
            || Self.relatedNames(first.name, second.name)) {
            return .ambiguous(candidates: Array(matches.prefix(3)))
        }
        guard first.score >= 0.9 else {
            return first.score >= 0.65
                ? .ambiguous(candidates: Array(matches.prefix(3)))
                : .createNew(suggestedName: String(query.prefix(120)))
        }
        if first.lifecycle == "removed" {
            return .removed(projectID: first.projectID, confidence: first.score)
        }
        return first.lifecycle == AIProjectLifecycle.archived.rawValue
            ? .archived(projectID: first.projectID, confidence: first.score)
            : .existing(projectID: first.projectID, confidence: first.score)
    }

    private static func normalized(_ value: String) -> String {
        tokens(value).joined(separator: " ")
    }

    private static func tokens(_ value: String) -> [String] {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func containsPhrase(_ phrase: String, in query: String) -> Bool {
        !phrase.isEmpty && (" " + query + " ").contains(" " + phrase + " ")
    }

    private static func isDistinctive(_ phrase: String) -> Bool {
        let generic: Set<String> = ["app", "project", "website", "dashboard", "test", "code", "new"]
        return phrase.count >= 4 && !generic.contains(phrase)
    }

    private static func relatedNames(_ first: String, _ second: String) -> Bool {
        let a = normalized(first)
        let b = normalized(second)
        return a.hasPrefix(b + " ") || b.hasPrefix(a + " ")
    }

    private static func repositoryName(_ remote: String) -> String {
        let path: String
        if let components = URLComponents(string: remote), components.scheme != nil {
            path = components.path
        } else {
            path = remote.split(separator: ":").last.map(String.init) ?? remote
        }
        let name = path.split(separator: "/").last.map(String.init) ?? ""
        return name.hasSuffix(".git") ? String(name.dropLast(4)) : name
    }
}
