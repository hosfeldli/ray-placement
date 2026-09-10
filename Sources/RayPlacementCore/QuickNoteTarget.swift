import Foundation

public enum QuickNoteTargetMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case lastQuickNote
    case inbox
    case mostRecent

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .lastQuickNote: return "Last Quick Note"
        case .inbox: return "Inbox"
        case .mostRecent: return "Most Recent"
        }
    }

    public var detail: String {
        switch self {
        case .lastQuickNote: return "Reopen the note last shown in Quick Note"
        case .inbox: return "Use the note tagged as the local Inbox"
        case .mostRecent: return "Open the note changed most recently"
        }
    }
}

public enum QuickNoteTargetResolver {
    public static func resolve(
        mode: QuickNoteTargetMode,
        savedTargetID: UUID?,
        selectedNoteID: UUID?,
        notes: [MarkdownNote]
    ) -> UUID? {
        guard !notes.isEmpty else { return nil }
        switch mode {
        case .lastQuickNote:
            if let savedTargetID, notes.contains(where: { $0.id == savedTargetID }) {
                return savedTargetID
            }
            if let selectedNoteID, notes.contains(where: { $0.id == selectedNoteID }) {
                return selectedNoteID
            }
            return notes.max(by: { $0.modifiedAt < $1.modifiedAt })?.id
        case .inbox:
            if let inboxID = notes.first(where: {
                $0.displayTitle.caseInsensitiveCompare("Inbox") == .orderedSame
                    || $0.tags.contains { $0.caseInsensitiveCompare("inbox") == .orderedSame }
            })?.id {
                return inboxID
            }
            // Selecting Inbox before it exists should not discard the last
            // Quick Note target. Keep the mode active so a later Inbox is
            // picked up automatically.
            return resolve(
                mode: .lastQuickNote,
                savedTargetID: savedTargetID,
                selectedNoteID: selectedNoteID,
                notes: notes
            )
        case .mostRecent:
            return notes.max(by: { $0.modifiedAt < $1.modifiedAt })?.id
        }
    }
}
