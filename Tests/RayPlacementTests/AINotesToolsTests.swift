import Foundation
import Testing
@testable import RayPlacement
import RayPlacementCore

@Test @MainActor func notesToolsSearchAndReadAreBounded() async throws {
    let target = MarkdownNote(title: "Browser investigation", content: "The bridge navigation path needs an exact-site grant.", modifiedAt: .distantFuture)
    let extras = (0..<11).map { MarkdownNote(title: "Browser note \($0)", content: "Browser note fixture \($0)") }
    let store = NotesStore(visualFixtures: [target] + extras)

    let searchCall = AIOutputItem(
        phase: .completed, apiType: "function_call", callID: "search",
        name: "search_notes", arguments: #"{"query":"browser"}"#
    )
    let search = await AINotesTools.execute(searchCall, store: store)
    #expect(!search.isError)
    let searchData = try #require(search.output.data(using: .utf8))
    let searchObject = try #require(JSONSerialization.jsonObject(with: searchData) as? [String: Any])
    let matches = try #require(searchObject["matches"] as? [[String: Any]])
    #expect(matches.count == 10)
    #expect(searchObject["total_matches"] as? Int == 12)
    #expect(searchObject["truncated"] as? Bool == true)
    #expect(matches.allSatisfy { ($0["excerpt"] as? String ?? "").count <= 320 })
    #expect(matches.contains { ($0["note_id"] as? String) == target.id.uuidString })

    let readCall = AIOutputItem(
        phase: .completed, apiType: "function_call", callID: "read",
        name: "read_note",
        arguments: "{\"note_id\":\"\(target.id.uuidString)\",\"offset\":4,\"length\":6}"
    )
    let read = await AINotesTools.execute(readCall, store: store)
    #expect(!read.isError)
    let readData = try #require(read.output.data(using: .utf8))
    let readObject = try #require(JSONSerialization.jsonObject(with: readData) as? [String: Any])
    #expect(readObject["content"] as? String == "bridge")
    #expect(readObject["offset"] as? Int == 4)
    #expect(readObject["next_offset"] as? Int == 10)

    let missing = await AINotesTools.execute(
        AIOutputItem(phase: .completed, apiType: "function_call", callID: "missing",
                     name: "read_note",
                     arguments: #"{"note_id":"00000000-0000-0000-0000-000000000000","offset":0,"length":100}"#),
        store: store
    )
    #expect(missing.isError)
}

@Test @MainActor func enabledNotesToolsRemainVisibleForEveryPrompt() {
    let model = AIChatViewModel(
        store: AIConversationStore(fixtures: []),
        credentials: AIChatCredentialStore(configuration: .fixture),
        nativeToolStore: LimaAIToolStore(fixtures: AINotesTools.readIDs),
        transport: FixtureAITransport.standard
    )
    #expect(Set(model.routedNativeTools(for: "Explain this query").map(\.id)) == AINotesTools.readIDs.union(BrowserWorkspaceAITools.ids))
    #expect(Set(model.routedNativeTools(for: "Search my notes for browser integration").map(\.id)) == AINotesTools.readIDs.union(BrowserWorkspaceAITools.ids))
}

@Test @MainActor func notesReadToolsMigrateWithoutAddingBrowserSelections() throws {
    let suite = "RayPlacementTests.browser-notes-read-migration.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["search_files"], forKey: "lima.ai.enabled-native-tools")
    defaults.set(true, forKey: "lima.ai.context-tools-v1")
    defaults.set(true, forKey: "lima.ai.computer-actions-v1")

    let store = LimaAIToolStore(defaults: defaults)
    #expect(store.enabledToolIDs.isSuperset(of: AINotesTools.readIDs))
    #expect(store.enabledToolIDs.isDisjoint(with: AINotesTools.writeIDs))
    #expect(store.enabledToolIDs.isDisjoint(with: BrowserWorkspaceAITools.ids))
    #expect(store.effectiveEnabledToolIDs.contains("browser_read"))
    #expect(!store.enabledToolIDs.contains("browser_open_tabs"))

    let browserRead = try #require(LimaAIToolRegistry.definition(for: "browser_read"))
    store.setEnabled(browserRead, enabled: false)
    let reloaded = LimaAIToolStore(defaults: defaults)
    #expect(reloaded.enabledToolIDs.isDisjoint(with: BrowserWorkspaceAITools.ids))
    #expect(reloaded.effectiveEnabledToolIDs.contains("browser_read"))
    #expect(reloaded.enabledToolIDs.contains("search_notes"))
    #expect(defaults.bool(forKey: "lima.ai.browser-notes-read-v1"))
}

@Test @MainActor func reviewedAINoteCreationKeepsRichMarkdownEditable() async throws {
    let store = NotesStore(visualFixtures: [])
    let markdown = """
    # Release report

    | Area | State |
    | --- | --- |
    | Mail | In progress |

    ```chart
    title: Test coverage
    type: bar
    Passed,3
    Failed,0
    ```
    """
    let arguments = String(decoding: try JSONSerialization.data(withJSONObject: [
        "title": "Release report",
        "content": markdown
    ]), as: UTF8.self)
    let call = AIOutputItem(phase: .completed, apiType: "function_call",
                            callID: "create", name: "create_note", arguments: arguments)

    #expect(LimaAIToolRegistry.requiresApproval(for: "create_note", toolAccessMode: .fullControl))
    let denied = await AINotesTools.execute(call, store: store)
    #expect(denied.isError)
    #expect(store.notes.isEmpty)

    let created = await AINotesTools.execute(call, store: store, approvalGranted: true)
    #expect(!created.isError)
    #expect(store.notes.count == 1)
    let note = try #require(store.notes.first)
    #expect(store.selectedNoteID == note.id)
    #expect(note.title == "Release report")
    #expect(note.content.contains("| Mail | In progress |"))
    #expect(note.content.contains("```chart"))

    let unsafeArguments = String(decoding: try JSONSerialization.data(withJSONObject: [
        "title": "Unsafe image",
        "content": "![Remote](https://example.com/image.png)"
    ]), as: UTF8.self)
    let unsafeCall = AIOutputItem(phase: .completed, apiType: "function_call",
                                  callID: "unsafe", name: "create_note", arguments: unsafeArguments)
    let unsafe = await AINotesTools.execute(unsafeCall, store: store, approvalGranted: true)
    #expect(unsafe.isError)
    for syntax in [
        "![remote][figure]\n\n[figure]: https://example.com/image.png",
        "<img src=\"https://example.com/image.png\">"
    ] {
        let data = try JSONSerialization.data(withJSONObject: [
            "title": "Unsupported image", "content": syntax
        ])
        let call = AIOutputItem(phase: .completed, apiType: "function_call",
                                callID: UUID().uuidString, name: "create_note",
                                arguments: String(decoding: data, as: UTF8.self))
        let result = await AINotesTools.execute(call, store: store, approvalGranted: true)
        #expect(result.isError)
    }
    #expect(store.notes.count == 1)
}

@Test @MainActor func reviewedAINoteAppendRejectsStaleContentAndUnsafeImages() async throws {
    let source = MarkdownNote(title: "Status", content: "Original text")
    let store = NotesStore(visualFixtures: [source])
    let readCall = AIOutputItem(
        phase: .completed, apiType: "function_call", callID: "read-append",
        name: "read_note",
        arguments: "{\"note_id\":\"\(source.id.uuidString)\",\"offset\":0,\"length\":100}"
    )
    let read = await AINotesTools.execute(readCall, store: store)
    let readData = try #require(read.output.data(using: .utf8))
    let readObject = try #require(JSONSerialization.jsonObject(with: readData) as? [String: Any])
    let hash = try #require(readObject["content_sha256"] as? String)
    #expect(hash.count == 64)

    func call(_ content: String, hash: String) throws -> AIOutputItem {
        let data = try JSONSerialization.data(withJSONObject: [
            "note_id": source.id.uuidString,
            "expected_content_sha256": hash,
            "content": content
        ])
        return AIOutputItem(phase: .completed, apiType: "function_call",
                            callID: UUID().uuidString, name: "append_to_note",
                            arguments: String(decoding: data, as: UTF8.self))
    }

    let append = try call("## Progress\n\n- [ ] Review QA", hash: hash)
    #expect(LimaAIToolRegistry.requiresApproval(for: "append_to_note", toolAccessMode: .fullControl))
    let denied = await AINotesTools.execute(append, store: store)
    #expect(denied.isError)
    #expect(store.selectedNote?.content == "Original text")

    let accepted = await AINotesTools.execute(append, store: store, approvalGranted: true)
    #expect(!accepted.isError)
    #expect(store.selectedNote?.content == "Original text\n\n## Progress\n\n- [ ] Review QA")

    let stale = await AINotesTools.execute(append, store: store, approvalGranted: true)
    #expect(stale.isError)
    #expect(store.selectedNote?.content.contains("Review QA") == true)

    let freshRead = await AINotesTools.execute(readCall, store: store)
    let freshData = try #require(freshRead.output.data(using: .utf8))
    let freshObject = try #require(JSONSerialization.jsonObject(with: freshData) as? [String: Any])
    let freshHash = try #require(freshObject["content_sha256"] as? String)
    let unsafe = await AINotesTools.execute(
        try call("![remote](https://example.com/image.png)", hash: freshHash),
        store: store, approvalGranted: true
    )
    #expect(unsafe.isError)
    #expect(store.selectedNote?.content.contains("example.com") == false)

    store.updateContent("User-edited version")
    let oldProposal = await AINotesTools.execute(
        try call("Outdated AI addition", hash: freshHash),
        store: store, approvalGranted: true
    )
    #expect(oldProposal.isError)
    #expect(store.selectedNote?.content == "User-edited version")
}

@Test @MainActor func centralAINotesDispatcherReachesReviewedWriteGate() async {
    let call = AIOutputItem(
        phase: .completed, apiType: "function_call", callID: "reviewed-note",
        name: "create_note", arguments: #"{"title":"Routing check","content":"Body"}"#
    )
    let result = await LimaAIToolRegistry.execute(call)
    #expect(result.isError)
    #expect(result.output.contains("requires review of the exact title"))
}
