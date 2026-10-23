import Foundation
import Testing
import WebKit
@testable import RayPlacement

private final class QuestionOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [[String: Any]] = []

    func record(_ outputs: [[String: Any]]) {
        lock.lock()
        captured = outputs
        lock.unlock()
    }

    var outputs: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }
}

@Test func userQuestionParsesAllFourKindsAndValidatesAnswers() throws {
    let runID = UUID()
    let kinds: [(String, String)] = [
        ("single_choice", #"{"kind":"single_choice","question":"Which project?","options":[{"id":"a","label":"A"},{"id":"b","label":"B"}],"allow_other":true}"#),
        ("multiple_choice", #"{"kind":"multiple_choice","question":"Which features?","options":[{"id":"a","label":"A"},{"id":"b","label":"B"}],"minimum_selections":1}"#),
        ("free_response", #"{"kind":"free_response","question":"What headline?","multiline":true}"#),
        ("confirmation", #"{"kind":"confirmation","question":"Replace the prototype?","confirm_label":"Replace","cancel_label":"Keep"}"#)
    ]
    for (name, raw) in kinds {
        let question = try #require(AIUserQuestionTools.parse(raw, runID: runID))
        #expect(question.runID == runID)
        #expect(question.kind.rawValue == name)
        let stale = AIUserQuestionResponse(questionID: UUID(), selectedOptionIDs: ["a"], text: nil)
        #expect(!stale.isValid(for: question))
    }

    let choice = try #require(AIUserQuestionTools.parse(kinds[0].1, runID: runID))
    #expect(AIUserQuestionResponse(questionID: choice.id, selectedOptionIDs: ["a"], text: nil).isValid(for: choice))
    #expect(!AIUserQuestionResponse(questionID: choice.id, selectedOptionIDs: ["a", "b"], text: nil).isValid(for: choice))
    #expect(AIUserQuestionResponse(questionID: choice.id, selectedOptionIDs: ["other"], text: "New project").isValid(for: choice))
    #expect(!AIUserQuestionResponse(questionID: choice.id, selectedOptionIDs: ["other"], text: " ").isValid(for: choice))

    let multi = try #require(AIUserQuestionTools.parse(kinds[1].1, runID: runID))
    #expect(AIUserQuestionResponse(questionID: multi.id, selectedOptionIDs: ["a", "b"], text: nil).isValid(for: multi))
    #expect(!AIUserQuestionResponse(questionID: multi.id, selectedOptionIDs: ["a", "a"], text: nil).isValid(for: multi))
    let free = try #require(AIUserQuestionTools.parse(kinds[2].1, runID: runID))
    #expect(AIUserQuestionResponse(questionID: free.id, selectedOptionIDs: [], text: "Track spending").isValid(for: free))
    let confirmation = try #require(AIUserQuestionTools.parse(kinds[3].1, runID: runID))
    #expect(AIUserQuestionResponse(questionID: confirmation.id, selectedOptionIDs: ["cancel"], text: nil).isValid(for: confirmation))

    let projectChoice = try #require(AIUserQuestionTools.parse(
        #"{"kind":"single_choice","purpose":"project_resolution","question":"Reuse the existing dashboard?","options":[{"id":"existing","label":"Use Finance Dashboard"},{"id":"create_new_project","label":"Create a new project"}]}"#,
        runID: runID
    ))
    #expect(projectChoice.purpose == .projectResolution)
    #expect(AIUserQuestionResponse(questionID: projectChoice.id,
        selectedOptionIDs: ["create_new_project"], text: nil).isValid(for: projectChoice))
    #expect(AIUserQuestionTools.parse(
        #"{"kind":"single_choice","purpose":"project_resolution","question":"Choose","options":[{"id":"existing","label":"Existing"},{"id":"create_new_project","label":"Other thing"}]}"#,
        runID: runID
    ) == nil)
}

@Test func userQuestionRejectsMalformedPayloadsAndPersistsPendingRun() throws {
    let runID = UUID()
    #expect(AIUserQuestionTools.parse(#"{"kind":"single_choice","question":"Pick","options":[{"id":"a","label":"A"},{"id":"a","label":"Again"}]}"#, runID: runID) == nil)
    #expect(AIUserQuestionTools.parse(#"{"kind":"free_response","question":" ","options":[]}"#, runID: runID) == nil)
    #expect(AIUserQuestionTools.parse(#"{"kind":"confirmation","question":"Proceed?","options":[{"id":"a","label":"A"}]}"#, runID: runID) == nil)

    var run = AIExecutionRun(id: runID, conversationID: UUID(), userMessageID: UUID(),
        assistantMessageID: UUID(),
        providerConfigurationSnapshot: AIExecutionProviderConfigurationSnapshot(
            providerID: "openAI", modelID: "gpt-5", reasoningEffort: "medium"),
        toolConfigurationSnapshot: AIExecutionToolConfigurationSnapshot(
            localToolIDs: ["request_user_input"]))
    let question = try #require(AIUserQuestionTools.parse(#"{"kind":"free_response","question":"What headline?"}"#, runID: runID))
    let beganQuestion = run.beginQuestion(question)
    #expect(beganQuestion)
    #expect(run.state == .waitingForUserInput)
    #expect(run.isActive && !run.isStreaming)
    let incidentalTransition = run.transition(to: .runningTools)
    #expect(!incidentalTransition)
    #expect(run.pendingQuestion == question)
    let decoded = try JSONDecoder().decode(AIExecutionRun.self, from: JSONEncoder().encode(run))
    #expect(decoded.pendingQuestion == question)
    let rejectedStaleQuestion = run.resumeQuestion(UUID())
    #expect(!rejectedStaleQuestion)
    let resumedQuestion = run.resumeQuestion(question.id)
    #expect(resumedQuestion)
    #expect(run.pendingQuestion == nil)
    #expect(run.state == .runningTools)
}

@Test @MainActor func userQuestionResumesSameAIExecutionRunWithStructuredToolOutput() async throws {
    let capture = QuestionOutputCapture()
    var transport = FixtureAITransport(events: [
        .responseCreated("question-response"),
        .outputItem(AIOutputItem(
            phase: .completed, apiType: "function_call", callID: "question-call",
            name: "request_user_input",
            arguments: #"{"kind":"single_choice","title":"Choose a project","question":"Which project should I use?","options":[{"id":"a","label":"Dashboard A"},{"id":"b","label":"Dashboard B"}]}"#
        )),
        .completed("question-response")
    ])
    transport.toolOutputEvents = [
        .responseCreated("answer-response"),
        .textDelta("I will use Dashboard B."),
        .completed("answer-response")
    ]
    transport.onToolOutputs = { outputs, _ in capture.record(outputs) }
    let store = AIConversationStore(fixtures: [])
    let registry = TaskRegistry()
    let model = AIChatViewModel(
        store: store,
        credentials: AIChatCredentialStore(configuration: .fixture),
        nativeToolStore: LimaAIToolStore(fixtures: ["request_user_input"]),
        transport: transport,
        taskRegistry: registry
    )
    model.draft = "Use the right dashboard"
    model.send()
    for _ in 0..<300 where model.pendingQuestion == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    let question = try #require(model.pendingQuestion)
    let runID = try #require(model.executionRun?.id)
    let assistantID = try #require(model.executionRun?.assistantMessageID)
    #expect(model.executionRun?.state == .waitingForUserInput)
    #expect(model.canEndTask)
    #expect(!model.isStreaming)
    #expect(capture.outputs.isEmpty)
    #expect(!registry.activeTasks.isEmpty)

    model.answerUserQuestion(AIUserQuestionResponse(
        questionID: UUID(), selectedOptionIDs: ["b"], text: nil
    ))
    #expect(model.pendingQuestion?.id == question.id)
    model.answerUserQuestion(AIUserQuestionResponse(
        questionID: question.id, selectedOptionIDs: ["b"], text: nil
    ))
    for _ in 0..<300 where model.canEndTask {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.executionRun?.id == runID)
    #expect(model.executionRun?.assistantMessageID == assistantID)
    #expect(model.executionRun?.state == .completed)
    #expect(model.pendingQuestion == nil)
    #expect(registry.activeTasks.isEmpty)
    #expect(store.conversations.first?.messages.last?.text == "I will use Dashboard B.")
    let output = try #require(capture.outputs.first?["output"] as? String)
    let body = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    #expect(body["question_id"] as? String == question.id.uuidString)
    #expect(body["selected_option_ids"] as? [String] == ["b"])
    #expect(body["answered"] as? Bool == true)
}


@Test @MainActor func secureBrowserHandoffResumesSameRunWithoutReturningFieldValues() async throws {
    let browser = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    browser.aiControlMode = .fullControl
    let tab = browser.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    tab.webView.loadHTMLString("""
        <!doctype html><html><body>
        <h1>Payment fixture</h1>
        <form aria-label="Payment">
          <label>Card number <input id="card" autocomplete="cc-number" required></label>
        </form>
        </body></html>
        """, baseURL: URL(string: "https://example.com")!)
    _ = try await browser.wait(tab.id, condition: .pageStable, timeoutMilliseconds: 5_000)

    let capture = QuestionOutputCapture()
    let arguments = #"{"kind":"confirmation","purpose":"secure_browser_input","question":"Enter your card on the page","browser_tab_id":""# +
        tab.id.uuidString + #""}"#
    var transport = FixtureAITransport(events: [
        .responseCreated("secure-question-response"),
        .outputItem(AIOutputItem(
            phase: .completed, apiType: "function_call", callID: "secure-question-call",
            name: "request_user_input", arguments: arguments
        )),
        .completed("secure-question-response")
    ])
    transport.toolOutputEvents = [
        .responseCreated("secure-answer-response"),
        .textDelta("I will review the order before any final action."),
        .completed("secure-answer-response")
    ]
    transport.onToolOutputs = { outputs, _ in capture.record(outputs) }
    let model = AIChatViewModel(
        store: AIConversationStore(fixtures: []),
        credentials: AIChatCredentialStore(configuration: .fixture),
        nativeToolStore: LimaAIToolStore(fixtures: ["request_user_input"]),
        transport: transport,
        taskRegistry: TaskRegistry(),
        browserWorkspace: browser
    )
    model.draft = "Continue checkout after I enter the card"
    model.send()
    for _ in 0..<500 where model.pendingQuestion == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    let question = try #require(model.pendingQuestion)
    let runID = try #require(model.executionRun?.id)
    #expect(question.purpose == AIUserQuestionPurpose.secureBrowserInput)
    #expect(question.browserTabID == tab.id)
    #expect(question.secureFields?.count == 1)
    #expect(model.executionRun?.state == .waitingForUserInput)
    let answer = AIUserQuestionResponse(questionID: question.id,
        selectedOptionIDs: ["confirm"], text: nil)
    model.answerUserQuestion(answer)
    for _ in 0..<500 where model.secureInputError == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.secureInputError != nil)
    #expect(model.pendingQuestion?.id == question.id)
    #expect(model.executionRun?.id == runID)

    _ = try await tab.webView.evaluateJavaScript("""
        document.getElementById('card').value = '4111111111111111';
        const extra = document.createElement('input');
        extra.id = 'cvv'; extra.autocomplete = 'cc-csc'; extra.required = true;
        document.querySelector('form').appendChild(extra);
        true;
        """)
    browser.markPageChangedByUser(tab.id)
    model.answerUserQuestion(answer)
    for _ in 0..<500 where model.secureInputError == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.secureInputError?.contains("changed") == true)
    #expect(model.pendingQuestion?.id == question.id)
    #expect(model.executionRun?.state == .waitingForUserInput)

    _ = try await tab.webView.evaluateJavaScript(
        "document.getElementById('cvv').remove()"
    )
    browser.markPageChangedByUser(tab.id)
    model.answerUserQuestion(answer)
    for _ in 0..<800 where model.executionRun?.state != .completed {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.executionRun?.id == runID)
    #expect(model.executionRun?.state == .completed)
    let output = try #require(capture.outputs.first?["output"] as? String)
    #expect(!output.contains("4111111111111111"))
    let payload = try #require(JSONSerialization.jsonObject(
        with: Data(output.utf8)
    ) as? [String: Any])
    #expect(payload["values_redacted"] as? Bool == true)
    #expect(payload["fresh_browser_read_required"] as? Bool == true)
    #expect(payload["final_action_authorized"] as? Bool == false)
    let statuses = try #require(payload["secure_fields"] as? [[String: Any]])
    #expect(statuses.count == 1 && statuses[0]["filled"] as? Bool == true)
    try await browser.close(tab.id)
}



@Test @MainActor func secureBrowserHandoffRejectsSameHostRouteAndCancelStopsRun() async throws {
    let browser = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    browser.aiControlMode = .fullControl
    let tab = browser.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    tab.webView.loadHTMLString("""
        <!doctype html><html><body>
        <form><label>Card number <input id="card" autocomplete="cc-number" required></label></form>
        </body></html>
        """, baseURL: URL(string: "https://example.com")!)
    let original = try await browser.wait(tab.id, condition: .pageStable, timeoutMilliseconds: 5_000)
    let arguments = #"{"kind":"confirmation","purpose":"secure_browser_input","question":"Enter card details on this page","browser_tab_id":""# +
        tab.id.uuidString + #""}"#
    let transport = FixtureAITransport(events: [
        .responseCreated("secure-stale-response"),
        .outputItem(AIOutputItem(
            phase: .completed, apiType: "function_call", callID: "secure-stale-call",
            name: "request_user_input", arguments: arguments
        )),
        .completed("secure-stale-response")
    ])
    let model = AIChatViewModel(
        store: AIConversationStore(fixtures: []),
        credentials: AIChatCredentialStore(configuration: .fixture),
        nativeToolStore: LimaAIToolStore(fixtures: ["request_user_input"]),
        transport: transport,
        taskRegistry: TaskRegistry(),
        browserWorkspace: browser
    )
    model.draft = "Continue checkout after I enter the card"
    model.send()
    for _ in 0..<500 where model.pendingQuestion == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    let question = try #require(model.pendingQuestion)
    let runID = try #require(model.executionRun?.id)
    _ = try await tab.webView.evaluateJavaScript("""
        document.getElementById('card').value = '4111111111111111';
        history.pushState({}, '', '/different-checkout-step');
        true;
        """)
    browser.markPageChangedByUser(tab.id)
    let changed = try await browser.wait(tab.id, condition: .pageStable, timeoutMilliseconds: 5_000)
    #expect(changed.identity.documentID == original.identity.documentID)
    #expect(changed.identity.routeGeneration != original.identity.routeGeneration)
    let confirm = AIUserQuestionResponse(questionID: question.id,
        selectedOptionIDs: ["confirm"], text: nil)
    model.answerUserQuestion(confirm)
    for _ in 0..<500 where model.secureInputError == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.secureInputError?.contains("changed") == true)
    #expect(model.executionRun?.id == runID)
    #expect(model.executionRun?.state == .waitingForUserInput)

    let cancel = AIUserQuestionResponse(questionID: question.id,
        selectedOptionIDs: ["cancel"], text: nil)
    model.answerUserQuestion(cancel)
    for _ in 0..<500 where model.executionRun?.state != .cancelled {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.executionRun?.state == .cancelled)
    #expect(model.pendingQuestion == nil)
    try await browser.close(tab.id)
}

private final class ProjectChoiceFixturePlan: @unchecked Sendable {
    private let lock = NSLock()
    private var continuationIndex = 0
    private var capturedOutputs: [[[String: Any]]] = []

    var outputs: [[[String: Any]]] {
        lock.lock()
        defer { lock.unlock() }
        return capturedOutputs
    }

    var initialEvents: [AIChatStreamEvent] {
        [
            .responseCreated("project-search-response"),
            .outputItem(AIOutputItem(
                phase: .completed, apiType: "function_call", callID: "project-search-call",
                name: "project_search", arguments: #"{"query":"Finance Dashboard"}"#
            )),
            .completed("project-search-response")
        ]
    }

    func continuationStream(outputs: [[String: Any]]) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        lock.lock()
        let step = continuationIndex
        continuationIndex += 1
        capturedOutputs.append(outputs)
        lock.unlock()
        switch step {
        case 0:
            return stream([
                .responseCreated("project-choice-response"),
                .outputItem(AIOutputItem(
                    phase: .completed, apiType: "function_call", callID: "project-choice-call",
                    name: "request_user_input",
                    arguments: #"{"kind":"single_choice","purpose":"project_resolution","question":"Reuse Finance Dashboard or create a separate project?","options":[{"id":"existing","label":"Use Finance Dashboard"},{"id":"create_new_project","label":"Create a new project"}]}"#
                )),
                .completed("project-choice-response")
            ])
        case 1:
            let output = outputs.first?["output"] as? String ?? ""
            let body = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any]
            let questionID = body?["question_id"] as? String ?? ""
            let arguments = #"{"name":"Budget Charts","user_choice_question_id":""# + questionID + #""}"#
            return stream([
                .responseCreated("project-create-response"),
                .outputItem(AIOutputItem(
                    phase: .completed, apiType: "function_call", callID: "project-create-call",
                    name: "project_create", arguments: arguments
                )),
                .completed("project-create-response")
            ])
        default:
            return stream([
                .responseCreated("project-finished-response"),
                .textDelta("Created the separate project."),
                .completed("project-finished-response")
            ])
        }
    }

    private func stream(_ events: [AIChatStreamEvent]) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

@Test @MainActor func projectDiscoveryChoiceAndCreationContinueInTheSameAIRun() async throws {
    let existing = AIProject(name: "Finance Dashboard")
    let projects = AIWorkspaceStore(fixtures: [existing])
    let conversations = AIConversationStore(fixtures: [])
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("LimaProjectChoiceRun-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = AIProjectManager(store: projects, paths: AIWorkspacePaths(root: root))
    let plan = ProjectChoiceFixturePlan()
    var transport = FixtureAITransport(events: plan.initialEvents)
    transport.toolOutputStream = { outputs, _ in plan.continuationStream(outputs: outputs) }
    let model = AIChatViewModel(
        store: conversations,
        credentials: AIChatCredentialStore(configuration: .fixture),
        nativeToolStore: LimaAIToolStore(
            fixtures: ["project_search", "request_user_input", "project_create"],
            accessMode: .fullControl
        ),
        transport: transport,
        workspaceStore: projects,
        projectToolManager: manager
    )
    model.draft = "Add budgeting charts to my Finance Dashboard"
    model.send()
    for _ in 0..<500 where model.pendingQuestion == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    let question = try #require(model.pendingQuestion)
    let runID = try #require(model.executionRun?.id)
    #expect(model.executionRun?.state == .waitingForUserInput)
    #expect(projects.projects.count == 1)
    #expect(plan.outputs.count == 1)
    let discoveryOutput = try #require(plan.outputs.first?.first?["output"] as? String)
    let discovery = try #require(JSONSerialization.jsonObject(with: Data(discoveryOutput.utf8)) as? [String: Any])
    let matches = try #require(discovery["matches"] as? [[String: Any]])
    #expect(matches.first?["project_id"] as? String == existing.id.uuidString)
    let resolution = try #require(discovery["resolution"] as? [String: Any])
    #expect(resolution["kind"] as? String == "existing")
    model.answerUserQuestion(AIUserQuestionResponse(
        questionID: question.id, selectedOptionIDs: ["create_new_project"], text: nil
    ))
    for _ in 0..<500 where model.executionRun?.state != .completed {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.pendingApproval == nil)
    #expect(model.executionRun?.id == runID)
    #expect(model.executionRun?.state == .completed)
    #expect(projects.projects.count == 2)
    let newProject = try #require(projects.projects.first(where: { $0.name == "Budget Charts" }))
    #expect(conversations.conversations.first?.projectID == newProject.id)
    #expect(FileManager.default.fileExists(atPath: manager.paths.project(newProject.id).path))
    let batches = plan.outputs
    #expect(batches.count == 3)
    let answerOutput = try #require(batches[1].first?["output"] as? String)
    let answer = try #require(JSONSerialization.jsonObject(with: Data(answerOutput.utf8)) as? [String: Any])
    #expect(answer["question_id"] as? String == question.id.uuidString)
    #expect(answer["selected_option_ids"] as? [String] == ["create_new_project"])
    let creationOutput = try #require(batches[2].first?["output"] as? String)
    let creation = try #require(JSONSerialization.jsonObject(with: Data(creationOutput.utf8)) as? [String: Any])
    #expect(creation["attached_to_conversation"] as? Bool == true)
}

@Test @MainActor func endingQuestionCancelsSameRunWithoutToolContinuation() async throws {
    let capture = QuestionOutputCapture()
    var transport = FixtureAITransport(events: [
        .responseCreated("cancel-question"),
        .outputItem(AIOutputItem(
            phase: .completed, apiType: "function_call", callID: "cancel-call",
            name: "request_user_input",
            arguments: #"{"kind":"free_response","question":"What should I write?"}"#
        )),
        .completed("cancel-question")
    ])
    transport.toolOutputEvents = [.textDelta("Must not appear"), .completed("late-answer")]
    transport.onToolOutputs = { outputs, _ in capture.record(outputs) }
    let model = AIChatViewModel(
        store: AIConversationStore(fixtures: []),
        credentials: AIChatCredentialStore(configuration: .fixture),
        nativeToolStore: LimaAIToolStore(fixtures: ["request_user_input"]),
        transport: transport
    )
    model.draft = "Ask a question"
    model.send()
    for _ in 0..<300 where model.pendingQuestion == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    let question = try #require(model.pendingQuestion)
    model.endTask()
    for _ in 0..<300 where model.executionRun?.isActive == true {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.executionRun?.state == .cancelled)
    #expect(model.pendingQuestion == nil)
    #expect(capture.outputs.isEmpty)
    model.answerUserQuestion(AIUserQuestionResponse(
        questionID: question.id, selectedOptionIDs: [], text: "Too late"
    ))
    #expect(model.executionRun?.state == .cancelled)
}
