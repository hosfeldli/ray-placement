@preconcurrency import Foundation
import RayPlacementCore
import RayPlacementWriting

@MainActor
private final class LocalAIExecutionGate {
    static let shared = LocalAIExecutionGate()
    private var owner: UUID?

    func acquire(_ candidate: UUID) -> Bool {
        guard owner == nil else { return false }
        owner = candidate
        return true
    }

    func release(_ candidate: UUID) {
        if owner == candidate { owner = nil }
    }
}

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
        case modelBusy

        var errorDescription: String? {
            switch self {
            case .missingResource(let name):
                return "The bundled \(name) resource is missing. Reinstall RayPlacement."
            case .processFailed(let message):
                return message.isEmpty ? "The local writing engine failed." : message
            case .textTooLong(let provider, let limit):
                return "\(provider.title) checks are limited to \(limit.formatted()) characters at a time."
            case .modelBusy:
                return "Another local AI task is already running. Wait for it to finish or cancel it first."
            }
        }
    }

    private let reviewer = WritingCheckService()
    private var activeProcess: Process?
    private var modelLease: UUID?

    func cancel() {
        if activeProcess?.isRunning == true {
            activeProcess?.terminate()
            // Keep the lease until the terminated process has actually exited. This
            // prevents a second model from briefly overlapping it during cancellation.
            return
        }
        activeProcess = nil
        releaseModelLease()
    }

    func summarize(
        _ markdown: String,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        cancel()
        let cleanText = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else {
            completion(.failure(WritingCheckService.CheckError.emptyText))
            return
        }
        guard resourceURL("llama-cli", in: "Qwen/runtime") != nil,
              resourceURL("Qwen3-1.7B-Q8_0.gguf", in: "Qwen") != nil else {
            completion(.failure(RunnerError.missingResource("Qwen3 Deep")))
            return
        }
        guard acquireModelLease() else {
            completion(.failure(RunnerError.modelBusy))
            return
        }

        let chunks = NoteSummaryPlan.chunks(cleanText)
        let summaryTokenLimit = SettingsStore.shared.runtimeWritingPerformance.summaryTokenLimit
        if chunks.count == 1, let onlyChunk = chunks.first {
            progress("Summarizing this note with Qwen…")
            runQwenText(
                prompt: wrappedSummaryPrompt(onlyChunk),
                systemPrompt: finalSummarySystemPrompt,
                predict: summaryTokenLimit
            ) { [weak self] result in
                self?.releaseModelLease()
                completion(result)
            }
            return
        }
        summarizeSections(chunks, index: 0, summaries: [], progress: progress) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.releaseModelLease()
                completion(.failure(error))
            case .success(let sectionSummaries):
                self.reduceSummaries(sectionSummaries, pass: 1, progress: progress) { [weak self] reduced in
                    guard let self else { return }
                    self.releaseModelLease()
                    completion(reduced)
                }
            }
        }
    }

    func check(
        _ text: String,
        provider: WritingProvider,
        progress: @escaping (String) -> Void = { _ in },
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
            progress("Running fast spelling and grammar rules across the full selection…")
            runHarper(text, completion: completion)
        case .coeditInt8:
            progress("Cleaning spelling, then rewriting the full selection with T5-small…")
            runCoEdit(text, progress: progress, completion: completion)
        case .qwen3Deep:
            progress("Cleaning spelling before the deep proofreading pass…")
            runQwenDeep(text, progress: progress, completion: completion)
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
                    let harperReview = try self.reviewer.review(sourceText: text, harperJSON: output.stdout)
                    let corrected = self.reviewer.normalizeProofreadRewrite(
                        harperReview.suggestedText,
                        preservingBoundaryFrom: text
                    )
                    if corrected == harperReview.suggestedText {
                        completion(.success(harperReview))
                    } else {
                        completion(.success(try self.reviewer.review(
                            sourceText: text,
                            rewrittenText: corrected,
                            providerTitle: "Harper + RayPlacement quality pass"
                        )))
                    }
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    private func runCoEdit(
        _ text: String,
        progress: @escaping (String) -> Void,
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
        runHarper(text) { [weak self] preparationResult in
            guard let self else { return }
            switch preparationResult {
            case .failure(let error):
                completion(.failure(error))
            case .success(let preparation):
                let preparedText = self.reviewer.normalizeProofreadRewrite(preparation.suggestedText)
                let performance = SettingsStore.shared.runtimeWritingPerformance
                progress("Spelling cleanup complete. Rewriting with T5-small on \(performance.threadLimit) CPU thread\(performance.threadLimit == 1 ? "" : "s")…")
                guard self.acquireModelLease() else {
                    completion(.failure(RunnerError.modelBusy))
                    return
                }
                self.run(
                    executable: executable,
                    arguments: [runner.path, model.path, String(performance.threadLimit)],
                    input: preparedText,
                    timeoutSeconds: performance.writingTimeout
                ) { [weak self] result in
                    guard let self else { return }
                    self.releaseModelLease()
                    switch result {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let output):
                        guard output.status == 0 else {
                            completion(.failure(RunnerError.processFailed(output.stderr)))
                            return
                        }
                        let rewritten = self.reviewer.normalizeProofreadRewrite(
                            String(decoding: output.stdout, as: UTF8.self),
                            preservingBoundaryFrom: text
                        )
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
        }
    }

    private func runQwenDeep(
        _ text: String,
        progress: @escaping (String) -> Void,
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

        runHarper(text) { [weak self] preparationResult in
            guard let self else { return }
            switch preparationResult {
            case .failure(let error):
                completion(.failure(error))
            case .success(let preparation):
                let systemPrompt = "You are an exacting English copy editor. Proofread the entire supplied passage, not only one error. Correct every spelling, grammar, verb-tense, word-choice, agreement, capitalization, and punctuation problem. Preserve the intended meaning and line breaks. Make every sentence complete and natural. Return only the fully corrected passage with no explanation, labels, or quotation marks."
                let performance = SettingsStore.shared.runtimeWritingPerformance
                let preparedText = self.reviewer.normalizeProofreadRewrite(preparation.suggestedText)
                progress("Spelling cleanup complete. Qwen is proofreading the full selection on \(performance.threadLimit) CPU thread\(performance.threadLimit == 1 ? "" : "s")…")
                guard self.acquireModelLease() else {
                    completion(.failure(RunnerError.modelBusy))
                    return
                }
                let threads = String(performance.threadLimit)
                let arguments = [
                    "-m", model.path,
                    "--conversation", "--single-turn", "--reasoning", "off",
                    "--system-prompt", systemPrompt,
                    "--prompt", preparedText,
                    "--simple-io", "--no-display-prompt", "--log-disable",
                    "--predict", "512", "--temp", "0", "--ctx-size", "4096",
                    "--threads", threads, "--threads-batch", threads,
                    "--batch-size", "128", "--ubatch-size", "64",
                    "--prio", "-1", "--prio-batch", "0",
                    "--gpu-layers", "0", "--no-warmup"
                ]
                self.run(
                    executable: executable,
                    arguments: arguments,
                    input: "",
                    timeoutSeconds: performance.writingTimeout
                ) { [weak self] result in
                    guard let self else { return }
                    self.releaseModelLease()
                    switch result {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let output):
                        guard output.status == 0 else {
                            completion(.failure(RunnerError.processFailed(output.stderr)))
                            return
                        }
                        let console = String(decoding: output.stdout, as: UTF8.self)
                        guard let rewritten = self.extractQwenResponse(from: console, prompt: preparedText) else {
                            completion(.failure(RunnerError.processFailed("Qwen3 returned an unreadable response.")))
                            return
                        }
                        do {
                            let normalized = self.reviewer.normalizeProofreadRewrite(
                                rewritten,
                                preservingBoundaryFrom: text
                            )
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
        }
    }

    private func summarizeSections(
        _ chunks: [String],
        index: Int,
        summaries: [String],
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        guard index < chunks.count else {
            completion(.success(summaries))
            return
        }
        progress("Summarizing section \(index + 1) of \(chunks.count) with Qwen…")
        let systemPrompt = "Summarize one section of Markdown notes. Preserve concrete facts, names, dates, decisions, action items, risks, and open questions. Return concise Markdown bullets only. Do not invent information."
        let predict = min(320, SettingsStore.shared.runtimeWritingPerformance.summaryTokenLimit)
        runQwenText(prompt: wrappedSummaryPrompt(chunks[index]), systemPrompt: systemPrompt, predict: predict) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let summary):
                self.summarizeSections(
                    chunks,
                    index: index + 1,
                    summaries: summaries + [summary],
                    progress: progress,
                    completion: completion
                )
            }
        }
    }

    private func reduceSummaries(
        _ summaries: [String],
        pass: Int,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let combined = summaries.enumerated().map { "### Section \($0.offset + 1)\n\($0.element)" }
            .joined(separator: "\n\n")
        if combined.count <= 6_000 || pass >= 4 {
            progress("Building the final Qwen summary…")
            let prompt = String(combined.prefix(8_000))
            let predict = SettingsStore.shared.runtimeWritingPerformance.summaryTokenLimit
            runQwenText(prompt: wrappedSummaryPrompt(prompt), systemPrompt: finalSummarySystemPrompt, predict: predict, completion: completion)
            return
        }

        let groups = NoteSummaryPlan.chunks(combined)
        progress("Condensing \(groups.count) groups with Qwen…")
        summarizeReductionGroups(groups, index: 0, summaries: [], pass: pass, progress: progress, completion: completion)
    }

    private func summarizeReductionGroups(
        _ groups: [String],
        index: Int,
        summaries: [String],
        pass: Int,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard index < groups.count else {
            reduceSummaries(summaries, pass: pass + 1, progress: progress, completion: completion)
            return
        }
        progress("Condensing summary group \(index + 1) of \(groups.count)…")
        let systemPrompt = "Condense these partial Markdown summaries. Keep all distinct decisions, action items, names, dates, risks, and open questions. Remove repetition. Return Markdown bullets only and do not invent facts."
        let predict = min(320, SettingsStore.shared.runtimeWritingPerformance.summaryTokenLimit)
        runQwenText(prompt: wrappedSummaryPrompt(groups[index]), systemPrompt: systemPrompt, predict: predict) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let summary):
                self.summarizeReductionGroups(
                    groups,
                    index: index + 1,
                    summaries: summaries + [summary],
                    pass: pass,
                    progress: progress,
                    completion: completion
                )
            }
        }
    }

    private func runQwenText(
        prompt: String,
        systemPrompt: String,
        predict: Int,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let executable = resourceURL("llama-cli", in: "Qwen/runtime"),
              let model = resourceURL("Qwen3-1.7B-Q8_0.gguf", in: "Qwen") else {
            completion(.failure(RunnerError.missingResource("Qwen3 Deep")))
            return
        }
        let performance = SettingsStore.shared.runtimeWritingPerformance
        let threads = String(performance.threadLimit)
        let arguments = [
            "-m", model.path,
            "--conversation", "--single-turn", "--reasoning", "off",
            "--system-prompt", systemPrompt,
            "--prompt", prompt,
            "--simple-io", "--no-display-prompt", "--log-disable",
            "--predict", String(predict), "--temp", "0", "--ctx-size", "4096",
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
                guard let response = self.extractQwenResponse(from: console, prompt: prompt) else {
                    completion(.failure(RunnerError.processFailed("Qwen3 returned an unreadable summary.")))
                    return
                }
                completion(.success(response.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }

    private var finalSummarySystemPrompt: String {
        "Combine the supplied notes into one accurate Markdown summary. Use the headings Overview, Decisions, Action Items, Risks, and Open Questions when relevant. Remove repetition, preserve names and dates, and never invent facts. Return only the finished summary with complete Markdown sentences."
    }

    private func wrappedSummaryPrompt(_ source: String) -> String {
        "# Notes to summarize\n\n\(source)\n\n# Required output\nWrite a useful summary with complete Markdown bullet points."
    }

    private func acquireModelLease() -> Bool {
        let candidate = UUID()
        guard LocalAIExecutionGate.shared.acquire(candidate) else { return false }
        modelLease = candidate
        return true
    }

    private func releaseModelLease() {
        guard let modelLease else { return }
        LocalAIExecutionGate.shared.release(modelLease)
        self.modelLease = nil
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
        let performance = SettingsStore.shared.runtimeWritingPerformance
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
