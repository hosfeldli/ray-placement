import AppKit
import SwiftUI

/// A projection of AI-owned terminal sessions into the top of Chat.
/// The Terminal workspace remains the shared source of truth; this view never
/// owns a process or grants command permission, but can revoke an existing grant.
struct AIChatTerminalMonitor: View {
    @ObservedObject private var coordinator = AIWorkspaceTerminalCoordinator.shared
    @Environment(\.limaWorkspaceSizeClass) private var workspaceSizeClass

    let conversationID: UUID?
    let previewSessions: [AIWorkspaceTerminalSnapshot]?

    @State private var selectedSessionID: UUID?
    @State private var isMinimized: Bool
    @State private var stopError: String?

    init(conversationID: UUID?, previewSessions: [AIWorkspaceTerminalSnapshot]? = nil,
         initiallyMinimized: Bool = false) {
        self.conversationID = conversationID
        self.previewSessions = previewSessions
        _isMinimized = State(initialValue: initiallyMinimized)
    }

    private var visibleSessions: [AIWorkspaceTerminalSnapshot] {
        if let previewSessions { return previewSessions }
        return coordinator.sessions(for: conversationID)
    }

    private var selectedSession: AIWorkspaceTerminalSnapshot? {
        if let selectedSessionID,
           let selected = visibleSessions.first(where: { $0.id == selectedSessionID }) {
            return selected
        }
        return visibleSessions.last(where: { $0.state == .running }) ?? visibleSessions.last
    }

    private var sessionIDs: [UUID] { visibleSessions.map(\.id) }
    private var runningIDs: [UUID] {
        visibleSessions.filter { $0.state == .running }.map(\.id)
    }

    var body: some View {
        if let session = selectedSession {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "terminal.fill")
                        .foregroundStyle(LimaTheme.accentInk)
                        .frame(width: 26, height: 26)
                        .background(LimaColors.accentSoft, in: RoundedRectangle(cornerRadius: 7))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI Terminal")
                            .limaFont(.caption.weight(.semibold))
                            .foregroundStyle(LimaColors.primaryText)
                        Text(session.isBoundedExternal ? "Approved external command" : "Sandboxed AI Workspace")
                            .limaFont(.caption2)
                            .foregroundStyle(LimaColors.secondaryText)
                    }
                    Spacer(minLength: 4)
                    if visibleSessions.count > 1 {
                        Menu {
                            ForEach(visibleSessions.reversed()) { candidate in
                                Button(candidate.title) { selectedSessionID = candidate.id }
                            }
                        } label: {
                            Text("\(visibleSessions.count) sessions")
                                .limaFont(.caption)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel("Choose AI terminal session")
                    }
                    Button {
                        isMinimized.toggle()
                    } label: {
                        Image(systemName: isMinimized ? "chevron.down" : "chevron.up")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .help(isMinimized ? "Expand AI Terminal" : "Minimize AI Terminal")
                    .accessibilityLabel(isMinimized ? "Expand AI Terminal" : "Minimize AI Terminal")
                }

                HStack(spacing: 7) {
                    Circle()
                        .fill(statusColor(for: session))
                        .frame(width: 6, height: 6)
                    Text(statusTitle(for: session))
                        .limaFont(.caption2.weight(.semibold))
                        .foregroundStyle(statusColor(for: session))
                    Text(session.directory)
                        .limaFont(.caption2)
                        .foregroundStyle(LimaColors.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if session.state == .running {
                        Button("Stop") {
                            guard previewSessions == nil else { return }
                            do { _ = try coordinator.interrupt(sessionID: session.id); stopError = nil }
                            catch { stopError = error.localizedDescription }
                        }
                        .buttonStyle(.borderless)
                        .limaFont(.caption2.weight(.semibold))
                        .help("Interrupt this AI terminal command")
                    }
                }
                .padding(.top, 9)

                if session.directoryGrantActive {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(LimaColors.success)
                        Text("Commands allowed in this directory")
                            .foregroundStyle(LimaColors.secondaryText)
                        Spacer(minLength: 4)
                        Button("Revoke") {
                            guard previewSessions == nil else { return }
                            coordinator.revokeDirectoryGrant(sessionID: session.id)
                        }
                        .buttonStyle(.borderless)
                        .help("Require approval for the next AI Workspace command")
                    }
                    .limaFont(.caption2)
                    .padding(.top, 6)
                }

                if let stopError {
                    Text(stopError)
                        .limaFont(.caption2)
                        .foregroundStyle(LimaColors.danger)
                        .padding(.top, 5)
                }

                if !isMinimized {
                    GlassHairline()
                        .padding(.vertical, 9)
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                if session.outputTruncated || session.output.count > 12_000 {
                                    Text("Showing recent output; earlier output is available in Terminal when retained.")
                                        .limaFont(.caption2)
                                        .foregroundStyle(LimaColors.secondaryText)
                                }
                                Text(outputPreview(for: session))
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(LimaColors.primaryText)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Color.clear.frame(height: 1).id("terminal-bottom")
                            }
                            .padding(9)
                        }
                        .frame(height: workspaceSizeClass == .compact ? 116 : 180)
                        .background(LimaColors.editorBackground, in: RoundedRectangle(cornerRadius: 8))
                        .onChange(of: session.nextOutputByte) { _ in
                            proxy.scrollTo("terminal-bottom", anchor: .bottom)
                        }
                    }
                    .accessibilityLabel("AI terminal output")
                }
            }
            .padding(11)
            .limaGlassContainer(region: .hud, cornerRadius: LimaRadius.panel)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .accessibilityIdentifier(LimaQAIdentifiers.AI.terminalMonitor)
            .onChange(of: sessionIDs) { ids in
                if let latest = ids.last {
                    selectedSessionID = latest
                    isMinimized = false
                    stopError = nil
                } else {
                    selectedSessionID = nil
                }
            }
            .onChange(of: runningIDs) { ids in
                if let latest = ids.last {
                    selectedSessionID = latest
                    isMinimized = false
                }
            }
            .onChange(of: conversationID) { _ in
                selectedSessionID = nil
                isMinimized = false
                stopError = nil
            }
        }
    }

    private func outputPreview(for session: AIWorkspaceTerminalSnapshot) -> String {
        guard !session.output.isEmpty else {
            switch session.state {
            case .idle: return "Session ready. Waiting for an approved command."
            case .running: return "Command running. Waiting for output…"
            default: return "No output retained."
            }
        }
        let tail = String(session.output.suffix(12_000))
        return tail.replacingOccurrences(
            of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        ).replacingOccurrences(of: "\r", with: "\n")
    }

    private func statusTitle(for session: AIWorkspaceTerminalSnapshot) -> String {
        switch session.state {
        case .idle: return "Ready"
        case .running: return "Running"
        case .completed: return session.exitStatus.map { "Completed · exit \($0)" } ?? "Completed"
        case .failed: return session.exitStatus.map { "Failed · exit \($0)" } ?? "Failed"
        case .cancelled: return "Stopped"
        case .timedOut: return "Timed out"
        }
    }

    private func statusColor(for session: AIWorkspaceTerminalSnapshot) -> Color {
        switch session.state {
        case .idle: return LimaColors.secondaryText
        case .running: return LimaTheme.accentInk
        case .completed: return LimaColors.success
        case .failed, .timedOut: return LimaColors.danger
        case .cancelled: return LimaColors.warning
        }
    }
}
