import AppKit
import RayPlacementCore
import SwiftUI

@MainActor
struct BrowserBridgeSettingsView: View {
    @ObservedObject private var bridge = BrowserBridgeService.shared
    @State private var message: String?
    @State private var installed = false
    @State private var confirmInstall = false
    @State private var confirmRemove = false
    @State private var busy = false
    @State private var grants: [String] = []
    @State private var tabs: [BridgeTab] = []
    @State private var selectedTab: Int?
    @State private var destination = ""
    @State private var caseNumber = ""
    @State private var inspection = ""
    @State private var operation: Task<Void, Never>?
    @State private var isPresented = false

    struct BridgeTab: Decodable, Identifiable {
        let id: Int
        let title: String
        let url: String
    }

    private var executable: URL {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/LimaBrowserBridgeHost")
        #if DEBUG
        if !FileManager.default.isExecutableFile(atPath: bundled.path) {
            return URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("LimaBrowserBridgeHost")
        }
        #endif
        return bundled
    }

    private var packageDirectory: URL {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/BrowserBridge")
        #if DEBUG
        if !FileManager.default.fileExists(atPath: bundled.path) {
            return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("BrowserBridge")
        }
        #endif
        return bundled
    }

    private var signedPackage: URL { packageDirectory.appendingPathComponent("lima-browser-bridge-signed.xpi") }

    var body: some View {
        Form {
            Section("Zen / Firefox Browser Bridge") {
                Toggle("Enable browser bridge", isOn: $bridge.enabled)
                LabeledContent("Connection", value: bridge.status)
                LabeledContent("Native helper", value: installed ? "Installed for this app" : "Setup or repair required")
                Text("Page access is opt-in per HTTPS site. No private windows, passwords, arbitrary scripts, or background browsing capture.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(installed ? "Repair Native Helper…" : "Install Native Helper…") { confirmInstall = true }
                    Button("Remove Helper…") { confirmRemove = true }.disabled(!installed)
                    Button("Show Companion Files") {
                        NSWorkspace.shared.activateFileViewerSelecting([packageDirectory])
                    }
                    if FileManager.default.fileExists(atPath: signedPackage.path) {
                        Button("Show Companion XPI") {
                            NSWorkspace.shared.activateFileViewerSelecting([signedPackage])
                        }
                    }
                }
                Text("For a bundled signed XPI, use Install Add-on From File in the browser\'s Add-ons manager. Load manifest.json via about:debugging for development. Permanent installation requires a Mozilla-signed XPI; an unsigned package is not a production installer. No browser security settings need to be disabled.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("In the companion popup, grant only the sites needed, then connect to Lima. Helper installation is per-user and must be repaired if Lima moves.")
                    .font(.caption).foregroundStyle(.secondary)
                if bridge.sessions.count > 1 {
                    Picker("Browser connection", selection: $bridge.selectedSession) {
                        Text("Choose a connection").tag(Optional<UUID>.none)
                        ForEach(bridge.sessions, id: \.self) { id in
                            Text("Session \(id.uuidString.prefix(8))").tag(Optional(id))
                        }
                    }.disabled(busy)
                }
                Button("Test Connection & Refresh Sites") { run { try await refresh() } }
                    .disabled(!bridge.enabled || busy)
                if let message { Text(message).font(.caption).textSelection(.enabled) }
            }
            Section("Site access") {
                if grants.isEmpty {
                    Text("No granted sites reported. Grant a site using the browser companion, then refresh.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(grants, id: \.self) { Text($0).font(.caption.monospaced()) }
                Text("Revoke access in the companion popup. Revocations invalidate pending reads and approvals. Data already added to a conversation is not erased. Browser context used by AI is sent to the conversation's selected provider.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Browser interactions") {
                Toggle("Open new tabs in the background", isOn: $bridge.openInBackground)
                Button("Refresh Granted Tabs") {
                    run {
                        let result = try await bridge.request("browser.tabs")
                        struct Result: Decodable { var tabs: [BridgeTab] }
                        tabs = try JSONDecoder().decode(Result.self, from: JSONEncoder().encode(result)).tabs
                        if !tabs.contains(where: { $0.id == selectedTab }) { selectedTab = tabs.first?.id }
                    }
                }.disabled(busy || !bridge.enabled)
                Picker("Tab", selection: $selectedTab) {
                    Text("Select a granted tab").tag(Optional<Int>.none)
                    ForEach(tabs) { tab in
                        Text(tab.title.isEmpty ? tab.url : tab.title).tag(Optional(tab.id))
                    }
                }
                if let tab = tabs.first(where: { $0.id == selectedTab }) {
                    Text(tab.url).font(.caption).lineLimit(2).textSelection(.enabled)
                    HStack {
                        Button("Read Page") {
                            run {
                                let result = try await bridge.request("browser.read", arguments: ["tabID": .number(Double(tab.id))])
                                if isPresented, case .object(let fields) = result, case .string(let text)? = fields["text"] { inspection = text }
                            }
                        }
                        Button("Focus Tab…") { mutate("browser.focus", tab: tab) }
                        Button("Close Tab…") { mutate("browser.close", tab: tab) }
                    }.disabled(busy)
                    HStack {
                        TextField("Exact Salesforce case number", text: $caseNumber)
                        Button("Resolve Case") {
                            run {
                                let result = try await bridge.resolveCase(number: caseNumber, tabID: tab.id)
                                if case .object(let fields) = result {
                                    if case .string(let url)? = fields["recordURL"] {
                                        destination = url
                                        message = "Exact case found. Review the destination before opening."
                                    } else if case .string(let status)? = fields["status"] {
                                        message = "Case lookup: \(status). No navigation was performed."
                                    } else { message = "Case lookup could not complete." }
                                }
                            }
                        }.disabled(busy || caseNumber.isEmpty)
                    }
                }
                TextField("HTTPS destination URL", text: $destination)
                HStack {
                    Button("Open New Tab…") {
                        mutate("browser.open", extra: ["url": .string(destination), "active": .bool(!bridge.openInBackground)])
                    }.disabled(busy || destination.isEmpty)
                    if let tab = tabs.first(where: { $0.id == selectedTab }) {
                        Button("Navigate Selected Tab…") {
                            mutate("browser.navigate", tab: tab, extra: ["url": .string(destination)])
                        }.disabled(busy || destination.isEmpty)
                    }
                    if busy { Button("Cancel", role: .cancel) { operation?.cancel() } }
                }
                Text("Tab changes wait for Allow Once in the companion popup (badge !). Destinations must also have an explicit site grant.")
                    .font(.caption).foregroundStyle(.secondary)
                if !inspection.isEmpty {
                    DisclosureGroup("Page preview (not saved)") {
                        ScrollView { Text(inspection).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(height: 160)
                    }
                }
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden).controlSize(.small)
        .onAppear { isPresented = true; installed = BrowserBridgeInstallation.isInstalled(executable: executable) }
        // Leaving Settings is navigation; pending work remains stoppable in Activity Shelf.
        .onDisappear { isPresented = false; inspection = "" }
        .onChange(of: bridge.selectedSession) { _ in grants = []; tabs = []; selectedTab = nil; inspection = ""; destination = "" }
        .onChange(of: bridge.enabled) { _ in grants = []; tabs = []; selectedTab = nil; inspection = "" }
        .alert("Install browser native helper?", isPresented: $confirmInstall) {
            Button("Cancel", role: .cancel) {}
            Button("Install") {
                do {
                    try BrowserBridgeInstallation.install(executable: executable)
                    installed = BrowserBridgeInstallation.isInstalled(executable: executable)
                    message = "Native helper registered. Install/load the companion, then connect."
                } catch { message = "Helper setup failed. Build or reinstall Lima, then try again." }
            }
        } message: {
            Text("Create or repair per-user Mozilla and Zen native-host manifests pointing to this Lima app. Only the Lima companion's fixed extension ID is allowed.")
        }
        .alert("Remove browser native helper?", isPresented: $confirmRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                do {
                    try BrowserBridgeInstallation.uninstall()
                    bridge.enabled = false
                    installed = false
                    message = "Native-host manifests removed. Browser site grants remain manageable in the companion."
                } catch { message = "Could not remove helper manifests; unrelated files were left untouched." }
            }
        }
    }

    private func refresh() async throws {
        let result = try await bridge.request("bridge.status")
        guard case .object(let fields) = result, case .array(let sites)? = fields["origins"] else {
            throw BrowserBridgeError.invalidResponse
        }
        grants = sites.compactMap { if case .string(let value) = $0 { return value }; return nil }.sorted()
        message = "End-to-end connection verified."
    }

    private func mutate(_ command: String, tab: BridgeTab? = nil, extra: [String: JSONValue] = [:]) {
        var arguments = extra
        if let tab {
            arguments["tabID"] = .number(Double(tab.id))
            arguments["expectedURL"] = .string(tab.url)
        }
        message = "Review this action in the browser companion popup."
        run { _ = try await bridge.request(command, arguments: arguments); message = nil }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        operation = Task {
            defer { busy = false; operation = nil }
            do { try await action() }
            catch is CancellationError { message = "Cancelled." }
            catch { message = error.localizedDescription }
        }
    }
}
