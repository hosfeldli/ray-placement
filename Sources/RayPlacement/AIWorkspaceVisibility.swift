import AppKit
import SwiftUI

/// Tracks actual visible Chat hosts, including the split view. A mounted view
/// inside a closed or minimized window must not suppress the activity shelf.
@MainActor
final class AIWorkspaceVisibility: ObservableObject {
    static let shared = AIWorkspaceVisibility()
    @Published private(set) var isVisible = false
    private let hosts = NSHashTable<NSView>.weakObjects()
    private var timer: Timer?

    func register(_ view: NSView) {
        hosts.add(view)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        Task { @MainActor in
            await Task.yield()
            self.refresh()
        }
    }

    func refresh() {
        let visible = hosts.allObjects.contains { view in
            view.window.map { $0.isVisible && !$0.isMiniaturized && !view.isHiddenOrHasHiddenAncestor } ?? false
        }
        if visible != isVisible { isVisible = visible }
        if hosts.allObjects.isEmpty { timer?.invalidate(); timer = nil }
    }
}

struct AIWorkspaceVisibilityMarker: NSViewRepresentable {
    final class Marker: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            AIWorkspaceVisibility.shared.register(self)
        }
    }
    func makeNSView(context: Context) -> NSView { Marker() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
