import AppKit
import SwiftUI

/// AI may open this local editor, but it never receives a Mail write capability.
/// The existing composer owns draft saving and one-shot exact-message send review.
@MainActor
final class MailComposeWindowController: NSObject, NSWindowDelegate {
    static let shared = MailComposeWindowController()

    private var window: NSWindow?
    private var isBusy = false

    @discardableResult
    func present(_ proposal: MailOutgoingRequest) -> Bool {
        if let window, window.isVisible || window.isMiniaturized || isBusy {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return false
        }
        window?.close()

        let editor = MailComposeReviewView(
            proposal: proposal,
            onDismiss: { [weak self] in self?.window?.close() },
            onBusyChanged: { [weak self] busy in self?.isBusy = busy }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Prepare Mail Message"
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
