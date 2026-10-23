import Foundation
import RayPlacementCore

/// Opt-in AI entry points for operations already implemented by
/// NativeCapabilityRouter. Every call requires a trusted exact-call continuation,
/// including read-only calls and calls made in Full Control.
@MainActor
enum NativeCapabilityAITools {
    private static let operations: [String: NativeCapabilityOperation] = [
        "screenshot_targets": .screenshotTargets,
        "screenshot_capture": .screenshotCapture,
        "screenshot_list": .screenshotList,
        "screenshot_search": .screenshotSearch,
        "screenshot_info": .screenshotInfo,
        "screenshot_copy": .screenshotCopy,
        "screenshot_delete": .screenshotDelete,
        "audio_list_outputs": .audioListOutputs,
        "audio_get_output": .audioGetOutput,
        "audio_set_output": .audioSetOutput,
        "audio_get_volume": .audioGetVolume,
        "audio_set_volume": .audioSetVolume,
        "audio_toggle_mute": .audioToggleMute,
        "network_test_start": .networkTestStart,
        "network_test_status": .networkTestStatus,
        "network_test_cancel": .networkTestCancel,
        "network_test_history": .networkTestHistory,
        "network_connection_info": .networkConnectionInfo
    ]

    static let ids = Set(operations.keys)

    private struct ExactApproval {
        let toolID: String
        let arguments: String?
        let approvedAt: Date
    }

    /// An Allow Once decision is registered only by AIChat's UI continuation.
    /// A Boolean passed through another tool path is not itself authority.
    private static var exactApprovals: [UUID: [String: ExactApproval]] = [:]

    private static func discardExpiredApprovals(now: Date) {
        for runID in Array(exactApprovals.keys) {
            let fresh = exactApprovals[runID, default: [:]].filter { _, approval in
                now >= approval.approvedAt && now.timeIntervalSince(approval.approvedAt) <= 120
            }
            if fresh.isEmpty { exactApprovals.removeValue(forKey: runID) }
            else { exactApprovals[runID] = fresh }
        }
    }

    @discardableResult
    static func recordExactApproval(_ approval: AIToolApprovalRequest,
                                    call: AIOutputItem, runID: UUID?) -> Bool {
        let now = Date()
        discardExpiredApprovals(now: now)
        guard let runID, let callID = call.callID,
              let name = call.name,
              matchesApproval(approval, call: call, now: now) else { return false }
        exactApprovals[runID, default: [:]][callID] = ExactApproval(
            toolID: name, arguments: call.arguments, approvedAt: now
        )
        return true
    }

    static func consumeExactApproval(for call: AIOutputItem, runID: UUID?) -> Bool {
        let now = Date()
        discardExpiredApprovals(now: now)
        guard let runID, let callID = call.callID,
              let name = call.name,
              let approval = exactApprovals[runID]?.removeValue(forKey: callID) else { return false }
        if exactApprovals[runID]?.isEmpty == true { exactApprovals.removeValue(forKey: runID) }
        return approval.toolID == name && approval.arguments == call.arguments &&
            now >= approval.approvedAt && now.timeIntervalSince(approval.approvedAt) <= 120
    }

    /// Bind a native Allow Once decision to the exact provider call the user saw.
    /// A changed tool, call ID, argument string, or stale review fails closed.
    static func matchesApproval(_ approval: AIToolApprovalRequest,
                                call: AIOutputItem, now: Date = Date()) -> Bool {
        guard let name = call.name, ids.contains(name),
              let callID = call.callID, !callID.isEmpty,
              approval.decision == .pending,
              approval.localCallID == callID,
              approval.localToolID == name,
              approval.arguments == call.arguments,
              now >= approval.createdAt,
              now.timeIntervalSince(approval.createdAt) <= 120 else { return false }
        return true
    }

    private static func tool(_ id: String, _ description: String,
                             _ properties: [String: Any] = [:],
                             required: [String] = [],
                             risk: AILocalToolRisk = .read,
                             category: AIComputerActionCategory) -> LimaAIToolDefinition {
        LimaAIToolDefinition(
            id: id, name: id, description: description,
            parameters: [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false
            ],
            risk: risk, actionCategory: category
        )
    }

    private static let limit: [String: Any] = [
        "type": ["integer", "null"], "minimum": 1, "maximum": 100,
        "description": "Maximum items to return; defaults to 30."
    ]
    private static let screenshotID: [String: Any] = [
        "type": "string", "format": "uuid",
        "description": "Identifier of a saved Screenshot History capture."
    ]

    static let definitions: [LimaAIToolDefinition] = [
        tool("screenshot_targets", "List available display and window IDs and titles after exact-call review and macOS Screen Recording access; returns no pixels.",
             category: .screenCapture),
        tool("screenshot_capture", "Capture exactly one selected display or window and save it to persistent Screenshot History. May contain private screen content; requires exact-call review and macOS Screen Recording access. Returns metadata, not image pixels.",
             ["target_id": ["type": "string", "pattern": "^(display|window):[0-9]+$",
                            "description": "Exact ID returned by screenshot_targets."]],
             required: ["target_id"], risk: .localAction, category: .screenCapture),
        tool("screenshot_list", "List saved Screenshot History metadata; never returns image pixels.",
             ["limit": limit], category: .screenshotHistory),
        tool("screenshot_search", "Search saved Screenshot History metadata, tags, and local OCR text.",
             ["query": ["type": "string", "description": "Text to find in saved captures."],
              "limit": limit], required: ["query"], category: .screenshotHistory),
        tool("screenshot_info", "Read metadata for one saved Screenshot History capture, not the image pixels.",
             ["id": screenshotID], required: ["id"], category: .screenshotHistory),
        tool("screenshot_copy", "Copy one saved screenshot as actual image data to the system clipboard.",
             ["id": screenshotID], required: ["id"], risk: .localAction, category: .screenshotHistory),
        tool("screenshot_delete", "Permanently delete one saved screenshot and its thumbnail.",
             ["id": screenshotID], required: ["id"], risk: .destructive, category: .screenshotHistory),
        tool("audio_list_outputs", "List currently connected system audio output devices by stable UID.",
             category: .audioOutput),
        tool("audio_get_output", "Read the verified default system audio output device.",
             category: .audioOutput),
        tool("audio_set_output", "Set the system default audio output to a connected stable device UID and verify it.",
             ["uid": ["type": "string", "description": "Stable UID returned by audio_list_outputs."]],
             required: ["uid"], risk: .localAction, category: .audioOutput),
        tool("audio_get_volume", "Read the current system output volume when the device supports it.",
             category: .audioOutput),
        tool("audio_set_volume", "Set and verify the current system output volume from 0 to 100 percent.",
             ["percent": ["type": "integer", "minimum": 0, "maximum": 100]],
             required: ["percent"], risk: .localAction, category: .audioOutput),
        tool("audio_toggle_mute", "Toggle and verify system output mute when supported.",
             risk: .localAction, category: .audioOutput),
        tool("network_test_start", "Start an active macOS networkQuality bandwidth test. It may download and upload hundreds of megabytes; require the user's exact-call review.",
             risk: .localAction, category: .networkQuality),
        tool("network_test_status", "Read the current bandwidth-test state and latest measured result.",
             category: .networkQuality),
        tool("network_test_cancel", "Stop a running bandwidth test by its returned run ID.",
             ["run_id": ["type": "string", "format": "uuid"]],
             required: ["run_id"], risk: .localAction, category: .networkQuality),
        tool("network_test_history", "Read bounded locally saved network test measurements.",
             ["limit": limit], category: .networkQuality),
        tool("network_connection_info", "Read the currently observed connection type without running a bandwidth test.",
             category: .networkQuality)
    ]

    static func execute(_ call: AIOutputItem, approvalGranted: Bool,
                        runID: UUID?) async -> LimaAIToolExecution {
        guard let name = call.name,
              let operation = operations[name],
              NativeCapabilityRouter.supportedOperations.contains(operation),
              let callID = call.callID, !callID.isEmpty,
              let runID,
              let definition = definitions.first(where: { $0.id == name }),
              AIComputerActionPolicy.shared.permits(
                definition, approvalGranted: approvalGranted
              ),
              consumeExactApproval(for: call, runID: runID) else {
            return .json(["error": "This native operation is unavailable or needs exact-call approval in Lima Settings."], isError: true)
        }
        guard let raw = call.arguments, raw.utf8.count <= 16_384,
              let data = raw.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object = arguments else {
            return .json(["error": "The native operation arguments were invalid."], isError: true)
        }
        let nativeCall = NativeCapabilityCall(
            origin: .ai(runID: runID, toolCallID: callID),
            operation: operation, arguments: arguments
        )
        do {
            let approvalID = try await NativeCapabilityRouter.shared.recordReviewedCall(nativeCall)
            let result = try await NativeCapabilityRouter.shared.execute(
                nativeCall, approvalID: approvalID
            )
            let encoded = try JSONEncoder().encode(result)
            return LimaAIToolExecution(
                output: String(decoding: encoded, as: UTF8.self), isError: false
            )
        } catch {
            return .json(["error": error.localizedDescription], isError: true)
        }
    }
}
