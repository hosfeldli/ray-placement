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
    private var activeProcess: Process?
    private var remoteTask: URLSessionDataTask?
    private var usageID: UUID?
    private var operationID: UUID?

    func cancel() {
        operationID = nil
        if activeProcess?.isRunning == true { activeProcess?.terminate() }
        activeProcess = nil
        remoteTask?.cancel()
        remoteTask = nil
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
            operation: "Rule-based spelling and grammar",
            performance: SettingsStore.shared.runtimeWritingPerformance,
            inputCharacters: source.count
        )
        let operationID = UUID()
        self.operationID = operationID
        let protected = StealthGrammarService.protect(
            source,
            ignoreList: SettingsStore.shared.writingInstructions
        )
        progress("Checking spelling locally…")
        runPython(protected.maskedText, mode: "standard") { [weak self] pythonResult in
            guard let self, self.operationID == operationID else { return }
            let spelled: String
            switch pythonResult {
            case .success(let value): spelled = value
            case .failure: spelled = protected.maskedText
            }
            progress("Applying grammar and style rules…")
            self.runHarper(spelled) { [weak self] harperResult in
                guard let self, self.operationID == operationID else { return }
                do {
                    let correctedMasked: String
                    switch harperResult {
                    case .success(let value) where protected.restore(value) != nil: correctedMasked = value
                    case .success: correctedMasked = spelled
                    case .failure where spelled != protected.maskedText: correctedMasked = spelled
                    case .failure(let error): throw error
                    }
                    let normalizedMasked = self.reviewer.normalizeProofreadRewrite(correctedMasked)
                    let localNormalized = protected.restore(normalizedMasked) ?? source
                    guard SettingsStore.shared.developerGrammarEnabled else {
                        self.completeLocalReview(
                            source: source,
                            rewrittenText: localNormalized,
                            operationID: operationID,
                            status: nil,
                            completion: completion
                        )
                        return
                    }
                    guard let configuration = SettingsStore.shared.developerGrammarConfiguration else {
                        if SettingsStore.shared.grammarFallbackToLocal {
                            self.completeLocalReview(
                                source: source,
                                rewrittenText: localNormalized,
                                operationID: operationID,
                                status: "Enhanced check unavailable · Local result shown.",
                                completion: completion
                            )
                        } else {
                            let error = StealthGrammarRemoteClient.ClientError.invalidConfiguration
                            self.finish(success: false, detail: error.localizedDescription)
                            completion(.failure(error))
                        }
                        return
                    }
                    progress("Applying Enhanced Grammar…")
                    self.remoteTask = self.remoteClient.correct(normalizedMasked, configuration: configuration) { [weak self] remoteResult in
                        guard let self, self.operationID == operationID else { return }
                        self.remoteTask = nil
                        switch remoteResult {
                        case .success(let remoteText):
                            let candidate = self.reviewer.normalizeProofreadRewrite(remoteText)
                            if let enhanced = protected.restore(candidate),
                               StealthGrammarService.isSafeReplacement(source, enhanced) {
                                do {
                                    let review = try self.reviewer.review(sourceText: source, rewrittenText: enhanced, engineTitle: "Enhanced Grammar")
                                    self.finish(success: true, output: enhanced.count)
                                    completion(.success(review))
                                } catch {
                                    self.finish(success: false, detail: error.localizedDescription)
                                    completion(.failure(error))
                                }
                            } else if SettingsStore.shared.grammarFallbackToLocal {
                                self.completeLocalReview(source: source, rewrittenText: localNormalized, operationID: operationID, status: "Enhanced check unavailable · Local result shown.", completion: completion)
                            } else {
                                let error = WritingCheckService.CheckError.invalidProviderResponse
                                self.finish(success: false, detail: error.localizedDescription)
                                completion(.failure(error))
                            }
                        case .failure(let error):
                            if SettingsStore.shared.grammarFallbackToLocal {
                                self.completeLocalReview(source: source, rewrittenText: localNormalized, operationID: operationID, status: "Enhanced check unavailable · Local result shown.", completion: completion)
                            } else {
                                self.finish(success: false, detail: error.localizedDescription)
                                completion(.failure(error))
                            }
                        }
                    }
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
        if SettingsStore.shared.developerGrammarEnabled {
            guard let configuration = SettingsStore.shared.developerGrammarConfiguration else {
                if SettingsStore.shared.grammarFallbackToLocal {
                    progress("Enhanced check unavailable · Local result shown.")
                    runLocalStealth(source: source, protected: protected, operationID: operationID, progress: progress, completion: completion)
                } else {
                    let error = StealthGrammarRemoteClient.ClientError.invalidConfiguration
                    finish(success: false, detail: error.localizedDescription)
                    completion(.failure(error))
                }
                return
            }
            progress("Checking with Enhanced Grammar…")
            remoteTask = remoteClient.correct(
                protected.maskedText,
                configuration: configuration
            ) { [weak self] result in
                guard let self, self.operationID == operationID else { return }
                self.remoteTask = nil
                switch result {
                case .success(let correctedMasked):
                    guard let corrected = protected.restore(self.reviewer.normalizeProofreadRewrite(correctedMasked)),
                          StealthGrammarService.isSafeReplacement(source, corrected) else {
                        if SettingsStore.shared.grammarFallbackToLocal {
                            progress("Enhanced check unavailable · Local result shown.")
                            self.runLocalStealth(source: source, protected: protected, operationID: operationID, progress: progress, completion: completion)
                        } else {
                            let error = WritingCheckService.CheckError.invalidProviderResponse
                            self.finish(success: false, detail: error.localizedDescription)
                            completion(.failure(error))
                        }
                        return
                    }
                    self.finish(success: true, output: corrected.count)
                    completion(.success(corrected))
                case .failure(let error):
                    if SettingsStore.shared.grammarFallbackToLocal {
                        progress("Enhanced check unavailable · Local result shown.")
                        self.runLocalStealth(source: source, protected: protected, operationID: operationID, progress: progress, completion: completion)
                    } else {
                        self.finish(success: false, detail: error.localizedDescription)
                        completion(.failure(error))
                    }
                }
            }
            return
        }

        runLocalStealth(source: source, protected: protected, operationID: operationID, progress: progress, completion: completion)
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
