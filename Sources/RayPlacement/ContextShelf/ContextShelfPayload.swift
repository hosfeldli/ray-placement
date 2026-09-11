import Foundation

enum ContextShelfPayload: Codable, Equatable {
    case text(String)
    case file(path: String, displayName: String)
    case note(noteID: UUID, title: String)
    case terminal(command: String?, output: String)
    case dictation(transcript: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case path
        case displayName
        case noteID
        case title
        case command
        case output
        case transcript
    }

    private enum PayloadType: String, Codable {
        case text
        case file
        case note
        case terminal
        case dictation
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode(PayloadType.text, forKey: .type)
            try container.encode(text, forKey: .text)
        case .file(let path, let displayName):
            try container.encode(PayloadType.file, forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(displayName, forKey: .displayName)
        case .note(let noteID, let title):
            try container.encode(PayloadType.note, forKey: .type)
            try container.encode(noteID, forKey: .noteID)
            try container.encode(title, forKey: .title)
        case .terminal(let command, let output):
            try container.encode(PayloadType.terminal, forKey: .type)
            try container.encodeIfPresent(command, forKey: .command)
            try container.encode(output, forKey: .output)
        case .dictation(let transcript):
            try container.encode(PayloadType.dictation, forKey: .type)
            try container.encode(transcript, forKey: .transcript)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(PayloadType.self, forKey: .type) {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .file:
            self = .file(
                path: try container.decode(String.self, forKey: .path),
                displayName: try container.decode(String.self, forKey: .displayName)
            )
        case .note:
            self = .note(
                noteID: try container.decode(UUID.self, forKey: .noteID),
                title: try container.decode(String.self, forKey: .title)
            )
        case .terminal:
            self = .terminal(
                command: try container.decodeIfPresent(String.self, forKey: .command),
                output: try container.decode(String.self, forKey: .output)
            )
        case .dictation:
            self = .dictation(transcript: try container.decode(String.self, forKey: .transcript))
        }
    }
}
