import Combine
import Foundation
import RayPlacementCore
import SwiftUI

struct AIScheduledTask: Codable, Identifiable, Equatable {
    enum State: String, Codable {
        case scheduled, running, finished, needsAttention, cancelled, expired
        var sortPriority: Int {
            switch self {
            case .running: return 0
            case .needsAttention: return 1
            case .scheduled: return 2
            case .expired: return 3
            case .finished: return 4
            case .cancelled: return 5
            }
        }
        var title: String {
            switch self {
            case .scheduled: return "Scheduled"
            case .running: return "Running"
            case .finished: return "Run finished"
            case .needsAttention: return "Needs attention"
            case .cancelled: return "Cancelled"
            case .expired: return "Start window missed"
            }
        }
    }
    var id = UUID()
    let conversationID: UUID
    let title: String
    let instructions: String
    let runAt: Date
    let expiresAt: Date
    let timeZone: String
    var autoApproveNonpayment = false
    var independentBrowser = false
    var state: State = .scheduled
    var detail: String = "Waiting for its scheduled time"
    var runID: UUID?
    var updatedAt = Date()
}

@MainActor
final class AIScheduledTaskStore: ObservableObject {
    static let shared = AIScheduledTaskStore()
    @Published private(set) var tasks: [AIScheduledTask] = []
    @Published private(set) var error: String?
    private let url: URL
    private let files = PrivateFileStore()
    private var loadFailed = false

    init(url: URL? = nil) {
        self.url = url ?? LimaTestEnvironment.storageURL(relativePath: "AI/scheduled-tasks.json") ??
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Lima/AI/scheduled-tasks.json")
        let loaded = files.loadJSON([AIScheduledTask].self, from: self.url)
        switch loaded.result.state {
        case .missing: break
        case .loaded:
            guard let value = loaded.value, value.count <= 200,
                  Set(value.map(\.id)).count == value.count,
                  value.allSatisfy({
                      !$0.title.isEmpty && $0.title.count <= 120 && !$0.instructions.isEmpty &&
                      $0.instructions.count <= 12000 && $0.runAt.timeIntervalSince1970.isFinite &&
                      $0.expiresAt > $0.runAt && $0.expiresAt.timeIntervalSince($0.runAt) <= 86400 &&
                      TimeZone(identifier: $0.timeZone) != nil
                  }) else {
                loadFailed = true; error = "Scheduled tasks could not be read."; return
            }
            tasks = value
            // A crash may happen after a remote booking committed. Never replay.
            if tasks.contains(where: { $0.state == .running }) {
                var recovered = tasks
                for index in recovered.indices where recovered[index].state == .running {
                    recovered[index].state = .needsAttention
                    recovered[index].detail = "Lima restarted during this run. Inspect the conversation and website before trying again."
                }
                try? save(recovered)
            }
        case .corrupt, .unreadable:
            loadFailed = true; error = "Scheduled tasks could not be read. The existing file has been preserved."
        }
    }

    @discardableResult
    func create(conversationID: UUID, title: String, instructions: String,
                runAt: Date, expiresAt: Date, timeZone: String, autoApproveNonpayment: Bool = false, independentBrowser: Bool = false, now: Date = Date()) throws -> AIScheduledTask {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120, !instructions.isEmpty, instructions.count <= 12000,
              runAt > now, expiresAt > runAt, expiresAt.timeIntervalSince(runAt) <= 86400,
              TimeZone(identifier: timeZone) != nil else {
            throw TaskError.invalid
        }
        guard !autoApproveNonpayment || independentBrowser || !BrowserTaskApprovalState.explicitSites(in: instructions).isEmpty else {
            throw TaskError.missingApprovedSite
        }
        // Retries of the same tool call must not create duplicate midnight attempts.
        if let existing = tasks.first(where: {
            $0.conversationID == conversationID && $0.instructions == instructions &&
            $0.runAt == runAt && $0.expiresAt == expiresAt && $0.autoApproveNonpayment == autoApproveNonpayment && $0.independentBrowser == independentBrowser && $0.state == .scheduled
        }) { return existing }
        guard tasks.count < 200 else { throw TaskError.invalid }
        var task = AIScheduledTask(conversationID: conversationID, title: title,
                                   instructions: instructions, runAt: runAt,
                                   expiresAt: expiresAt, timeZone: timeZone)
        task.autoApproveNonpayment = autoApproveNonpayment
        task.independentBrowser = independentBrowser
        try save([task] + tasks)
        return task
    }

    func update(_ id: UUID, state: AIScheduledTask.State, detail: String, runID: UUID? = nil) throws {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { throw TaskError.missing }
        var next = tasks
        next[index].state = state
        next[index].detail = String(detail.prefix(500))
        next[index].updatedAt = Date()
        next[index].runID = runID ?? next[index].runID
        try save(next)
    }

    func remove(_ id: UUID) throws {
        guard let task = tasks.first(where: { $0.id == id }),
              task.state != .scheduled && task.state != .running else { throw TaskError.invalid }
        try save(tasks.filter { $0.id != id })
    }

    func due(at date: Date) -> AIScheduledTask? {
        tasks.filter { $0.state == .scheduled && $0.runAt <= date && $0.expiresAt > date }
            .sorted { $0.runAt < $1.runAt }.first
    }

    func expire(at date: Date) throws {
        var next = tasks
        for index in next.indices where next[index].state == .scheduled && next[index].expiresAt <= date {
            next[index].state = .expired
            next[index].detail = "The allowed start window passed. This task was not run."
            next[index].updatedAt = date
        }
        if next != tasks { try save(next) }
    }

    private func save(_ next: [AIScheduledTask]) throws {
        guard !loadFailed else { throw TaskError.unavailable }
        do {
            try files.write(next, to: url, backupExisting: false)
            tasks = next
            error = nil
        } catch {
            self.error = "Could not save scheduled tasks. No new task was armed."
            throw error
        }
    }

    enum TaskError: LocalizedError {
        case invalid, missing, unavailable, missingApprovedSite
        var errorDescription: String? {
            switch self {
            case .invalid: return "Provide a title, instructions, a future start time, a valid timezone, and an expiry within 24 hours of the start. The queue holds at most 200 tasks."
            case .missingApprovedSite: return "Include the exact website URL for Approved Sites, or choose Independent browsing."
            case .missing: return "The scheduled task no longer exists."
            case .unavailable: return "Scheduled-task storage is unavailable."
            }
        }
    }
}

/// Runs through the visible chat and its normal approval pipeline. No hidden
/// second agent may race the user's Browser or inherit an expired site grant.
@MainActor
final class AIScheduledTaskRunner {
    static let shared = AIScheduledTaskRunner()
    private weak var model: AIChatViewModel?
    private var timer: Timer?
    private var activeID: UUID?
    private let store: AIScheduledTaskStore

    init(store: AIScheduledTaskStore? = nil) { self.store = store ?? .shared }

    func start(model: AIChatViewModel) {
        guard !LimaTestEnvironment.isEnabled else { return }
        self.model = model
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    func bindForTesting(model: AIChatViewModel) {
        guard LimaTestEnvironment.isEnabled else { return }
        self.model = model
    }

    func cancel(_ id: UUID) {
        do {
            try store.update(id, state: .cancelled, detail: "Cancelled by the user")
            if activeID == id {
                if let runID = store.tasks.first(where: { $0.id == id })?.runID,
                   model?.executionRun?.id == runID { model?.endTask() }
                activeID = nil
            }
        } catch { }
    }

    func tick(now: Date = Date()) {
        guard let model else { return }
        if let id = activeID {
            if store.tasks.first(where: { $0.id == id })?.state == .cancelled {
                model.endTask(); activeID = nil; return
            }
            let task = store.tasks.first { $0.id == id }
            if let expected = task?.runID, model.executionRun?.id != expected {
                try? store.update(id, state: .needsAttention, detail: "The active conversation changed. Check the saved task's result before retrying.")
                activeID = nil; return
            }
            if model.canEndTask {
                let detail: String?
                switch model.executionRun?.state {
                case .waitingForApproval: detail = "Waiting for your approval. Open the active task to continue."
                case .waitingForUserInput: detail = "Waiting for your answer. Open the active task to continue."
                case .waitingForConfiguration: detail = "Provider setup needs attention. Open the active task."
                default: detail = nil
                }
                if let detail, task?.detail != detail { try? store.update(id, state: .running, detail: detail) }
                return
            }
            let run = model.executionRun
            do {
                try store.update(id, state: run?.state == .completed ? .finished : .needsAttention,
                    detail: run?.state == .completed
                        ? "The AI run ended. Open its conversation to check the verified outcome."
                        : (model.streamError ?? "The run stopped. Open its conversation before retrying."),
                    runID: run?.id)
                activeID = nil
            } catch { }
            return
        }
        do { try store.expire(at: now) } catch { return }
        guard AIRequestPolicy.shared.isEnabled, !model.canEndTask,
              model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              model.attachments.isEmpty, let task = store.due(at: now) else { return }
        guard model.store.conversation(id: task.conversationID) != nil else {
            try? store.update(task.id, state: .needsAttention, detail: "The original conversation is missing.")
            return
        }
        // Persist the claim before invoking any provider or external action.
        do { try store.update(task.id, state: .running, detail: "Starting in the original conversation") }
        catch { return }
        activeID = task.id
        model.select(task.conversationID)
        guard model.selectedConversationID == task.conversationID else {
            try? store.update(task.id, state: .needsAttention, detail: "The conversation could not be opened.")
            activeID = nil; return
        }
        model.draft = """
        Run my saved task now: \(task.title)
        Scheduled start: \(ISO8601DateFormatter().string(from: task.runAt)); timezone: \(task.timeZone).
        \(task.instructions)

        Recheck current availability and any existing confirmation before committing. Follow current permissions and ask for required approvals. Do not repeat a completed booking or claim success without confirmation. Do not schedule another attempt unless my saved instructions explicitly request it.
        """
        BrowserTaskApprovalState.shared.select(task.autoApproveNonpayment ? (task.independentBrowser ? .independent : .autoApproveNonpayment) : .askForActions)
        model.send()
        if model.canEndTask, let runID = model.executionRun?.id {
            try? store.update(task.id, state: .running, detail: "Running in the original conversation", runID: runID)
        } else {
            BrowserTaskApprovalState.shared.select(.askForActions)
            model.draft = ""
            try? store.update(task.id, state: .needsAttention,
                              detail: model.streamError ?? "The AI run could not start.")
            activeID = nil
        }
    }
}
