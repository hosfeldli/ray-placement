import CryptoKit
import Foundation
import RayPlacementCore

/// Keeps large message bodies out of the conversation metadata file. The
/// metadata is committed only after every referenced body has been written.
enum AIConversationPersistence {
    static let bodyThresholdBytes = 8 * 1_024

    enum StorageError: Error {
        case invalidBodyReference
        case missingOrCorruptBody
    }

    static func load(from url: URL) throws -> [AIConversation] {
        let data = try Data(contentsOf: url)
        var conversations = try JSONDecoder().decode([AIConversation].self, from: data)
        let bodyDirectory = url.deletingLastPathComponent()
            .appendingPathComponent("messages", isDirectory: true)

        for conversationIndex in conversations.indices {
            for messageIndex in conversations[conversationIndex].messages.indices {
                let message = conversations[conversationIndex].messages[messageIndex]
                guard let reference = message.textStorageReference else { continue }
                guard valid(reference: reference, for: message.id) else {
                    throw StorageError.invalidBodyReference
                }
                let bodyURL = bodyDirectory.appendingPathComponent(reference, isDirectory: false)
                guard let bodyData = try? Data(contentsOf: bodyURL),
                      digestHex(bodyData) == expectedDigest(in: reference, for: message.id),
                      let body = String(data: bodyData, encoding: .utf8) else {
                    throw StorageError.missingOrCorruptBody
                }
                conversations[conversationIndex].messages[messageIndex].restoreBodyFromStorage(body)
            }
        }
        return conversations
    }

    static func persist(_ conversations: [AIConversation], to url: URL) throws {
        let fileStore = PrivateFileStore()
        let bodyDirectory = url.deletingLastPathComponent()
            .appendingPathComponent("messages", isDirectory: true)
        var metadata = conversations

        for conversationIndex in metadata.indices {
            for messageIndex in metadata[conversationIndex].messages.indices {
                let message = metadata[conversationIndex].messages[messageIndex]
                guard message.text.utf8.count >= bodyThresholdBytes else {
                    metadata[conversationIndex].messages[messageIndex].textStorageReference = nil
                    continue
                }
                let bodyData = Data(message.text.utf8)
                let reference = message.id.uuidString + "-" + digestHex(bodyData) + ".txt"
                let bodyURL = bodyDirectory.appendingPathComponent(reference, isDirectory: false)
                let existingData = try? Data(contentsOf: bodyURL)
                if existingData != bodyData {
                    try fileStore.write(data: bodyData, to: bodyURL, backupExisting: false)
                }
                metadata[conversationIndex].messages[messageIndex].replaceBodyForStorage(reference: reference)
            }
        }

        // Atomic metadata commit comes last: no committed reference points at a
        // body that has not yet been durably written. Legacy inline JSON remains
        // readable and is migrated only when a new snapshot is saved.
        try fileStore.write(metadata, to: url, backupExisting: false)

        let retainedReferences = Set(metadata.flatMap { conversation in
            conversation.messages.compactMap(\.textStorageReference)
        })
        if let files = try? FileManager.default.contentsOfDirectory(
            at: bodyDirectory, includingPropertiesForKeys: nil
        ) {
            for file in files where !retainedReferences.contains(file.lastPathComponent) {
                guard file.lastPathComponent.count == 36 + 1 + 64 + 4,
                      let messageID = UUID(uuidString: String(file.lastPathComponent.prefix(36))),
                      valid(reference: file.lastPathComponent, for: messageID) else { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private static func valid(reference: String, for messageID: UUID) -> Bool {
        guard let digest = expectedDigest(in: reference, for: messageID) else { return false }
        return digest.count == 64 && digest.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }

    private static func expectedDigest(in reference: String, for messageID: UUID) -> String? {
        let prefix = messageID.uuidString + "-"
        guard reference.hasPrefix(prefix), reference.hasSuffix(".txt") else { return nil }
        return String(reference.dropFirst(prefix.count).dropLast(4))
    }

    private static func digestHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
