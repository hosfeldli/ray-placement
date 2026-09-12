@preconcurrency import Foundation
import RayPlacementWriting

@MainActor
final class RuleBasedWritingChecker {
    enum CheckerError: LocalizedError {
        case missingResources
        case processFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingResources: return "The local grammar resources are missing. Reinstall Lima."
            case .processFailed(let detail): return detail.isEmpty ? "The local grammar checker failed." : detail
            }
        }
    }

    private struct Output {
        let status: Int32
        let stdout: Data
        let stderr: String
    }

    private let reviewer = WritingCheckService()
    private let remoteClient = StealthGrammarRemoteClient()
    private lazy var ensembleCoordinator = GrammarEnsembleCoordinator(remoteClient: remoteClient)

    private var externalSystemPrompt: String {
        let mode = SettingsStore.shared.grammarCorrectionMode
        let modeInstruction: String = mode == .polish
            ? "In addition to proofreading, make only small, clearly beneficial clarity or flow improvements. Preserve the author's voice."
            : "Only correct high-confidence spelling, grammar, capitalization, and punctuation. Do not polish or rephrase."
        return StealthGrammarRemoteClient.systemPrompt + "\n" + modeInstruction
    }
    private var activeProcess: Process?
    private var externalGrammarTask: Task<Void, Never>?
    private var usageID: UUID?
    private var operationID: UUID?

    func cancel() {
        operationID = nil
        if activeProcess?.isRunning == true { activeProcess?.terminate() }
        activeProcess = nil
        externalGrammarTask?.cancel()
        externalGrammarTask = nil
        if let usageID {
            UsageMonitor.shared.finish(usageID, succeeded: false, detail: "Cancelled")
            self.usageID = nil
        }
    }

    /// Runs the privacy-preserving local pipeline only. Inline Notes checking
    /// uses this entry point so an optional provider can never put keystrokes
    /// on the network or make live checking depend on an API key.
    func checkLocal(
        _ source: String,
        progress: @escaping (String) -> Void = { _ in },
        completion: @escaping (Result<WritingReview, Error>) -> Void
    ) {
        cancel()
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(.failure(WritingCheckService.CheckError.emptyText))
            return
        }
        guard source.count <= reviewer.characterLimit else {
            completion(.failure(WritingCheckService.CheckError.textTooLong(reviewer.characterLimit)))
            return
        }
        let operationID = UUID()
        self.operationID = operationID
        let protected = StealthGrammarService.protect(
            source,
            ignoreList: SettingsStore.shared.writingInstructions
        )
        progress("Checking locally…")
        runPython(protected.maskedText, mode: "standard") { [weak self] pythonResult in
            guard let self, self.operationID == operationID else { return }
            let spelled: String
            switch pythonResult {
            case .success(let value): spelled = value
            case .failure: spelled = protected.maskedText
            }
            self.runHarper(spelled) { [weak self] harperResult in
                guard let self, self.operationID == operationID else { return }
                let correctedMasked: String
                switch harperResult {
                case .success(let value) where protected.restore(value) != nil: correctedMasked = value
                case .success: correctedMasked = spelled
                case .failure where spelled != protected.maskedText: correctedMasked = spelled
                case .failure(let error):
                    self.finish(success: false, detail: error.localizedDescription)
                    completion(.failure(error))
                    return
                }
                let normalized = self.reviewer.normalizeProofreadRewrite(correctedMasked)
                let corrected = protected.restore(normalized) ?? source
                self.completeLocalReview(
                    source: source,
                    rewrittenText: corrected,
                    operationID: operationID,
                    status: nil,
                    completion: completion
                )
            }
        }
    }

    func check(
        _ source: String,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<WritingReview, Error>) -> Void
    ) {
        cancel()
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(.failure(WritingCheckService.CheckError.emptyText))
            return
        }
        guard source.count <= reviewer.characterLimit else {
            completion(.failure(WritingCheckService.CheckError.textTooLong(reviewer.characterLimit)))
            return
        }
        usageID = UsageMonitor.shared.begin(
            category: .writing,
            operation: "Selected spelling and grammar engine",
            performance: SettingsStore.shared.runtimeWritingPerformance,
            inputCharacters: source.count
        )
        let operationID = UUID()
        self.operationID = operationID
        let protected = StealthGrammarService.protect(
            source,
            ignoreList: SettingsStore.shared.writingInstructions
        )

        guard SettingsStore.shared.grammarEngineMode == .externalAPI else {
            runLocalReview(
                source: source,
                protected: protected,
                operationID: operationID,
                progress: progress,
                status: nil,
                completion: completion
            )
            return
        }

        guard let configuration = SettingsStore.shared.developerGrammarConfiguration else {
            let error = StealthGrammarRemoteClient.ClientError.invalidConfiguration
            finish(success: false, detail: error.localizedDescription)
            completion(.failure(error))
            return
        }

        progress("Applying External Grammar ensemble…")
        runExternalEnsemble(
            source: source,
            protected: protected,
            configuration: configuration,
            operationID: operationID,
            progress: progress,
            completion: completion
        )
    }

    private struct ExternalReviewOutcome {
        let report: StealthGrammarApplyReport
        let review: WritingReview
    }

    private func externalReview(
        source: String,
        report: StealthGrammarApplyReport
    ) throws -> ExternalReviewOutcome {
        guard StealthGrammarService.isSafeReplacement(source, report.text) else {
            throw StealthGrammarRemoteClient.ClientError.safetyRejected
        }
        var review = try reviewer.review(
            sourceText: source,
            rewrittenText: report.text,
            engineTitle: "External API"
        )
        if report.rejectedCount > 0 {
            review = WritingReview(
                sourceText: review.sourceText,
                suggestedText: review.suggestedText,
                issues: review.issues,
                status: "Corrected \(report.appliedCount) issues · \(report.rejectedCount) suggestions ignored for safety"
            )
        }
        return ExternalReviewOutcome(report: report, review: review)
    }

    private func runExternalEnsemble(
        source: String,
        protected: StealthProtectedText,
        configuration: DeveloperGrammarConfiguration,
        operationID: UUID,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<WritingReview, Error>) -> Void
    ) {
        externalGrammarTask = Task { [weak self] in
            guard let self else { return }
            do {
                let strategy = SettingsStore.shared.grammarEnsembleStrategy
                var result = try await self.ensembleCoordinator.run(
                    contextText: protected.contextText,
                    source: source,
                    protected: protected,
                    configuration: configuration,
                    strategy: strategy,
                    systemPrompt: self.externalSystemPrompt,
                    useJudgeOnDisagreement: SettingsStore.shared.grammarJudgeOnDisagreement
                )

                // A disagreement with no edit-level consensus is retried once
                // with the same controlled ensemble. This is deliberately an
                // operation-level retry, not one retry per candidate.
                if result.hasProposals && result.report.appliedCount == 0 {
                    guard self.operationID == operationID else { return }
                    progress("Validating External Grammar ensemble… retrying once")
                    result = try await self.ensembleCoordinator.run(
                        contextText: protected.contextText,
                        source: source,
                        protected: protected,
                        configuration: configuration,
                        strategy: strategy,
                        systemPrompt: self.externalSystemPrompt + "\nThe prior ensemble had no safe edit-level consensus. Be more conservative and return only corrections supported by the supplied document.",
                        useJudgeOnDisagreement: SettingsStore.shared.grammarJudgeOnDisagreement
                    )
                }

                guard self.operationID == operationID else { return }
                guard !result.hasProposals || result.report.appliedCount > 0 else {
                    throw StealthGrammarRemoteClient.ClientError.safetyRejected
                }
                let outcome = try self.externalReview(source: source, report: result.report)
                self.finish(success: true, output: outcome.review.suggestedText.count)
                self.externalGrammarTask = nil
                completion(.success(outcome.review))
            } catch is CancellationError {
                // cancel() invalidates operationID; do not publish a stale
                // completion or overwrite the cancellation usage record.
            } catch {
                guard self.operationID == operationID else { return }
                self.externalGrammarTask = nil
                self.finishExternalFailure(error, completion: completion)
            }
        }
    }

    private func finishExternalFailure(
        _ error: Error,
        completion: @escaping (Result<WritingReview, Error>) -> Void
    ) {
        finish(success: false, detail: error.localizedDescription)
        completion(.failure(error))
    }

    private func runLocalReview(
        source: String,
        protected: StealthProtectedText,
        operationID: UUID,
        progress: @escaping (String) -> Void,
        status: String?,
        completion: @escaping (Result<WritingReview, Error>) -> Void
    ) {
        progress("Checking locally…")
        runPython(protected.maskedText, mode: "standard") { [weak self] pythonResult in
            guard let self, self.operationID == operationID else { return }
            let spelled = (try? pythonResult.get()) ?? protected.maskedText
            progress("Applying local grammar rules…")
            self.runHarper(spelled) { [weak self] harperResult in
                guard let self, self.operationID == operationID else { return }
                do {
                    let correctedMasked: String
                    switch harperResult {
                    case .success(let value) where protected.restore(value) != nil:
                        correctedMasked = value
                    case .success:
                        correctedMasked = spelled
                    case .failure where spelled != protected.maskedText:
                        correctedMasked = spelled
                    case .failure(let error):
                        throw error
                    }
                    let normalized = self.reviewer.normalizeProofreadRewrite(correctedMasked)
                    let corrected = protected.restore(normalized) ?? source
                    self.completeLocalReview(
                        source: source,
                        rewrittenText: corrected,
                        operationID: operationID,
                        status: status,
                        completion: completion
                    )
                } catch {
                    self.finish(success: false, detail: error.localizedDescription)
                    completion(.failure(error))
                }
            }
        }
    }

    private func completeLocalReview(
        source: String,
        rewrittenText: String,
        operationID: UUID,
        status: String?,
        completion: @escaping (Result<WritingReview, Error>) -> Void
    ) {
        guard self.operationID == operationID else { return }
        do {
            var review = try reviewer.review(
                sourceText: source,
                rewrittenText: rewrittenText,
                engineTitle: "Python + Harper"
            )
            if let status {
                review = WritingReview(
                    sourceText: review.sourceText,
                    suggestedText: review.suggestedText,
                    issues: review.issues,
                    status: status
                )
            }
            finish(success: true, output: rewrittenText.count)
            completion(.success(review))
        } catch {
            finish(success: false, detail: error.localizedDescription)
            completion(.failure(error))
        }
    }

    /// A deliberately conservative, no-review correction pass. High-risk text
    /// is replaced with opaque tokens before either local engine sees it, then
    /// restored only if every protected value survives byte-for-byte.
    func checkStealth(
        _ source: String,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        cancel()
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(.failure(WritingCheckService.CheckError.emptyText))
            return
        }
        guard source.count <= reviewer.characterLimit else {
            completion(.failure(WritingCheckService.CheckError.textTooLong(reviewer.characterLimit)))
            return
        }
        usageID = UsageMonitor.shared.begin(
            category: .writing,
            operation: "Stealth grammar correction",
            performance: SettingsStore.shared.runtimeWritingPerformance,
            inputCharacters: source.count
        )
        let operationID = UUID()
        self.operationID = operationID
        let protected = StealthGrammarService.protect(
            source,
            ignoreList: SettingsStore.shared.writingInstructions
        )
        if SettingsStore.shared.grammarEngineMode == .externalAPI {
            guard let configuration = SettingsStore.shared.developerGrammarConfiguration else {
                let error = StealthGrammarRemoteClient.ClientError.invalidConfiguration
                finish(success: false, detail: error.localizedDescription)
                completion(.failure(error))
                return
            }
            progress("Checking with External Grammar ensemble…")
            runExternalStealthEnsemble(
                source: source,
                protected: protected,
                configuration: configuration,
                operationID: operationID,
                progress: progress,
                completion: completion
            )
            return
        }

        runLocalStealth(source: source, protected: protected, operationID: operationID, progress: progress, completion: completion)
    }

    private struct ExternalStealthOutcome {
        let report: StealthGrammarApplyReport
        let text: String
    }

    private func externalStealthReplacement(
        source: String,
        report: StealthGrammarApplyReport
    ) throws -> ExternalStealthOutcome {
        guard StealthGrammarService.isSafeReplacement(source, report.text) else {
            throw StealthGrammarRemoteClient.ClientError.safetyRejected
        }
        return ExternalStealthOutcome(report: report, text: report.text)
    }

    private func runExternalStealthEnsemble(
        source: String,
        protected: StealthProtectedText,
        configuration: DeveloperGrammarConfiguration,
        operationID: UUID,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        externalGrammarTask = Task { [weak self] in
            guard let self else { return }
            do {
                let strategy = SettingsStore.shared.grammarEnsembleStrategy
                var result = try await self.ensembleCoordinator.run(
                    contextText: protected.contextText,
                    source: source,
                    protected: protected,
                    configuration: configuration,
                    strategy: strategy,
                    systemPrompt: self.externalSystemPrompt,
                    useJudgeOnDisagreement: SettingsStore.shared.grammarJudgeOnDisagreement
                )
                if result.hasProposals && result.report.appliedCount == 0 {
                    guard self.operationID == operationID else { return }
                    progress("Validating External Grammar ensemble… retrying once")
                    result = try await self.ensembleCoordinator.run(
                        contextText: protected.contextText,
                        source: source,
                        protected: protected,
                        configuration: configuration,
                        strategy: strategy,
                        systemPrompt: self.externalSystemPrompt + "\nThe prior ensemble had no safe edit-level consensus. Be more conservative and return only corrections supported by the supplied document.",
                        useJudgeOnDisagreement: SettingsStore.shared.grammarJudgeOnDisagreement
                    )
                }
                guard self.operationID == operationID else { return }
                guard !result.hasProposals || result.report.appliedCount > 0 else {
                    throw StealthGrammarRemoteClient.ClientError.safetyRejected
                }
                let outcome = try self.externalStealthReplacement(source: source, report: result.report)
                self.finish(success: true, output: outcome.text.count)
                self.externalGrammarTask = nil
                completion(.success(outcome.text))
            } catch is CancellationError {
                // The parent task is cancelled by cancel(); its operation ID
                // is invalidated before any stale result can be delivered.
            } catch {
                guard self.operationID == operationID else { return }
                self.externalGrammarTask = nil
                finish(success: false, detail: error.localizedDescription)
                completion(.failure(error))
            }
        }
    }

    private func runLocalStealth(
        source: String,
        protected: StealthProtectedText,
        operationID: UUID,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        progress("Editing locally…")
        runPython(protected.maskedText, mode: "stealth") { [weak self] pythonResult in
            guard let self, self.operationID == operationID else { return }
            do {
                let correctedMasked: String
                switch pythonResult {
                case .success(let value) where protected.restore(value) != nil:
                    correctedMasked = value
                case .success, .failure:
                    correctedMasked = protected.maskedText
                }
                guard let corrected = protected.restore(correctedMasked),
                      StealthGrammarService.isSafeReplacement(source, corrected) else {
                    throw WritingCheckService.CheckError.invalidProviderResponse
                }
                self.finish(success: true, output: corrected.count)
                completion(.success(corrected))
            } catch {
                self.finish(success: false, detail: error.localizedDescription)
                completion(.failure(error))
            }
        }
    }

    private func runPython(
        _ text: String,
        mode: String = "standard",
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
              let script = resourceURL("grammar_check.py", in: "Tools/PythonGrammar")
                ?? developmentURL("Packaging/Vendor/PythonGrammar/grammar_check.py") else {
            completion(.failure(CheckerError.missingResources))
            return
        }
        let payload: [String: String] = [
            "text": text,
            "preserve": SettingsStore.shared.writingInstructions,
            "mode": mode
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(.failure(CheckerError.processFailed("Could not prepare the grammar check.")))
            return
        }
        run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path], input: data) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let output):
                guard output.status == 0 else { completion(.failure(CheckerError.processFailed(output.stderr))); return }
                let value = String(decoding: output.stdout, as: UTF8.self)
                completion(value.isEmpty ? .failure(CheckerError.processFailed("The spelling pass returned no text.")) : .success(value))
            }
        }
    }

    private func runHarper(_ text: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let executable = resourceURL("harper-cli", in: "Tools")
                ?? developmentURL("Packaging/Vendor/Harper/harper-cli") else {
            completion(.failure(CheckerError.missingResources))
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
        run(executable: executable, arguments: arguments, input: Data(text.utf8)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let output):
                guard output.status == 0 || output.status == 1 else {
                    completion(.failure(CheckerError.processFailed(output.stderr)))
                    return
                }
                do {
                    let review = try self.reviewer.review(sourceText: text, harperJSON: output.stdout)
                    completion(.success(review.suggestedText))
                } catch { completion(.failure(error)) }
            }
        }
    }

    private func run(
        executable: URL,
        arguments: [String],
        input: Data,
        completion: @escaping (Result<Output, Error>) -> Void
    ) {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LANG": "en_US.UTF-8",
            "PYTHONDONTWRITEBYTECODE": "1"
        ]
        do {
            try process.run()
            activeProcess = process
        } catch {
            completion(.failure(error))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            inputPipe.fileHandleForWriting.write(input)
            try? inputPipe.fileHandleForWriting.close()
            let group = DispatchGroup()
            var stdout = Data()
            var stderr = Data()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                stdout = outputPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                stderr = errorPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            process.waitUntilExit()
            group.wait()
            let result = Output(
                status: process.terminationStatus,
                stdout: stdout,
                stderr: String(decoding: stderr.prefix(32_000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            )
            DispatchQueue.main.async { [weak self] in
                if self?.activeProcess === process { self?.activeProcess = nil }
                completion(.success(result))
            }
        }
    }

    private func resourceURL(_ name: String, in directory: String) -> URL? {
        let url = Bundle.main.resourceURL?.appendingPathComponent(directory, isDirectory: true).appendingPathComponent(name)
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    private func developmentURL(_ path: String) -> URL? {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func finish(success: Bool, output: Int = 0, detail: String? = nil) {
        operationID = nil
        guard let usageID else { return }
        self.usageID = nil
        UsageMonitor.shared.finish(usageID, succeeded: success, outputCharacters: output, detail: detail)
    }
}
