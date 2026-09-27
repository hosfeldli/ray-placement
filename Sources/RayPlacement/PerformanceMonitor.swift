import Foundation
import OSLog

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
        let operation: String
        let startedAt: Date
        let detail: String?
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.liam.lima", category: "performance")
    private var active: [UUID: ActiveOperation] = [:]

    private init() {}

    @discardableResult
    func begin(_ operation: String, detail: String? = nil) -> UUID {
        let identifier = UUID()
        let value = ActiveOperation(
            operation: Self.bounded(operation, limit: 80),
            startedAt: Date(),
            detail: Self.optionalBounded(detail, limit: 160)
        )
        active[identifier] = value
        logger.debug("Lima operation started: \(value.operation, privacy: .public)")
        return identifier
    }

    func end(_ identifier: UUID, succeeded: Bool = true, detail: String? = nil) {
        guard let operation = active.removeValue(forKey: identifier) else { return }
        record(
            operation.operation,
            startedAt: operation.startedAt,
            duration: max(0, Date().timeIntervalSince(operation.startedAt)),
            succeeded: succeeded,
            detail: detail ?? operation.detail
        )
    }

    func record(
        _ operation: String,
        startedAt: Date = Date(),
        duration: TimeInterval,
        succeeded: Bool = true,
        detail: String? = nil
    ) {
        let sample = LimaPerformanceSample(
            id: UUID(),
            operation: Self.bounded(operation, limit: 80),
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

    func clear() {
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
