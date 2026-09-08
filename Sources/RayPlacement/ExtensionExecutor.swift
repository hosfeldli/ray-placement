import AppKit
import Foundation
import RayPlacementCore
import RayPlacementWriting

@MainActor
final class ExtensionExecutor {
    struct FormResult {
        let headline: String
        let detail: String
        let output: String
        let succeeded: Bool
    }

    enum ExecutionResult {
        case completed(String?)
        case native(ExtensionAction)
        case nativeChain([ExtensionAction])
    }
    private var activeProcesses: [UUID: Process] = [:]
    private var cancelledProcesses = Set<UUID>()
    private var timedOutProcesses = Set<UUID>()
    private var timeoutWorkItems: [UUID: DispatchWorkItem] = [:]
    private var usageTasks: [UUID: UUID] = [:]

    func cancelAll() {
        for (identifier, process) in activeProcesses {
            cancelledProcesses.insert(identifier)
            timeoutWorkItems.removeValue(forKey: identifier)?.cancel()
            if process.isRunning { process.terminate() }
            if let usage = usageTasks.removeValue(forKey: identifier) {
                UsageMonitor.shared.finish(usage, succeeded: false, detail: "Cancelled by user")
            }
        }
    }

    /// Async bridge used by workflows. The callback API remains the launcher
    /// surface, while this bridge does not advance until the underlying action
    /// has actually completed.
    func executeAsync(
        _ loaded: LoadedExtensionCommand,
        clipboard: ClipboardHistoryService
    ) async throws -> ExecutionResult {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                execute(loaded, clipboard: clipboard, reportCancellation: true) { result in
                    continuation.resume(with: result)
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in self?.cancelAll() }
        })
    }

    func execute(
        _ loaded: LoadedExtensionCommand,
        clipboard: ClipboardHistoryService,
        reportCancellation: Bool = false,
        completion: @escaping (Result<ExecutionResult, Error>) -> Void
    ) {
        let action = loaded.command.action
        if let chain = action.chain, !chain.isEmpty {
            do {
                try ExtensionAction.validateNativeChain(chain)
            } catch {
                completion(.failure(ExecutionError.invalidAction("Action chains may contain at most eight approved native actions.")))
                return
            }
            completion(.success(.nativeChain(chain)))
            return
        }
        switch action.type {
        case .url:
            guard let url = URL(string: action.value) else {
                completion(.failure(ExecutionError.invalidURL(action.value)))
                return
            }
            if NSWorkspace.shared.open(url) {
                completion(.success(.completed(nil)))
            } else {
                completion(.failure(ExecutionError.cannotOpen(url.absoluteString)))
            }

        case .file:
            let url: URL
            do {
                url = try ExtensionSecurityPolicy.resolvePath(action.value, relativeTo: loaded.directory, capabilities: loaded.capabilities, executable: false)
            } catch {
                completion(.failure(ExecutionError.securityViolation(error.localizedDescription)))
                return
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                completion(.failure(ExecutionError.missingFile(url.path)))
                return
            }
            if NSWorkspace.shared.open(url) {
                completion(.success(.completed(nil)))
            } else {
                completion(.failure(ExecutionError.cannotOpen(url.path)))
            }

        case .application:
            // A path-based application action is retained for user extensions;
            // operation-based actions are public native host requests.
            if let operation = action.operation, !operation.isEmpty {
                completion(.success(.native(action)))
                return
            }
            let url: URL
            do {
                url = try ExtensionSecurityPolicy.resolvePath(action.value, relativeTo: loaded.directory, capabilities: loaded.capabilities, executable: false)
            } catch {
                completion(.failure(ExecutionError.securityViolation(error.localizedDescription)))
                return
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                completion(.failure(ExecutionError.missingFile(url.path)))
                return
            }
            if NSWorkspace.shared.open(url) {
                completion(.success(.completed(nil)))
            } else {
                completion(.failure(ExecutionError.cannotOpen(url.path)))
            }

        case .clipboard:
            switch action.operation ?? "copy" {
            case "copy":
                clipboard.copy(action.value)
                completion(.success(.completed(nil)))
            case "paste":
                clipboard.copy(action.value)
                completion(.success(.native(action)))
            case "pastePlainText":
                do {
                    let text = try PlainTextPasteboardService.rewriteAsPlainText()
                    clipboard.copy(text)
                    completion(.success(.native(ExtensionAction(type: .clipboard, value: text, operation: "paste"))))
                } catch {
                    completion(.failure(error))
                }
            default:
                completion(.failure(ExecutionError.invalidAction("Unknown clipboard operation.")))
            }

        case .form, .picker, .system, .window, .workspace:
            completion(.success(.native(action)))

        case .shell:
            run(action, relativeTo: loaded.directory, capabilities: loaded.capabilities, reportCancellation: reportCancellation, completion: completion)
        }
    }

    func executeForm(
        _ loaded: LoadedExtensionCommand,
        values: [String: String],
        completion: @escaping (Result<FormResult, Error>) -> Void
    ) {
        guard let definition = loaded.command.action.form else {
            completion(.failure(ExecutionError.invalidForm("The form definition is missing.")))
            return
        }
        for field in definition.fields where field.required == true && isVisible(field, values: values) {
            if values[field.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                completion(.failure(ExecutionError.invalidForm("\(field.label) is required.")))
                return
            }
        }
        switch definition.execution.type {
        case .shell:
            guard let executable = definition.execution.executable, !executable.isEmpty else {
                completion(.failure(ExecutionError.invalidForm("The executable is missing.")))
                return
            }
            let action = ExtensionAction(
                type: .shell,
                value: ExtensionTemplate.render(executable, values: values),
                arguments: definition.execution.arguments?.map { ExtensionTemplate.render($0, values: values) },
                workingDirectory: definition.execution.workingDirectory.map { ExtensionTemplate.render($0, values: values) }
            )
            run(action, relativeTo: loaded.directory, capabilities: loaded.capabilities, reportCancellation: false) { result in
                switch result {
                case .success(let executionResult):
                    guard case .completed(let output) = executionResult else {
                        completion(.failure(ExecutionError.invalidAction("Form execution returned a native action instead of command output.")))
                        return
                    }
                    completion(.success(FormResult(
                        headline: "Command completed",
                        detail: "Exit status 0",
                        output: output ?? "No output",
                        succeeded: true
                    )))
                case .failure(let error): completion(.failure(error))
                }
            }
        }
    }

    private func isVisible(_ field: ExtensionFormField, values: [String: String]) -> Bool {
        guard let condition = field.visibleWhen else { return true }
        let value = values[condition.field, default: ""]
        if let equals = condition.equals, value != equals { return false }
        if let notEquals = condition.notEquals, value == notEquals { return false }
        return true
    }

    private func run(
        _ action: ExtensionAction,
        relativeTo directory: URL,
        capabilities: Set<ExtensionManifest.Capability>,
        reportCancellation: Bool = false,
        completion: @escaping (Result<ExecutionResult, Error>) -> Void
    ) {
        let executable: URL
        do {
            executable = try ExtensionSecurityPolicy.resolvePath(action.value, relativeTo: directory, capabilities: capabilities, executable: true)
        } catch {
            completion(.failure(ExecutionError.securityViolation(error.localizedDescription)))
            return
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            completion(.failure(ExecutionError.notExecutable(executable.path)))
            return
        }

        let task = Process()
        let performance = SettingsStore.shared.runtimeExtensionPerformance
        task.executableURL = executable
        task.arguments = action.arguments ?? []
        task.qualityOfService = performance.qualityOfService
        task.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LANG": "en_US.UTF-8",
            "OMP_NUM_THREADS": String(performance.threadLimit),
            "OMP_THREAD_LIMIT": String(performance.threadLimit),
            "MKL_NUM_THREADS": String(performance.threadLimit),
            "VECLIB_MAXIMUM_THREADS": String(performance.threadLimit),
            "TOKENIZERS_PARALLELISM": "false",
            "LIMA_PERFORMANCE_SCALE": performance.rawValue,
            "LIMA_THREAD_LIMIT": String(performance.threadLimit),
            "LIMA_TIMEOUT_SECONDS": String(Int(performance.extensionTimeout)),
            // Compatibility for extensions installed before the Lima rename.
            "RAYPLACEMENT_PERFORMANCE_SCALE": performance.rawValue,
            "RAYPLACEMENT_THREAD_LIMIT": String(performance.threadLimit),
            "RAYPLACEMENT_TIMEOUT_SECONDS": String(Int(performance.extensionTimeout))
        ]
        if let workingDirectory = action.workingDirectory {
            do {
                task.currentDirectoryURL = try ExtensionSecurityPolicy.resolvePath(workingDirectory, relativeTo: directory, capabilities: capabilities, executable: false)
            } catch {
                completion(.failure(ExecutionError.securityViolation(error.localizedDescription)))
                return
            }
        } else {
            task.currentDirectoryURL = directory
        }
        // Merge the streams and continuously drain them so a chatty extension cannot
        // deadlock on a full stderr or stdout pipe.
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output

        let identifier = UUID()
        do {
            try task.run()
            activeProcesses[identifier] = task
            usageTasks[identifier] = UsageMonitor.shared.begin(
                category: .extensionCommand,
                operation: executable.lastPathComponent,
                performance: performance
            )
        } catch {
            completion(.failure(error))
            return
        }

        if performance.extensionTimeout > 0 {
            let timeout = DispatchWorkItem { [weak self] in
                DispatchQueue.main.async {
                    guard let self,
                          let running = self.activeProcesses[identifier],
                          running.isRunning else { return }
                    self.timedOutProcesses.insert(identifier)
                    running.terminate()
                }
            }
            timeoutWorkItems[identifier] = timeout
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + performance.extensionTimeout,
                execute: timeout
            )
        }

        let executionQueue = DispatchQueue.global(qos: performance.dispatchQoS)
        executionQueue.async {
            do {
                let handle = output.fileHandleForReading
                let limit = 1_000_000
                var captured = Data()
                var truncated = false
                while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
                    let remaining = limit - captured.count
                    if remaining > 0 {
                        captured.append(chunk.prefix(remaining))
                    }
                    if chunk.count > remaining { truncated = true }
                }
                task.waitUntilExit()
                var outputText = String(decoding: captured, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if truncated { outputText += "\n\n[Output truncated after 1 MB]" }
                DispatchQueue.main.async {
                    self.activeProcesses.removeValue(forKey: identifier)
                    self.timeoutWorkItems.removeValue(forKey: identifier)?.cancel()
                    if self.cancelledProcesses.remove(identifier) != nil {
                        self.timedOutProcesses.remove(identifier)
                        if reportCancellation { completion(.failure(ExecutionError.cancelled)) }
                        return
                    }
                    if self.timedOutProcesses.remove(identifier) != nil {
                        if let usage = self.usageTasks.removeValue(forKey: identifier) {
                            UsageMonitor.shared.finish(usage, succeeded: false, outputCharacters: outputText.count, detail: "Timed out")
                        }
                        completion(.failure(ExecutionError.timedOut(Int(performance.extensionTimeout))))
                    } else if task.terminationStatus == 0 {
                        if let usage = self.usageTasks.removeValue(forKey: identifier) {
                            UsageMonitor.shared.finish(usage, succeeded: true, outputCharacters: outputText.count)
                        }
                        completion(.success(.completed(outputText.isEmpty ? nil : outputText)))
                    } else {
                        if let usage = self.usageTasks.removeValue(forKey: identifier) {
                            UsageMonitor.shared.finish(usage, succeeded: false, outputCharacters: outputText.count, detail: "Exit \(task.terminationStatus)")
                        }
                        completion(.failure(ExecutionError.processFailed(task.terminationStatus, outputText)))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.activeProcesses.removeValue(forKey: identifier)
                    self.timeoutWorkItems.removeValue(forKey: identifier)?.cancel()
                    if self.cancelledProcesses.remove(identifier) == nil {
                        self.timedOutProcesses.remove(identifier)
                        if let usage = self.usageTasks.removeValue(forKey: identifier) {
                            UsageMonitor.shared.finish(usage, succeeded: false, detail: error.localizedDescription)
                        }
                        completion(.failure(error))
                    } else {
                        self.timedOutProcesses.remove(identifier)
                    }
                }
            }
        }
    }

    enum ExecutionError: LocalizedError {
        case invalidURL(String)
        case missingFile(String)
        case notExecutable(String)
        case cannotOpen(String)
        case processFailed(Int32, String)
        case timedOut(Int)
        case invalidForm(String)
        case cancelled
        case securityViolation(String)
        case invalidAction(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL(let value): return "Invalid URL: \(value)"
            case .missingFile(let path): return "File not found: \(path)"
            case .notExecutable(let path): return "The extension script is not executable: \(path)"
            case .cannotOpen(let value): return "macOS could not open: \(value)"
            case .processFailed(let code, let message): return message.isEmpty ? "The command exited with status \(code)." : message
            case .timedOut(let seconds): return "The extension exceeded its \(seconds)-second performance limit and was stopped."
            case .invalidForm(let message): return message
            case .cancelled: return "The workflow command was cancelled."
            case .securityViolation(let message): return "Extension security policy rejected this action: \(message)"
            case .invalidAction(let message): return message
            }
        }
    }
}
