import AppKit
import SwiftUI

/// User-facing management for paired local and TLS network AI connections.
@MainActor
struct LimaAccessSettingsView: View {
    @ObservedObject private var access = LimaAccessService.shared
    @State private var proposedName = "AI on this Mac"
    @State private var selectedNetworkAddress = ""
    @State private var pairingTransport: LimaAccessTransport = .local
    @State private var pairingToken: String?
    @State private var message: String?

    private var canPair: Bool {
        pairingTransport == .local
            ? (access.localEnabled && access.isRunning)
            : (access.networkEnabled && access.isNetworkRunning)
    }

    private var pairingEndpoint: String {
        pairingTransport == .local ? access.endpoint : (access.networkEndpoint ?? "Off")
    }

    var body: some View {
        Form {
            Section("Local AI Connections") {
                Toggle("Allow AI apps on this Mac", isOn: Binding(
                    get: { access.localEnabled && access.isRunning },
                    set: { access.setLocalEnabled($0) }
                ))
                Text("Off by default. Local clients receive separate Keychain-backed credentials.")
                    .font(.caption).foregroundStyle(.secondary)
                if let status = access.statusMessage {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Local address", value: access.isRunning ? access.endpoint : "Off")
            }

            Section("Network AI Connections") {
                Picker("Private address", selection: $selectedNetworkAddress) {
                    if access.availableNetworkAddresses.isEmpty {
                        Text("No private LAN or Tailscale address").tag("")
                    }
                    ForEach(access.availableNetworkAddresses, id: \.self) { address in
                        Text(address).tag(address)
                    }
                }
                .disabled(access.networkEnabled || access.availableNetworkAddresses.isEmpty)
                Toggle("Allow trusted AIs on this network", isOn: Binding(
                    get: { access.networkEnabled },
                    set: { enabled in
                        do {
                            try access.setNetworkEnabled(enabled, on: selectedNetworkAddress)
                            message = nil
                        } catch {
                            message = error.localizedDescription
                        }
                    }
                ))
                .disabled(!access.networkEnabled && selectedNetworkAddress.isEmpty)
                if let status = access.networkStatusMessage {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("TLS address", value: access.isNetworkRunning ? (access.networkEndpoint ?? "Off") : "Off")
                if let fingerprint = access.networkCertificateFingerprint,
                   let certificate = access.networkCertificatePEM {
                    Text("Certificate SHA-256 fingerprint")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(fingerprint)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy TLS Certificate") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(certificate, forType: .string)
                    }
                }
                Text("Off by default. Lima binds TLS only to the selected private address and advertises safe Bonjour hints while running. Trust or pin the displayed certificate on the other device before using a network token; never disable TLS verification. A network token cannot use the local endpoint.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Pair New AI") {
                TextField("Connection name", text: $proposedName)
                Picker("Connection", selection: $pairingTransport) {
                    Text("This Mac").tag(LimaAccessTransport.local)
                    Text("Network TLS").tag(LimaAccessTransport.network)
                }
                Button("Pair New AI") {
                    do {
                        pairingToken = try access.pairClient(named: proposedName, transport: pairingTransport)
                        message = nil
                    } catch {
                        message = error.localizedDescription
                    }
                }
                .disabled(!canPair || proposedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("Each AI gets a unique Read Only token, shown once. Revoke only that connection at any time. Network and local tokens are not interchangeable.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Connected AIs") {
                if access.clients.isEmpty {
                    Text("No AI apps paired.").foregroundStyle(.secondary)
                } else {
                    ForEach(access.clients) { client in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: client.effectiveTransport == .network ? "network" : "desktopcomputer")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(client.name).fontWeight(.medium)
                                Text("\(client.access.title) · \(client.effectiveTransport.title) · Paired \(client.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(client.lastUsedAt.map {
                                    "Last used \($0.formatted(date: .abbreviated, time: .shortened))"
                                } ?? "Never used")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Revoke", role: .destructive) {
                                do {
                                    try access.revoke(client.id)
                                    message = nil
                                } catch {
                                    message = error.localizedDescription
                                }
                            }
                        }
                    }
                }
            }

            Section("Protocol") {
                LabeledContent("Local", value: "MCP · Loopback HTTP")
                LabeledContent("Network", value: "MCP · TLS Streamable HTTP")
                Text("Paired AI Connections currently expose bounded Notes and non-sensitive status only. Browser, terminal, clipboard, chats, settings, and extension execution remain unavailable to external clients.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            selectedNetworkAddress = access.networkAddress
                ?? access.availableNetworkAddresses.first ?? ""
            if !access.isRunning && access.isNetworkRunning {
                pairingTransport = .network
            }
        }
        .sheet(isPresented: Binding(
            get: { pairingToken != nil },
            set: { if !$0 { pairingToken = nil } }
        )) {
            pairingSheet
        }
    }

    private var pairingSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect an AI to Lima").font(.title2).fontWeight(.semibold)
            Text("Copy these details into the AI client's MCP configuration. Keep the bearer token private; it is shown only here.")
                .font(.callout).foregroundStyle(.secondary)
            LabeledContent("Address", value: pairingEndpoint)
            LabeledContent("Access", value: "Read Only · \(pairingTransport.title)")
            if pairingTransport == .network {
                Text("First trust or pin Lima's TLS certificate on the other device. Verify its fingerprint in Settings before sending this token. Do not disable certificate verification.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let token = pairingToken {
                Text("Bearer token").font(.caption).foregroundStyle(.secondary)
                Text(token)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                HStack {
                    Button("Copy Connection JSON") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(connectionJSON(token: token), forType: .string)
                    }
                    Spacer()
                    Button("Done") { pairingToken = nil }
                }
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    private func connectionJSON(token: String) -> String {
        let value: [String: Any] = [
            "mcpServers": [
                "lima": [
                    "url": pairingEndpoint,
                    "headers": ["Authorization": "Bearer \(token)"]
                ]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}
