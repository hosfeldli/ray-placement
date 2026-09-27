import Foundation
import Testing
@testable import RayPlacement

@Test func commandCenterMapsCommandIDsToShortcutAssignments() {
    #expect(CommandCenterCatalog.shortcutAssignmentID(for: "builtin.note-dictation") == "builtin.dictation")
    #expect(CommandCenterCatalog.shortcutAssignmentID(for: "builtin.add-selection-to-shelf") == "builtin.context-shelf.capture-selection")
    for id in ["builtin.notes", "builtin.quick-note", "builtin.terminal", "extension.example.command"] {
        #expect(CommandCenterCatalog.shortcutAssignmentID(for: id) == id)
    }
}

@Test @MainActor func commandCenterToolEnablementUsesTheSharedReadOnlyStore() throws {
    let definitions = LimaAIToolRegistry.definitions + BrowserBridgeAITools.definitions
    let store = LimaAIToolStore(fixtures: [])
    var rows = CommandCenterCatalog.nativeToolEntries(definitions: definitions, enabledIDs: store.enabledToolIDs)
    #expect(rows.count == definitions.count)
    #expect(rows.allSatisfy { !$0.isEnabled && $0.availableToAI == true })
    let bridge = try #require(definitions.first { $0.id == "browser_read" })
    store.setEnabled(bridge, enabled: true)
    rows = CommandCenterCatalog.nativeToolEntries(definitions: definitions, enabledIDs: store.enabledToolIDs)
    #expect(rows.first { $0.id == bridge.id }?.isEnabled == true)
    #expect(CommandCenterCatalog.visibleEntries(rows, filter: .disabled, query: "").count == rows.count - 1)
    #expect(CommandCenterCatalog.visibleEntries(rows, filter: .tools, query: "browser").contains { $0.id == bridge.id })
    store.setEnabled(bridge, enabled: false)
    #expect(!store.isEnabled(bridge))
    #expect(!LimaAIToolRegistry.defaultEnabledToolIDs.contains(bridge.id))
}

@Test func commandCenterNeverDisplaysWriteToolsAsEnabledForAI() {
    let tool = LimaAIToolDefinition(id: "fixture.write", name: "fixture_write",
        description: "Fixture", parameters: [:], risk: .write)
    let row = CommandCenterCatalog.nativeToolEntries(definitions: [tool], enabledIDs: [tool.id]).first
    #expect(row?.isEnabled == false)
    #expect(row?.availableToAI == false)
}
