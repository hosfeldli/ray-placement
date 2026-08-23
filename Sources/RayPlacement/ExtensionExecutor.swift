import AppKit
import Foundation
import RayPlacementCore
import RayPlacementWriting

@MainActor
final class ExtensionExecutor {
    private var activeProcesses: [UUID: Process] = [:]
    private var cancelledProcesses = Set<UUID>()
    private var timedOutProcesses = Set<UUID>()
    private var timeoutWorkItems: [UUID: DispatchWorkItem] = [:]

    func cancelAll() {
        for (identifier, process) in activeProcesses {
            cancelledProcesses.insert(identifier)
            timeoutWorkItems.removeValue(forKey: identifier)?.cancel()
            if process.isRunning { process.terminate() }
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

        case .openInVSCode:
            completion(.success("__OPEN_IN_VSCODE__"))

        case .convertTimezones:
            completion(.success("__CONVERT_TIMEZONES__"))

        case .forceQuitApplications:
            completion(.success("__FORCE_QUIT_APPLICATIONS__"))

        case .forceQuitAllApplications:
            completion(.success("__FORCE_QUIT_ALL_APPLICATIONS__"))

        case .shell:
            run(action, relativeTo: loaded.directory, completion: completion)
        }
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
        } catch {
            completion(.failure(error))
            return
        }

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
                        completion(.failure(ExecutionError.timedOut(Int(performance.extensionTimeout))))
                    } else if task.terminationStatus == 0 {
                        completion(.success(outputText.isEmpty ? nil : outputText))
                    } else {
                        completion(.failure(ExecutionError.processFailed(task.terminationStatus, outputText)))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.activeProcesses.removeValue(forKey: identifier)
                    self.timeoutWorkItems.removeValue(forKey: identifier)?.cancel()
                    if self.cancelledProcesses.remove(identifier) == nil {
                        self.timedOutProcesses.remove(identifier)
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

        var errorDescription: String? {
            switch self {
            case .invalidURL(let value): return "Invalid URL: \(value)"
            case .missingFile(let path): return "File not found: \(path)"
            case .notExecutable(let path): return "The extension script is not executable: \(path)"
            case .cannotOpen(let value): return "macOS could not open: \(value)"
            case .processFailed(let code, let message): return message.isEmpty ? "The command exited with status \(code)." : message
            case .timedOut(let seconds): return "The extension exceeded its \(seconds)-second performance limit and was stopped."
            }
        }
    }
}
