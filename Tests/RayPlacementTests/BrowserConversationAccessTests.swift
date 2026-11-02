import Foundation
import Network
import Testing
import WebKit
@testable import RayPlacement

@Test @MainActor func independentBrowserGrantFollowsOnlyItsConversationAcrossTurns() throws {
    let suite = "browser-chat-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let state = BrowserTaskApprovalState(defaults: defaults)
    let chat = UUID(), other = UUID(), first = UUID(), second = UUID()
    state.selectConversation(chat)
    state.select(.independent)
    state.begin(runID: first, instruction: "Find a table", initialURL: nil, conversationID: chat)
    #expect(state.isAutoApproved(runID: first, url: "https://restaurant.example/locations"))
    #expect(state.isAutoApproved(runID: first, url: "https://booking.example/calendar"))
    state.end(runID: first)
    #expect(state.displayMode == .independent)
    state.begin(runID: second, instruction: "Continue with 7 PM", initialURL: nil, conversationID: chat)
    #expect(state.isAutoApproved(runID: second, url: "https://another-booking.example/form"))
    #expect(!state.isAutoApproved(runID: first, url: "https://booking.example/"))
    #expect(!state.requiresActionPrompt(runID: second, toolID: "browser_click"))
    state.end(runID: second)
    state.selectConversation(other)
    #expect(state.displayMode == .askForActions)
    let third = UUID()
    state.begin(runID: third, instruction: "Open a page", initialURL: nil, conversationID: other)
    #expect(state.requiresActionPrompt(runID: third, toolID: "browser_navigate"))
    #expect(!state.isAutoApproved(runID: third, url: "https://booking.example/"))
    state.end(runID: third)
    let restored = BrowserTaskApprovalState(defaults: defaults)
    restored.selectConversation(chat)
    #expect(restored.displayMode == .independent)
    restored.select(.askForActions)
    restored.begin(runID: UUID(), instruction: "Continue", initialURL: nil, conversationID: chat)
    #expect(restored.activeMode == .askForActions)
    restored.forgetConversation(chat)
    let forgotten = BrowserTaskApprovalState(defaults: defaults)
    forgotten.selectConversation(chat)
    #expect(forgotten.displayMode == .askForActions)
}

@Test @MainActor func savedBrowserTaskOverrideDoesNotChangeConversationPermission() {
    let state = BrowserTaskApprovalState()
    let chat = UUID()
    state.selectConversation(chat)
    state.select(.independent)
    state.overrideNextRun(.askForActions)
    let run = UUID()
    state.begin(runID: run, instruction: "Saved task", initialURL: nil, conversationID: chat)
    #expect(state.activeMode == .askForActions)
    state.end(runID: run)
    #expect(state.displayMode == .independent)
    let next = UUID()
    state.begin(runID: next, instruction: "Continue", initialURL: nil, conversationID: chat)
    #expect(state.activeMode == .independent)
    state.end(runID: next)
    state.select(.askForActions)
    state.overrideNextRun(.independent)
    let temporary = UUID()
    state.begin(runID: temporary, instruction: "One saved task", initialURL: nil, conversationID: chat)
    #expect(state.activeMode == .independent)
    state.end(runID: temporary)
    #expect(state.displayMode == .askForActions)
}

private final class ReservationNavigationFixture {
    let listener: NWListener
    let url: URL
    init() throws {
        let pages = [
            "/": #"""
            <!doctype html><h1>Test restaurant</h1>
            <a href="/wrong" onclick="event.preventDefault();document.getElementById('booking').hidden=false">Reservations</a>
            <iframe id="booking" hidden src="/booking" style="display:block;width:700px;height:500px;border:0"></iframe>
            <script>document.getElementById('booking').style.display='';</script>
            """#,
            "/booking": #"""
            <!doctype html><form aria-label="Table search" onsubmit="event.preventDefault();location.href='/details'">
            <label>Guests<select aria-label="Guests"><option>1</option><option>2</option><option>4</option></select></label>
            <input type="date" aria-label="Reservation date" required>
            <button type="button" role="combobox" aria-label="Choose time" aria-expanded="false"
              onpointerdown="this.setAttribute('aria-expanded','true');document.getElementById('times').hidden=false">Choose time</button>
            <div id="times" hidden><button type="button" role="option" onclick="document.getElementById('chosen').textContent='7:00 PM selected'">7:00 PM</button></div>
            <p id="chosen"></p><button>Find a table</button></form>
            """#,
            "/details": #"""
            <!doctype html><h1>Guest details</h1><form aria-label="Dinner reservation" onsubmit="event.preventDefault();document.getElementById('confirmation').textContent='Fixture confirmation: table for 2 at 7:00 PM'">
            <input aria-label="Guest name" required><button>Confirm reservation</button></form><p id="confirmation"></p>
            """#,
            "/wrong": "<!doctype html><h1>Wrong: click handler bypassed</h1>"
        ]
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "lima.reservation-fixture")
        let started = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state { case .ready, .failed: started.signal(); default: break }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let path = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let body = pages[path] ?? "<!doctype html><p>Not found</p>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
        guard started.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
            listener.cancel(); throw BrowserRuntimeError.unsupportedAction
        }
        url = URL(string: "http://127.0.0.1:\(port)/")!
    }
    deinit { listener.cancel() }
}

@Test @MainActor func independentReservationFlowClicksLinksPointerWidgetsFramesAndSubmitButtons() async throws {
    let site = try ReservationNavigationFixture()
    let browser = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    browser.aiControlMode = .fullControl
    let tab = browser.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
    let state = BrowserTaskApprovalState.shared
    let chat = UUID(), run = UUID()
    state.selectConversation(chat)
    state.select(.independent)
    state.begin(runID: run, instruction: "Test reservation fixture", initialURL: site.url.absoluteString, conversationID: chat)
    defer {
        state.end(runID: run)
        state.forgetConversation(chat)
        state.select(.askForActions)
        Task { try? await browser.close(tab.id) }
    }
    try browser.navigate(tab.id, to: site.url)
    func target(_ label: String) async throws -> BrowserTarget {
        for _ in 0..<200 {
            if let page = try? await browser.read(tab.id),
               let target = (page.links + page.controls).first(where: { $0.label == label }) { return target }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw BrowserRuntimeError.missingSnapshot
    }
    func act(_ name: String, label: String, extra: [String: Any] = [:]) async throws {
        let item = try await target(label)
        var args = extra
        args["tab_id"] = tab.id.uuidString
        args["target"] = item.id
        let data = try JSONSerialization.data(withJSONObject: args)
        let call = AIOutputItem(phase: .completed, apiType: "function_call", callID: UUID().uuidString,
                                name: name, arguments: String(decoding: data, as: UTF8.self))
        let result = await BrowserWorkspaceAITools.execute(call, browser: browser, runID: run)
        #expect(!result.isError, "\(name) \(label): \(result.output)")
    }
    try await act("browser_activate", label: "Reservations")
    #expect(tab.webView.url?.path == "/")
    let guest = try await target("Guests")
    #expect(guest.frameID != "main")
    try await act("browser_select", label: "Guests", extra: ["option": "2"])
    try await act("browser_set_value", label: "Reservation date", extra: ["text": "2026-11-15"])
    try await act("browser_activate", label: "Choose time")
    try await act("browser_activate", label: "7:00 PM")
    try await act("browser_activate", label: "Find a table")
    try await act("browser_type", label: "Guest name", extra: ["text": "Test Guest"])
    try await act("browser_activate", label: "Confirm reservation")
    let confirmed = try await browser.wait(tab.id, condition: .textPresent("Fixture confirmation: table for 2 at 7:00 PM"), timeoutMilliseconds: 10000)
    #expect(confirmed.text.contains("Fixture confirmation"))
}

/// Opt-in public-site smoke check. It only opens the reservation page and its
/// date picker: no availability submission, personal data, or booking commit.
@Test @MainActor func liveFogoNavigationCanOpenReservationControls() async throws {
    guard ProcessInfo.processInfo.environment["LIMA_BROWSER_LIVE_NAVIGATION"] == "1" else { return }
    let browser = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    browser.aiControlMode = .fullControl
    let tab = browser.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 1200, height: 850)
    let state = BrowserTaskApprovalState.shared
    let chat = UUID(), run = UUID()
    state.selectConversation(chat); state.select(.independent)
    state.begin(runID: run, instruction: "Inspect public reservation controls", initialURL: nil, conversationID: chat)
    defer {
        state.end(runID: run); state.forgetConversation(chat); state.select(.askForActions)
        Task { try? await browser.close(tab.id) }
    }
    try browser.navigate(tab.id, to: URL(string: "https://fogodechao.com/")!)
    func page(matching predicate: (BrowserPageSnapshot) -> Bool) async throws -> BrowserPageSnapshot {
        for _ in 0..<240 {
            if let page = try? await browser.read(tab.id), predicate(page) { return page }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw BrowserRuntimeError.missingSnapshot
    }
    let home = try await page { !tab.isLoading && $0.diagnostics.canReleaseContent && $0.links.contains { $0.destination?.contains("/reservations/") == true } }
    print("FOGO home diagnostics: \(home.diagnostics)")
    #expect(home.diagnostics.canReleaseContent)
    let link = try #require(home.links.first { $0.destination?.contains("/reservations/") == true })
    let args = try JSONSerialization.data(withJSONObject: ["tab_id": tab.id.uuidString, "target": link.id])
    let call = AIOutputItem(phase: .completed, apiType: "function_call", callID: UUID().uuidString,
                            name: "browser_activate", arguments: String(decoding: args, as: UTF8.self))
    let opened = await BrowserWorkspaceAITools.execute(call, browser: browser, runID: run)
    print("FOGO activation: \(opened.isError ? opened.output : "performed")")
    try #require(!opened.isError)
    let booking = try await page { !tab.isLoading && $0.diagnostics.canReleaseContent && $0.identity.url.contains("/reservations/") && !$0.controls.isEmpty }
    print("FOGO reservation diagnostics: \(booking.diagnostics)")
    print("FOGO controls: \(booking.controls.map { "\($0.label):\($0.availableActions ?? [])" })")
    #expect(booking.diagnostics.canReleaseContent)
    #expect(booking.controls.contains { $0.availableActions?.isEmpty == false })
    let date = try #require(booking.controls.first { $0.label == "Date" })
    let dateArgs = try JSONSerialization.data(withJSONObject: ["tab_id": tab.id.uuidString, "target": date.id])
    let dateCall = AIOutputItem(phase: .completed, apiType: "function_call", callID: UUID().uuidString,
        name: "browser_activate", arguments: String(decoding: dateArgs, as: UTF8.self))
    let calendar = await BrowserWorkspaceAITools.execute(dateCall, browser: browser, runID: run)
    print("FOGO date picker: \(calendar.isError ? calendar.output : "performed")")
    try #require(!calendar.isError)
    let calendarPage = try await browser.read(tab.id)
    let day = try #require(calendarPage.links.first { Int($0.label) != nil && $0.availableActions?.contains("activate") == true })
    let dayArgs = try JSONSerialization.data(withJSONObject: ["tab_id": tab.id.uuidString, "target": day.id])
    let dayCall = AIOutputItem(phase: .completed, apiType: "function_call", callID: UUID().uuidString,
        name: "browser_activate", arguments: String(decoding: dayArgs, as: UTF8.self))
    let selected = await BrowserWorkspaceAITools.execute(dayCall, browser: browser, runID: run)
    print("FOGO calendar day: \(selected.isError ? selected.output : "performed")")
    #expect(!selected.isError)
    #expect(try await tab.webView.evaluateJavaScript("Boolean(document.getElementById('datepicker-date')?.value)") as? Bool == true)
    let capture = try await browser.screenshot(tab.id)
    #expect(capture.byteCount > 0)
    #expect(browser.isScreenshotCurrent(capture))
    print("FOGO protected visual capture: \(capture.pixelWidth)x\(capture.pixelHeight)")
}

@Test @MainActor func semanticActionsTolerateUnrelatedUpdatesButRejectChangedControlAndTerms() async throws {
    let browser = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    browser.aiControlMode = .fullControl
    let tab = browser.newTab()
    defer { Task { try? await browser.close(tab.id) } }
    tab.webView.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
    tab.webView.loadHTMLString("""
        <!doctype html><button type="button" onclick="document.getElementById('result').textContent='Opened'">Choose time</button>
        <div role="alertdialog" style="position:fixed;visibility:hidden;width:300px;height:300px">Hidden dialog</div>
        <p id="ticker"></p><p id="result"></p><p id="terms"></p>
        <script>setInterval(() => {document.getElementById('ticker').textContent=Date.now()}, 15)</script>
        """, baseURL: URL(string: "https://example.com")!)
    var page: BrowserPageSnapshot?
    for _ in 0..<200 {
        if let current = try? await browser.read(tab.id), !current.controls.isEmpty { page = current; break }
        try await Task.sleep(for: .milliseconds(50))
    }
    let first = try #require(page?.controls.first { $0.label == "Choose time" })
    try await Task.sleep(for: .milliseconds(100))
    let result = try await browser.activate(tab.id, targetID: first.id, disposition: .currentTab)
    if case .interacted(let outcome) = result { #expect(outcome.performed) }
    else { Issue.record("Expected semantic widget activation") }
    #expect(try await tab.webView.evaluateJavaScript("document.getElementById('result').textContent") as? String == "Opened")
    let fresh = try await browser.read(tab.id)
    let changed = try #require(fresh.controls.first)
    _ = try await tab.webView.evaluateJavaScript("document.querySelector('button').textContent='Different action'")
    await #expect(throws: BrowserRuntimeError.staleTarget) {
        _ = try await browser.activate(tab.id, targetID: changed.id, disposition: .currentTab)
    }
    let next = try await browser.read(tab.id)
    let withTerms = try #require(next.controls.first)
    _ = try await tab.webView.evaluateJavaScript("document.getElementById('terms').textContent='A $50 deposit is required'")
    await #expect(throws: BrowserRuntimeError.staleTarget) {
        _ = try await browser.activate(tab.id, targetID: withTerms.id, disposition: .currentTab)
    }
}

@Test func independentSemanticBookingStillReviewsFinancialCommitments() {
    let identity = BrowserPageIdentity(documentID: "booking", routeGeneration: 0, mutationRevision: 0,
        userRevision: 0, snapshotRevision: 1, url: "https://restaurant.example/reservations")
    let diagnostics = BrowserDiagnostics(textLength: 30, linkCount: 0, controlCount: 1, headingCount: 0,
        semanticRowCount: 0, shadowRootCount: 0, frameCount: 1, quietMS: 500, truncated: false)
    var button = BrowserTarget(id: "confirm", role: "button", label: "Confirm reservation", destination: nil,
        relationship: nil, x: 0, y: 0, width: 100, height: 40, frameID: "main", sensitive: false)
    button.isSubmit = true
    button.formLabel = "Dinner reservation"
    func page(_ text: String) -> BrowserPageSnapshot {
        BrowserPageSnapshot(identity: identity, readiness: .readyWithContent, title: "Dinner reservation",
            text: text, links: [], controls: [button], headings: [], rows: [], diagnostics: diagnostics)
    }
    #expect(BrowserCommitAuthorization.review(tabID: UUID(), target: button, action: .submit,
        page: page("Table for 2 at 7 PM"), autoApproveNonpayment: true, independent: true) == nil)
    #expect(BrowserCommitAuthorization.review(tabID: UUID(), target: button, action: .submit,
        page: page("Table for 2 at 7 PM"), autoApproveNonpayment: true) != nil)
    #expect(BrowserCommitAuthorization.review(tabID: UUID(), target: button, action: .submit,
        page: page("A $50 deposit is required"), autoApproveNonpayment: true, independent: true)?.requiresPaymentConfirmation == true)
}

@Test @MainActor func semanticReadAccountsForMoreThanTwelveEmbeddedFrames() async throws {
    let browser = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    browser.aiControlMode = .fullControl
    let tab = browser.newTab()
    defer { Task { try? await browser.close(tab.id) } }
    let frames = (0..<13).map { "<iframe srcdoc=\"<p>Embedded panel \($0)</p>\"></iframe>" }.joined()
    tab.webView.loadHTMLString("<!doctype html><h1>Many embedded panels</h1>" + frames,
        baseURL: URL(string: "https://example.com")!)
    for _ in 0..<200 {
        let page = try await browser.read(tab.id)
        if page.diagnostics.frameCount == 14 && page.diagnostics.canReleaseContent {
            #expect(page.frameContexts?.count == 14)
            #expect(page.text.contains("Embedded panel 12"))
            return
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("All thirteen embedded panels must be accounted for before releasing the page")
}
