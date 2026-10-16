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
    let definitions = LimaAIToolRegistry.definitions + BrowserWorkspaceAITools.definitions
    let store = LimaAIToolStore(fixtures: [])
    var rows = CommandCenterCatalog.nativeToolEntries(definitions: definitions, enabledIDs: store.enabledToolIDs)
    #expect(rows.count == definitions.count)
    #expect(rows.allSatisfy { !$0.isEnabled })
    #expect(rows.filter { ["browser_new_tab", "browser_focus_tab", "browser_navigate"].contains($0.id) }
        .allSatisfy { $0.availableToAI == false })
    #expect(rows.first { $0.id == "browser_read" }?.availableToAI == true)
    let fileRead = try #require(definitions.first { $0.id == "read_file" })
    store.setEnabled(fileRead, enabled: true)
    rows = CommandCenterCatalog.nativeToolEntries(definitions: definitions, enabledIDs: store.enabledToolIDs)
    #expect(rows.first { $0.id == fileRead.id }?.isEnabled == true)
    #expect(CommandCenterCatalog.visibleEntries(rows, filter: .disabled, query: "").count == rows.count - 1)
    #expect(CommandCenterCatalog.visibleEntries(rows, filter: .tools, query: "file").contains { $0.id == fileRead.id })
    store.setEnabled(fileRead, enabled: false)
    #expect(!store.isEnabled(fileRead))
    #expect(LimaAIToolRegistry.defaultEnabledToolIDs.contains(fileRead.id))
}

@Test func commandCenterNeverDisplaysWriteToolsAsEnabledForAI() {
    let tool = LimaAIToolDefinition(id: "fixture.write", name: "fixture_write",
        description: "Fixture", parameters: [:], risk: .write)
    let row = CommandCenterCatalog.nativeToolEntries(definitions: [tool], enabledIDs: [tool.id]).first
    #expect(row?.isEnabled == false)
    #expect(row?.availableToAI == false)
}
