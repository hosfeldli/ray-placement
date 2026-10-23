import Foundation
import Testing
import WebKit
@testable import RayPlacement

private func webAgentCall(_ name: String, _ arguments: [String: Any]) throws -> AIOutputItem {
    let data = try JSONSerialization.data(withJSONObject: arguments)
    return AIOutputItem(
        phase: .completed, apiType: "function_call", callID: UUID().uuidString,
        name: name, arguments: String(decoding: data, as: UTF8.self)
    )
}

private func webAgentPage(_ model: BrowserWorkspaceModel, tabID: UUID,
                          targetLabel: String) async throws -> BrowserPageSnapshot {
    for _ in 0..<100 {
        if let page = try? await model.read(tabID),
           page.controls.contains(where: { $0.label == targetLabel }) {
            return page
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    throw BrowserRuntimeError.missingSnapshot
}

@Test @MainActor func browserFormReadExposesStateWithoutInputValues() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tab = model.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    tab.webView.loadHTMLString("""
        <!doctype html><html><body>
        <form aria-label="Reservation">
          <select aria-label="Party size" required>
            <option>Choose</option><option>2</option><option>4</option>
          </select>
          <input type="date" aria-label="Date" required>
          <input type="text" aria-label="Notes" value="private-form-marker">
          <input type="checkbox" aria-label="Outdoor seating">
          <button type="submit">Find a table</button>
        </form>
        <input type="password" aria-label="Password" value="secret-marker">
        <div role="grid" aria-label="Calendar">
          <button type="button" role="gridcell" aria-label="Friday, October 23">23</button>
        </div>
        </body></html>
        """, baseURL: URL(string: "https://example.com")!)
    let page = try await webAgentPage(model, tabID: tab.id, targetLabel: "Party size")
    let party = try #require(page.controls.first { $0.label == "Party size" })
    #expect(party.role == "combobox")
    #expect(party.kind == "combobox")
    #expect(party.state?.required == true)
    #expect(party.state?.enabled == true)
    #expect(party.availableActions?.contains("select") == true)
    #expect(party.options?.map(\.label) == ["Choose", "2", "4"])
    let date = try #require(page.controls.first { $0.label == "Date" })
    #expect(date.role == "date")
    #expect(date.state?.required == true)
    #expect(date.state?.invalid == true)
    #expect(page.controls.contains {
        $0.role == "gridcell" && $0.label == "Friday, October 23" &&
        $0.availableActions?.contains("activate") == true
    })
    #expect(page.controls.contains { $0.label == "Password or secret" && $0.sensitive && $0.confidential &&
            $0.state?.filled == true })
    #expect(page.find("Party size").contains {
        $0.targetID == party.id && $0.state?.required == true
    })

    let execution = await BrowserWorkspaceAITools.execute(
        try webAgentCall("browser_form_read", ["tab_id": tab.id.uuidString]),
        browser: model
    )
    #expect(!execution.isError)
    #expect(!execution.output.contains("private-form-marker"))
    #expect(!execution.output.contains("secret-marker"))
    let formRead = try JSONDecoder().decode(BrowserFormRead.self, from:
        try #require(execution.output.data(using: .utf8)))
    #expect(formRead.tabID == tab.id)
    let form = try #require(formRead.forms.first { $0.label == "Reservation" })
    #expect(form.fields.contains { $0.label == "Party size" })
    #expect(form.fields.contains { $0.label == "Date" })
    #expect(form.submitTargets.contains { $0.label == "Find a table" })
    #expect(formRead.unassociatedFields.contains { $0.label == "Password or secret" && $0.sensitive && $0.confidential &&
            $0.state?.filled == true })
    try await model.close(tab.id)
}

@Test @MainActor func browserNativeFormActionsVerifyAndStayTabBound() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tab = model.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    tab.webView.loadHTMLString("""
        <!doctype html><html><body>
        <form aria-label="Reservation">
          <input type="date" aria-label="Date">
          <select aria-label="Party size"><option>Choose</option><option>2</option></select>
          <input type="checkbox" aria-label="Outdoor seating">
          <button type="submit">Find a table</button>
        </form>
        <input type="password" aria-label="Password">
        </body></html>
        """, baseURL: URL(string: "https://example.com")!)

    func action(_ name: String, _ target: BrowserTarget,
                extra: [String: Any] = [:]) async throws -> BrowserActionOutcome {
        var arguments: [String: Any] = ["tab_id": tab.id.uuidString, "target": target.id]
        for (key, value) in extra { arguments[key] = value }
        let execution = await BrowserWorkspaceAITools.execute(
            try webAgentCall(name, arguments), browser: model
        )
        #expect(!execution.isError)
        return try JSONDecoder().decode(BrowserActionOutcome.self, from:
            try #require(execution.output.data(using: .utf8)))
    }

    var page = try await webAgentPage(model, tabID: tab.id, targetLabel: "Date")
    var date = try #require(page.controls.first { $0.label == "Date" })
    let set = try await action("browser_set_value", date, extra: ["text": "2026-10-23"])
    #expect(set.postActionVerified)
    #expect(try await tab.webView.evaluateJavaScript(
        "document.querySelector('input[type=date]').value"
    ) as? String == "2026-10-23")

    page = try await model.read(tab.id)
    var party = try #require(page.controls.first { $0.label == "Party size" })
    let unavailable = await BrowserWorkspaceAITools.execute(
        try webAgentCall("browser_select", [
            "tab_id": tab.id.uuidString, "target": party.id, "option": "99"
        ]), browser: model
    )
    #expect(unavailable.isError)
    let unavailableData = try #require(unavailable.output.data(using: .utf8))
    let unavailableJSON = try JSONSerialization.jsonObject(with: unavailableData)
    let unavailableObject = try #require(unavailableJSON as? [String: Any])
    let unavailableError = try #require(unavailableObject["error"] as? [String: Any])
    #expect(unavailableError["code"] as? String == "unsupported_operation")
    page = try await model.read(tab.id)
    party = try #require(page.controls.first { $0.label == "Party size" })
    let selected = try await action("browser_select", party, extra: ["option": "2"])
    #expect(selected.postActionVerified)
    #expect(try await tab.webView.evaluateJavaScript(
        "document.querySelector('select').selectedOptions[0].textContent"
    ) as? String == "2")

    page = try await model.read(tab.id)
    let outdoor = try #require(page.controls.first { $0.label == "Outdoor seating" })
    let toggled = try await action("browser_toggle", outdoor, extra: ["checked": true])
    #expect(toggled.postActionVerified)
    #expect(try await tab.webView.evaluateJavaScript(
        "document.querySelector('input[type=checkbox]').checked"
    ) as? Bool == true)

    page = try await model.read(tab.id)
    date = try #require(page.controls.first { $0.label == "Date" })
    let cleared = try await action("browser_clear", date)
    #expect(cleared.postActionVerified)
    #expect(try await tab.webView.evaluateJavaScript(
        "document.querySelector('input[type=date]').value"
    ) as? String == "")

    page = try await model.read(tab.id)
    let password = try #require(page.controls.first { $0.label == "Password or secret" })
    await #expect(throws: BrowserRuntimeError.self) {
        _ = try await model.interact(tab.id, targetID: password.id,
                                     action: .setValue, text: "must-not-enter")
    }
    let wrongTab = model.newTab()
    await #expect(throws: BrowserRuntimeError.self) {
        _ = try await model.interact(wrongTab.id, targetID: password.id,
                                     action: .setValue, text: "must-not-enter")
    }
    try await model.close(wrongTab.id)
    try await model.close(tab.id)
}

@Test @MainActor func browserModalBlocksUnderlyingTargetsUntilResolved() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tab = model.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    tab.webView.loadHTMLString("""
        <!doctype html><html><body>
        <button type="button" id="under" onclick="document.body.append(' Selected')">Choose time</button>
        <div role="dialog" aria-modal="true" aria-label="Cookie choices"
             style="position:fixed;inset:0;background:white;z-index:10">
          <button type="button" id="dismiss" onclick="this.parentElement.remove()">Continue</button>
        </div>
        </body></html>
        """, baseURL: URL(string: "https://example.com")!)
    var page = try await webAgentPage(model, tabID: tab.id, targetLabel: "Choose time")
    let underlying = try #require(page.controls.first { $0.label == "Choose time" })
    #expect(page.activeDialog?.label == "Cookie choices")
    #expect(page.activeDialog?.modal == true)
    #expect(underlying.state?.blockedByModal == true)
    #expect(underlying.availableActions?.isEmpty == true)
    await #expect(throws: BrowserRuntimeError.targetOccluded) {
        _ = try await model.interact(tab.id, targetID: underlying.id, action: .click)
    }
    let dismiss = try #require(page.controls.first { $0.label == "Continue" })
    #expect(page.activeDialog?.targetIDs.contains(dismiss.id) == true)
    _ = try await model.interact(tab.id, targetID: dismiss.id, action: .click)
    page = try await model.read(tab.id)
    let fresh = try #require(page.controls.first { $0.label == "Choose time" })
    #expect(page.activeDialog == nil)
    #expect(fresh.state?.enabled == true)
    let clicked = try await model.interact(tab.id, targetID: fresh.id, action: .click)
    #expect(clicked.postActionVerified)
    #expect(try await tab.webView.evaluateJavaScript(
        "document.body.textContent.includes('Selected')"
    ) as? Bool == true)
    try await model.close(tab.id)
}

@Test @MainActor func browserGenericReservationFlowRequiresVisibleConfirmation() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tab = model.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    tab.webView.loadHTMLString("""
        <!doctype html><html><body>
        <h1>Local reservation fixture</h1>
        <form aria-label="Reservation">
          <div role="grid" aria-label="Calendar">
            <button type="button" role="gridcell" aria-label="Friday, October 23"
              aria-selected="false"
              onclick="this.setAttribute('aria-selected','true')">23</button>
          </div>
          <button type="button" role="combobox" aria-label="Time"
            aria-expanded="false"
            onclick="this.setAttribute('aria-expanded','true');document.getElementById('times').hidden=false">Time</button>
          <div id="times" role="listbox" hidden>
            <button type="button" role="option" aria-label="7:00 PM"
              aria-selected="false"
              onclick="this.setAttribute('aria-selected','true');document.getElementById('selection').textContent='7:00 PM selected'">7:00 PM</button>
          </div>
          <p id="selection"></p>
          <button type="submit">Reserve</button>
        </form>
        <button type="button" id="noop">No-op</button>
        <p id="confirmation"></p>
        <script>
          document.querySelector('form').addEventListener('submit', event => {
            event.preventDefault();
            const date = document.querySelector('[role=gridcell]').getAttribute('aria-selected');
            const time = document.querySelector('[role=option]').getAttribute('aria-selected');
            if (date === 'true' && time === 'true') {
              document.getElementById('confirmation').textContent =
                'Confirmed reservation for Friday, October 23 at 7:00 PM';
            }
          });
        </script>
        </body></html>
        """, baseURL: URL(string: "https://example.com")!)

    var page = try await webAgentPage(model, tabID: tab.id, targetLabel: "Friday, October 23")
    let noOp = try #require(page.controls.first { $0.label == "No-op" })
    let noOpResult = try await model.interact(tab.id, targetID: noOp.id, action: .click)
    #expect(noOpResult.performed)
    #expect(!noOpResult.postActionVerified)

    page = try await model.read(tab.id)
    let date = try #require(page.controls.first { $0.label == "Friday, October 23" })
    let dateResult = try await model.activate(tab.id, targetID: date.id, disposition: .currentTab)
    guard case .interacted(let dateAction) = dateResult else {
        Issue.record("The calendar cell must use a semantic control action.")
        return
    }
    #expect(dateAction.postActionVerified)

    page = try await model.read(tab.id)
    let time = try #require(page.controls.first { $0.label == "Time" })
    #expect(time.role == "combobox")
    #expect(time.state?.expanded == false)
    #expect(time.availableActions?.contains("activate") == true)
    _ = try await model.activate(tab.id, targetID: time.id, disposition: .currentTab)

    page = try await model.read(tab.id)
    let option = try #require(page.controls.first {
        $0.label == "7:00 PM" && $0.role == "option"
    })
    #expect(option.role == "option")
    #expect(option.state?.selected == false)
    _ = try await model.activate(tab.id, targetID: option.id, disposition: .currentTab)

    page = try await model.read(tab.id)
    #expect(page.controls.contains {
        $0.label == "7:00 PM" && $0.state?.selected == true
    })
    let reserve = try #require(page.controls.first { $0.label == "Reserve" })
    #expect(reserve.availableActions?.contains("submit") == true)
    let submitCall = try webAgentCall("browser_submit", [
        "tab_id": tab.id.uuidString, "target": reserve.id
    ])
    let review = await BrowserWorkspaceAITools.commitReview(for: submitCall, browser: model)
    #expect(review?.label == "Reserve")
    let denied = await BrowserWorkspaceAITools.execute(submitCall, browser: model)
    #expect(denied.isError)
    #expect(try await tab.webView.evaluateJavaScript(
        "document.getElementById('confirmation').textContent"
    ) as? String == "")
    let submit = await BrowserWorkspaceAITools.execute(
        submitCall, browser: model, approvalGranted: true
    )
    #expect(!submit.isError)
    let submitted = try JSONDecoder().decode(BrowserActionOutcome.self, from:
        try #require(submit.output.data(using: .utf8)))
    #expect(submitted.postActionVerified)
    let confirmation = try await model.wait(
        tab.id, condition: .textPresent("Confirmed reservation"),
        timeoutMilliseconds: 5_000
    )
    #expect(confirmation.text.contains(
        "Confirmed reservation for Friday, October 23 at 7:00 PM"
    ))
    try await model.close(tab.id)
}

@Test @MainActor func browserHitTestRejectsNonmodalOverlay() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tab = model.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    tab.webView.loadHTMLString("""
        <!doctype html><html><body>
        <button type="button" style="position:absolute;top:80px;left:80px"
          onclick="document.body.append(' Activated')">Covered action</button>
        <div id="cover" style="position:fixed;inset:0;z-index:10;background:white"></div>
        </body></html>
        """, baseURL: URL(string: "https://example.com")!)
    var page = try await webAgentPage(model, tabID: tab.id, targetLabel: "Covered action")
    let covered = try #require(page.controls.first { $0.label == "Covered action" })
    #expect(covered.state?.enabled == true)
    #expect(page.activeDialog == nil)
    await #expect(throws: BrowserRuntimeError.targetOccluded) {
        _ = try await model.interact(tab.id, targetID: covered.id, action: .click)
    }
    #expect(try await tab.webView.evaluateJavaScript(
        "document.body.textContent.includes('Activated')"
    ) as? Bool == false)
    _ = try await tab.webView.evaluateJavaScript(
        "document.getElementById('cover').remove()"
    )
    page = try await model.read(tab.id)
    let uncovered = try #require(page.controls.first { $0.label == "Covered action" })
    let outcome = try await model.interact(tab.id, targetID: uncovered.id, action: .click)
    #expect(outcome.postActionVerified)
    try await model.close(tab.id)
}

@Test @MainActor func browserHitTestKeepsShadowRootControlsUsable() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tab = model.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    tab.webView.loadHTMLString("""
        <!doctype html><html><body>
        <div id="host"></div>
        <script>
          const root = document.getElementById('host').attachShadow({mode:'open'});
          const button = document.createElement('button');
          button.type = 'button';
          button.textContent = 'Shadow action';
          button.addEventListener('click', () => document.body.append(' Shadow activated'));
          root.append(button);
        </script>
        </body></html>
        """, baseURL: URL(string: "https://example.com")!)
    let page = try await webAgentPage(model, tabID: tab.id, targetLabel: "Shadow action")
    let target = try #require(page.controls.first { $0.label == "Shadow action" })
    let outcome = try await model.interact(tab.id, targetID: target.id, action: .click)
    #expect(outcome.postActionVerified)
    #expect(try await tab.webView.evaluateJavaScript(
        "document.body.textContent.includes('Shadow activated')"
    ) as? Bool == true)
    try await model.close(tab.id)
}

@Test func browserMainFrameModalMasksChildFrameActions() throws {
    let diagnostics = BrowserDiagnostics(
        textLength: 0, linkCount: 0, controlCount: 1, headingCount: 0,
        semanticRowCount: 0, shadowRootCount: 0, frameCount: 1,
        quietMS: 600, truncated: false
    )
    let mainIdentity = BrowserPageIdentity(
        documentID: "main", routeGeneration: 0, mutationRevision: 0,
        userRevision: 0, snapshotRevision: 1, url: "https://example.com"
    )
    var main = BrowserPageSnapshot(
        identity: mainIdentity, readiness: .readyWithContent, title: "Main",
        text: "Dialog", links: [], controls: [], headings: [], rows: [],
        diagnostics: diagnostics
    )
    main.activeDialog = BrowserDialogSummary(
        role: "dialog", label: "Choose", modal: true, targetIDs: [], frameID: "main"
    )
    var target = BrowserTarget(
        id: "child_target", role: "button", label: "Under dialog",
        destination: nil, relationship: nil, x: 0, y: 0, width: 100,
        height: 30, frameID: "child", sensitive: false
    )
    target.availableActions = ["activate"]
    target.state = BrowserTargetState(
        enabled: true, selected: nil, checked: nil, expanded: nil,
        required: false, sensitive: false, invalid: nil, blockedByModal: false
    )
    var child = BrowserPageSnapshot(
        identity: BrowserPageIdentity(
            documentID: "child", routeGeneration: 0, mutationRevision: 0,
            userRevision: 0, snapshotRevision: 1, url: "https://example.com/frame"
        ),
        readiness: .readyWithContent, title: "Child", text: "Under dialog",
        links: [], controls: [target], headings: [], rows: [],
        diagnostics: diagnostics
    )
    child.frameID = "child"
    let page = BrowserPageSnapshot.aggregate(
        main, children: [child], expectedFrameCount: 2
    )
    let blocked = try #require(page.controls.first)
    #expect(blocked.availableActions == [])
    #expect(blocked.state?.enabled == false)
    #expect(blocked.state?.blockedByModal == true)
    #expect(page.activeDialog?.label == "Choose")
}
