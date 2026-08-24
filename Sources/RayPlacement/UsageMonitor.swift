import AppKit
import Foundation

enum UsageCategory: String, Codable, CaseIterable {
    case writing = "Writing"
    case summary = "Summary"
    case formatterAI = "Formatter AI"
    case dictation = "Dictation"
    case extensionCommand = "Extension"
}

struct UsageEvent: Codable, Identifiable, Hashable {
    let id: UUID
    let category: UsageCategory
    let operation: String
    let model: String?
    let performance: String
    let threads: Int
    let startedAt: Date
    let duration: TimeInterval
    let inputCharacters: Int
    let outputCharacters: Int
    let succeeded: Bool
    let detail: String?
}

struct ActiveUsageTask: Identifiable, Hashable {
    let id: UUID
    let category: UsageCategory
    let operation: String
    let model: String?
    let performance: PerformanceScale
    let threads: Int
    let inputCharacters: Int
    let startedAt: Date
}

struct UsageSummary {
    let completedToday: Int
    let failedToday: Int
    let modelSecondsToday: TimeInterval
    let inputCharactersToday: Int
    let outputCharactersToday: Int
}

@MainActor
final class UsageMonitor: ObservableObject {
    static let shared = UsageMonitor()
    static let maximumEvents = 1_500

    @Published private(set) var activeTasks: [ActiveUsageTask] = []
    @Published private(set) var events: [UsageEvent]

    private let persistenceQueue = DispatchQueue(label: "dev.rayplacement.usage-persistence", qos: .utility)
    private var pendingSave: DispatchWorkItem?

    private init() {
        events = Self.load()
    }

    @discardableResult
    func begin(
        category: UsageCategory,
        operation: String,
        model: String? = nil,
        performance: PerformanceScale,
        inputCharacters: Int = 0
    ) -> UUID {
        let task = ActiveUsageTask(
            id: UUID(),
            category: category,
            operation: operation,
            model: model,
            performance: performance,
            threads: performance.threadLimit,
            inputCharacters: inputCharacters,
            startedAt: Date()
        )
        activeTasks.append(task)
        return task.id
    }

    func finish(
        _ identifier: UUID,
        succeeded: Bool,
        outputCharacters: Int = 0,
        detail: String? = nil
    ) {
        guard let index = activeTasks.firstIndex(where: { $0.id == identifier }) else { return }
        let task = activeTasks.remove(at: index)
        events.insert(UsageEvent(
            id: task.id,
            category: task.category,
            operation: task.operation,
            model: task.model,
            performance: task.performance.title,
            threads: task.threads,
            startedAt: task.startedAt,
            duration: max(0, Date().timeIntervalSince(task.startedAt)),
            inputCharacters: task.inputCharacters,
            outputCharacters: outputCharacters,
            succeeded: succeeded,
            detail: detail.map { String($0.prefix(500)) }
        ), at: 0)
        if events.count > Self.maximumEvents { events.removeLast(events.count - Self.maximumEvents) }
        scheduleSave()
    }

    var summary: UsageSummary {
        let start = Calendar.current.startOfDay(for: Date())
        let today = events.filter { $0.startedAt >= start }
        return UsageSummary(
            completedToday: today.filter(\.succeeded).count,
            failedToday: today.filter { !$0.succeeded }.count,
            modelSecondsToday: today.filter { $0.model != nil }.reduce(0) { $0 + $1.duration },
            inputCharactersToday: today.reduce(0) { $0 + $1.inputCharacters },
            outputCharactersToday: today.reduce(0) { $0 + $1.outputCharacters }
        )
    }

    func clear() {
        events = []
        pendingSave?.cancel()
        pendingSave = nil
        persistenceQueue.async {
            try? FileManager.default.removeItem(at: ApplicationPaths.usageLog)
        }
    }

    func revealLog() {
        flush()
        NSWorkspace.shared.activateFileViewerSelecting([ApplicationPaths.usageLog])
    }

    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = events
        persistenceQueue.sync { Self.persist(snapshot) }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = events
        let work = DispatchWorkItem { Self.persist(snapshot) }
        pendingSave = work
        persistenceQueue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private static func load() -> [UsageEvent] {
        guard let data = try? Data(contentsOf: ApplicationPaths.usageLog),
              let decoded = try? Self.decoder.decode([UsageEvent].self, from: data) else { return [] }
        return Array(decoded.prefix(maximumEvents))
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func persist(_ events: [UsageEvent]) {
        try? ApplicationPaths.prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(events) else { return }
        try? data.write(to: ApplicationPaths.usageLog, options: .atomic)
    }
}
