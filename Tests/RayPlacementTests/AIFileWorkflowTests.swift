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

@Test func completedMarkdownViewsCompareByContent() {
    let first = LimaMarkdownDocumentView(markdown: "# Summary\nUseful content")
    #expect(first == LimaMarkdownDocumentView(markdown: "# Summary\nUseful content"))
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
