import Darwin
import Foundation

enum AIWorkspaceTerminalState: String, Equatable {
    case idle
    case running
    case completed
    case failed
    case cancelled
    case timedOut = "timed_out"
}

struct AIWorkspaceTerminalSnapshot: Identifiable, Equatable {
    let id: UUID
    let directory: String
    let isBoundedExternal: Bool
    let state: AIWorkspaceTerminalState
    let output: String
    let firstOutputByte: Int
    let nextOutputByte: Int
    let exitStatus: Int?
    let outputTruncated: Bool

    var title: String {
        let prefix = isBoundedExternal ? "AI · External · " : "AI · "
        return prefix + URL(fileURLWithPath: directory).lastPathComponent
    }
}

private final class AIWorkspaceProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var finished = false
    private var cancellationRequested = false
    private var timeoutRequested = false

    func install(_ process: Process) {
        lock.lock()
        self.process = process
        let stopNow = cancellationRequested || timeoutRequested
        lock.unlock()
        if stopNow { terminate(process) }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let current = process
        lock.unlock()
        if let current { terminate(current) }
    }

    func timeout() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        timeoutRequested = true
        let current = process
        lock.unlock()
        if let current { terminate(current) }
    }

    func finish() -> (cancelled: Bool, timedOut: Bool) {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        process = nil
        return (cancellationRequested, timeoutRequested)
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
            self?.forceKillIfRunning()
        }
    }

    private func forceKillIfRunning() {
        lock.lock()
        let current = process
        lock.unlock()
        if let current, current.isRunning {
            _ = kill(current.processIdentifier, SIGKILL)
        }
    }
}

private struct AIWorkspaceCommandResult: Sendable {
    let exitStatus: Int?
    let launchFailed: Bool
    let cancelled: Bool
    let timedOut: Bool
    let outputTruncated: Bool
}

/// Owns AI command sessions displayed by the Terminal workspace. The visible
/// shell remains user-owned; AI never injects text into it. AI processes run in
/// a default-deny macOS sandbox with writes and temporary files confined to
/// the dedicated workspace, no network grant, and no unrelated home reads.
@MainActor
final class AIWorkspaceTerminalCoordinator: ObservableObject {
    static let shared = AIWorkspaceTerminalCoordinator()
    static let maximumSessions = 8
    static let maximumConcurrentCommands = 4
    static let maximumOutputBytes = 256 * 1_024

    @Published private(set) var sessions: [AIWorkspaceTerminalSnapshot] = []

    // Tests supply an isolated, preexisting physical root. Production always
    // resolves the fixed Desktop workspace through workspaceRoot(create:).
    private let testRoot: URL?

    init(testRoot: URL? = nil) {
        self.testRoot = testRoot
    }

    private func sessionRoot(create: Bool) throws -> URL {
        guard let testRoot else { return try Self.workspaceRoot(create: create) }
        guard try Self.directoryExistsWithoutSymlink(testRoot),
              testRoot.resolvingSymlinksInPath().path == testRoot.path else {
            throw WorkspaceError.unavailable
        }
        return testRoot
    }

    private final class Session {
        let id: UUID
        let root: URL
        let isBoundedExternal: Bool
        var directory: URL
        var state: AIWorkspaceTerminalState = .idle
        var output = Data()
        var firstOutputByte = 0
        var nextOutputByte = 0
        var exitStatus: Int?
        var outputTruncated = false
        var box: AIWorkspaceProcessBox?
        var externalCancel: (() -> Void)?
        var taskID: UUID?
        var lastPublishedAt = 0.0

        init(root: URL, directory: URL, isBoundedExternal: Bool = false) {
            id = UUID()
            self.root = root
            self.directory = directory
            self.isBoundedExternal = isBoundedExternal
        }

        var snapshot: AIWorkspaceTerminalSnapshot {
            AIWorkspaceTerminalSnapshot(
                id: id,
                directory: directory.path,
                isBoundedExternal: isBoundedExternal,
                state: state,
                output: String(decoding: output, as: UTF8.self),
                firstOutputByte: firstOutputByte,
                nextOutputByte: nextOutputByte,
                exitStatus: exitStatus,
                outputTruncated: outputTruncated
            )
        }
    }

    private var sessionOrder: [UUID] = []
    private var sessionByID: [UUID: Session] = [:]

    enum WorkspaceError: LocalizedError {
        case unavailable
        case invalidDirectory
        case invalidWorkspaceName
        case workspaceExists
        case outsideWorkspace
        case symlink
        case tooManySessions
        case tooManyCommands
        case unknownSession
        case alreadyRunning
        case notRunning
        case notWorkspaceSession
        case invalidCommand

        var errorDescription: String? {
            switch self {
            case .unavailable: return "The AI Workspace folder or macOS sandbox is unavailable."
            case .invalidDirectory: return "Use an existing directory inside the AI Workspace."
            case .invalidWorkspaceName: return "Use a short, visible workspace name with letters, numbers, spaces, hyphens, or underscores."
            case .workspaceExists: return "That AI Workspace already exists; choose another name or start a session in it."
            case .outsideWorkspace: return "AI terminal sessions cannot leave the AI Workspace."
            case .symlink: return "AI terminal sessions do not follow symbolic links in workspace paths."
            case .tooManySessions: return "The AI Workspace session limit has been reached."
            case .tooManyCommands: return "Too many AI Workspace commands are running."
            case .unknownSession: return "That AI Workspace session does not exist."
            case .alreadyRunning: return "This session already has a running command."
            case .notRunning: return "This session has no running command to interrupt."
            case .notWorkspaceSession: return "This visible bounded command session is not an AI Workspace session."
            case .invalidCommand: return "Provide one bounded UTF-8 command without binary control characters."
            }
        }
    }

    /// The fixed default is created only after an approved terminal_start call.
    /// Refuse preexisting symlinks instead of following them into another tree.
    static func workspaceRoot(create: Bool) throws -> URL {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        let root = desktop.appendingPathComponent("Lima Workspace", isDirectory: true)
        guard try directoryExistsWithoutSymlink(desktop) else { throw WorkspaceError.unavailable }
        if !manager.fileExists(atPath: root.path) {
            guard create else { throw WorkspaceError.unavailable }
            try manager.createDirectory(at: root, withIntermediateDirectories: false)
        }
        guard try directoryExistsWithoutSymlink(root),
              root.resolvingSymlinksInPath().path == root.path else {
            throw WorkspaceError.symlink
        }
        return root
    }

    @discardableResult
    func start(directory relativeDirectory: String? = nil, newWorkspace: String? = nil) throws -> AIWorkspaceTerminalSnapshot {
        guard sessionOrder.count < Self.maximumSessions else { throw WorkspaceError.tooManySessions }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            throw WorkspaceError.unavailable
        }
        guard relativeDirectory == nil || newWorkspace == nil else { throw WorkspaceError.invalidDirectory }
        let root = try sessionRoot(create: true)
        let directory: URL
        if let newWorkspace {
            guard newWorkspace.utf8.count <= 64,
                  newWorkspace == newWorkspace.trimmingCharacters(in: .whitespaces),
                  newWorkspace.range(of: "^[A-Za-z0-9][A-Za-z0-9 _-]*$", options: .regularExpression) != nil else {
                throw WorkspaceError.invalidWorkspaceName
            }
            let created = root.appendingPathComponent(newWorkspace, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: created.path) else { throw WorkspaceError.workspaceExists }
            try FileManager.default.createDirectory(at: created, withIntermediateDirectories: false)
            directory = try Self.validDirectory(newWorkspace, root: root)
        } else {
            directory = try Self.validDirectory(relativeDirectory ?? ".", root: root)
        }
        let session = Session(root: root, directory: directory)
        sessionByID[session.id] = session
        sessionOrder.append(session.id)
        publish()
        return session.snapshot
    }

    /// The older, narrowly allowlisted command path remains available outside
    /// the sandboxed Workspace, but uses this same visible session/read model.
    /// Only AILocalCommandRunner may create or feed these one-shot sessions.
    func startBoundedExternal(directory: URL, onCancel: @escaping () -> Void) throws -> AIWorkspaceTerminalSnapshot {
        guard sessionOrder.count < Self.maximumSessions else { throw WorkspaceError.tooManySessions }
        guard sessionByID.values.filter({ $0.state == .running }).count < Self.maximumConcurrentCommands else {
            throw WorkspaceError.tooManyCommands
        }
        guard try Self.directoryExistsWithoutSymlink(directory) else { throw WorkspaceError.invalidDirectory }
        let session = Session(root: directory, directory: directory, isBoundedExternal: true)
        session.state = .running
        session.externalCancel = onCancel
        append(Data("\nLima AI · Approved bounded developer command\n".utf8), to: session)
        sessionByID[session.id] = session
        sessionOrder.append(session.id)
        publish()
        return session.snapshot
    }

    func appendBoundedExternal(_ chunk: Data, sessionID: UUID) {
        guard let session = sessionByID[sessionID], session.isBoundedExternal,
              session.state == .running else { return }
        append(chunk, to: session)
        let now = ProcessInfo.processInfo.systemUptime
        if now - session.lastPublishedAt >= 0.05 {
            session.lastPublishedAt = now
            publish(session)
        }
    }

    func finishBoundedExternal(sessionID: UUID, exitStatus: Int?, cancelled: Bool,
                               timedOut: Bool, outputTruncated: Bool) {
        guard let session = sessionByID[sessionID], session.isBoundedExternal,
              session.state == .running else { return }
        session.externalCancel = nil
        session.exitStatus = exitStatus
        session.outputTruncated = session.outputTruncated || outputTruncated
        let success = exitStatus == 0 && !cancelled && !timedOut
        session.state = cancelled ? .cancelled : timedOut ? .timedOut : success ? .completed : .failed
        append(Data(("\n[AI command " + (success ? "completed" : session.state.rawValue) + "]\n").utf8), to: session)
        publish(session)
    }

    func setDirectory(sessionID: UUID, relativeDirectory: String) throws -> AIWorkspaceTerminalSnapshot {
        let session = try find(sessionID)
        guard !session.isBoundedExternal else { throw WorkspaceError.notWorkspaceSession }
        guard session.state != .running else { throw WorkspaceError.alreadyRunning }
        session.directory = try Self.validDirectory(relativeDirectory, root: session.root)
        publish()
        return session.snapshot
    }

    func status(sessionID: UUID) throws -> AIWorkspaceTerminalSnapshot {
        try find(sessionID).snapshot
    }

    func close(sessionID: UUID) throws {
        let session = try find(sessionID)
        guard session.state != .running else { throw WorkspaceError.alreadyRunning }
        sessionByID.removeValue(forKey: sessionID)
        sessionOrder.removeAll { $0 == sessionID }
        publish()
    }

    func read(sessionID: UUID, from requestedByte: Int?) throws -> [String: Any] {
        let session = try find(sessionID)
        let start = min(max(requestedByte ?? session.firstOutputByte, session.firstOutputByte), session.nextOutputByte)
        let index = min(max(start - session.firstOutputByte, 0), session.output.count)
        let chunk = session.output.dropFirst(index).prefix(32 * 1_024)
        let next = min(session.nextOutputByte, start + chunk.count)
        return [
            "session_id": session.id.uuidString,
            "state": session.state.rawValue,
            "output": String(decoding: chunk, as: UTF8.self),
            "from_byte": start,
            "next_byte": next,
            "old_output_dropped": requestedByte.map { $0 < session.firstOutputByte } ?? false,
            "output_truncated": session.outputTruncated,
            "exit_status": session.exitStatus.map { $0 as Any } ?? NSNull()
        ]
    }

    @discardableResult
    func run(sessionID: UUID, command: String, timeoutSeconds: Int) throws -> AIWorkspaceTerminalSnapshot {
        let session = try find(sessionID)
        guard !session.isBoundedExternal else { throw WorkspaceError.notWorkspaceSession }
        guard session.state != .running else { throw WorkspaceError.alreadyRunning }
        guard sessionByID.values.filter({ $0.state == .running }).count < Self.maximumConcurrentCommands else {
            throw WorkspaceError.tooManyCommands
        }
        guard command.utf8.count > 0, command.utf8.count <= 4_096,
              !command.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) && ![9, 10, 13].contains(Int($0.value))
              }), (1...900).contains(timeoutSeconds) else {
            throw WorkspaceError.invalidCommand
        }
        // Revalidate the workspace root and path before every process launch.
        guard try sessionRoot(create: false).path == session.root.path else {
            throw WorkspaceError.unavailable
        }
        let relativeDirectory = session.directory.path == session.root.path
            ? "."
            : String(session.directory.path.dropFirst(session.root.path.count + 1))
        session.directory = try Self.validDirectory(relativeDirectory, root: session.root)
        let profile = Self.sandboxProfile(root: session.root)
        let box = AIWorkspaceProcessBox()
        session.box = box
        session.state = .running
        session.exitStatus = nil
        session.outputTruncated = session.firstOutputByte > 0
        append(Data(("\nLima AI · " + Self.safeCommandLabel(command) + "\n").utf8), to: session)
        let taskID = TaskRegistry.shared.begin(
            kind: .aiTool,
            title: "AI Workspace command",
            detail: session.directory.lastPathComponent,
            isCancellable: true,
            onCancel: { box.cancel() }
        )
        session.taskID = taskID
        publish()

        let directory = session.directory
        let root = session.root
        Task { [weak self] in
            let result = await Self.execute(
                command: command,
                profile: profile,
                root: root,
                directory: directory,
                timeoutSeconds: timeoutSeconds,
                box: box,
                onChunk: { [weak self] chunk in
                    DispatchQueue.main.sync {
                        MainActor.assumeIsolated {
                            self?.appendStreamChunk(chunk, sessionID: sessionID, box: box)
                        }
                    }
                }
            )
            self?.finish(sessionID: sessionID, box: box, result: result)
        }
        return session.snapshot
    }

    @discardableResult
    func interrupt(sessionID: UUID) throws -> AIWorkspaceTerminalSnapshot {
        let session = try find(sessionID)
        guard session.state == .running else { throw WorkspaceError.notRunning }
        if let box = session.box { box.cancel() }
        else if let externalCancel = session.externalCancel { externalCancel() }
        else { throw WorkspaceError.notRunning }
        return session.snapshot
    }

    private func appendStreamChunk(_ chunk: Data, sessionID: UUID, box: AIWorkspaceProcessBox) {
        guard let session = sessionByID[sessionID], session.state == .running, session.box === box else { return }
        append(chunk, to: session)
        let now = ProcessInfo.processInfo.systemUptime
        if now - session.lastPublishedAt >= 0.05 {
            session.lastPublishedAt = now
            publish(session)
        }
    }

    private func finish(sessionID: UUID, box: AIWorkspaceProcessBox, result: AIWorkspaceCommandResult) {
        guard let session = sessionByID[sessionID], session.box === box else { return }
        session.box = nil
        session.exitStatus = result.exitStatus
        session.outputTruncated = session.outputTruncated || result.outputTruncated
        let success = result.exitStatus == 0 && !result.launchFailed && !result.cancelled && !result.timedOut
        session.state = result.cancelled ? .cancelled : result.timedOut ? .timedOut : success ? .completed : .failed
        append(Data(("\n[AI command " + (success ? "completed" : session.state.rawValue) + "]\n").utf8), to: session)
        if let taskID = session.taskID {
            let taskState: LimaTaskState = result.cancelled ? .cancelled : success ? .completed : .failed
            TaskRegistry.shared.finish(taskID, state: taskState, detail: session.state.rawValue)
        }
        session.taskID = nil
        publish(session)
    }

    private func append(_ data: Data, to session: Session) {
        session.output.append(data)
        session.nextOutputByte += data.count
        if session.output.count > Self.maximumOutputBytes {
            let drop = session.output.count - Self.maximumOutputBytes
            session.output.removeFirst(drop)
            session.firstOutputByte += drop
            session.outputTruncated = true
        }
    }

    private func publish(_ changed: Session? = nil) {
        if let changed, let index = sessions.firstIndex(where: { $0.id == changed.id }) {
            sessions[index] = changed.snapshot
        } else {
            sessions = sessionOrder.compactMap { sessionByID[$0]?.snapshot }
        }
    }

    private func find(_ id: UUID) throws -> Session {
        guard let session = sessionByID[id] else { throw WorkspaceError.unknownSession }
        return session
    }

    private nonisolated static func directoryExistsWithoutSymlink(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    static func validDirectory(_ relative: String, root: URL) throws -> URL {
        guard !relative.isEmpty, relative.utf8.count <= 2_048,
              !relative.hasPrefix("/"), !relative.contains("\u{0}"),
              !relative.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WorkspaceError.invalidDirectory
        }
        let components = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard components.allSatisfy({ $0 != ".." && !$0.hasPrefix(".") || $0 == "." }) else {
            throw WorkspaceError.outsideWorkspace
        }
        var candidate = root
        for component in components where component != "." {
            candidate.appendPathComponent(String(component), isDirectory: true)
            guard try directoryExistsWithoutSymlink(candidate) else { throw WorkspaceError.symlink }
        }
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/"),
              candidate.resolvingSymlinksInPath().path == candidate.path else {
            throw WorkspaceError.outsideWorkspace
        }
        return candidate
    }

    static func sandboxProfile(root: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
        func quoted(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return """
        (version 1)
        (deny default)
        (allow process*)
        (allow file-read*)
        (deny file-read* (subpath \(quoted(home.path))))
        (allow file-read* (subpath \(quoted(root.path))))
        (allow file-write* (subpath \(quoted(root.path))))
        (allow file-read* file-write* (literal "/dev/null"))
        (allow sysctl*)
        """
    }

    private static func safeCommandLabel(_ command: String) -> String {
        let words = command.split(whereSeparator: \.isWhitespace)
        guard let first = words.first else { return "Approved command" }
        let program = URL(fileURLWithPath: String(first)).lastPathComponent
        let safeActions: [String: Set<String>] = [
            "swift": ["build", "test", "run"],
            "git": ["status", "diff", "log", "init"],
            "npm": ["install", "run", "test", "init"],
            "node": ["--version"],
            "python3": ["--version"]
        ]
        if words.count > 1, safeActions[program]?.contains(String(words[1])) == true {
            return "\(program) \(words[1])"
        }
        // Never echo arbitrary first tokens: environment assignments and
        // inline credentials can look like program names.
        return "Approved command"
    }

    private nonisolated static func execute(
        command: String,
        profile: String,
        root: URL,
        directory: URL,
        timeoutSeconds: Int,
        box: AIWorkspaceProcessBox,
        onChunk: @escaping @Sendable (Data) -> Void
    ) async -> AIWorkspaceCommandResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
                    process.arguments = ["-p", profile, "/bin/zsh", "-f", "-c", command]
                    process.currentDirectoryURL = directory
                    process.qualityOfService = .utility
                    let temporary = root.appendingPathComponent(".tmp", isDirectory: true)
                    let cache = root.appendingPathComponent(".cache", isDirectory: true)
                    let manager = FileManager.default
                    do {
                        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
                        try manager.createDirectory(at: cache, withIntermediateDirectories: true)
                        guard try directoryExistsWithoutSymlink(temporary),
                              try directoryExistsWithoutSymlink(cache) else {
                            throw WorkspaceError.symlink
                        }
                    } catch {
                        continuation.resume(returning: AIWorkspaceCommandResult(
                            exitStatus: nil, launchFailed: true, cancelled: false,
                            timedOut: false, outputTruncated: false
                        ))
                        return
                    }
                    process.environment = [
                        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin",
                        "HOME": root.path,
                        "TMPDIR": temporary.path + "/",
                        "XDG_CACHE_HOME": cache.path,
                        "npm_config_cache": cache.appendingPathComponent("npm").path,
                        "ZDOTDIR": root.path,
                        "LANG": "en_US.UTF-8",
                        "LC_ALL": "en_US.UTF-8",
                        "TERM": "dumb"
                    ]
                    process.standardInput = FileHandle.nullDevice
                    let output = Pipe()
                    process.standardOutput = output
                    process.standardError = output
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(returning: AIWorkspaceCommandResult(
                            exitStatus: nil, launchFailed: true, cancelled: false,
                            timedOut: false, outputTruncated: false
                        ))
                        return
                    }
                    box.install(process)
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(timeoutSeconds)) {
                        box.timeout()
                    }
                    let handle = output.fileHandleForReading
                    var total = 0
                    var truncated = false
                    while let chunk = try? handle.read(upToCount: 8_192), !chunk.isEmpty {
                        total += chunk.count
                        if total > 2 * 1_024 * 1_024 { truncated = true }
                        if !truncated { onChunk(chunk) }
                    }
                    process.waitUntilExit()
                    let state = box.finish()
                    continuation.resume(returning: AIWorkspaceCommandResult(
                        exitStatus: Int(process.terminationStatus),
                        launchFailed: false,
                        cancelled: state.cancelled,
                        timedOut: state.timedOut,
                        outputTruncated: truncated
                    ))
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}
