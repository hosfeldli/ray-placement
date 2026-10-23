import AppKit
import SwiftUI

/// A compact, explicit launcher surface. Opening it only inspects connection
/// status; a bandwidth-intensive test starts solely from the Run button.
@MainActor
final class NetworkQualityWindowController: NSObject, NSWindowDelegate {
    static let shared = NetworkQualityWindowController()

    private let service = NetworkQualityService.shared
    private var panel: NSPanel?
    private weak var returnApplication: NSRunningApplication?

    func present(returningTo application: NSRunningApplication? = nil) {
        if let application, application.bundleIdentifier != Bundle.main.bundleIdentifier {
            returnApplication = application
        }
        if panel == nil {
            let panel = NetworkQualityPanel(
                contentRect: NSRect(x: 0, y: 0, width: 470, height: 480),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            panel.title = "Internet Speed Test"
            panel.isReleasedWhenClosed = false
            panel.onCancel = { [weak self] in self?.dismiss() }
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: NetworkQualityView(
                service: service, close: { [weak self] in self?.dismiss() }
            ))
            panel.center()
            self.panel = panel
        }
        service.refreshConnection()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if service.phase == .running { service.cancel() }
        returnApplication?.activate(options: [.activateIgnoringOtherApps])
    }

    private func dismiss() {
        if service.phase == .running { service.cancel() }
        panel?.orderOut(nil)
        returnApplication?.activate(options: [.activateIgnoringOtherApps])
    }
}

private final class NetworkQualityPanel: NSPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
private struct NetworkQualityView: View {
    @ObservedObject var service: NetworkQualityService
    let close: () -> Void
    @State private var copied = false
    @State private var launchError: String?

    private var isActive: Bool {
        service.phase == .running || service.phase == .cancelling
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Internet Speed Test").font(.title2.weight(.semibold))
                Spacer()
                Text(service.connectionDescription)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Uses macOS networkQuality. A run actively downloads and uploads data, potentially hundreds of megabytes. Results describe this test path, not every Internet service.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let result = service.latestResult {
                HStack(spacing: 12) {
                    metric("Download", value: result.downloadMbps)
                    metric("Upload", value: result.uploadMbps)
                }
                HStack {
                    if let latency = result.idleLatencyMilliseconds {
                        Label(String(format: "Idle latency %.1f ms", latency), systemImage: "timer")
                    }
                    Spacer()
                    if let responsiveness = result.responsiveness {
                        Text(responsiveness).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("Measured with \(result.method) · \(result.startedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("No test result yet")
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity, minHeight: 100)
            }

            if isActive {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(service.phase == .cancelling ? "Stopping test…" : "Measuring network quality…")
                        .font(.caption)
                }
            }
            if let error = launchError ?? service.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("network-quality-error")
            }

            Divider()
            Text("Recent tests").font(.subheadline.weight(.semibold))
            if service.results.isEmpty {
                Text("Run a test to begin a local comparison history.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List(service.results.prefix(20)) { result in
                    HStack {
                        Text(result.startedAt.formatted(date: .abbreviated, time: .shortened))
                        Spacer()
                        Text(String(format: "↓ %.1f  ↑ %.1f Mbps",
                                    result.downloadMbps, result.uploadMbps))
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
                .accessibilityIdentifier("network-quality-history")
            }

            HStack {
                Button("Close", action: close)
                Spacer()
                if service.latestResult != nil {
                    Button(copied ? "Copied" : "Copy Result") { copyLatest() }
                        .disabled(isActive)
                }
                if isActive {
                    Button("Cancel Test") { service.cancel() }
                        .disabled(service.phase == .cancelling)
                } else {
                    Button("Run Speed Test") {
                        copied = false
                        launchError = nil
                        do { _ = try service.start() }
                        catch { launchError = error.localizedDescription }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
        .frame(width: 470, height: 480)
    }

    private func metric(_ title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%.1f", value))
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("Mbps").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func copyLatest() {
        guard let result = service.latestResult else { return }
        var lines = [
            "Network quality · \(result.startedAt.formatted(date: .abbreviated, time: .shortened))",
            String(format: "Download: %.1f Mbps", result.downloadMbps),
            String(format: "Upload: %.1f Mbps", result.uploadMbps)
        ]
        if let latency = result.idleLatencyMilliseconds {
            lines.append(String(format: "Idle latency: %.1f ms", latency))
        }
        if let responsiveness = result.responsiveness {
            lines.append("Responsiveness: \(responsiveness)")
        }
        lines.append("Method: \(result.method)")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        copied = pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
