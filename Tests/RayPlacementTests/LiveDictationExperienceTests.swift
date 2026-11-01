import Foundation
import RayPlacementCore
import Testing
@testable import RayPlacement

@Test func localSpeakerTurnsDoNotInventAnAlternatingTwoPersonIdentity() throws {
    let response = Data(#"{"transcription":[{"text":"One","speaker_turn_next":true},{"text":"Two","speaker_turn_next":true},{"text":"Three","speaker_turn_next":true},{"text":"Four"}]}"#.utf8)
    let text = try #require(LocalWhisperTranscriber.formattedTranscript(from: response))
    #expect(text.contains("Turn 3"))
    #expect(text.contains("Turn 4"))
    #expect(!text.contains("Speaker"))
}

@Test func speakerBoundaryCommitsOnceAndDoesNotReplayRecognition() {
    var assembler = TranscriptAssembler(heldWordCount: 1)
    _ = assembler.receivePartial("Hello there")
    let boundary = assembler.commitBoundary()
    #expect(boundary.committedDelta == "Hello there")
    #expect(assembler.receivePartial("Hello there").committedDelta.isEmpty)
    _ = assembler.receivePartial("Hello there welcome back")
    let next = assembler.commitBoundary()
    #expect(next.committedDelta == " welcome back")
    #expect(assembler.commitBoundary().committedDelta.isEmpty)
    var labels = DictationSpeakerAttribution()
    #expect(labels.label(boundary.committedDelta, speaker: "Alex") == "Alex: Hello there")
    #expect(labels.label(next.committedDelta, speaker: "Sam") == "\n\nSam: welcome back")
    #expect(labels.label(" everyone", speaker: "Sam") == " everyone")
    #expect(labels.label("Third person", speaker: "Lee") == "\n\nLee: Third person")
}

@Test func cloudSpeakerRequestsAndParsingPreserveMoreThanTwoVoices() throws {
    let (_, body) = try OpenAICloudTranscriber.request(audio: Data([1, 2]), apiKey: "fixture", boundary: "fixture", diarize: true)
    let request = String(decoding: body, as: UTF8.self)
    #expect(request.contains("gpt-4o-transcribe-diarize"))
    #expect(request.contains("diarized_json"))
    #expect(request.contains("chunking_strategy"))
    let data = Data(#"{"segments":[{"speaker":"A","start":0,"text":"First"},{"speaker":"B","start":1,"text":"Second"},{"speaker":"C","start":2,"text":"Third"}]}"#.utf8)
    let text = try OpenAICloudTranscriber.parseSpeakers(data, status: 200, window: 2, offset: 10)
    #expect(text.contains("[00:10] Window 2 · Speaker A: First"))
    #expect(text.contains("Speaker C: Third"))
    #expect(throws: OpenAICloudTranscriber.Failure.self) {
        try OpenAICloudTranscriber.parseSpeakers(Data(#"{"segments":[{"text":"missing identity"}]}"#.utf8), status: 200, window: 1, offset: 0)
    }
}

@Test @MainActor func cloudLiveQueueCommitsWhileRecordingAndDrainsExactlyOnceAfterStop() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let urls = [root.appendingPathComponent("one.wav"), root.appendingPathComponent("two.wav")]
    for url in urls { try Data([1, 2]).write(to: url) }
    var windows: [Int] = []
    var events: [DictationTranscriptEvent] = []
    let service = NoteDictationService(onTranscript: { _ in }, onTargetEvent: { _, event in events.append(event) },
        cloudKeyProvider: { "fixture-only" }, cloudTranscribe: { _, _, speakers, window, offset in
            #expect(speakers)
            #expect(offset == Double(window - 1) * 10)
            windows.append(window)
            return "window-\(window)"
        })
    service.prepareLiveCloudFixture(urls: urls, durations: [10, 0], target: UUID())
    await service.waitForCloudFixture()
    #expect(service.phase == .recording)
    #expect(windows == [1])
    #expect(events == [.committedDelta("window-1")])
    #expect(!FileManager.default.fileExists(atPath: urls[0].path))
    service.finishLiveCloudFixture(durations: [10, 5])
    await service.waitForCloudFixture()
    #expect(windows == [1, 2])
    #expect(service.phase == .completed)
    #expect(events.filter { $0.insertableDelta != nil }.count == 2)
    #expect(events.contains(.committedDelta("\n\nwindow-2")))
}

@Test @MainActor func cloudLiveFailurePreservesAudioAndRetriesOnlyPendingWindow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("pending.wav")
    try Data([1]).write(to: url)
    var attempts = 0
    var events: [DictationTranscriptEvent] = []
    let service = NoteDictationService(onTranscript: { _ in }, onTargetEvent: { _, event in events.append(event) },
        cloudKeyProvider: { "fixture-only" }, cloudTranscribe: { _, _, _, _, _ in
            attempts += 1
            if attempts == 1 { throw OpenAICloudTranscriber.Failure.rejected(429) }
            return "Recovered text"
        })
    service.prepareLiveCloudFixture(urls: [url], durations: [10], target: UUID())
    await service.waitForCloudFixture()
    #expect(events.isEmpty)
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(service.phase == .recording)
    service.finishLiveCloudFixture(durations: [10])
    await service.waitForCloudFixture()
    #expect(attempts == 2)
    #expect(events.filter { $0.insertableDelta != nil }.count == 1)
    #expect(service.phase == .completed)
}

@Test @MainActor func backgroundContextIsExcludedFromSavedLayoutsAndSurfaceNavigation() {
    var configuration = WorkspaceConfiguration(workspaceModules: [.home, .context, .dictation], toolModules: [])
    #expect(!configuration.visibleModules.contains(.context))
    #expect(!configuration.hiddenModules.contains(.context))
    configuration.showModule(.context)
    #expect(!configuration.visibleModules.contains(.context))
    #expect(!LimaWorkspaceModule.userFacingModules.contains(.context))
    #expect(LimaWorkspaceModule.workspaceDestinations.contains(.dictation))
}

@Test @MainActor func extensionMetadataScanAndUnchangedRegistrationAvoidRepeatedWrites() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<100 {
        let manifest = ExtensionManifest(id: "fixture.\(index)", name: "Tool \(index)", commands: [])
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("\(index).json"))
    }
    try Data("invalid".utf8).write(to: root.appendingPathComponent("invalid.json"))
    let metadata = ExtensionManagementMetadata.read(directory: root)
    #expect(metadata.count == 100)
    #expect(Set(metadata.map { $0.manifest.id }).count == 100)
    let suite = "LimaExtensionIdempotence." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let registry = ExtensionPackageManager(defaults: defaults)
    registry.register(id: "fixture", name: "Tool", version: "1", provenance: .localDeveloper, manifestHash: "same")
    let first = try #require(registry.record(for: "fixture"))
    let persisted = defaults.data(forKey: "lima.extensionPackageRecords")
    registry.register(id: "fixture", name: "Tool", version: "1", provenance: .localDeveloper, manifestHash: "same")
    #expect(registry.record(for: "fixture")?.updatedAt == first.updatedAt)
    #expect(defaults.data(forKey: "lima.extensionPackageRecords") == persisted)
}

@Test @MainActor func dictationParticipantsPersistAndOldConversationsRemainReadable() throws {
    let old = Data(#"{"id":"209D197B-1083-4D5D-9D90-5DC5EE0AFC83","startedAt":0,"modifiedAt":0,"segments":["Previous recording"],"isComplete":true}"#.utf8)
    let conversation = try JSONDecoder().decode(DictationConversation.self, from: old)
    #expect(conversation.participants == nil)
    var updated = conversation
    updated.participants = ["Alex", "Sam", "Lee"]
    let restored = try JSONDecoder().decode(DictationConversation.self, from: JSONEncoder().encode(updated))
    #expect(restored.participants == ["Alex", "Sam", "Lee"])
    #expect(restored.transcript == "Previous recording")
}

@Test @MainActor func cloudCancellationCannotCommitLateResults() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("pending.wav")
    try Data([1]).write(to: url)
    var started = false
    var events: [DictationTranscriptEvent] = []
    let service = NoteDictationService(onTranscript: { _ in }, onTargetEvent: { _, event in events.append(event) },
        cloudKeyProvider: { "fixture-only" }, cloudTranscribe: { _, _, _, _, _ in
            started = true
            // Emulate a transport finishing despite cancellation. The run token
            // must still prevent its result from reaching the conversation.
            try? await Task.sleep(for: .milliseconds(100))
            return "Late text"
        })
    service.prepareLiveCloudFixture(urls: [url], durations: [10], target: UUID())
    for _ in 0..<100 where !started { await Task.yield() }
    #expect(started)
    service.cancel()
    try await Task.sleep(for: .milliseconds(150))
    #expect(events.isEmpty)
    #expect(service.phase == .idle)
}
