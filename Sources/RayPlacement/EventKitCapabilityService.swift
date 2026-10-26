import EventKit
import Foundation
import RayPlacementCore

/// EventKit-backed native operations. No event or reminder is persisted by Lima;
/// identifiers are resolved against the live store immediately before each call.
@MainActor
final class EventKitCapabilityService {
    static let shared = EventKitCapabilityService()

    static let supportedOperations: Set<NativeCapabilityOperation> = [
        .calendarList, .calendarEvents, .calendarSearch, .calendarCheckConflicts,
        .calendarCreateEvent, .calendarUpdateEvent, .calendarDeleteEvent,
        .remindersListLists, .remindersSearch, .remindersList,
        .remindersCreate, .remindersUpdate, .remindersComplete,
        .remindersReopen, .remindersDelete
    ]

    enum Failure: LocalizedError {
        case invalidArguments
        case permissionDenied
        case notFound
        case readOnly
        case recurringEvent
        case noDefaultList

        var errorDescription: String? {
            switch self {
            case .invalidArguments: return "The Calendar or Reminders arguments are invalid. Use ISO 8601 times with an explicit timezone."
            case .permissionDenied: return "macOS Calendar or Reminders access was not granted. Enable it for Lima in System Settings and retry."
            case .notFound: return "The selected calendar event, reminder, or list no longer exists."
            case .readOnly: return "The selected calendar or reminders list cannot be changed."
            case .recurringEvent: return "Lima does not modify recurring calendar series. Edit this occurrence in Calendar instead."
            case .noDefaultList: return "No writable default calendar or reminders list is available."
            }
        }
    }

    private let store = EKEventStore()
    private init() {}

    func execute(_ operation: NativeCapabilityOperation, arguments: [String: JSONValue]) async throws -> JSONValue {
        guard Self.supportedOperations.contains(operation) else { throw Failure.invalidArguments }
        switch operation.capability {
        case .calendar: try await ensureCalendarAccess(createOnly: operation == .calendarCreateEvent)
        case .reminders: try await ensureRemindersAccess()
        default: throw Failure.invalidArguments
        }

        switch operation {
        case .calendarList:
            return .object(["calendars": .array(store.calendars(for: .event).map(calendarJSON))])
        case .calendarEvents, .calendarSearch, .calendarCheckConflicts:
            let (start, end) = try Self.interval(arguments)
            let calendars = try selectedCalendars(arguments, type: .event)
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
            var events = store.events(matching: predicate).filter { $0.endDate > start && $0.startDate < end }
            if operation == .calendarSearch {
                let query = try Self.requiredText(arguments, "query", maximum: 160)
                events = events.filter {
                    $0.title.localizedCaseInsensitiveContains(query) ||
                    ($0.location?.localizedCaseInsensitiveContains(query) ?? false) ||
                    ($0.notes?.localizedCaseInsensitiveContains(query) ?? false)
                }
            }
            if operation == .calendarCheckConflicts {
                let conflicts = events.filter { !$0.isAllDay }.prefix(100)
                return .object(["has_conflict": .bool(!conflicts.isEmpty),
                                "events": .array(conflicts.map(eventJSON))])
            }
            return .object(["events": .array(events.prefix(100).map(eventJSON)),
                            "truncated": .bool(events.count > 100)])
        case .calendarCreateEvent:
            let title = try Self.requiredText(arguments, "title", maximum: 240)
            let (start, end) = try Self.interval(arguments, maximumDays: 31)
            let calendar = try writableCalendar(arguments, type: .event)
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = title
            event.startDate = start
            event.endDate = end
            event.isAllDay = Self.boolean(arguments, "all_day") ?? false
            event.location = try Self.optionalText(arguments, "location", maximum: 500)
            event.notes = try Self.optionalText(arguments, "notes", maximum: 10_000)
            try store.save(event, span: .thisEvent, commit: true)
            return .object(["created": .bool(true), "event": eventJSON(event)])
        case .calendarUpdateEvent:
            let event = try existingEvent(arguments)
            guard !event.hasRecurrenceRules else { throw Failure.recurringEvent }
            guard event.calendar.allowsContentModifications else { throw Failure.readOnly }
            guard !(Self.hasValue(arguments, "location") && Self.boolean(arguments, "clear_location") == true),
                  !(Self.hasValue(arguments, "notes") && Self.boolean(arguments, "clear_notes") == true) else {
                throw Failure.invalidArguments
            }
            var changed = false
            if Self.hasValue(arguments, "title") { event.title = try Self.requiredText(arguments, "title", maximum: 240); changed = true }
            if Self.hasValue(arguments, "location") { event.location = try Self.optionalText(arguments, "location", maximum: 500); changed = true }
            if Self.boolean(arguments, "clear_location") == true { event.location = nil; changed = true }
            if Self.hasValue(arguments, "notes") { event.notes = try Self.optionalText(arguments, "notes", maximum: 10_000); changed = true }
            if Self.boolean(arguments, "clear_notes") == true { event.notes = nil; changed = true }
            if Self.hasValue(arguments, "from") { event.startDate = try Self.date(arguments, "from"); changed = true }
            if Self.hasValue(arguments, "to") { event.endDate = try Self.date(arguments, "to"); changed = true }
            if let allDay = Self.boolean(arguments, "all_day") {
                event.isAllDay = allDay; changed = true
            }
            if Self.hasValue(arguments, "calendar_id") {
                event.calendar = try writableCalendar(arguments, type: .event)
                changed = true
            }
            guard changed, event.endDate > event.startDate,
                  event.endDate.timeIntervalSince(event.startDate) <= 31 * 86_400 else {
                throw Failure.invalidArguments
            }
            try store.save(event, span: .thisEvent, commit: true)
            return .object(["updated": .bool(true), "event": eventJSON(event)])
        case .calendarDeleteEvent:
            let event = try existingEvent(arguments)
            guard !event.hasRecurrenceRules else { throw Failure.recurringEvent }
            guard event.calendar.allowsContentModifications else { throw Failure.readOnly }
            let id = event.eventIdentifier ?? ""
            try store.remove(event, span: .thisEvent, commit: true)
            return .object(["deleted": .bool(true), "event_id": .string(id)])
        case .remindersListLists:
            return .object(["lists": .array(store.calendars(for: .reminder).map(calendarJSON))])
        case .remindersList, .remindersSearch:
            let calendars = try selectedCalendars(arguments, type: .reminder)
            let predicate = store.predicateForReminders(in: calendars)
            var reminders = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
            }
            if Self.boolean(arguments, "include_completed") != true {
                reminders.removeAll { $0.isCompleted }
            }
            if operation == .remindersSearch {
                let query = try Self.requiredText(arguments, "query", maximum: 160)
                reminders = reminders.filter {
                    $0.title.localizedCaseInsensitiveContains(query) ||
                    ($0.notes?.localizedCaseInsensitiveContains(query) ?? false)
                }
            }
            reminders.sort { ($0.dueDateComponents?.date ?? .distantFuture, $0.title) <
                ($1.dueDateComponents?.date ?? .distantFuture, $1.title) }
            return .object(["reminders": .array(reminders.prefix(100).map(reminderJSON)),
                            "truncated": .bool(reminders.count > 100)])
        case .remindersCreate:
            let title = try Self.requiredText(arguments, "title", maximum: 240)
            let calendar = try writableCalendar(arguments, type: .reminder)
            let reminder = EKReminder(eventStore: store)
            reminder.calendar = calendar
            reminder.title = title
            reminder.notes = try Self.optionalText(arguments, "notes", maximum: 10_000)
            if Self.hasValue(arguments, "due_at") {
                let due = try Self.date(arguments, "due_at")
                reminder.dueDateComponents = Self.dueComponents(due)
                reminder.addAlarm(EKAlarm(absoluteDate: due))
            }
            try store.save(reminder, commit: true)
            return .object(["created": .bool(true), "reminder": reminderJSON(reminder)])
        case .remindersUpdate:
            let reminder = try existingReminder(arguments)
            guard reminder.calendar.allowsContentModifications else { throw Failure.readOnly }
            guard !(Self.hasValue(arguments, "notes") && Self.boolean(arguments, "clear_notes") == true),
                  !(Self.hasValue(arguments, "due_at") && Self.boolean(arguments, "clear_due") == true) else {
                throw Failure.invalidArguments
            }
            var changed = false
            if Self.hasValue(arguments, "title") { reminder.title = try Self.requiredText(arguments, "title", maximum: 240); changed = true }
            if Self.hasValue(arguments, "notes") { reminder.notes = try Self.optionalText(arguments, "notes", maximum: 10_000); changed = true }
            if Self.boolean(arguments, "clear_notes") == true { reminder.notes = nil; changed = true }
            if Self.hasValue(arguments, "due_at") || Self.boolean(arguments, "clear_due") == true {
                let previousDue = reminder.dueDateComponents?.date
                let due = Self.hasValue(arguments, "due_at") ? try Self.date(arguments, "due_at") : nil
                reminder.alarms = Self.alarmsUpdatingDue(reminder.alarms, previousDue: previousDue, newDue: due)
                reminder.dueDateComponents = due.map(Self.dueComponents)
                changed = true
            }
            if Self.hasValue(arguments, "list_id") {
                reminder.calendar = try writableCalendar(arguments, type: .reminder)
                changed = true
            }
            guard changed else { throw Failure.invalidArguments }
            try store.save(reminder, commit: true)
            return .object(["updated": .bool(true), "reminder": reminderJSON(reminder)])
        case .remindersComplete, .remindersReopen:
            let reminder = try existingReminder(arguments)
            guard reminder.calendar.allowsContentModifications else { throw Failure.readOnly }
            reminder.isCompleted = operation == .remindersComplete
            reminder.completionDate = operation == .remindersComplete ? Date() : nil
            try store.save(reminder, commit: true)
            return .object(["updated": .bool(true), "reminder": reminderJSON(reminder)])
        case .remindersDelete:
            let reminder = try existingReminder(arguments)
            guard reminder.calendar.allowsContentModifications else { throw Failure.readOnly }
            let id = reminder.calendarItemIdentifier
            try store.remove(reminder, commit: true)
            return .object(["deleted": .bool(true), "reminder_id": .string(id)])
        default:
            throw Failure.invalidArguments
        }
    }

    private func ensureCalendarAccess(createOnly: Bool) async throws {
        if #available(macOS 14.0, *) {
            let status = EKEventStore.authorizationStatus(for: .event)
            if status == .fullAccess || (createOnly && status == .writeOnly) { return }
            guard status == .notDetermined || status == .writeOnly else { throw Failure.permissionDenied }
            guard try await store.requestFullAccessToEvents() else { throw Failure.permissionDenied }
        } else {
            let status = EKEventStore.authorizationStatus(for: .event)
            if status == .authorized { return }
            guard status == .notDetermined else { throw Failure.permissionDenied }
            let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                store.requestAccess(to: .event) { allowed, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: allowed) }
                }
            }
            guard granted else { throw Failure.permissionDenied }
        }
    }

    private func ensureRemindersAccess() async throws {
        if #available(macOS 14.0, *) {
            let status = EKEventStore.authorizationStatus(for: .reminder)
            if status == .fullAccess { return }
            guard status == .notDetermined,
                  (try await store.requestFullAccessToReminders()) else { throw Failure.permissionDenied }
        } else {
            let status = EKEventStore.authorizationStatus(for: .reminder)
            if status == .authorized { return }
            guard status == .notDetermined else { throw Failure.permissionDenied }
            let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                store.requestAccess(to: .reminder) { allowed, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: allowed) }
                }
            }
            guard granted else { throw Failure.permissionDenied }
        }
    }

    private func selectedCalendars(_ arguments: [String: JSONValue], type: EKEntityType) throws -> [EKCalendar]? {
        let key = type == .event ? "calendar_id" : "list_id"
        guard let id = try Self.optionalText(arguments, key, maximum: 500) else { return nil }
        guard let calendar = store.calendar(withIdentifier: id), calendar.allowedEntityTypes.contains(type == .event ? .event : .reminder) else {
            throw Failure.notFound
        }
        return [calendar]
    }

    private func writableCalendar(_ arguments: [String: JSONValue], type: EKEntityType) throws -> EKCalendar {
        let calendar: EKCalendar?
        if let selected = try selectedCalendars(arguments, type: type) {
            calendar = selected.first
        } else if type == .event {
            calendar = store.defaultCalendarForNewEvents
        } else {
            calendar = store.defaultCalendarForNewReminders()
        }
        guard let calendar else { throw Failure.noDefaultList }
        guard calendar.allowsContentModifications else { throw Failure.readOnly }
        return calendar
    }

    private func existingEvent(_ arguments: [String: JSONValue]) throws -> EKEvent {
        let id = try Self.requiredText(arguments, "event_id", maximum: 500)
        let expectedTitle = try Self.requiredText(arguments, "expected_title", maximum: 240)
        guard let event = store.event(withIdentifier: id), event.title == expectedTitle else {
            throw Failure.notFound
        }
        return event
    }

    private func existingReminder(_ arguments: [String: JSONValue]) throws -> EKReminder {
        let id = try Self.requiredText(arguments, "reminder_id", maximum: 500)
        let expectedTitle = try Self.requiredText(arguments, "expected_title", maximum: 240)
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder,
              reminder.title == expectedTitle else { throw Failure.notFound }
        return reminder
    }

    private func calendarJSON(_ calendar: EKCalendar) -> JSONValue {
        .object([
            "id": .string(calendar.calendarIdentifier),
            "title": .string(calendar.title),
            "writable": .bool(calendar.allowsContentModifications)
        ])
    }

    private func eventJSON(_ event: EKEvent) -> JSONValue {
        .object([
            "id": event.eventIdentifier.map(JSONValue.string) ?? .null,
            "calendar_id": .string(event.calendar.calendarIdentifier),
            "title": .string(event.title ?? ""),
            "from": .string(Self.iso(event.startDate)),
            "to": .string(Self.iso(event.endDate)),
            "all_day": .bool(event.isAllDay),
            "location": event.location.map { .string(String($0.prefix(500))) } ?? .null,
            "notes": event.notes.map { .string(String($0.prefix(10_000))) } ?? .null,
            "recurring": .bool(event.hasRecurrenceRules)
        ])
    }

    private func reminderJSON(_ reminder: EKReminder) -> JSONValue {
        .object([
            "id": .string(reminder.calendarItemIdentifier),
            "list_id": .string(reminder.calendar.calendarIdentifier),
            "title": .string(reminder.title),
            "notes": reminder.notes.map { .string(String($0.prefix(10_000))) } ?? .null,
            "due_at": reminder.dueDateComponents?.date.map { .string(Self.iso($0)) } ?? .null,
            "completed": .bool(reminder.isCompleted)
        ])
    }

    static func interval(_ arguments: [String: JSONValue], maximumDays: Double = 90) throws -> (Date, Date) {
        let start = try date(arguments, "from")
        let end = try date(arguments, "to")
        guard end > start, end.timeIntervalSince(start) <= maximumDays * 86_400 else {
            throw Failure.invalidArguments
        }
        return (start, end)
    }

    static func date(_ arguments: [String: JSONValue], _ key: String) throws -> Date {
        let raw = try requiredText(arguments, key, maximum: 40)
        guard raw.range(of: #"(Z|[+-][0-9]{2}:[0-9]{2})$"#, options: .regularExpression) != nil else {
            throw Failure.invalidArguments
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: raw) else { throw Failure.invalidArguments }
        return date
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func requiredText(_ arguments: [String: JSONValue], _ key: String, maximum: Int) throws -> String {
        guard case .string(let value)? = arguments[key] else { throw Failure.invalidArguments }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maximum else { throw Failure.invalidArguments }
        return text
    }

    static func optionalText(_ arguments: [String: JSONValue], _ key: String, maximum: Int) throws -> String? {
        guard let value = arguments[key] else { return nil }
        if case .null = value { return nil }
        guard case .string(let text) = value, text.count <= maximum else { throw Failure.invalidArguments }
        return text
    }

    /// Replace only the absolute alarm tied to Lima's due time; preserve other
    /// user-defined relative or absolute alarms on the reminder.
    static func alarmsUpdatingDue(_ existing: [EKAlarm]?, previousDue: Date?, newDue: Date?) -> [EKAlarm] {
        var alarms = (existing ?? []).filter { alarm in
            guard let previousDue, let absoluteDate = alarm.absoluteDate else { return true }
            return abs(absoluteDate.timeIntervalSince(previousDue)) > 60
        }
        if let newDue,
           !alarms.contains(where: { $0.absoluteDate.map { abs($0.timeIntervalSince(newDue)) <= 60 } ?? false }) {
            alarms.append(EKAlarm(absoluteDate: newDue))
        }
        return alarms
    }

    private static func dueComponents(_ date: Date) -> DateComponents {
        var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        components.calendar = Calendar.current
        components.timeZone = Calendar.current.timeZone
        return components
    }

    private static func hasValue(_ arguments: [String: JSONValue], _ key: String) -> Bool {
        guard let value = arguments[key] else { return false }
        if case .null = value { return false }
        return true
    }

    private static func boolean(_ arguments: [String: JSONValue], _ key: String) -> Bool? {
        guard case .bool(let value)? = arguments[key] else { return nil }
        return value
    }
}
