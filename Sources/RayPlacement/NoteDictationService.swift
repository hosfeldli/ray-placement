@preconcurrency import AVFoundation
import Foundation
import RayPlacementCore
@preconcurrency import Speech

@MainActor
final class NoteDictationService: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum Phase: Equatable {
        case idle
        case requestingPermission
        case recording
        case transcribing
    }

    enum DictationError: LocalizedError {
        case speechPermission
        case microphonePermission
        case onDeviceUnavailable
        case recorderUnavailable
        case transcriptionFailed(String)
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case .speechPermission:
                return "Allow RayPlacement under System Settings → Privacy & Security → Speech Recognition to dictate notes."
            case .microphonePermission:
                return "Allow RayPlacement under System Settings → Privacy & Security → Microphone to record dictation."
            case .onDeviceUnavailable:
                return "On-device speech recognition is unavailable for the current language. RayPlacement will not send note audio to a network service."
            case .recorderUnavailable:
                return "RayPlacement could not start the Mac's active microphone."
            case .transcriptionFailed(let detail):
                return detail.isEmpty ? "The recorded dictation could not be transcribed." : detail
            case .emptyTranscript:
                return "No speech was recognized in that recording."
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcriptionProgress: String?
    @Published var lastError: String?

    private let onTranscript: (String, UUID?) -> Void
    private var destinationNoteID: UUID?
    private var recorder: AVAudioRecorder?
    private var audioURL: URL?
    private var recordedDuration: TimeInterval = 0
    private var sourceAsset: AVURLAsset?
    private var activeExportSession: AVAssetExportSession?
    private var activeExportIdentifier: UUID?
    private var activeChunkURL: URL?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionIdentifier: UUID?
    private var transcriptionTimeout: DispatchWorkItem?
    private var activePerformance: PerformanceScale?
    private var currentChunkIndex = 0
    private var totalChunkCount = 0
    private var currentChunkRetryCount = 0
    private var chunkTranscripts: [String] = []
    private var skippedChunkCount = 0

    init(onTranscript: @escaping (String, UUID?) -> Void) {
        self.onTranscript = onTranscript
        super.init()
    }

    var actionTitle: String {
        switch phase {
        case .idle: return "Dictate"
        case .requestingPermission: return "Waiting for Permission…"
        case .recording: return "Stop & Transcribe"
        case .transcribing: return "Transcribing…"
        }
    }

    var statusText: String {
        switch phase {
        case .idle:
            return "Records only when requested, then transcribes after Stop."
        case .requestingPermission:
            return "Waiting for microphone and speech-recognition permission."
        case .recording:
            let seconds = activePerformance?.dictationMaximumDuration
                ?? SettingsStore.shared.dictationPerformance.dictationMaximumDuration
            return "Recording locally — maximum \(Self.durationLabel(seconds))."
        case .transcribing:
            return transcriptionProgress ?? "Preparing the completed recording for on-device transcription."
        }
    }

    func performPrimaryAction(destinationNoteID: UUID?) {
        switch phase {
        case .idle:
            self.destinationNoteID = destinationNoteID
            requestPermissionsAndStart()
        case .recording:
            stopAndTranscribe()
        case .requestingPermission, .transcribing:
            break
        }
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        activeExportSession?.cancelExport()
        activeExportSession = nil
        activeExportIdentifier = nil
        recognitionIdentifier = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        transcriptionTimeout?.cancel()
        transcriptionTimeout = nil
        cleanupAudioFiles()
        resetJobState()
        phase = .idle
    }

    private func requestPermissionsAndStart() {
        lastError = nil
        phase = .requestingPermission
        requestSpeechAuthorization { [weak self] speechGranted in
            guard let self else { return }
            guard speechGranted else {
                self.fail(DictationError.speechPermission)
                return
            }
            self.requestMicrophoneAuthorization { [weak self] microphoneGranted in
                guard let self else { return }
                guard microphoneGranted else {
                    self.fail(DictationError.microphonePermission)
                    return
                }
                self.startRecording()
            }
        }
    }

    private func requestSpeechAuthorization(_ completion: @escaping (Bool) -> Void) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            completion(true)
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { status in
                Task { @MainActor in completion(status == .authorized) }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    private func requestMicrophoneAuthorization(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in completion(granted) }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    private func startRecording() {
        do {
            try ApplicationPaths.prepare()
            cleanupAudioFiles()
            let destinationNoteID = destinationNoteID
            resetJobState()
            self.destinationNoteID = destinationNoteID
            let url = ApplicationPaths.dictationScratch
                .appendingPathComponent("note-dictation-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            let performance = SettingsStore.shared.dictationPerformance
            guard recorder.prepareToRecord(), recorder.record(forDuration: performance.dictationMaximumDuration) else {
                throw DictationError.recorderUnavailable
            }
            self.recorder = recorder
            activePerformance = performance
            audioURL = url
            phase = .recording
        } catch {
            fail(error)
        }
    }

    private func stopAndTranscribe() {
        guard phase == .recording, let recorder else { return }
        recordedDuration = max(recorder.currentTime, 0.1)
        recorder.stop()
        self.recorder = nil
        if phase == .recording { beginTranscriptionIfPossible() }
    }

    private func beginTranscriptionIfPossible() {
        guard phase == .recording, let url = audioURL else { return }
        phase = .transcribing

        guard let recognizer = SFSpeechRecognizer(locale: Locale.current),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            fail(DictationError.onDeviceUnavailable)
            return
        }

        speechRecognizer = recognizer
        sourceAsset = AVURLAsset(url: url)
        totalChunkCount = max(1, MeetingDictationPlan.segments(for: recordedDuration).count)
        currentChunkIndex = 0
        currentChunkRetryCount = 0
        chunkTranscripts = []
        skippedChunkCount = 0
        transcribeNextChunk()
    }

    private func transcribeNextChunk() {
        guard phase == .transcribing, let sourceURL = audioURL else { return }
        guard currentChunkIndex < totalChunkCount else {
            finishTranscription()
            return
        }

        let displayIndex = currentChunkIndex + 1
        transcriptionProgress = "Preparing segment \(displayIndex) of \(totalChunkCount)…"

        if totalChunkCount == 1 {
            startRecognition(of: sourceURL)
        } else {
            exportCurrentChunk()
        }
    }

    private func exportCurrentChunk() {
        guard let asset = sourceAsset else {
            fail(DictationError.transcriptionFailed("The meeting recording could not be opened for segmented transcription."))
            return
        }

        let chunkURL = ApplicationPaths.dictationScratch.appendingPathComponent(
            "note-dictation-segment-\(UUID().uuidString).m4a"
        )
        try? FileManager.default.removeItem(at: chunkURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A),
              export.supportedFileTypes.contains(.m4a) else {
            fail(DictationError.transcriptionFailed("This Mac could not prepare the meeting recording for segmented transcription."))
            return
        }

        let startSeconds = Double(currentChunkIndex) * MeetingDictationPlan.segmentDuration
        let remaining = max(0.1, recordedDuration - startSeconds)
        let duration = min(MeetingDictationPlan.segmentDuration, remaining)
        export.outputURL = chunkURL
        export.outputFileType = .m4a
        export.shouldOptimizeForNetworkUse = false
        export.timeRange = CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        activeExportSession = export
        let exportIdentifier = UUID()
        activeExportIdentifier = exportIdentifier
        activeChunkURL = chunkURL

        export.exportAsynchronously { [weak self] in
            Task { @MainActor in
                guard let self, self.activeExportIdentifier == exportIdentifier,
                      let export = self.activeExportSession,
                      self.phase == .transcribing else { return }
                self.activeExportSession = nil
                self.activeExportIdentifier = nil
                switch export.status {
                case .completed:
                    self.startRecognition(of: chunkURL)
                case .cancelled:
                    break
                case .failed:
                    self.fail(DictationError.transcriptionFailed(
                        export.error?.localizedDescription ?? "A meeting-audio segment could not be prepared."
                    ))
                case .unknown, .waiting, .exporting:
                    self.fail(DictationError.transcriptionFailed("A meeting-audio segment did not finish preparing."))
                @unknown default:
                    self.fail(DictationError.transcriptionFailed("A meeting-audio segment could not be prepared."))
                }
            }
        }
    }

    private func startRecognition(of url: URL) {
        guard phase == .transcribing, let recognizer = speechRecognizer else { return }
        let displayIndex = currentChunkIndex + 1
        transcriptionProgress = "Transcribing segment \(displayIndex) of \(totalChunkCount) on device…"

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation

        let identifier = UUID()
        recognitionIdentifier = identifier
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.recognitionIdentifier == identifier else { return }
                self.handleRecognitionFailure(
                    "Segment \(displayIndex) exceeded its on-device time limit.",
                    sourceURL: url
                )
            }
        }
        transcriptionTimeout = timeout
        let timeoutSeconds = activePerformance?.dictationTranscriptionTimeout
            ?? SettingsStore.shared.dictationPerformance.dictationTranscriptionTimeout
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.phase == .transcribing,
                      self.recognitionIdentifier == identifier else { return }
                if let result, result.isFinal {
                    let transcript = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    self.finishCurrentChunk(with: transcript)
                } else if let error {
                    self.handleRecognitionFailure(error.localizedDescription, sourceURL: url)
                }
            }
        }
    }

    private func handleRecognitionFailure(_ detail: String, sourceURL: URL) {
        recognitionIdentifier = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        transcriptionTimeout?.cancel()
        transcriptionTimeout = nil

        if currentChunkRetryCount == 0 {
            currentChunkRetryCount = 1
            transcriptionProgress = "Retrying segment \(currentChunkIndex + 1) of \(totalChunkCount)…"
            startRecognition(of: sourceURL)
            return
        }

        skippedChunkCount += 1
        let start = Double(currentChunkIndex) * MeetingDictationPlan.segmentDuration
        let end = min(recordedDuration, start + MeetingDictationPlan.segmentDuration)
        let marker = "[Untranscribed audio \(Self.clockLabel(start))–\(Self.clockLabel(end)): \(detail)]"
        finishCurrentChunk(with: marker)
    }

    private func finishCurrentChunk(with transcript: String) {
        recognitionIdentifier = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        transcriptionTimeout?.cancel()
        transcriptionTimeout = nil
        if !transcript.isEmpty { chunkTranscripts.append(transcript) }
        cleanupActiveChunk()
        currentChunkIndex += 1
        currentChunkRetryCount = 0
        transcribeNextChunk()
    }

    private func finishTranscription() {
        let transcript = chunkTranscripts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !transcript.isEmpty else {
            fail(DictationError.emptyTranscript)
            return
        }

        let destinationNoteID = destinationNoteID
        onTranscript(transcript, destinationNoteID)
        let warning = skippedChunkCount > 0
            ? "Dictation completed, but \(skippedChunkCount) audio segment\(skippedChunkCount == 1 ? "" : "s") could not be recognized. Markers were added to the note."
            : nil
        cleanupAudioFiles()
        resetJobState()
        phase = .idle
        lastError = warning
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let duration = recorder.currentTime
        Task { @MainActor [weak self] in
            guard let self, self.phase == .recording else { return }
            self.recorder = nil
            self.recordedDuration = max(duration, 0.1)
            if flag {
                self.beginTranscriptionIfPossible()
            } else {
                self.fail(DictationError.recorderUnavailable)
            }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            self?.fail(error ?? DictationError.recorderUnavailable)
        }
    }

    private func fail(_ error: Error) {
        activeExportSession?.cancelExport()
        activeExportSession = nil
        activeExportIdentifier = nil
        recognitionIdentifier = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recorder?.stop()
        recorder = nil
        transcriptionTimeout?.cancel()
        transcriptionTimeout = nil
        lastError = error.localizedDescription
        cleanupAudioFiles()
        resetJobState()
        phase = .idle
    }

    private func cleanupActiveChunk() {
        guard let activeChunkURL else { return }
        if activeChunkURL != audioURL { try? FileManager.default.removeItem(at: activeChunkURL) }
        self.activeChunkURL = nil
    }

    private func cleanupAudioFiles() {
        cleanupActiveChunk()
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        audioURL = nil
    }

    private func resetJobState() {
        recordedDuration = 0
        sourceAsset = nil
        speechRecognizer = nil
        activePerformance = nil
        currentChunkIndex = 0
        totalChunkCount = 0
        currentChunkRetryCount = 0
        chunkTranscripts = []
        skippedChunkCount = 0
        transcriptionProgress = nil
        destinationNoteID = nil
    }

    private static func durationLabel(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes == 60 ? "1 hour" : "\(minutes) minutes"
    }

    private static func clockLabel(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
