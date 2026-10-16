import AppKit
import Foundation
import RayPlacementCore

/// Serial disk writer for immutable Workspace snapshots. Window and module
/// updates stay synchronous in memory, but JSON encoding and atomic file I/O
/// never run as part of a SwiftUI/MainActor state change.
final class WorkspaceStatePersistence: Sendable {
    private let queue = DispatchQueue(label: "Lima.WorkspaceStatePersistence", qos: .utility)
    private let store = PrivateFileStore()
    private let url: URL

    init(url: URL) { self.url = url }

    func write(_ snapshot: WorkspaceState, completion: @escaping @Sendable (String?) -> Void) {
        queue.async {
            do {
                try self.store.write(snapshot, to: self.url)
                completion(nil)
            } catch {
                completion(error.localizedDescription)
            }
        }
    }

    /// Called at app shutdown (and in tests) so the last queued snapshot is durable.
    func flush() { queue.sync {} }
}

@MainActor
final class WorkspaceStateRegistry: ObservableObject {
    static let shared = WorkspaceStateRegistry()
    @Published private(set) var state: WorkspaceState
    @Published var lastError: String?
    private let store = PrivateFileStore()
    private let url = ApplicationPaths.applicationSupport.appendingPathComponent("workspace-state.json")
    private lazy var persistence = WorkspaceStatePersistence(url: url)
    private var pendingSaveTask: Task<Void, Never>?
    private var writeGeneration = 0

    private init() {
        let loaded = store.loadJSON(WorkspaceState.self, from: url)
        state = loaded.value ?? WorkspaceState()
        if loaded.result.state == .corrupt || loaded.result.state == .unreadable {
            lastError = "Workspace state could not be restored. A recovery copy was preserved."
        }
    }

    func update(_ change: (inout WorkspaceState) -> Void) {
        change(&state)
        writeGeneration &+= 1
        let generation = writeGeneration
        let snapshot = state
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.pendingSaveTask = nil
            self.enqueueWrite(snapshot, generation: generation)
        }
    }

    /// Normal app termination persists the newest in-memory state, even if its
    /// debounce interval has not elapsed, then waits for serial disk work.
    func flushPendingWrites() {
        if pendingSaveTask != nil {
            pendingSaveTask?.cancel()
            pendingSaveTask = nil
            enqueueWrite(state, generation: writeGeneration)
        }
        persistence.flush()
    }

    private func enqueueWrite(_ snapshot: WorkspaceState, generation: Int) {
        persistence.write(snapshot) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.writeGeneration == generation else { return }
                self.lastError = error
            }
        }
    }

    func remember(window: NSWindow, identifier: String) {
        update { $0.windowFrames[identifier] = NSStringFromRect(window.frame) }
    }

    func restore(window: NSWindow, identifier: String) {
        guard let raw = state.windowFrames[identifier] else { return }
        window.setFrame(NSRectFromString(raw), display: false)
    }
}
