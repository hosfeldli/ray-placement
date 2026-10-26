import Foundation

/// A bounded, presentation-only accounting view of one persisted assistant turn.
/// Provider usage events are additive across response/tool rounds. Cached input
/// and reasoning output remain subsets of input and output, never extra tokens.
struct AIUsageRunSummary: Equatable {
    let providerLabel: String
    let modelLabel: String
    let usage: AIUsageMetrics?
    let completedToolCalls: Int
    let failedToolCalls: Int
    let duration: TimeInterval?

    init(message: AIChatMessage) {
        providerLabel = message.providerID.flatMap(AIProvider.init(rawValue:))?.title ?? "Not recorded"
        if let modelID = message.modelID, !modelID.isEmpty {
            modelLabel = modelID == "default" ? "Provider default (exact model not reported)" : modelID
        } else {
            modelLabel = "Not recorded"
        }

        let activities = message.activities ?? []
        let reports = activities.compactMap(\.usage)
        func aggregate(_ keyPath: KeyPath<AIUsageMetrics, Int?>) -> Int? {
            var total: Int?
            for report in reports {
                guard let value = report[keyPath: keyPath], value >= 0 else { continue }
                let current = total ?? 0
                total = value > Int.max - current ? Int.max : current + value
            }
            return total
        }
        let combined = AIUsageMetrics(
            inputTokens: aggregate(\.inputTokens),
            cachedInputTokens: aggregate(\.cachedInputTokens),
            outputTokens: aggregate(\.outputTokens),
            reasoningTokens: aggregate(\.reasoningTokens)
        )
        usage = reports.isEmpty ? nil : combined
        completedToolCalls = activities.filter { $0.kind == .toolCompleted || $0.kind == .toolFailed }.count
        failedToolCalls = activities.filter { $0.kind == .toolFailed }.count

        let terminal = activities.last {
            ($0.kind == .completed && $0.title != "Usage") || $0.kind == .error
        }
        if let measured = terminal?.duration, measured >= 0 {
            duration = measured
        } else if let started = activities.first(where: { $0.kind == .started })?.startedAt,
                  let ended = terminal?.endedAt ?? terminal?.startedAt,
                  ended >= started {
            duration = ended.timeIntervalSince(started)
        } else {
            duration = nil
        }
    }

    var reportedTokenText: String {
        usage?.displayText ?? "Not reported"
    }

    var durationText: String {
        guard let duration else { return "Not recorded" }
        let seconds = Int(duration.rounded())
        let minutes = seconds / 60
        return minutes == 0 ? "\(seconds)s" : "\(minutes)m \(seconds % 60)s"
    }

    static let costAvailability = "Unavailable — verified pricing and billing data are not recorded for this run."
}
