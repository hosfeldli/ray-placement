import Foundation

struct GrammarCandidateProfile: Identifiable, Equatable, Sendable {
    let id: String
    let diversitySeed: UInt64
    let promptVersion: String
    let instructions: String
    let temperature: Double?
    let reasoningEffort: String?

    static let minimalEditor = GrammarCandidateProfile(
        id: "minimal-editor",
        diversitySeed: 17,
        promptVersion: "ensemble-proofread-v1",
        instructions: "Correct only clear grammatical, spelling, capitalization, and punctuation errors. Make the smallest possible changes. Do not make stylistic changes or rewrite correct phrases.",
        temperature: 0.1,
        reasoningEffort: nil
    )

    static let grammarAnalyst = GrammarCandidateProfile(
        id: "grammar-analyst",
        diversitySeed: 43,
        promptVersion: "ensemble-proofread-v1",
        instructions: "Act as a conservative grammar analyst. Pay particular attention to subject and verb agreement, tense, articles, pronouns, apostrophes, punctuation, and misspellings. Return only narrowly targeted atomic corrections.",
        temperature: 0.2,
        reasoningEffort: nil
    )

    static let preservationEditor = GrammarCandidateProfile(
        id: "preservation-editor",
        diversitySeed: 89,
        promptVersion: "ensemble-proofread-v1",
        instructions: "Correct objectively incorrect writing while maximizing preservation of the original. Any character that does not require changing must remain unchanged, especially whitespace, punctuation, formatting, and tone.",
        temperature: 0.3,
        reasoningEffort: nil
    )

    static let skepticalReviewer = GrammarCandidateProfile(
        id: "skeptical-reviewer",
        diversitySeed: 101,
        promptVersion: "ensemble-proofread-v1",
        instructions: "Only propose an edit when you are highly confident the existing wording is objectively incorrect. Prefer no change over a speculative correction. Use the smallest atomic replacement.",
        temperature: 0.1,
        reasoningEffort: nil
    )

    static let syntaxReviewer = GrammarCandidateProfile(
        id: "syntax-reviewer",
        diversitySeed: 137,
        promptVersion: "ensemble-proofread-v1",
        instructions: "Review the complete document for objective syntax and agreement errors. Preserve meaning, voice, formatting, and every correct character. Never perform a stylistic rewrite.",
        temperature: 0.2,
        reasoningEffort: nil
    )

    static let conservativeAdjudicator = GrammarCandidateProfile(
        id: "conservative-adjudicator",
        diversitySeed: 151,
        promptVersion: "ensemble-judge-v1",
        instructions: "Evaluate only the proposed corrections. Do not proofread the source yourself and do not invent, rewrite, or modify an edit. Select an existing candidate for each issue only when it is objectively correct and preserves meaning and formatting; otherwise select null.",
        temperature: 0.1,
        reasoningEffort: nil
    )

    static func profiles(for strategy: GrammarEnsembleStrategy) -> [GrammarCandidateProfile] {
        switch strategy {
        case .fast: return [minimalEditor, grammarAnalyst]
        case .balanced: return [minimalEditor, grammarAnalyst, preservationEditor]
        case .thorough: return [minimalEditor, grammarAnalyst, preservationEditor, skepticalReviewer, syntaxReviewer]
        }
    }
}

enum GrammarEnsembleStrategy: String, CaseIterable, Identifiable, Sendable, Codable {
    case fast
    case balanced
    case thorough

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var candidateCount: Int {
        switch self {
        case .fast: return 2
        case .balanced: return 3
        case .thorough: return 5
        }
    }

    var detail: String {
        switch self {
        case .fast: return "2 diversified candidates"
        case .balanced: return "3 diversified candidates"
        case .thorough: return "5 diversified candidates"
        }
    }
}
