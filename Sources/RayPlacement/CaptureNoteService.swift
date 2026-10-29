import Foundation

/// Explicit local capture. AI tools never call this service.
@MainActor
enum CaptureNoteService {
    enum Source {
        case clipboard
        case selection(applicationName: String?)
        case browser(pageTitle: String)
        case dictation(startedAt: Date)
        case aiResponse(conversationTitle: String?)

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
            case .browser(let pageTitle):
                let cleanTitle = pageTitle.replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return cleanTitle.isEmpty ? "Captured Browser Page" :
                    "Browser · \(String(cleanTitle.prefix(80)))"
            case .dictation(let startedAt):
                return "Dictation · \(startedAt.formatted(date: .abbreviated, time: .shortened))"
            case .aiResponse(let conversationTitle):
                let cleanTitle = conversationTitle?
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let cleanTitle, !cleanTitle.isEmpty else { return "AI Response" }
                return "AI Response · \(String(cleanTitle.prefix(80)))"
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
