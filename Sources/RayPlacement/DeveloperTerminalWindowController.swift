import AppKit
import SwiftUI

@MainActor
final class DeveloperTerminalWindowController: NSWindowController {
    private let model = DeveloperTerminalModel()
    private let helper = TerminalEditorOverlayController()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 570),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "RayPlacement Terminal"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 620, height: 420)
        window.setAccessibilityLabel("RayPlacement developer terminal")
        self.init(window: window)
        model.onOpenEditor = { [weak self] editor, command in
            self?.openEditor(editor, command: command)
        }
        window.contentView = NSHostingView(rootView: DeveloperTerminalView(model: model))
    }

    func present() {
        model.ensureSession()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func shutdown() {
        model.shutdown()
        helper.dismiss()
    }

    private func openEditor(_ editor: TerminalEditorOverlayController.Editor, command: String) {
        do {
            let script = FileManager.default.temporaryDirectory
                .appendingPathComponent("RayPlacement-Editor-\(UUID().uuidString).command")
            let content = "#!/bin/zsh\ncd \(Self.shellQuote(model.workingDirectory.path))\n\(command)\n"
            try Data(content.utf8).write(to: script, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            guard NSWorkspace.shared.open(script) else {
                model.append("Could not open the editor session in Terminal.app.\n")
                return
            }
            helper.show(editor: editor)
        } catch {
            model.append("Could not start editor session: \(error.localizedDescription)\n")
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

@MainActor
private final class DeveloperTerminalModel: ObservableObject {
    @Published var command = ""
    @Published var output = "RayPlacement Terminal · persistent local zsh\n"
    @Published var workingDirectory = FileManager.default.homeDirectoryForCurrentUser
    @Published var isRunning = false
    @Published var isSessionLive = false
    @Published var outputFilter = ""
    var onOpenEditor: ((TerminalEditorOverlayController.Editor, String) -> Void)?

    private var shellProcess: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var streamBuffer = Data()
    private var pendingMarker: String?
    private var commandHistory: [String] = []
    private var historyIndex = 0
    private var outputBytes = 0
    private let outputLimit = 2_000_000

    var visibleOutput: String {
        let query = outputFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return output }
        return output.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.localizedCaseInsensitiveContains(query) }
            .joined(separator: "\n")
    }

    func run() {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isRunning else { return }
        command = ""
        commandHistory.append(value)
        if commandHistory.count > 500 { commandHistory.removeFirst(commandHistory.count - 500) }
        historyIndex = commandHistory.count
        append("\n\(promptPath) % \(value)\n")

        let firstLine = value.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? value
        let executable = firstLine.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        if !value.contains("\n"), ["vim", "nvim"].contains(executable) {
            onOpenEditor?(.vim, value)
            append("Opened Vim in Terminal.app with a shortcut guide.\n")
            return
        }
        if !value.contains("\n"), executable == "nano" {
            onOpenEditor?(.nano, value)
            append("Opened Nano in Terminal.app with a shortcut guide.\n")
            return
        }

        ensureSession()
        guard let inputPipe, shellProcess?.isRunning == true else {
            append("The shell session could not be started.\n")
            return
        }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        pendingMarker = "__RAYPLACEMENT_DONE_\(token)__:"
        let payload = """
        \(value)
        __rayplacement_status=$?
        __rayplacement_pwd_hex=$(printf %s "$PWD" | /usr/bin/od -An -v -tx1 | /usr/bin/tr -d ' \\n')
        printf '\\n__RAYPLACEMENT_DONE_\(token)__:%s:%s\\n' "$__rayplacement_status" "$__rayplacement_pwd_hex"
        unset __rayplacement_status __rayplacement_pwd_hex

        """
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
            isRunning = true
        } catch {
            pendingMarker = nil
            append("Could not send command: \(error.localizedDescription)\n")
        }
    }

    func cancel() {
        guard isRunning, let shellProcess else { return }
        append("\n[interrupt requested]\n")
        shellProcess.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self, weak shellProcess] in
            guard let self, let shellProcess,
                  self.isRunning,
                  self.shellProcess === shellProcess,
                  shellProcess.isRunning else { return }
            shellProcess.terminate()
        }
    }

    func clear() {
        output = ""
        outputBytes = 0
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(visibleOutput, forType: .string)
    }

    func append(_ value: String) {
        let remaining = max(0, outputLimit - outputBytes)
        guard remaining > 0 else { return }
        let data = Data(value.utf8).prefix(remaining)
        output += String(decoding: data, as: UTF8.self)
        outputBytes += data.count
        if outputBytes >= outputLimit, !output.hasSuffix("[Output capped at 2 MB]\n") {
            output += "\n[Output capped at 2 MB]\n"
        }
    }

    func ensureSession() {
        guard shellProcess?.isRunning != true else { return }
        let task = Process()
        let input = Pipe()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-l"]
        task.currentDirectoryURL = workingDirectory
        task.standardInput = input
        task.standardOutput = output
        task.standardError = output
        task.environment = ProcessInfo.processInfo.environment.merging([
            "TERM": "dumb",
            "NO_COLOR": "1",
            "CLICOLOR": "0",
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        ]) { _, new in new }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.consume(data) }
        }
        task.terminationHandler = { [weak self, weak task, weak output] finished in
            output?.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor [weak self, weak task] in
                guard let self, let task, self.shellProcess === task else { return }
                self.shellProcess = nil
                self.inputPipe = nil
                self.outputPipe = nil
                self.pendingMarker = nil
                self.isRunning = false
                self.isSessionLive = false
                self.flushStreamBuffer()
                self.append("\n[session ended · status \(finished.terminationStatus); the next command starts a new session]\n")
            }
        }
        do {
            try task.run()
            shellProcess = task
            inputPipe = input
            outputPipe = output
            isSessionLive = true
            append("[session ready · state is preserved between commands]\n")
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            append("Could not start zsh: \(error.localizedDescription)\n")
        }
    }

    func restartSession() {
        endSession()
        append("\n[session restarted]\n")
        ensureSession()
    }

    func shutdown() {
        endSession()
    }

    func previousCommand() {
        guard !commandHistory.isEmpty else { return }
        historyIndex = max(0, historyIndex - 1)
        command = commandHistory[historyIndex]
    }

    func nextCommand() {
        guard !commandHistory.isEmpty else { return }
        historyIndex = min(commandHistory.count, historyIndex + 1)
        command = historyIndex == commandHistory.count ? "" : commandHistory[historyIndex]
    }

    private var promptPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = workingDirectory.path
        return path == home ? "~" : path.replacingOccurrences(of: home + "/", with: "~/")
    }

    private func endSession() {
        let process = shellProcess
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        try? inputPipe?.fileHandleForWriting.close()
        shellProcess = nil
        inputPipe = nil
        outputPipe = nil
        pendingMarker = nil
        streamBuffer.removeAll(keepingCapacity: false)
        isRunning = false
        isSessionLive = false
        if process?.isRunning == true { process?.terminate() }
    }

    private func consume(_ data: Data) {
        streamBuffer.append(data)
        while let newline = streamBuffer.firstIndex(of: 0x0A) {
            let lineData = streamBuffer.prefix(upTo: newline)
            streamBuffer.removeSubrange(...newline)
            handleLine(String(decoding: lineData, as: UTF8.self))
        }
    }

    private func flushStreamBuffer() {
        guard !streamBuffer.isEmpty else { return }
        append(String(decoding: streamBuffer, as: UTF8.self))
        streamBuffer.removeAll(keepingCapacity: false)
    }

    private func handleLine(_ line: String) {
        guard let marker = pendingMarker, line.hasPrefix(marker) else {
            append(line + "\n")
            return
        }
        let payload = line.dropFirst(marker.count)
        let fields = payload.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let status = fields.first.flatMap { Int($0) } ?? -1
        if fields.count == 2, let directory = Self.decodeHex(String(fields[1])), !directory.isEmpty {
            workingDirectory = URL(fileURLWithPath: directory).standardizedFileURL
        }
        pendingMarker = nil
        isRunning = false
        append("[exit \(status)]\n")
    }

    private static func decodeHex(_ value: String) -> String? {
        guard value.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return String(data: data, encoding: .utf8)
    }
}

private struct DeveloperTerminalView: View {
    @ObservedObject var model: DeveloperTerminalModel
    @FocusState private var commandFocused: Bool

    var body: some View {
        ZStack {
            LiquidGlassBackdrop(material: .underWindowBackground, blendingMode: .behindWindow)
            VStack(spacing: 9) {
                HStack(spacing: 9) {
                    Image(systemName: "terminal.fill")
                        .foregroundStyle(SettingsStore.shared.accentTheme.gradient)
                    Circle()
                        .fill(model.isSessionLive ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text("Persistent zsh").font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text(model.workingDirectory.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    TextField("Filter output", text: $model.outputFilter)
                        .textFieldStyle(.plain)
                        .frame(width: 130)
                        .padding(.horizontal, 9)
                        .frame(height: 27)
                        .liquidGlass(cornerRadius: 8, depth: .recessed, accentOpacity: 0.01)
                    Button(action: model.copy) { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("Copy output")
                    Button(action: model.clear) { Image(systemName: "trash") }.buttonStyle(.plain).help("Clear")
                    Button(action: model.restartSession) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .help("Restart shell state")
                        .disabled(model.isRunning)
                    if model.isRunning {
                        Button(action: model.cancel) { Image(systemName: "stop.fill") }.buttonStyle(.plain).foregroundStyle(.orange).help("Stop")
                    }
                }
                .padding(.horizontal, 13)
                .frame(height: 43)
                .liquidGlass(cornerRadius: 15, depth: .raised, accentOpacity: 0.035)

                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        Text(model.visibleOutput)
                            .font(.system(size: 12.2, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                            .frame(minWidth: 760, alignment: .topLeading)
                            .padding(14)
                            .id("end")
                    }
                    .onChange(of: model.output) { _ in proxy.scrollTo("end", anchor: .bottomLeading) }
                }
                .liquidGlass(cornerRadius: 17, depth: .recessed, accentOpacity: 0.018)

                HStack(alignment: .top, spacing: 8) {
                    Text("%")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(SettingsStore.shared.accentTheme.primary)
                        .padding(.top, 9)
                    TextEditor(text: $model.command)
                        .font(.system(size: 12.5, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .focused($commandFocused)
                        .frame(minHeight: 42, maxHeight: 78)
                        .disabled(model.isRunning)
                    VStack(spacing: 5) {
                        HStack(spacing: 5) {
                            Button(action: model.previousCommand) { Image(systemName: "chevron.up") }
                            Button(action: model.nextCommand) { Image(systemName: "chevron.down") }
                        }
                        .buttonStyle(.plain)
                        Button(model.isRunning ? "Running" : "Run", action: model.run)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .keyboardShortcut(.return, modifiers: [.command])
                            .disabled(model.isRunning || model.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .liquidGlass(cornerRadius: 14, depth: .floating, accentOpacity: 0.028)
            }
            .padding(10)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            model.ensureSession()
            commandFocused = true
        }
    }
}

@MainActor
final class TerminalEditorOverlayController {
    enum Editor { case vim, nano }
    private let panel: NSPanel

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 54),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.setAccessibilityLabel("Editor shortcut guide")
    }

    func show(editor: Editor) {
        panel.contentView = NSHostingView(rootView: TerminalEditorOverlayView(editor: editor) { [weak self] in
            self?.panel.orderOut(nil)
        })
        if let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 24))
        }
        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel.orderOut(nil)
    }
}

private struct TerminalEditorOverlayView: View {
    let editor: TerminalEditorOverlayController.Editor
    let dismiss: () -> Void

    var keys: [(String, String)] {
        switch editor {
        case .vim: return [("i", "Insert"), ("esc", "Normal"), (":w", "Save"), (":q", "Quit"), ("dd", "Delete line"), ("/", "Search")]
        case .nano: return [("⌃O", "Save"), ("⌃X", "Exit"), ("⌃W", "Search"), ("⌃K", "Cut"), ("⌃U", "Paste")]
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(editor == .vim ? "VIM" : "NANO")
                .font(.caption2.bold())
                .foregroundStyle(SettingsStore.shared.accentTheme.primary)
            ForEach(Array(keys.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    Text(item.0).font(.caption.monospaced().bold()).foregroundStyle(.primary)
                    Text(item.1).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .padding(.horizontal, 15)
        .frame(width: 650, height: 54)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .preferredColorScheme(.dark)
    }
}
