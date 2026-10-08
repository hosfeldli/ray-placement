import Foundation

/// A display-only projection of events that Lima actually recorded. It never
/// predicts the model's next tool call or treats a requested call as executed.
struct AIActivityStreamStep: Identifiable, Equatable {
    enum Status: Equatable {
        case running
        case waiting
        case completed
        case failed
        case interrupted
    }

    let id: UUID
    var title: String
    var detail: String?
    var status: Status
    let isToolAction: Bool
    var correlationID: String? = nil

    var symbol: String {
        switch status {
        case .running: return "circle.dotted"
        case .waiting: return "hand.raised.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .interrupted: return "stop.circle"
        }
    }
}

enum AIActivityTerminalState: Equatable {
    case done
    case stopped
    case needsAttention
}

enum AIActivityStream {
    static func steps(from activities: [AIAgentActivity], isActive: Bool) -> [AIActivityStreamStep] {
        var steps: [AIActivityStreamStep] = []

        for activity in activities {
            switch activity.kind {
            case .toolStarted:
                steps.append(AIActivityStreamStep(
                    id: activity.id, title: activity.displayTitle,
                    detail: meaningfulDetail(activity.detail), status: .running,
                    isToolAction: true, correlationID: activity.correlationID
                ))
            case .toolCompleted, .toolFailed:
                let status: AIActivityStreamStep.Status = activity.kind == .toolFailed ? .failed : .completed
                if let index = steps.indices.reversed().first(where: { candidate in
                    steps[candidate].status == .running &&
                    (activity.correlationID.map { steps[candidate].correlationID == $0 }
                     ?? (steps[candidate].correlationID == nil && steps[candidate].title == activity.displayTitle))
                }) {
                    steps[index].status = status
                    steps[index].detail = meaningfulDetail(activity.detail) ?? steps[index].detail
                } else {
                    steps.append(AIActivityStreamStep(
                        id: activity.id, title: activity.displayTitle,
                        detail: meaningfulDetail(activity.detail), status: status,
                        isToolAction: true, correlationID: activity.correlationID
                    ))
                }
            case .toolApproval:
                if activity.completed {
                    if let index = steps.indices.reversed().first(where: { steps[$0].status == .waiting }) {
                        steps[index].status = activity.title == "Tool denied" ? .failed : .completed
                        steps[index].title = activity.title
                        steps[index].detail = meaningfulDetail(activity.detail)
                    } else {
                        steps.append(AIActivityStreamStep(
                            id: activity.id, title: activity.title,
                            detail: meaningfulDetail(activity.detail),
                            status: activity.title == "Tool denied" ? .failed : .completed,
                            isToolAction: false
                        ))
                    }
                } else {
                    steps.append(AIActivityStreamStep(
                        id: activity.id, title: activity.title,
                        detail: meaningfulDetail(activity.detail), status: .waiting, isToolAction: false
                    ))
                }
            case .error:
                steps.append(AIActivityStreamStep(
                    id: activity.id, title: activity.title,
                    detail: meaningfulDetail(activity.detail), status: .failed, isToolAction: false
                ))
            case .started, .thinking, .reasoningSummary, .attachment, .completed:
                // Request lifecycle, reasoning, attachments and token usage are not
                // completed tool actions. The task status and message show them.
                break
            }
        }

        if !isActive {
            for index in steps.indices where steps[index].status == .running || steps[index].status == .waiting {
                steps[index].status = .interrupted
            }
        }
        return steps
    }

    static func completedActionCount(_ steps: [AIActivityStreamStep]) -> Int {
        steps.filter { $0.isToolAction && ($0.status == .completed || $0.status == .failed) }.count
    }

    static func terminalState(from activities: [AIAgentActivity], steps: [AIActivityStreamStep]) -> AIActivityTerminalState {
        if steps.contains(where: { $0.status == .failed }) { return .needsAttention }
        if steps.contains(where: { $0.status == .interrupted }) || activities.contains(where: {
            $0.kind == .completed && ($0.title == "Stopped" || $0.title == "Task ended")
        }) { return .stopped }
        return .done
    }

    private static func meaningfulDetail(_ detail: String?) -> String? {
        guard let detail, !detail.isEmpty, detail != "Lima" else { return nil }
        return detail
    }
}
