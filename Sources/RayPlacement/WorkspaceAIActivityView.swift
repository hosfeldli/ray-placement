import SwiftUI

/// The sidecar's activity pane is a projection of the live chat run and its
/// recorded tool events. It never invents progress or a transaction outcome.
struct WorkspaceAIActivityView: View {
    @ObservedObject var model: AIChatViewModel
    @ObservedObject private var browser = BrowserWorkspaceModel.shared
    let showChat: () -> Void

    private var assistant: AIChatMessage? {
        model.selectedConversation?.messages.last(where: { $0.role == .assistant })
    }

    private var activities: [AIAgentActivity] { assistant?.activities ?? [] }

    private var steps: [AIActivityStreamStep] {
        AIActivityStream.steps(from: activities, isActive: model.currentTaskState.isActive)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                statusCard

                if let latest = steps.last {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: latest.symbol)
                            .foregroundStyle(color(for: latest.status))
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("LATEST ACTION")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(LimaTheme.textSecondary)
                            Text(latest.title)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Text(statusLabel(for: latest.status))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(color(for: latest.status))
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("workspace.ai.latest-action")
                }

                if !activities.isEmpty || assistant?.reasoningSummary?.isEmpty == false {
                    ActivityDisclosureView(
                        activities: activities,
                        reasoningSummary: assistant?.reasoningSummary,
                        isWorking: model.currentTaskState.isActive,
                        currentActionTitle: model.currentTaskState.title,
                        cachedSteps: steps,
                        labelTitle: "Task activity",
                        initiallyExpanded: false
                    )
                } else if !model.currentTaskState.isActive {
                    Text("No task activity to show yet. Open Chat to give Lima an instruction.")
                        .font(.system(size: 12))
                        .foregroundStyle(LimaTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let tab = browser.selectedTab {
                    HStack(spacing: 6) {
                        Image(systemName: browser.pausedTabIDs.contains(tab.id) ? "pause.circle" : "globe")
                        Text(browser.pausedTabIDs.contains(tab.id)
                             ? "AI access paused for this Browser tab"
                             : "Browser permission: \(browser.aiControlMode.title)")
                            .lineLimit(2)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(LimaTheme.textSecondary)
                    .padding(.top, 2)
                }
                }
                .padding(12)
            }
            GlassHairline()
            Button(action: showChat) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil")
                    Text(model.canEndTask ? "View the live task in Chat" :
                         "Ask Lima or provide a new instruction…")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 12))
                .foregroundStyle(LimaTheme.textSecondary)
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .help(model.canEndTask ? "Open Chat to review the active task" :
                  "Open the compact Chat composer")
            .accessibilityLabel(model.canEndTask ? "Open active Chat" : "Open Chat composer")
            .padding(8)
        }
        .accessibilityIdentifier("workspace.ai.activity")
    }

    private var statusCard: some View {
        let state = model.currentTaskState
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: state.symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(state.tone.color)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LimaTheme.textPrimary)
                    Text(state.detail)
                        .font(.system(size: 13))
                        .foregroundStyle(LimaTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                if model.pendingApproval != nil || model.pendingQuestion != nil {
                    Button("Review request", action: showChat)
                        .buttonStyle(.borderedProminent)
                } else if !state.isActive && model.canRetryLastRequest {
                    Button("Retry request") { model.retryLastRequest() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(state.isActive ? "Open Chat" : "Continue in Chat", action: showChat)
                        .buttonStyle(.bordered)
                }

                if let tab = browser.selectedTab,
                   state.isActive,
                   !browser.pausedTabIDs.contains(tab.id) {
                    Button("Take control") { browser.pauseAI(on: tab.id) }
                        .buttonStyle(.bordered)
                        .help("Pause AI access on this Browser tab until you resume it")
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .limaNativeSurface(
            fill: state.tone.color.opacity(0.055),
            radius: LimaRadius.control,
            border: state.tone.color.opacity(0.25)
        )
        .accessibilityIdentifier("workspace.ai.active-status")
    }

    private func color(for status: AIActivityStreamStep.Status) -> Color {
        switch status {
        case .running, .interrupted: return LimaTheme.textSecondary
        case .waiting: return LimaTheme.warning
        case .completed: return LimaColors.success
        case .failed: return LimaColors.danger
        }
    }

    private func statusLabel(for status: AIActivityStreamStep.Status) -> String {
        switch status {
        case .running: return "Running"
        case .waiting: return "Waiting"
        case .completed: return "Returned"
        case .failed: return "Failed"
        case .interrupted: return "Stopped"
        }
    }
}
