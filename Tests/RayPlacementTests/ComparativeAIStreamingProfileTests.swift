import Combine
import Foundation
import Testing
@testable import RayPlacement

/// Opt-in fixture probe shared verbatim with the v3.14.24 worktree.
@Test @MainActor func comparativeAIStreamingProfile() async {
    guard ProcessInfo.processInfo.environment["LIMA_RUN_PERFORMANCE_PROFILE"] == "1" else { return }

    let delta = "0123456789"
    let deltaCount = 2_000
    let responseID = "profile-response"
    let events: [AIChatStreamEvent] =
        [.responseCreated(responseID)]
        + Array(repeating: .textDelta(delta), count: deltaCount)
        + [.completed(responseID)]
    let expectedText = String(repeating: delta, count: deltaCount)
    let clock = ProcessInfo.processInfo
    var sendMainSamples: [Double] = []
    var completionSamples: [Double] = []
    var storePublicationSamples: [Int] = []
    var modelPublicationSamples: [Int] = []

    for iteration in 0..<14 {
        let store = AIConversationStore(fixtures: [])
        let model = AIChatViewModel(
            store: store,
            credentials: AIChatCredentialStore(configuration: .fixture),
            nativeToolStore: LimaAIToolStore(fixtures: []),
            transport: FixtureAITransport(events: events)
        )
        var storePublishes = 0
        var modelPublishes = 0
        let storeObserver = store.objectWillChange.sink { _ in storePublishes += 1 }
        let modelObserver = model.objectWillChange.sink { _ in modelPublishes += 1 }

        model.draft = "Return a 20 KB fixture response."
        let startedAt = clock.systemUptime
        model.send()
        let sendMainMS = (clock.systemUptime - startedAt) * 1_000
        for _ in 0..<30_000 where model.canEndTask {
            try? await Task.sleep(for: .milliseconds(1))
        }
        let completionMS = (clock.systemUptime - startedAt) * 1_000

        let assistant = store.conversations.first?.messages.last(where: { $0.role == .assistant })
        #expect(!model.canEndTask)
        #expect(model.executionRun?.state == .completed)
        #expect(assistant?.text == expectedText)
        if iteration >= 2 {
            sendMainSamples.append(sendMainMS)
            completionSamples.append(completionMS)
            storePublicationSamples.append(storePublishes)
            modelPublicationSamples.append(modelPublishes)
        }
        _ = storeObserver
        _ = modelObserver
    }

    func percentile<T: Comparable>(_ samples: [T], _ fraction: Double) -> T {
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))
        return sorted[index]
    }
    func milliseconds(_ value: Double) -> String { String(format: "%.3f", value) }
    print("LIMA_PROFILE_AI_STREAM sendMainP50MS=\(milliseconds(percentile(sendMainSamples, 0.5))) sendMainP95MS=\(milliseconds(percentile(sendMainSamples, 0.95))) completionP50MS=\(milliseconds(percentile(completionSamples, 0.5))) completionP95MS=\(milliseconds(percentile(completionSamples, 0.95))) storePublishesP50=\(percentile(storePublicationSamples, 0.5)) modelPublishesP50=\(percentile(modelPublicationSamples, 0.5)) bytes=\(expectedText.utf8.count)")
}
