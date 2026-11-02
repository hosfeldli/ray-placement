import SwiftUI

/// A public-facing summary of the request and recorded work, never a prediction
/// of the model's internal reasoning or a percentage of an unknown plan.
struct AIMissionSnapshot {
    let plan: AITaskPlan?
    let goal: String
    let steps: [AIActivityStreamStep]

    init(messages: [AIChatMessage], isActive: Bool) {
        guard let userIndex = messages.lastIndex(where: { $0.role == .user }) else {
            plan = nil
            goal = "Give Lima a goal to get started."
            steps = []
            return
        }
        let request = messages[userIndex].text.trimmingCharacters(in: .whitespacesAndNewlines)
        goal = request.isEmpty ? "Work with the context you shared." : String(request.prefix(300))
        let response = messages.dropFirst(userIndex + 1).last(where: { $0.role == .assistant })
        plan = response?.taskPlan
        steps = AIActivityStream.steps(from: response?.activities ?? [], isActive: isActive)
    }

    var returnedCount: Int { steps.filter { $0.isToolAction && $0.status == .completed }.count }
    var failureCount: Int { steps.filter { $0.status == .failed }.count }
    var current: AIActivityStreamStep? {
        steps.last(where: { $0.status == .waiting || $0.status == .running }) ?? steps.last
    }
}

struct AIMissionView: View {
    let mission: AIMissionSnapshot
    let state: AIChatTaskState
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    private var activityTitle: String {
        if let plan = mission.plan {
            if plan.unfinished.isEmpty { return "Checklist complete" }
            if !state.isActive { return state.title }
            if let step = plan.steps.first(where: { $0.status == .inProgress }) { return step.title }
        }
        return mission.current?.title ?? state.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                mascot
                Button { expanded.toggle() } label: {
                    HStack(spacing: 8) {
                        Text(activityTitle)
                            .limaFont(.system(size: 12, weight: .medium))
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Activity: " + activityTitle)
            }
            if expanded || !compact {
                Text(mission.goal).limaFont(.callout).foregroundStyle(LimaTheme.textSecondary)
                    .lineLimit(4).textSelection(.enabled)
                if let plan = mission.plan { AITaskPlanView(plan: plan, isActive: state.isActive) }
                ForEach(mission.plan == nil ? Array(mission.steps.suffix(8)) : []) { step in
                    HStack(spacing: 8) {
                        Image(systemName: step.symbol).frame(width: 16)
                            .foregroundStyle(step.status == .failed ? LimaColors.danger : LimaTheme.accentInk)
                        Text(step.title).lineLimit(2)
                        Spacer(minLength: 0)
                    }.limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 8))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: expanded)
        .accessibilityIdentifier("workspace.ai.mission")
    }

    private var mascot: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !state.isActive || reduceMotion)) { context in
            let phase = state.isActive && !reduceMotion ? context.date.timeIntervalSinceReferenceDate : 0
            ZStack {
                RoundedRectangle(cornerRadius: 13).fill(LimaTheme.accentInk.opacity(0.12))
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(LimaTheme.accentInk)
                    .offset(y: CGFloat(sin(phase * 2)) * 2)
                Circle().fill(state.tone.color).frame(width: 6, height: 6)
                    .offset(x: 10, y: -10)
            }
        }
        .frame(width: compact ? 26 : 32, height: compact ? 26 : 32)
        .accessibilityHidden(true)
    }
}
