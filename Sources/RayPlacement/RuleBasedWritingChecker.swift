@preconcurrency import Foundation
import RayPlacementWriting

@MainActor
final class RuleBasedWritingChecker {
    enum CheckerError: LocalizedError {
        case missingResources
        case processFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingResources: return "The local grammar resources are missing. Reinstall LiamFlow."
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
    private var activeProcess: Process?
    private var usageID: UUID?

    func cancel() {
        if activeProcess?.isRunning == true { activeProcess?.terminate() }
        activeProcess = nil
        if let usageID {
            UsageMonitor.shared.finish(usageID, succeeded: false, detail: "Cancelled")
            self.usageID = nil
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
        progress("Checking spelling locally…")
        runPython(source) { [weak self] pythonResult in
            guard let self else { return }
            let spelled: String
            switch pythonResult {
            case .success(let value): spelled = value
            case .failure: spelled = self.reviewer.normalizeProofreadRewrite(source)
            }
            progress("Applying grammar and style rules…")
            self.runHarper(spelled) { [weak self] harperResult in
                guard let self else { return }
                do {
                    let corrected: String
                    switch harperResult {
                    case .success(let value): corrected = value
                    case .failure where spelled != source: corrected = spelled
                    case .failure(let error): throw error
                    }
                    let normalized = self.reviewer.normalizeProofreadRewrite(corrected, preservingBoundaryFrom: source)
                    let review = try self.reviewer.review(
                        sourceText: source,
                        rewrittenText: normalized,
                        engineTitle: "Python + Harper"
                    )
                    self.finish(success: true, output: normalized.count)
                    completion(.success(review))
                } catch {
                    self.finish(success: false, detail: error.localizedDescription)
                    completion(.failure(error))
                }
            }
        }
    }

    private func runPython(_ text: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
              let script = resourceURL("grammar_check.py", in: "Tools/PythonGrammar")
                ?? developmentURL("Packaging/Vendor/PythonGrammar/grammar_check.py") else {
            completion(.failure(CheckerError.missingResources))
            return
        }
        let payload: [String: String] = [
            "text": text,
            "preserve": SettingsStore.shared.writingInstructions
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
        guard let usageID else { return }
        self.usageID = nil
        UsageMonitor.shared.finish(usageID, succeeded: success, outputCharacters: output, detail: detail)
    }
}
