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
                return "The on-device transcription engine is missing. Reinstall Lima to restore dictation."
            case .processFailed(let detail):
                return detail.isEmpty ? "The on-device transcription engine could not transcribe the recording." : detail
            case .emptyTranscript:
                return "No recognizable speech was found in the recording."
            }
        }
    }

    private struct Resources {
        let executable: URL
        let model: URL
        let supportsSpeakerTurns: Bool
    }

    private struct TimedSegment {
        let startMilliseconds: Int
        let endMilliseconds: Int
        let text: String
        let speakerTurnAfter: Bool
    }

    private var activeProcess: Process?
    private var launchingProcess: Process?
    private var jobIdentifier: UUID?
    private var scratchURLs: [URL] = []

    func cancel() {
        jobIdentifier = nil
        if activeProcess?.isRunning == true { activeProcess?.terminate() }
        if launchingProcess?.isRunning == true { launchingProcess?.terminate() }
        activeProcess = nil
        launchingProcess = nil
        cleanupScratch()
    }

    func transcribe(
        audioURL: URL,
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
        let normalizedDestination = ApplicationPaths.dictationScratch.appendingPathComponent("room-normalized-\(identifier.uuidString).wav")
        let outputBase = ApplicationPaths.dictationScratch.appendingPathComponent("whisper-output-\(identifier.uuidString)")
        let outputURL = outputBase.appendingPathExtension("json")
        scratchURLs.append(outputURL)
        let compute = SettingsStore.shared.dictationComputeMode

        func attempt(normalizedAudio: URL, useGPU: Bool, allowFallback: Bool) {
            guard self.jobIdentifier == identifier else { return }
            progress("Transcribing…")
            var arguments = [
                "-m", resources.model.path,
                "-f", normalizedAudio.path,
                "--threads", String(performance.threadLimit),
                "--language", "en",
                "--output-json-full",
                "--output-file", outputBase.path,
                "--no-prints",
                "--suppress-nst",
                "--split-on-word",
                "--max-len", "120",
                "--beam-size", "5",
                "--best-of", "5",
                "--no-speech-thold", "0.82",
                "--logprob-thold", "-1.35"
            ]
            if resources.supportsSpeakerTurns { arguments.append("--tinydiarize") }
            if !useGPU { arguments.append("--no-gpu") }
            if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                arguments += ["--prompt", String(prompt.prefix(240))]
            }
            self.runProcess(executable: resources.executable, arguments: arguments, performance: performance) { [weak self] result in
                guard let self, self.jobIdentifier == identifier else { return }
                switch result {
                case .failure(let error):
                    if allowFallback {
                        progress("Retrying transcription…")
                        attempt(normalizedAudio: normalizedAudio, useGPU: false, allowFallback: false)
                    } else { self.finish(.failure(error), completion: completion) }
                case .success(let processOutput):
                    guard processOutput.status == 0 else {
                        if allowFallback {
                            progress("Retrying transcription…")
                            attempt(normalizedAudio: normalizedAudio, useGPU: false, allowFallback: false)
                        } else {
                            self.finish(.failure(TranscriptionError.processFailed(processOutput.stderr)), completion: completion)
                        }
                        return
                    }
                    DispatchQueue.global(qos: .utility).async {
                        let transcript = (try? Data(contentsOf: outputURL)).flatMap(Self.formattedTranscript(from:))
                        DispatchQueue.main.async {
                            guard self.jobIdentifier == identifier else { return }
                            guard let transcript, !transcript.isEmpty else {
                                self.finish(.failure(TranscriptionError.emptyTranscript), completion: completion)
                                return
                            }
                            self.finish(.success(transcript), completion: completion)
                        }
                    }
                }
            }
        }

        // A PCM segment can be many megabytes. Reading and scanning it on the
        // main actor made every dictation destination appear frozen at rollover.
        DispatchQueue.global(qos: .utility).async {
            let prepared = Self.normalizedRoomAudio(from: audioURL, destination: normalizedDestination)
            DispatchQueue.main.async {
                guard self.jobIdentifier == identifier else {
                    if let prepared { try? FileManager.default.removeItem(at: prepared) }
                    return
                }
                if let prepared { self.scratchURLs.append(prepared) }
                let normalizedAudio = prepared ?? audioURL
                switch compute {
                case .cpu: attempt(normalizedAudio: normalizedAudio, useGPU: false, allowFallback: false)
                case .metal: attempt(normalizedAudio: normalizedAudio, useGPU: true, allowFallback: false)
                case .automatic: attempt(normalizedAudio: normalizedAudio, useGPU: true, allowFallback: true)
                }
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

        // Process.run can synchronously wait for macOS process setup. Keep even
        // launch off the main actor so dictation never stalls its destination UI.
        launchingProcess = process
        let lock = NSLock()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                try process.run()
            } catch {
                DispatchQueue.main.async {
                    guard self?.launchingProcess === process else { return }
                    self?.launchingProcess = nil
                    completion(.failure(error))
                }
                return
            }
            DispatchQueue.main.async {
                guard self?.launchingProcess === process else {
                    if process.isRunning { process.terminate() }
                    return
                }
                self?.launchingProcess = nil
                self?.activeProcess = process
            }
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
            let detail = String(decoding: stderrData.suffix(64_000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            lock.unlock()
            DispatchQueue.main.async { [weak self] in
                if self?.activeProcess === process { self?.activeProcess = nil }
                completion(.success(ProcessOutput(status: process.terminationStatus, stderr: detail)))
            }
        }
    }

    private nonisolated static func formattedTranscript(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawSegments = root["transcription"] as? [[String: Any]] else { return nil }
        let segments = rawSegments.compactMap { item -> TimedSegment? in
            guard var text = item["text"] as? String else { return nil }
            let marker = "[SPEAKER_TURN]"
            let markedTurn = text.contains(marker)
            text = text.replacingOccurrences(of: marker, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let offsets = item["offsets"] as? [String: Any]
            let from = Self.integer(offsets?["from"]) ?? 0
            let to = Self.integer(offsets?["to"]) ?? from
            let directTurn = item["speaker_turn_next"] as? Bool ?? false
            let tokenTurn = (item["tokens"] as? [[String: Any]])?.contains {
                ($0["text"] as? String)?.contains("SPEAKER_TURN") == true
                    || ($0["id"] as? Int) == 50_364
            } ?? false
            return TimedSegment(startMilliseconds: from, endMilliseconds: to, text: text, speakerTurnAfter: markedTurn || directTurn || tokenTurn)
        }
        guard !segments.isEmpty else { return nil }

        let hasSpeakerTurns = segments.contains(where: \.speakerTurnAfter)
        var speaker = 1
        var paragraphs: [String] = []
        var current = ""
        var priorEnd = 0

        func flush() {
            let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { paragraphs.append(value) }
            current = ""
        }

        for segment in segments {
            let gap = segment.startMilliseconds - priorEnd
            if gap >= 1_100 { flush() }
            if current.isEmpty, hasSpeakerTurns { current = "**Speaker \(speaker):** " }
            if !current.isEmpty, !current.hasSuffix(" ") { current += " " }
            current += segment.text
            priorEnd = segment.endMilliseconds
            if segment.speakerTurnAfter {
                flush()
                speaker = speaker == 1 ? 2 : 1
            }
        }
        flush()
        return paragraphs.joined(separator: "\n\n")
    }

    /// Quiet room microphones often produce valid speech at a low level. This
    /// normalizes only the PCM sample payload, never compresses it, and caps gain
    /// to avoid clipping or amplifying near-silence into noise.
    private nonisolated static func normalizedRoomAudio(from source: URL, destination: URL) -> URL? {
        guard var data = try? Data(contentsOf: source), data.count > 48,
              let dataRange = Self.waveDataRange(in: data) else { return nil }
        var sumSquares = 0.0
        var peak = 0
        var count = 0
        var offset = dataRange.lowerBound
        while offset + 1 < dataRange.upperBound {
            let raw = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            let sample = Int(Int16(bitPattern: raw))
            peak = max(peak, abs(sample))
            sumSquares += Double(sample * sample)
            count += 1
            offset += 2
        }
        guard count > 0, peak > 24 else { return nil }
        let rms = sqrt(sumSquares / Double(count))
        guard rms > 18, rms < 3_600 else { return nil }
        let gain = min(7.5, min(30_000 / Double(peak), 3_600 / rms))
        guard gain > 1.12 else { return nil }
        offset = dataRange.lowerBound
        while offset + 1 < dataRange.upperBound {
            let raw = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            let sample = Double(Int(Int16(bitPattern: raw))) * gain
            let adjusted = Int16(max(-32_000, min(32_000, sample)).rounded())
            let encoded = UInt16(bitPattern: adjusted)
            data[offset] = UInt8(encoded & 0xff)
            data[offset + 1] = UInt8(encoded >> 8)
            offset += 2
        }
        do {
            try data.write(to: destination, options: .atomic)
            return destination
        } catch { return nil }
    }

    private nonisolated static func waveDataRange(in data: Data) -> Range<Int>? {
        guard data.count >= 12, String(decoding: data[0..<4], as: UTF8.self) == "RIFF" else { return nil }
        var offset = 12
        while offset + 8 <= data.count {
            let name = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            let size = Int(data[offset + 4]) | (Int(data[offset + 5]) << 8) | (Int(data[offset + 6]) << 16) | (Int(data[offset + 7]) << 24)
            let start = offset + 8
            let end = min(data.count, start + size)
            if name == "data", end > start { return start..<end }
            offset = start + size + (size.isMultiple(of: 2) ? 0 : 1)
        }
        return nil
    }

    private nonisolated static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func finish(_ result: Result<String, Error>, completion: @escaping (Result<String, Error>) -> Void) {
        jobIdentifier = nil
        activeProcess = nil
        cleanupScratch()
        completion(result)
    }

    private func cleanupScratch() {
        for url in scratchURLs { try? FileManager.default.removeItem(at: url) }
        scratchURLs.removeAll()
    }

    private func resources() -> Resources? {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Whisper", isDirectory: true) else { return nil }
        let executable = root.appendingPathComponent("runtime/whisper-cli")
        let tdrz = root.appendingPathComponent("model/ggml-small.en-tdrz.bin")
        let standard = root.appendingPathComponent("model/ggml-small.en.bin")
        let cached = ApplicationPaths.applicationSupport.appendingPathComponent("Whisper/model/ggml-small.en-tdrz.bin")
        guard let model = [tdrz, cached, standard].first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        guard FileManager.default.isExecutableFile(atPath: executable.path), FileManager.default.fileExists(atPath: model.path) else { return nil }
        return Resources(executable: executable, model: model, supportsSpeakerTurns: model.lastPathComponent.contains("tdrz"))
    }
}
