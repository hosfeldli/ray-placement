import AppKit
import Foundation
import Testing
@testable import RayPlacement

@Test func aiAvailabilityPolicyRejectsRequestsAndCanReenable() throws {
    let policy = AIRequestPolicy(enabled: false)
    #expect(!policy.isEnabled)
    #expect(throws: AIRequestPolicy.Disabled.self) { try policy.check() }
    #expect(throws: AIRequestPolicy.Disabled.self) { _ = try policy.checkedSession() }
    policy.setEnabled(true)
    try policy.check()
    #expect(policy.isEnabled)
    _ = try policy.checkedSession()
    policy.setEnabled(false)
    #expect(throws: AIRequestPolicy.Disabled.self) { _ = try policy.checkedSession() }
}

@Test func embeddedNoteContentsReachOpenAIAndClaudeWithoutAPath() throws {
    let note = AIAttachment(kind: .file, displayName: "Release Plan.md",
                            text: "Verify checksums and sign the release.", mimeType: "text/markdown")
    let openAI = try AIInputEncoder.attachmentContent([note])
    #expect(openAI.count == 1)
    #expect(openAI[0]["type"] as? String == "input_text")
    #expect((openAI[0]["text"] as? String)?.contains("Verify checksums") == true)

    let claude = try AIProviderHTTP.attachmentContent([note])
    #expect(claude.count == 1)
    if case .text(let value) = claude[0] {
        #expect(value.contains("Verify checksums"))
    } else {
        Issue.record("Claude must receive the in-memory note as text.")
    }
}

@Test func aiFileContextRejectsSensitiveHiddenPaths() {
    let hidden = AIAttachment(kind: .file, displayName: ".env",
                              path: "/Users/example/project/.env", mimeType: "text/plain")
    #expect(throws: Error.self) { _ = try AIFileAttachmentPolicy.text(for: hidden) }
}

@Test func largePastePolicyKeepsShortTextInlineAndDetachesLogs() {
    #expect(!AILargePastePolicy.shouldAttach("A short question"))
    #expect(!AILargePastePolicy.shouldAttach(String(repeating: "x", count: 500)))
    #expect(AILargePastePolicy.shouldAttach(String(repeating: "x", count: 8_000)))
    #expect(AILargePastePolicy.shouldAttach(String(repeating: "line\n", count: 50)))
}

@Test @MainActor func pastedTextPersistsAsMetadataAndProvidersReadBoundedContent() throws {
    guard LimaTestEnvironment.isEnabled else { return }
    let pasted = String(repeating: "log entry with unicode café\n", count: 12_000)
    let model = AIChatViewModel(
        store: AIConversationStore(fixtures: []),
        credentials: AIChatCredentialStore(configuration: .fixture),
        nativeToolStore: LimaAIToolStore(fixtures: []),
        transport: FixtureAITransport.standard
    )
    model.draft = "What caused this?"
    #expect(model.attachPastedText(pasted))
    let attachment = try #require(model.attachments.first)
    #expect(model.draft == "What caused this?")
    #expect(attachment.kind == .pastedText)
    #expect(attachment.text == nil)
    #expect(attachment.path == nil)
    #expect(attachment.byteCount == pasted.utf8.count)
    #expect(attachment.lineCount == 12_001)
    #expect(attachment.preview.contains("log entry"))
    #expect(attachment.metadataSummary?.contains("lines") == true)
    let fileURL = try #require(LimaTestEnvironment.storageURL(
        relativePath: "AI/attachments/\(attachment.id.uuidString).txt"
    ))
    let fileMode = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
    let directoryMode = try FileManager.default.attributesOfItem(
        atPath: fileURL.deletingLastPathComponent().path
    )[.posixPermissions] as? NSNumber
    #expect(fileMode?.intValue == 0o600)
    #expect(directoryMode?.intValue == 0o700)

    let metadata = try JSONEncoder().encode(attachment)
    #expect(metadata.count < 1_000)
    #expect(!String(decoding: metadata, as: UTF8.self).contains("log entry with unicode café\nlog entry"))
    let restored = try JSONDecoder().decode(AIAttachment.self, from: metadata)
    #expect(restored == attachment)

    let openAI = try AIInputEncoder.attachmentContent([restored])
    let openAIText = try #require(openAI.first?["text"] as? String)
    #expect(openAIText.contains("log entry with unicode café"))
    #expect(openAIText.contains("Attachment content truncated"))
    #expect(openAIText.utf8.count < 97_000)
    let claude = try AIProviderHTTP.attachmentContent([restored])
    if case .text(let value) = try #require(claude.first) {
        #expect(value.contains("log entry with unicode café"))
        #expect(value.contains("Attachment content truncated"))
        #expect(value.utf8.count < 97_000)
    } else {
        Issue.record("Claude must receive bounded pasted text.")
    }
}

@Test func statelessProviderHistoryKeepsRecentUserTurnWithinBudget() {
    let history = [
        AIProviderMessage(role: .user, text: String(repeating: "a", count: 80_000)),
        AIProviderMessage(role: .assistant, text: String(repeating: "b", count: 80_000)),
        AIProviderMessage(role: .user, text: "What changed?")
    ]
    let bounded = AIProviderHTTP.boundedConversation(history, maximumCharacters: 1_000)
    #expect(bounded.count == 1)
    if case .text(let value) = bounded[0].content[0] { #expect(value == "What changed?") }
    else { Issue.record("The latest user prompt must remain.") }
}

@Test func statelessHistoryRetainsScreenshotToolUseAndResultAsAPair() {
    let history = [
        AIProviderMessage(role: .user, text: String(repeating: "x", count: 80_000)),
        AIProviderMessage(role: .assistant, content: [
            .toolUse(id: "capture", name: "browser_screenshot", arguments: "{}")
        ]),
        AIProviderMessage(role: .user, content: [
            .toolResult(id: "capture", output: "captured"),
            .image(mediaType: "image/jpeg", base64: String(repeating: "a", count: 100_000))
        ])
    ]
    let bounded = AIProviderHTTP.boundedConversation(history, maximumCharacters: 2_000)
    #expect(bounded.count == 2)
    if case .toolUse(let id, _, _) = bounded[0].content[0] { #expect(id == "capture") }
    else { Issue.record("The screenshot tool result lost its call.") }
    if case .toolResult(let id, _) = bounded[1].content[0] { #expect(id == "capture") }
    else { Issue.record("The screenshot result was not retained.") }
}

@Test func completedMarkdownViewsCompareByContent() {
    let markdown = "# Summary\nUseful content\n\n- one\n- two"
    let first = LimaMarkdownDocumentView(markdown: markdown)
    #expect(first == LimaMarkdownDocumentView(markdown: markdown))
    #expect(first != LimaMarkdownDocumentView(markdown: "# Other"))
}

@Test @MainActor func fileActionsAndFileScopeAreAvailableFromRootSearch() {
    #expect(UniversalSearchCoordinator.parse("files: report").prefix == "file")
    #expect(UniversalSearchCoordinator.parse("file: report").query == "report")
    let model = LauncherViewModel(clipboard: .shared, scanApplications: false)
    let url = URL(fileURLWithPath: #filePath)
    let item = LauncherItem(id: "file.test", title: "report.md", subtitle: "Files",
                            icon: .file(url), keywords: [], action: .fileAction(url, .open))
    let ids = Set(model.actionPanelActions(for: item).map(\.id))
    let hasCode = ["com.microsoft.VSCode", "com.visualstudio.code.oss"]
        .contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    #expect(ids.contains("code") == hasCode)
    #expect(ids.contains("describe-ai"))
    #expect(ids.contains("ask-ai"))
}

@Test func largeToolOutputUsesPrivateBlobAndBoundedProviderText() async throws {
    let payload = String(repeating: "terminal line with useful content\n", count: 34_000)
    #expect(payload.utf8.count > 1_000_000)
    let prepared = try await AIToolOutputStore.shared.prepare(payload)
    let reference = try #require(prepared.reference)
    #expect(reference.byteCount == payload.utf8.count)
    #expect(reference.lineCount == 34_001)
    #expect(prepared.providerText.utf8.count < 50_000)
    #expect(prepared.providerText.contains("middle of tool output omitted"))
    let url = try #require(AIToolOutputStore.fileURL(for: reference))
    #expect(try Data(contentsOf: url) == Data(payload.utf8))
    let permissions = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    #expect(permissions == 0o600)

    let activity = AIAgentActivity(kind: .toolCompleted, title: "Terminal",
                                   toolOutputReference: reference, completed: true)
    let restored = try JSONDecoder().decode(AIAgentActivity.self, from: JSONEncoder().encode(activity))
    #expect(restored.toolOutputReference == reference)
    #expect(AIActivityStream.steps(from: [activity], isActive: false).first?.toolOutputReference == reference)

    let short = try await AIToolOutputStore.shared.prepare("small result")
    #expect(short.reference == nil)
    #expect(short.providerText == "small result")
}

@Test func oversizedBrowserResultsCanBeRetrievedOnlyAsBoundedBrowserChunks() async throws {
    let payload = String(repeating: "🔗 Browser result line\n", count: 6_000)
    #expect(payload.utf8.count > AIToolOutputStore.inlineLimit)
    let outputStore = AIToolOutputStore()
    let tabID = UUID()
    let browser = try await outputStore.prepare(payload, scope: .browser(tabID: tabID))
    let browserReference = try #require(browser.reference)
    #expect(browser.providerText.utf8.count < 50_000)

    var offset = 0
    var recovered = ""
    for _ in 0..<100 {
        let chunk = try await outputStore.readBrowserChunk(
            id: browserReference.id, offset: offset, maximumBytes: 4_096
        )
        #expect(chunk.tabID == tabID)
        #expect(chunk.offset == offset)
        #expect(chunk.text.utf8.count <= 4_096)
        recovered += chunk.text
        offset = chunk.nextOffset
        if chunk.eof { break }
    }
    #expect(offset == payload.utf8.count)
    #expect(recovered == payload)
    await #expect(throws: AIToolOutputReadError.self) {
        _ = try await outputStore.readBrowserChunk(id: browserReference.id, offset: 1)
    }

    let general = try await outputStore.prepare(payload)
    let generalReference = try #require(general.reference)
    await #expect(throws: AIToolOutputReadError.self) {
        _ = try await outputStore.readBrowserChunk(id: generalReference.id, offset: 0)
    }

    let otherTab = UUID()
    let other = try await outputStore.prepare(payload, scope: .browser(tabID: otherTab))
    let otherReference = try #require(other.reference)
    let browserURL = try #require(AIToolOutputStore.fileURL(for: browserReference))
    let otherURL = try #require(AIToolOutputStore.fileURL(for: otherReference))
    await outputStore.removeBrowserResults(for: tabID)
    #expect(!FileManager.default.fileExists(atPath: browserURL.path))
    #expect(FileManager.default.fileExists(atPath: otherURL.path))
    await #expect(throws: AIToolOutputReadError.self) {
        _ = try await outputStore.readBrowserChunk(id: browserReference.id, offset: 0)
    }
    #expect(try await outputStore.readBrowserChunk(
        id: otherReference.id, offset: 0
    ).tabID == otherTab)
    await outputStore.clearBrowserResults()
    #expect(!FileManager.default.fileExists(atPath: otherURL.path))
}

@Test @MainActor func browserNavigationAcknowledgementSurvivesPageResultRevocation() async {
    let model = AIChatViewModel(
        store: AIConversationStore(fixtures: []),
        credentials: AIChatCredentialStore(configuration: .fixture),
        transport: FixtureAITransport.standard
    )
    let tabID = UUID()
    let arguments = "{\"tab_id\":\"\(tabID.uuidString)\"}"
    let navigation = AIOutputItem(
        phase: .completed, apiType: "function_call", callID: "navigate",
        name: "browser_navigate", arguments: arguments
    )
    let acknowledgement = await model.prepareToolOutputForTesting(
        "Navigation started", toolName: "browser_navigate",
        call: navigation, explicitBrowserTabID: tabID
    )
    #expect(acknowledgement.providerText == "Navigation started")
    #expect(acknowledgement.reference == nil)

    let pageRead = AIOutputItem(
        phase: .completed, apiType: "function_call", callID: "read",
        name: "browser_read", arguments: arguments
    )
    let revoked = await model.prepareToolOutputForTesting(
        "Page contents", toolName: "browser_read",
        call: pageRead, explicitBrowserTabID: tabID
    )
    #expect(revoked.providerText.contains("changed or closed"))
    #expect(revoked.reference == nil)
}

@Test func blobMetadataPreviewStaysBoundedForOneHugeGrapheme() async throws {
    let payload = "a" + String(repeating: "\u{0301}", count: 60_000)
    #expect(payload.utf8.count > AIToolOutputStore.inlineLimit)
    let attachment = try AIPastedTextStore.save(payload)
    let attachmentPreview = try #require(attachment.previewText)
    #expect(attachmentPreview.utf8.count <= AITextPreview.maximumBytes + 3)
    let prepared = try await AIToolOutputStore.shared.prepare(payload)
    let toolPreview = try #require(prepared.reference?.preview)
    #expect(toolPreview.utf8.count <= AITextPreview.maximumBytes + 3)
    #expect(prepared.providerText.utf8.count < 50_000)
}
