import AppKit
import SwiftUI

@MainActor
final class BrowserBridgeSetupWindowController: NSWindowController {
    private let service = BrowserBridgeService.shared

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        LimaWindowChrome.configure(
            window,
            title: "Lima Browser Bridge",
            accessibilityLabel: "Lima browser bridge setup",
            minSize: NSSize(width: 620, height: 500),
            movableByBackground: false
        )
        self.init(window: window)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: LimaTypographyRoot(content: BrowserBridgeSetupView(service: service))
        )
    }

    func present() {
        service.start()
        service.refreshActivePage()
        window?.center()
        showWindow(nil)
        if let window { WorkspaceWindowCoordinator.shared.present(window) }
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct BrowserBridgeSetupView: View {
    @ObservedObject var service: BrowserBridgeService
    @State private var actionMessage: String?
    @State private var testCases = ""

    var body: some View {
        ZStack {
            LiquidGlassBackdrop(material: .underWindowBackground, blendingMode: .behindWindow)
            VStack(spacing: 12) {
                header
                ScrollView {
                    VStack(spacing: 10) {
                        setupCard
                        permissionsCard
                        testCard
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(12)
        }
        .onAppear { service.refreshActivePage() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(SettingsStore.shared.accentTheme.primary.opacity(0.13))
                Image(systemName: "globe.badge.chevron.backward")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(SettingsStore.shared.accentTheme.readablePrimary)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text("Browser Bridge").limaFont(.headline)
                Text("Read and control explicitly approved Zen/Firefox pages without arbitrary JavaScript.")
                    .limaFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusBadge
        }
        .padding(12)
        .limaNativeSurface(fill: LimaColors.raisedSurface, radius: LimaRadius.panel, border: LimaColors.border)
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(service.isConnected ? LimaColors.success : LimaColors.warning)
                .frame(width: 7, height: 7)
            Text(service.isConnected ? "Connected" : "Not connected")
                .limaFont(.caption.weight(.semibold))
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .limaNativeSurface(fill: LimaColors.recessedSurface, radius: LimaRadius.control, border: LimaColors.border)
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SETUP").limaFont(.caption2.weight(.bold)).foregroundStyle(.secondary)

            setupRow(
                symbol: "safari",
                title: "Zen Browser",
                detail: BrowserBridgeInstaller.zenApplicationURL == nil
                    ? "Zen Browser was not found in Launch Services."
                    : "Zen Browser is installed.",
                complete: BrowserBridgeInstaller.zenApplicationURL != nil
            )

            setupRow(
                symbol: "point.3.connected.trianglepath.dotted",
                title: "Native messaging host",
                detail: BrowserBridgeInstaller.nativeManifestInstalled
                    ? "Installed for this macOS user."
                    : "Lima installs a per-user Mozilla native-messaging manifest.",
                complete: BrowserBridgeInstaller.nativeManifestInstalled
            ) {
                Button("Repair") {
                    do {
                        try BrowserBridgeInstaller.installNativeMessagingHost()
                        actionMessage = "Native messaging host installed."
                    } catch {
                        actionMessage = error.localizedDescription
                    }
                }
                .controlSize(.small)
            }

            setupRow(
                symbol: "puzzlepiece.extension",
                title: "Lima Zen/Firefox Extension",
                detail: extensionDetail,
                complete: service.isConnected
            ) {
                HStack(spacing: 6) {
                    Button(service.isConnected ? "Reinstall" : "Install in Zen") {
                        BrowserBridgeInstaller.openExtensionInstaller { result in
                            switch result {
                            case .success:
                                actionMessage = "Zen opened the extension installer. Approve the browser prompt, then grant Lima access on the Salesforce site you want to use."
                            case .failure(let error):
                                actionMessage = error.localizedDescription
                            }
                        }
                    }
                    .controlSize(.small)
                    .disabled(BrowserBridgeInstaller.zenApplicationURL == nil)

                    Button("Add-ons") { BrowserBridgeInstaller.openZenAddOns() }
                        .controlSize(.small)
                        .disabled(BrowserBridgeInstaller.zenApplicationURL == nil)
                }
            }

            if let actionMessage {
                Text(actionMessage)
                    .limaFont(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(13)
        .limaNativeSurface(fill: LimaColors.raisedSurface, radius: LimaRadius.panel, border: LimaColors.border)
    }

    private var extensionDetail: String {
        if service.isConnected { return "Installed and connected to Lima." }
        switch BrowserBridgeInstaller.extensionBuildKind {
        case "signed":
            return "Signed production XPI bundled with Lima."
        case "unsigned-development":
            return "Development XPI bundled. Normal Zen releases require Mozilla signing for permanent installation."
        default:
            return "Extension package bundled with Lima."
        }
    }

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("SITE ACCESS").limaFont(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text("The extension starts with no persistent webpage access. Click its toolbar button in Zen and approve the current site before Lima can read or interact with that page.")
                .limaFont(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Label("No password values", systemImage: "lock.shield")
                Label("No payment-field values", systemImage: "creditcard.trianglebadge.exclamationmark")
                Label("No arbitrary JS tool", systemImage: "curlybraces.square")
            }
            .limaFont(.caption2.weight(.medium))
            .foregroundStyle(.secondary)

            if let title = service.activePageTitle, let url = service.activePageURL {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).limaFont(.callout.weight(.semibold)).lineLimit(1)
                    Text(url).limaFont(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(13)
        .limaNativeSurface(fill: LimaColors.raisedSurface, radius: LimaRadius.panel, border: LimaColors.border)
    }

    private var testCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("SALESFORCE CASE TEST").limaFont(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text("With an approved Salesforce page active in Zen, enter case numbers. Lima resolves matching case links from the current DOM and opens each record in a background tab.")
                .limaFont(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("01234567, 01234568", text: $testCases)
                    .textFieldStyle(.roundedBorder)
                Button("Open Cases") {
                    let values = testCases
                        .components(separatedBy: CharacterSet(charactersIn: ", \n\t"))
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    service.openSalesforceCases(values) { result in
                        switch result {
                        case .success(let payload):
                            let opened = payload["opened"] as? [String] ?? []
                            let unresolved = payload["unresolved"] as? [String] ?? []
                            actionMessage = unresolved.isEmpty
                                ? "Opened \(opened.count) Salesforce case tab\(opened.count == 1 ? "" : "s")."
                                : "Opened \(opened.count). Not found on the current page: \(unresolved.joined(separator: ", "))."
                        case .failure(let error):
                            actionMessage = error.localizedDescription
                        }
                    }
                }
                .disabled(!service.isConnected || testCases.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(13)
        .limaNativeSurface(fill: LimaColors.raisedSurface, radius: LimaRadius.panel, border: LimaColors.border)
    }

    @ViewBuilder
    private func setupRow<Actions: View>(
        symbol: String,
        title: String,
        detail: String,
        complete: Bool,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: complete ? "checkmark.circle.fill" : symbol)
                .foregroundStyle(complete ? LimaColors.success : SettingsStore.shared.accentTheme.readablePrimary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).limaFont(.callout.weight(.semibold))
                Text(detail).limaFont(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            actions()
        }
    }

    private func setupRow(
        symbol: String,
        title: String,
        detail: String,
        complete: Bool
    ) -> some View {
        setupRow(symbol: symbol, title: title, detail: detail, complete: complete) { EmptyView() }
    }
}
