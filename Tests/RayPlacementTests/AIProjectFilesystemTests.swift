import Foundation
import RayPlacementCore
import Testing
@testable import RayPlacement

@Test @MainActor func projectFilesystemRoundTripAndPathIsolation() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("LimaProjectFiles-\(UUID().uuidString)", isDirectory: true)
    defer { try? files.removeItem(at: root) }
    let paths = AIWorkspacePaths(root: root)
    let store = AIWorkspaceStore(fixtures: [])
    let manager = AIProjectManager(store: store, paths: paths)
    let project = try manager.create(name: "Code")
    let filesystem = AIProjectFilesystem(paths: paths)

    func args(_ path: String, _ extras: [String: JSONValue] = [:]) -> [String: JSONValue] {
        ["path": .string(path)].merging(extras) { _, new in new }
    }
    _ = try await filesystem.execute("directory_create", projectID: project.id, arguments: args("src"))
    _ = try await filesystem.execute("file_write", projectID: project.id,
                                     arguments: args("src/main.swift", ["content": .string("print(\"A\")\n")]))
    _ = try await filesystem.execute("file_patch", projectID: project.id,
                                     arguments: args("src/main.swift", ["old_text": .string("\"A\""),
                                                                        "new_text": .string("\"B\"")]))
    let read = try await filesystem.execute("file_read", projectID: project.id, arguments: args("src/main.swift"))
    #expect(read == .object(["path": .string("src/main.swift"), "content": .string("print(\"B\")\n")]))
    let search = try await filesystem.execute("file_search", projectID: project.id,
                                              arguments: args(".", ["query": .string("print")]))
    if case .object(let fields) = search, case .array(let matches)? = fields["matches"] {
        #expect(matches.count == 1)
    } else {
        Issue.record("Project text search did not return a match array.")
    }
    _ = try await filesystem.execute("file_copy", projectID: project.id,
                                     arguments: args("src/main.swift", ["destination": .string("src/copy.swift")]))
    _ = try await filesystem.execute("file_move", projectID: project.id,
                                     arguments: args("src/copy.swift", ["destination": .string("src/moved.swift")]))
    #expect(files.fileExists(atPath: paths.project(project.id).appendingPathComponent("src/moved.swift").path))
    _ = try await filesystem.execute("file_delete", projectID: project.id, arguments: args("src/moved.swift"))
    #expect(!files.fileExists(atPath: paths.project(project.id).appendingPathComponent("src/moved.swift").path))

    let external = root.appendingPathComponent("outside.txt")
    try Data("private".utf8).write(to: external)
    let link = paths.project(project.id).appendingPathComponent("link.txt")
    try files.createSymbolicLink(at: link, withDestinationURL: external)
    do {
        _ = try await filesystem.execute("file_read", projectID: project.id, arguments: args("link.txt"))
        Issue.record("Project file tool followed a symbolic link.")
    } catch {}
    do {
        _ = try await filesystem.execute("file_read", projectID: project.id, arguments: args("../outside.txt"))
        Issue.record("Project file tool accepted path traversal.")
    } catch {}
    #expect(try String(contentsOf: external, encoding: .utf8) == "private")
}

@Test @MainActor func projectFileToolSchemasAreRoutable() {
    for id in AIProjectFileTools.ids {
        #expect(LimaAIToolRegistry.definition(for: id) != nil)
        #expect(LimaAIToolRegistry.schemaValidationMessage(for: id) == nil)
    }
}
