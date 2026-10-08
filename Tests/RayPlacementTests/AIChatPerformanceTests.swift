import Combine
import Foundation
import Testing
@testable import RayPlacement

@Test @MainActor func streamingPresentationKeepsCompletedRowsStableAndPublishesBatches() {
    let completed = AIChatMessage(role: .assistant, text: "Completed answer")
    let active = AIChatMessage(role: .assistant, text: "")
    let presentation = AIStreamingPresentation()

    presentation.begin(assistantID: active.id)
    let startedRevision = presentation.revision
    presentation.append(text: "A batched answer", reasoning: "A brief summary")

    #expect(presentation.revision == startedRevision + 1)
    #expect(presentation.visibleText(for: active.id, fallback: active.text) == "A batched answer")
    #expect(presentation.visibleReasoningSummary(for: active.id, fallback: nil) == "A brief summary")
    #expect(presentation.visibleText(for: completed.id, fallback: completed.text) == "Completed answer")
    #expect(presentation.visibleReasoningSummary(for: completed.id, fallback: "cached") == "cached")
}

@Test @MainActor func largeStreamingBatchPublishesOneRevisionWithoutObservingMessageStrings() {
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
    #expect(presentation.revision == 2)
    #expect(presentation.visibleText(for: messageID, fallback: "") == response)
    _ = observation
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
    #expect(recent.count == 100)
    #expect(recent.first?.id == messages[400].id)
    #expect(recent.last?.id == messages[499].id)

    let expandedLimit = AIMessageHistoryWindow.nextLimit(current: recent.count, total: messages.count)
    let expanded = AIMessageHistoryWindow.visibleMessages(from: messages, limit: expandedLimit)
    #expect(expanded.count == 200)
    #expect(expanded.first?.id == messages[300].id)
    #expect(messages.count == 500)

    let oneHundred = Array(messages.prefix(100))
    #expect(AIMessageHistoryWindow.visibleMessages(from: oneHundred, limit: 100).count == 100)
    #expect(AIMessageHistoryWindow.nextLimit(current: 100, total: 100) == 100)
}

@Test func largeMarkdownBlockAndInlineCachesReuseCompletedRenders() {
    let markdown = "# Large response\n\n"
        + String(repeating: "A verified paragraph with **bold text** and `inline code`.\n\n", count: 1_000)
        + "```swift\n"
        + String(repeating: "let answer = 42\n", count: 4_000)
        + "```"
    let blocks = LimaMarkdownDocumentView.cachedDocumentIdentityForTesting(markdown)
    let inline = LimaMarkdownDocumentView.cachedInlineMarkdownIdentityForTesting("A completed **inline** summary.")

    #expect(LimaMarkdownDocumentView.cachedDocumentIdentityForTesting(markdown) == blocks)
    #expect(LimaMarkdownDocumentView.cachedInlineMarkdownIdentityForTesting("A completed **inline** summary.") == inline)
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
    #expect(opened.count == 100)
    #expect(openElapsed < .milliseconds(16), "500-message window projection exceeded one 60 FPS frame.")

    let coldStarted = clock.now
    let cachedRows = opened.map(AIMessageRenderModel.cached(for:))
    let coldRenderElapsed = clock.now - coldStarted
    #expect(cachedRows.count == 100)
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
    #expect(switchedRows.count == 100)
    #expect(switchElapsed < .milliseconds(16), "Warm chat-switch projection and cached lookups exceeded one 60 FPS frame.")

    func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1_000_000_000_000_000
    }
    print("AI Chat core performance: 500-message open projection \(milliseconds(openElapsed)) ms; 100 cold row snapshots \(milliseconds(coldRenderElapsed)) ms; warm conversation switch \(milliseconds(switchElapsed)) ms. SwiftUI layout and scrolling are not measured by this fixture.")
    _ = cachedRows
    _ = secondCachedRows
}

@Test @MainActor func stopCancellationRequestMeetsResponsivenessBudget() async {
    let registry = TaskRegistry()
    let model = AIChatViewModel(
        store: AIConversationStore(fixtures: []),
        credentials: AIChatCredentialStore(configuration: .fixture),
        mcpStore: MCPServerStore(fixtures: []),
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
