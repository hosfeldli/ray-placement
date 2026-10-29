import AppKit
import EventKit
import Foundation
import RayPlacementCore

/// One host path for native UI, extension, and AI operations. The caller may
/// propose a call, but only this object resolves installed extension state,
/// current OS access, and the final service implementation.
@MainActor
final class NativeCapabilityRouter {
    static let shared = NativeCapabilityRouter()

    enum RoutingError: LocalizedError {
        case invalidArguments
        case unavailable
        case aiDisabled
        case screenshotAccessDisabled
        case extensionChanged
        case clipboardFailed

        var errorDescription: String? {
            switch self {
            case .invalidArguments: return "The native operation arguments are invalid."
            case .unavailable: return "This native operation is not available yet."
            case .aiDisabled: return "Lima AI access is disabled."
            case .screenshotAccessDisabled: return "Screenshot History access is disabled for Lima AI. Enable Screenshot History and its metadata tool before attaching a saved capture."
            case .extensionChanged: return "The extension changed or is no longer approved. Reload and review it again."
            case .clipboardFailed: return "The screenshot image could not be copied to the clipboard."
            }
        }
    }

    /// Operations absent from this set cannot be exposed by an AI definition or
    /// executed by an extension, even if its manifest declares the capability.
    static let supportedOperations: Set<NativeCapabilityOperation> = [
        .screenshotTargets, .screenshotCapture, .screenshotList, .screenshotSearch, .screenshotInfo,
        .screenshotReadImage, .screenshotCopy, .screenshotDelete,
        .audioListOutputs, .audioGetOutput, .audioSetOutput,
        .audioGetVolume, .audioSetVolume, .audioToggleMute,
        .networkTestStart, .networkTestStatus, .networkTestCancel,
        .networkTestHistory, .networkConnectionInfo,
        .calendarList, .calendarEvents, .calendarSearch, .calendarCheckConflicts,
        .calendarCreateEvent, .calendarUpdateEvent, .calendarDeleteEvent,
        .remindersListLists, .remindersSearch, .remindersList,
        .remindersCreate, .remindersUpdate, .remindersComplete,
        .remindersReopen, .remindersDelete,
        .contactsSearch, .contactsGet, .contactsFindEmail, .contactsFindPhone,
        .contactsCreate, .contactsUpdate, .locationCurrent
    ]

    private let authorizer = NativeCapabilityAuthorizer()
    private let audio = AudioOutputService()
    private var screenshotHistory: ScreenshotHistoryStore?

    private init() {}

    /// The host calls this only after its own exact-call review has completed.
    /// Execution never mints an approval for itself; the returned grant is
    /// fingerprinted to origin, operation, and arguments and consumed once.
    func recordReviewedCall(_ call: NativeCapabilityCall) async throws -> UUID {
        guard Self.supportedOperations.contains(call.operation) else {
            throw RoutingError.unavailable
        }
        switch call.origin {
        case .userInterface:
            throw NativeCapabilityAuthorizationError.invalidCall
        case .ai:
            guard AIRequestPolicy.shared.isEnabled else { throw RoutingError.aiDisabled }
        case .extensionCommand:
            // Pixel handoff is AI-only. Extension commands cannot claim this
            // operation merely by declaring screenCapture in a manifest.
            guard call.operation != .screenshotReadImage else {
                throw NativeCapabilityAuthorizationError.invalidCall
            }
            guard try currentExtensionAuthority(for: call)?.approved == true else {
                throw RoutingError.extensionChanged
            }
        }
        return try await authorizer.recordExplicitApproval(for: call)
    }

    func execute(_ call: NativeCapabilityCall,
                 approvalID: UUID? = nil) async throws -> JSONValue {
        guard Self.supportedOperations.contains(call.operation),
              call.operation != .screenshotReadImage else {
            throw RoutingError.unavailable
        }
        if case .ai = call.origin {
            guard AIRequestPolicy.shared.isEnabled else { throw RoutingError.aiDisabled }
        }
        let installed = try currentExtensionAuthority(for: call)
        try await authorizer.authorize(
            call, approvalID: approvalID, installedExtension: installed,
            // These services ask macOS only after the one-use Lima review is
            // consumed. Their dispatch methods enforce the resulting TCC state.
            osPermissionGranted: osPermissionGranted(for: call.operation) ||
                EventKitCapabilityService.supportedOperations.contains(call.operation) ||
                ContactsCapabilityService.supportedOperations.contains(call.operation) ||
                call.operation == .locationCurrent
        )
        return try await dispatch(call)
    }

    /// Deliver pixels only to the AI bridge after a consumed exact-call grant.
    /// The ordinary JSON router deliberately cannot return this operation.
    func executeReviewedScreenshotImage(
        _ call: NativeCapabilityCall, approvalID: UUID
    ) async throws -> ScreenshotProviderImage {
        guard call.operation == .screenshotReadImage,
              case .ai = call.origin,
              case .object(let args) = call.arguments,
              args.count == 1,
              let id = args.uuid("id") else { throw RoutingError.invalidArguments }
        guard AIRequestPolicy.shared.isEnabled else { throw RoutingError.aiDisabled }
        try await authorizer.authorize(
            call, approvalID: approvalID, installedExtension: nil,
            osPermissionGranted: true
        )
        return try await history().providerImage(for: id)
    }

    /// Local Note attachment is separate from visual-provider sharing. The
    /// Notes write has its own exact-call review, but Screenshot History must
    /// still be enabled in the current AI tool scope.
    func screenshotImageForNote(id: UUID) async throws -> (Data, ScreenshotImageFormat) {
        guard AIRequestPolicy.shared.isEnabled else { throw RoutingError.aiDisabled }
        guard AIComputerActionPolicy.shared.effectiveAccess(for: .screenshotHistory) != .disabled,
              LimaAIToolStore.shared.effectiveEnabledToolIDs.contains("screenshot_info") else {
            throw RoutingError.screenshotAccessDisabled
        }
        return try await history().boundedImageDataForNote(for: id)
    }

    func isSavedScreenshotCurrent(_ image: ScreenshotProviderImage) async -> Bool {
        guard AIRequestPolicy.shared.isEnabled,
              AIComputerActionPolicy.shared.effectiveAccess(for: .screenshotHistory) != .disabled,
              let store = try? history() else { return false }
        return await store.isProviderImageCurrent(image)
    }

    private func currentExtensionAuthority(for call: NativeCapabilityCall)
        throws -> NativeExtensionAuthoritySnapshot? {
        guard case .extensionCommand(let extensionID, let hash, let commandID) = call.origin else {
            return nil
        }
        let matches = ExtensionLoader().load(prepare: false, registerPackages: false).commands
            .filter { $0.extensionID == extensionID && $0.command.id == commandID }
        guard matches.count == 1, let current = matches.first,
              current.manifestHash == hash,
              current.command.action.type == .nativeCapability,
              current.command.action.operation == call.operation.rawValue,
              current.capabilities.contains(call.operation.capability),
              case .object(let supplied) = call.arguments else {
            throw RoutingError.extensionChanged
        }
        let expected = (current.command.action.parameters ?? [:]).mapValues(JSONValue.string)
        guard supplied == expected else { throw RoutingError.extensionChanged }
        let bundled = current.bundled || current.trust == .bundled || current.trust == .builtIn
        let approved = bundled || {
            guard let record = ExtensionApprovalStore.record(for: extensionID) else { return false }
            return record.manifestHash == hash &&
                record.capabilities.isSuperset(of: current.capabilities)
        }()
        return NativeExtensionAuthoritySnapshot(
            extensionID: extensionID, manifestHash: hash, approved: approved,
            capabilities: current.capabilities
        )
    }

    private func osPermissionGranted(for operation: NativeCapabilityOperation) -> Bool {
        switch operation {
        case .screenshotTargets, .screenshotCapture:
            return ScreenshotCaptureService.shared.hasScreenRecordingPermission
        case .calendarList, .calendarEvents, .calendarSearch, .calendarCheckConflicts,
             .calendarUpdateEvent, .calendarDeleteEvent, .calendarOpenEvent:
            if #available(macOS 14.0, *) {
                return EKEventStore.authorizationStatus(for: .event) == .fullAccess
            }
            return EKEventStore.authorizationStatus(for: .event) == .authorized
        case .calendarCreateEvent:
            if #available(macOS 14.0, *) {
                let status = EKEventStore.authorizationStatus(for: .event)
                return status == .fullAccess || status == .writeOnly
            }
            return EKEventStore.authorizationStatus(for: .event) == .authorized
        case .remindersListLists, .remindersSearch, .remindersList,
             .remindersCreate, .remindersUpdate, .remindersComplete,
             .remindersReopen, .remindersDelete:
            if #available(macOS 14.0, *) {
                return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
            }
            return EKEventStore.authorizationStatus(for: .reminder) == .authorized
        default:
            // No macOS TCC category exists for Core Audio output control,
            // local Screenshot History, or a user-approved speed test.
            return true
        }
    }

    private func history() throws -> ScreenshotHistoryStore {
        if let screenshotHistory { return screenshotHistory }
        let store = try ScreenshotHistoryStore()
        screenshotHistory = store
        return store
    }

    private func dispatch(_ call: NativeCapabilityCall) async throws -> JSONValue {
        guard case .object(let args) = call.arguments else { throw RoutingError.invalidArguments }
        if EventKitCapabilityService.supportedOperations.contains(call.operation) {
            return try await EventKitCapabilityService.shared.execute(call.operation, arguments: args)
        }
        if ContactsCapabilityService.supportedOperations.contains(call.operation) {
            return try await ContactsCapabilityService.shared.execute(call.operation, arguments: args)
        }
        if call.operation == .locationCurrent {
            guard args.isEmpty else { throw RoutingError.invalidArguments }
            return try await CurrentLocationCapabilityService.shared.currentLocation()
        }
        switch call.operation {
        case .audioListOutputs:
            return .object(["outputs": .array(try audio.listOutputs().map(audioJSON))])
        case .audioGetOutput:
            return audioJSON(try audio.currentOutput())
        case .audioSetOutput:
            guard let uid = args.string("uid"), !uid.isEmpty else { throw RoutingError.invalidArguments }
            return audioJSON(try await audio.setOutput(uid: uid))
        case .audioGetVolume:
            return .object(["percent": try audio.getVolume().map { .number(Double($0)) } ?? .null])
        case .audioSetVolume:
            guard let percent = args.integer("percent") else { throw RoutingError.invalidArguments }
            return .object(["percent": .number(Double(try audio.setVolume(percent)))])
        case .audioToggleMute:
            return .object(["muted": .bool(try audio.toggleMute())])
        case .networkTestStart:
            let id = try NetworkQualityService.shared.start()
            return .object(["run_id": .string(id.uuidString), "state": .string("running"),
                            "method": .string("macOS networkQuality")])
        case .networkTestStatus:
            let service = NetworkQualityService.shared
            return .object([
                "state": .string(service.phase.rawValue),
                "run_id": service.activeRunID.map { .string($0.uuidString) } ?? .null,
                "started_at": service.startedAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
                "latest_result": service.latestResult.map(networkJSON) ?? .null,
                "error": service.errorMessage.map(JSONValue.string) ?? .null
            ])
        case .networkTestCancel:
            guard let id = args.uuid("run_id"),
                  NetworkQualityService.shared.activeRunID == id else {
                throw RoutingError.invalidArguments
            }
            NetworkQualityService.shared.cancel()
            return .object(["run_id": .string(id.uuidString), "state": .string("cancelling")])
        case .networkTestHistory:
            let results = NetworkQualityService.shared.results.prefix(args.boundedLimit)
            return .object(["results": .array(results.map(networkJSON))])
        case .networkConnectionInfo:
            let service = NetworkQualityService.shared
            service.refreshConnection()
            return .object(["connection": .string(service.connectionDescription),
                            "source": .string("macOS network path monitor")])
        case .screenshotTargets:
            let targets = try await eligibleScreenshotTargets()
            return .object(["targets": .array(targets.prefix(100).map { target in
                .object([
                    "id": .string(target.id),
                    "title": .string(target.title),
                    "kind": .string(target.kind == .display ? "display" : "window"),
                    "source_application": target.sourceApplication.map(JSONValue.string) ?? .null
                ])
            })])
        case .screenshotCapture:
            guard let targetID = args.string("target_id"),
                  let target = try await eligibleScreenshotTargets().first(where: { $0.id == targetID }) else {
                throw ScreenshotCaptureError.targetDisappeared
            }
            let image = try await ScreenshotCaptureService.shared.capture(target.target)
            let record = try await history().importImage(
                image.pngData, format: .png, metadata: image.metadata,
                recognizeText: LimaTestEnvironment.userDefaults.bool(forKey: "lima.screenshot.localOCR")
            )
            return .object([
                "capture": screenshotJSON(record),
                "saved_to_history": .bool(true),
                "image_pixels_returned": .bool(false)
            ])
        case .screenshotList:
            let records = try await history().recent(limit: args.boundedLimit)
            return .object(["captures": .array(records.map(screenshotJSON))])
        case .screenshotSearch:
            guard let query = args.string("query"), !query.isEmpty else { throw RoutingError.invalidArguments }
            let records = try await history().search(query, limit: args.boundedLimit)
            return .object(["captures": .array(records.map(screenshotJSON))])
        case .screenshotInfo:
            guard let id = args.uuid("id"),
                  let record = try await history().record(id: id) else {
                throw ScreenshotHistoryError.notFound
            }
            return screenshotJSON(record)
        case .screenshotCopy:
            guard let id = args.uuid("id") else { throw RoutingError.invalidArguments }
            let (data, format) = try await history().imageData(for: id)
            guard ScreenshotClipboard.copy(data, format: format) else { throw RoutingError.clipboardFailed }
            return .object(["copied": .bool(true), "id": .string(id.uuidString)])
        case .screenshotDelete:
            guard let id = args.uuid("id") else { throw RoutingError.invalidArguments }
            try await history().delete(id: id)
            return .object(["deleted": .bool(true), "id": .string(id.uuidString)])
        default:
            throw RoutingError.unavailable
        }
    }

    private func eligibleScreenshotTargets() async throws -> [ScreenshotCaptureTargetInfo] {
        try await ScreenshotCaptureService.shared.availableTargets().filter {
            $0.kind == .display || $0.sourceBundleID != Bundle.main.bundleIdentifier
        }
    }

    private func audioJSON(_ device: AudioOutputDevice) -> JSONValue {
        .object([
            "uid": .string(device.uid),
            "name": .string(device.name),
            "is_default": .bool(device.isDefault)
        ])
    }

    private func networkJSON(_ result: NetworkQualityResult) -> JSONValue {
        .object([
            "id": .string(result.id.uuidString),
            "started_at": .string(ISO8601DateFormatter().string(from: result.startedAt)),
            "duration_seconds": .number(result.durationSeconds),
            "download_mbps": .number(result.downloadMbps),
            "upload_mbps": .number(result.uploadMbps),
            "idle_latency_ms": result.idleLatencyMilliseconds.map(JSONValue.number) ?? .null,
            "responsiveness": result.responsiveness.map(JSONValue.string) ?? .null,
            "interface": result.interfaceName.map(JSONValue.string) ?? .null,
            "method": .string(result.method)
        ])
    }

    private func screenshotJSON(_ record: ScreenshotRecord) -> JSONValue {
        .object([
            "id": .string(record.id.uuidString),
            "captured_at": .string(ISO8601DateFormatter().string(from: record.capturedAt)),
            "source_application": record.sourceApplication.map(JSONValue.string) ?? .null,
            "window_title": record.windowTitle.map(JSONValue.string) ?? .null,
            "category": .string(record.category.rawValue),
            "tags": .array(record.tags.map(JSONValue.string)),
            "recognized_text": record.recognizedText.map(JSONValue.string) ?? .null,
            "pixel_width": .number(Double(record.pixelWidth)),
            "pixel_height": .number(Double(record.pixelHeight)),
            "is_pinned": .bool(record.isPinned)
        ])
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? {
        guard case .string(let value)? = self[key] else { return nil }
        return value
    }

    func integer(_ key: String) -> Int? {
        guard case .number(let value)? = self[key],
              value.isFinite, value.rounded(.towardZero) == value,
              value >= Double(Int.min), value <= Double(Int.max) else { return nil }
        return Int(value)
    }

    func uuid(_ key: String) -> UUID? {
        string(key).flatMap(UUID.init(uuidString:))
    }

    var boundedLimit: Int { Swift.min(100, Swift.max(1, integer("limit") ?? 30)) }
}
