import AppKit
@preconcurrency import Darwin
import Foundation
import SwiftTerm
import SwiftUI

@MainActor
final class DeveloperTerminalWindowController: NSWindowController {
    private let model = DeveloperTerminalModel()
    private let shortcutGuide = TerminalEditorOverlayController()
    private var keyMonitor: Any?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_140, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Terminal"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 720, height: 470)
        window.setAccessibilityLabel("RayPlacement developer terminal")
        self.init(window: window)
        model.onEditorChanged = { [weak self] editor in
            guard let self else { return }
            if let editor { self.shortcutGuide.show(editor: editor) }
            else { self.shortcutGuide.dismiss() }
        }
        window.contentView = NSHostingView(rootView: DeveloperTerminalView(model: model))
        installKeyMonitor()
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    func present() {
        model.startIfNeeded()
        window?.center()
        if let window { WorkspaceWindowCoordinator.shared.present(window) }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in self?.model.focus() }
    }

    func shutdown() {
        model.shutdown()
        shortcutGuide.dismiss()
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let commandShift = flags.contains([.command, .shift])
            let key = event.charactersIgnoringModifiers?.lowercased()
            if event.keyCode == 122 { // F1
                self.model.toggleHelp()
                return nil
            }
            guard commandShift else { return event }
            switch key {
            case "h": self.model.toggleHelp()
            case "e": self.model.toggleExplorer()
            case "l": self.model.requestComposerFocus()
            case "r": self.model.refreshExplorer()
            case "[": self.model.adjustHelpWidth(by: -36)
            case "]": self.model.adjustHelpWidth(by: 36)
            default: return event
            }
            return nil
        }
    }
}

private struct TerminalCommandReference: Identifiable, Hashable {
    let command: String
    let synopsis: String
    let summary: String
    let examples: [String]
    let flags: [String]

    var id: String { command }

    static let catalog: [TerminalCommandReference] = [
        .init(command: "cd", synopsis: "cd [directory]", summary: "Change the shell's current directory.", examples: ["cd ~/Projects", "cd ..", "cd -"], flags: [".. parent directory", "- previous directory"]),
        .init(command: "ls", synopsis: "ls [-lah] [path]", summary: "List files and directories.", examples: ["ls", "ls -lah", "ls -lah src"], flags: ["-l long listing", "-a include hidden files", "-h readable sizes"]),
        .init(command: "rg", synopsis: "rg [pattern] [path]", summary: "Fast recursive text search (ripgrep).", examples: ["rg TODO", "rg -n 'func ' Sources", "rg --files"], flags: ["-n line numbers", "--files list tracked candidates", "-g glob filter"]),
        .init(command: "git", synopsis: "git <command> [options]", summary: "Inspect and manage a Git repository.", examples: ["git status", "git diff", "git log --oneline -10"], flags: ["status working tree", "diff uncommitted changes", "switch change branch"]),
        .init(command: "swift", synopsis: "swift <subcommand>", summary: "Build, test, and run Swift packages.", examples: ["swift test", "swift build", "swift run"], flags: ["test run package tests", "build compile package", "run run executable"]),
        .init(command: "python3", synopsis: "python3 [script.py]", summary: "Run Python 3 or start an interactive interpreter.", examples: ["python3 script.py", "python3 -m json.tool file.json"], flags: ["-m run a module", "-c execute a short expression"]),
        .init(command: "npm", synopsis: "npm <command>", summary: "Run Node package scripts and manage dependencies.", examples: ["npm run", "npm test", "npm run dev"], flags: ["run list or execute scripts", "test run test script"]),
        .init(command: "man", synopsis: "man <command>", summary: "Read a command's local manual page.", examples: ["man git", "man ls", "man 1 printf"], flags: ["q quit pager", "/ search within manual", "n next match"])
    ]
}

private struct TerminalFileNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let children: [TerminalFileNode]?

    var id: String { url.path }
    var name: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }
}

@MainActor
private final class TerminalDirectoryExplorer: ObservableObject {
    @Published private(set) var root: TerminalFileNode?
    @Published var showHidden = false { didSet { refresh() } }
    @Published private(set) var status = ""

    private var directoryURL: URL?
    private var watcher: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private var refreshWorkItem: DispatchWorkItem?

    func setDirectory(_ path: String) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard directoryURL != url else { return }
        directoryURL = url
        refresh()
        startWatching(url)
    }

    func refresh() {
        guard let directoryURL else { return }
        let hidden = showHidden
        let rootURL = directoryURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let node = Self.makeNode(url: rootURL, depth: 0, showHidden: hidden)
            DispatchQueue.main.async {
                guard self?.directoryURL == rootURL else { return }
                self?.root = node
                self?.status = node == nil ? "Folder is unavailable" : "Updated just now"
            }
        }
    }

    nonisolated private static func makeNode(url: URL, depth: Int, showHidden: Bool) -> TerminalFileNode? {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { return nil }
        guard directory.boolValue else { return TerminalFileNode(url: url, isDirectory: false, children: nil) }
        guard depth < 4 else { return TerminalFileNode(url: url, isDirectory: true, children: []) }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .nameKey]
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [.skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants]
        guard let values = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: options) else {
            return TerminalFileNode(url: url, isDirectory: true, children: [])
        }
        let children = values
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(120)
            .compactMap { child -> TerminalFileNode? in
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDirectory { return makeNode(url: child, depth: depth + 1, showHidden: showHidden) }
                return TerminalFileNode(url: child, isDirectory: false, children: nil)
            }
        return TerminalFileNode(url: url, isDirectory: true, children: children)
    }

    private func startWatching(_ url: URL) {
        stopWatching()
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let watchedDescriptor = descriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchedDescriptor,
            eventMask: [.write, .rename, .delete, .attrib, .extend, .link, .revoke],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                self?.refreshWorkItem?.cancel()
                let work = DispatchWorkItem { self?.refresh() }
                self?.refreshWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
            }
        }
        source.setCancelHandler { if watchedDescriptor >= 0 { close(watchedDescriptor) } }
        watcher = source
        source.resume()
    }

    private func stopWatching() {
        refreshWorkItem?.cancel()
        refreshWorkItem = nil
        if let watcher {
            // The source owns and closes its descriptor in its cancel handler.
            self.watcher = nil
            descriptor = -1
            watcher.cancel()
        } else if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
    }
}

@MainActor
private final class DeveloperTerminalModel: NSObject, ObservableObject, @preconcurrency LocalProcessTerminalViewDelegate {
    @Published private(set) var isLive = false
    @Published private(set) var terminalTitle = "Local zsh"
    @Published private(set) var workingDirectory = FileManager.default.homeDirectoryForCurrentUser.path {
        didSet { explorer.setDirectory(workingDirectory) }
    }
    @Published var optionAsMeta = true { didSet { terminalView.optionAsMetaKey = optionAsMeta } }
    @Published private(set) var fontSize: CGFloat = 13
    @Published var helpVisible = false
    @Published var explorerVisible = false
    @Published var helpQuery = ""
    @Published var selectedReference = TerminalCommandReference.catalog.first!
    @Published private(set) var manualText = "Choose a command to see its purpose, examples, flags, and local manual page."
    @Published private(set) var isLoadingManual = false
    @Published var commandComposer = ""
    @Published var composerFocusToken = UUID()
    @Published var helpPanelWidth: CGFloat = 330
    @Published private(set) var commandHistory: [String]

    var onEditorChanged: ((TerminalEditorOverlayController.Editor?) -> Void)?
    let terminalView = LocalProcessTerminalView(frame: .zero)
    let explorer = TerminalDirectoryExplorer()
    private var restartWhenTerminated = false
    private var shuttingDown = false
    private let historyKey = "terminalAssistantHistory"

    override init() {
        commandHistory = Array(UserDefaults.standard.stringArray(forKey: "terminalAssistantHistory") ?? []).prefix(24).map { $0 }
        super.init()
        terminalView.processDelegate = self
        terminalView.optionAsMetaKey = true
        terminalView.allowMouseReporting = true
        terminalView.nativeForegroundColor = NSColor(calibratedWhite: 0.91, alpha: 1)
        terminalView.nativeBackgroundColor = NSColor(calibratedRed: 0.026, green: 0.035, blue: 0.055, alpha: 1)
        terminalView.selectedTextBackgroundColor = NSColor.systemIndigo.withAlphaComponent(0.58)
        terminalView.caretColor = NSColor.systemCyan
        terminalView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        terminalView.wantsLayer = true
        terminalView.layer?.backgroundColor = terminalView.nativeBackgroundColor.cgColor
        terminalView.getTerminal().setCursorStyle(.steadyBar)
        terminalView.setAccessibilityLabel("Interactive terminal. Shell completion, Control, and Option Meta keys are supported.")
        explorer.setDirectory(workingDirectory)
    }

    var displayPath: String {
        workingDirectory.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    var commandSuggestions: [String] {
        let query = commandComposer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let references = TerminalCommandReference.catalog.map(\.command).filter { query.isEmpty || $0.contains(query) }
        let history = commandHistory.filter { query.isEmpty || $0.lowercased().contains(query) }
        let project = projectSuggestions.filter { query.isEmpty || $0.lowercased().contains(query) }
        return Array((references + history + project).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(7))
    }

    private var projectSuggestions: [String] {
        let root = URL(fileURLWithPath: workingDirectory)
        var suggestions: [String] = []
        let manager = FileManager.default
        if manager.fileExists(atPath: root.appendingPathComponent(".git").path) { suggestions += ["git status", "git diff"] }
        if manager.fileExists(atPath: root.appendingPathComponent("Package.swift").path) { suggestions += ["swift test", "swift build"] }
        if manager.fileExists(atPath: root.appendingPathComponent("package.json").path) { suggestions += ["npm run", "npm test"] }
        if manager.fileExists(atPath: root.appendingPathComponent("pyproject.toml").path) { suggestions += ["python3 -m pytest"] }
        return suggestions
    }

    func startIfNeeded() {
        guard !terminalView.process.running else { isLive = true; return }
        shuttingDown = false
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let executable = FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/zsh"
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "RayPlacement"
        environment["TERM_PROGRAM_VERSION"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        terminalView.startProcess(
            executable: executable,
            args: [],
            environment: environment.map { "\($0.key)=\($0.value)" },
            execName: "-" + URL(fileURLWithPath: executable).lastPathComponent,
            currentDirectory: workingDirectory
        )
        isLive = true
        focus()
    }

    func restart() {
        guard terminalView.process.running else { startIfNeeded(); return }
        restartWhenTerminated = true
        terminalView.terminate()
    }

    func interrupt() { guard terminalView.process.running else { return }; send(bytes: [0x03]); focus() }
    func clear() { guard terminalView.process.running else { return }; send(bytes: [0x0c]); focus() }
    func paste() { guard let value = NSPasteboard.general.string(forType: .string), !value.isEmpty else { return }; sendText(value); focus() }
    func increaseFont() { setFontSize(fontSize + 1) }
    func decreaseFont() { setFontSize(fontSize - 1) }

    func shutdown() {
        shuttingDown = true
        restartWhenTerminated = false
        if terminalView.process.running { terminalView.terminate() }
    }

    func focus() { terminalView.window?.makeFirstResponder(terminalView) }
    func toggleHelp() { helpVisible.toggle(); if helpVisible { loadManualIfNeeded() }; focus() }
    func toggleExplorer() { explorerVisible.toggle(); if explorerVisible { refreshExplorer() }; focus() }
    func refreshExplorer() { explorer.refresh() }
    func adjustHelpWidth(by amount: CGFloat) { helpPanelWidth = min(560, max(250, helpPanelWidth + amount)) }
    func requestComposerFocus() { helpVisible = true; composerFocusToken = UUID() }

    func runComposer() {
        let command = commandComposer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        sendText(command + "\n")
        commandHistory.removeAll { $0 == command }
        commandHistory.insert(command, at: 0)
        commandHistory = Array(commandHistory.prefix(24))
        UserDefaults.standard.set(commandHistory, forKey: historyKey)
        commandComposer = ""
        focus()
    }

    func useSuggestion(_ value: String) { commandComposer = value; requestComposerFocus() }

    func selectReference(_ reference: TerminalCommandReference) {
        selectedReference = reference
        manualText = reference.summary
        loadManualIfNeeded()
    }

    func insertPath(_ url: URL) { sendText(Self.shellQuote(url.path)); focus() }

    func changeDirectory(to url: URL) {
        guard url.hasDirectoryPath else { return }
        sendText("cd -- \(Self.shellQuote(url.path))\n")
        workingDirectory = url.path
        refreshExplorer()
        focus()
    }

    func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    func openPath(_ url: URL) { NSWorkspace.shared.open(url) }
    func revealPath(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    private func loadManualIfNeeded() {
        let reference = selectedReference
        isLoadingManual = true
        manualText = "Loading local manual for \(reference.command)…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/man")
            process.arguments = ["-P", "/bin/cat", reference.command]
            process.standardOutput = output
            process.standardError = error
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "MANPAGER": "/bin/cat"]
            do {
                try process.run()
                process.waitUntilExit()
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let failure = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    guard self?.selectedReference == reference else { return }
                    self?.manualText = result.isEmpty
                        ? "No local manual was found.\n\n\(reference.summary)\n\nExamples:\n\(reference.examples.joined(separator: "\n"))\n\n\(failure)"
                        : Self.cleanManualText(String(result.prefix(50_000)))
                    self?.isLoadingManual = false
                }
            } catch {
                DispatchQueue.main.async {
                    guard self?.selectedReference == reference else { return }
                    self?.manualText = "\(reference.summary)\n\nExamples:\n\(reference.examples.joined(separator: "\n"))\n\nManual unavailable: \(error.localizedDescription)"
                    self?.isLoadingManual = false
                }
            }
        }
    }

    private func setFontSize(_ value: CGFloat) {
        fontSize = min(24, max(9, value))
        terminalView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        terminalView.needsDisplay = true
        focus()
    }

    private static func cleanManualText(_ text: String) -> String {
        // `man -P cat` can retain old-style overstrike formatting as `x\\b x`.
        // Collapse it so the side panel remains readable without a pager.
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if next < text.endIndex, text[next] == "\u{08}" {
                let afterBackspace = text.index(after: next)
                if afterBackspace < text.endIndex {
                    output.append(text[afterBackspace])
                    index = text.index(after: afterBackspace)
                    continue
                }
            }
            output.append(character)
            index = next
        }
        return output
    }

    private func sendText(_ text: String) { send(bytes: Array(text.utf8)) }
    private func send(bytes: [UInt8]) { terminalView.send(source: terminalView, data: bytes[...]) }
    private static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        terminalTitle = title.isEmpty ? "Local zsh" : title
        let normalized = title.lowercased()
        if normalized.contains("vim") { onEditorChanged?(.vim) }
        else if normalized.contains("nano") { onEditorChanged?(.nano) }
        else { onEditorChanged?(nil) }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, !directory.isEmpty else { return }
        workingDirectory = directory.removingPercentEncoding ?? directory
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isLive = false
        onEditorChanged?(nil)
        guard !shuttingDown, restartWhenTerminated else { return }
        restartWhenTerminated = false
        DispatchQueue.main.async { [weak self] in self?.startIfNeeded() }
    }
}

private struct TerminalSurface: NSViewRepresentable {
    @ObservedObject var model: DeveloperTerminalModel
    func makeNSView(context: Context) -> LocalProcessTerminalView { model.terminalView }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) { nsView.optionAsMetaKey = model.optionAsMeta }
}

private struct DeveloperTerminalView: View {
    @ObservedObject var model: DeveloperTerminalModel
    @FocusState private var composerFocused: Bool

    var body: some View {
        ZStack {
            LiquidGlassBackdrop(material: .underWindowBackground, blendingMode: .behindWindow)
            VStack(spacing: 8) {
                toolbar
                HSplitView {
                    if model.explorerVisible { TerminalExplorerPanel(model: model).frame(minWidth: 220, idealWidth: 260, maxWidth: 380) }
                    terminalSurface
                    if model.helpVisible { TerminalHelpPanel(model: model).frame(minWidth: 250, idealWidth: model.helpPanelWidth, maxWidth: 560) }
                }
                .clipShape(PrismaticPanelShape(cut: 8))
                inlineHint
            }
            .padding(9)
        }
        .preferredColorScheme(.dark)
        .onAppear { model.startIfNeeded() }
        .onChange(of: model.composerFocusToken) { _ in composerFocused = true }
    }

    private var toolbar: some View {
        HStack(spacing: 9) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SettingsStore.shared.accentTheme.gradient)
                .help("Interactive local zsh session")
            Circle().fill(model.isLive ? Color.green : Color.orange).frame(width: 6, height: 6)
                .shadow(color: model.isLive ? .green.opacity(0.55) : .clear, radius: 5)
            Text(model.terminalTitle).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
            Text(model.displayPath).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Button(action: model.toggleExplorer) { Image(systemName: model.explorerVisible ? "folder.fill" : "folder") }
                .help("Toggle project explorer (⌘⇧E)")
            Button(action: model.toggleHelp) { Image(systemName: model.helpVisible ? "book.closed.fill" : "book.closed") }
                .help("Toggle command help and manual (F1 or ⌘⇧H)")
            Toggle(isOn: $model.optionAsMeta) { Text("⌥ Meta").font(.caption2.monospaced()) }
                .toggleStyle(.switch).controlSize(.mini).help("Send Option-key combinations as terminal Meta sequences")
            Button(action: model.decreaseFont) { Image(systemName: "textformat.size.smaller") }.help("Smaller terminal text")
            Button(action: model.increaseFont) { Image(systemName: "textformat.size.larger") }.help("Larger terminal text")
            Button(action: model.paste) { Image(systemName: "doc.on.clipboard") }.help("Paste into terminal")
            Button(action: model.clear) { Image(systemName: "eraser") }.help("Clear terminal screen")
            Button(action: model.restart) { Image(systemName: "arrow.clockwise") }.help("Restart shell session")
            Button(action: model.interrupt) { Image(systemName: "stop.fill") }.foregroundStyle(.orange).help("Send Control-C")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 13)
        .frame(height: 39)
        .liquidGlass(cornerRadius: 14, depth: .raised, accentOpacity: 0.035)
    }

    private var terminalSurface: some View {
        TerminalSurface(model: model)
            .clipShape(PrismaticPanelShape(cut: 8))
            .overlay(PrismaticPanelShape(cut: 8).stroke(Color.white.opacity(0.09), lineWidth: 0.7))
            .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
            .onTapGesture { model.focus() }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var inlineHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "lightbulb").foregroundStyle(SettingsStore.shared.accentTheme.primary).font(.caption)
            Text("Shell completion: Tab · Help: F1 / ⌘⇧H · Explorer: ⌘⇧E · Command bar: ⌘⇧L")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 11).frame(height: 22)
    }
}

private struct TerminalHelpPanel: View {
    @ObservedObject var model: DeveloperTerminalModel
    @FocusState private var commandFocused: Bool

    private var references: [TerminalCommandReference] {
        let query = model.helpQuery.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return TerminalCommandReference.catalog.filter { query.isEmpty || $0.command.contains(query) || $0.summary.lowercased().contains(query) }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Command Guide", systemImage: "book.closed").font(.caption.weight(.semibold))
                Spacer()
                Button { model.adjustHelpWidth(by: -36) } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    .help("Narrow help panel (⌘⇧[)")
                Button { model.adjustHelpWidth(by: 36) } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    .help("Widen help panel (⌘⇧])")
                Button(action: model.toggleHelp) { Image(systemName: "xmark") }.help("Close help panel (F1 or ⌘⇧H)")
            }
            TextField("Search command or manual", text: $model.helpQuery)
                .textFieldStyle(.plain).font(.system(size: 11.5, design: .monospaced))
                .padding(.horizontal, 9).frame(height: 31)
                .liquidGlass(cornerRadius: 8, depth: .recessed, accentOpacity: 0.01)
                .focused($commandFocused)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(references) { reference in
                        Button(reference.command) { model.selectReference(reference) }
                            .buttonStyle(.plain).font(.caption.monospaced().weight(reference == model.selectedReference ? .bold : .regular))
                            .padding(.horizontal, 7).padding(.vertical, 5)
                            .liquidGlass(cornerRadius: 7, depth: reference == model.selectedReference ? .raised : .recessed, selected: reference == model.selectedReference, accentOpacity: reference == model.selectedReference ? 0.08 : 0.005)
                    }
                }
            }
            commandCard
            Divider().overlay(Color.white.opacity(0.1))
            HStack {
                Text("LOCAL MANUAL").font(.caption2.bold()).foregroundStyle(.secondary)
                Spacer()
                if model.isLoadingManual { ProgressView().controlSize(.mini) }
                Button { model.selectReference(model.selectedReference) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload local manual")
            }
            ScrollView {
                Text(model.manualText).font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(.bottom, 4)
            }
            .liquidGlass(cornerRadius: 10, depth: .recessed, accentOpacity: 0.007)
        }
        .padding(10)
        .liquidGlass(cornerRadius: 15, depth: .floating, accentOpacity: 0.022)
    }

    private var commandCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.selectedReference.synopsis).font(.system(size: 12, weight: .semibold, design: .monospaced))
            Text(model.selectedReference.summary).font(.caption).foregroundStyle(.secondary)
            Text("Examples").font(.caption2.bold()).foregroundStyle(.secondary)
            ForEach(model.selectedReference.examples, id: \.self) { example in
                Button { model.useSuggestion(example) } label: {
                    Text("$ \(example)").font(.caption2.monospaced()).foregroundStyle(SettingsStore.shared.accentTheme.tertiary)
                }
                .buttonStyle(.plain).help("Place this example in the command bar")
            }
            if !model.selectedReference.flags.isEmpty {
                Text(model.selectedReference.flags.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(9)
        .liquidGlass(cornerRadius: 10, depth: .raised, accentOpacity: 0.02)
    }
}

private struct TerminalExplorerPanel: View {
    @ObservedObject var model: DeveloperTerminalModel

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Project", systemImage: "folder").font(.caption.weight(.semibold))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.explorer.showHidden },
                    set: { model.explorer.showHidden = $0 }
                )).labelsHidden().toggleStyle(.checkbox).help("Show hidden files")
                Button(action: model.refreshExplorer) { Image(systemName: "arrow.clockwise") }.help("Refresh project tree (⌘⇧R)")
                Button(action: model.toggleExplorer) { Image(systemName: "xmark") }.help("Close project explorer (⌘⇧E)")
            }
            Text(model.displayPath).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            if let root = model.explorer.root {
                OutlineGroup([root], children: \.children) { node in
                    TerminalExplorerRow(node: node, model: model)
                }
                .font(.system(size: 11.2))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Spacer(); ProgressView(); Text("Reading folder…").font(.caption2).foregroundStyle(.secondary); Spacer()
            }
            Text(model.explorer.status).font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .liquidGlass(cornerRadius: 15, depth: .floating, accentOpacity: 0.018)
    }
}

private struct TerminalExplorerRow: View {
    let node: TerminalFileNode
    @ObservedObject var model: DeveloperTerminalModel

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc")
                .font(.system(size: 10)).foregroundStyle(node.isDirectory ? SettingsStore.shared.accentTheme.primary : .secondary)
            Text(node.name).lineLimit(1)
            Spacer(minLength: 0)
            Menu {
                Button("Insert Path") { model.insertPath(node.url) }
                Button("Copy Path") { model.copyPath(node.url) }
                if node.isDirectory { Button("Change Terminal Directory") { model.changeDirectory(to: node.url) } }
                Button("Open") { model.openPath(node.url) }
                Button("Reveal in Finder") { model.revealPath(node.url) }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { node.isDirectory ? model.changeDirectory(to: node.url) : model.insertPath(node.url) }
        .help(node.isDirectory ? "Double-click to change terminal directory" : "Double-click to insert shell-escaped path")
    }
}

@MainActor
final class TerminalEditorOverlayController {
    enum Editor { case vim, nano }
    private let panel: NSPanel

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 650, height: 48), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.setAccessibilityLabel("Editor shortcut guide")
    }

    func show(editor: Editor) {
        panel.contentView = NSHostingView(rootView: TerminalEditorOverlayView(editor: editor) { [weak self] in self?.panel.orderOut(nil) })
        if let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame { panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 24)) }
        panel.orderFrontRegardless()
    }

    func dismiss() { panel.orderOut(nil) }
}

private struct TerminalEditorOverlayView: View {
    let editor: TerminalEditorOverlayController.Editor
    let dismiss: () -> Void
    private var keys: [(String, String)] {
        switch editor {
        case .vim: return [("i", "Insert"), ("esc", "Normal"), (":w", "Save"), (":q", "Quit"), ("dd", "Delete"), ("/", "Find")]
        case .nano: return [("⌃O", "Save"), ("⌃X", "Exit"), ("⌃W", "Find"), ("⌃K", "Cut"), ("⌃U", "Paste")]
        }
    }
    var body: some View {
        HStack(spacing: 11) {
            Text(editor == .vim ? "VIM" : "NANO").font(.caption2.bold()).foregroundStyle(SettingsStore.shared.accentTheme.primary)
            ForEach(Array(keys.enumerated()), id: \.offset) { _, item in HStack(spacing: 4) { Text(item.0).font(.caption.monospaced().bold()); Text(item.1).font(.caption2).foregroundStyle(.secondary) } }
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close editor shortcut guide")
        }
        .padding(.horizontal, 14).frame(width: 650, height: 48)
        .background(.ultraThinMaterial, in: Capsule()).overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8).preferredColorScheme(.dark)
    }
}
