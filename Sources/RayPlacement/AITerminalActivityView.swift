import SwiftUI

/// Progress belongs to the session's chat, while the PTY remains an untouched
/// stream of real process output. Never write decorative status into the shell.
struct AITerminalActivityView: View {
    @ObservedObject var model: AIChatViewModel
    let conversationID: UUID
    @State private var expanded = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var conversation: AIConversation? { model.store.conversation(id: conversationID) }
    private var response: AIChatMessage? { conversation?.messages.last(where: { $0.role == .assistant }) }
    private var active: Bool { model.executionRun?.conversationID == conversationID && model.currentTaskState.isActive }
    private var steps: [AIActivityStreamStep] { AIActivityStream.steps(from: response?.activities ?? [], isActive: active) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: active ? "circle.dotted" : "clock.arrow.circlepath")
                        .foregroundStyle(LimaTheme.accentInk)
                    Text(active ? (response?.taskPlan?.steps.first(where: { $0.status == .inProgress })?.title ?? steps.last(where: { $0.status == .running })?.title ?? model.currentTaskState.title) : "Recent AI work")
                        .fontWeight(.medium).lineLimit(1)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let goal = conversation?.messages.last(where: { $0.role == .user })?.text {
                            Text(goal).foregroundStyle(LimaTheme.textSecondary).lineLimit(2)
                        }
                        if let plan = response?.taskPlan {
                            AITaskPlanView(plan: plan, isActive: active)
                        }
                        ForEach(steps.filter { $0.title != AITaskPlanTool.id && $0.title != "Update task checklist" }.suffix(3)) { step in
                            HStack(spacing: 8) {
                                Image(systemName: step.symbol).foregroundStyle(step.status == .failed ? LimaTheme.error : LimaTheme.accentInk)
                                Text(step.title).lineLimit(1)
                                if let detail = step.detail { Text(detail).foregroundStyle(LimaTheme.textSecondary).lineLimit(1) }
                                Spacer(minLength: 0)
                            }
                        }
                        if steps.isEmpty && response?.taskPlan == nil {
                            Text("Commands and their results will appear here as Lima works.").foregroundStyle(LimaTheme.textSecondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: response?.taskPlan == nil ? 95 : 180)
            }
        }
        .limaFont(.caption).padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LimaTheme.surfacePrimary)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: expanded)
        .accessibilityIdentifier("ai-terminal-work-log")
    }
}
