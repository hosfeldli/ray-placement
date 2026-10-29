import Foundation

extension Notification.Name {
    static let limaMessagesPolicyDidChange = Notification.Name("lima.messages.policy.did-change")
}

/// A reference is metadata, not cached message content or permission to read it.
struct MessageContextReference: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case conversation, message, selection }
    let kind: Kind
    let conversationGUID: String
    let messageGUID: String?
    let selectedText: String?
    let participantLabels: [String]
    let messageDate: Date?
    let service: String?
    let capturedAt: Date

    var isValid: Bool {
        let validKind: Bool
        switch kind {
        case .conversation:
            validKind = messageGUID == nil && selectedText == nil
        case .message:
            validKind = messageGUID?.isEmpty == false && selectedText == nil
        case .selection:
            validKind = messageGUID?.isEmpty == false &&
                selectedText?.isEmpty == false &&
                (selectedText?.utf8.count ?? 0) <= 4_096
        }
        return validKind &&
            !conversationGUID.isEmpty && conversationGUID.utf8.count <= 512 &&
            (messageGUID?.utf8.count ?? 0) <= 512 &&
            participantLabels.count <= 32 &&
            participantLabels.allSatisfy { !$0.isEmpty && $0.utf8.count <= 160 } &&
            (service?.utf8.count ?? 0) <= 80
    }
}

struct MessagesConversation: Codable, Hashable, Sendable, Identifiable {
    let guid: String
    let title: String
    let service: String?
    let lastMessageAt: Date?
    let isGroup: Bool
    var id: String { guid }
}

struct MessagesMessage: Codable, Hashable, Sendable, Identifiable {
    let guid: String
    let conversationGUID: String
    let senderAddress: String?
    let sentAt: Date
    let text: String?
    let contentStatus: String
    let isFromMe: Bool
    let service: String?
    var id: String { guid }
}

struct MessagesAttachment: Codable, Hashable, Sendable, Identifiable {
    let guid: String
    let messageGUID: String
    let filename: String?
    let mimeType: String?
    let byteCount: Int64?
    var id: String { guid }
}

enum MessagesOrigin: Sendable { case userInterface, ai, extensionCommand }

enum MessagesCapabilityError: LocalizedError, Sendable {
    case readingDisabled, aiReadingDisabled, sendingDisabled, permissionDenied
    case conversationNotPermitted, invalidRequest, schemaUnsupported
    case databaseUnavailable, messageUnavailable, automationDenied
    case destinationChanged, reviewRequired, reviewExpired, reviewMismatch
    case sendOutcomeUncertain, journalUnavailable, sendFailed

    var errorDescription: String? {
        switch self {
        case .readingDisabled: return "Messages history access is off in Lima Settings."
        case .aiReadingDisabled: return "Sharing selected Messages conversations with AI is off in Lima Settings."
        case .sendingDisabled: return "Messages sending is off in Lima Settings."
        case .permissionDenied: return "Lima could not read Messages history. Grant Full Disk Access in macOS Settings, then retry."
        case .conversationNotPermitted: return "This conversation is not in Lima's selected Messages scope."
        case .invalidRequest: return "The Messages request must use a selected conversation, a bounded date range, and a bounded result count."
        case .schemaUnsupported: return "This macOS Messages history format is not supported by Lima's read-only adapter."
        case .databaseUnavailable: return "Messages history is unavailable. Check that Messages is configured on this Mac and Lima has Full Disk Access, then retry."
        case .messageUnavailable: return "That message is no longer available in the selected conversation."
        case .automationDenied: return "macOS denied Lima permission to automate Messages. Review Automation in System Settings."
        case .destinationChanged: return "The Messages destination changed. Review the recipient or group again."
        case .reviewRequired: return "Review the exact recipient and message in Lima before sending."
        case .reviewExpired: return "This Messages send review expired. Review the message again."
        case .reviewMismatch: return "The destination, text, or attachment changed after review. Review it again."
        case .sendOutcomeUncertain: return "Messages may have accepted this send. Check the conversation before trying again; Lima will not retry it automatically."
        case .journalUnavailable: return "Lima could not safely record or reconcile this send. Check Messages before trying again; Lima will not retry it automatically."
        case .sendFailed: return "Messages did not confirm acceptance of the send request. Its outcome is uncertain until checked in Messages."
        }
    }
}

/// Full Disk Access is a broad OS grant. This policy narrows Lima's own reads.
struct MessagesCapabilityPolicy: Codable, Equatable, Sendable {
    var readEnabled = false
    var aiReadEnabled = false
    var sendEnabled = false
    var aiComposeEnabled = false
    var monitorEnabled = false
    var attachmentContentEnabled = false
    var selectedConversationGUIDs: Set<String> = []
    var excludedConversationGUIDs: Set<String> = []
    var historyDays = 30

    static let disabled = MessagesCapabilityPolicy()

    func permits(_ guid: String) -> Bool {
        readEnabled && selectedConversationGUIDs.contains(guid) &&
            !excludedConversationGUIDs.contains(guid)
    }

    var isValid: Bool {
        (1...365).contains(historyDays) &&
        selectedConversationGUIDs.count <= 500 &&
        excludedConversationGUIDs.count <= 500 &&
        (selectedConversationGUIDs.union(excludedConversationGUIDs)).allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 512
        } &&
        (!aiReadEnabled || readEnabled) &&
        (!aiComposeEnabled || sendEnabled)
    }
}

enum MessagesCapabilityPolicyStore {
    private static let key = "lima.messages.capability-policy.v1"

    static func load(defaults: UserDefaults = LimaTestEnvironment.userDefaults) -> MessagesCapabilityPolicy {
        guard let data = defaults.data(forKey: key),
              let policy = try? JSONDecoder().decode(MessagesCapabilityPolicy.self, from: data),
              policy.isValid else { return .disabled }
        return policy
    }

    static func save(_ policy: MessagesCapabilityPolicy,
                     defaults: UserDefaults = LimaTestEnvironment.userDefaults) throws {
        guard policy.isValid else { throw MessagesCapabilityError.invalidRequest }
        defaults.set(try JSONEncoder().encode(policy), forKey: key)
        NotificationCenter.default.post(name: .limaMessagesPolicyDidChange, object: nil)
    }

    static func disconnect(defaults: UserDefaults = LimaTestEnvironment.userDefaults) {
        defaults.removeObject(forKey: key)
        NotificationCenter.default.post(name: .limaMessagesPolicyDidChange, object: nil)
    }
}

/// All UI, AI, and extension reads pass through one service and one policy.
actor MessagesCapabilityService {
    static let shared = MessagesCapabilityService()
    private let reader = MessagesReadAdapter()

    func discoverChats(limit: Int = 100) async throws -> [MessagesConversation] {
        guard MessagesCapabilityPolicyStore.load().readEnabled,
              (1...100).contains(limit) else { throw MessagesCapabilityError.readingDisabled }
        let chats = try await reader.listChats(limit: limit)
        guard MessagesCapabilityPolicyStore.load().readEnabled else {
            throw MessagesCapabilityError.readingDisabled
        }
        return chats
    }

    func listChats(origin: MessagesOrigin, limit: Int = 30) async throws -> [MessagesConversation] {
        let policy = try authorizedPolicy(origin: origin)
        guard (1...100).contains(limit) else { throw MessagesCapabilityError.invalidRequest }
        let chats = try await reader.listChats(
            limit: limit,
            selectedGUIDs: policy.selectedConversationGUIDs.subtracting(policy.excludedConversationGUIDs)
        )
        let live = try authorizedPolicy(origin: origin)
        return chats.filter { live.permits($0.guid) }
    }

    func search(_ text: String, after: Date, before: Date, limit: Int,
                origin: MessagesOrigin) async throws -> [MessagesMessage] {
        let policy = try authorizedPolicy(origin: origin)
        let now = Date()
        let lower = max(after, now.addingTimeInterval(-Double(policy.historyDays) * 86_400))
        let upper = min(before, now)
        guard text.utf8.count <= 256, after < before, lower < upper,
              (1...50).contains(limit) else { throw MessagesCapabilityError.invalidRequest }
        let messages = try await reader.search(
            text: text, after: lower, before: upper, limit: limit,
            permittedGUIDs: policy.selectedConversationGUIDs.subtracting(policy.excludedConversationGUIDs)
        )
        let live = try authorizedPolicy(origin: origin)
        let cutoff = Date().addingTimeInterval(-Double(live.historyDays) * 86_400)
        return messages.filter {
            live.permits($0.conversationGUID) && $0.sentAt >= cutoff
        }
    }

    func messages(in guid: String, after: Date, before: Date, limit: Int,
                  origin: MessagesOrigin) async throws -> [MessagesMessage] {
        let policy = try authorizedPolicy(origin: origin)
        guard policy.permits(guid) else { throw MessagesCapabilityError.conversationNotPermitted }
        let now = Date()
        let lower = max(after, now.addingTimeInterval(-Double(policy.historyDays) * 86_400))
        let upper = min(before, now)
        guard after < before, lower < upper,
              (1...100).contains(limit) else { throw MessagesCapabilityError.invalidRequest }
        let messages = try await reader.messages(
            in: guid, after: lower, before: upper, limit: limit
        )
        let live = try authorizedPolicy(origin: origin)
        guard live.permits(guid) else {
            throw MessagesCapabilityError.conversationNotPermitted
        }
        let cutoff = Date().addingTimeInterval(-Double(live.historyDays) * 86_400)
        return messages.filter { $0.sentAt >= cutoff }
    }

    func message(_ messageGUID: String, in conversationGUID: String,
                 origin: MessagesOrigin) async throws -> MessagesMessage {
        let policy = try authorizedPolicy(origin: origin)
        guard policy.permits(conversationGUID) else {
            throw MessagesCapabilityError.conversationNotPermitted
        }
        let end = Date()
        let message = try await reader.message(
            messageGUID, in: conversationGUID,
            after: end.addingTimeInterval(-Double(policy.historyDays) * 86_400),
            before: end
        )
        let live = try authorizedPolicy(origin: origin)
        guard live.permits(conversationGUID),
              message.sentAt >= Date().addingTimeInterval(
                -Double(live.historyDays) * 86_400
              ) else {
            throw MessagesCapabilityError.messageUnavailable
        }
        return message
    }

    func participants(in guid: String, origin: MessagesOrigin) async throws -> [String] {
        let policy = try authorizedPolicy(origin: origin)
        guard policy.permits(guid) else { throw MessagesCapabilityError.conversationNotPermitted }
        let participants = try await reader.participants(in: guid)
        guard try authorizedPolicy(origin: origin).permits(guid) else {
            throw MessagesCapabilityError.conversationNotPermitted
        }
        return participants
    }

    func attachments(for messageGUID: String, conversationGUID: String,
                     origin: MessagesOrigin) async throws -> [MessagesAttachment] {
        _ = try await message(messageGUID, in: conversationGUID, origin: origin)
        let attachments = try await reader.attachments(for: messageGUID, in: conversationGUID)
        guard try authorizedPolicy(origin: origin).permits(conversationGUID) else {
            throw MessagesCapabilityError.conversationNotPermitted
        }
        return attachments
    }

    private func authorizedPolicy(origin: MessagesOrigin) throws -> MessagesCapabilityPolicy {
        let policy = MessagesCapabilityPolicyStore.load()
        guard policy.readEnabled else { throw MessagesCapabilityError.readingDisabled }
        if case .ai = origin {
            guard policy.aiReadEnabled else { throw MessagesCapabilityError.aiReadingDisabled }
        }
        // Extension commands receive no implicit history grant from the user's UI selection.
        if case .extensionCommand = origin { throw MessagesCapabilityError.conversationNotPermitted }
        return policy
    }
}
