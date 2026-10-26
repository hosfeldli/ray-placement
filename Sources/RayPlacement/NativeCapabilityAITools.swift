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
        "network_connection_info": .networkConnectionInfo,
        "calendar_list": .calendarList,
        "calendar_events": .calendarEvents,
        "calendar_search": .calendarSearch,
        "calendar_check_conflicts": .calendarCheckConflicts,
        "calendar_create_event": .calendarCreateEvent,
        "calendar_update_event": .calendarUpdateEvent,
        "calendar_delete_event": .calendarDeleteEvent,
        "reminders_list_lists": .remindersListLists,
        "reminders_search": .remindersSearch,
        "reminders_list": .remindersList,
        "reminders_create": .remindersCreate,
        "reminders_update": .remindersUpdate,
        "reminders_complete": .remindersComplete,
        "reminders_reopen": .remindersReopen,
        "reminders_delete": .remindersDelete,
        "location_current": .locationCurrent
    ]

    static let ids = Set(operations.keys)
    nonisolated static let calendarIDs: Set<String> = ["calendar_list", "calendar_events", "calendar_search",
        "calendar_check_conflicts", "calendar_create_event", "calendar_update_event", "calendar_delete_event"]
    nonisolated static let reminderIDs: Set<String> = ["reminders_list_lists", "reminders_search", "reminders_list",
        "reminders_create", "reminders_update", "reminders_complete", "reminders_reopen", "reminders_delete"]
    nonisolated static let locationIDs: Set<String> = ["location_current"]

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

    private static let isoTime: [String: Any] = [
        "type": "string",
        "description": "ISO 8601 date-time with explicit timezone, e.g. 2026-10-25T14:00:00-04:00."
    ]
    private static let calendarID: [String: Any] = ["type": "string", "description": "ID returned by calendar_list."]
    private static let listID: [String: Any] = ["type": "string", "description": "ID returned by reminders_list_lists."]
    private static let eventID: [String: Any] = ["type": "string", "description": "ID returned by calendar_events or calendar_create_event."]
    private static let reminderID: [String: Any] = ["type": "string", "description": "ID returned by reminders_list or reminders_create."]
    private static let boundedTitle: [String: Any] = ["type": "string", "description": "Nonempty title or query; host enforces length limits."]
    private static let optionalText: [String: Any] = ["type": ["string", "null"]]

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
             category: .networkQuality),
        tool("calendar_list", "List the user's EventKit calendars and writable status after exact-call review.",
             category: .calendar),
        tool("calendar_events", "Read up to 100 calendar events in a bounded 90-day interval. Use calendar_list for a specific calendar.",
             ["from": isoTime, "to": isoTime, "calendar_id": calendarID],
             required: ["from", "to"], category: .calendar),
        tool("calendar_search", "Search titles, locations, and notes in a bounded calendar interval.",
             ["query": boundedTitle, "from": isoTime, "to": isoTime, "calendar_id": calendarID],
             required: ["query", "from", "to"], category: .calendar),
        tool("calendar_check_conflicts", "Check for timed events overlapping a proposed interval; does not change the calendar.",
             ["from": isoTime, "to": isoTime, "calendar_id": calendarID],
             required: ["from", "to"], category: .calendar),
        tool("calendar_create_event", "Create one calendar event after exact-call review. Use calendar_list first if the user named a specific calendar. Does not invite attendees or create recurrence.",
             ["title": boundedTitle, "from": isoTime, "to": isoTime, "calendar_id": calendarID,
              "all_day": ["type": "boolean"], "location": optionalText, "notes": optionalText],
             required: ["title", "from", "to"], risk: .write, category: .calendar),
        tool("calendar_update_event", "Update one nonrecurring event by a freshly observed EventKit ID. Null fields are unchanged; clear_location and clear_notes explicitly remove values.",
             ["event_id": eventID, "expected_title": boundedTitle, "title": boundedTitle, "from": isoTime, "to": isoTime,
              "calendar_id": calendarID, "all_day": ["type": "boolean"],
              "location": optionalText, "notes": optionalText,
              "clear_location": ["type": "boolean"], "clear_notes": ["type": "boolean"]],
             required: ["event_id", "expected_title"], risk: .write, category: .calendar),
        tool("calendar_delete_event", "Delete one nonrecurring calendar event by exact EventKit ID and previously observed title after review.",
             ["event_id": eventID, "expected_title": boundedTitle],
             required: ["event_id", "expected_title"], risk: .destructive, category: .calendar),
        tool("reminders_list_lists", "List Apple Reminders lists and their writable status.",
             category: .reminders),
        tool("reminders_list", "List up to 100 reminders in one list or across all lists; completed items are excluded unless requested.",
             ["list_id": listID, "include_completed": ["type": "boolean"]], category: .reminders),
        tool("reminders_search", "Search reminder titles and notes in one list or across all lists.",
             ["query": boundedTitle, "list_id": listID, "include_completed": ["type": "boolean"]],
             required: ["query"], category: .reminders),
        tool("reminders_create", "Create one Apple Reminder after exact-call review. A due time also creates one notification alarm. Use reminders_list_lists if the user named a list.",
             ["title": boundedTitle, "notes": optionalText, "due_at": isoTime, "list_id": listID],
             required: ["title"], risk: .write, category: .reminders),
        tool("reminders_update", "Update one reminder by a freshly observed ID. Null fields are unchanged; clear_notes and clear_due explicitly remove values. Changing due_at moves its due-time alarm while preserving other alarms.",
             ["reminder_id": reminderID, "expected_title": boundedTitle, "title": boundedTitle, "notes": optionalText,
              "due_at": isoTime, "list_id": listID,
              "clear_notes": ["type": "boolean"], "clear_due": ["type": "boolean"]],
             required: ["reminder_id", "expected_title"], risk: .write, category: .reminders),
        tool("reminders_complete", "Mark one reminder complete by exact ID and previously observed title.",
             ["reminder_id": reminderID, "expected_title": boundedTitle],
             required: ["reminder_id", "expected_title"], risk: .write, category: .reminders),
        tool("reminders_reopen", "Reopen one completed reminder by exact ID and previously observed title.",
             ["reminder_id": reminderID, "expected_title": boundedTitle],
             required: ["reminder_id", "expected_title"], risk: .write, category: .reminders),
        tool("reminders_delete", "Permanently delete one reminder by exact ID and previously observed title.",
             ["reminder_id": reminderID, "expected_title": boundedTitle],
             required: ["reminder_id", "expected_title"], risk: .destructive, category: .reminders),
        tool("location_current", "Request one current location from macOS Location Services after exact-call review. Returns coordinates, accuracy, and observation time; Lima does not retain a location history.",
             category: .location)
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
