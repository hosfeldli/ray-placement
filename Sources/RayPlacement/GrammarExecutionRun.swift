import Foundation

enum GrammarExecutionRunState: String, Codable, CaseIterable, Sendable {
    case queued
    case checking
    case applying
    case completed
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        case .queued, .checking, .applying: false
        }
    }

    fileprivate func canTransition(to next: Self) -> Bool {
        if self == next { return true }
        switch self {
        case .queued:
            return [.checking, .failed, .cancelled].contains(next)
        case .checking:
            return [.applying, .completed, .failed, .cancelled].contains(next)
        case .applying:
            return [.completed, .failed, .cancelled].contains(next)
        case .completed, .failed, .cancelled:
            return false
        }
    }
}

/// Tracks the explicit Grammar lifecycle independently from its visible toast or
/// review surface. It intentionally retains no selected text or provider output.
struct GrammarExecutionRun: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    private(set) var state: GrammarExecutionRunState
    private(set) var completedAt: Date?

    init(id: UUID = UUID(), startedAt: Date = Date()) {
        self.id = id
        self.startedAt = startedAt
        state = .queued
        completedAt = nil
    }

    var isActive: Bool { !state.isTerminal }

    @discardableResult
    mutating func transition(to nextState: GrammarExecutionRunState, at date: Date = Date()) -> Bool {
        guard state.canTransition(to: nextState) else { return false }
        if state == nextState { return true }

        state = nextState
        completedAt = nextState.isTerminal ? date : nil
        return true
    }
}
