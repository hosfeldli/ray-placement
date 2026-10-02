import Foundation

/// Explicit local capture. AI tools never call this service.
@MainActor
enum CaptureNoteService {
    enum Source {
        case clipboard
        case selection(applicationName: String?)

        var title: String {
            switch self {
            case .clipboard:
                return "Captured Clipboard"
            case .selection(let applicationName):
                let cleanName = applicationName?
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let cleanName, !cleanName.isEmpty else {
                    return "Captured Selection"
                }
                return "Captured Selection · \(String(cleanName.prefix(80)))"
            }
        }
    }

    enum CaptureError: LocalizedError {
        case emptyText
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyText:
                return "There is no text to capture."
            case .saveFailed(let message):
                return message
            }
        }
    }

    @discardableResult
    static func save(_ text: String, source: Source, in store: NotesStore) throws -> UUID {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw CaptureError.emptyText }
        let previousID = store.selectedNoteID
        store.createQuickNote(with: clean)
        guard let id = store.selectedNoteID, id != previousID else {
            throw CaptureError.saveFailed(store.lastError ?? "The captured note could not be created.")
        }
        store.updateTitle(source.title)
        return id
    }
}
