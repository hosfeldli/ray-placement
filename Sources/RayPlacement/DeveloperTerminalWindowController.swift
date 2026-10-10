import AppKit
import Combine
import Foundation
import SwiftTerm
import SwiftUI

fileprivate final class ShelfCapturingTerminalView: LocalProcessTerminalView {
    var onOutput: ((ArraySlice<UInt8>) -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        onOutput?(slice)
        super.dataReceived(slice: slice)
    }
}

@MainActor
final class DeveloperTerminalModel: NSObject, ObservableObject, @preconcurrency LocalProcessTerminalViewDelegate {
    @Published private(set) var isLive = false
    @Published private(set) var wrapsLines = true

    fileprivate let terminalView = ShelfCapturingTerminalView(frame: .zero)
    private var shuttingDown = false
    private var currentDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    private var typographySubscription: AnyCancellable?
    private var terminalOutput = ""
    private var lastShelfCaptureAt = Date.distantPast

    override init() {
        super.init()
        terminalView.processDelegate = self
        terminalView.onOutput = { [weak self] slice in
            let text = String(decoding: slice, as: UTF8.self)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.terminalOutput.append(text)
                if self.terminalOutput.count > 100_000 {
                    self.terminalOutput = String(self.terminalOutput.suffix(100_000))
                }
            }
        }
        terminalView.optionAsMetaKey = true
        terminalView.allowMouseReporting = true
        terminalView.nativeForegroundColor = NSColor(calibratedWhite: 0.91, alpha: 1)
        terminalView.nativeBackgroundColor = NSColor(calibratedRed: 0.026, green: 0.035, blue: 0.055, alpha: 1)
        terminalView.selectedTextBackgroundColor = LimaAppKitDesign.accentSoft
        terminalView.caretColor = LimaAppKitDesign.focus
        terminalView.font = NSFont.monospacedSystemFont(ofSize: AppTypography.size(13), weight: .regular)
        terminalView.wantsLayer = true
        terminalView.layer?.backgroundColor = terminalView.nativeBackgroundColor.cgColor
        terminalView.getTerminal().setCursorStyle(.steadyBar)
        wrapsLines = SettingsStore.shared.terminalWrapLines
        terminalView.getTerminal().feed(text: wrapsLines ? "\u{1B}[?7h" : "\u{1B}[?7l")
        terminalView.setAccessibilityLabel("Interactive terminal")
        typographySubscription = AppTypography.shared.$scale.sink { [weak self] scale in
            self?.terminalView.font = .monospacedSystemFont(ofSize: 13 * scale, weight: .regular)
        }
    }

    /// Changes the working directory for the single Lima shell. A running
    /// shell is restarted so the directory applies at process creation rather
    /// than injecting an unescaped command into its input stream.
    func setInitialDirectory(_ directory: String) {
        let expanded = (directory as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        currentDirectory = expanded
        if terminalView.process.running {
            terminalView.terminate()
        } else {
            startIfNeeded()
        }
    }

    func startIfNeeded() {
        guard !terminalView.process.running else {
            isLive = true
            focus()
            return
        }

        shuttingDown = false
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let executable = FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/zsh"
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Lima"
        environment["TERM_PROGRAM_VERSION"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        terminalOutput = ""
        terminalView.startProcess(
            executable: executable,
            args: [],
            environment: environment.map { "\($0.key)=\($0.value)" },
            execName: "-" + URL(fileURLWithPath: executable).lastPathComponent,
            currentDirectory: currentDirectory
        )
        isLive = true
        focus()
    }

    func shutdown() {
        shuttingDown = true
        if terminalView.process.running {
            terminalView.terminate()
        }
    }

    func captureOutputToShelf() {
        let captured = terminalOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !captured.isEmpty else { return }
        ContextShelfIntegration.addTerminalOutput(
            captured,
            sessionName: "Terminal"
        )
        lastShelfCaptureAt = Date()
    }

    func focus() {
        terminalView.window?.makeFirstResponder(terminalView)
    }

    /// Applies DEC auto-wrap to the terminal emulator. This does not rewrite
    /// shell output or send a command to the child process.
    func setWrapLines(_ enabled: Bool) {
        guard wrapsLines != enabled else { return }
        wrapsLines = enabled
        SettingsStore.shared.terminalWrapLines = enabled
        terminalView.getTerminal().feed(text: enabled ? "\u{1B}[?7h" : "\u{1B}[?7l")
    }

    func restartShell() {
        if terminalView.process.running {
            terminalView.terminate()
        } else {
            startIfNeeded()
        }
    }

    func clearScreen() {
        terminalView.getTerminal().feed(text: "\u{1B}[2J\u{1B}[H")
        terminalOutput = ""
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, !directory.isEmpty else { return }
        currentDirectory = directory
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isLive = false
        let captured = terminalOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !captured.isEmpty, Date().timeIntervalSince(lastShelfCaptureAt) > 0.5 {
            lastShelfCaptureAt = Date()
            ContextShelfIntegration.addTerminalOutput(captured, sessionName: "Terminal")
        }
        guard !shuttingDown else { return }
        DispatchQueue.main.async { [weak self] in
            self?.startIfNeeded()
        }
    }
}

private struct TerminalSurface: NSViewRepresentable {
    @ObservedObject var model: DeveloperTerminalModel

    func makeNSView(context: Context) -> ShelfCapturingTerminalView {
        model.terminalView
    }

    func updateNSView(_ nsView: ShelfCapturingTerminalView, context: Context) {}
}

struct DeveloperTerminalView: View {
    @ObservedObject var model: DeveloperTerminalModel
    @ObservedObject private var aiSessions = AIWorkspaceTerminalCoordinator.shared
    @Environment(\.limaWorkspaceSizeClass) private var workspaceSizeClass
    @State private var selectedSessionID: UUID?

    private var selectedAISession: AIWorkspaceTerminalSnapshot? {
        guard let selectedSessionID else { return nil }
        return aiSessions.sessions.first(where: { $0.id == selectedSessionID })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: LimaSpacing.sm) {
                Label("Terminal", systemImage: "terminal")
                    .limaFont(.caption.weight(.semibold))
                if !aiSessions.sessions.isEmpty {
                    Picker("Session", selection: $selectedSessionID) {
                        Text("My Shell").tag(UUID?.none)
                        ForEach(aiSessions.sessions) { session in
                            Text(session.title).tag(Optional(session.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                Button {
                    if let session = selectedAISession {
                        ContextShelfIntegration.addTerminalOutput(session.output, sessionName: session.title)
                    } else {
                        model.captureOutputToShelf()
                    }
                } label: {
                    Image(systemName: "tray.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .help("Add terminal output to Context Shelf")
                Spacer()
                Menu {
                    if let session = selectedAISession {
                        if session.state == .running {
                            Button("Stop AI Session") { _ = try? aiSessions.interrupt(sessionID: session.id) }
                        } else {
                            Button("Close AI Session") {
                                _ = try? aiSessions.close(sessionID: session.id)
                                selectedSessionID = nil
                            }
                        }
                    } else {
                        Toggle("Wrap Lines", isOn: Binding(
                            get: { model.wrapsLines },
                            set: { model.setWrapLines($0) }
                        ))
                        Divider()
                        Button("Clear Screen") { model.clearScreen() }
                        Button("Restart Shell") { model.restartShell() }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Terminal options")
            }
            .padding(.horizontal, workspaceSizeClass == .compact ? LimaSpacing.sm : LimaSpacing.md)
            .frame(height: LimaDesign.toolbarHeight)
            .background(LimaTheme.surfaceSecondary)
            GlassHairline()
            if let session = selectedAISession {
                aiSessionView(session)
            } else {
                TerminalSurface(model: model)
                    .background(Color(nsColor: model.terminalView.nativeBackgroundColor))
                    .onTapGesture { model.focus() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Terminal")
                    .onAppear { model.startIfNeeded() }
            }
        }
        .onAppear {
            if selectedSessionID == nil,
               let running = aiSessions.sessions.last(where: { $0.state == .running }) {
                selectedSessionID = running.id
            }
        }
        .onChange(of: aiSessions.sessions.count) { _ in
            if let newest = aiSessions.sessions.last { selectedSessionID = newest.id }
        }
    }

    @ViewBuilder
    private func aiSessionView(_ session: AIWorkspaceTerminalSnapshot) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: LimaSpacing.sm) {
                Image(systemName: session.state == .running ? "circle.dotted" :
                    session.state == .completed ? "checkmark.circle" :
                    session.state == .idle ? "terminal" : "xmark.circle")
                Text(session.state.rawValue.capitalized)
                Text(session.directory)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(LimaTheme.textSecondary)
                Spacer()
                if session.state == .running {
                    Button("Stop") { _ = try? aiSessions.interrupt(sessionID: session.id) }
                        .buttonStyle(.borderless)
                }
            }
            .limaFont(.caption)
            .padding(.horizontal, LimaSpacing.md)
            .frame(height: LimaDesign.toolbarHeight)
            .background(LimaTheme.surfaceSecondary)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(session.output.isEmpty ? "AI Workspace session ready." : session.output)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(LimaTheme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(LimaSpacing.md)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .onChange(of: session.nextOutputByte) { _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .background(Color(nsColor: model.terminalView.nativeBackgroundColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("AI Workspace Terminal")
    }
}
