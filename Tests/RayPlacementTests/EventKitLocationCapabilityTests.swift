import EventKit
import Foundation
import RayPlacementCore
import Testing
@testable import RayPlacement

@Test @MainActor func calendarRemindersAndLocationHaveStrictDiscoverableSchemas() throws {
    for (id, category, risk) in [
        ("calendar_create_event", AIComputerActionCategory.calendar, AILocalToolRisk.write),
        ("calendar_update_event", .calendar, .write),
        ("calendar_delete_event", .calendar, .destructive),
        ("reminders_create", .reminders, .write),
        ("reminders_update", .reminders, .write),
        ("reminders_complete", .reminders, .write),
        ("reminders_delete", .reminders, .destructive),
        ("location_current", .location, .read)
    ] {
        let tool = try #require(LimaAIToolRegistry.definition(for: id))
        #expect(tool.actionCategory == category)
        #expect(tool.risk == risk)
        #expect(tool.responsePayload != nil)
        #expect(AIComputerActionPolicy.shared.requiresApproval(for: tool, toolAccessMode: .fullControl))
    }
    let groups = LimaAIToolGroup.visibleGroups(for: NativeCapabilityAITools.definitions)
    #expect(groups.first { $0.id == "calendar" }?.toolIDs == NativeCapabilityAITools.calendarIDs)
    #expect(groups.first { $0.id == "reminders" }?.toolIDs == NativeCapabilityAITools.reminderIDs)
    #expect(groups.first { $0.id == "location" }?.toolIDs == NativeCapabilityAITools.locationIDs)
    #expect(NativeCapabilityOperation.locationCurrent.capability == .location)

    for id in ["calendar_update_event", "calendar_delete_event", "reminders_update",
               "reminders_complete", "reminders_reopen", "reminders_delete"] {
        let tool = try #require(LimaAIToolRegistry.definition(for: id))
        let required = try #require(tool.parameters["required"] as? [String])
        #expect(required.contains("expected_title"), "\(id) must identify the reviewed target by title")
        let properties = try #require(tool.parameters["properties"] as? [String: Any])
        #expect(properties["expected_title"] != nil)
    }
}

@Test @MainActor func calendarRemindersAndLocationCannotRunWithoutExactReview() async {
    let runID = UUID()
    for (name, arguments) in [
        ("calendar_create_event", #"{"title":"Review","from":"2026-10-25T14:00:00-04:00","to":"2026-10-25T15:00:00-04:00"}"#),
        ("reminders_create", #"{"title":"Review"}"#),
        ("location_current", "{}")
    ] {
        let call = AIOutputItem(
            phase: .completed, apiType: "function_call",
            callID: "unreviewed-\(name)", name: name, arguments: arguments
        )
        let denied = await NativeCapabilityAITools.execute(
            call, approvalGranted: true, runID: runID
        )
        #expect(denied.isError)
        #expect(denied.output.contains("exact-call approval"))
    }
}

@Test @MainActor func reminderDueChangePreservesUnrelatedAlarms() {
    let oldDue = Date(timeIntervalSince1970: 1_800_000_000)
    let newDue = oldDue.addingTimeInterval(3_600)
    let customTime = oldDue.addingTimeInterval(7_200)
    let alarms = [EKAlarm(absoluteDate: oldDue), EKAlarm(absoluteDate: customTime),
                  EKAlarm(relativeOffset: -900)]

    let updated = EventKitCapabilityService.alarmsUpdatingDue(
        alarms, previousDue: oldDue, newDue: newDue
    )
    #expect(updated.count == 3)
    #expect(updated.contains { $0.absoluteDate == newDue })
    #expect(updated.contains { $0.absoluteDate == customTime })
    #expect(updated.contains { $0.relativeOffset == -900 })
    #expect(!updated.contains { $0.absoluteDate == oldDue })

    let cleared = EventKitCapabilityService.alarmsUpdatingDue(
        updated, previousDue: newDue, newDue: nil
    )
    #expect(cleared.count == 2)
    #expect(cleared.contains { $0.absoluteDate == customTime })
    #expect(cleared.contains { $0.relativeOffset == -900 })
}

@Test @MainActor func calendarTimeValidationRejectsAmbiguousAndUnboundedIntervals() throws {
    let valid: [String: JSONValue] = [
        "from": .string("2026-10-25T14:00:00-04:00"),
        "to": .string("2026-10-25T15:00:00-04:00")
    ]
    let (start, end) = try EventKitCapabilityService.interval(valid)
    #expect(end > start)
    #expect(throws: EventKitCapabilityService.Failure.self) {
        try EventKitCapabilityService.interval([
            "from": .string("2026-10-25T14:00:00"),
            "to": .string("2026-10-25T15:00:00")
        ])
    }
    #expect(throws: EventKitCapabilityService.Failure.self) {
        try EventKitCapabilityService.interval([
            "from": .string("2026-10-25T15:00:00-04:00"),
            "to": .string("2026-10-25T14:00:00-04:00")
        ])
    }
    #expect(throws: EventKitCapabilityService.Failure.self) {
        try EventKitCapabilityService.interval([
            "from": .string("2026-10-25T14:00:00-04:00"),
            "to": .string("2027-10-25T14:00:00-04:00")
        ])
    }
}
