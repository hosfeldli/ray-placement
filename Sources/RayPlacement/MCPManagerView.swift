import SwiftUI

@MainActor
final class MCPManagerWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MCP Servers"
        window.minSize = NSSize(width: 620, height: 440)
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LimaTypographyRoot(content: MCPManagerView()))
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct MCPManagerView: View {
    @ObservedObject private var store = MCPServerStore.shared
    @State private var selectedID: UUID?
    @State private var name = ""
    @State private var url = ""
    @State private var transport: MCPTransport = .streamableHTTP
    @State private var token = ""
    @State private var status: String?
    @State private var isTesting = false

    var body: some View {
        HStack(spacing: 0) {
            serverList
            Divider()
            editor
        }
        .frame(minWidth: 620, minHeight: 440)
        .onAppear { select(store.servers.first) }
    }

    private var serverList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MCP Servers").limaFont(.headline)
                Spacer()
                Button { newServer() } label: { Image(systemName: "plus") }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 14).padding(.top, 14)
            if store.servers.isEmpty {
                Text("Connect remote HTTP MCP servers to give AI Chat approved tools.")
                    .limaFont(.caption).foregroundStyle(LimaColors.secondaryText)
                    .padding(14)
            } else {
                List(store.servers, selection: $selectedID) { server in
                    Button { select(server) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: server.enabled ? "circle.fill" : "circle")
                                .foregroundStyle(server.lastError == nil ? LimaColors.success : LimaColors.danger)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name).limaFont(.callout.weight(.medium))
                                Text("\(server.enabledTools.count) enabled tools")
                                    .limaFont(.caption2).foregroundStyle(LimaColors.secondaryText)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .tag(server.id)
                }
                .listStyle(.sidebar)
            }
            Spacer()
            Text("Credentials are stored in Keychain. Server definitions contain no secrets.")
                .limaFont(.caption2).foregroundStyle(LimaColors.tertiaryText).padding(12)
        }
        .frame(width: 245)
        .background(LimaColors.sidebarBackground)
    }

    @ViewBuilder
    private var editor: some View {
        if let server = store.servers.first(where: { $0.id == selectedID }) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name).limaFont(.title3.weight(.semibold))
                        Text(server.lastError == nil ? "Remote HTTP MCP" : (server.lastError ?? "Error"))
                            .limaFont(.caption).foregroundStyle(server.lastError == nil ? LimaColors.secondaryText : LimaColors.danger)
                    }
                    Spacer()
                    Toggle("Enabled", isOn: Binding(get: { server.enabled }, set: { store.setEnabled(server.id, enabled: $0) }))
                        .toggleStyle(.switch)
                }
                TextField("Server name", text: $name)
                    .textFieldStyle(.roundedBorder)
                TextField("https://example.com/mcp", text: $url)
                    .textFieldStyle(.roundedBorder)
                Picker("Transport", selection: $transport) {
                    ForEach(MCPTransport.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                SecureField("Bearer token (optional)", text: $token)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(isTesting ? "Testing…" : "Test & Discover Tools") { test(server) }
                        .buttonStyle(.borderedProminent).disabled(isTesting)
                    Button("Save") { save(server) }.buttonStyle(.bordered)
                    Spacer()
                    Button("Remove", role: .destructive) { store.remove(id: server.id); select(store.servers.first) }
                        .buttonStyle(.borderless)
                }
                if let status { Text(status).limaFont(.caption).foregroundStyle(.secondary) }
                Divider()
                Text("Tools and permissions").limaFont(.headline)
                if server.tools.isEmpty {
                    Text("Test the connection to discover tools. Read tools run automatically; write and destructive tools require approval.")
                        .limaFont(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(server.tools) { tool in
                                HStack {
                                    Toggle("", isOn: Binding(get: { toolIsEnabled(tool, server: server) }, set: { setToolEnabled(tool, enabled: $0, server: server) }))
                                        .labelsHidden()
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tool.displayTitle).limaFont(.callout)
                                        Text("\(tool.risk.title) · \(tool.description ?? "No description")")
                                            .limaFont(.caption2).foregroundStyle(LimaColors.secondaryText).lineLimit(2)
                                    }
                                    Spacer()
                                    if tool.risk.requiresApproval { Label("Ask", systemImage: "hand.raised") .limaFont(.caption2).foregroundStyle(LimaColors.warning) }
                                }
                                .padding(8)
                                .background(LimaColors.recessedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                    }
                }
                Spacer()
            }
            .padding(22)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "server.rack").font(.system(size: 28)).foregroundStyle(SettingsStore.shared.accentTheme.readablePrimary)
                Text("Add an MCP server").limaFont(.title3.weight(.semibold))
                Text("Use the plus button to configure a remote HTTP MCP connection.").foregroundStyle(.secondary)
                Button("Add Server", action: newServer).buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func select(_ server: MCPServer?) {
        selectedID = server?.id
        name = server?.name ?? ""
        url = server?.url ?? ""
        transport = server?.transport ?? .streamableHTTP
        token = ""
        status = nil
    }

    private func newServer() {
        let server = MCPServer(name: "New Server", url: "https://")
        store.addOrUpdate(server)
        select(server)
    }

    private func save(_ server: MCPServer) {
        var updated = server
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "MCP Server" : name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.transport = transport
        store.addOrUpdate(updated)
        if !token.isEmpty { try? MCPCredentialStore.save(serverID: server.id, value: token); token = "" }
        status = "Saved."
    }

    private func test(_ server: MCPServer) {
        save(server)
        guard let current = store.servers.first(where: { $0.id == server.id }) else { return }
        isTesting = true
        status = "Discovering tools…"
        Task {
            do {
                let tools = try await MCPHTTPClient().test(server: current)
                store.updateTools(tools, for: current.id)
                status = "Connected · \(tools.count) tools discovered."
            } catch { status = error.localizedDescription }
            isTesting = false
        }
    }

    private func toolIsEnabled(_ tool: MCPToolDescriptor, server: MCPServer) -> Bool {
        server.allowedToolNames.isEmpty || server.allowedToolNames.contains(tool.name)
    }

    private func setToolEnabled(_ tool: MCPToolDescriptor, enabled: Bool, server: MCPServer) {
        var names = server.allowedToolNames.isEmpty ? server.tools.map(\.name) : server.allowedToolNames
        names.removeAll { $0 == tool.name }
        if enabled { names.append(tool.name) }
        var updated = server
        updated.allowedToolNames = names
        store.addOrUpdate(updated)
    }
}
