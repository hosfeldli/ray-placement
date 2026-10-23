import Foundation
import Testing
import WebKit
@testable import RayPlacement


@Test func browserAggregateSuppressesParentEchoAfterChildSecureEntry() throws {
    let secret = "4111111111111111"
    let mainIdentity = BrowserPageIdentity(
        documentID: "main-document", routeGeneration: 1, mutationRevision: 1,
        userRevision: 0, snapshotRevision: 1, url: "https://example.com/checkout"
    )
    let childIdentity = BrowserPageIdentity(
        documentID: "payment-document", routeGeneration: 1, mutationRevision: 1,
        userRevision: 0, snapshotRevision: 1, url: "https://pay.example.com"
    )
    let diagnostics = BrowserDiagnostics(
        textLength: secret.count, linkCount: 0, controlCount: 0,
        headingCount: 1, semanticRowCount: 0, shadowRootCount: 0,
        frameCount: 1, quietMS: 1_000, truncated: false
    )
    var parentField = BrowserTarget(
        id: "parent-password", role: "textbox", label: "Password or secret",
        destination: nil, relationship: nil, x: 0, y: 0,
        width: 200, height: 30, frameID: "main", sensitive: true
    )
    parentField.confidential = true
    parentField.secureKind = "password"
    parentField.formLabel = secret
    let main = BrowserPageSnapshot(
        identity: mainIdentity, readiness: .readyWithContent, title: secret,
        text: "The parent echoed " + secret, links: [], controls: [parentField],
        headings: [secret], rows: [], diagnostics: diagnostics
    )
    var card = BrowserTarget(
        id: "card", role: "textbox", label: "Card number",
        destination: nil, relationship: nil, x: 0, y: 0,
        width: 200, height: 30, frameID: "payment",
        sensitive: true
    )
    card.confidential = true
    card.secureKind = "card_number"
    card.state = BrowserTargetState(
        enabled: true, selected: nil, checked: nil, expanded: nil,
        required: true, sensitive: true, invalid: nil,
        blockedByModal: false, filled: true
    )
    var child = BrowserPageSnapshot(
        identity: childIdentity, readiness: .readyWithContent, title: secret,
        text: "Payment " + secret, links: [], controls: [card],
        headings: [secret], rows: [], diagnostics: diagnostics
    )
    child.frameID = "payment"
    let aggregate = BrowserPageSnapshot.aggregate(
        main, children: [child], expectedFrameCount: 2
    )
    let output = String(decoding: try JSONEncoder().encode(aggregate), as: UTF8.self)
    #expect(!output.contains(secret))
    #expect(aggregate.secureFields.count == 2)
    #expect(aggregate.secureFields.contains { $0.kind == "card_number" && $0.filled })
    #expect(aggregate.controls.allSatisfy { $0.confidential })
    #expect(aggregate.links.isEmpty)
}

@Test func browserAggregateSuppressesChildEchoAfterMainSecureEntry() throws {
    let secret = "main-frame-private-value"
    let mainIdentity = BrowserPageIdentity(
        documentID: "main-document", routeGeneration: 1, mutationRevision: 1,
        userRevision: 0, snapshotRevision: 1, url: "https://example.com/checkout"
    )
    let childIdentity = BrowserPageIdentity(
        documentID: "child-document", routeGeneration: 1, mutationRevision: 1,
        userRevision: 0, snapshotRevision: 1, url: "https://widget.example.com"
    )
    let diagnostics = BrowserDiagnostics(
        textLength: secret.count, linkCount: 0, controlCount: 1,
        headingCount: 1, semanticRowCount: 0, shadowRootCount: 0,
        frameCount: 1, quietMS: 1_000, truncated: false
    )
    var password = BrowserTarget(
        id: "password", role: "textbox", label: "Password or secret",
        destination: nil, relationship: nil, x: 0, y: 0,
        width: 200, height: 30, frameID: "main", sensitive: true
    )
    password.confidential = true
    password.secureKind = "password"
    password.state = BrowserTargetState(
        enabled: true, selected: nil, checked: nil, expanded: nil,
        required: true, sensitive: true, invalid: nil,
        blockedByModal: false, filled: true
    )
    let main = BrowserPageSnapshot(
        identity: mainIdentity, readiness: .readyWithContent, title: "Checkout",
        text: "Ready for review", links: [], controls: [password],
        headings: ["Checkout"], rows: [], diagnostics: diagnostics
    )
    let echoed = BrowserTarget(
        id: "echo", role: "button", label: secret,
        destination: nil, relationship: nil, x: 10, y: 10,
        width: 90, height: 30, frameID: "widget", sensitive: false
    )
    var child = BrowserPageSnapshot(
        identity: childIdentity, readiness: .readyWithContent, title: secret,
        text: "Echo: " + secret, links: [], controls: [echoed],
        headings: [secret], rows: [], diagnostics: diagnostics
    )
    child.frameID = "widget"
    let aggregate = BrowserPageSnapshot.aggregate(
        main, children: [child], expectedFrameCount: 2
    )
    let output = String(decoding: try JSONEncoder().encode(aggregate), as: UTF8.self)
    #expect(!output.contains(secret))
    #expect(aggregate.secureFields.count == 1)
    #expect(aggregate.secureFields[0].filled)
    #expect(aggregate.controls.allSatisfy { $0.confidential })
    #expect(aggregate.links.isEmpty)
}

private func secureBrowserCall(_ name: String, _ arguments: [String: Any]) throws -> AIOutputItem {
    let data = try JSONSerialization.data(withJSONObject: arguments)
    return AIOutputItem(
        phase: .completed, apiType: "function_call", callID: UUID().uuidString,
        name: name, arguments: String(decoding: data, as: UTF8.self)
    )
}


@Test @MainActor func browserIncompleteTraversalWithholdsSemanticToolOutput() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .readOnly
    let tab = model.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    let buttons = (0..<245).map { index in
        "<button style='position:absolute;left:20px;top:60px'>Choice \(index)</button>"
    }.joined()
    tab.webView.loadHTMLString(
        "<!doctype html><html><body><h1>private-page-marker</h1>\(buttons)</body></html>",
        baseURL: URL(string: "https://example.com")!
    )
    var incomplete = false
    for _ in 0..<100 {
        if let page = try? await model.read(tab.id), page.diagnostics.truncated {
            incomplete = true
            break
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(incomplete)
    let read = await BrowserWorkspaceAITools.execute(
        try secureBrowserCall("browser_read", ["tab_id": tab.id.uuidString]),
        browser: model
    )
    #expect(read.isError)
    #expect(!read.output.contains("private-page-marker"))
    try await model.close(tab.id)
}

@Test @MainActor func browserSecureEntryRedactsValuesAndSeparatelyReviewsFinalSubmit() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tab = model.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    tab.webView.loadHTMLString("""
        <!doctype html><html><body>
        <h1>Review purchase</h1>
        <p>Total: $96.12</p>
        <form aria-label="Checkout">
          <label>Card number <input id="card" autocomplete="cc-number" required></label>
          <label>Security code <input id="cvv" autocomplete="cc-csc" required></label>
          <button type="submit">Place order</button>
        </form>
        <p id="mirror"></p><p id="status">Not submitted</p>
        <script>
          document.querySelector('form').addEventListener('submit', event => {
            event.preventDefault();
            document.getElementById('status').textContent = 'Order request sent';
          });
        </script>
        </body></html>
        """, baseURL: URL(string: "https://example.com")!)
    var initial: BrowserPageSnapshot?
    for _ in 0..<100 {
        if let page = try? await model.read(tab.id), page.secureFields.count == 2 {
            initial = page
            break
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    let before = try #require(initial)
    #expect(before.secureFields.allSatisfy { $0.required && !$0.filled })
    let card = try #require(before.controls.first { $0.secureKind == "card_number" })
    #expect(card.label == "Card number")
    #expect(card.availableActions == ["request_secure_input"])
    let blocked = await BrowserWorkspaceAITools.execute(
        try secureBrowserCall("browser_set_value", [
            "tab_id": tab.id.uuidString, "target": card.id,
            "text": "4111111111111111"
        ]), browser: model
    )
    #expect(blocked.isError)

    // Direct WebKit entry represents the user's takeover, not a model tool.
    _ = try await tab.webView.evaluateJavaScript("""
        document.getElementById('card').value = '4111111111111111';
        document.getElementById('cvv').value = '123';
        document.getElementById('mirror').textContent = '4111111111111111';
        document.title = '4111111111111111';
        history.replaceState({}, '', '/privatepathvalue?token=privatepathvalue#privatepathvalue');
        const link = document.createElement('a');
        link.textContent = 'Private link';
        link.href = 'https://example.com/privatepathvalue?token=privatepathvalue';
        document.body.appendChild(link);
        true;
        """)
    model.markPageChangedByUser(tab.id)
    let entered = try await model.wait(tab.id, condition: .pageStable, timeoutMilliseconds: 5_000)
    #expect(entered.secureFields.allSatisfy { $0.filled })
    #expect(!entered.text.contains("4111111111111111"))
    #expect(!entered.text.contains("123"))
    #expect(entered.text.contains("$96.12"))
    #expect(entered.find("4111111111111111").isEmpty)
    let snapshotJSON = String(decoding: try JSONEncoder().encode(entered), as: UTF8.self)
    #expect(!snapshotJSON.contains("4111111111111111"))
    #expect(!snapshotJSON.contains("123"))

    for tool in ["browser_tabs", "browser_current", "browser_read"] {
        let result = await BrowserWorkspaceAITools.execute(
            try secureBrowserCall(tool, tool == "browser_read"
                ? ["tab_id": tab.id.uuidString] : [:]), browser: model
        )
        #expect(!result.isError)
        #expect(!result.output.contains("4111111111111111"))
        #expect(!result.output.contains("privatepathvalue"))
    }
    let found = await BrowserWorkspaceAITools.execute(
        try secureBrowserCall("browser_find", [
            "tab_id": tab.id.uuidString, "query": "Private link"
        ]), browser: model
    )
    #expect(!found.isError)
    #expect(!found.output.contains("privatepathvalue"))

    let read = await BrowserWorkspaceAITools.execute(
        try secureBrowserCall("browser_form_read", ["tab_id": tab.id.uuidString]),
        browser: model
    )
    #expect(!read.isError)
    #expect(!read.output.contains("4111111111111111"))
    #expect(!read.output.contains("\"123\""))

    let fresh = try await model.read(tab.id)
    let submit = try #require(fresh.controls.first { $0.label == "Place order" })
    #expect(!submit.sensitive)
    let call = try secureBrowserCall("browser_submit", [
        "tab_id": tab.id.uuidString, "target": submit.id
    ])
    let review = try #require(await BrowserWorkspaceAITools.commitReview(for: call, browser: model))
    #expect(review.visibleTerms.contains { $0.contains("$96.12") })
    let denied = await BrowserWorkspaceAITools.execute(call, browser: model)
    #expect(denied.isError)
    #expect(try await tab.webView.evaluateJavaScript(
        "document.getElementById('status').textContent"
    ) as? String == "Not submitted")
    let approved = await BrowserWorkspaceAITools.execute(
        call, browser: model, approvalGranted: true
    )
    #expect(!approved.isError)
    #expect(try await tab.webView.evaluateJavaScript(
        "document.getElementById('status').textContent"
    ) as? String == "Order request sent")
    try await model.close(tab.id)
}
