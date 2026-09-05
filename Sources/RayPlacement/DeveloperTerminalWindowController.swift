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
        terminalView.startProcess(
            executable: executable,
            args: [],
            environment: environment.map { "\($0.key)=\($0.value)" },
            execName: "-" + URL(fileURLWithPath: executable).lastPathComponent,
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path
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

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

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

    var body: some View {
        TerminalSurface(model: model)
            .padding(8)
            .background(Color(nsColor: model.terminalView.nativeBackgroundColor))
            .clipShape(PrismaticPanelShape(cut: 8))
            .overlay(PrismaticPanelShape(cut: 8).stroke(LimaDesign.controlBorder, lineWidth: LimaDesign.borderWidth))
            .shadow(color: .black.opacity(0.20), radius: 14, y: 6)
            .onTapGesture { model.focus() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(9)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Developer Terminal")
            .onAppear { model.startIfNeeded() }
    }
}
