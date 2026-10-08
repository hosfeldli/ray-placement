import Darwin
import Foundation
import RayPlacementCore

/// Local actions intentionally stay narrow: regular UTF-8 text/source files
/// under the current user’s home directory, and one noninteractive developer
/// command at a time. The chat approval is checked again here so a direct call
/// cannot bypass the UI decision.
@MainActor
enum AILocalComputerActionTools {
    static let fileToolIDs: Set<String> = ["create_text_file", "replace_text_file"]
    static let terminalToolIDs: Set<String> = ["run_terminal_command"]
    static let ids = fileToolIDs.union(terminalToolIDs)

    static let definitions: [LimaAIToolDefinition] = [
        tool(
            "create_text_file",
            "Create one new UTF-8 text or source file in an existing non-sensitive directory under the current user’s home folder. Never overwrites, deletes, renames, creates directories, follows symlinks, or writes credentials.",
            [
                "path": ["type": "string", "description": "Absolute path for a new text or source file under the current user’s home folder."],
                "content": ["type": "string", "description": "Complete UTF-8 file content, limited to 96 KB."]
            ],
            risk: .write,
            actionCategory: .localFiles
        ),
        tool(
            "replace_text_file",
            "Atomically replace one existing bounded UTF-8 text or source file after the user approves. Never creates directories, follows symlinks, changes permissions, deletes, renames, or writes hidden or sensitive paths. expected_modified_at must exactly match the value from file_metadata so Lima never replaces a file that changed after inspection.",
            [
                "path": ["type": "string", "description": "Absolute path for an existing text or source file under the current user’s home folder."],
                "content": ["type": "string", "description": "Complete replacement UTF-8 content, limited to 96 KB."],
                "expected_modified_at": ["type": "string", "description": "The exact modified_at value returned by file_metadata immediately before this replacement."]
            ],
            risk: .write,
            actionCategory: .localFiles
        ),
        tool(
            "run_terminal_command",
            "Run one bounded, approved local developer command without a shell. Supports Swift build/test/run, Xcode build/test, read-only Git, or an existing local Python or Node script. Set working_directory to the project for builds and tests; omit it only to use your home folder. Timeout defaults to 180 seconds (maximum 300); output is limited and every run requires user approval.",
            [
                "command": ["type": "string", "description": "One supported local developer command of at most 4096 characters, such as swift test or python3 script.py. Lima does not interpret shell syntax."],
                "working_directory": ["type": "string", "description": "Absolute existing non-sensitive project directory under your home folder; omit only to run in your home folder."],
                "timeout_seconds": ["type": "integer", "minimum": 1, "maximum": 300, "description": "Optional maximum execution time from 1 to 300 seconds; defaults to 180."]
            ],
            risk: .localAction,
            actionCategory: .terminal,
            required: ["command"]
        )
    ]

    private static func tool(
        _ id: String,
        _ description: String,
        _ properties: [String: Any],
        risk: AILocalToolRisk,
        actionCategory: AIComputerActionCategory,
        required: [String]? = nil
    ) -> LimaAIToolDefinition {
        LimaAIToolDefinition(
            id: id,
            name: id,
            description: description,
            parameters: [
                "type": "object",
                "properties": properties,
                "required": required ?? properties.keys.sorted(),
                "additionalProperties": false
            ],
            risk: risk,
            actionCategory: actionCategory
        )
    }

    static func execute(_ call: AIOutputItem, approvalGranted: Bool) async -> LimaAIToolExecution {
        guard let definition = definitions.first(where: { $0.name == call.name }),
              AIComputerActionPolicy.shared.permits(definition, approvalGranted: approvalGranted) else {
            return .json(["error": "This local computer action is disabled or still needs your approval in Lima Settings."], isError: true)
        }

        do {
            let arguments = try decodedArguments(for: call)
            switch definition.id {
            case "create_text_file":
                guard case .string(let path)? = arguments["path"],
                      case .string(let content)? = arguments["content"] else {
                    return .json(["error": "Create File needs a path and UTF-8 content."], isError: true)
                }
                let url = try writableTextURL(path: path, mustExist: false)
                let data = try safeTextData(content)
                guard !FileManager.default.fileExists(atPath: url.path) else {
                    return .json(["error": "That file already exists. Use Replace File after inspecting it."], isError: true)
                }
                try writeTextData(data, to: url, operation: "Created", options: .withoutOverwriting)
                return .json(["created": true, "path": url.path, "bytes_written": data.count])

            case "replace_text_file":
                guard case .string(let path)? = arguments["path"],
                      case .string(let content)? = arguments["content"] else {
                    return .json(["error": "Replace File needs a path and UTF-8 content."], isError: true)
                }
                guard case .string(let expected)? = arguments["expected_modified_at"], !expected.isEmpty else {
                    return .json(["error": "Replace File requires the exact modified_at timestamp returned by file_metadata."], isError: true)
                }
                let url = try writableTextURL(path: path, mustExist: true)
                try verifyExpectedModification(expected, at: url)
                let data = try safeTextData(content)
                try writeTextData(data, to: url, operation: "Replaced", options: .atomic)
                return .json(["replaced": true, "path": url.path, "bytes_written": data.count])

            case "run_terminal_command":
                guard case .string(let command)? = arguments["command"] else {
                    return .json(["error": "Run Terminal Command needs one supported command."], isError: true)
                }
                let directory: String
                switch arguments["working_directory"] {
                case .some(.string(let value)):
                    directory = value
                case .none, .some(.null):
                    directory = FileManager.default.homeDirectoryForCurrentUser.path
                default:
                    return .json(["error": "working_directory must be an absolute non-sensitive directory under your home folder."], isError: true)
                }
                let timeout: Int
                switch arguments["timeout_seconds"] {
                case .some(.number(let value)) where value.isFinite && value.rounded() == value && (1...300).contains(value):
                    timeout = Int(value)
                case .none, .some(.null):
                    timeout = 180
                default:
                    return .json(["error": "timeout_seconds must be an integer from 1 to 300."], isError: true)
                }
                let workingDirectory = try safeWorkingDirectory(directory)
                return await AILocalCommandRunner.shared.run(
                    command: command,
                    workingDirectory: workingDirectory,
                    timeoutSeconds: timeout
                )

            default:
                return .json(["error": "The requested local action is unavailable."], isError: true)
            }
        } catch {
            return .json(["error": error.localizedDescription], isError: true)
        }
    }

    private enum LocalActionError: LocalizedError {
        case invalidPath
        case outsideHome
        case sensitivePath
        case symlink
        case missingParent
        case unsupportedFile
        case notRegularFile
        case changedSinceInspection
        case oversizedContent
        case unsafeText
        case unsafeCommand

        var errorDescription: String? {
            switch self {
            case .invalidPath: return "Use an absolute file or directory path."
            case .outsideHome: return "Lima local actions are limited to the current user’s home folder."
            case .sensitivePath: return "Lima does not use hidden, Library, credential, secret, system, or protected Lima locations."
            case .symlink: return "Lima local actions do not follow symbolic links."
            case .missingParent: return "The target directory must already exist."
            case .unsupportedFile: return "Lima local actions support text and source-code files only."
            case .notRegularFile: return "The target must be a regular file."
            case .changedSinceInspection: return "That file changed after it was inspected. Read its metadata again before replacing it."
            case .oversizedContent: return "Local file content is limited to 96 KB."
            case .unsafeText: return "Lima local actions require safe UTF-8 text without binary control characters."
            case .unsafeCommand: return "That command exceeds Lima’s local developer-command limits. Use the dedicated file tools for edits and a simple build, test, lint, or existing-script command."
            }
        }
    }

    private static func decodedArguments(for call: AIOutputItem) throws -> [String: JSONValue] {
        guard let raw = call.arguments, raw.utf8.count <= 128_000,
              let data = raw.data(using: .utf8),
              let arguments = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            throw LocalActionError.invalidPath
        }
        return arguments
    }

    private static func writableTextURL(path: String, mustExist: Bool) throws -> URL {
        guard path.hasPrefix("/"), path.utf8.count <= 4_096,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw LocalActionError.invalidPath
        }
        let requested = URL(fileURLWithPath: path).standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
        guard requested.path.hasPrefix(home.path + "/") else { throw LocalActionError.outsideHome }
        guard !isRestrictedUserLocation(requested, home: home) else { throw LocalActionError.sensitivePath }
        try rejectSymlinks(from: requested, through: home)

        let parent = requested.deletingLastPathComponent()
        let parentValues = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parentValues.isDirectory == true else { throw LocalActionError.missingParent }
        guard parentValues.isSymbolicLink != true else { throw LocalActionError.symlink }

        let resolvedParent = parent.resolvingSymlinksInPath()
        let target = resolvedParent.appendingPathComponent(requested.lastPathComponent).standardizedFileURL
        guard target.path.hasPrefix(home.path + "/") else { throw LocalActionError.outsideHome }
        guard !isRestrictedUserLocation(target, home: home),
              !LimaAIToolRegistry.isSensitivePath(target), !isSensitiveFilename(target.lastPathComponent) else {
            throw LocalActionError.sensitivePath
        }
        guard LimaAIToolRegistry.isTextFile(url: target, contentType: nil) else {
            throw LocalActionError.unsupportedFile
        }

        let exists = FileManager.default.fileExists(atPath: target.path)
        guard exists == mustExist else {
            throw mustExist ? LocalActionError.notRegularFile : LocalActionError.invalidPath
        }
        if mustExist {
            let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentTypeKey])
            guard values.isSymbolicLink != true else { throw LocalActionError.symlink }
            guard values.isRegularFile == true else { throw LocalActionError.notRegularFile }
            guard (values.fileSize ?? 0) <= 96 * 1_024,
                  LimaAIToolRegistry.isTextFile(url: target, contentType: values.contentType) else {
                throw LocalActionError.unsupportedFile
            }
        }
        return target
    }

    private static func safeWorkingDirectory(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), path.utf8.count <= 4_096,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw LocalActionError.invalidPath
        }
        let requested = URL(fileURLWithPath: path).standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
        guard requested.path == home.path || requested.path.hasPrefix(home.path + "/"),
              !isRestrictedUserLocation(requested, home: home) else {
            throw LocalActionError.outsideHome
        }
        try rejectSymlinks(from: requested, through: home)
        let resolved = requested.resolvingSymlinksInPath()
        guard resolved.path == home.path || resolved.path.hasPrefix(home.path + "/"),
              !isRestrictedUserLocation(resolved, home: home),
              !LimaAIToolRegistry.isSensitivePath(resolved),
              (try resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw LocalActionError.sensitivePath
        }
        return resolved
    }

    private static func rejectSymlinks(from url: URL, through home: URL) throws {
        var cursor = url
        while true {
            if FileManager.default.fileExists(atPath: cursor.path),
               (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw LocalActionError.symlink
            }
            if cursor.path == home.path { return }
            let parent = cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else { throw LocalActionError.outsideHome }
            cursor = parent
        }
    }

    private static func isRestrictedUserLocation(_ url: URL, home: URL) -> Bool {
        let relativeComponents = url.pathComponents.dropFirst(home.pathComponents.count)
        return relativeComponents.contains { component in
            component.hasPrefix(".") || component.caseInsensitiveCompare("Library") == .orderedSame
        }
    }

    private static func isSensitiveFilename(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower == ".env"
            || lower.hasPrefix(".env.")
            || [".netrc", ".npmrc", ".pypirc", ".git-credentials", "credentials", "token", "secret"].contains(lower)
    }

    private static func safeTextData(_ content: String) throws -> Data {
        let data = Data(content.utf8)
        guard data.count <= 96 * 1_024 else { throw LocalActionError.oversizedContent }
        guard !data.contains(0),
              !content.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) && ![9, 10, 13].contains(Int($0.value))
              }) else {
            throw LocalActionError.unsafeText
        }
        return data
    }

    private static func writeTextData(
        _ data: Data,
        to url: URL,
        operation: String,
        options: Data.WritingOptions
    ) throws {
        let detail = "\(operation) · \(url.lastPathComponent)"
        let taskID = TaskRegistry.shared.begin(kind: .aiTool, title: "AI file action", detail: detail)
        do {
            try data.write(to: url, options: options)
            TaskRegistry.shared.finish(taskID, detail: detail)
        } catch {
            TaskRegistry.shared.finish(taskID, state: .failed, detail: "Failed · \(url.lastPathComponent)")
            throw error
        }
    }

    private static func verifyExpectedModification(_ expected: String, at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let actual = values.contentModificationDate.map { formatter.string(from: $0) }
        guard actual == expected else { throw LocalActionError.changedSinceInspection }
    }
}

@MainActor
final class AILocalCommandRunner {
    static let shared = AILocalCommandRunner()

    private var isRunning = false

    private struct CommandSpec: Sendable {
        let executable: URL
        let arguments: [String]
        let journalLabel: String
    }

    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var finished = false
        private var timedOut = false
        private var cancelled = false

        func install(_ process: Process) {
            lock.lock()
            self.process = process
            let shouldStop = cancelled || timedOut
            lock.unlock()
            if shouldStop { stop(process) }
        }

        func markFinished() {
            lock.lock()
            finished = true
            process = nil
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let process = self.process
            lock.unlock()
            stop(process)
        }

        func timeout() {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            timedOut = true
            let process = self.process
            lock.unlock()
            stop(process)
        }

        private func stop(_ process: Process?) {
            guard let process, process.isRunning else { return }
            process.terminate()
            // A script can ignore SIGTERM. Escalate after a short grace period
            // so a cancelled or timed-out direct process cannot run forever.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
                self?.forceKillIfRunning()
            }
        }

        private func forceKillIfRunning() {
            lock.lock()
            let process = self.process
            lock.unlock()
            if let process, process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }

        func state() -> (cancelled: Bool, timedOut: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (cancelled, timedOut)
        }
    }

    private struct CommandResult: Sendable {
        let output: String
        let exitStatus: Int32?
        let truncated: Bool
        let cancelled: Bool
        let timedOut: Bool
        let launchFailed: Bool
    }

    func run(command rawCommand: String, workingDirectory: URL, timeoutSeconds: Int) async -> LimaAIToolExecution {
        guard !isRunning else {
            return .json(["error": "Lima runs one approved local developer command at a time."], isError: true)
        }
        guard let specification = Self.commandSpec(for: rawCommand, workingDirectory: workingDirectory) else {
            return .json(["error": "That command exceeds Lima’s local developer-command limits."], isError: true)
        }

        isRunning = true
        defer { isRunning = false }
        let label = specification.journalLabel
        let box = ProcessBox()
        let taskID = TaskRegistry.shared.begin(
            kind: .aiTool,
            title: "AI terminal command",
            detail: "Local developer command · \(label)",
            isCancellable: true,
            onCancel: { box.cancel() }
        )
        let measurementID = PerformanceMonitor.shared.begin("AI terminal command", detail: label)
        let result = await Self.execute(
            specification: specification,
            workingDirectory: workingDirectory,
            timeoutSeconds: timeoutSeconds,
            box: box
        )

        let success = !result.cancelled && !result.timedOut && !result.launchFailed && result.exitStatus == 0
        let taskState: LimaTaskState = result.cancelled ? .cancelled : (success ? .completed : .failed)
        let taskDetail = result.cancelled ? "Stopped by user" : (result.timedOut ? "Timed out" : (success ? "Completed" : "Failed"))
        TaskRegistry.shared.finish(taskID, state: taskState, detail: taskDetail)
        PerformanceMonitor.shared.end(measurementID, succeeded: success)

        let output = result.output.isEmpty ? "(No output)" : result.output
        return .json([
            "command": label,
            "working_directory": workingDirectory.path,
            "exit_status": result.exitStatus.map { Int($0) as Any } ?? NSNull(),
            "succeeded": success,
            "timed_out": result.timedOut,
            "cancelled": result.cancelled,
            "output": output,
            "output_truncated": result.truncated
        ], isError: !success)
    }

    private nonisolated static func execute(
        specification: CommandSpec,
        workingDirectory: URL,
        timeoutSeconds: Int,
        box: ProcessBox
    ) async -> CommandResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let process = Process()
                    process.executableURL = specification.executable
                    process.arguments = specification.arguments
                    process.currentDirectoryURL = workingDirectory
                    process.terminationHandler = { _ in box.markFinished() }
                    process.qualityOfService = .utility
                    process.environment = [
                        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin",
                        "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                        "LANG": "en_US.UTF-8",
                        "LC_ALL": "en_US.UTF-8",
                        "TMPDIR": NSTemporaryDirectory()
                    ]
                    process.standardInput = FileHandle.nullDevice
                    let output = Pipe()
                    process.standardOutput = output
                    process.standardError = output

                    do {
                        try process.run()
                    } catch {
                        box.markFinished()
                        continuation.resume(returning: CommandResult(
                            output: "Lima could not start the local command.",
                            exitStatus: nil,
                            truncated: false,
                            cancelled: false,
                            timedOut: false,
                            launchFailed: true
                        ))
                        return
                    }

                    box.install(process)
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(timeoutSeconds)) {
                        box.timeout()
                    }

                    let handle = output.fileHandleForReading
                    var captured = Data()
                    var truncated = false
                    while let chunk = try? handle.read(upToCount: 8_192), !chunk.isEmpty {
                        let remaining = 64 * 1_024 - captured.count
                        if remaining > 0 {
                            captured.append(chunk.prefix(remaining))
                        }
                        if chunk.count > remaining { truncated = true }
                    }
                    process.waitUntilExit()
                    let state = box.state()
                    box.markFinished()
                    let text = Self.sanitizedOutput(String(decoding: captured, as: UTF8.self))
                    continuation.resume(returning: CommandResult(
                        output: text,
                        exitStatus: process.terminationStatus,
                        truncated: truncated,
                        cancelled: state.cancelled,
                        timedOut: state.timedOut,
                        launchFailed: false
                    ))
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    nonisolated static func acceptsCommand(_ rawCommand: String, workingDirectory: URL) -> Bool {
        commandSpec(for: rawCommand, workingDirectory: workingDirectory) != nil
    }

    private nonisolated static func commandSpec(for rawCommand: String, workingDirectory: URL) -> CommandSpec? {
        guard let parts = tokenizedCommand(rawCommand), let program = parts.first else { return nil }
        let arguments = Array(parts.dropFirst())
        // Commands run as the current user, not in a filesystem sandbox. Keep
        // command-line path operands inside the approved working tree; project
        // build scripts still need their own user review in the approval UI.
        guard arguments.allSatisfy({ safeOperand($0) }) else { return nil }
        let executable: URL
        let journalLabel: String
        switch program {
        case "swift":
            guard let action = arguments.first, ["build", "test", "run"].contains(action),
                  !arguments.contains(where: { $0.hasPrefix("--package-path") || $0.hasPrefix("--scratch-path") || $0.hasPrefix("--build-path") || $0.hasPrefix("--cache-path") }) else { return nil }
            executable = URL(fileURLWithPath: "/usr/bin/swift")
            journalLabel = "swift \(action)"
        case "xcodebuild":
            guard arguments.contains("build") || arguments.contains("test"),
                  !arguments.contains(where: { ["clean", "archive", "-exportArchive", "-exportPath", "-archivePath", "-derivedDataPath", "-resultBundlePath", "-clonedSourcePackagesDirPath", "-project", "-workspace"].contains($0) }) else { return nil }
            executable = URL(fileURLWithPath: "/usr/bin/xcodebuild")
            journalLabel = arguments.contains("test") ? "xcodebuild test" : "xcodebuild build"
        case "git":
            guard let action = arguments.first,
                  ["branch", "describe", "diff", "grep", "log", "ls-files", "rev-parse", "show", "status"].contains(action),
                  safeGitArguments(arguments) else { return nil }
            executable = URL(fileURLWithPath: "/usr/bin/git")
            journalLabel = "git \(action)"
        case "python3":
            guard let script = arguments.first,
                  approvedScript(script, workingDirectory: workingDirectory, extensions: ["py"]) else { return nil }
            guard let resolved = executableURL(named: "python3") else { return nil }
            executable = resolved
            journalLabel = "python3 \(URL(fileURLWithPath: script).lastPathComponent)"
        case "node":
            guard let script = arguments.first,
                  approvedScript(script, workingDirectory: workingDirectory, extensions: ["cjs", "js", "mjs"]) else { return nil }
            guard let resolved = executableURL(named: "node") else { return nil }
            executable = resolved
            journalLabel = "node \(URL(fileURLWithPath: script).lastPathComponent)"
        default:
            return nil
        }
        return CommandSpec(executable: executable, arguments: arguments, journalLabel: journalLabel)
    }

    private nonisolated static func safeOperand(_ value: String) -> Bool {
        guard !value.hasPrefix("/"), !value.contains("=/"), !value.contains("../"),
              !value.contains("..\\"), !value.contains("~"), !value.contains("\\n") else { return false }
        return !value.split(separator: "/").contains(where: { $0 == ".." || $0.hasPrefix(".") && $0 != "." })
    }

    private nonisolated static func safeGitArguments(_ arguments: [String]) -> Bool {
        guard let action = arguments.first else { return false }
        let operands = Array(arguments.dropFirst())
        if action == "branch" {
            return operands.isEmpty || ["--list", "--show-current", "-a", "-r", "-v", "-vv"].contains(operands.joined(separator: " "))
        }
        return !operands.contains(where: { operand in
            operand.contains(":") || operand == "--no-index" || operand == "--ext-diff"
                || operand == "--open-files-in-pager" || operand.hasPrefix("--output")
                || operand.hasPrefix("--git-dir") || operand.hasPrefix("--work-tree")
                || operand == "-C" || operand == "--config-env"
        })
    }

    private nonisolated static func tokenizedCommand(_ raw: String) -> [String]? {
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, command.utf8.count <= 4_096 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._/-=:+,@%\"' \t"))
        guard command.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }

        var parts: [String] = []
        var current = ""
        var quote: Character?
        func appendCurrent() {
            if !current.isEmpty { parts.append(current); current = "" }
        }
        for character in command {
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
                else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                appendCurrent()
            } else {
                current.append(character)
            }
        }
        guard quote == nil else { return nil }
        appendCurrent()
        return parts.isEmpty ? nil : parts
    }


    private nonisolated static func executableURL(named name: String) -> URL? {
        let candidates: [String]
        switch name {
        case "python3": candidates = ["/usr/bin/python3"]
        case "node": candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        default: return nil
        }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    nonisolated static func approvedScript(
        _ path: String,
        workingDirectory: URL,
        extensions: Set<String>
    ) -> Bool {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return false }
        let directory = workingDirectory.standardizedFileURL
        let candidate = directory.appendingPathComponent(path).standardizedFileURL
        guard candidate.path.hasPrefix(directory.path + "/"),
              candidate.resolvingSymlinksInPath().path.hasPrefix(directory.path + "/"),
              extensions.contains(candidate.pathExtension.lowercased()),
              !candidate.pathComponents.dropFirst(directory.pathComponents.count).contains(where: { $0.hasPrefix(".") }),
              !hasSymlinkComponent(candidate, through: directory),
              let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= 96 * 1_024 else { return false }
        return true
    }

    private nonisolated static func hasSymlinkComponent(_ path: URL, through root: URL) -> Bool {
        var cursor = path
        while cursor.path != root.path {
            if (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return true }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { return true }
            cursor = parent
        }
        return false
    }

    private nonisolated static func sanitizedOutput(_ value: String) -> String {
        String(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || [9, 10, 13].contains(Int($0.value))
        }).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
