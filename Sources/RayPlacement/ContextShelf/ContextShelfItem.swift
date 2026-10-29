import Foundation

enum ContextShelfItemKind: String, Codable, CaseIterable {
    case selectedText
    case clipboard
    case terminalOutput
    case file
    case dictation
    case extensionOutput
    case noteReference
    case plainText
    case mailReference
    case browserReference
    case messageReference
}

struct ContextShelfItem: Identifiable, Codable, Equatable {
    let id: UUID
    var kind: ContextShelfItemKind
    var title: String
    var preview: String
    var payload: ContextShelfPayload
    var source: ContextShelfSource
    var createdAt: Date
    var isPinned: Bool

    /// Treat either a Mail kind or payload as private Mail context. This also
    /// fails closed for inconsistent records loaded from local storage.
    var isMailReference: Bool {
        if kind == .mailReference { return true }
        if case .mailReference = payload { return true }
        return false
    }

    /// Browser references require a fresh Browser read for page content and
    /// must not be flattened into generic Shelf text for AI or extensions.
    var isBrowserReference: Bool {
        if kind == .browserReference { return true }
        if case .browserReference = payload { return true }
        return false
    }

    var isMessageReference: Bool {
        if kind == .messageReference { return true }
        if case .messageReference = payload { return true }
        return false
    }

    var textValue: String? {
        switch payload {
        case .text(let text): return text
        case .terminal(_, let output): return output
        case .dictation(let transcript): return transcript
        case .file, .note, .mailReference, .browserReference, .messageReference: return nil
        }
    }
}
