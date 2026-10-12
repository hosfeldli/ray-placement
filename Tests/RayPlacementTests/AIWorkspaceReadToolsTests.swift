import Foundation
import Testing
@testable import RayPlacement

private func workspaceReadCall(_ name: String, _ arguments: [String: Any]) throws -> AIOutputItem {
    let data = try JSONSerialization.data(withJSONObject: arguments)
    return AIOutputItem(phase: .completed, apiType: "function_call", callID: UUID().uuidString,
                        name: name, arguments: String(decoding: data, as: UTF8.self))
}

private func workspaceReadObject(_ execution: LimaAIToolExecution) throws -> [String: Any] {
    let data = try #require(execution.output.data(using: .utf8))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test @MainActor func workspaceReadToolsAreValidRoutedReads() throws {
    let definitions = LimaAIToolRegistry.validDefinitions
    let newTools = definitions.filter { AIWorkspaceReadTools.ids.contains($0.id) }
    #expect(Set(newTools.map(\.id)) == AIWorkspaceReadTools.ids)
    #expect(newTools.allSatisfy { $0.risk == .read && $0.actionCategory == nil })
    let group = try #require(LimaAIToolGroup.coreGroups.first { $0.id == "files" })
    #expect(group.toolIDs.isSuperset(of: AIWorkspaceReadTools.ids))
}

@Test @MainActor func workspaceReadToolsSearchAndInspectBoundedSafeFiles() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("AIWorkspaceReadFixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let nested = root.appendingPathComponent("Sources")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    for index in 0..<20 {
        try "needle\nneedle\nneedle\nneedle\n".write(
            to: nested.appendingPathComponent("file\(index).swift"), atomically: true, encoding: .utf8)
    }
    try "needle hidden".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("linked.swift"),
        withDestinationURL: nested.appendingPathComponent("file0.swift")
    )
    try "A visible root file".write(to: root.appendingPathComponent("z-readme.md"),
                                    atomically: true, encoding: .utf8)

    let search = await AIWorkspaceReadTools.execute(try workspaceReadCall(
        "search_workspace_text", ["directory": root.path, "query": "needle"]))
    #expect(!search.isError)
    let searchObject = try workspaceReadObject(search)
    let matches = try #require(searchObject["matches"] as? [[String: Any]])
    #expect(matches.count == 48)
    #expect(searchObject["truncated"] as? Bool == true)
    #expect(matches.allSatisfy {
        ($0["path"] as? String ?? "").contains("Sources/file")
            && (1...3).contains($0["line"] as? Int ?? 0)
            && ($0["excerpt"] as? String ?? "").contains("needle")
    })

    let tree = await AIWorkspaceReadTools.execute(try workspaceReadCall(
        "inspect_directory_tree", ["directory": root.path, "max_depth": 2]))
    #expect(!tree.isError)
    let treeObject = try workspaceReadObject(tree)
    let entries = try #require(treeObject["entries"] as? [[String: Any]])
    #expect(entries.contains { $0["path"] as? String == "Sources" && $0["kind"] as? String == "directory" })
    #expect(entries.contains { $0["path"] as? String == "Sources/file0.swift" })
    #expect(entries.contains { $0["path"] as? String == "z-readme.md" })
    #expect(!entries.contains { ($0["path"] as? String ?? "").contains(".env") })
    #expect(!entries.contains { ($0["path"] as? String ?? "").contains("linked.swift") })

    let shallow = await AIWorkspaceReadTools.execute(try workspaceReadCall(
        "inspect_directory_tree", ["directory": root.path, "max_depth": 1]))
    let shallowEntries = try #require(try workspaceReadObject(shallow)["entries"] as? [[String: Any]])
    #expect(shallowEntries.contains { $0["path"] as? String == "Sources" })
    #expect(shallowEntries.contains { $0["path"] as? String == "z-readme.md" })
    #expect(!shallowEntries.contains { ($0["path"] as? String ?? "").contains("file0.swift") })
}

@Test @MainActor func workspaceReadToolsRejectUnsafeOrInvalidRequests() async throws {
    let relative = await AIWorkspaceReadTools.execute(try workspaceReadCall(
        "search_workspace_text", ["directory": "relative", "query": "needle"]))
    #expect(relative.isError)

    let sensitive = await AIWorkspaceReadTools.execute(try workspaceReadCall(
        "inspect_directory_tree", ["directory": "/private/var", "max_depth": 2]))
    #expect(sensitive.isError)

    let hidden = await AIWorkspaceReadTools.execute(try workspaceReadCall(
        "inspect_directory_tree", ["directory": "/Users/example/.config", "max_depth": 2]))
    #expect(hidden.isError)

    let invalidDepth = await AIWorkspaceReadTools.execute(try workspaceReadCall(
        "inspect_directory_tree", ["directory": URL(fileURLWithPath: #filePath).deletingLastPathComponent().path,
                                   "max_depth": 9]))
    #expect(invalidDepth.isError)

    let blankQuery = await AIWorkspaceReadTools.execute(try workspaceReadCall(
        "search_workspace_text", ["directory": URL(fileURLWithPath: #filePath).deletingLastPathComponent().path,
                                  "query": ""]))
    #expect(blankQuery.isError)
}

@Test @MainActor func existingCustomToolListsGainWorkspaceReadsOnlyOnce() throws {
    let suite = "AIWorkspaceReadToolsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["read_file"], forKey: "lima.ai.enabled-native-tools")
    defaults.set("custom", forKey: "lima.ai.tool-access-mode")

    let store = LimaAIToolStore(defaults: defaults)
    #expect(store.enabledToolIDs.isSuperset(of: AIWorkspaceReadTools.ids))
    let search = try #require(AIWorkspaceReadTools.definitions.first { $0.id == "search_workspace_text" })
    store.setEnabled(search, enabled: false)
    let reloaded = LimaAIToolStore(defaults: defaults)
    #expect(!reloaded.enabledToolIDs.contains(search.id))
    #expect(reloaded.enabledToolIDs.contains("inspect_directory_tree"))
}
