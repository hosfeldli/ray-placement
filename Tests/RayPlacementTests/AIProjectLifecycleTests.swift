import Foundation
import Testing
@testable import RayPlacement

@Test func legacyProjectDecodesAsContextOnlyWithoutAWorkingTree() throws {
    let id = UUID()
    let date = Date()
    let old = ["id": id.uuidString, "name": "Legacy context",
               "instructions": "Use local context.",
               "createdAt": date.timeIntervalSinceReferenceDate,
               "updatedAt": date.timeIntervalSinceReferenceDate] as [String: Any]
    let data = try JSONSerialization.data(withJSONObject: old)
    let project = try JSONDecoder().decode(AIProject.self, from: data)
    #expect(project.workState == .contextOnly)
    #expect(project.lifecycle == .active)
    #expect(project.directoryName == nil)
    #expect(project.id == id)
}

@Test @MainActor func managedProjectLifecyclePreservesFilesAndScopedMemory() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("LimaProjectLifecycle-\(UUID().uuidString)", isDirectory: true)
    defer { try? manager.removeItem(at: root) }
    let paths = AIWorkspacePaths(root: root)
    let store = AIWorkspaceStore(fixtures: [])
    let projects = AIProjectManager(store: store, paths: paths)

    #expect(!manager.fileExists(atPath: paths.projects.path))
    let contextOnly = try #require(store.createProject(name: "Reference context"))
    #expect(contextOnly.workState == .contextOnly)
    #expect(!manager.fileExists(atPath: paths.projects.path))

    let materialized = try projects.materialize(contextOnly.id)
    #expect(materialized.workState == .materialized)
    #expect(materialized.directoryName == contextOnly.id.uuidString)
    #expect(manager.fileExists(atPath: paths.project(contextOnly.id).path))

    let project = try projects.create(name: "Dashboard")
    let file = try #require(projects.directory(for: project))
        .appendingPathComponent("README.md")
    try Data("# Dashboard".utf8).write(to: file)
    let memory = try #require(store.createMemory(title: "Design", content: "Keep a sidecar", projectID: project.id))

    let archived = try await projects.archive(project.id)
    #expect(archived.lifecycle == .archived)
    #expect(store.activeProjects.allSatisfy { $0.id != project.id })
    #expect(store.archivedProjects.contains { $0.id == project.id })
    #expect(manager.fileExists(atPath: paths.project(project.id, lifecycle: .archived).appendingPathComponent("README.md").path))
    #expect(store.memories(for: project.id).contains { $0.id == memory.id })

    let restored = try projects.restore(project.id)
    #expect(restored.lifecycle == .active)
    #expect(manager.fileExists(atPath: file.path))

    let removed = try await projects.remove(project.id)
    #expect(removed.id == project.id)
    #expect(store.project(id: project.id) == nil)
    #expect(store.removedProject(id: project.id)?.id == project.id)
    #expect(manager.fileExists(atPath: paths.removedProject(project.id).appendingPathComponent("README.md").path))
    #expect(store.memories(for: project.id).contains { $0.id == memory.id })

    let recovered = try projects.recover(project.id)
    #expect(recovered.lifecycle == .active)
    #expect(manager.fileExists(atPath: file.path))
    #expect(store.project(id: project.id) != nil)
}

@Test func scratchCleanupNeverTouchesProjects() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("LimaScratchLifecycle-\(UUID().uuidString)", isDirectory: true)
    defer { try? manager.removeItem(at: root) }
    let paths = AIWorkspacePaths(root: root)
    let scratch = try paths.createScratchRun(UUID())
    let activeID = UUID()
    let activeScratch = try paths.createScratchRun(activeID)
    let project = paths.project(UUID())
    try paths.ensureDirectory(project)
    try manager.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: scratch.path)
    try manager.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: activeScratch.path)
    #expect(try paths.pruneScratch(olderThan: Date(), excluding: [activeID]) == 1)
    #expect(!manager.fileExists(atPath: scratch.path))
    #expect(manager.fileExists(atPath: activeScratch.path))
    #expect(manager.fileExists(atPath: project.path))
}
