import Foundation

/// A privacy-preserving lifecycle record for work that may outlive the surface
/// that started it. A task contains status metadata only; prompts, note bodies,
/// file contents, credentials, and tool arguments are deliberately excluded.
enum LimaTaskKind: String, Codable, CaseIterable, Sendable {
    case aiGeneration
    case aiTool
    case dictation
    case extensionTask
    case workflow
    case update
    case formatter

    var title: String {
        switch self {
        case .aiGeneration: return "AI"
        case .aiTool: return "AI tool"
        case .dictation: return "Dictation"
        case .extensionTask: return "Extension"
        case .workflow: return "Workflow"
        case .update: return "Update"
        case .formatter: return "Formatter"
        }
    }

    var symbol: String {
        switch self {
        case .aiGeneration: return "sparkles"
        case .aiTool: return "wrench.and.screwdriver.fill"
        case .dictation: return "waveform"
        case .extensionTask: return "puzzlepiece.extension.fill"
        case .workflow: return "point.3.connected.trianglepath.dotted"
        case .update: return "arrow.down.circle.fill"
        case .formatter: return "doc.text.magnifyingglass"
        }
    }
}

enum LimaTaskState: String, Codable, Sendable {
    case running
    case waiting
    case completed
    case failed
    case cancelled

    var isActive: Bool {
        self == .running || self == .waiting
    }
}

struct LimaTask: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let kind: LimaTaskKind
    var title: String
    var detail: String?
    var state: LimaTaskState
    var progress: Double?
    let startedAt: Date
    var updatedAt: Date
    var finishedAt: Date?
    var isCancellable: Bool

    var elapsed: TimeInterval {
        (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var compactDetail: String {
        [title, detail].compactMap { $0 }.joined(separator: " · ")
    }
}

@MainActor
final class TaskRegistry: ObservableObject {
    static let shared = TaskRegistry()
    static let maximumHistory = 100

    @Published private(set) var activeTasks: [LimaTask] = []
    @Published private(set) var recentTasks: [LimaTask] = []

    private var cancellationHandlers: [UUID: () -> Void] = [:]

    init() {}

    @discardableResult
    func begin(
        kind: LimaTaskKind,
        title: String,
        detail: String? = nil,
        progress: Double? = nil,
        isCancellable: Bool = false,
        onCancel: (() -> Void)? = nil
    ) -> UUID {
        let now = Date()
        let task = LimaTask(
            id: UUID(),
            kind: kind,
            title: Self.bounded(title, limit: 120),
            detail: Self.optionalBounded(detail, limit: 240),
            state: .running,
            progress: Self.normalized(progress),
            startedAt: now,
            updatedAt: now,
            finishedAt: nil,
            isCancellable: isCancellable
        )
        activeTasks.append(task)
        if let onCancel { cancellationHandlers[task.id] = onCancel }
        return task.id
    }

    func update(
        _ id: UUID,
        title: String? = nil,
        detail: String? = nil,
        progress: Double? = nil,
        state: LimaTaskState? = nil
    ) {
        guard let index = activeTasks.firstIndex(where: { $0.id == id }) else { return }
        if let title { activeTasks[index].title = Self.bounded(title, limit: 120) }
        if let detail { activeTasks[index].detail = Self.optionalBounded(detail, limit: 240) }
        if let progress { activeTasks[index].progress = Self.normalized(progress) }
        if let state { activeTasks[index].state = state }
        activeTasks[index].updatedAt = Date()
    }

    func finish(
        _ id: UUID,
        state: LimaTaskState = .completed,
        detail: String? = nil
    ) {
        guard let index = activeTasks.firstIndex(where: { $0.id == id }) else { return }
        var task = activeTasks.remove(at: index)
        task.state = state
        task.detail = Self.optionalBounded(detail, limit: 240) ?? task.detail
        task.updatedAt = Date()
        task.finishedAt = task.updatedAt
        task.progress = state == .completed ? 1 : task.progress
        cancellationHandlers.removeValue(forKey: id)
        recentTasks.insert(task, at: 0)
        if recentTasks.count > Self.maximumHistory {
            recentTasks.removeLast(recentTasks.count - Self.maximumHistory)
        }
    }

    /// Invokes only the cancellation closure provided by the originating
    /// operation. The registry neither executes work nor manufactures actions.
    func cancel(_ id: UUID) {
        guard let task = activeTasks.first(where: { $0.id == id }), task.isCancellable else { return }
        cancellationHandlers[id]?()
        finish(id, state: .cancelled, detail: "Stopped by user")
    }

    func cancelAll() {
        activeTasks.filter(\.isCancellable).map(\.id).forEach(cancel)
    }

    func task(id: UUID) -> LimaTask? {
        activeTasks.first(where: { $0.id == id }) ?? recentTasks.first(where: { $0.id == id })
    }

    private static func bounded(_ value: String, limit: Int) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    private static func optionalBounded(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let bounded = Self.bounded(value, limit: limit)
        return bounded.isEmpty ? nil : bounded
    }

    private static func normalized(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(1, max(0, value))
    }
}
