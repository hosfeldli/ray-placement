@preconcurrency import Foundation
import Darwin
import RayPlacementWriting

/// Local writing correction used by the public checkWriting action and live
/// writing surfaces. Harper is deliberately the only production engine here:
/// no Python runtime, network provider, prompt, ensemble, or judge is involved.
@MainActor
final class RuleBasedWritingChecker {
    enum CheckerError: LocalizedError {
        case missingResources
        case processFailed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .missingResources:
                return "The local writing checker is unavailable. Reinstall Lima."
            case .processFailed(let detail):
                return detail.isEmpty ? "The local writing checker failed." : detail
            case .timedOut:
                return "The local writing checker took too long to respond. Try again."
            }
        }
    }

    private struct Output {
        let status: Int32
        let stdout: Data
        let stderr: String
    }

    private let reviewer = WritingCheckService()
    private let api = StealthGrammarRemoteClient()
    private var activeProcess: Process?
    private var operationID: UUID?
    private var usageID: UUID?
    private let maximumCorrections = 100

    func cancel() {
        operationID = nil
        if let process = activeProcess, process.isRunning {
            process.terminate()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        activeProcess = nil
        if let usageID {
            UsageMonitor.shared.finish(usageID, succeeded: false, detail: "Cancelled")
            self.usageID = nil
        }
    }

    func checkLocal(
        _ source: String,
        progress: @escaping (String) -> Void = { _ in },
        completion: @escaping (Result<WritingReview, Error>) -> Void
    ) {
        start(source: source, progress: progress, completion: completion)
    }

    /// Compatibility façade for the existing writing-check callers. The
    /// production implementation is always local Harper, regardless of stale
    /// provider settings that may remain in older preference stores.
    func check(
        _ source: String,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<WritingReview, Error>) -> Void
    ) {
        start(source: source, progress: progress, completion: completion)
    }

    func checkStealth(
        _ source: String,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        cancel()
        guard validate(source) else {
            completion(.failure(WritingCheckService.CheckError.emptyText))
            return
        }
        beginUsage(for: source, operation: "Writing correction")
        let id = UUID()
        operationID = id
        correct(source: source, operationID: id, progress: progress) { [weak self] result in
            guard let self, self.operationID == id else { return }
            switch result {
            case .success(let corrected):
                self.finish(success: true, output: corrected.count)
                completion(.success(corrected))
            case .failure(let error):
                self.finish(success: false, detail: error.localizedDescription)
                completion(.failure(error))
            }
        }
    }

    private func start(
        source: String,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<WritingReview, Error>) -> Void
    ) {
        cancel()
        guard validate(source) else {
            completion(.failure(WritingCheckService.CheckError.emptyText))
            return
        }
        beginUsage(for: source, operation: "Writing check")
        let id = UUID()
        operationID = id
        correct(source: source, operationID: id, progress: progress) { [weak self] result in
            guard let self, self.operationID == id else { return }
            switch result {
            case .success(let corrected):
                do {
                    let review = try self.reviewer.review(
                        sourceText: source,
                        rewrittenText: corrected,
                        engineTitle: self.engineTitle
                    )
                    self.finish(success: true, output: corrected.count)
                    completion(.success(review))
                } catch {
                    self.finish(success: false, detail: error.localizedDescription)
                    completion(.failure(error))
                }
            case .failure(let error):
                self.finish(success: false, detail: error.localizedDescription)
                completion(.failure(error))
            }
        }
    }

    private func validate(_ source: String) -> Bool {
        !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && source.count <= reviewer.characterLimit
    }

    private func beginUsage(for source: String, operation: String) {
        usageID = UsageMonitor.shared.begin(
            category: .writing,
            operation: operation,
            performance: SettingsStore.shared.runtimeWritingPerformance,
            inputCharacters: source.count
        )
    }

    private var usesAPI: Bool {
        SettingsStore.shared.grammarEngineMode == .externalAPI
    }

    private var engineTitle: String {
        usesAPI ? "AI" : "Harper"
    }

    private func correct(
        source: String,
        operationID: UUID,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard operationID == self.operationID else { return }
        guard usesAPI else {
            progress("Checking locally…")
            correctIteratively(
                source: source,
                current: source,
                operationID: operationID,
                correctionCount: 0,
                progress: progress,
                completion: completion
            )
            return
        }

        guard let configuration = SettingsStore.shared.developerGrammarConfiguration else {
            if SettingsStore.shared.grammarFallbackToLocal {
                progress("AI unavailable · checking locally…")
                correctIteratively(
                    source: source,
                    current: source,
                    operationID: operationID,
                    correctionCount: 0,
                    progress: progress,
                    completion: completion
                )
            } else {
                completion(.failure(StealthGrammarRemoteClient.ClientError.invalidConfiguration))
            }
            return
        }

        progress("Fixing writing…")
        Task { [weak self] in
            guard let self else { return }
            do {
                var corrected = try await self.api.correctText(
                    source,
                    configuration: configuration,
                    systemPrompt: StealthGrammarRemoteClient.simpleCorrectionSystemPrompt
                )
                if !Self.isValidCorrection(original: source, corrected: corrected) {
                    throw StealthGrammarRemoteClient.ClientError.safetyRejected
                }
                corrected = self.reviewer.normalizeRewrite(corrected)
                guard Self.isValidCorrection(original: source, corrected: corrected) else {
                    throw StealthGrammarRemoteClient.ClientError.safetyRejected
                }
                guard self.operationID == operationID else { return }
                completion(.success(corrected))
            } catch {
                guard self.operationID == operationID else { return }
                if Self.isTransient(error: error) {
                    do {
                        let corrected = try await self.api.correctText(
                            source,
                            configuration: configuration,
                            systemPrompt: StealthGrammarRemoteClient.simpleCorrectionSystemPrompt
                        )
                        guard Self.isValidCorrection(original: source, corrected: corrected) else {
                            throw StealthGrammarRemoteClient.ClientError.safetyRejected
                        }
                        guard self.operationID == operationID else { return }
                        completion(.success(self.reviewer.normalizeRewrite(corrected)))
                        return
                    } catch {
                        // One retry only; optional local fallback handles the
                        // complete API failure without touching the selection.
                    }
                }
                if SettingsStore.shared.grammarFallbackToLocal {
                    progress("AI unavailable · checking locally…")
                    self.correctIteratively(
                        source: source,
                        current: source,
                        operationID: operationID,
                        correctionCount: 0,
                        progress: progress,
                        completion: completion
                    )
                } else {
                    completion(.failure(error))
                }
            }
        }
    }

    private static func isTransient(error: Error?) -> Bool {
        guard let error else { return false }
        switch error {
        case StealthGrammarRemoteClient.ClientError.requestFailed,
             StealthGrammarRemoteClient.ClientError.requestTimedOut:
            return true
        default:
            return false
        }
    }

    private static func isValidCorrection(original: String, corrected: String) -> Bool {
        guard !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let ratio = Double(corrected.count) / Double(max(original.count, 1))
        return ratio > 0.40 && ratio < 2.5
            && !StealthGrammarService.isChattyResponse(corrected)
    }

    private func correctIteratively(
        source: String,
        current: String,
        operationID: UUID,
        correctionCount: Int,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard self.operationID == operationID else { return }
        guard correctionCount < maximumCorrections else {
            completion(.success(current))
            return
        }

        runHarper(current) { [weak self] result in
            guard let self, self.operationID == operationID else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let review):
                // Only an unambiguous lint may be applied. Re-linting the whole
                // result after each edit avoids stale UTF-16 offsets and keeps
                // the final replacement atomic at the caller boundary.
                guard let issue = review.issues.first(where: {
                    $0.suggestions.count == 1
                        && $0.suggestions[0] != $0.original
                        && !$0.suggestions[0].contains("\n")
                }) else {
                    completion(.success(current))
                    return
                }
                let next = review.applying([issue.id]).suggestedText
                guard next != current else {
                    completion(.success(current))
                    return
                }
                progress("Correcting locally…")
                self.correctIteratively(
                    source: source,
                    current: next,
                    operationID: operationID,
                    correctionCount: correctionCount + 1,
                    progress: progress,
                    completion: completion
                )
            }
        }
    }

    private func runHarper(
        _ text: String,
        completion: @escaping (Result<WritingReview, Error>) -> Void
    ) {
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
            case .failure(let error):
                completion(.failure(error))
            case .success(let output):
                guard output.status == 0 || output.status == 1 else {
                    completion(.failure(CheckerError.processFailed(output.stderr)))
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
            "LANG": "en_US.UTF-8"
        ]
        do {
            try process.run()
            activeProcess = process
        } catch {
            completion(.failure(error))
            return
        }

        let timeout = DispatchWorkItem { [weak self, weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            if self?.activeProcess === process { self?.activeProcess = nil }
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3, execute: timeout)

        DispatchQueue.global(qos: .userInitiated).async {
            inputPipe.fileHandleForWriting.write(input)
            try? inputPipe.fileHandleForWriting.close()
            let stdout = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            let timedOut = process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL
            let output = Output(
                status: process.terminationStatus,
                stdout: stdout,
                stderr: timedOut
                    ? "The local writing checker timed out."
                    : String(decoding: stderr.prefix(32_000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            )
            DispatchQueue.main.async { [weak self] in
                if self?.activeProcess === process { self?.activeProcess = nil }
                completion(timedOut ? .failure(CheckerError.timedOut) : .success(output))
            }
        }
    }

    private func resourceURL(_ name: String, in directory: String) -> URL? {
        let url = Bundle.main.resourceURL?
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent(name)
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
