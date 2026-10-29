import SwiftUI

/// Uses the existing Lima card materials; recovery changes behavior, not theme.
struct AIRecoveryStatusView: View {
    let state: AIExecutionRunState
    let message: String
    let nextAttemptAt: Date?
    let onResume: () -> Void
    let onStopAutomaticRecovery: () -> Void
    let onFixSettings: () -> Void

    private var isProviderWait: Bool { state == .waitingForProvider }
    private var isConfigurationWait: Bool { state == .waitingForConfiguration }
    private var retryBlocked: Bool { nextAttemptAt.map { $0 > Date() } ?? false }
    private var statusTitle: String {
        switch state {
        case .waitingForProvider: "Paused — recovering automatically"
        case .waitingForConfiguration: "Paused — user action required"
        case .recovering: "Recovering provider"
        case .resuming: "Resuming unfinished task"
        default: "Diagnosing provider failure"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(
                statusTitle,
                systemImage: isProviderWait ? "clock" :
                    ([.recovering, .resuming].contains(state) ? "arrow.clockwise" : "exclamationmark.triangle.fill")
            )
            .limaFont(.caption.weight(.semibold))
            .foregroundStyle(LimaTheme.textPrimary)
            Text(message)
                .limaFont(.caption)
                .foregroundStyle(LimaTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let nextAttemptAt, isProviderWait {
                Text("Next eligible attempt: \(nextAttemptAt.formatted(date: .abbreviated, time: .shortened))")
                    .limaFont(.caption.weight(.medium))
                    .foregroundStyle(LimaTheme.textPrimary)
            }
            if isProviderWait || isConfigurationWait {
                HStack(spacing: 7) {
                    Button(isProviderWait ? "Retry Now" : "Resume Task", action: onResume)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(retryBlocked)
                    if isProviderWait {
                        Button("Stop Automatic Recovery", action: onStopAutomaticRecovery)
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                    if isConfigurationWait {
                        Button("Fix Settings", action: onFixSettings)
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: LimaRadius.control))
    }
}
