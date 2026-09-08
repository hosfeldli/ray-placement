import AppKit
import Combine
import Foundation
import SwiftTerm
import SwiftUI

@MainActor
final class DeveloperTerminalModel: NSObject, ObservableObject, @preconcurrency LocalProcessTerminalViewDelegate {
    @Published private(set) var isLive = false

    let terminalView = LocalProcessTerminalView(frame: .zero)
    private var shuttingDown = false
    private var activeSessionID: UUID?
    private var typographySubscription: AnyCancellable?

    override init() {
        super.init()
        terminalView.processDelegate = self
        terminalView.optionAsMetaKey = true
        terminalView.allowMouseReporting = true
        terminalView.nativeForegroundColor = NSColor(calibratedWhite: 0.91, alpha: 1)
        terminalView.nativeBackgroundColor = NSColor(calibratedRed: 0.026, green: 0.035, blue: 0.055, alpha: 1)
        terminalView.selectedTextBackgroundColor = LimaAppKitDesign.selection
        terminalView.caretColor = LimaAppKitDesign.focus
        terminalView.font = NSFont.monospacedSystemFont(ofSize: AppTypography.size(13), weight: .regular)
        terminalView.wantsLayer = true
        terminalView.layer?.backgroundColor = terminalView.nativeBackgroundColor.cgColor
        terminalView.getTerminal().setCursorStyle(.steadyBar)
        terminalView.setAccessibilityLabel("Interactive terminal")
        typographySubscription = AppTypography.shared.$scale.sink { [weak self] scale in
            self?.terminalView.font = .monospacedSystemFont(ofSize: 13 * scale, weight: .regular)
        }
    }

    func selectSession(_ id: UUID) {
        TerminalSessionStore.shared.select(id)
        WorkspaceStateRegistry.shared.update { $0.terminalSessionID = id }
        activeSessionID = id
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
        let session = TerminalSessionStore.shared.selectedSession
        activeSessionID = session?.id
        if let id = session?.id { WorkspaceStateRegistry.shared.update { $0.terminalSessionID = id } }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let executable = FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/zsh"
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Lima"
        environment["TERM_PROGRAM_VERSION"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        terminalView.startProcess(
            executable: executable,
            args: [],
            environment: environment.map { "\($0.key)=\($0.value)" },
            execName: "-" + URL(fileURLWithPath: executable).lastPathComponent,
            currentDirectory: session?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
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

    func focus() {
        terminalView.window?.makeFirstResponder(terminalView)
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, !directory.isEmpty else { return }
        TerminalSessionStore.shared.updateDirectory(directory, for: activeSessionID)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isLive = false
        guard !shuttingDown else { return }
        DispatchQueue.main.async { [weak self] in
            self?.startIfNeeded()
        }
    }
}

private struct TerminalSurface: NSViewRepresentable {
    @ObservedObject var model: DeveloperTerminalModel

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        model.terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}

struct DeveloperTerminalView: View {
    @ObservedObject var model: DeveloperTerminalModel
    @ObservedObject private var sessions = TerminalSessionStore.shared

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 7) {
                Label("Session", systemImage: "terminal")
                    .limaFont(.caption.weight(.semibold))
                Picker("Terminal session", selection: Binding(
                    get: { sessions.selectedSessionID ?? sessions.sessions.first?.id },
                    set: { if let id = $0 { model.selectSession(id) } }
                )) {
                    ForEach(sessions.sessions) { session in
                        Text(session.name).tag(Optional(session.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 210)
                Button {
                    model.selectSession(sessions.create().id)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Create terminal session")
                Spacer()
                if let error = sessions.lastError {
                    Text(error).limaFont(.caption2).foregroundStyle(.orange).lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            TerminalSurface(model: model)
            .padding(8)
            .background(Color(nsColor: model.terminalView.nativeBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: LimaRadius.panel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LimaRadius.panel, style: .continuous).stroke(LimaColors.border, lineWidth: LimaDesign.borderWidth))
            .onTapGesture { model.focus() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(9)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Terminal")
            .onAppear { model.startIfNeeded() }
        }
    }
}
