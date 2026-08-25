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
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
    @Published var output = "RayPlacement Terminal · local zsh\n"
    @Published var workingDirectory = FileManager.default.homeDirectoryForCurrentUser
    @Published var isRunning = false
    @Published var outputFilter = ""
    var onOpenEditor: ((TerminalEditorOverlayController.Editor, String) -> Void)?

    private var process: Process?
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
        append("\n\(workingDirectory.lastPathComponent) % \(value)\n")

        if let path = directoryChange(from: value) {
            let resolved = URL(fileURLWithPath: path, relativeTo: workingDirectory).standardizedFileURL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue {
                workingDirectory = resolved
            } else {
                append("cd: no such directory: \(path)\n")
            }
            return
        }

        let executable = value.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        if ["vim", "nvim"].contains(executable) {
            onOpenEditor?(.vim, value)
            append("Opened Vim in Terminal.app with a shortcut guide.\n")
            return
        }
        if executable == "nano" {
            onOpenEditor?(.nano, value)
            append("Opened Nano in Terminal.app with a shortcut guide.\n")
            return
        }

        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", value]
        task.currentDirectoryURL = workingDirectory
        task.standardOutput = pipe
        task.standardError = pipe
        task.environment = ProcessInfo.processInfo.environment.merging([
            "TERM": "xterm-256color",
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        ]) { _, new in new }
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                let remaining = max(0, self.outputLimit - self.outputBytes)
                guard remaining > 0 else { return }
                let chunk = data.prefix(remaining)
                self.outputBytes += chunk.count
                self.output += String(decoding: chunk, as: UTF8.self)
                if self.outputBytes >= self.outputLimit { self.output += "\n[Output capped at 2 MB]\n" }
            }
        }
        task.terminationHandler = { [weak self, weak pipe] finished in
            pipe?.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunning = false
                self.process = nil
                self.append("\n[exit \(finished.terminationStatus)]\n")
            }
        }
        do {
            try task.run()
            process = task
            isRunning = true
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            append("Could not start: \(error.localizedDescription)\n")
        }
    }

    func cancel() {
        if process?.isRunning == true { process?.terminate() }
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
        output += value
        outputBytes = min(outputLimit, outputBytes + value.utf8.count)
    }

    private func directoryChange(from command: String) -> String? {
        guard command == "cd" || command.hasPrefix("cd ") else { return nil }
        let value = command.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == "~" { return FileManager.default.homeDirectoryForCurrentUser.path }
        return NSString(string: value).expandingTildeInPath
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
                    Text("Terminal").font(.system(size: 15, weight: .semibold, design: .rounded))
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

                HStack(spacing: 8) {
                    Text("%")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(SettingsStore.shared.accentTheme.primary)
                    TextField("Enter a zsh command", text: $model.command)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .monospaced))
                        .focused($commandFocused)
                        .onSubmit(model.run)
                        .disabled(model.isRunning)
                    if model.isRunning { ProgressView().controlSize(.small) }
                    Text("↩ Run").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 13)
                .frame(height: 40)
                .liquidGlass(cornerRadius: 14, depth: .floating, accentOpacity: 0.028)
            }
            .padding(10)
        }
        .preferredColorScheme(.dark)
        .onAppear { commandFocused = true }
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
