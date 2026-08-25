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
        case invalidModelResponse
        case textTooLong(provider: WritingProvider, limit: Int)
        case modelBusy

        var errorDescription: String? {
            switch self {
            case .missingResource(let name):
                return "The bundled \(name) resource is missing. Reinstall RayPlacement."
            case .processFailed(let message):
                return message.isEmpty ? "The local writing engine failed." : message
            case .invalidModelResponse:
                return "The local model returned an incomplete response twice. No text was changed."
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
    private var usageTaskID: UUID?

    func cancel() {
        if activeProcess?.isRunning == true {
            activeProcess?.terminate()
            // Keep the lease until the terminated process has actually exited. This
            // prevents a second model from briefly overlapping it during cancellation.
            return
        }
        activeProcess = nil
        if let usageTaskID {
            UsageMonitor.shared.finish(usageTaskID, succeeded: false, detail: "Cancelled by user")
            self.usageTaskID = nil
        }
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
        let selectedModel = SettingsStore.shared.selectedModel(for: .summary)
        guard resourceURL("llama-cli", in: "Qwen/runtime") != nil,
              LocalModelCatalog.url(for: selectedModel) != nil else {
            completion(.failure(RunnerError.missingResource(LocalModelCatalog.descriptor(selectedModel).title)))
            return
        }
        guard acquireModelLease() else {
            completion(.failure(RunnerError.modelBusy))
            return
        }

        let chunks = NoteSummaryPlan.chunks(cleanText)
        let summaryTokenLimit = SettingsStore.shared.runtimeWritingPerformance.summaryTokenLimit
        let modelTitle = LocalModelCatalog.descriptor(selectedModel).title
        usageTaskID = UsageMonitor.shared.begin(
            category: .summary,
            operation: "Summarize note",
            model: modelTitle,
            performance: SettingsStore.shared.runtimeWritingPerformance,
            inputCharacters: cleanText.count
        )
        if chunks.count == 1, let onlyChunk = chunks.first {
            progress("Summarizing this note with \(modelTitle)…")
            runQwenText(
                prompt: wrappedSummaryPrompt(onlyChunk),
                systemPrompt: finalSummarySystemPrompt,
                predict: summaryTokenLimit,
                task: .summary
            ) { [weak self] result in
                self?.releaseModelLease()
                self?.finishUsage(result)
                completion(result)
            }
            return
        }
        summarizeSections(chunks, index: 0, summaries: [], progress: progress) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.releaseModelLease()
                self.finishUsage(.failure(error) as Result<String, Error>)
                completion(.failure(error))
            case .success(let sectionSummaries):
                self.reduceSummaries(sectionSummaries, pass: 1, progress: progress) { [weak self] reduced in
                    guard let self else { return }
                    self.releaseModelLease()
                    self.finishUsage(reduced)
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

        // Writing correction is intentionally model-only. The provider argument is
        // retained for manifest/source compatibility, but every user-facing check
        // is performed directly by Qwen without Harper, NSSpellChecker, or a
        // rule-based post-processing pass.
        progress("Loading Qwen for a complete AI grammar correction…")
        runQwenDeep(text, progress: progress, completion: completion)
    }

    func proposeDocumentCorrection(
        source: String,
        kind: FormatterDocumentKind,
        diagnostics: [FormatterDiagnostic],
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        cancel()
        let cleanSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSource.isEmpty else {
            completion(.failure(WritingCheckService.CheckError.emptyText))
            return
        }
        guard acquireModelLease() else {
            completion(.failure(RunnerError.modelBusy))
            return
        }
        let selected = SettingsStore.shared.selectedModel(for: .formatter)
        let descriptor = LocalModelCatalog.descriptor(selected)
        progress("\(descriptor.title) is reviewing the validation findings…")
        usageTaskID = UsageMonitor.shared.begin(
            category: .formatterAI,
            operation: "Propose \(kind.title) corrections",
            model: descriptor.title,
            performance: SettingsStore.shared.runtimeWritingPerformance,
            inputCharacters: cleanSource.count
        )
        let issueText = diagnostics.map { "- [\($0.severity.rawValue)] \($0.location.map { "\($0): " } ?? "")\($0.message)" }
            .joined(separator: "\n")
        let prompt = """
        # Document type
        \(kind.title)

        # Deterministic validation findings
        \(issueText.isEmpty ? "- No deterministic findings." : issueText)

        # Document
        \(cleanSource)

        Correct every deterministic error listed above. For EDI, copy an ST02 control number into its matching SE02 and replace SE01 with the exact counted value named in the finding. Preserve all other control numbers and business values. Do not return an unchanged document when an error has an explicit correction. Never invent trading-partner data. Return only the corrected complete document.
        """
        let systemPrompt = """
        You correct structured EDI, JSON, and XML documents using deterministic validation findings. Apply every correction whose exact expected value is stated. Preserve unrelated business data and delimiters. Return the complete corrected document without Markdown fences, labels, or explanation.

        Example:
        Findings: SE02 should equal ST02 (A), but it is B. SE01 should report 3 segments, but it is 9.
        Input: ST*990*A~B1*X*Y~SE*9*B~
        Output: ST*990*A~B1*X*Y~SE*3*A~
        """
        runQwenText(prompt: prompt, systemPrompt: systemPrompt, predict: 2_048, task: .formatter) { [weak self] result in
            guard let self else { return }
            self.releaseModelLease()
            self.finishUsage(result)
            completion(result)
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
        let selectedModel = SettingsStore.shared.selectedModel(for: .writing)
        let descriptor = LocalModelCatalog.descriptor(selectedModel)
        guard let executable = resourceURL("llama-cli", in: "Qwen/runtime"),
              let model = LocalModelCatalog.url(for: selectedModel) else {
            completion(.failure(RunnerError.missingResource(descriptor.title)))
            return
        }

        let customInstructions = SettingsStore.shared.writingInstructions
        let systemPrompt = AIWritingPrompt.systemPrompt(customInstructions: customInstructions)
        let performance = SettingsStore.shared.runtimeWritingPerformance
        progress("\(descriptor.title) is correcting the full selection…")
        guard acquireModelLease() else {
            completion(.failure(RunnerError.modelBusy))
            return
        }
        usageTaskID = UsageMonitor.shared.begin(
            category: .writing,
            operation: "Correct selected text",
            model: descriptor.title,
            performance: performance,
            inputCharacters: text.count
        )
        let grammarPredictionLimit = performance.isUnbounded ? 4_096 : min(2_048, max(512, text.count))
        runGrammarPass(
            executable: executable,
            model: model,
            prompt: text,
            systemPrompt: systemPrompt,
            predictionLimit: grammarPredictionLimit,
            performance: performance,
            attempt: 0,
            progress: progress
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.releaseModelLease()
                self.finishUsage(.failure(error) as Result<String, Error>)
                completion(.failure(error))
            case .success(let draft):
                progress("Auditing every correction before it is offered…")
                self.runGrammarPass(
                    executable: executable,
                    model: model,
                    prompt: AIWritingPrompt.auditPrompt(original: text, draft: draft),
                    systemPrompt: AIWritingPrompt.auditSystemPrompt(customInstructions: customInstructions),
                    predictionLimit: grammarPredictionLimit,
                    performance: performance,
                    attempt: 0,
                    progress: progress
                ) { [weak self] auditResult in
                    guard let self else { return }
                    self.releaseModelLease()
                    // A valid first pass remains safer than discarding the entire
                    // correction if an audit process is interrupted after it runs.
                    let finalText = (try? auditResult.get()) ?? draft
                    do {
                        let cleaned = AIWritingPrompt.cleanResponse(finalText, preservingBoundaryFrom: text)
                        self.finishUsage(.success(cleaned))
                        completion(.success(try self.reviewer.review(
                            sourceText: text,
                            rewrittenText: cleaned,
                            providerTitle: "\(descriptor.title) · Verified"
                        )))
                    } catch {
                        self.finishUsage(.failure(error) as Result<String, Error>)
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    private func runGrammarPass(
        executable: URL,
        model: URL,
        prompt: String,
        systemPrompt: String,
        predictionLimit: Int,
        performance: PerformanceScale,
        attempt: Int,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let mode = SettingsStore.shared.aiComputeMode
        let useCPU = mode == .cpu || (mode == .automatic && attempt > 0)
        let arguments = localModelArguments(
            model: model,
            prompt: prompt,
            systemPrompt: systemPrompt,
            predictionLimit: predictionLimit,
            performance: performance,
            useCPU: useCPU,
            seed: attempt + 1
        )
        run(executable: executable, arguments: arguments, input: "", timeoutSeconds: performance.writingTimeout) { [weak self] result in
            guard let self else { return }
            let parsed: Result<String, Error>
            switch result {
            case .failure(let error):
                parsed = .failure(error)
            case .success(let output):
                if output.status != 0 {
                    parsed = .failure(RunnerError.processFailed(output.stderr))
                } else {
                    let console = String(decoding: output.stdout, as: UTF8.self)
                    let response = self.extractQwenResponse(from: console, prompt: prompt) ?? console
                    if let corrected = AIWritingPrompt.taggedResponse(response),
                       AIWritingPrompt.isPlausibleCorrection(corrected, for: prompt) {
                        parsed = .success(corrected)
                    } else {
                        parsed = .failure(RunnerError.invalidModelResponse)
                    }
                }
            }
            if case .failure = parsed, attempt == 0 {
                progress(mode == .automatic
                    ? "Retrying the correction safely on CPU…"
                    : "The first response was incomplete. Retrying once…")
                self.runGrammarPass(
                    executable: executable,
                    model: model,
                    prompt: prompt,
                    systemPrompt: systemPrompt,
                    predictionLimit: predictionLimit,
                    performance: performance,
                    attempt: 1,
                    progress: progress,
                    completion: completion
                )
                return
            }
            completion(parsed)
        }
    }

    private func localModelArguments(
        model: URL,
        prompt: String,
        systemPrompt: String,
        predictionLimit: Int,
        performance: PerformanceScale,
        useCPU: Bool,
        seed: Int
    ) -> [String] {
        let threads = String(performance.threadLimit)
        return [
            "-m", model.path,
            "--conversation", "--single-turn", "--reasoning", "off",
            "--system-prompt", systemPrompt,
            "--prompt", prompt,
            "--simple-io", "--no-display-prompt", "--log-disable",
            "--predict", String(predictionLimit), "--temp", "0", "--seed", String(seed), "--ctx-size", "8192",
            "--threads", threads, "--threads-batch", threads,
            "--batch-size", performance.isUnbounded ? "512" : "128",
            "--ubatch-size", performance.isUnbounded ? "256" : "64",
            "--prio", "-1", "--prio-batch", "0",
            "--gpu-layers", useCPU ? "0" : "all", "--no-warmup"
        ]
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
        runQwenText(prompt: wrappedSummaryPrompt(chunks[index]), systemPrompt: systemPrompt, predict: predict, task: .summary) { [weak self] result in
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
            runQwenText(prompt: wrappedSummaryPrompt(prompt), systemPrompt: finalSummarySystemPrompt, predict: predict, task: .summary, completion: completion)
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
        runQwenText(prompt: wrappedSummaryPrompt(groups[index]), systemPrompt: systemPrompt, predict: predict, task: .summary) { [weak self] result in
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
        task: LocalModelTask,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let selected = SettingsStore.shared.selectedModel(for: task)
        let descriptor = LocalModelCatalog.descriptor(selected)
        guard let executable = resourceURL("llama-cli", in: "Qwen/runtime"),
              let model = LocalModelCatalog.url(for: selected) else {
            completion(.failure(RunnerError.missingResource(descriptor.title)))
            return
        }
        runQwenTextAttempt(
            executable: executable,
            model: model,
            prompt: prompt,
            systemPrompt: systemPrompt,
            predict: predict,
            attempt: 0,
            completion: completion
        )
    }

    private func runQwenTextAttempt(
        executable: URL,
        model: URL,
        prompt: String,
        systemPrompt: String,
        predict: Int,
        attempt: Int,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let performance = SettingsStore.shared.runtimeWritingPerformance
        let mode = SettingsStore.shared.aiComputeMode
        let useCPU = mode == .cpu || (mode == .automatic && attempt > 0)
        let taggedSystemPrompt = """
        \(systemPrompt)

        Return exactly <RP_RESULT> followed by the complete requested output and then <RP_END>. Do not put any text outside those tags.
        """
        let arguments = localModelArguments(
            model: model,
            prompt: prompt,
            systemPrompt: taggedSystemPrompt,
            predictionLimit: predict,
            performance: performance,
            useCPU: useCPU,
            seed: attempt + 1
        )
        run(executable: executable, arguments: arguments, input: "", timeoutSeconds: performance.writingTimeout) { [weak self] result in
            guard let self else { return }
            let parsed: Result<String, Error>
            switch result {
            case .failure(let error):
                parsed = .failure(error)
            case .success(let output):
                if output.status != 0 {
                    parsed = .failure(RunnerError.processFailed(output.stderr))
                } else {
                    let console = String(decoding: output.stdout, as: UTF8.self)
                    let response = self.extractQwenResponse(from: console, prompt: prompt) ?? console
                    if let value = Self.extractTaggedResult(response), !value.isEmpty {
                        parsed = .success(value)
                    } else {
                        parsed = .failure(RunnerError.invalidModelResponse)
                    }
                }
            }
            if case .failure = parsed, attempt == 0 {
                self.runQwenTextAttempt(
                    executable: executable,
                    model: model,
                    prompt: prompt,
                    systemPrompt: systemPrompt,
                    predict: predict,
                    attempt: 1,
                    completion: completion
                )
            } else {
                completion(parsed)
            }
        }
    }

    private static func extractTaggedResult(_ response: String) -> String? {
        guard let start = response.range(of: "<RP_RESULT>", options: .backwards),
              let end = response.range(of: "<RP_END>", range: start.upperBound..<response.endIndex) else { return nil }
        var value = String(response[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("</RP_RESULT>") {
            value.removeLast("</RP_RESULT>".count)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !value.contains("<RP_"), !value.contains("</RP_") else { return nil }
        return value
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

    private func finishUsage(_ result: Result<String, Error>) {
        guard let usageTaskID else { return }
        self.usageTaskID = nil
        switch result {
        case .success(let output):
            UsageMonitor.shared.finish(usageTaskID, succeeded: true, outputCharacters: output.count)
        case .failure(let error):
            UsageMonitor.shared.finish(usageTaskID, succeeded: false, detail: error.localizedDescription)
        }
    }

    private func extractQwenResponse(from console: String, prompt: String) -> String? {
        QwenConsoleParser.response(from: console, prompt: prompt)
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
        let effectiveTimeout = timeoutSeconds ?? performance.writingTimeout
        let timeoutWorkItem: DispatchWorkItem? = effectiveTimeout > 0 ? DispatchWorkItem {
            guard process.isRunning else { return }
            stateLock.lock()
            didTimeOut = true
            stateLock.unlock()
            process.terminate()
        } : nil
        if let timeoutWorkItem {
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + effectiveTimeout,
                execute: timeoutWorkItem
            )
        }

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
            timeoutWorkItem?.cancel()

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
