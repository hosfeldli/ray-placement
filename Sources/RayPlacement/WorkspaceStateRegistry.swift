import AppKit
import Foundation
import RayPlacementCore

@MainActor
final class WorkspaceStateRegistry: ObservableObject {
    static let shared = WorkspaceStateRegistry()
    @Published private(set) var state: WorkspaceState
    @Published var lastError: String?
    private let store = PrivateFileStore()
    private let url = ApplicationPaths.applicationSupport.appendingPathComponent("workspace-state.json")

    private init() {
        let loaded = store.loadJSON(WorkspaceState.self, from: url)
        state = loaded.value ?? WorkspaceState()
        if loaded.result.state == .corrupt || loaded.result.state == .unreadable {
            lastError = "Workspace state could not be restored. A recovery copy was preserved."
        }
    }

    func update(_ change: (inout WorkspaceState) -> Void) {
        change(&state)
        do {
            try ApplicationPaths.prepare()
            try store.write(state, to: url)
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    func remember(window: NSWindow, identifier: String) {
        update { $0.windowFrames[identifier] = NSStringFromRect(window.frame) }
    }

    func restore(window: NSWindow, identifier: String) {
        guard let raw = state.windowFrames[identifier] else { return }
        window.setFrame(NSRectFromString(raw), display: false)
    }
}
