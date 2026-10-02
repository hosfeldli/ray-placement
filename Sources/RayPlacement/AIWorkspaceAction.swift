import Foundation

/// Every shortcut prepares a visible draft; none sends a request or runs a tool.
enum AIWorkspaceAction: String, CaseIterable, Identifiable {
    case summarize, improve, shorten, tasks, brainstorm, email
    var id: String { rawValue }
    var title: String {
        switch self {
        case .summarize: return "Summarize"
        case .improve: return "Improve writing"
        case .shorten: return "Make it shorter"
        case .tasks: return "Find action items"
        case .brainstorm: return "Brainstorm ideas"
        case .email: return "Draft an email"
        }
    }
    var symbol: String {
        switch self {
        case .summarize: return "doc.text"
        case .improve: return "wand.and.stars"
        case .shorten: return "text.alignleft"
        case .tasks: return "checklist"
        case .brainstorm: return "lightbulb"
        case .email: return "envelope"
        }
    }
    var requiresSource: Bool { self != .brainstorm && self != .email }
    var instruction: String {
        switch self {
        case .summarize: return "Summarize the attached context, or the latest response if there are no attachments, clearly and concisely."
        case .improve: return "Improve the clarity of the attached text, or the latest response if there are no attachments, while preserving its meaning."
        case .shorten: return "Shorten the attached text, or the latest response if there are no attachments, while preserving the key facts."
        case .tasks: return "Extract action items from the attached context, or the latest response if there are no attachments, as a Markdown checklist. Do not invent owners or dates."
        case .brainstorm: return "Help me brainstorm ideas. Ask me what goal and constraints to focus on if they are not already clear."
        case .email: return "Help me draft an email. Ask for the recipient, purpose, and tone if they are not already clear. Prepare text only; do not send an email."
        }
    }
}

extension AIChatViewModel {
    var hasWorkspaceActionSource: Bool {
        !attachments.isEmpty || (selectedConversation?.messages.contains {
            $0.role == .assistant && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? false)
    }

    @discardableResult
    func prepareWorkspaceAction(_ action: AIWorkspaceAction) -> Bool {
        guard AIRequestPolicy.shared.isEnabled, !canEndTask,
              !action.requiresSource || hasWorkspaceActionSource else { return false }
        appendDraftPrompt(action.instruction)
        return true
    }
}
