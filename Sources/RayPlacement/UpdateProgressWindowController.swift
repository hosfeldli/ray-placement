import AppKit
import SwiftUI

@MainActor
final class UpdateProgressWindowController: NSWindowController {
    init(service: UpdateService) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 390),
            styleMask: [.titled, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Lima Update"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentView = NSHostingView(rootView: UpdateProgressView(service: service) { [weak self] in
            self?.close()
        })
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
    let close: () -> Void

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [UpdateColors.indigo.opacity(0.11), .clear, UpdateColors.cyan.opacity(0.055)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if let result = service.completionResult {
                completionView(result)
            } else {
                progressView
            }
        }
        .frame(width: 540, height: 390)
    }

    private var progressView: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                UpdatePulse()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Updating Lima")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(service.installingVersion.map { "Installing version \($0)" } ?? "Preparing update")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("VERIFIED LOCAL BUILD")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(UpdateColors.cyan)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(UpdateColors.cyan.opacity(0.1), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: service.installationProgress)
                    .tint(UpdateColors.indigo)
                HStack {
                    Text(service.installationStage.isEmpty ? "Preparing…" : service.installationStage)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(Int(service.installationProgress * 100))%")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(UpdateColors.indigo)
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.8), in: PrismaticPanelShape(cut: 8))
            .overlay(PrismaticPanelShape(cut: 8).stroke(UpdateColors.indigo.opacity(0.28)))

            VStack(spacing: 11) {
                updateStep("Download small update kit", threshold: 0.08, completeAt: 0.2)
                updateStep("Verify GitHub digest and contents", threshold: 0.2, completeAt: 0.34)
                updateStep("Reuse Whisper, build, and sign locally", threshold: 0.34, completeAt: 0.9)
                updateStep("Close briefly, install, and reopen", threshold: 0.9, completeAt: 1)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Lima stays open while the verified replacement is prepared, then closes briefly and reopens automatically.")
                Text("Detailed log: ~/Library/Application Support/RayPlacement/Updates/update.log")
                    .fontDesign(.monospaced)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(26)
        .accessibilityElement(children: .contain)
    }

    private func updateStep(_ title: String, threshold: Double, completeAt: Double) -> some View {
        let complete = service.installationProgress >= completeAt
        let active = service.installationProgress >= threshold && !complete
        return HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(complete || active ? UpdateColors.indigo : Color.primary.opacity(0.09))
                    .frame(width: 22, height: 22)
                if complete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                } else if active {
                    ProgressView().controlSize(.mini).tint(.white)
                } else {
                    Circle().fill(Color.secondary.opacity(0.4)).frame(width: 5, height: 5)
                }
            }
            Text(title)
                .font(.system(size: 12.5, weight: active ? .semibold : .medium))
                .foregroundStyle(complete || active ? Color.primary : .secondary)
            Spacer()
        }
    }

    private func completionView(_ result: UpdateService.CompletionResult) -> some View {
        VStack(spacing: 17) {
            ZStack {
                Circle().fill((result.succeeded ? Color.green : Color.orange).opacity(0.13))
                Image(systemName: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(result.succeeded ? Color.green : Color.orange)
            }
            .frame(width: 82, height: 82)
            Text(result.succeeded ? "Update complete" : "Update needs attention")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text(result.message)
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
            Button("Done") {
                service.dismissCompletion()
                close()
            }
            .buttonStyle(.borderedProminent)
            .tint(UpdateColors.indigo)
            .keyboardShortcut(.defaultAction)
        }
        .padding(28)
    }
}

private struct UpdatePulse: View {
    @State private var rotation = 0.0
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(UpdateColors.indigo.opacity(pulse ? 0.08 : 0.17)).scaleEffect(pulse ? 1.14 : 0.9)
            Circle()
                .trim(from: 0.08, to: 0.73)
                .stroke(UpdateColors.heroGradient, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(rotation))
                .padding(5)
            Image(systemName: "arrow.down.app.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(UpdateColors.indigo)
        }
        .onAppear {
            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { rotation = 360 }
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityHidden(true)
    }
}

private enum UpdateColors {
    static let indigo = Color(red: 0.33, green: 0.32, blue: 0.95)
    static let violet = Color(red: 0.64, green: 0.31, blue: 0.95)
    static let cyan = Color(red: 0.04, green: 0.67, blue: 0.82)
    static let heroGradient = LinearGradient(colors: [indigo, violet, cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
}
