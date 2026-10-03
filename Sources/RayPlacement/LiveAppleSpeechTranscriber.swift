@preconcurrency import AVFoundation
import Foundation
import RayPlacementCore
@preconcurrency import Speech

@MainActor
final class LiveAppleSpeechTranscriber {
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var assembler = TranscriptAssembler()
    private var isFinishing = false
    private var finishHandler: ((Error?) -> Void)?
    private var finishTimeout: DispatchWorkItem?

    var onPartial: ((String) -> Void)?
    var onCommittedDelta: ((String) -> Void)?
    var onFailure: ((Error) -> Void)?

    var isCapturing: Bool { audioEngine?.isRunning == true }
    var isActive: Bool { request != nil }

    func start(locale: Locale = .current) throws {
        cancel()
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            throw NoteDictationService.DictationError.onDeviceUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.taskHint = .dictation

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NoteDictationService.DictationError.recorderUnavailable
        }

        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        self.recognizer = recognizer
        self.request = request
        self.audioEngine = engine
        self.assembler.reset()
        isFinishing = false
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.audioEngine = nil
            self.request = nil
            self.recognizer = nil
            throw error
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    let update = self.assembler.receivePartial(text)
                    self.onPartial?(update.partialText)
                    if !update.committedDelta.isEmpty {
                        self.onCommittedDelta?(update.committedDelta)
                    }
                    if result.isFinal {
                        self.finishRecognition(error: nil)
                        return
                    }
                }

                if let error {
                    if self.isFinishing {
                        self.finishRecognition(error: error)
                    } else {
                        self.failRecognition(error)
                    }
                }
            }
        }
    }

    func pause() {
        stopAudioCapture()
    }

    func resume() throws {
        guard let engine = audioEngine, request != nil, !engine.isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NoteDictationService.DictationError.recorderUnavailable
        }
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Stop microphone capture while allowing Speech to finish consuming already
    /// appended buffers. A timeout flushes the latest preview as a final result.
    func finish(completion: @escaping (Error?) -> Void) {
        guard audioEngine != nil else {
            completion(NoteDictationService.DictationError.recorderUnavailable)
            return
        }
        finishHandler = completion
        isFinishing = true
        stopAudioCapture()
        request?.endAudio()

        let timeout = DispatchWorkItem { [weak self] in
            self?.finishRecognition(error: nil)
        }
        finishTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    func cancel() {
        finishTimeout?.cancel()
        finishTimeout = nil
        finishHandler = nil
        isFinishing = false
        stopAudioCapture()
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        recognizer = nil
        audioEngine = nil
        assembler.reset()
        onPartial?("")
    }

    private func stopAudioCapture() {
        guard let engine = audioEngine else { return }
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func failRecognition(_ error: Error) {
        guard !isFinishing else {
            finishRecognition(error: error)
            return
        }
        stopAudioCapture()
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        recognizer = nil
        audioEngine = nil
        let update = assembler.finish()
        if !update.committedDelta.isEmpty {
            onCommittedDelta?(update.committedDelta)
        }
        onPartial?("")
        onFailure?(error)
    }

    private func finishRecognition(error: Error?) {
        guard isFinishing else { return }
        finishTimeout?.cancel()
        finishTimeout = nil

        let update = assembler.finish()
        if !update.committedDelta.isEmpty {
            onCommittedDelta?(update.committedDelta)
        }
        onPartial?("")

        let handler = finishHandler
        finishHandler = nil
        isFinishing = false
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        recognizer = nil
        audioEngine = nil
        handler?(error)
    }
}
