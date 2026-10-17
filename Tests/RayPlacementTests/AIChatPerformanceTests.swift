import Combine
import Foundation
import Testing
@testable import RayPlacement

@Test @MainActor func streamingPresentationKeepsCompletedRowsStableAndPublishesBatches() {
    let completed = AIChatMessage(role: .assistant, text: "Completed answer")
    let active = AIChatMessage(role: .assistant, text: "")
    let presentation = AIStreamingPresentation()

    presentation.begin(assistantID: active.id)
    let startedRevision = presentation.snapshot.revision
    presentation.append(text: "A batched answer", reasoning: "A brief summary")

    #expect(presentation.snapshot.revision == startedRevision + 1)
    #expect(presentation.visibleText(for: active.id, fallback: active.text) == "A batched answer")
    #expect(presentation.visibleReasoningSummary(for: active.id, fallback: nil) == "A brief summary")
    #expect(presentation.visibleText(for: completed.id, fallback: completed.text) == "Completed answer")
    #expect(presentation.visibleReasoningSummary(for: completed.id, fallback: "cached") == "cached")
}

@Test @MainActor func largeStreamingBatchPublishesOneObservableSnapshot() {
    let presentation = AIStreamingPresentation()
    let messageID = UUID()
    var changeCount = 0
    let observation = presentation.objectWillChange.sink { _ in changeCount += 1 }

    presentation.begin(assistantID: messageID)
    changeCount = 0
    let response = String(repeating: "streamed content ", count: 8_000)
    let startedAt = ContinuousClock.now
    presentation.append(text: response, reasoning: String(repeating: "summary ", count: 1_000))
    let publishElapsed = ContinuousClock.now - startedAt

    #expect(publishElapsed < .milliseconds(16), "Large stream batch publication exceeded one 60 FPS frame.")
    #expect(changeCount == 1)
    #expect(presentation.snapshot.revision == 2)
    #expect(presentation.visibleText(for: messageID, fallback: "") == response)
    _ = observation
}

@Test func providerEventBatcherPreservesOrderAndCoalescesTwentyKilobytes() async throws {
    let stream = AsyncThrowingStream<AIChatStreamEvent, Error> { continuation in
        continuation.yield(.reasoningSummaryDelta("thinking"))
        for _ in 0..<20_000 { continuation.yield(.textDelta("x")) }
        continuation.yield(.activity(AIAgentActivity(kind: .completed, title: "Done", completed: true)))
        continuation.yield(.completed(nil))
        continuation.finish()
    }
    var events: [AIChatStreamEvent] = []
    for try await batch in AIProviderEventBatcher.batches(stream) { events += batch }
    #expect(events.count < 1_000)
    guard case .reasoningSummaryDelta("thinking") = events.first else {
        Issue.record("Reasoning must remain ahead of later visible text.")
        return
    }
    let output = events.compactMap { event -> String? in
        if case .textDelta(let text) = event { return text }
        return nil
    }.joined()
    #expect(output == String(repeating: "x", count: 20_000))
    guard case .completed = events.last else {
        Issue.record("The terminal event must remain after all visible output.")
        return
    }
}

@Test @MainActor func conversationUpdatePublishesOneSnapshot() {
    let store = AIConversationStore(fixtures: [])
    var changes = 0
    let observation = store.objectWillChange.sink { _ in changes += 1 }
    var conversation = store.createConversation(model: "gpt-5")
    changes = 0
    conversation.messages.append(AIChatMessage(role: .user, text: "One prompt"))
    store.update(conversation)
    #expect(changes == 1)
    #expect(store.conversations.first?.messages.count == 1)
    #expect(store.conversationSummaries.first?.id == conversation.id)
    #expect(store.conversationSummaries.first?.preview == "One prompt")
    _ = observation
}

@Test @MainActor func conversationSidebarPublishesBoundedMetadataInsteadOfMessageBodies() {
    let store = AIConversationStore(fixtures: [])
    var conversation = store.createConversation(model: "gpt-5")
    let body = String(repeating: "Large response. ", count: 12_000)
    conversation.messages.append(AIChatMessage(role: .assistant, text: body))
    store.update(conversation)

    let summary = store.conversationSummaries.first
    #expect(summary?.id == conversation.id)
    #expect((summary?.preview.count ?? 0) <= 92)
    #expect(summary?.preview != body)
    #expect(store.conversation(id: conversation.id)?.messages.last?.text == body)
}

@Test @MainActor func conversationShutdownFlushPersistsNewestSnapshot() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lima-ai-store-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("conversations.json")
    let store = AIConversationStore(storageURL: url)
    var conversation = store.createConversation(model: "gpt-5")
    conversation.messages.append(AIChatMessage(role: .user, text: "first"))
    store.update(conversation)
    conversation.messages.append(AIChatMessage(role: .assistant, text: "durable final answer"))
    store.update(conversation)
    store.flushPendingWrites()

    let restored = AIConversationStore(storageURL: url)
    #expect(restored.conversation(id: conversation.id)?.messages.last?.text == "durable final answer")
    let permissions = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    #expect(permissions == 0o600)
}

@Test @MainActor func largeConversationBodyPersistsOutsideMetadataWithPrivatePermissions() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lima-ai-body-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("conversations.json")
    let store = AIConversationStore(storageURL: url)
    var conversation = store.createConversation(model: "gpt-5")
    let marker = "PRIVATE_BODY_MARKER_\(UUID().uuidString)"
    let body = String(repeating: "Long assistant response. ", count: 1_000) + marker
    let message = AIChatMessage(role: .assistant, text: body)
    conversation.messages.append(message)
    store.update(conversation)
    store.flushPendingWrites()

    let metadataData = try Data(contentsOf: url)
    let metadataText = try #require(String(data: metadataData, encoding: .utf8))
    #expect(!metadataText.contains(marker))
    let stored = try JSONDecoder().decode([AIConversation].self, from: metadataData)
    let storedMessage = try #require(stored.first?.messages.first)
    #expect(storedMessage.text.isEmpty)
    let reference = try #require(storedMessage.textStorageReference)
    let bodyDirectory = directory.appendingPathComponent("messages", isDirectory: true)
    let bodyURL = bodyDirectory.appendingPathComponent(reference)
    #expect(try String(contentsOf: bodyURL, encoding: .utf8) == body)
    #expect(try FileManager.default.attributesOfItem(atPath: bodyDirectory.path)[.posixPermissions] as? Int == 0o700)
    #expect(try FileManager.default.attributesOfItem(atPath: bodyURL.path)[.posixPermissions] as? Int == 0o600)

    let restored = AIConversationStore(storageURL: url)
    let restoredMessage = try #require(restored.conversation(id: conversation.id)?.messages.first)
    #expect(restoredMessage.text == body)
    #expect(restoredMessage.renderRevision == message.renderRevision)
    #expect(restored.lastError == nil)

    try FileManager.default.removeItem(at: bodyURL)
    let missingBodyStore = AIConversationStore(storageURL: url)
    #expect(missingBodyStore.conversations.isEmpty)
    #expect(missingBodyStore.lastError != nil)
    #expect(try Data(contentsOf: url) == metadataData)
}

@Test func conversationBodyBlobRepairsCorruptionAndPrunesOnlySupersededReferences() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lima-ai-body-gc-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("conversations.json")
    let bodyDirectory = directory.appendingPathComponent("messages", isDirectory: true)
    var message = AIChatMessage(role: .assistant, text: String(repeating: "first body ", count: 1_000))
    var conversation = AIConversation(model: "gpt-5", messages: [message])
    try AIConversationPersistence.persist([conversation], to: url)
    let firstMetadata = try JSONDecoder().decode([AIConversation].self, from: Data(contentsOf: url))
    let firstReference = try #require(firstMetadata.first?.messages.first?.textStorageReference)
    let firstURL = bodyDirectory.appendingPathComponent(firstReference)

    try Data("corrupted".utf8).write(to: firstURL)
    try AIConversationPersistence.persist([conversation], to: url)
    #expect(try AIConversationPersistence.load(from: url).first?.messages.first?.text == message.text)

    let unrelatedURL = bodyDirectory.appendingPathComponent("user-note.txt")
    try Data("leave me alone".utf8).write(to: unrelatedURL)
    message.text = String(repeating: "second body ", count: 1_000)
    conversation.messages = [message]
    try AIConversationPersistence.persist([conversation], to: url)
    let secondMetadata = try JSONDecoder().decode([AIConversation].self, from: Data(contentsOf: url))
    let secondReference = try #require(secondMetadata.first?.messages.first?.textStorageReference)
    #expect(secondReference != firstReference)
    #expect(!FileManager.default.fileExists(atPath: firstURL.path))
    #expect(FileManager.default.fileExists(atPath: bodyDirectory.appendingPathComponent(secondReference).path))
    #expect(FileManager.default.fileExists(atPath: unrelatedURL.path))
    #expect(try AIConversationPersistence.load(from: url).first?.messages.first?.text == message.text)
}

@Test @MainActor func legacyInlineConversationLoadsWithoutBlobMigrationOnRead() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lima-ai-legacy-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("conversations.json")
    let legacy = AIConversation(model: "gpt-5", messages: [
        AIChatMessage(role: .assistant, text: String(repeating: "Legacy body. ", count: 1_000))
    ])
    let legacyData = try JSONEncoder().encode([legacy])
    try legacyData.write(to: url)
    let restored = AIConversationStore(storageURL: url)
    #expect(restored.conversation(id: legacy.id)?.messages.first?.text == legacy.messages.first?.text)
    #expect(try Data(contentsOf: url) == legacyData)
}

@Test func completedMessageRenderCacheIsStableAndRevisionAware() throws {
    var message = AIChatMessage(
        id: UUID(),
        role: .assistant,
        text: String(repeating: "# Cached heading\\n\\nA completed response.\\n\\n", count: 20),
        reasoningSummary: "Verified summary",
        activities: [AIAgentActivity(kind: .toolCompleted, title: "Search", completed: true)]
    )
    let original = AIMessageRenderModel.cached(for: message)

    #expect(original === AIMessageRenderModel.cached(for: message))
    #expect(original.text == message.text)
    #expect(original.reasoningSummary == "Verified summary")
    #expect(original.completedActivityCount == 1)

    let originalRevision = message.renderRevision
    message.text += "\\nAdditional verified detail."
    #expect(message.renderRevision == originalRevision + 1)
    let updated = AIMessageRenderModel.cached(for: message)
    #expect(updated !== original)
    #expect(updated.text == message.text)

    let encoded = try JSONEncoder().encode(message)
    var legacyRecord = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacyRecord.removeValue(forKey: "renderRevision")
    let legacyData = try JSONSerialization.data(withJSONObject: legacyRecord)
    let decodedLegacyMessage = try JSONDecoder().decode(AIChatMessage.self, from: legacyData)
    #expect(decodedLegacyMessage.renderRevision == 0)
}

@Test func longConversationWindowBoundsMountedMessagesWithoutDroppingHistory() {
    let codeMarkdown = String(repeating: "```swift\nlet result = 42\n```\n", count: 32)
    let fixtureActivity = AIAgentActivity(kind: .started, title: "Fixture action", completed: true)
    let messages = (0..<500).map { index in
        AIChatMessage(
            role: index.isMultiple(of: 2) ? .user : .assistant,
            text: "Message \(index)\n\n" + codeMarkdown,
            reasoningSummary: index.isMultiple(of: 2) ? nil : "Verified fixture step",
            activities: index.isMultiple(of: 2) ? nil : Array(repeating: fixtureActivity, count: 5)
        )
    }

    let recent = AIMessageHistoryWindow.visibleMessages(from: messages, limit: AIMessageHistoryWindow.initialLimit)
    #expect(recent.count == 50)
    #expect(recent.first?.id == messages[450].id)
    #expect(recent.last?.id == messages[499].id)

    let expandedLimit = AIMessageHistoryWindow.nextLimit(current: recent.count, total: messages.count)
    let expanded = AIMessageHistoryWindow.visibleMessages(from: messages, limit: expandedLimit)
    #expect(expanded.count == 100)
    #expect(expanded.first?.id == messages[400].id)
    #expect(messages.count == 500)

    let oneHundred = Array(messages.prefix(100))
    #expect(AIMessageHistoryWindow.visibleMessages(from: oneHundred, limit: 100).count == 100)
    #expect(AIMessageHistoryWindow.nextLimit(current: 100, total: 100) == 100)
}

@Test @MainActor func largeConversationProjectionAndCachedRowsMeetFrameBudgets() {
    let codeMarkdown = String(repeating: "```swift\nlet result = 42\n```\n", count: 32)
    let activity = AIAgentActivity(kind: .toolCompleted, title: "Verified action", completed: true)
    let messages = (0..<500).map { index in
        AIChatMessage(
            role: index.isMultiple(of: 2) ? .user : .assistant,
            text: "Message \(index)\n\n" + codeMarkdown,
            reasoningSummary: index.isMultiple(of: 2) ? nil : "Completed",
            activities: index.isMultiple(of: 2) ? nil : Array(repeating: activity, count: 8)
        )
    }
    let clock = ContinuousClock()

    let openStarted = clock.now
    let opened = AIMessageHistoryWindow.visibleMessages(from: messages, limit: AIMessageHistoryWindow.initialLimit)
    let openElapsed = clock.now - openStarted
    #expect(opened.count == 50)
    #expect(openElapsed < .milliseconds(16), "500-message window projection exceeded one 60 FPS frame.")

    let coldStarted = clock.now
    let cachedRows = opened.map(AIMessageRenderModel.cached(for:))
    let coldRenderElapsed = clock.now - coldStarted
    #expect(cachedRows.count == 50)
    #expect(coldRenderElapsed < .milliseconds(200), "Cold completed-message snapshots exceeded the open budget.")

    let secondConversation = (0..<500).map { index in
        AIChatMessage(
            role: index.isMultiple(of: 2) ? .user : .assistant,
            text: "Second conversation \(index)\n\n" + codeMarkdown,
            activities: index.isMultiple(of: 2) ? nil : Array(repeating: activity, count: 8)
        )
    }
    let secondVisible = AIMessageHistoryWindow.visibleMessages(from: secondConversation, limit: AIMessageHistoryWindow.initialLimit)
    let secondCachedRows = secondVisible.map(AIMessageRenderModel.cached(for:))

    let switchStarted = clock.now
    let switchedMessages = AIMessageHistoryWindow.visibleMessages(from: secondConversation, limit: AIMessageHistoryWindow.initialLimit)
    let switchedRows = switchedMessages.map(AIMessageRenderModel.cached(for:))
    let switchElapsed = clock.now - switchStarted
    #expect(switchedRows.count == 50)
    #expect(switchElapsed < .milliseconds(16), "Warm chat-switch projection and cached lookups exceeded one 60 FPS frame.")

    func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1_000_000_000_000_000
    }
    print("AI Chat core performance: 500-message open projection \(milliseconds(openElapsed)) ms; 50 cold row snapshots \(milliseconds(coldRenderElapsed)) ms; warm conversation switch \(milliseconds(switchElapsed)) ms. SwiftUI layout and scrolling are not measured by this fixture.")
    _ = cachedRows
    _ = secondCachedRows
}

@Test @MainActor func stopCancellationRequestMeetsResponsivenessBudget() async {
    let registry = TaskRegistry()
    let model = AIChatViewModel(
        store: AIConversationStore(fixtures: []),
        credentials: AIChatCredentialStore(configuration: .fixture),
        nativeToolStore: LimaAIToolStore(fixtures: []),
        transport: FixtureAITransport(
            events: [.responseCreated("slow-fixture"), .textDelta("partial"), .completed("slow-fixture")],
            interEventDelay: .seconds(30)
        ),
        taskRegistry: registry
    )
    model.draft = "Cancel the active fixture."
    model.send()

    let startedAt = ContinuousClock.now
    model.cancel()
    let elapsed = ContinuousClock.now - startedAt
    #expect(elapsed < .milliseconds(100), "The stop action exceeded its 100 ms responsiveness budget.")

    for _ in 0..<100 where !registry.activeTasks.isEmpty { await Task.yield() }
    #expect(registry.activeTasks.isEmpty)
}
