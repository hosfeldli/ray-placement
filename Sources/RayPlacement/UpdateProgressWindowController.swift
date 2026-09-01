import AppKit
import SwiftUI

@MainActor
final class UpdateProgressWindowController: NSWindowController {
    init(service: UpdateService) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 470),
            styleMask: [.titled, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Lima Update"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentView = NSHostingView(rootView: LimaTypographyRoot(content: UpdateProgressView(service: service) { [weak self] in
            self?.close()
        }))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct UpdateProgressView: View {
    @ObservedObject var service: UpdateService
    @ObservedObject private var settings = SettingsStore.shared
    let close: () -> Void

    var body: some View {
        ZStack {
            LiquidGlassBackdrop(material: .hudWindow, blendingMode: .withinWindow)
            if let result = service.completionResult {
                completionView(result)
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            } else {
                progressView.transition(.opacity)
            }
        }
        .frame(width: 620, height: 470)
        .tint(settings.accentTheme.primary)
        .animation(.easeOut(duration: 0.18), value: service.completionResult)
    }

    private var progressView: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            stageCard
            steps
            if let notice = contextualNotice { noticeCard(notice) }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button("Show Log") { service.revealUpdateLog() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                Spacer()
                if service.canCancelInstallation {
                    Button("Cancel Update") { service.cancelInstallation() }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                } else {
                    Label("Lima stays open until replacement is ready", systemImage: "shield.checkered")
                        .limaFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(26)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 14) {
            UpdatePulse(color: settings.accentTheme.primary, gradient: settings.accentTheme.gradient)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text("Lima Update")
                    .limaFont(.system(size: 21, weight: .bold, design: .rounded))
                Text(service.installingVersion.map { "Installing version \($0)" } ?? "Preparing a verified update")
                    .limaFont(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(elapsedText(at: context.date))
                    .limaFont(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .liquidGlass(cornerRadius: 7, depth: .recessed, accentOpacity: 0.01)
            }
        }
    }

    private var stageCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text(service.installationStage.isEmpty ? "Preparing…" : service.installationStage)
                    .limaFont(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 12)
                Text("\(Int(service.installationProgress * 100))%")
                    .limaFont(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(settings.accentTheme.tertiary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.075))
                    Capsule()
                        .fill(settings.accentTheme.gradient)
                        .frame(width: max(4, proxy.size.width * service.installationProgress))
                        .shadow(color: settings.accentTheme.primary.opacity(0.35), radius: 7)
                }
            }
            .frame(height: 6)
            if let bytes = service.formattedDownloadProgress, service.installationProgress < 0.25 {
                Text(bytes)
                    .limaFont(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(15)
        .liquidGlass(cornerRadius: 11, depth: .raised, accentOpacity: 0.035)
    }

    private var steps: some View {
        HStack(spacing: 7) {
            updateStep("Download", symbol: "arrow.down", startsAt: 0.0, completesAt: 0.25)
            connector(complete: service.installationProgress >= 0.25)
            updateStep("Verify", symbol: "checkmark.shield", startsAt: 0.25, completesAt: 0.52)
            connector(complete: service.installationProgress >= 0.52)
            updateStep("Prepare", symbol: "shippingbox", startsAt: 0.52, completesAt: 0.90)
            connector(complete: service.installationProgress >= 0.90)
            updateStep("Replace", symbol: "arrow.triangle.2.circlepath", startsAt: 0.90, completesAt: 1.0)
        }
    }

    private func updateStep(_ title: String, symbol: String, startsAt: Double, completesAt: Double) -> some View {
        let complete = service.installationProgress >= completesAt
        let active = service.installationProgress >= startsAt && !complete
        return VStack(spacing: 6) {
            ZStack {
                PrismaticPanelShape(cut: 5)
                    .fill(complete || active ? AnyShapeStyle(settings.accentTheme.gradient) : AnyShapeStyle(Color.white.opacity(0.06)))
                    .frame(width: 28, height: 28)
                Image(systemName: complete ? "checkmark" : symbol)
                    .limaFont(.system(size: 11, weight: .bold))
                    .foregroundStyle(complete || active ? Color.white : .secondary)
            }
            Text(title)
                .limaFont(.caption2.weight(active ? .bold : .medium))
                .foregroundStyle(complete || active ? Color.primary : .secondary)
        }
        .frame(width: 72)
    }

    private func connector(complete: Bool) -> some View {
        Rectangle()
            .fill(complete ? AnyShapeStyle(settings.accentTheme.gradient) : AnyShapeStyle(Color.white.opacity(0.08)))
            .frame(maxWidth: .infinity, maxHeight: 1)
            .offset(y: -9)
    }

    private var contextualNotice: (symbol: String, title: String, detail: String)? {
        let stage = service.installationStage.lowercased()
        if stage.contains("administrator") || stage.contains("approval") {
            return ("lock.shield", "macOS approval needed", "Approve the system dialog so Lima can replace the copy in Applications. Canceling leaves the current app untouched.")
        }
        if stage.contains("trust prompt") || stage.contains("code-signing") {
            return ("person.badge.key", "One-time signing approval", "This preserves Lima’s identity so Accessibility permissions continue to follow future updates.")
        }
        if stage.contains("dictation model") {
            return ("waveform", "Keeping dictation local", "Lima is verifying or restoring the on-device speech resource; it is not bundled into every update.")
        }
        return nil
    }

    private func noticeCard(_ notice: (symbol: String, title: String, detail: String)) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: notice.symbol)
                .foregroundStyle(settings.accentTheme.tertiary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title).limaFont(.caption.weight(.bold))
                Text(notice.detail).limaFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .liquidGlass(cornerRadius: 9, depth: .recessed, accentOpacity: 0.018)
    }

    private func completionView(_ result: UpdateService.CompletionResult) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                ZStack {
                    PrismaticPanelShape(cut: 8)
                        .fill(result.succeeded ? AnyShapeStyle(Color.green.opacity(0.18)) : AnyShapeStyle(Color.orange.opacity(0.18)))
                    Image(systemName: result.succeeded ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .limaFont(.system(size: 22, weight: .semibold))
                        .foregroundStyle(result.succeeded ? Color.green : Color.orange)
                }
                .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.succeeded ? "Lima is up to date" : "Update not installed")
                        .limaFont(.system(size: 21, weight: .bold, design: .rounded))
                    Text(result.succeeded ? "The new app passed its relaunch check." : "Your current copy of Lima was left unchanged.")
                        .limaFont(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Text(result.message)
                .limaFont(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .liquidGlass(cornerRadius: 11, depth: .raised, accentOpacity: result.succeeded ? 0.025 : 0.04)

            if !result.succeeded {
                Label("Retry first. If macOS still blocks replacement, use the DMG; the update log contains the exact failed step.", systemImage: "info.circle")
                    .limaFont(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            HStack(spacing: 10) {
                Button("Show Log") { service.revealUpdateLog() }.buttonStyle(.borderless)
                if !result.succeeded {
                    Button("Download DMG") { service.openManualDownload() }.buttonStyle(.bordered)
                }
                Spacer()
                if !result.succeeded && service.canRetryInstallation {
                    Button("Retry") { service.retryInstallation() }.buttonStyle(.borderedProminent)
                }
                if result.succeeded {
                    Button("Done") {
                        service.dismissCompletion()
                        close()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Close") {
                        service.dismissCompletion()
                        close()
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
    }

    private func elapsedText(at date: Date) -> String {
        guard let started = service.installationStartedAt else { return "READY" }
        let seconds = max(0, Int(date.timeIntervalSince(started)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct UpdatePulse: View {
    let color: Color
    let gradient: LinearGradient
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation = 0.0

    var body: some View {
        ZStack {
            PrismaticPanelShape(cut: 8).fill(color.opacity(0.14))
            PrismaticPanelShape(cut: 8)
                .trim(from: 0.06, to: 0.72)
                .stroke(gradient, style: StrokeStyle(lineWidth: 2.5, lineCap: .square))
                .rotationEffect(.degrees(rotation))
                .padding(4)
            Image(systemName: "arrow.down.app.fill")
                .limaFont(.system(size: 17, weight: .bold))
                .foregroundStyle(color)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) { rotation = 360 }
        }
        .accessibilityHidden(true)
    }
}
