import Foundation
import Testing
@testable import RayPlacement

private func scheduledFixtureURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("tasks.json")
}

@Test @MainActor func scheduledTasksPersistDeduplicateAndExpireWithoutReplay() throws {
    let url = scheduledFixtureURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = AIScheduledTaskStore(url: url)
    let now = Date(timeIntervalSince1970: 1900000000)
    let conversation = UUID()
    let task = try store.create(conversationID: conversation, title: "Midnight reservation",
        instructions: "Try https://example.com for two. Do not pay a deposit.",
        runAt: now.addingTimeInterval(60), expiresAt: now.addingTimeInterval(1800),
        timeZone: "America/New_York", autoApproveNonpayment: true, now: now)
    let same = try store.create(conversationID: conversation, title: "Midnight reservation",
        instructions: task.instructions, runAt: task.runAt, expiresAt: task.expiresAt,
        timeZone: task.timeZone, autoApproveNonpayment: true, now: now)
    #expect(same.id == task.id)
    #expect(store.tasks.count == 1)
    #expect(store.due(at: now) == nil)
    #expect(store.due(at: task.runAt)?.id == task.id)
    let reopened = AIScheduledTaskStore(url: url)
    #expect(reopened.tasks == store.tasks)
    try reopened.update(task.id, state: .running, detail: "Trying")
    let recovered = AIScheduledTaskStore(url: url)
    #expect(recovered.tasks.first?.state == .needsAttention)
    #expect(recovered.due(at: task.runAt) == nil)
    #expect(AIScheduledTaskStore(url: url).tasks.first?.state == .needsAttention)
    try store.expire(at: task.expiresAt)
    #expect(store.tasks.first?.state == .expired)
    #expect(store.due(at: task.expiresAt) == nil)
}

@Test @MainActor func scheduledTasksRejectUnboundedDatesUnknownZonesAndMissingApprovedSites() throws {
    let url = scheduledFixtureURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = AIScheduledTaskStore(url: url)
    let now = Date()
    for (start, expiry, zone, auto) in [
        (now.addingTimeInterval(-1), now.addingTimeInterval(60), "America/New_York", false),
        (now.addingTimeInterval(60), now.addingTimeInterval(30), "America/New_York", false),
        (now.addingTimeInterval(60), now.addingTimeInterval(90000), "America/New_York", false),
        (now.addingTimeInterval(60), now.addingTimeInterval(120), "Not/A_Zone", false),
        (now.addingTimeInterval(60), now.addingTimeInterval(120), "America/New_York", true)
    ] {
        #expect(throws: AIScheduledTaskStore.TaskError.self) {
            _ = try store.create(conversationID: UUID(), title: "Task", instructions: "Try later",
                runAt: start, expiresAt: expiry, timeZone: zone, autoApproveNonpayment: auto, now: now)
        }
    }
    #expect(store.tasks.isEmpty)
}

@Test @MainActor func scheduledTaskToolKeepsConversationsSeparateAndAcknowledgesPersistence() throws {
    let url = scheduledFixtureURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = AIScheduledTaskStore(url: url)
    let conversation = UUID()
    func call(_ name: String, _ args: [String: Any]) throws -> AIOutputItem {
        AIOutputItem(phase: .completed, apiType: "function_call", callID: UUID().uuidString,
            name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self))
    }
    let formatter = ISO8601DateFormatter()
    let result = AIScheduledTaskTools.execute(try call("task_schedule", [
        "title": "Book a table", "instructions": "Check https://example.com for two; no deposit.",
        "run_at": formatter.string(from: Date().addingTimeInterval(600)),
        "expires_at": formatter.string(from: Date().addingTimeInterval(1800)),
        "time_zone": "America/New_York", "auto_approve_nonpayment": true
    ]), conversationID: conversation, store: store)
    #expect(!result.isError)
    #expect(result.output.contains("\"persisted\":true"))
    let task = try #require(store.tasks.first)
    let otherList = AIScheduledTaskTools.execute(try call("task_list", [:]), conversationID: UUID(), store: store)
    #expect(!otherList.output.contains("Book a table"))
    let wrongCancel = AIScheduledTaskTools.execute(try call("task_cancel", ["task_id": task.id.uuidString]),
        conversationID: UUID(), store: store)
    #expect(wrongCancel.isError)
    #expect(store.tasks.first?.state == .scheduled)
    let cancelled = AIScheduledTaskTools.execute(try call("task_cancel", ["task_id": task.id.uuidString]),
        conversationID: conversation, store: store)
    #expect(!cancelled.isError)
    #expect(AIScheduledTaskStore(url: url).tasks.first?.state == .cancelled)
    for definition in AIScheduledTaskTools.definitions { #expect(definition.responsePayload != nil) }
}

@Test @MainActor func gameInputAlwaysReleasesOnCancellationOrRevokedAuthority() async throws {
    var events: [String] = []
    let task = Task { @MainActor in
        try await BrowserGameInput.hold(milliseconds: 1000, press: { events.append("down") },
            release: { events.append("up") }, isAuthorized: { true })
    }
    for _ in 0..<100 where events.isEmpty { await Task.yield() }
    task.cancel()
    do { try await task.value; Issue.record("Cancelled game input should stop") } catch { }
    #expect(events == ["down", "up"])
    events = []
    var allowed = true
    do {
        try await BrowserGameInput.hold(milliseconds: 100,
            press: { events.append("down"); allowed = false }, release: { events.append("up") },
            isAuthorized: { allowed })
        Issue.record("Revoked game input should stop")
    } catch { }
    #expect(events == ["down", "up"])
    #expect(BrowserGameInput.keyCodes["Command"] == nil)
    #expect(BrowserGameInput.keyCodes["w"] != nil)
}

@Test @MainActor func scheduledTaskRunnerStartsOnceWhenDueAndPreservesAnUnsentDraft() async throws {
    let url = scheduledFixtureURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = AIScheduledTaskStore(url: url)
    let conversations = AIConversationStore(fixtures: [])
    let conversation = conversations.createConversation(provider: .openAI, model: "gpt-5")
    let model = AIChatViewModel(store: conversations, credentials: AIChatCredentialStore(configuration: .fixture),
        nativeToolStore: LimaAIToolStore(fixtures: []),
        transport: FixtureAITransport(events: [.textDelta("Availability checked."), .completed("scheduled-fixture")]),
        taskRegistry: TaskRegistry(), workspaceStore: AIWorkspaceStore(fixtures: []))
    let now = Date()
    let task = try store.create(conversationID: conversation.id, title: "Check the opening",
        instructions: "Check availability. Do not submit a reservation.",
        runAt: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(600),
        timeZone: "America/New_York", now: now.addingTimeInterval(-10))
    let runner = AIScheduledTaskRunner(store: store)
    runner.bindForTesting(model: model)
    model.draft = "My unfinished message"
    runner.tick(now: now)
    #expect(store.tasks.first?.state == .scheduled)
    #expect(model.draft == "My unfinished message")
    #expect(conversations.conversation(id: conversation.id)?.messages.isEmpty == true)
    model.draft = ""
    runner.tick(now: now)
    #expect(store.tasks.first?.state == .running)
    #expect(store.tasks.first?.runID == model.executionRun?.id)
    runner.tick(now: now)
    #expect(conversations.conversation(id: conversation.id)?.messages.filter { $0.role == .user }.count == 1)
    for _ in 0..<3000 where model.canEndTask { await Task.yield() }
    #expect(!model.canEndTask)
    runner.tick(now: now)
    #expect(store.tasks.first?.state == .finished)
    runner.tick(now: now)
    #expect(conversations.conversation(id: conversation.id)?.messages.filter { $0.role == .user }.count == 1)
    #expect(store.tasks.first?.id == task.id)
}

@Test @MainActor func independentBrowserModeCrossesSitesWithoutLeakingAuthorityToTheNextTask() {
    let approval = BrowserTaskApprovalState()
    let run = UUID()
    approval.select(.independent)
    approval.begin(runID: run, instruction: "Play a game and browse", initialURL: "https://example.com")
    #expect(approval.isAutoApproved(runID: run, url: "https://game.liamhosfeld.com"))
    #expect(approval.isWithinScope(runID: run, url: "https://another.example/path"))
    #expect(!approval.isAutoApproved(runID: UUID(), url: "https://example.com"))
    #expect(!approval.isWithinScope(runID: run, url: "javascript:alert(1)"))
    #expect(!approval.requiresActionPrompt(runID: run, toolID: "browser_game_key"))
    approval.end(runID: run)
    approval.begin(runID: UUID(), instruction: "Next task", initialURL: nil)
    #expect(approval.activeMode == .askForActions)
}

@Test func independentVisualActionsRetainPaymentAndProtectedReview() throws {
    func assessment(_ overrides: [String: Any]) throws -> BrowserVisualActionAssessment {
        var values: [String: Any] = ["label": "", "role": "canvas", "formLabel": "", "isSubmit": false,
            "isEditable": false, "isCanvas": true, "sensitive": false, "disabled": false,
            "financialContext": false, "financialTerms": [String](), "protectedContext": false]
        values.merge(overrides) { _, new in new }
        return try JSONDecoder().decode(BrowserVisualActionAssessment.self,
            from: JSONSerialization.data(withJSONObject: values))
    }
    let canvas = try assessment([:])
    #expect(canvas.requiresReview(independent: false))
    #expect(!canvas.requiresReview(independent: true))
    let payment = try assessment(["label": "Pay deposit", "financialContext": true])
    #expect(payment.requiresReview(independent: true))
    #expect(try assessment(["protectedContext": true]).decision == .blocked)
    #expect(try assessment(["sensitive": true]).decision == .blocked)
}

@Test @MainActor func surfaceToolsRejectUnknownModulesAndReportRealVisibility() throws {
    let prior = LimaSurfaceAITools.openSurface
    defer { LimaSurfaceAITools.openSurface = prior }
    var opened: [LimaWorkspaceModule] = []
    LimaSurfaceAITools.openSurface = { module in opened.append(module); return false }
    func call(_ surface: String) throws -> AIOutputItem {
        AIOutputItem(phase: .completed, apiType: "function_call", callID: UUID().uuidString,
            name: "lima_surface_open", arguments: String(decoding: try JSONSerialization.data(withJSONObject: ["surface": surface]), as: UTF8.self))
    }
    let unknown = LimaSurfaceAITools.execute(try call("unimplemented"))
    #expect(unknown.isError)
    #expect(opened.isEmpty)
    let notShown = LimaSurfaceAITools.execute(try call("notes"))
    #expect(notShown.isError)
    #expect(opened == [.notes])
    LimaSurfaceAITools.openSurface = { _ in true }
    let shown = LimaSurfaceAITools.execute(try call("browser"))
    #expect(!shown.isError)
    #expect(shown.output.contains("\"visible\":true"))
    for definition in LimaSurfaceAITools.definitions { #expect(definition.responsePayload != nil) }
}

@Test func browserCaptureCachePreservesOtherTabsWhenOnePageIsBusy() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BrowserScreenshotStore(directory: directory)
    var captures: [BrowserScreenshotResult] = []
    func save(_ tabID: UUID) async throws -> BrowserScreenshotResult {
        try await store.save(Data([0xFF, 0xD8, 0xFF, 0xD9]), for: tabID,
            width: 8, height: 8, pointWidth: 8, pointHeight: 8, authorityRevision: 0,
            readRevision: 0, navigationRevision: 0,
            pageIdentity: BrowserPageIdentity(documentID: "fixture", routeGeneration: 0,
                mutationRevision: 0, userRevision: 0, snapshotRevision: 1, url: "https://example.com"),
            viewportWidth: 8, viewportHeight: 8, frameIDs: [])
    }
    for _ in 0..<12 { captures.append(try await save(UUID())) }
    let busyTab = try #require(captures.first?.tabID)
    for _ in 0..<10 { _ = try await save(busyTab) }
    #expect(await store.capture(id: captures[0].captureID) == nil)
    for capture in captures.dropFirst() {
        #expect(await store.capture(id: capture.captureID) != nil)
        #expect(FileManager.default.fileExists(atPath: capture.fileURL.path))
    }
    await store.clear()
}

@Test @MainActor func duplicateScheduledTaskRecordsCannotStartTwiceAfterReload() throws {
    let url = scheduledFixtureURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = AIScheduledTaskStore(url: url)
    let now = Date()
    let task = try store.create(conversationID: UUID(), title: "Check availability", instructions: "Read availability",
        runAt: now.addingTimeInterval(60), expiresAt: now.addingTimeInterval(180), timeZone: "America/New_York")
    let data = try JSONEncoder().encode([task, task])
    try data.write(to: url)
    let reopened = AIScheduledTaskStore(url: url)
    #expect(reopened.error != nil)
    #expect(reopened.tasks.isEmpty)
    #expect(reopened.due(at: task.runAt) == nil)
    #expect(try Data(contentsOf: url) == data)
}
