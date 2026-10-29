import AppKit
import SwiftUI

/// AI may open this local editor, but it cannot submit a Messages send.
@MainActor
final class MessagesComposeWindowController: NSObject, NSWindowDelegate {
    static let shared = MessagesComposeWindowController()

    private var window: NSWindow?
    private var isBusy = false

    @discardableResult
    func present(_ proposal: MessagesOutgoingRequest,
                 conversationTitle: String) -> Bool {
        if let window, window.isVisible || window.isMiniaturized || isBusy {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return false
        }
        window?.close()
        let editor = MessagesComposeReviewView(
            proposal: proposal,
            conversationTitle: conversationTitle,
            onDismiss: { [weak self] in self?.window?.close() },
            onBusyChanged: { [weak self] busy in self?.isBusy = busy }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Prepare Messages Text"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: LimaTypographyRoot(content: editor))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        !isBusy
    }
}
