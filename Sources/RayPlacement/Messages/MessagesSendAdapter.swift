import AppKit
import CryptoKit
import Foundation
import RayPlacementCore

enum MessagesDestination: Codable, Hashable, Sendable {
    case existingConversation(guid: String, participants: [String])
    case direct(address: String, serviceID: String)

    var displayAddress: String {
        switch self {
        case .existingConversation(_, let participants): return participants.joined(separator: ", ")
        case .direct(let address, _): return address
        }
    }
}

struct MessagesOutgoingRequest: Codable, Hashable, Sendable {
    let destination: MessagesDestination
    let text: String

    func validate() throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 32 * 1_024,
              !text.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) &&
                      $0.value != 9 && $0.value != 10 && $0.value != 13
              }) else { throw MessagesCapabilityError.invalidRequest }
        switch destination {
        case .existingConversation(let guid, let participants):
            guard !guid.isEmpty, guid.utf8.count <= 512,
                  !participants.isEmpty, participants.count <= 32,
                  participants.allSatisfy(Self.isAddress),
                  Set(participants.map { $0.lowercased() }).count == participants.count else {
                throw MessagesCapabilityError.invalidRequest
            }
        case .direct(let address, let serviceID):
            guard Self.isAddress(address), !serviceID.isEmpty,
                  serviceID.utf8.count <= 256 else {
                throw MessagesCapabilityError.invalidRequest
            }
        }
    }

    private static func isAddress(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 320 &&
        !value.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
        })
    }
}

struct MessagesOutgoingReview: Identifiable, Sendable {
    let id: UUID
    let request: MessagesOutgoingRequest
    let expiresAt: Date
}

enum MessagesSendJournal {
    private struct State: Codable {
        let salt: Data
        var pending: Set<String>
    }

    private static let url = ApplicationPaths.applicationSupport
        .appendingPathComponent("Messages", isDirectory: true)
        .appendingPathComponent("pending-sends.json")
    private static let files = PrivateFileStore()

    static func markPending(_ request: MessagesOutgoingRequest) throws -> String {
        var state = try load() ?? State(
            salt: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }),
            pending: []
        )
        let digest = try fingerprint(request, salt: state.salt)
        guard !state.pending.contains(digest) else {
            throw MessagesCapabilityError.sendOutcomeUncertain
        }
        guard state.pending.count < 256 else {
            throw MessagesCapabilityError.journalUnavailable
        }
        state.pending.insert(digest)
        do {
            try files.write(state, to: url, backupExisting: false)
        } catch {
            throw MessagesCapabilityError.journalUnavailable
        }
        return digest
    }

    static func clearResolved(_ digest: String) throws {
        guard var state = try load(), state.pending.contains(digest) else {
            throw MessagesCapabilityError.journalUnavailable
        }
        state.pending.remove(digest)
        do {
            try files.write(state, to: url, backupExisting: false)
        } catch {
            throw MessagesCapabilityError.journalUnavailable
        }
    }

    private static func load() throws -> State? {
        let loaded = files.loadJSON(State.self, from: url)
        switch loaded.result.state {
        case .missing: return nil
        case .loaded:
            guard let state = loaded.value, state.salt.count == 32,
                  state.pending.count <= 256,
                  state.pending.allSatisfy({
                      $0.count == 64 && $0.allSatisfy(\.isHexDigit)
                  }) else {
                throw MessagesCapabilityError.journalUnavailable
            }
            return state
        case .corrupt, .unreadable:
            throw MessagesCapabilityError.journalUnavailable
        }
    }

    private static func fingerprint(_ request: MessagesOutgoingRequest,
                                    salt: Data) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(request)
        return SHA256.hash(data: salt + payload)
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// The only Messages Apple Events endpoint. Script source is fixed; destination
/// and user text are Apple Event arguments, never process argv or script source.
actor MessagesSendAdapter {
    static let shared = MessagesSendAdapter()
    private let queue = DispatchQueue(label: "dev.liam.lima.messages.apple-events", qos: .utility)

    private static let sendScript = """
        on sendmessage(targetKind, targetID, serviceID, messageText)
            with timeout of 15 seconds
                tell application id "com.apple.iChat"
                    if targetKind is "chat" then
                        set matches to every chat whose id is targetID
                        if (count of matches) is not 1 then error "The selected chat is unavailable."
                        send messageText to item 1 of matches
                    else
                        set matches to every service whose id is serviceID
                        if (count of matches) is not 1 then error "The selected service is unavailable."
                        set recipient to buddy targetID of item 1 of matches
                        send messageText to recipient
                    end if
                end tell
            end timeout
            return "LIMA_ACCEPTED"
        end sendmessage
        """

    func send(_ request: MessagesOutgoingRequest) async throws -> Date {
        try request.validate()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Self.run(request))
            }
        }
    }

    private nonisolated static func run(_ request: MessagesOutgoingRequest) -> Result<Date, Error> {
        let kind: String
        let target: String
        let service: String
        switch request.destination {
        case .existingConversation(let guid, _):
            kind = "chat"; target = guid; service = ""
        case .direct(let address, let serviceID):
            kind = "direct"; target = address; service = serviceID
        }
        guard let script = NSAppleScript(source: sendScript) else {
            return .failure(MessagesCapabilityError.sendOutcomeUncertain)
        }
        // ascr/psbr invokes a named handler in this fixed local script. Neither
        // the recipient nor text is interpolated into executable AppleScript.
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: 0x61736372, eventID: 0x70736272,
            targetDescriptor: .null(), returnID: -1, transactionID: 0
        )
        let arguments = NSAppleEventDescriptor.list()
        for (index, value) in [kind, target, service, request.text].enumerated() {
            arguments.insert(NSAppleEventDescriptor(string: value), at: index + 1)
        }
        event.setParam(NSAppleEventDescriptor(string: "sendmessage"),
                       forKeyword: 0x736e616d)
        event.setParam(arguments, forKeyword: 0x2d2d2d2d)
        var errorInfo: NSDictionary?
        let result = script.executeAppleEvent(event, error: &errorInfo)
        if let errorInfo {
            // The error dictionary can contain private message text. Never log it.
            if errorInfo["NSAppleScriptErrorNumber"] as? Int == -1743 {
                return .failure(MessagesCapabilityError.automationDenied)
            }
            return .failure(MessagesCapabilityError.sendOutcomeUncertain)
        }
        guard result.stringValue == "LIMA_ACCEPTED" else {
            return .failure(MessagesCapabilityError.sendOutcomeUncertain)
        }
        return .success(Date())
    }
}

/// A one-shot visible review is the only route to a native send. A timeout or
/// process failure leaves the salted digest pending; no automatic replay occurs.
actor MessagesOutgoingCoordinator {
    static let shared = MessagesOutgoingCoordinator()
    private var reviews: [UUID: MessagesOutgoingReview] = [:]

    func prepare(_ request: MessagesOutgoingRequest,
                 origin: MessagesOrigin) throws -> MessagesOutgoingReview {
        let policy = MessagesCapabilityPolicyStore.load()
        guard policy.sendEnabled else { throw MessagesCapabilityError.sendingDisabled }
        switch origin {
        case .userInterface: break
        case .ai:
            guard policy.aiComposeEnabled else { throw MessagesCapabilityError.sendingDisabled }
        case .extensionCommand:
            throw MessagesCapabilityError.reviewRequired
        }
        try request.validate()
        let now = Date()
        reviews = reviews.filter { $0.value.expiresAt > now }
        guard reviews.count < 20 else { throw MessagesCapabilityError.reviewRequired }
        let review = MessagesOutgoingReview(
            id: UUID(), request: request, expiresAt: now.addingTimeInterval(120)
        )
        reviews[review.id] = review
        return review
    }

    func discard(_ id: UUID) {
        reviews.removeValue(forKey: id)
    }

    func sendReviewed(_ review: MessagesOutgoingReview,
                      origin: MessagesOrigin) async throws -> Date {
        guard case .userInterface = origin else { throw MessagesCapabilityError.reviewRequired }
        guard let stored = reviews.removeValue(forKey: review.id),
              stored.request == review.request else { throw MessagesCapabilityError.reviewMismatch }
        guard stored.expiresAt > Date() else { throw MessagesCapabilityError.reviewExpired }
        guard MessagesCapabilityPolicyStore.load().sendEnabled else {
            throw MessagesCapabilityError.sendingDisabled
        }
        try review.request.validate()
        if case .existingConversation(let guid, let participants) = review.request.destination {
            let current = try await MessagesCapabilityService.shared.participants(
                in: guid, origin: .userInterface
            )
            guard Set(current.map { $0.lowercased() }) ==
                  Set(participants.map { $0.lowercased() }) else {
                throw MessagesCapabilityError.destinationChanged
            }
        }
        let live = MessagesCapabilityPolicyStore.load()
        guard !Task.isCancelled, live.sendEnabled else {
            throw MessagesCapabilityError.sendingDisabled
        }
        if case .existingConversation(let guid, _) = review.request.destination {
            guard live.permits(guid) else {
                throw MessagesCapabilityError.conversationNotPermitted
            }
        }
        let digest = try MessagesSendJournal.markPending(review.request)
        do {
            let acceptedAt = try await MessagesSendAdapter.shared.send(review.request)
            try MessagesSendJournal.clearResolved(digest)
            return acceptedAt
        } catch MessagesCapabilityError.automationDenied {
            // TCC refused the Apple Event before Messages could process a send.
            try MessagesSendJournal.clearResolved(digest)
            throw MessagesCapabilityError.automationDenied
        } catch {
            // Any other Apple Events failure could occur after Messages
            // accepted a send. Keep the journal entry until user reconciliation.
            throw error
        }
    }
}

extension MessagesCapabilityService {
    func prepareOutgoing(_ request: MessagesOutgoingRequest,
                         origin: MessagesOrigin) async throws -> MessagesOutgoingReview {
        try await MessagesOutgoingCoordinator.shared.prepare(request, origin: origin)
    }

    func discardOutgoingReview(_ id: UUID) async {
        await MessagesOutgoingCoordinator.shared.discard(id)
    }

    func sendReviewed(_ review: MessagesOutgoingReview,
                      origin: MessagesOrigin) async throws -> Date {
        try await MessagesOutgoingCoordinator.shared.sendReviewed(review, origin: origin)
    }
}
