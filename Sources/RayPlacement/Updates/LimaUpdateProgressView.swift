import SwiftUI

/// Only download bytes expose measurable progress in the legacy recovery
/// updater. Verification, installation, and relaunch remain indeterminate;
/// Sparkle owns its own progress UI in the production update backend.
enum LimaUpdateProgressPresentation {
    static func measuredDownloadFraction(
        canCancelDownload: Bool,
        downloadedBytes: Int64,
        totalBytes: Int64
    ) -> Double? {
        guard canCancelDownload, totalBytes > 0 else { return nil }
        return min(max(Double(downloadedBytes) / Double(totalBytes), 0), 1)
    }
}

struct LimaUpdateProgressView: View {
    @ObservedObject var updateService: UpdateService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if updateService.isInstalling {
                if let fraction = LimaUpdateProgressPresentation.measuredDownloadFraction(
                    canCancelDownload: updateService.canCancelInstallation,
                    downloadedBytes: updateService.downloadedBytes,
                    totalBytes: updateService.totalDownloadBytes
                ) {
                    ProgressView(value: fraction)
                        .accessibilityLabel("Update download")
                        .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
                    if let detail = updateService.formattedDownloadProgress {
                        Text(detail)
                            .limaFont(.caption2)
                            .foregroundStyle(LimaTheme.textSecondary)
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Update in progress")
                }
                Text(updateService.installationStage)
                    .limaFont(.caption2.weight(.medium))
                    .foregroundStyle(LimaTheme.textSecondary)
                if updateService.canCancelInstallation {
                    Button("Cancel Download") { updateService.cancelInstallation() }
                        .buttonStyle(.borderless)
                }
            }
            if updateService.completionResult?.succeeded == false &&
                updateService.canRetryInstallation {
                Button("Retry Update") { updateService.retryInstallation() }
                    .buttonStyle(.bordered)
            }
        }
    }
}
