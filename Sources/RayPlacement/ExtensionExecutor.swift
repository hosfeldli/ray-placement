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

    func execute(
        _ loaded: LoadedExtensionCommand,
        clipboard: ClipboardHistoryService,
        completion: @escaping (Result<String?, Error>) -> Void
    ) {
        let action = loaded.command.action
        switch action.type {
        case .url:
            guard let url = URL(string: action.value) else {
                completion(.failure(ExecutionError.invalidURL(action.value)))
                return
            }
            if NSWorkspace.shared.open(url) {
                completion(.success(nil))
            } else {
                completion(.failure(ExecutionError.cannotOpen(url.absoluteString)))
            }

        case .file, .application:
            let url = resolve(action.value, relativeTo: loaded.directory)
            guard FileManager.default.fileExists(atPath: url.path) else {
                completion(.failure(ExecutionError.missingFile(url.path)))
                return
            }
            if NSWorkspace.shared.open(url) {
                completion(.success(nil))
            } else {
                completion(.failure(ExecutionError.cannotOpen(url.path)))
            }

        case .copy, .paste:
            clipboard.copy(action.value)
            completion(.success(action.type == .paste ? "__PASTE__" : nil))

        case .pastePlainText:
            do {
                let text = try PlainTextPasteboardService.rewriteAsPlainText()
                clipboard.copy(text)
                completion(.success("__PASTE__"))
            } catch {
                completion(.failure(error))
            }

        case .checkWriting:
            completion(.success("__CHECK_WRITING__"))

        case .openFocusedFileLauncher:
            completion(.success("__OPEN_FOCUSED_FILE_LAUNCHER__"))

        case .convertTimezones:
            completion(.success("__CONVERT_TIMEZONES__"))

        case .forceQuitApplications:
            completion(.success("__FORCE_QUIT_APPLICATIONS__"))

        case .forceQuitAllApplications:
            completion(.success("__FORCE_QUIT_ALL_APPLICATIONS__"))

        case .openFormatterWorkspace:
            completion(.success("__OPEN_FORMATTER_WORKSPACE__"))

        case .openEmojiPicker:
            completion(.success("__OPEN_EMOJI_PICKER__"))

        case .openPasswordGenerator:
            completion(.success("__OPEN_PASSWORD_GENERATOR__"))

        case .openExtensionDevelopment:
            completion(.success("__OPEN_EXTENSION_DEVELOPMENT__"))

        case .uninstallApplication:
            completion(.success("__UNINSTALL_APPLICATION__"))

        case .form:
            completion(.success("__OPEN_EXTENSION_FORM__"))

        case .shell:
            run(action, relativeTo: loaded.directory, completion: completion)
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
        case .httpRequest:
            executeHTTPRequest(definition.execution, values: values, completion: completion)
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
            run(action, relativeTo: loaded.directory) { result in
                switch result {
                case .success(let output):
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

    private func executeHTTPRequest(
        _ execution: ExtensionFormExecution,
        values: [String: String],
        completion: @escaping (Result<FormResult, Error>) -> Void
    ) {
        let renderedURL = ExtensionTemplate.render(execution.url ?? "", values: values)
        guard let url = URL(string: renderedURL), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            completion(.failure(ExecutionError.invalidURL(renderedURL)))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = ExtensionTemplate.render(execution.method ?? "GET", values: values).uppercased()
        for (name, value) in execution.headers ?? [:] {
            let rendered = ExtensionTemplate.render(value, values: values)
            if !rendered.isEmpty { request.setValue(rendered, forHTTPHeaderField: name) }
        }
        if let body = execution.body, !body.isEmpty {
            request.httpBody = Data(ExtensionTemplate.render(body, values: values).utf8)
        }
        let configuredTimeout = TimeInterval(execution.timeoutSeconds ?? 30)
        let performanceTimeout = SettingsStore.shared.runtimeExtensionPerformance.extensionTimeout
        request.timeoutInterval = performanceTimeout > 0
            ? min(max(configuredTimeout, 1), performanceTimeout)
            : max(configuredTimeout, 1)

        let started = Date()
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let response = response as? HTTPURLResponse else {
                    completion(.failure(ExecutionError.invalidForm("The endpoint did not return an HTTP response.")))
                    return
                }
                let limited = (data ?? Data()).prefix(1_000_000)
                let output = Self.formattedResponse(Data(limited), response: response)
                let elapsed = Date().timeIntervalSince(started)
                completion(.success(FormResult(
                    headline: "HTTP \(response.statusCode)",
                    detail: String(format: "%.0f ms · %@", elapsed * 1_000, ByteCountFormatter.string(fromByteCount: Int64(data?.count ?? 0), countStyle: .file)),
                    output: output,
                    succeeded: (200..<400).contains(response.statusCode)
                )))
            }
        }
        task.resume()
    }

    private static func formattedResponse(_ data: Data, response: HTTPURLResponse) -> String {
        var sections = response.allHeaderFields
            .map { "\($0.key): \($0.value)" }
            .sorted()
            .joined(separator: "\n")
        if let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            sections += "\n\n" + String(decoding: pretty, as: UTF8.self)
        } else if !data.isEmpty {
            sections += "\n\n" + String(decoding: data, as: UTF8.self)
        }
        return sections
    }

    private func run(
        _ action: ExtensionAction,
        relativeTo directory: URL,
        completion: @escaping (Result<String?, Error>) -> Void
    ) {
        let executable = resolve(action.value, relativeTo: directory)
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
            task.currentDirectoryURL = resolve(workingDirectory, relativeTo: directory)
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
                        completion(.success(outputText.isEmpty ? nil : outputText))
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

    private func resolve(_ path: String, relativeTo directory: URL) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        return directory.appendingPathComponent(expanded).standardizedFileURL
    }

    enum ExecutionError: LocalizedError {
        case invalidURL(String)
        case missingFile(String)
        case notExecutable(String)
        case cannotOpen(String)
        case processFailed(Int32, String)
        case timedOut(Int)
        case invalidForm(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL(let value): return "Invalid URL: \(value)"
            case .missingFile(let path): return "File not found: \(path)"
            case .notExecutable(let path): return "The extension script is not executable: \(path)"
            case .cannotOpen(let value): return "macOS could not open: \(value)"
            case .processFailed(let code, let message): return message.isEmpty ? "The command exited with status \(code)." : message
            case .timedOut(let seconds): return "The extension exceeded its \(seconds)-second performance limit and was stopped."
            case .invalidForm(let message): return message
            }
        }
    }
}
