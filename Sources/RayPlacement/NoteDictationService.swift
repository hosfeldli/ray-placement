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
        case paused
        case stopping
        case transcribing
        case completed
        case failed
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
    @Published private(set) var partialTranscript = ""
    @Published private(set) var recoveryAudioURL: URL?
    @Published var lastError: String?

    private let onTranscript: (String) -> Void
    private let onCommittedDelta: (String) -> Void
    var targetProvider: (() -> DictationTarget)?
    var onTargetEvent: ((DictationTarget, DictationTranscriptEvent) -> Void)?
    private(set) var currentTarget: DictationTarget?
    private var requestedTarget: DictationTarget?
    private let onSessionStarted: () -> Void
    private let onSessionRetryStarted: () -> Void
    private let onSessionFinished: () -> Void
    private let onSessionFailed: () -> Void
    private let localWhisper = LocalWhisperTranscriber()
    private let liveAppleTranscriber = LiveAppleSpeechTranscriber()
    private var liveSpeechWarning: String?
    private var liveAppleRestartCount = 0
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
    private var liveCommittedTranscript = ""
    private var isAppleAudioFallbackTranscription = false
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
    private var registryTaskID: UUID?
    private var firstPartialPerformanceMeasurementID: UUID?
    private var partialToCommitStartedAt: Date?
    private var sessionStarted = false
    private var usesDefaultConversationCallbacks = false
    private var aiPolicyObserver: NSObjectProtocol?

    init(
        onTranscript: @escaping (String) -> Void,
        onCommittedDelta: ((String) -> Void)? = nil,
        targetProvider: (() -> DictationTarget)? = nil,
        onTargetEvent: ((DictationTarget, DictationTranscriptEvent) -> Void)? = nil,
        onSessionStarted: @escaping () -> Void = {},
        onSessionRetryStarted: @escaping () -> Void = {},
        onSessionFinished: @escaping () -> Void = {},
        onSessionFailed: @escaping () -> Void = {}
    ) {
        self.onTranscript = onTranscript
        self.onCommittedDelta = onCommittedDelta ?? onTranscript
        self.targetProvider = targetProvider
        self.onTargetEvent = onTargetEvent
        self.onSessionStarted = onSessionStarted
        self.onSessionRetryStarted = onSessionRetryStarted
        self.onSessionFinished = onSessionFinished
        self.onSessionFailed = onSessionFailed
        super.init()
        aiPolicyObserver = NotificationCenter.default.addObserver(forName: AIRequestPolicy.changed, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !AIRequestPolicy.shared.isEnabled else { return }
                self.cancel()
                self.lastError = AIRequestPolicy.disabledMessage
            }
        }
    }

    var actionTitle: String {
        switch phase {
        case .idle: return "Dictate"
        case .requestingPermission: return "Waiting for Permission…"
        case .recording: return "Stop & Transcribe"
        case .paused: return "Resume Recording"
        case .stopping: return "Stopping…"
        case .transcribing: return "Transcribing…"
        case .completed: return "Record Again"
        case .failed: return recoveryAudioURL == nil ? "Record Again" : "Retry Transcription"
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
        case .recording, .paused:
            let seconds = activePerformance?.dictationMaximumDuration
                ?? SettingsStore.shared.runtimeDictationPerformance.dictationMaximumDuration
            let prepared = max(0, recordingSegmentURLs.count - (recorder == nil ? 0 : 1))
            var suffix = prepared > 0 ? " · \(prepared) segment\(prepared == 1 ? "" : "s") secured" : ""
            if activeTranscribeWhileRecording, localSegmentIndex > 0 {
                suffix += " · \(localSegmentIndex) transcribed"
            }
            if recorderRestartCount > 0 { suffix += " · input recovered" }
            let state = phase == .paused ? "Recording paused" : "Recording locally"
            return "\(state) — maximum \(Self.durationLabel(seconds))\(suffix)."
        case .stopping:
            return "Finishing the recording…"
        case .transcribing:
            return transcriptionProgress ?? "Transcribing…"
        case .completed:
            return "Dictation completed. You can edit the transcript or record another conversation."
        case .failed:
            return lastError ?? "Transcription failed. You can retry the saved recording or record again."
        }
    }

    var inputSignalText: String {
        guard phase == .recording else { return phase == .paused ? "Recording paused" : "" }
        if audioLevel < 0.10 { return "Listening for room audio" }
        if audioLevel < 0.28 { return "Quiet speech detected" }
        return "Speech detected"
    }

    func performPrimaryAction(target: DictationTarget? = nil) {
        guard AIRequestPolicy.shared.isEnabled else { lastError = AIRequestPolicy.disabledMessage; return }
        switch phase {
        case .idle:
            requestedTarget = target
            currentTarget = target
            requestPermissionsAndStart()
        case .recording, .paused:
            stopAndTranscribe()
        case .completed, .failed:
            requestedTarget = target
            currentTarget = target
            recoveryAudioURL = nil
            lastError = nil
            requestPermissionsAndStart()
        case .requestingPermission, .stopping, .transcribing:
            break
        }
    }

    func pauseOrResume() {
        switch phase {
        case .recording:
            guard let recorder else { return }
            recorder.pause()
            liveAppleTranscriber.pause()
            stopMetering()
            phase = .paused
        case .paused:
            guard let recorder, recorder.record() else {
                lastError = "The microphone could not resume recording."
                phase = .failed
                return
            }
            if activeEngine == .appleSpeech, liveAppleTranscriber.isActive {
                do { try liveAppleTranscriber.resume() }
                catch {
                    liveSpeechWarning = "Live speech recognition could not resume; the saved audio may be retried."
                    liveTranscriptionPaused = true
                }
            }
            phase = .recording
            startMetering()
        default:
            break
        }
    }

    func cancel() {
        finishFirstPartialMeasurement(succeeded: false, detail: "Cancelled before first partial")
        let hadActiveSession = sessionStarted
        liveAppleTranscriber.cancel()
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
        finishRegistryTask(state: .cancelled, detail: "Stopped by user")
        if hadActiveSession { finishSession(success: false) }
        lastError = preservedAudio == nil
            ? nil
            : "Dictation was canceled. The remaining audio was preserved; choose Retry Transcription to resume it."
        operationIdentifier = nil
        resetJobState()
        phase = .idle
    }

    func retryFailedRecording() {
        guard AIRequestPolicy.shared.isEnabled else { lastError = AIRequestPolicy.disabledMessage; return }
        guard phase == .idle, let recoveryAudioURL,
              FileManager.default.fileExists(atPath: recoveryAudioURL.path) else { return }
        lastError = nil
        let operation = UUID()
        operationIdentifier = operation
        phase = .requestingPermission
        activePerformance = SettingsStore.shared.runtimeDictationPerformance
        activeEngine = SettingsStore.shared.dictationEngine

        let retryTarget = currentTarget ?? targetProvider?()
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
            if self.usesDefaultConversationCallbacks {
                self.onSessionRetryStarted()
                self.sessionStarted = true
            } else {
                self.sessionStarted = false
            }
            self.currentTarget = retryTarget
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
        guard AIRequestPolicy.shared.isEnabled else { cancel(); lastError = AIRequestPolicy.disabledMessage; return }
        guard operationIdentifier == operation, phase == .requestingPermission else { return }
        do {
            try ApplicationPaths.prepare()
            cleanupAudioFiles()
            resetJobState()
            usesDefaultConversationCallbacks = requestedTarget == nil
            sessionStarted = usesDefaultConversationCallbacks
            if sessionStarted { onSessionStarted() }
            currentTarget = requestedTarget ?? targetProvider?()
            requestedTarget = nil
            let performance = SettingsStore.shared.runtimeDictationPerformance
            activePerformance = performance
            activeEngine = SettingsStore.shared.dictationEngine
            // Keep a private rolling recording for interruption recovery. Apple
            // Speech receives continuous audio buffers; Whisper still consumes
            // short local windows while its persistent-worker path is developed.
            activeTranscribeWhileRecording = true
            let directory = ApplicationPaths.dictationScratch
                .appendingPathComponent("note-dictation-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            recordingDirectoryURL = directory
            recordingElapsed = 0
            audioLevel = 0
            phase = .recording
            try startNextRecordingSegment()
            if activeEngine == .appleSpeech {
                liveAppleTranscriber.onPartial = { [weak self] partial in
                    guard let self, self.operationIdentifier == operation else { return }
                    if !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.finishFirstPartialMeasurement(succeeded: true)
                        if self.partialToCommitStartedAt == nil {
                            self.partialToCommitStartedAt = Date()
                        }
                    } else {
                        self.partialToCommitStartedAt = nil
                    }
                    self.partialTranscript = partial
                    self.livePreviewText = partial
                    self.publishTargetEvent(.partial(partial))
                }
                liveAppleTranscriber.onCommittedDelta = { [weak self] delta in
                    self?.acceptLiveCommittedDelta(delta, operation: operation)
                }
                liveAppleTranscriber.onFailure = { [weak self] error in
                    guard let self, self.operationIdentifier == operation, self.phase == .recording else { return }
                    self.liveSpeechWarning = "Live speech recognition paused: \(error.localizedDescription)"
                    self.liveTranscriptionPaused = true
                    self.liveAppleRestartCount += 1
                    guard self.liveAppleRestartCount == 1 else {
                        self.transcriptionProgress = "Live recognition stopped; committed text is preserved."
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                        guard let self, self.operationIdentifier == operation, self.phase == .recording else { return }
                        do {
                            try self.liveAppleTranscriber.start()
                            self.liveTranscriptionPaused = false
                            self.liveSpeechWarning = nil
                        } catch {
                            self.liveSpeechWarning = "Live recognition stopped: \(error.localizedDescription)"
                            self.transcriptionProgress = "Committed text is preserved; saved audio is available for retry."
                        }
                    }
                }
                firstPartialPerformanceMeasurementID = PerformanceMonitor.shared.begin("Dictation speech to first partial")
                do {
                    try liveAppleTranscriber.start()
                } catch {
                    liveTranscriptionPaused = true
                    transcriptionProgress = "Live speech input is unavailable; saved audio will be transcribed after Stop."
                }
            }
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

    private func acceptLiveCommittedDelta(_ delta: String, operation: UUID) {
        guard operationIdentifier == operation,
              phase == .recording || phase == .transcribing,
              !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let partialToCommitStartedAt {
            let duration = max(0, Date().timeIntervalSince(partialToCommitStartedAt))
            if duration >= 0.01 {
                PerformanceMonitor.shared.record(
                    "Dictation partial to committed delta",
                    startedAt: partialToCommitStartedAt,
                    duration: duration
                )
            }
        }
        self.partialToCommitStartedAt = nil
        publishTargetEvent(.committedDelta(delta))
        liveCommittedTranscript += delta
        chunkTranscripts.append(delta)
        deliveredTranscriptCount = chunkTranscripts.count
        deliveredCharacterCount += delta.count
        semiLiveSegmentCount += 1
        transcriptionProgress = "Live · committed phrase \(semiLiveSegmentCount)"
    }

    private func publishTargetEvent(_ event: DictationTranscriptEvent) {
        if let currentTarget, let onTargetEvent {
            onTargetEvent(currentTarget, event)
            return
        }
        if case .committedDelta(let delta) = event {
            onCommittedDelta(delta)
        }
    }

    private func stopAndTranscribe() {
        guard phase == .recording || phase == .paused, let recorder else { return }
        finishFirstPartialMeasurement(succeeded: false, detail: "Stopped before first partial")
        phase = .stopping
        stopMetering()
        finalizeCurrentRecordingSegment(recorder)
        recorder.delegate = nil
        recorder.stop()
        self.recorder = nil
        recordedDuration = max(completedRecordingDuration, 0.1)
        if activeEngine == .appleSpeech, liveAppleTranscriber.isActive {
            finishLiveAppleTranscription()
            return
        }
        if activeEngine == .appleSpeech, deliveredCharacterCount > 0 {
            beginAppleAudioFallbackTranscription()
            return
        }
        beginTranscriptionIfPossible()
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
            if activeEngine == .appleSpeech, liveAppleTranscriber.isActive {
                finishLiveAppleTranscription()
            } else {
                beginTranscriptionIfPossible()
            }
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
        guard phase == .recording || phase == .paused || phase == .stopping, !recordingSegmentURLs.isEmpty else { return }
        if activeEngine == .appleSpeech,
           !liveAppleTranscriber.isActive,
           !liveCommittedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            beginAppleAudioFallbackTranscription()
            return
        }
        beginTranscriptionTaskIfNeeded()
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
        transcriptionProgress = "Transcribing segment \(localSegmentIndex + 1) of \(recordingSegmentURLs.count)…"
        let performance = activePerformance ?? SettingsStore.shared.runtimeDictationPerformance
        let segmentStartedAt = Date()
        localWhisperIsRunning = true
        localWhisper.transcribe(
            audioURL: url,
            prompt: "Dictation conversation",
            performance: performance,
            progress: { [weak self] message in
                self?.transcriptionProgress = message
            }
        ) { [weak self] result in
            guard let self else { return }
            let succeeded: Bool
            if case .success = result { succeeded = true } else { succeeded = false }
            PerformanceMonitor.shared.record(
                "Whisper segment duration",
                startedAt: segmentStartedAt,
                duration: max(0, Date().timeIntervalSince(segmentStartedAt)),
                succeeded: succeeded
            )
            guard self.phase == .recording || self.phase == .transcribing else { return }
            self.localWhisperIsRunning = false
            switch result {
            case .success(let transcript):
                let cleanTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanTranscript.isEmpty {
                    self.livePreviewText = cleanTranscript
                    self.chunkTranscripts.append(cleanTranscript)
                    if self.phase == .recording {
                        self.publishTargetEvent(.committedDelta(cleanTranscript))
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
                    self.transcriptionProgress = "A live segment will retry after Stop."
                } else if self.currentChunkRetryCount == 0 {
                    self.currentChunkRetryCount = 1
                    self.transcriptionProgress = "Retrying segment \(self.localSegmentIndex + 1) of \(self.totalChunkCount)…"
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
        if activeEngine == .appleSpeech, liveAppleTranscriber.isActive { return }
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

    private func beginAppleAudioFallbackTranscription() {
        guard !recordingSegmentURLs.isEmpty else {
            fail(DictationError.recorderUnavailable)
            return
        }
        beginTranscriptionTaskIfNeeded()
        isAppleAudioFallbackTranscription = true
        phase = .transcribing
        currentChunkIndex = 0
        totalChunkCount = recordingSegmentURLs.count
        currentChunkRetryCount = 0
        chunkTranscripts = []
        deliveredTranscriptCount = 0
        skippedChunkCount = 0
        transcriptionProgress = "Recovering uncommitted on-device speech…"
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
        guard AIRequestPolicy.shared.isEnabled else { fail(AIRequestPolicy.Disabled()); return }
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
            transcriptionProgress = "A live window will retry after Stop."
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
                publishTargetEvent(.committedDelta(cleanTranscript))
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

    private func finishLiveAppleTranscription() {
        beginTranscriptionTaskIfNeeded()
        phase = .transcribing
        transcriptionProgress = "Finalizing on-device speech…"
        liveAppleTranscriber.finish { [weak self] error in
            guard let self else { return }
            if let error {
                self.liveSpeechWarning = "Speech recognition ended early: " + error.localizedDescription
            }
            self.finishTranscription()
        }
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
        let remainingTranscript: String
        if isAppleAudioFallbackTranscription {
            remainingTranscript = TranscriptReconciliation.uncommittedSuffix(
                committed: liveCommittedTranscript,
                recovered: allTranscript
            )
        } else {
            remainingTranscript = chunkTranscripts
                .dropFirst(min(deliveredTranscriptCount, chunkTranscripts.count))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }

        let warning = liveSpeechWarning ?? (skippedChunkCount > 0
            ? "Dictation completed, but \(skippedChunkCount) audio segment\(skippedChunkCount == 1 ? "" : "s") could not be recognized. Markers were added to the conversation."
            : nil)
        completeTranscription(
            remainingTranscript,
            outputCharacters: deliveredCharacterCount + remainingTranscript.count,
            warning: warning,
            finalTranscript: allTranscript
        )
    }

    private func completeTranscription(
        _ transcript: String,
        outputCharacters: Int,
        warning: String?,
        finalTranscript: String
    ) {
        if !transcript.isEmpty { publishTargetEvent(.committedDelta(transcript)) }
        publishTargetEvent(.completed(finalTranscript))
        cleanupAudioFiles()
        finishRegistryTask(state: .completed, detail: "Transcription complete")
        finishUsage(succeeded: true, outputCharacters: outputCharacters, detail: "Recorded \\(Int(recordedDuration)) seconds")
        finishSession(success: true)
        operationIdentifier = nil
        resetJobState()
        phase = .completed
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
        liveAppleTranscriber.cancel()
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
        finishRegistryTask(state: .failed, detail: "Transcription failed")
        lastError = recoveryURL == nil
            ? error.localizedDescription
            : "\(error.localizedDescription) The recording was preserved; choose Retry Transcription after changing engines or performance if needed."
        finishUsage(succeeded: false, detail: error.localizedDescription)
        finishSession(success: false)
        operationIdentifier = nil
        resetJobState()
        phase = .failed
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

    private func finishFirstPartialMeasurement(succeeded: Bool, detail: String? = nil) {
        guard let measurementID = firstPartialPerformanceMeasurementID else { return }
        PerformanceMonitor.shared.end(measurementID, succeeded: succeeded, detail: detail)
        firstPartialPerformanceMeasurementID = nil
    }

    private func resetJobState() {
        finishFirstPartialMeasurement(succeeded: false, detail: "Reset before first partial")
        partialToCommitStartedAt = nil
        stopMetering()
        recordedDuration = 0
        speechRecognizer = nil
        activePerformance = nil
        activeEngine = nil
        currentChunkIndex = 0
        totalChunkCount = 0
        currentChunkRetryCount = 0
        currentPartialTranscript = ""
        liveCommittedTranscript = ""
        isAppleAudioFallbackTranscription = false
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
        partialTranscript = ""
        liveSpeechWarning = nil
        liveAppleRestartCount = 0
    }

    private func beginTranscriptionTaskIfNeeded() {
        guard registryTaskID == nil else { return }
        registryTaskID = TaskRegistry.shared.begin(
            kind: .dictation,
            title: "Transcribing dictation",
            detail: "Finishing on-device transcription",
            isCancellable: true,
            onCancel: { [weak self] in self?.cancel() }
        )
    }

    private func finishRegistryTask(state: LimaTaskState, detail: String) {
        guard let registryTaskID else { return }
        self.registryTaskID = nil
        TaskRegistry.shared.finish(registryTaskID, state: state, detail: detail)
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
