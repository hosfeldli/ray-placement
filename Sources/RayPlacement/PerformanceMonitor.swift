import Foundation
import OSLog

enum LimaPerformanceMetric: String, CaseIterable, Codable, Sendable {
    case launcherOpenToVisible
    case universalSearchQueryToResults
    case workspaceOpenToVisible
    case workspaceModuleSwitch
    case aiSendMainActorPreparation
    case aiRequest
    case aiComposerToFirstToken
    case aiHistoryConstruction
    case aiToolDuration
    case aiTerminalCommand
    case dictationSpeechToFirstPartial
    case dictationPartialToCommittedDelta
    case whisperSegmentDuration
    case formatterParse
    case extensionExecution
    case workflowExecution
    case workflowStep
    case mainThreadSchedulingDelay

    var title: String {
        switch self {
        case .launcherOpenToVisible: return "Launcher open to visible"
        case .universalSearchQueryToResults: return "Search query to results"
        case .workspaceOpenToVisible: return "Workspace open to visible"
        case .workspaceModuleSwitch: return "Workspace module switch"
        case .aiSendMainActorPreparation: return "AI send main-actor preparation"
        case .aiRequest: return "AI request"
        case .aiComposerToFirstToken: return "AI composer to first token"
        case .aiHistoryConstruction: return "AI history construction"
        case .aiToolDuration: return "AI tool duration"
        case .aiTerminalCommand: return "AI terminal command"
        case .dictationSpeechToFirstPartial: return "Dictation speech to first partial"
        case .dictationPartialToCommittedDelta: return "Dictation partial to committed delta"
        case .whisperSegmentDuration: return "Whisper segment duration"
        case .formatterParse: return "Formatter parse"
        case .extensionExecution: return "Extension execution"
        case .workflowExecution: return "Workflow execution"
        case .workflowStep: return "Workflow step"
        case .mainThreadSchedulingDelay: return "Main thread scheduling delay"
        }
    }
}

struct LimaPerformanceSample: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let operation: String
    let startedAt: Date
    let duration: TimeInterval
    let succeeded: Bool
    let detail: String?

    var milliseconds: Int {
        Int((duration * 1_000).rounded())
    }
}

@MainActor
final class PerformanceMonitor: ObservableObject {
    static let shared = PerformanceMonitor()
    static let maximumSamples = 160

    @Published private(set) var samples: [LimaPerformanceSample] = []

    private struct ActiveOperation {
        let metric: LimaPerformanceMetric
        let startedAt: Date
        let detail: String?
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.liam.lima", category: "performance")
    private var active: [UUID: ActiveOperation] = [:]
    private let probeQueue = DispatchQueue(label: "dev.liam.lima.main-thread-probe", qos: .utility)
    private var mainThreadProbe: DispatchSourceTimer?
    private var mainThreadProbeToken: UUID?

    private init() {}

    @discardableResult
    func begin(_ metric: LimaPerformanceMetric, detail: String? = nil) -> UUID {
        let identifier = UUID()
        let value = ActiveOperation(
            metric: metric,
            startedAt: Date(),
            detail: Self.optionalBounded(detail, limit: 160)
        )
        active[identifier] = value
        logger.debug("Lima operation started: \(metric.title, privacy: .public)")
        return identifier
    }

    func end(_ identifier: UUID, succeeded: Bool = true, detail: String? = nil) {
        guard let operation = active.removeValue(forKey: identifier) else { return }
        record(
            operation.metric,
            startedAt: operation.startedAt,
            duration: max(0, Date().timeIntervalSince(operation.startedAt)),
            succeeded: succeeded,
            detail: detail ?? operation.detail
        )
    }

    func record(
        _ metric: LimaPerformanceMetric,
        startedAt: Date = Date(),
        duration: TimeInterval,
        succeeded: Bool = true,
        detail: String? = nil
    ) {
        let sample = LimaPerformanceSample(
            id: UUID(),
            operation: metric.title,
            startedAt: startedAt,
            duration: max(0, duration),
            succeeded: succeeded,
            detail: Self.optionalBounded(detail, limit: 160)
        )
        samples.insert(sample, at: 0)
        if samples.count > Self.maximumSamples {
            samples.removeLast(samples.count - Self.maximumSamples)
        }
        logger.info("Lima operation completed: \(sample.operation, privacy: .public) in \(sample.milliseconds, privacy: .public)ms")
    }

    /// Probe only while AI is working. A delayed callback measures scheduler
    /// latency on the UI thread without sampling prompts, responses, or tools.
    func startMainThreadProbe() {
        guard mainThreadProbe == nil else { return }
        let token = UUID()
        mainThreadProbeToken = token
        let timer = DispatchSource.makeTimerSource(queue: probeQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            let queuedAt = Date()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.mainThreadProbeToken == token else { return }
                let delay = Date().timeIntervalSince(queuedAt)
                if delay >= 0.1 {
                    self.record(.mainThreadSchedulingDelay, startedAt: queuedAt, duration: delay)
                }
            }
        }
        mainThreadProbe = timer
        timer.resume()
    }

    func stopMainThreadProbe() {
        mainThreadProbeToken = nil
        mainThreadProbe?.cancel()
        mainThreadProbe = nil
    }

    /// Safe to copy or export: never includes sample details, request bodies,
    /// file paths, provider responses, or tool arguments.
    func redactedTrace() -> String {
        let formatter = ISO8601DateFormatter()
        let rows = samples.reversed().map { sample in
            "\(formatter.string(from: sample.startedAt))  \(sample.operation)  \(sample.milliseconds) ms  \(sample.succeeded ? "OK" : "FAILED")"
        }
        return (["Lima Developer Activity · metadata only"] + rows).joined(separator: "\n")
    }

    func clear() {
        stopMainThreadProbe()
        active = [:]
        samples = []
    }

    private static func bounded(_ value: String, limit: Int) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    private static func optionalBounded(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let result = bounded(value, limit: limit)
        return result.isEmpty ? nil : result
    }
}
