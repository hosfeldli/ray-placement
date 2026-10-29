import CryptoKit
import Foundation

/// Host-side authority for native operations. Manifest declarations never grant execution.
public enum NativeCapabilityOperation: String, Codable, CaseIterable, Sendable {
    case screenshotTargets, screenshotCapture, screenshotList, screenshotSearch, screenshotInfo
    case screenshotReadImage, screenshotCopy, screenshotSave, screenshotDelete
    case audioListOutputs, audioGetOutput, audioSetOutput
    case audioGetVolume, audioSetVolume, audioToggleMute
    case networkTestStart, networkTestStatus, networkTestCancel
    case networkTestHistory, networkConnectionInfo
    case calendarList, calendarEvents, calendarSearch, calendarCheckConflicts
    case calendarCreateEvent, calendarUpdateEvent, calendarDeleteEvent, calendarOpenEvent
    case remindersListLists, remindersSearch, remindersList
    case remindersCreate, remindersUpdate, remindersComplete
    case remindersReopen, remindersDelete
    case contactsSearch, contactsGet, contactsFindEmail, contactsFindPhone
    case contactsCreate, contactsUpdate
    case locationCurrent

    public var capability: ExtensionManifest.Capability {
        switch self {
        case .screenshotTargets, .screenshotCapture, .screenshotList, .screenshotSearch, .screenshotInfo,
             .screenshotReadImage, .screenshotCopy, .screenshotSave, .screenshotDelete: return .screenCapture
        case .audioListOutputs, .audioGetOutput, .audioSetOutput,
             .audioGetVolume, .audioSetVolume, .audioToggleMute: return .audioOutput
        case .networkTestStart, .networkTestStatus, .networkTestCancel,
             .networkTestHistory, .networkConnectionInfo: return .networkQuality
        case .calendarList, .calendarEvents, .calendarSearch, .calendarCheckConflicts,
             .calendarCreateEvent, .calendarUpdateEvent, .calendarDeleteEvent,
             .calendarOpenEvent: return .calendar
        case .remindersListLists, .remindersSearch, .remindersList,
             .remindersCreate, .remindersUpdate, .remindersComplete,
             .remindersReopen, .remindersDelete: return .reminders
        case .contactsSearch, .contactsGet, .contactsFindEmail, .contactsFindPhone,
             .contactsCreate, .contactsUpdate: return .contacts
        case .locationCurrent: return .location
        }
    }
}

public enum NativeCapabilityOrigin: Codable, Equatable, Sendable {
    case userInterface(surfaceID: String)
    case ai(runID: UUID, toolCallID: String)
    case extensionCommand(extensionID: String, manifestHash: String, commandID: String)
}

public struct NativeCapabilityCall: Sendable {
    public let origin: NativeCapabilityOrigin
    public let operation: NativeCapabilityOperation
    public let arguments: JSONValue

    public init(origin: NativeCapabilityOrigin,
                operation: NativeCapabilityOperation,
                arguments: JSONValue) {
        self.origin = origin
        self.operation = operation
        self.arguments = arguments
    }

    fileprivate func fingerprint() throws -> Data {
        struct Envelope: Encodable {
            let origin: NativeCapabilityOrigin
            let operation: NativeCapabilityOperation
            let arguments: JSONValue
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(
            origin: origin, operation: operation, arguments: arguments
        ))
        return Data(SHA256.hash(data: data))
    }
}

/// Obtain from the installed approved-package record at execution time.
public struct NativeExtensionAuthoritySnapshot: Sendable {
    public let extensionID: String
    public let manifestHash: String
    public let approved: Bool
    public let capabilities: Set<ExtensionManifest.Capability>

    public init(extensionID: String, manifestHash: String, approved: Bool,
                capabilities: Set<ExtensionManifest.Capability>) {
        self.extensionID = extensionID
        self.manifestHash = manifestHash
        self.approved = approved
        self.capabilities = capabilities
    }
}

public enum NativeCapabilityAuthorizationError: LocalizedError, Equatable, Sendable {
    case invalidCall
    case approvalRequired
    case approvalExpired
    case extensionNotApproved
    case osPermissionDenied

    public var errorDescription: String? {
        switch self {
        case .invalidCall:
            return "The native operation request is invalid."
        case .approvalRequired:
            return "This native operation needs a fresh exact-call Allow Once review."
        case .approvalExpired:
            return "The native operation review expired. Review the exact call again."
        case .extensionNotApproved:
            return "The extension is not currently approved for this native capability."
        case .osPermissionDenied:
            return "macOS privacy access for this native operation is not granted. Enable it in System Settings and retry."
        }
    }
}

/// The trusted host records a user's approval. AI and extension calls consume
/// one matching grant; a mutation to origin, operation or arguments fails closed.
public actor NativeCapabilityAuthorizer {
    private struct Grant {
        let fingerprint: Data
        let expiresAt: Date
    }

    private var grants: [UUID: Grant] = [:]
    private let lifetime: TimeInterval

    public init(lifetime: TimeInterval = 120) {
        self.lifetime = max(1, min(lifetime, 300))
    }

    @discardableResult
    public func recordExplicitApproval(for call: NativeCapabilityCall,
                                       now: Date = Date()) throws -> UUID {
        guard case .object = call.arguments else {
            throw NativeCapabilityAuthorizationError.invalidCall
        }
        switch call.origin {
        case .userInterface:
            throw NativeCapabilityAuthorizationError.invalidCall
        case .ai(_, let callID):
            guard !callID.isEmpty else { throw NativeCapabilityAuthorizationError.invalidCall }
        case .extensionCommand(let extensionID, let hash, let commandID):
            guard !extensionID.isEmpty, !hash.isEmpty, !commandID.isEmpty else {
                throw NativeCapabilityAuthorizationError.invalidCall
            }
        }
        grants = grants.filter { $0.value.expiresAt >= now }
        let id = UUID()
        grants[id] = Grant(fingerprint: try call.fingerprint(),
                           expiresAt: now.addingTimeInterval(lifetime))
        return id
    }

    public func authorize(_ call: NativeCapabilityCall,
                          approvalID: UUID? = nil,
                          installedExtension: NativeExtensionAuthoritySnapshot? = nil,
                          osPermissionGranted: Bool,
                          now: Date = Date()) throws {
        guard case .object = call.arguments else {
            throw NativeCapabilityAuthorizationError.invalidCall
        }
        if case .extensionCommand(let extensionID, let hash, let commandID) = call.origin {
            guard !extensionID.isEmpty, !hash.isEmpty, !commandID.isEmpty,
                  let installedExtension,
                  installedExtension.approved,
                  installedExtension.extensionID == extensionID,
                  installedExtension.manifestHash == hash,
                  installedExtension.capabilities.contains(call.operation.capability) else {
                throw NativeCapabilityAuthorizationError.extensionNotApproved
            }
        }
        switch call.origin {
        case .userInterface(let surfaceID):
            guard !surfaceID.isEmpty else {
                throw NativeCapabilityAuthorizationError.invalidCall
            }
        case .ai, .extensionCommand:
            guard let approvalID, let grant = grants.removeValue(forKey: approvalID) else {
                throw NativeCapabilityAuthorizationError.approvalRequired
            }
            guard now <= grant.expiresAt else {
                throw NativeCapabilityAuthorizationError.approvalExpired
            }
            guard try call.fingerprint() == grant.fingerprint else {
                throw NativeCapabilityAuthorizationError.approvalRequired
            }
        }
        guard osPermissionGranted else {
            throw NativeCapabilityAuthorizationError.osPermissionDenied
        }
    }

    public func revokeAll() { grants.removeAll() }
}
