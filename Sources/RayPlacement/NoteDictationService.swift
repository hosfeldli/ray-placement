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
                return "Allow Lima under System Settings → Privacy & Security → Speech Recognition to record dictation conversations."
            case .microphonePermission:
                return "Allow Lima under System Settings → Privacy & Security → Microphone to record dictation."
            case .onDeviceUnavailable:
                return "On-device speech recognition is unavailable for the current language. Lima will not send dictation audio to a network service."
            case .recorderUnavailable:
                return "Lima could not start the Mac's active microphone."
            case .transcriptionFailed(let detail):
                return detail.isEmpty ? "The recorded dictation could not be transcribed." : detail
            case .emptyTranscript:
                return "No speech was recognized in that recording."
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcriptionProgress: String?
    @Published private(set) var audioLevel: Double = 0
    @Published private(set) var recordingElapsed: TimeInterval = 0
    @Published private(set) var semiLiveSegmentCount = 0
    @Published private(set) var livePreviewText = ""
    @Published private(set) var recoveryAudioURL: URL?
    @Published var lastError: String?

    private let onTranscript: (String) -> Void
    private let onSessionStarted: () -> Void
    private let onSessionRetryStarted: () -> Void
    private let onSessionFinished: () -> Void
    private let onSessionFailed: () -> Void
    private let localWhisper = LocalWhisperTranscriber()
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var recordingDirectoryURL: URL?
    private var recordingSegmentURLs: [URL] = []
    private var recordingSegmentDurations: [TimeInterval] = []
    private var completedRecordingDuration: TimeInterval = 0
    private var rotatingRecorder = false
    private var recordedDuration: TimeInterval = 0
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionIdentifier: UUID?
    private var activePerformance: PerformanceScale?
    private var activeEngine: DictationEngine?
    private var activeTranscribeWhileRecording = false
    private var currentChunkIndex = 0
    private var totalChunkCount = 0
    private var currentChunkRetryCount = 0
    private var currentPartialTranscript = ""
    private var chunkTranscripts: [String] = []
    private var deliveredTranscriptCount = 0
    private var deliveredCharacterCount = 0
    private var skippedChunkCount = 0
    private var usageTaskID: UUID?
    private var recoveryDuration: TimeInterval = 0
    private var localSegmentIndex = 0
    private var localWhisperIsRunning = false
    private var liveTranscriptionPaused = false
    private var recorderRestartCount = 0
    private var operationIdentifier: UUID?
    private var sessionStarted = false

    init(
        onTranscript: @escaping (String) -> Void,
        onSessionStarted: @escaping () -> Void = {},
        onSessionRetryStarted: @escaping () -> Void = {},
        onSessionFinished: @escaping () -> Void = {},
        onSessionFailed: @escaping () -> Void = {}
    ) {
        self.onTranscript = onTranscript
        self.onSessionStarted = onSessionStarted
        self.onSessionRetryStarted = onSessionRetryStarted
        self.onSessionFinished = onSessionFinished
        self.onSessionFailed = onSessionFailed
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
            return "Records only when requested. Audio is secured in short local segments until Stop."
        case .requestingPermission:
            return SettingsStore.shared.dictationEngine == .localWhisper
                ? "Waiting for microphone permission."
                : "Waiting for microphone and speech-recognition permission."
        case .recording:
            let seconds = activePerformance?.dictationMaximumDuration
                ?? SettingsStore.shared.runtimeDictationPerformance.dictationMaximumDuration
            let prepared = max(0, recordingSegmentURLs.count - (recorder == nil ? 0 : 1))
            var suffix = prepared > 0 ? " · \(prepared) segment\(prepared == 1 ? "" : "s") secured" : ""
            if activeTranscribeWhileRecording, localSegmentIndex > 0 {
                suffix += " · \(localSegmentIndex) transcribed"
            }
            if recorderRestartCount > 0 { suffix += " · input recovered" }
            return "Recording locally — maximum \(Self.durationLabel(seconds))\(suffix)."
        case .transcribing:
            return transcriptionProgress ?? "Preparing the completed recording for on-device transcription."
        }
    }

    var inputSignalText: String {
        guard phase == .recording else { return "" }
        if audioLevel < 0.10 { return "Listening for room audio" }
        if audioLevel < 0.28 { return "Quiet speech detected" }
        return "Speech detected"
    }

    func performPrimaryAction() {
        switch phase {
        case .idle:
            requestPermissionsAndStart()
        case .recording:
            stopAndTranscribe()
        case .requestingPermission, .transcribing:
            break
        }
    }

    func cancel() {
        let hadActiveSession = sessionStarted
        stopMetering()
        if let recorder {
            recorder.delegate = nil
            finalizeCurrentRecordingSegment(recorder)
            recorder.stop()
            self.recorder = nil
        }
        recognitionIdentifier = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        localWhisper.cancel()

        // Cancellation is unsuccessful, but it should not silently destroy
        // audio that has not yet been delivered to the conversation. Completed
        // live segments have already removed their source files, so recovery
        // contains only the remaining work and cannot duplicate transcript text.
        let preservedAudio = preserveRecordingForRecovery()
        finishUsage(succeeded: false, detail: "Cancelled by user")
        if hadActiveSession { finishSession(success: false) }
        lastError = preservedAudio == nil
            ? nil
            : "Dictation was canceled. The remaining audio was preserved; choose Retry Transcription to resume it."
        operationIdentifier = nil
        resetJobState()
        phase = .idle
    }

    func retryFailedRecording() {
        guard phase == .idle, let recoveryAudioURL,
              FileManager.default.fileExists(atPath: recoveryAudioURL.path) else { return }
        lastError = nil
        let operation = UUID()
        operationIdentifier = operation
        phase = .requestingPermission
        activePerformance = SettingsStore.shared.runtimeDictationPerformance
        activeEngine = SettingsStore.shared.dictationEngine

        let beginRetry = { [weak self] in
            guard let self, self.operationIdentifier == operation, self.phase == .requestingPermission else { return }
            self.recordingDirectoryURL = recoveryAudioURL
            self.recordingSegmentURLs = Self.segmentFiles(in: recoveryAudioURL)
            guard !self.recordingSegmentURLs.isEmpty else {
                self.fail(DictationError.recorderUnavailable)
                return
            }
            self.recordingSegmentDurations = self.recordingSegmentURLs.map(Self.audioDuration)
            self.recordedDuration = max(self.recoveryDuration, 0.1)
            self.usageTaskID = UsageMonitor.shared.begin(
                category: .dictation,
                operation: "Retry saved dictation conversation",
                model: self.activeEngine == .localWhisper ? "Whisper small.en TinyDiarize" : "Apple on-device speech recognition",
                performance: self.activePerformance ?? .eco
            )
            self.onSessionRetryStarted()
            self.sessionStarted = true
            self.phase = .recording
            self.beginTranscriptionIfPossible()
        }

        if activeEngine == .appleSpeech {
            requestSpeechAuthorization { [weak self] granted in
                guard let self, self.operationIdentifier == operation, self.phase == .requestingPermission else { return }
                guard granted else {
                    self.fail(DictationError.speechPermission)
                    return
                }
                beginRetry()
            }
        } else {
            beginRetry()
        }
    }

    private func requestPermissionsAndStart() {
        lastError = nil
        recoveryAudioURL = nil
        let operation = UUID()
        operationIdentifier = operation
        phase = .requestingPermission

        let startIfCurrent = { [weak self] in
            guard let self, self.operationIdentifier == operation, self.phase == .requestingPermission else { return }
            self.startRecording(operation: operation)
        }

        if SettingsStore.shared.dictationEngine == .localWhisper {
            requestMicrophoneAuthorization { [weak self] microphoneGranted in
                guard let self, self.operationIdentifier == operation, self.phase == .requestingPermission else { return }
                guard microphoneGranted else {
                    self.fail(DictationError.microphonePermission)
                    return
                }
                startIfCurrent()
            }
            return
        }
        requestSpeechAuthorization { [weak self] speechGranted in
            guard let self, self.operationIdentifier == operation, self.phase == .requestingPermission else { return }
            guard speechGranted else {
                self.fail(DictationError.speechPermission)
                return
            }
            self.requestMicrophoneAuthorization { [weak self] microphoneGranted in
                guard let self, self.operationIdentifier == operation, self.phase == .requestingPermission else { return }
                guard microphoneGranted else {
                    self.fail(DictationError.microphonePermission)
                    return
                }
                startIfCurrent()
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

    private func startRecording(operation: UUID) {
        guard operationIdentifier == operation, phase == .requestingPermission else { return }
        do {
            try ApplicationPaths.prepare()
            cleanupAudioFiles()
            resetJobState()
            sessionStarted = true
            onSessionStarted()
            let performance = SettingsStore.shared.runtimeDictationPerformance
            activePerformance = performance
            activeEngine = SettingsStore.shared.dictationEngine
            // Both engines use a rolling live pipeline. A fresh segment keeps
            // recording while each completed window is delivered to the active
            // conversation.
            activeTranscribeWhileRecording = true
            let directory = ApplicationPaths.dictationScratch
                .appendingPathComponent("note-dictation-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            recordingDirectoryURL = directory
            recordingElapsed = 0
            audioLevel = 0
            phase = .recording
            try startNextRecordingSegment()
            usageTaskID = UsageMonitor.shared.begin(
                category: .dictation,
                operation: "Record dictation conversation",
                model: activeEngine == .localWhisper ? "Whisper small.en TinyDiarize" : "Apple on-device speech recognition",
                performance: performance
            )
            startMetering()
        } catch {
            fail(error)
        }
    }

    private func stopAndTranscribe() {
        guard phase == .recording, let recorder else { return }
        stopMetering()
        finalizeCurrentRecordingSegment(recorder)
        recorder.delegate = nil
        recorder.stop()
        self.recorder = nil
        recordedDuration = max(completedRecordingDuration, 0.1)
        if phase == .recording { beginTranscriptionIfPossible() }
    }

    private var recordingSegmentLimit: TimeInterval {
        activeEngine == .appleSpeech
            ? MeetingDictationPlan.appleSpeechSegmentDuration
            : MeetingDictationPlan.localWhisperSegmentDuration
    }

    private func startNextRecordingSegment() throws {
        guard let directory = recordingDirectoryURL else { throw DictationError.recorderUnavailable }
        let url = directory.appendingPathComponent(
            String(format: "segment-%04d.wav", recordingSegmentURLs.count + 1)
        )
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record() else { throw DictationError.recorderUnavailable }
        recordingSegmentURLs.append(url)
        recordingSegmentDurations.append(0)
        self.recorder = recorder
    }

    private func finalizeCurrentRecordingSegment(_ recorder: AVAudioRecorder) {
        guard let index = recordingSegmentURLs.indices.last else { return }
        let duration = max(0, recorder.currentTime)
        recordingSegmentDurations[index] = duration
        completedRecordingDuration = recordingSegmentDurations.reduce(0, +)
    }

    private func rotateRecordingSegment() {
        guard phase == .recording, !rotatingRecorder, let recorder else { return }
        rotatingRecorder = true
        finalizeCurrentRecordingSegment(recorder)
        recorder.delegate = nil
        recorder.stop()
        self.recorder = nil
        let maximum = activePerformance?.dictationMaximumDuration
            ?? SettingsStore.shared.runtimeDictationPerformance.dictationMaximumDuration
        if completedRecordingDuration >= maximum {
            rotatingRecorder = false
            recordedDuration = completedRecordingDuration
            stopMetering()
            beginTranscriptionIfPossible()
            return
        }
        do {
            try startNextRecordingSegment()
            rotatingRecorder = false
            beginLiveTranscriptionIfNeeded()
        } catch {
            rotatingRecorder = false
            fail(error)
        }
    }

    private func beginTranscriptionIfPossible() {
        guard phase == .recording, !recordingSegmentURLs.isEmpty else { return }
        phase = .transcribing

        if activeEngine == .localWhisper {
            totalChunkCount = recordingSegmentURLs.count
            liveTranscriptionPaused = false
            if !activeTranscribeWhileRecording {
                localSegmentIndex = 0
                chunkTranscripts = []
                currentChunkRetryCount = 0
                skippedChunkCount = 0
            }
            beginNextLocalWhisperSegment()
            return
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale.current),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            fail(DictationError.onDeviceUnavailable)
            return
        }

        speechRecognizer = recognizer
        totalChunkCount = recordingSegmentURLs.count
        currentChunkRetryCount = 0
        transcribeNextChunk()
    }

    private func beginNextLocalWhisperSegment() {
        guard phase == .recording || phase == .transcribing, !localWhisperIsRunning else { return }
        guard recordingSegmentURLs.indices.contains(localSegmentIndex) else {
            if phase == .transcribing { finishTranscription() }
            return
        }
        guard recordingSegmentDurations.indices.contains(localSegmentIndex),
              recordingSegmentDurations[localSegmentIndex] > 0 else { return }
        let url = recordingSegmentURLs[localSegmentIndex]
        transcriptionProgress = "Local Whisper segment \(localSegmentIndex + 1) of \(recordingSegmentURLs.count)…"
        let performance = activePerformance ?? SettingsStore.shared.runtimeDictationPerformance
        localWhisperIsRunning = true
        localWhisper.transcribe(
            audioURL: url,
            prompt: "Dictation conversation",
            performance: performance,
            progress: { [weak self] message in
                self?.transcriptionProgress = message
            }
        ) { [weak self] result in
            guard let self, self.phase == .recording || self.phase == .transcribing else { return }
            self.localWhisperIsRunning = false
            switch result {
            case .success(let transcript):
                let cleanTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanTranscript.isEmpty {
                    self.livePreviewText = cleanTranscript
                    self.chunkTranscripts.append(cleanTranscript)
                    if self.phase == .recording {
                        self.onTranscript(cleanTranscript)
                        self.deliveredTranscriptCount = self.chunkTranscripts.count
                        self.deliveredCharacterCount += cleanTranscript.count
                        self.semiLiveSegmentCount += 1
                        self.transcriptionProgress = "Added segment \(self.semiLiveSegmentCount) to conversation"
                        // This segment is now durable in the conversation store.
                        // Removing its audio prevents a later recovery retry from
                        // inserting the same completed segment a second time.
                        try? FileManager.default.removeItem(at: url)
                    }
                }
                self.localSegmentIndex += 1
                self.currentChunkRetryCount = 0
                self.beginNextLocalWhisperSegment()
            case .failure(let error):
                if case LocalWhisperTranscriber.TranscriptionError.emptyTranscript = error {
                    // Quiet meeting segments are valid. Keep the audio queue moving
                    // without turning a minute of silence into a failed meeting.
                    self.localSegmentIndex += 1
                    self.currentChunkRetryCount = 0
                    self.beginNextLocalWhisperSegment()
                } else if self.phase == .recording {
                    self.currentChunkRetryCount = 1
                    self.liveTranscriptionPaused = true
                    self.transcriptionProgress = "A live segment will retry after Stop: \(error.localizedDescription)"
                } else if self.currentChunkRetryCount == 0 {
                    self.currentChunkRetryCount = 1
                    self.transcriptionProgress = "Retrying Local Whisper segment \(self.localSegmentIndex + 1) of \(self.totalChunkCount)…"
                    self.beginNextLocalWhisperSegment()
                } else {
                    let start = self.recordingSegmentDurations.prefix(self.localSegmentIndex).reduce(0, +)
                    let duration = self.recordingSegmentDurations[self.localSegmentIndex]
                    self.skippedChunkCount += 1
                    self.chunkTranscripts.append(
                        "[Untranscribed audio \(Self.clockLabel(start))–\(Self.clockLabel(start + duration)): \(error.localizedDescription)]"
                    )
                    self.localSegmentIndex += 1
                    self.currentChunkRetryCount = 0
                    self.beginNextLocalWhisperSegment()
                }
            }
        }
    }

    private func beginLiveLocalWhisperIfNeeded() {
        guard phase == .recording,
              activeTranscribeWhileRecording,
              activeEngine == .localWhisper,
              !liveTranscriptionPaused else { return }
        beginNextLocalWhisperSegment()
    }

    private func beginLiveTranscriptionIfNeeded() {
        guard phase == .recording, activeTranscribeWhileRecording, !liveTranscriptionPaused else { return }
        if activeEngine == .localWhisper {
            beginLiveLocalWhisperIfNeeded()
            return
        }
        if speechRecognizer == nil {
            guard let recognizer = SFSpeechRecognizer(locale: Locale.current),
                  recognizer.isAvailable,
                  recognizer.supportsOnDeviceRecognition else {
                liveTranscriptionPaused = true
                transcriptionProgress = "Live recognition is unavailable; the recording will retry after Stop."
                return
            }
            speechRecognizer = recognizer
        }
        totalChunkCount = recordingSegmentURLs.count
        transcribeNextChunk()
    }

    private func transcribeNextChunk() {
        guard phase == .recording || phase == .transcribing, recognitionTask == nil else { return }
        guard currentChunkIndex < totalChunkCount else {
            if phase == .transcribing { finishTranscription() }
            return
        }
        guard recordingSegmentDurations.indices.contains(currentChunkIndex),
              recordingSegmentDurations[currentChunkIndex] > 0 else { return }

        let displayIndex = currentChunkIndex + 1
        transcriptionProgress = "Preparing segment \(displayIndex) of \(totalChunkCount)…"
        startRecognition(of: recordingSegmentURLs[currentChunkIndex])
    }

    private func startRecognition(of url: URL) {
        guard phase == .recording || phase == .transcribing, let recognizer = speechRecognizer else { return }
        let displayIndex = currentChunkIndex + 1
        transcriptionProgress = "Transcribing segment \(displayIndex) of \(totalChunkCount) on device…"

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation

        let identifier = UUID()
        recognitionIdentifier = identifier

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.phase == .recording || self.phase == .transcribing,
                      self.recognitionIdentifier == identifier else { return }
                if let result {
                    let transcript = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !transcript.isEmpty {
                        self.currentPartialTranscript = transcript
                        self.livePreviewText = transcript
                    }
                    if result.isFinal {
                        self.finishCurrentChunk(with: transcript)
                        return
                    }
                }
                if let error {
                    self.handleRecognitionFailure(error.localizedDescription, sourceURL: url)
                }
            }
        }
    }

    private func handleRecognitionFailure(_ detail: String, sourceURL: URL) {
        recognitionIdentifier = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        if !currentPartialTranscript.isEmpty {
            finishCurrentChunk(with: currentPartialTranscript)
            return
        }

        if currentChunkRetryCount == 0 {
            currentChunkRetryCount = 1
            currentPartialTranscript = ""
            transcriptionProgress = "Retrying segment \(currentChunkIndex + 1) of \(totalChunkCount)…"
            startRecognition(of: sourceURL)
            return
        }

        if phase == .recording {
            liveTranscriptionPaused = true
            transcriptionProgress = "A live window will retry after Stop: \(detail)"
            return
        }

        skippedChunkCount += 1
        let start = recordingSegmentDurations.prefix(currentChunkIndex).reduce(0, +)
        let duration = recordingSegmentDurations.indices.contains(currentChunkIndex)
            ? recordingSegmentDurations[currentChunkIndex]
            : 0
        let end = min(recordedDuration, start + duration)
        let marker = "[Untranscribed audio \(Self.clockLabel(start))–\(Self.clockLabel(end)): \(detail)]"
        finishCurrentChunk(with: marker)
    }

    private func finishCurrentChunk(with transcript: String) {
        recognitionIdentifier = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        let cleanTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTranscript.isEmpty {
            chunkTranscripts.append(cleanTranscript)
            if phase == .recording {
                onTranscript(cleanTranscript)
                deliveredTranscriptCount = chunkTranscripts.count
                deliveredCharacterCount += cleanTranscript.count
                semiLiveSegmentCount += 1
                transcriptionProgress = "Live · added window \(semiLiveSegmentCount) to conversation"
                if recordingSegmentURLs.indices.contains(currentChunkIndex) {
                    try? FileManager.default.removeItem(at: recordingSegmentURLs[currentChunkIndex])
                }
            }
        }
        currentChunkIndex += 1
        currentChunkRetryCount = 0
        currentPartialTranscript = ""
        transcribeNextChunk()
    }

    private func finishTranscription() {
        let allTranscript = chunkTranscripts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !allTranscript.isEmpty else {
            fail(DictationError.emptyTranscript)
            return
        }
        let remainingTranscript = chunkTranscripts
            .dropFirst(min(deliveredTranscriptCount, chunkTranscripts.count))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        let warning = skippedChunkCount > 0
            ? "Dictation completed, but \(skippedChunkCount) audio segment\(skippedChunkCount == 1 ? "" : "s") could not be recognized. Markers were added to the conversation."
            : nil
        completeTranscription(
            remainingTranscript,
            outputCharacters: deliveredCharacterCount + remainingTranscript.count,
            warning: warning
        )
    }

    private func completeTranscription(_ transcript: String, outputCharacters: Int, warning: String?) {
        if !transcript.isEmpty { onTranscript(transcript) }
        cleanupAudioFiles()
        finishUsage(succeeded: true, outputCharacters: outputCharacters, detail: "Recorded \(Int(recordedDuration)) seconds")
        finishSession(success: true)
        operationIdentifier = nil
        resetJobState()
        phase = .idle
        lastError = warning
        recoveryAudioURL = nil
        recoveryDuration = 0
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.phase == .recording, self.recorder === recorder else { return }
            // AVAudioRecorder can finish after a route/device interruption. The
            // completed segment is already durable, so immediately rotate to a
            // fresh file regardless of the success flag rather than ending the
            // meeting.
            self.recorderRestartCount += 1
            self.rotateRecordingSegment()
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.phase == .recording, self.recorder === recorder else { return }
            self.recorderRestartCount += 1
            self.rotateRecordingSegment()
        }
    }

    private func fail(_ error: Error) {
        stopMetering()
        recognitionIdentifier = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        localWhisper.cancel()
        localWhisperIsRunning = false
        recorder?.delegate = nil
        if let recorder { finalizeCurrentRecordingSegment(recorder) }
        recorder?.stop()
        recorder = nil
        let recoveryURL = preserveRecordingForRecovery()
        lastError = recoveryURL == nil
            ? error.localizedDescription
            : "\(error.localizedDescription) The recording was preserved; choose Retry Transcription after changing engines or performance if needed."
        finishUsage(succeeded: false, detail: error.localizedDescription)
        finishSession(success: false)
        operationIdentifier = nil
        resetJobState()
        phase = .idle
    }

    private func preserveRecordingForRecovery() -> URL? {
        recordedDuration = max(recordedDuration, completedRecordingDuration)
        guard let recordingDirectoryURL,
              FileManager.default.fileExists(atPath: recordingDirectoryURL.path),
              !recordingSegmentURLs.isEmpty,
              recordedDuration > 0 else {
            cleanupAudioFiles()
            return nil
        }
        try? ApplicationPaths.prepare()
        recoveryDuration = recordedDuration
        let destination: URL
        if recordingDirectoryURL.deletingLastPathComponent() == ApplicationPaths.failedDictations {
            destination = recordingDirectoryURL
        } else {
            destination = ApplicationPaths.failedDictations.appendingPathComponent(
                "Lima-Dictation-\(Self.fileTimestamp())-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
            do {
                try FileManager.default.moveItem(at: recordingDirectoryURL, to: destination)
            } catch {
                cleanupAudioFiles()
                return nil
            }
        }
        self.recordingDirectoryURL = nil
        self.recordingSegmentURLs = []
        self.recordingSegmentDurations = []
        recoveryAudioURL = destination
        return destination
    }

    private func cleanupAudioFiles() {
        if let recordingDirectoryURL { try? FileManager.default.removeItem(at: recordingDirectoryURL) }
        recordingDirectoryURL = nil
        recordingSegmentURLs = []
        recordingSegmentDurations = []
        completedRecordingDuration = 0
    }

    private func resetJobState() {
        stopMetering()
        recordedDuration = 0
        speechRecognizer = nil
        activePerformance = nil
        activeEngine = nil
        currentChunkIndex = 0
        totalChunkCount = 0
        currentChunkRetryCount = 0
        currentPartialTranscript = ""
        chunkTranscripts = []
        deliveredTranscriptCount = 0
        deliveredCharacterCount = 0
        skippedChunkCount = 0
        localSegmentIndex = 0
        localWhisperIsRunning = false
        liveTranscriptionPaused = false
        activeTranscribeWhileRecording = false
        rotatingRecorder = false
        recorderRestartCount = 0
        transcriptionProgress = nil
        audioLevel = 0
        recordingElapsed = 0
        semiLiveSegmentCount = 0
        livePreviewText = ""
    }

    private func finishSession(success: Bool) {
        guard sessionStarted else { return }
        sessionStarted = false
        if success {
            onSessionFinished()
        } else {
            onSessionFailed()
        }
    }

    private func finishUsage(succeeded: Bool, outputCharacters: Int = 0, detail: String? = nil) {
        guard let usageTaskID else { return }
        self.usageTaskID = nil
        UsageMonitor.shared.finish(
            usageTaskID,
            succeeded: succeeded,
            outputCharacters: outputCharacters,
            detail: detail
        )
    }

    private func startMetering() {
        stopMetering()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .recording, let recorder = self.recorder else { return }
                recorder.updateMeters()
                self.recordingElapsed = self.completedRecordingDuration + recorder.currentTime
                let maximumDuration = self.activePerformance?.dictationMaximumDuration
                    ?? SettingsStore.shared.runtimeDictationPerformance.dictationMaximumDuration
                if self.recordingElapsed >= maximumDuration {
                    self.stopAndTranscribe()
                    return
                }
                if recorder.currentTime >= self.recordingSegmentLimit {
                    self.rotateRecordingSegment()
                    return
                }
                let average = Self.normalizedLevel(
                    decibels: Double(recorder.averagePower(forChannel: 0)),
                    floor: -68,
                    ceiling: -8
                )
                let peak = Self.normalizedLevel(
                    decibels: Double(recorder.peakPower(forChannel: 0)),
                    floor: -62,
                    ceiling: -3
                )
                let detected = max(average, peak * 0.78)
                self.audioLevel = (self.audioLevel * 0.68) + (detected * 0.32)
            }
        }
        meterTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
        audioLevel = 0
    }

    private static func normalizedLevel(decibels: Double, floor: Double, ceiling: Double) -> Double {
        guard ceiling > floor else { return 0 }
        return min(1, max(0, (decibels - floor) / (ceiling - floor)))
    }

    private static func segmentFiles(in directory: URL) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func audioDuration(_ url: URL) -> TimeInterval {
        guard let audio = try? AVAudioFile(forReading: url),
              audio.processingFormat.sampleRate > 0 else { return 0 }
        return max(0, Double(audio.length) / audio.processingFormat.sampleRate)
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func durationLabel(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes % 60 == 0 { return "\(minutes / 60) hour\(minutes == 60 ? "" : "s")" }
        return "\(minutes) minutes"
    }

    private static func clockLabel(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
