import AppKit
import Foundation
import RayPlacementCore

/// A portable, versioned backup containing user data but never Keychain secrets.
struct LimaBackupArchive: Codable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let createdAt: Date
    let notes: [MarkdownNote]
    let dictation: [DictationConversation]
    let clipboard: [ClipboardEntry]
    let settings: [String: LimaBackupValue]
}

enum LimaBackupValue: Codable {
    case string(String)
    case bool(Bool)
    case integer(Int)
    case double(Double)
    case array([LimaBackupValue])
    case object([String: LimaBackupValue])

    init?(any: Any) {
        switch any {
        case let value as String: self = .string(value)
        case let value as Bool: self = .bool(value)
        case let value as Int: self = .integer(value)
        case let value as Double: self = .double(value)
        case let value as NSNumber:
            self = CFGetTypeID(value) == CFBooleanGetTypeID() ? .bool(value.boolValue) : .double(value.doubleValue)
        case let values as [Any]:
            self = .array(values.compactMap(LimaBackupValue.init(any:)))
        case let values as [String: Any]:
            self = .object(values.compactMapValues(LimaBackupValue.init(any:)))
        default: return nil
        }
    }

    private enum CodingKeys: String, CodingKey { case type, string, bool, integer, double, array, object }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let value):
            try container.encode("string", forKey: .type); try container.encode(value, forKey: .string)
        case .bool(let value):
            try container.encode("bool", forKey: .type); try container.encode(value, forKey: .bool)
        case .integer(let value):
            try container.encode("integer", forKey: .type); try container.encode(value, forKey: .integer)
        case .double(let value):
            try container.encode("double", forKey: .type); try container.encode(value, forKey: .double)
        case .array(let value):
            try container.encode("array", forKey: .type); try container.encode(value, forKey: .array)
        case .object(let value):
            try container.encode("object", forKey: .type); try container.encode(value, forKey: .object)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "string": self = .string(try container.decode(String.self, forKey: .string))
        case "bool": self = .bool(try container.decode(Bool.self, forKey: .bool))
        case "integer": self = .integer(try container.decode(Int.self, forKey: .integer))
        case "double": self = .double(try container.decode(Double.self, forKey: .double))
        case "array": self = .array(try container.decode([LimaBackupValue].self, forKey: .array))
        case "object": self = .object(try container.decode([String: LimaBackupValue].self, forKey: .object))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown backup value type")
        }
    }

    var anyValue: Any {
        switch self {
        case .string(let value): return value
        case .bool(let value): return value
        case .integer(let value): return value
        case .double(let value): return value
        case .array(let value): return value.map(\.anyValue)
        case .object(let value): return value.mapValues(\.anyValue)
        }
    }
}

@MainActor
final class DataBackupCoordinator: ObservableObject {
    static let shared = DataBackupCoordinator()
    @Published private(set) var lastError: String?
    @Published private(set) var lastBackupURL: URL?

    func exportBackup(to destination: URL? = nil) throws -> URL {
        let settingsURL = FileManager.default.temporaryDirectory.appendingPathComponent("lima-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        let settingsData = try SettingsStore.shared.exportBackup(to: settingsURL)
        let rawSettings = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsData)) as? [String: Any] ?? [:]
        let settings = rawSettings.compactMapValues(LimaBackupValue.init(any:))
        let notes = NotesStore.shared
        let dictation = DictationConversationStore.shared
        let clipboard = ClipboardHistoryService.shared
        let archive = LimaBackupArchive(
            schemaVersion: LimaBackupArchive.currentSchemaVersion,
            createdAt: Date(),
            notes: notes.notes,
            dictation: dictation.conversations,
            clipboard: clipboard.entries,
            settings: settings
        )
        let target = destination ?? FileManager.default.temporaryDirectory.appendingPathComponent("Lima-Backup-\(Int(Date().timeIntervalSince1970)).json")
        try ApplicationPaths.prepare()
        let data = try JSONEncoder.limaBackupEncoder.encode(archive)
        let parent = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: target, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        lastBackupURL = target
        lastError = nil
        return target
    }

    func report(_ error: Error) {
        lastError = error.localizedDescription
    }

    func importBackup(from url: URL) throws {
        let result = PrivateFileStore().loadJSON(LimaBackupArchive.self, from: url, decoder: JSONDecoder.limaBackupDecoder)
        guard let archive = result.value else {
            throw result.result.errorDescription.map { NSError(domain: "LimaBackup", code: 1, userInfo: [NSLocalizedDescriptionKey: $0]) }
                ?? NSError(domain: "LimaBackup", code: 2, userInfo: [NSLocalizedDescriptionKey: "The backup could not be read."])
        }
        guard archive.schemaVersion == LimaBackupArchive.currentSchemaVersion else {
            throw NSError(domain: "LimaBackup", code: 3, userInfo: [NSLocalizedDescriptionKey: "This backup version is not supported."])
        }
        guard archive.notes.count <= NotesStore.maximumNotes,
              archive.notes.allSatisfy({ $0.content.count <= NotesStore.maximumCharactersPerNote }),
              archive.dictation.count <= DictationConversationStore.maximumConversations,
              archive.dictation.allSatisfy({ $0.characterCount <= DictationConversationStore.maximumCharactersPerConversation }),
              archive.clipboard.count <= 500 else {
            throw NSError(domain: "LimaBackup", code: 4, userInfo: [NSLocalizedDescriptionKey: "The backup contains more data than Lima permits."])
        }
        try notesStore.replace(with: archive.notes)
        try dictationStore.replace(with: archive.dictation)
        try clipboardStore.replace(with: archive.clipboard)
        try SettingsStore.shared.importBackupValues(archive.settings)
        lastError = nil
    }

    private var notesStore: NotesStore { NotesStore.shared }
    private var dictationStore: DictationConversationStore { DictationConversationStore.shared }
    private var clipboardStore: ClipboardHistoryService { ClipboardHistoryService.shared }
}

extension JSONEncoder {
    static var limaBackupEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var limaBackupDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
