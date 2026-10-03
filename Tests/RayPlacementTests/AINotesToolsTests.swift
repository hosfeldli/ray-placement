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

@Test @MainActor func notesToolsOnlyRouteForExplicitNotesRequests() {
    let model = AIChatViewModel(
        store: AIConversationStore(fixtures: []),
        credentials: AIChatCredentialStore(configuration: .fixture),
        mcpStore: MCPServerStore(fixtures: []),
        nativeToolStore: LimaAIToolStore(fixtures: AINotesTools.ids),
        transport: FixtureAITransport.standard
    )
    #expect(model.routedNativeTools(for: "Explain this query").isEmpty)
    #expect(Set(model.routedNativeTools(for: "Search my notes for browser integration").map(\.id)) == AINotesTools.ids)
}

@Test @MainActor func browserAndNotesReadToolsMigrateOnceWithoutGrantingNavigation() throws {
    let suite = "RayPlacementTests.browser-notes-read-migration.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["search_files"], forKey: "lima.ai.enabled-native-tools")
    defaults.set(true, forKey: "lima.ai.context-tools-v1")
    defaults.set(true, forKey: "lima.ai.computer-actions-v1")

    let store = LimaAIToolStore(defaults: defaults)
    #expect(store.enabledToolIDs.isSuperset(of: AINotesTools.ids))
    #expect(store.enabledToolIDs.isSuperset(of: BrowserBridgeAITools.readToolIDs))
    #expect(!store.enabledToolIDs.contains("browser_open_tabs"))
    #expect(!store.enabledToolIDs.contains("browser_click"))

    let browserRead = try #require(BrowserBridgeAITools.definitions.first { $0.id == "browser_read" })
    store.setEnabled(browserRead, enabled: false)
    let reloaded = LimaAIToolStore(defaults: defaults)
    #expect(!reloaded.enabledToolIDs.contains("browser_read"))
    #expect(reloaded.enabledToolIDs.contains("search_notes"))
    #expect(defaults.bool(forKey: "lima.ai.browser-notes-read-v1"))
}
