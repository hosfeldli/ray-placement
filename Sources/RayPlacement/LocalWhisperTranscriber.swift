@preconcurrency import Dispatch
import Foundation

@MainActor
final class LocalWhisperTranscriber {
    enum TranscriptionError: LocalizedError {
        case assetsMissing
        case processFailed(String)
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case .assetsMissing:
                return "The bundled Local Whisper runtime is missing. Reinstall RayPlacement to restore meeting transcription."
            case .processFailed(let detail):
                return detail.isEmpty ? "Local Whisper could not transcribe the meeting audio." : detail
            case .emptyTranscript:
                return "Local Whisper found no recognizable speech in the recording."
            }
        }
    }

    private var activeProcess: Process?
    private var jobIdentifier: UUID?
    private var scratchURLs: [URL] = []

    func cancel() {
        jobIdentifier = nil
        if activeProcess?.isRunning == true { activeProcess?.terminate() }
        activeProcess = nil
        cleanupScratch()
    }

    func transcribe(
        audioURL: URL,
        audioDuration: TimeInterval,
        prompt: String?,
        performance: PerformanceScale,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        cancel()
        guard let resources = resources() else {
            completion(.failure(TranscriptionError.assetsMissing))
            return
        }

        let identifier = UUID()
        jobIdentifier = identifier
        let outputBase = ApplicationPaths.dictationScratch
            .appendingPathComponent("whisper-output-\(identifier.uuidString)")
        let outputURL = outputBase.appendingPathExtension("txt")
        scratchURLs = [outputURL]
        progress("Local Whisper is transcribing the completed recording…")
        var arguments = [
            "-m", resources.model.path,
            "-f", audioURL.path,
            "--threads", String(performance.threadLimit),
            "--language", "en",
            "--output-txt",
            "--output-file", outputBase.path,
            "--no-prints",
            "--no-timestamps",
            "--no-gpu",
            "--suppress-nst",
            "--beam-size", "5",
            "--best-of", "5",
            "--no-speech-thold", "0.72"
        ]
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["--prompt", String(prompt.prefix(240))]
        }
        runProcess(
            executable: resources.executable,
            arguments: arguments,
            performance: performance
        ) { [weak self] result in
            guard let self, self.jobIdentifier == identifier else { return }
            switch result {
            case .failure(let error):
                self.finish(.failure(error), completion: completion)
            case .success(let processOutput):
                guard processOutput.status == 0 else {
                    self.finish(.failure(TranscriptionError.processFailed(processOutput.stderr)), completion: completion)
                    return
                }
                let transcript = (try? String(contentsOf: outputURL, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !transcript.isEmpty else {
                    self.finish(.failure(TranscriptionError.emptyTranscript), completion: completion)
                    return
                }
                self.finish(.success(transcript), completion: completion)
            }
        }
    }

    private struct ProcessOutput {
        let status: Int32
        let stderr: String
    }

    private func runProcess(
        executable: URL,
        arguments: [String],
        performance: PerformanceScale,
        completion: @escaping (Result<ProcessOutput, Error>) -> Void
    ) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        process.qualityOfService = performance.qualityOfService
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LANG": "en_US.UTF-8",
            "OMP_NUM_THREADS": String(performance.threadLimit),
            "OMP_THREAD_LIMIT": String(performance.threadLimit),
            "VECLIB_MAXIMUM_THREADS": String(performance.threadLimit)
        ]

        do {
            try process.run()
            activeProcess = process
        } catch {
            completion(.failure(error))
            return
        }

        let lock = NSLock()
        DispatchQueue.global(qos: .utility).async {
            let group = DispatchGroup()
            var stderrData = Data()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                _ = stdout.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = stderr.fileHandleForReading.readDataToEndOfFile()
                lock.lock(); stderrData = data; lock.unlock()
                group.leave()
            }
            process.waitUntilExit()
            group.wait()
            lock.lock()
            let detail = String(decoding: stderrData.suffix(64_000), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lock.unlock()
            DispatchQueue.main.async { [weak self] in
                if self?.activeProcess === process { self?.activeProcess = nil }
                completion(.success(ProcessOutput(status: process.terminationStatus, stderr: detail)))
            }
        }
    }

    private func finish(
        _ result: Result<String, Error>,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        jobIdentifier = nil
        activeProcess = nil
        cleanupScratch()
        completion(result)
    }

    private func cleanupScratch() {
        for url in scratchURLs { try? FileManager.default.removeItem(at: url) }
        scratchURLs.removeAll()
    }

    private func resources() -> (executable: URL, model: URL)? {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Whisper", isDirectory: true) else {
            return nil
        }
        let executable = root.appendingPathComponent("runtime/whisper-cli")
        let model = root.appendingPathComponent("model/ggml-small.en.bin")
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              FileManager.default.fileExists(atPath: model.path) else { return nil }
        return (executable, model)
    }
}
