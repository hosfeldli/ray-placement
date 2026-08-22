@preconcurrency import Foundation
import RayPlacementWriting

@MainActor
final class WritingProviderRunner {
    struct ProcessOutput {
        let status: Int32
        let stdout: Data
        let stderr: String
    }

    enum RunnerError: LocalizedError {
        case missingResource(String)
        case processFailed(String)
        case textTooLong(provider: WritingProvider, limit: Int)

        var errorDescription: String? {
            switch self {
            case .missingResource(let name):
                return "The bundled \(name) resource is missing. Reinstall RayPlacement."
            case .processFailed(let message):
                return message.isEmpty ? "The local writing engine failed." : message
            case .textTooLong(let provider, let limit):
                return "\(provider.title) checks are limited to \(limit.formatted()) characters at a time."
            }
        }
    }

    private let reviewer = WritingCheckService()
    private var activeProcess: Process?

    func cancel() {
        if activeProcess?.isRunning == true { activeProcess?.terminate() }
        activeProcess = nil
    }

    func check(
        _ text: String,
        provider: WritingProvider,
        completion: @escaping (Result<WritingReview, Error>) -> Void
    ) {
        cancel()
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else {
            completion(.failure(WritingCheckService.CheckError.emptyText))
            return
        }

        switch provider {
        case .harper:
            runHarper(text, completion: completion)
        case .coeditInt8:
            runCoEdit(text, completion: completion)
        case .qwen3Deep:
            runQwenDeep(text, completion: completion)
        }
    }

    private func runHarper(
        _ text: String,
        completion: @escaping (Result<WritingReview, Error>) -> Void
    ) {
        guard text.count <= reviewer.characterLimit else {
            completion(.failure(RunnerError.textTooLong(provider: .harper, limit: reviewer.characterLimit)))
            return
        }
        guard let executable = resourceURL("harper-cli", in: "Tools") else {
            completion(.failure(RunnerError.missingResource("Harper")))
            return
        }
        try? ApplicationPaths.prepare()
        if !FileManager.default.fileExists(atPath: ApplicationPaths.harperDictionary.path) {
            FileManager.default.createFile(atPath: ApplicationPaths.harperDictionary.path, contents: Data())
        }
        let arguments = [
            "--no-color", "lint", "--format", "json", "--quiet",
            "--user-dict-path", ApplicationPaths.harperDictionary.path
        ]
        run(executable: executable, arguments: arguments, input: text) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let output):
                guard output.status == 0 || output.status == 1 else {
                    completion(.failure(RunnerError.processFailed(output.stderr)))
                    return
                }
                do {
                    completion(.success(try self.reviewer.review(sourceText: text, harperJSON: output.stdout)))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    private func runCoEdit(
        _ text: String,
        completion: @escaping (Result<WritingReview, Error>) -> Void
    ) {
        let limit = 4_000
        guard text.count <= limit else {
            completion(.failure(RunnerError.textTooLong(provider: .coeditInt8, limit: limit)))
            return
        }
        guard let executable = resourceURL("node", in: "CoEdit"),
              let runner = resourceURL("runner.mjs", in: "CoEdit"),
              let model = resourceURL("model", in: "CoEdit") else {
            completion(.failure(RunnerError.missingResource("T5-small CoEdit INT8")))
            return
        }
        let performance = SettingsStore.shared.writingPerformance
        run(
            executable: executable,
            arguments: [runner.path, model.path, String(performance.threadLimit)],
            input: text,
            timeoutSeconds: performance.writingTimeout
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let output):
                guard output.status == 0 else {
                    completion(.failure(RunnerError.processFailed(output.stderr)))
                    return
                }
                let rewritten = String(decoding: output.stdout, as: UTF8.self)
                do {
                    completion(.success(try self.reviewer.review(
                        sourceText: text,
                        rewrittenText: rewritten,
                        providerTitle: WritingProvider.coeditInt8.title
                    )))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    private func runQwenDeep(
        _ text: String,
        completion: @escaping (Result<WritingReview, Error>) -> Void
    ) {
        let limit = 6_000
        guard text.count <= limit else {
            completion(.failure(RunnerError.textTooLong(provider: .qwen3Deep, limit: limit)))
            return
        }
        guard let executable = resourceURL("llama-cli", in: "Qwen/runtime"),
              let model = resourceURL("Qwen3-1.7B-Q8_0.gguf", in: "Qwen") else {
            completion(.failure(RunnerError.missingResource("Qwen3 Deep")))
            return
        }

        let systemPrompt = "You are an exacting English proofreading engine. Correct every spelling, grammar, word-choice, and punctuation error. Preserve the intended meaning. Return only the fully corrected text, with no explanation."
        let performance = SettingsStore.shared.writingPerformance
        let threads = String(performance.threadLimit)
        let arguments = [
            "-m", model.path,
            "--conversation", "--single-turn", "--reasoning", "off",
            "--system-prompt", systemPrompt,
            "--prompt", text,
            "--simple-io", "--no-display-prompt", "--log-disable",
            "--predict", "512", "--temp", "0", "--ctx-size", "4096",
            "--threads", threads, "--threads-batch", threads,
            "--batch-size", "128", "--ubatch-size", "64",
            "--prio", "-1", "--prio-batch", "0",
            "--gpu-layers", "0", "--no-warmup"
        ]
        run(
            executable: executable,
            arguments: arguments,
            input: "",
            timeoutSeconds: performance.writingTimeout
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let output):
                guard output.status == 0 else {
                    completion(.failure(RunnerError.processFailed(output.stderr)))
                    return
                }
                let console = String(decoding: output.stdout, as: UTF8.self)
                guard let rewritten = self.extractQwenResponse(from: console, prompt: text) else {
                    completion(.failure(RunnerError.processFailed("Qwen3 returned an unreadable response.")))
                    return
                }
                do {
                    let normalized = self.reviewer.normalizeModelRewrite(rewritten)
                    completion(.success(try self.reviewer.review(
                        sourceText: text,
                        rewrittenText: normalized,
                        providerTitle: WritingProvider.qwen3Deep.title
                    )))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    private func extractQwenResponse(from console: String, prompt: String) -> String? {
        let promptMarker = "\n> \(prompt)\n"
        guard let promptRange = console.range(of: promptMarker, options: .backwards) else { return nil }
        let responseStart = promptRange.upperBound
        let remaining = console[responseStart...]
        let endMarkers = ["\n\n[ Prompt:", "\n[ Prompt:", "\n\nExiting..."]
        let responseEnd = endMarkers
            .compactMap { remaining.range(of: $0)?.lowerBound }
            .min() ?? console.endIndex
        let response = console[responseStart..<responseEnd]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return response.isEmpty ? nil : response
    }

    private func run(
        executable: URL,
        arguments: [String],
        input: String,
        timeoutSeconds: TimeInterval? = nil,
        completion: @escaping (Result<ProcessOutput, Error>) -> Void
    ) {
        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError
        let performance = SettingsStore.shared.writingPerformance
        process.qualityOfService = performance.qualityOfService
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LANG": "en_US.UTF-8",
            "OMP_NUM_THREADS": String(performance.threadLimit),
            "OMP_THREAD_LIMIT": String(performance.threadLimit),
            "MKL_NUM_THREADS": String(performance.threadLimit),
            "VECLIB_MAXIMUM_THREADS": String(performance.threadLimit),
            "TOKENIZERS_PARALLELISM": "false"
        ]

        do {
            try process.run()
            activeProcess = process
        } catch {
            completion(.failure(error))
            return
        }

        let stateLock = NSLock()
        var didTimeOut = false
        let timeoutWorkItem = DispatchWorkItem {
            guard process.isRunning else { return }
            stateLock.lock()
            didTimeOut = true
            stateLock.unlock()
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + (timeoutSeconds ?? performance.writingTimeout),
            execute: timeoutWorkItem
        )

        DispatchQueue.global(qos: .utility).async {
            standardInput.fileHandleForWriting.write(Data(input.utf8))
            try? standardInput.fileHandleForWriting.close()

            let group = DispatchGroup()
            var stdout = Data()
            var stderr = Data()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = standardOutput.fileHandleForReading.readDataToEndOfFile()
                stateLock.lock(); stdout = data; stateLock.unlock()
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = standardError.fileHandleForReading.readDataToEndOfFile()
                stateLock.lock(); stderr = data; stateLock.unlock()
                group.leave()
            }
            process.waitUntilExit()
            group.wait()
            timeoutWorkItem.cancel()

            stateLock.lock()
            let timedOut = didTimeOut
            let output = ProcessOutput(
                status: process.terminationStatus,
                stdout: stdout,
                stderr: String(decoding: stderr.prefix(64_000), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
            stateLock.unlock()
            DispatchQueue.main.async { [weak self] in
                if self?.activeProcess === process { self?.activeProcess = nil }
                if timedOut {
                    completion(.failure(RunnerError.processFailed("The local writing engine exceeded its time limit and was stopped.")))
                } else {
                    completion(.success(output))
                }
            }
        }
    }

    private func resourceURL(_ name: String, in directory: String) -> URL? {
        let url = Bundle.main.resourceURL?
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent(name)
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
