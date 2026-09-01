import AppKit
import Combine
@preconcurrency import Darwin
import Foundation
import RayPlacementCore
import SwiftTerm
import SwiftUI

@MainActor
final class DeveloperTerminalWindowController: NSWindowController {
    private let model = DeveloperTerminalModel()
    private let shortcutGuide = TerminalEditorOverlayController()
    private var keyMonitor: Any?
    private var hasPresented = false

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
        window.minSize = NSSize(width: 820, height: 500)
        window.setAccessibilityLabel("Lima developer terminal")
        self.init(window: window)
        model.onEditorChanged = { [weak self] editor in
            guard let self else { return }
            if let editor { self.shortcutGuide.show(editor: editor) }
            else { self.shortcutGuide.dismiss() }
        }
        window.contentView = NSHostingView(rootView: LimaTypographyRoot(content: DeveloperTerminalView(model: model)))
        installKeyMonitor()
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    func present() {
        model.startIfNeeded()
        if !hasPresented { window?.center(); hasPresented = true }
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
        .init(command: "pwd", synopsis: "pwd [-P]", summary: "Print the shell's current directory.", examples: ["pwd", "pwd -P"], flags: ["-P resolve symbolic links"]),
        .init(command: "ls", synopsis: "ls [-lah] [path]", summary: "List files and directories.", examples: ["ls", "ls -lah", "ls -lah src"], flags: ["-l long listing", "-a include hidden files", "-h readable sizes"]),
        .init(command: "find", synopsis: "find [path] [expression]", summary: "Find files by name, type, age, or other properties.", examples: ["find . -type f", "find . -name '*.swift'", "find . -maxdepth 2 -type d"], flags: ["-name pattern", "-type f/d", "-maxdepth levels"]),
        .init(command: "rg", synopsis: "rg [pattern] [path]", summary: "Fast recursive text search (ripgrep).", examples: ["rg TODO", "rg -n 'func ' Sources", "rg --files"], flags: ["-n line numbers", "--files list tracked candidates", "-g glob filter"]),
        .init(command: "grep", synopsis: "grep [options] pattern [file]", summary: "Search text streams and files for matching lines.", examples: ["grep -n error app.log", "grep -R 'needle' ."], flags: ["-n line numbers", "-i ignore case", "-R recursive"]),
        .init(command: "cat", synopsis: "cat [file ...]", summary: "Print or concatenate files.", examples: ["cat README.md", "cat part-* > combined"], flags: ["-n number lines"]),
        .init(command: "less", synopsis: "less [file]", summary: "Read long output in a searchable pager.", examples: ["less app.log", "git log | less"], flags: ["/ search", "n next match", "q quit"]),
        .init(command: "head", synopsis: "head [-n count] [file]", summary: "Print the beginning of a file or stream.", examples: ["head -n 20 app.log"], flags: ["-n number of lines"]),
        .init(command: "tail", synopsis: "tail [-f] [-n count] [file]", summary: "Print or follow the end of a file.", examples: ["tail -n 50 app.log", "tail -f server.log"], flags: ["-f follow changes", "-n line count"]),
        .init(command: "mkdir", synopsis: "mkdir [-p] directory", summary: "Create directories.", examples: ["mkdir build", "mkdir -p output/reports"], flags: ["-p create parents"]),
        .init(command: "cp", synopsis: "cp [options] source destination", summary: "Copy files or directories.", examples: ["cp config.example config", "cp -R assets backup/"], flags: ["-R recursive", "-i confirm overwrite"]),
        .init(command: "mv", synopsis: "mv source destination", summary: "Move or rename files and directories.", examples: ["mv old.txt new.txt", "mv report.pdf archive/"], flags: ["-i confirm overwrite", "-n never overwrite"]),
        .init(command: "rm", synopsis: "rm [options] path", summary: "Remove files. Review recursive targets carefully.", examples: ["rm file.tmp", "rm -i old.txt"], flags: ["-i confirm", "-r recursive", "-f force"]),
        .init(command: "chmod", synopsis: "chmod mode file", summary: "Change file permissions.", examples: ["chmod +x script.sh", "chmod 600 secret.env"], flags: ["+x executable", "600 owner read/write", "755 executable/public read"]),
        .init(command: "ps", synopsis: "ps [options]", summary: "Inspect running processes.", examples: ["ps aux", "ps aux | rg server"], flags: ["aux all user processes"]),
        .init(command: "kill", synopsis: "kill [-signal] pid", summary: "Send a signal to a process.", examples: ["kill 1234", "kill -TERM 1234"], flags: ["-TERM graceful stop", "-KILL immediate stop"]),
        .init(command: "curl", synopsis: "curl [options] URL", summary: "Transfer data to or from HTTP and other endpoints.", examples: ["curl -i https://example.com", "curl -X POST -H 'Content-Type: application/json' -d '{}' https://example.com"], flags: ["-i headers", "-L follow redirects", "-X method", "-d body"]),
        .init(command: "ssh", synopsis: "ssh [user@]host", summary: "Open an encrypted remote shell. The Files panel follows hosts available through keys or ssh-agent.", examples: ["ssh server", "ssh user@server"], flags: ["-p port", "-i identity file", "-L local forwarding"]),
        .init(command: "scp", synopsis: "scp source destination", summary: "Copy files over SSH.", examples: ["scp file.txt user@host:/tmp/", "scp user@host:/var/log/app.log ."], flags: ["-r recursive", "-P port"]),
        .init(command: "tar", synopsis: "tar [options] archive files", summary: "Create or extract archives.", examples: ["tar -czf archive.tgz folder", "tar -xzf archive.tgz"], flags: ["-c create", "-x extract", "-z gzip", "-f archive"]),
        .init(command: "git", synopsis: "git <command> [options]", summary: "Inspect and manage a Git repository.", examples: ["git status", "git diff", "git log --oneline -10"], flags: ["status working tree", "diff uncommitted changes", "switch change branch"]),
        .init(command: "swift", synopsis: "swift <subcommand>", summary: "Build, test, and run Swift packages.", examples: ["swift test", "swift build", "swift run"], flags: ["test run package tests", "build compile package", "run run executable"]),
        .init(command: "python3", synopsis: "python3 [script.py]", summary: "Run Python 3 or start an interactive interpreter.", examples: ["python3 script.py", "python3 -m json.tool file.json"], flags: ["-m run a module", "-c execute a short expression"]),
        .init(command: "npm", synopsis: "npm <command>", summary: "Run Node package scripts and manage dependencies.", examples: ["npm run", "npm test", "npm run dev"], flags: ["run list or execute scripts", "test run test script"]),
        .init(command: "brew", synopsis: "brew <command> [formula]", summary: "Install and manage Homebrew packages.", examples: ["brew search ripgrep", "brew install ripgrep", "brew update"], flags: ["search", "install", "upgrade", "info"]),
        .init(command: "docker", synopsis: "docker <command>", summary: "Build and run containers.", examples: ["docker ps", "docker compose up", "docker logs -f container"], flags: ["ps containers", "compose multi-container", "logs output"]),
        .init(command: "kubectl", synopsis: "kubectl <command> [resource]", summary: "Inspect and manage Kubernetes resources.", examples: ["kubectl get pods", "kubectl describe pod name", "kubectl logs -f pod"], flags: ["-n namespace", "get", "describe", "logs"]),
        .init(command: "vim", synopsis: "vim [file]", summary: "Edit a file with Vim's Normal, Insert, and Command modes.", examples: ["vim README.md", "vim +42 Sources/App.swift"], flags: ["i insert", "Esc normal", ":w save", ":q quit"]),
        .init(command: "nano", synopsis: "nano [file]", summary: "Edit a file with visible Control-key commands.", examples: ["nano README.md", "nano +42 app.conf"], flags: ["Control-O save", "Control-X exit", "Control-W find"]),
        .init(command: "man", synopsis: "man <command>", summary: "Read a command's local manual page.", examples: ["man git", "man ls", "man 1 printf"], flags: ["q quit pager", "/ search within manual", "n next match"])
    ]
}

private struct TerminalFileNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let children: [TerminalFileNode]?

    var id: String { url.absoluteString }
    var name: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }
    var isRemote: Bool { url.scheme == "ssh" }
}

@MainActor
private final class TerminalDirectoryExplorer: ObservableObject {
    @Published private(set) var root: TerminalFileNode?
    @Published var showHidden = false { didSet { refresh() } }
    @Published private(set) var status = ""
    @Published private(set) var remoteTarget: String?

    private var directoryURL: URL?
    private var remotePath: String?
    private var watcher: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private var refreshWorkItem: DispatchWorkItem?
    private var revision = UUID()

    func setDirectory(_ path: String) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard directoryURL != url || remoteTarget != nil else { return }
        remoteTarget = nil
        remotePath = nil
        directoryURL = url
        refresh()
        startWatching(url)
    }

    func setRemote(target: String, path: String) {
        let normalizedPath = path.hasPrefix("/") ? path : "~"
        guard remoteTarget != target || directoryURL?.path != normalizedPath else { return }
        stopWatching()
        remoteTarget = target
        remotePath = normalizedPath
        directoryURL = Self.remoteURL(target: target, path: normalizedPath)
        refresh()
    }

    func refresh() {
        guard let directoryURL else { return }
        let hidden = showHidden
        let rootURL = directoryURL
        let request = UUID()
        revision = request
        if let remoteTarget {
            status = "Reading \(remoteTarget)…"
            refreshRemote(target: remoteTarget, path: remotePath ?? rootURL.path, request: request)
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var budget = 1_200
            let node = Self.makeNode(url: rootURL, depth: 0, showHidden: hidden, budget: &budget)
            let limited = budget <= 0
            DispatchQueue.main.async {
                guard self?.directoryURL == rootURL, self?.revision == request else { return }
                self?.root = node
                self?.status = node == nil ? "Folder is unavailable" : (limited ? "1,200-entry preview · navigate into a folder to see more" : "Updated just now")
            }
        }
    }

    nonisolated private static func makeNode(url: URL, depth: Int, showHidden: Bool, budget: inout Int) -> TerminalFileNode? {
        guard budget > 0 else { return nil }
        budget -= 1
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { return nil }
        guard directory.boolValue else { return TerminalFileNode(url: url, isDirectory: false, children: nil) }
        guard depth < 16 else { return TerminalFileNode(url: url, isDirectory: true, children: []) }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .nameKey]
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [.skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants]
        guard let values = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: options) else {
            return TerminalFileNode(url: url, isDirectory: true, children: [])
        }
        let children = values
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(160)
            .compactMap { child -> TerminalFileNode? in
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard budget > 0 else { return nil }
                if isDirectory, (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true {
                    return makeNode(url: child, depth: depth + 1, showHidden: showHidden, budget: &budget)
                }
                budget -= 1
                return TerminalFileNode(url: child, isDirectory: false, children: nil)
            }
        return TerminalFileNode(url: url, isDirectory: true, children: children)
    }

    nonisolated private static func remoteURL(target: String, path: String) -> URL {
        var components = URLComponents()
        components.scheme = "ssh"
        if let split = target.lastIndex(of: "@") {
            components.user = String(target[..<split])
            components.host = String(target[target.index(after: split)...])
        } else {
            components.host = target
        }
        components.path = path.hasPrefix("/") ? path : "/"
        return components.url ?? URL(string: "ssh://invalid/")!
    }

    private func refreshRemote(target: String, path: String, request: UUID) {
        let hidden = showHidden
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            let quoted = path == "~" ? "\"$HOME\"" : TerminalWorkspaceInput.shellQuote(path)
            let hiddenFilter = hidden ? "" : " ! -name '.*'"
            let command = "( /usr/bin/find \(quoted) -maxdepth 16 -type d\(hiddenFilter) -print | /usr/bin/head -n 600; /usr/bin/printf '\\n__LIMA_FILES__\\n'; /usr/bin/find \(quoted) -maxdepth 16\(hiddenFilter) -print | /usr/bin/head -n 1200 )"
            process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "--", target, command]
            process.standardOutput = output
            process.standardError = errors
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self)
                let error = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let node = process.terminationStatus == 0 ? Self.makeRemoteTree(target: target, requestedRoot: path, output: text) : nil
                DispatchQueue.main.async {
                    guard self?.revision == request, self?.remoteTarget == target else { return }
                    self?.root = node
                    self?.status = node == nil
                        ? (error.isEmpty ? "Remote files unavailable · configure SSH keys or agent access" : String(error.prefix(180)))
                        : "Remote tree · \(target) · up to 16 levels"
                }
            } catch {
                DispatchQueue.main.async {
                    guard self?.revision == request else { return }
                    self?.root = nil
                    self?.status = "Remote files unavailable · \(error.localizedDescription)"
                }
            }
        }
    }

    nonisolated private static func makeRemoteTree(target: String, requestedRoot: String, output: String) -> TerminalFileNode? {
        let halves = output.components(separatedBy: "\n__LIMA_FILES__\n")
        guard halves.count == 2 else { return nil }
        let directoryLines = halves[0].split(separator: "\n").map(String.init)
        let directories = Set(directoryLines)
        let rootPath = requestedRoot == "~" ? (directoryLines.first ?? requestedRoot) : requestedRoot
        let paths = halves[1].split(separator: "\n").map(String.init).filter { $0 == rootPath || $0.hasPrefix(rootPath + "/") }
        guard !paths.isEmpty else { return nil }
        func node(_ path: String) -> TerminalFileNode {
            let prefix = path == "/" ? "/" : path + "/"
            let direct = paths.filter { candidate in
                guard candidate.hasPrefix(prefix), candidate != path else { return false }
                return !candidate.dropFirst(prefix.count).contains("/")
            }
            let children = directories.contains(path) ? direct.map(node).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } : nil
            return TerminalFileNode(url: remoteURL(target: target, path: path), isDirectory: directories.contains(path), children: children)
        }
        return node(rootPath)
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
private final class ContextAwareTerminalView: LocalProcessTerminalView {
    var onUserInput: ((ArraySlice<UInt8>) -> Void)?

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onUserInput?(data)
        super.send(source: source, data: data)
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
    @Published var composerVisible = false
    @Published var inputStatus = ""
    @Published var helpQuery = ""
    @Published var selectedReference = TerminalCommandReference.catalog.first!
    @Published private(set) var manualText = "Choose a command to see its purpose, examples, flags, and local manual page."
    @Published private(set) var isLoadingManual = false
    @Published var commandComposer = ""
    @Published var composerFocusToken = UUID()
    @Published var helpPanelWidth: CGFloat = 330
    @Published private(set) var commandHistory: [String]
    @Published private(set) var activeContext = "Ready for a command"
    @Published private(set) var activeRemoteTarget: String?

    var onEditorChanged: ((TerminalEditorOverlayController.Editor?) -> Void)?
    let terminalView = ContextAwareTerminalView(frame: .zero)
    let explorer = TerminalDirectoryExplorer()
    private var restartWhenTerminated = false
    private var shuttingDown = false
    private let historyKey = "terminalAssistantHistory"
    private var typographySubscription: AnyCancellable?
    private var directoryTimer: Timer?
    private var manualCache: [String: String] = [:]
    private var pendingCommandBytes: [UInt8] = []
    private var discardingEscapeSequence = false
    private var activeEditor: TerminalEditorOverlayController.Editor?

    override init() {
        commandHistory = Array(UserDefaults.standard.stringArray(forKey: "terminalAssistantHistory") ?? []).prefix(24).map { $0 }
        super.init()
        terminalView.processDelegate = self
        terminalView.onUserInput = { [weak self] bytes in self?.observeUserInput(bytes) }
        terminalView.optionAsMetaKey = true
        terminalView.allowMouseReporting = true
        terminalView.nativeForegroundColor = NSColor(calibratedWhite: 0.91, alpha: 1)
        terminalView.nativeBackgroundColor = NSColor(calibratedRed: 0.026, green: 0.035, blue: 0.055, alpha: 1)
        terminalView.selectedTextBackgroundColor = NSColor.systemIndigo.withAlphaComponent(0.58)
        terminalView.caretColor = NSColor.systemCyan
        let savedSize = UserDefaults.standard.double(forKey: "terminalFontSize")
        fontSize = savedSize > 0 ? min(28, max(9, savedSize)) : 13
        terminalView.font = NSFont.monospacedSystemFont(ofSize: AppTypography.size(fontSize), weight: .regular)
        terminalView.wantsLayer = true
        terminalView.layer?.backgroundColor = terminalView.nativeBackgroundColor.cgColor
        terminalView.getTerminal().setCursorStyle(.steadyBar)
        terminalView.setAccessibilityLabel("Interactive terminal. Shell completion, Control, and Option Meta keys are supported.")
        explorer.setDirectory(workingDirectory)
        typographySubscription = AppTypography.shared.$scale.sink { [weak self] scale in
            guard let self else { return }
            self.terminalView.font = .monospacedSystemFont(ofSize: self.fontSize * scale, weight: .regular)
        }
    }

    var displayPath: String {
        if let target = activeRemoteTarget {
            return "\(target):\(explorer.root?.url.path ?? "~")"
        }
        return workingDirectory.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    var commandSuggestions: [String] {
        let query = commandComposer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let references = TerminalCommandReference.catalog.map(\.command).filter { query.isEmpty || $0.contains(query) }
        let history = commandHistory.filter { query.isEmpty || $0.lowercased().contains(query) }
        let project = projectSuggestions.filter { query.isEmpty || $0.lowercased().contains(query) }
        return Array((references + history + project).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(7))
    }

    private var projectSuggestions: [String] {
        if let target = activeRemoteTarget {
            return ["pwd", "ls -lah", "find . -maxdepth 2 -type f", "df -h", "exit"].map { $0 }
                + ["ssh \(target)"]
        }
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
        environment["TERM_PROGRAM"] = "Lima"
        environment["TERM_PROGRAM_VERSION"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        terminalView.startProcess(
            executable: executable,
            args: [],
            environment: environment.map { "\($0.key)=\($0.value)" },
            execName: "-" + URL(fileURLWithPath: executable).lastPathComponent,
            currentDirectory: workingDirectory
        )
        isLive = true
        directoryTimer?.invalidate()
        directoryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshShellDirectory() }
        }
        directoryTimer?.tolerance = 0.5
        focus()
    }

    func restart() {
        guard terminalView.process.running else { startIfNeeded(); return }
        restartWhenTerminated = true
        terminalView.terminate()
    }

    func interrupt() { guard terminalView.process.running else { return }; send(bytes: [0x03]); focus() }
    func clear() { guard terminalView.process.running else { return }; send(bytes: [0x0c]); focus() }
    func paste() { guard isLive else { return }; terminalView.paste(self); focus() }
    func increaseFont() { setFontSize(fontSize + 1) }
    func decreaseFont() { setFontSize(fontSize - 1) }

    func shutdown() {
        shuttingDown = true
        directoryTimer?.invalidate()
        directoryTimer = nil
        restartWhenTerminated = false
        if terminalView.process.running { terminalView.terminate() }
    }

    func focus() { terminalView.window?.makeFirstResponder(terminalView) }
    func toggleHelp() { helpVisible.toggle(); if helpVisible { explorerVisible = false; loadManualIfNeeded() }; focus() }
    func toggleExplorer() { explorerVisible.toggle(); if explorerVisible { helpVisible = false; refreshExplorer() }; focus() }
    func refreshExplorer() { explorer.refresh() }
    func adjustHelpWidth(by amount: CGFloat) { helpPanelWidth = min(560, max(250, helpPanelWidth + amount)) }
    func requestComposerFocus() { composerVisible = true; composerFocusToken = UUID() }

    func insertComposer() {
        let command = commandComposer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLive, !command.isEmpty else { return }
        guard TerminalWorkspaceInput.isSafeSingleLine(command) else {
            inputStatus = "Use a single line without control characters."
            return
        }
        // This is an input assistant, not a second shell. Never append Return
        // or interrupt the foreground process. Execution stays in the terminal.
        sendText(command)
        inputStatus = "Inserted · review in the terminal, then press Return"
        commandComposer = ""
        composerVisible = false
        focus()
    }

    func useSuggestion(_ value: String) { commandComposer = value; requestComposerFocus() }

    func selectReference(_ reference: TerminalCommandReference) {
        selectedReference = reference
        manualText = reference.summary
        loadManualIfNeeded()
    }

    func reloadManual() {
        manualCache.removeValue(forKey: selectedReference.command)
        loadManualIfNeeded()
    }

    func insertPath(_ url: URL) { useSuggestion(TerminalWorkspaceInput.shellQuote(url.path)) }

    func changeDirectory(to url: URL) {
        useSuggestion("cd -- \(TerminalWorkspaceInput.shellQuote(url.path))")
    }

    func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    func openPath(_ url: URL) { guard url.isFileURL else { insertPath(url); return }; NSWorkspace.shared.open(url) }
    func revealPath(_ url: URL) { guard url.isFileURL else { copyPath(url); return }; NSWorkspace.shared.activateFileViewerSelecting([url]) }

    private func observeUserInput(_ bytes: ArraySlice<UInt8>) {
        for byte in bytes {
            if discardingEscapeSequence {
                if (0x40...0x7e).contains(byte), byte != 0x5b { discardingEscapeSequence = false }
                continue
            }
            switch byte {
            case 0x1b:
                discardingEscapeSequence = true
            case 0x03:
                pendingCommandBytes.removeAll(keepingCapacity: true)
                activeContext = "Interrupted · terminal remains ready"
            case 0x08, 0x7f:
                if !pendingCommandBytes.isEmpty { pendingCommandBytes.removeLast() }
            case 0x0a, 0x0d:
                let command = String(decoding: pendingCommandBytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                pendingCommandBytes.removeAll(keepingCapacity: true)
                if !command.isEmpty { commandSubmitted(command) }
            case 0x20...0x7e:
                if pendingCommandBytes.count < 8_192 { pendingCommandBytes.append(byte) }
            default:
                break
            }
        }
    }

    private func commandSubmitted(_ command: String) {
        inputStatus = ""
        if isSafeToRemember(command) {
            commandHistory.removeAll { $0 == command }
            commandHistory.insert(command, at: 0)
            if commandHistory.count > 40 { commandHistory.removeLast(commandHistory.count - 40) }
            UserDefaults.standard.set(commandHistory, forKey: historyKey)
        }
        if let destination = TerminalWorkspaceInput.sshDestination(from: command) {
            activeRemoteTarget = destination
            activeContext = "Connecting to \(destination) · remote file explorer ready"
            explorer.setRemote(target: destination, path: "~")
            if explorerVisible { explorer.refresh() }
            return
        }
        let primary = TerminalWorkspaceInput.primaryCommand(in: command)?.lowercased() ?? "command"
        if ["vi", "vim", "nvim"].contains(primary) { setActiveEditor(.vim) }
        else if primary == "nano" { setActiveEditor(.nano) }
        else { setActiveEditor(nil) }
        if primary == "exit", activeRemoteTarget != nil {
            activeRemoteTarget = nil
            explorer.setDirectory(workingDirectory)
            activeContext = "Returning to local shell"
        } else {
            activeContext = contextDescription(for: primary)
            let manualCommand = ["vi", "nvim"].contains(primary) ? "vim" : primary
            if let reference = TerminalCommandReference.catalog.first(where: { $0.command == manualCommand }) {
                selectedReference = reference
                if helpVisible { loadManualIfNeeded() }
            }
        }
    }

    private func contextDescription(for command: String) -> String {
        switch command {
        case "git": return "Git workflow · repository-aware suggestions available"
        case "swift", "npm", "python3", "pytest": return "Build/test workflow · project commands available"
        case "vim", "nvim", "nano": return "Editor active · shortcut guide follows the terminal"
        case "cd", "pushd", "popd": return "Navigating · file explorer will follow the working directory"
        case "ls", "find", "rg": return "Inspecting files · open the file explorer with ⌘⇧E"
        case "sudo": return "Elevated command · macOS will request credentials in the terminal"
        default: return "Running \(command) · terminal state is preserved"
        }
    }

    private func isSafeToRemember(_ command: String) -> Bool {
        let lowered = command.lowercased()
        let sensitive = ["password", "passwd", "secret", "token", "api_key", "apikey", "sshpass", "sqlplus", "mysql -p", "export "]
        return !sensitive.contains { lowered.contains($0) }
    }

    private func loadManualIfNeeded() {
        let reference = selectedReference
        if let cached = manualCache[reference.command] { manualText = cached; isLoadingManual = false; return }
        isLoadingManual = true
        manualText = "Loading local manual for \(reference.command)…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/man")
            process.arguments = ["-P", "/bin/cat", reference.command]
            process.standardOutput = output
            process.standardError = output
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "MANPAGER": "/bin/cat"]
            do {
                try process.run()
                // Drain before waiting: larger manual pages otherwise fill
                // the pipe and deadlock both the reader and the man process.
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    guard self?.selectedReference == reference else { return }
                    self?.manualText = result.isEmpty
                        ? "No local manual was found.\n\n\(reference.summary)\n\nExamples:\n\(reference.examples.joined(separator: "\n"))"
                        : Self.cleanManualText(String(result.prefix(50_000)))
                    self?.manualCache[reference.command] = self?.manualText
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
        fontSize = min(28, max(9, value))
        UserDefaults.standard.set(fontSize, forKey: "terminalFontSize")
        terminalView.font = NSFont.monospacedSystemFont(ofSize: AppTypography.size(fontSize), weight: .regular)
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
    private func refreshShellDirectory() {
        guard isLive, terminalView.window?.isVisible == true, activeRemoteTarget == nil else { return }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(terminalView.process.shellPid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        if path.hasPrefix("/"), path != workingDirectory { workingDirectory = path }
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        terminalTitle = title.isEmpty ? "Local zsh" : title
        let normalized = title.lowercased()
        if normalized.contains("vim") || normalized.contains("nvim") { setActiveEditor(.vim) }
        else if normalized.contains("nano") { setActiveEditor(.nano) }
        else if normalized.contains("zsh") || normalized.contains("shell") { setActiveEditor(nil) }
    }

    private func setActiveEditor(_ editor: TerminalEditorOverlayController.Editor?) {
        guard activeEditor != editor else { return }
        activeEditor = editor
        onEditorChanged?(editor)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, !directory.isEmpty else { return }
        if let path = TerminalWorkspaceInput.localDirectory(directory) {
            activeRemoteTarget = nil
            workingDirectory = path
        } else if let remote = TerminalWorkspaceInput.remoteDirectory(directory) {
            let target = activeRemoteTarget.flatMap { $0.hasSuffix("@\(remote.host)") || $0 == remote.host ? $0 : nil } ?? remote.host
            activeRemoteTarget = target
            explorer.setRemote(target: target, path: remote.path)
            activeContext = "Remote \(target) · \(remote.path)"
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isLive = false
        directoryTimer?.invalidate()
        directoryTimer = nil
        setActiveEditor(nil)
        activeRemoteTarget = nil
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
    @State private var inspectorDragStart: CGFloat?

    var body: some View {
        ZStack {
            LiquidGlassBackdrop(material: .underWindowBackground, blendingMode: .behindWindow)
            VStack(spacing: 8) {
                toolbar
                GeometryReader { geometry in
                  HStack(spacing: 0) {
                    terminalSurface
                    if model.helpVisible || model.explorerVisible {
                        Rectangle().fill(Color.white.opacity(0.09)).frame(width: 5)
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                                if inspectorDragStart == nil { inspectorDragStart = model.helpPanelWidth }
                                model.helpPanelWidth = min(max(250, geometry.size.width - 345), min(560, max(250, (inspectorDragStart ?? 330) - value.translation.width)))
                            }.onEnded { _ in inspectorDragStart = nil })
                            .accessibilityLabel("Resize terminal inspector")
                        VStack(spacing: 6) {
                            HStack {
                                Button("Files") { if !model.explorerVisible { model.toggleExplorer() } }
                                    .foregroundStyle(model.explorerVisible ? Color.accentColor : .secondary)
                                Button("Guide") { if !model.helpVisible { model.toggleHelp() } }
                                    .foregroundStyle(model.helpVisible ? Color.accentColor : .secondary)
                                Spacer()
                            }.buttonStyle(.plain).limaFont(.caption.weight(.semibold)).padding(8)
                            if model.helpVisible { TerminalHelpPanel(model: model) }
                            else { TerminalExplorerPanel(model: model) }
                        }.frame(width: min(model.helpPanelWidth, max(250, geometry.size.width - 345)))
                    }
                  }
                }
                .clipShape(PrismaticPanelShape(cut: 8))
                if model.composerVisible { commandShelf }
                statusBar
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
                .limaFont(.system(size: 13, weight: .semibold))
                .foregroundStyle(SettingsStore.shared.accentTheme.gradient)
                .help("Interactive local zsh session")
            Circle().fill(model.isLive ? Color.green : Color.orange).frame(width: 6, height: 6)
                .shadow(color: model.isLive ? .green.opacity(0.55) : .clear, radius: 5)
            Text(model.terminalTitle).limaFont(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
            Text(model.displayPath).limaFont(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Button(action: model.toggleExplorer) { Image(systemName: model.explorerVisible ? "folder.fill" : "folder") }
                .help("Toggle project explorer (⌘⇧E)")
            Button(action: model.toggleHelp) { Image(systemName: model.helpVisible ? "book.closed.fill" : "book.closed") }
                .help("Toggle command help and manual (F1 or ⌘⇧H)")
            Button(action: model.requestComposerFocus) { Image(systemName: "text.badge.plus") }
                .help("Command suggestions (⌘⇧L)")
            Button(action: model.paste) { Image(systemName: "doc.on.clipboard") }.help("Paste into terminal")
            Button(action: model.interrupt) { Image(systemName: "stop.fill") }.foregroundStyle(.orange).help("Send Control-C")
            Menu {
                Toggle("Option as Meta", isOn: $model.optionAsMeta)
                Button("Larger terminal text", action: model.increaseFont)
                Button("Smaller terminal text", action: model.decreaseFont)
                Button("Clear screen · Control-L", action: model.clear)
                Divider()
                Button("Restart shell…") {
                    let alert = NSAlert()
                    alert.messageText = "Restart this shell?"
                    alert.informativeText = "Running commands will stop and shell variables will be lost."
                    alert.addButton(withTitle: "Cancel")
                    alert.addButton(withTitle: "Restart")
                    if alert.runModal() == .alertSecondButtonReturn { model.restart() }
                }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 13)
        .frame(minHeight: 39)
        .liquidGlass(cornerRadius: 14, depth: .raised, accentOpacity: 0.035)
    }

    private var terminalSurface: some View {
        TerminalSurface(model: model)
            .padding(8)
            .background(Color(nsColor: model.terminalView.nativeBackgroundColor))
            .clipShape(PrismaticPanelShape(cut: 8))
            .overlay(PrismaticPanelShape(cut: 8).stroke(Color.white.opacity(0.09), lineWidth: 0.7))
            .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
            .onTapGesture { model.focus() }
            .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var commandShelf: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: "chevron.right").foregroundStyle(Color.accentColor)
                TextField("Find or draft a command", text: $model.commandComposer)
                    .textFieldStyle(.plain).limaFont(.system(size: 12, design: .monospaced))
                    .focused($composerFocused).onSubmit { model.insertComposer() }
                Button("Insert", action: model.insertComposer)
                    .disabled(!model.isLive || model.commandComposer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Insert without executing. Review it in the shell, then press Return.")
                Button { model.composerVisible = false; model.focus() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Close command suggestions")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(model.commandSuggestions, id: \.self) { command in
                        Button(command) { model.commandComposer = command }
                            .buttonStyle(.plain).limaFont(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
        }.padding(10).liquidGlass(cornerRadius: 8, depth: .recessed)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text(model.inputStatus.isEmpty ? (model.isLive ? model.activeContext : "Shell exited") : model.inputStatus)
                .limaFont(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if !model.isLive { Button("Start shell", action: model.startIfNeeded).limaFont(.caption) }
            Text(model.optionAsMeta ? "⌃ Control · ⌥ Meta" : "⌃ Control").limaFont(.caption2.monospaced()).foregroundStyle(.tertiary)
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
                Label("Command Guide", systemImage: "book.closed").limaFont(.caption.weight(.semibold))
                Spacer()
                Button { model.adjustHelpWidth(by: -36) } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    .help("Narrow help panel (⌘⇧[)")
                Button { model.adjustHelpWidth(by: 36) } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    .help("Widen help panel (⌘⇧])")
                Button(action: model.toggleHelp) { Image(systemName: "xmark") }.help("Close help panel (F1 or ⌘⇧H)")
            }
            TextField("Search command or manual", text: $model.helpQuery)
                .textFieldStyle(.plain).limaFont(.system(size: 11.5, design: .monospaced))
                .padding(.horizontal, 9).frame(height: 31)
                .liquidGlass(cornerRadius: 8, depth: .recessed, accentOpacity: 0.01)
                .focused($commandFocused)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(references) { reference in
                        Button(reference.command) { model.selectReference(reference) }
                            .buttonStyle(.plain).limaFont(.caption.monospaced().weight(reference == model.selectedReference ? .bold : .regular))
                            .padding(.horizontal, 7).padding(.vertical, 5)
                            .liquidGlass(cornerRadius: 7, depth: reference == model.selectedReference ? .raised : .recessed, selected: reference == model.selectedReference, accentOpacity: reference == model.selectedReference ? 0.08 : 0.005)
                    }
                }
            }
            commandCard
            Divider().overlay(Color.white.opacity(0.1))
            HStack {
                Text("LOCAL MANUAL").limaFont(.caption2.bold()).foregroundStyle(.secondary)
                Spacer()
                if model.isLoadingManual { ProgressView().controlSize(.mini) }
                Button(action: model.reloadManual) { Image(systemName: "arrow.clockwise") }
                    .help("Reload local manual")
            }
            ScrollView {
                Text(model.manualText).limaFont(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(.bottom, 4)
            }
            .liquidGlass(cornerRadius: 10, depth: .recessed, accentOpacity: 0.007)
        }
        .padding(10)
        .liquidGlass(cornerRadius: 15, depth: .floating, accentOpacity: 0.022)
    }

    private var commandCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.selectedReference.synopsis).limaFont(.system(size: 12, weight: .semibold, design: .monospaced))
            Text(model.selectedReference.summary).limaFont(.caption).foregroundStyle(.secondary)
            Text("Examples").limaFont(.caption2.bold()).foregroundStyle(.secondary)
            ForEach(model.selectedReference.examples, id: \.self) { example in
                Button { model.useSuggestion(example) } label: {
                    Text("$ \(example)").limaFont(.caption2.monospaced()).foregroundStyle(SettingsStore.shared.accentTheme.tertiary)
                }
                .buttonStyle(.plain).help("Place this example in the command bar")
            }
            if !model.selectedReference.flags.isEmpty {
                Text(model.selectedReference.flags.joined(separator: " · ")).limaFont(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(9)
        .liquidGlass(cornerRadius: 10, depth: .raised, accentOpacity: 0.02)
    }
}

private struct TerminalExplorerPanel: View {
    @ObservedObject var model: DeveloperTerminalModel
    @ObservedObject private var explorer: TerminalDirectoryExplorer

    init(model: DeveloperTerminalModel) {
        self.model = model
        self.explorer = model.explorer
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label(model.explorer.remoteTarget.map { "Remote · \($0)" } ?? "Project", systemImage: model.explorer.remoteTarget == nil ? "folder" : "network").limaFont(.caption.weight(.semibold))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.explorer.showHidden },
                    set: { model.explorer.showHidden = $0 }
                )).labelsHidden().toggleStyle(.checkbox).help("Show hidden files")
                Button(action: model.refreshExplorer) { Image(systemName: "arrow.clockwise") }.help("Refresh project tree (⌘⇧R)")
                Button(action: model.toggleExplorer) { Image(systemName: "xmark") }.help("Close project explorer (⌘⇧E)")
            }
            Text(model.displayPath).limaFont(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            if let root = model.explorer.root {
                ScrollView {
                    TerminalTree(node: root, model: model)
                    .limaFont(.system(size: 11.2))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }.frame(maxHeight: .infinity)
            } else {
                Spacer(); ProgressView(); Text("Reading folder…").limaFont(.caption2).foregroundStyle(.secondary); Spacer()
            }
            Text(model.explorer.status).limaFont(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .liquidGlass(cornerRadius: 15, depth: .floating, accentOpacity: 0.018)
    }
}

private struct TerminalTree: View {
    let node: TerminalFileNode
    @ObservedObject var model: DeveloperTerminalModel
    @State private var expanded: Set<String> = []

    var body: some View {
        TerminalTreeBranch(node: node, depth: 0, expanded: $expanded, model: model)
            .onAppear { expanded.insert(node.id) }
            .onChange(of: node.id) { id in expanded = [id] }
    }
}

private struct TerminalTreeBranch: View {
    let node: TerminalFileNode
    let depth: Int
    @Binding var expanded: Set<String>
    @ObservedObject var model: DeveloperTerminalModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                if node.isDirectory {
                    Button {
                        if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
                    } label: {
                        Image(systemName: expanded.contains(node.id) ? "chevron.down" : "chevron.right")
                            .limaFont(.system(size: 8, weight: .bold)).frame(width: 12)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 12, height: 1)
                }
                TerminalExplorerRow(node: node, model: model)
            }
            .padding(.leading, CGFloat(depth) * 13)
            if node.isDirectory, expanded.contains(node.id), let children = node.children {
                ForEach(children) { child in
                    TerminalTreeBranch(node: child, depth: depth + 1, expanded: $expanded, model: model)
                }
            }
        }
    }
}

private struct TerminalExplorerRow: View {
    let node: TerminalFileNode
    @ObservedObject var model: DeveloperTerminalModel

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc")
                .limaFont(.system(size: 10)).foregroundStyle(node.isDirectory ? SettingsStore.shared.accentTheme.primary : .secondary)
            Text(node.name).lineLimit(1)
            Spacer(minLength: 0)
            Menu {
                Button("Insert Path") { model.insertPath(node.url) }
                Button("Copy Path") { model.copyPath(node.url) }
                if node.isDirectory { Button("Prepare cd Command") { model.changeDirectory(to: node.url) } }
                if !node.isRemote {
                    Button("Open") { model.openPath(node.url) }
                    Button("Reveal in Finder") { model.revealPath(node.url) }
                }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { node.isDirectory ? model.changeDirectory(to: node.url) : model.insertPath(node.url) }
        .help(node.isDirectory ? "Double-click to prepare a cd command" : "Double-click to prepare a shell-escaped path")
    }
}

@MainActor
final class TerminalEditorOverlayController {
    enum Editor { case vim, nano }
    private let panel: NSPanel

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 880, height: 64), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.setAccessibilityLabel("Editor shortcut guide")
    }

    func show(editor: Editor) {
        panel.contentView = NSHostingView(rootView: LimaTypographyRoot(content: TerminalEditorOverlayView(editor: editor) { [weak self] in self?.panel.orderOut(nil) }))
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
        case .vim: return [("i", "Insert"), ("Esc", "Normal"), (":w", "Save"), (":q", "Quit"), (":wq", "Save + quit"), ("u", "Undo"), ("⌃R", "Redo"), ("dd", "Delete line"), ("yy / p", "Copy / paste"), ("/ / n", "Find / next")]
        case .nano: return [("⌃O ↩", "Save"), ("⌃X", "Exit"), ("⌃W", "Find"), ("⌃K", "Cut line"), ("⌃U", "Paste"), ("⌥U", "Undo"), ("⌥E", "Redo"), ("⌃_", "Go to line"), ("⌃C", "Position")]
        }
    }
    var body: some View {
        HStack(spacing: 11) {
            Text(editor == .vim ? "VIM" : "NANO").limaFont(.caption2.bold()).foregroundStyle(SettingsStore.shared.accentTheme.primary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 11) {
                    ForEach(Array(keys.enumerated()), id: \.offset) { _, item in HStack(spacing: 4) { Text(item.0).limaFont(.caption.monospaced().bold()); Text(item.1).limaFont(.caption2).foregroundStyle(.secondary) } }
                }
            }
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close editor shortcut guide")
        }
        .padding(.horizontal, 14).frame(width: 880, height: 64)
        .background(.ultraThinMaterial, in: PrismaticPanelShape(cut: 10)).overlay(PrismaticPanelShape(cut: 10).stroke(Color.white.opacity(0.2), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8).preferredColorScheme(.dark)
    }
}
