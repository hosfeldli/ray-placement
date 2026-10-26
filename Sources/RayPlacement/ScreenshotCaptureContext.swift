import AppKit

/// A takeover is permanent for this capture, even if the user switches back
/// before ScreenCaptureKit or local OCR finishes.
struct ScreenshotCaptureContextState {
    let limaProcessID: pid_t
    let sourceProcessID: pid_t?
    let clipboardChangeCount: Int
    private(set) var invalidated = false

    mutating func observeActivation(_ processID: pid_t?) {
        if !QuickRegionCaptureFocus.permitsCapture(
            frontmostProcessID: processID, limaProcessID: limaProcessID,
            sourceProcessID: sourceProcessID
        ) {
            invalidate()
        }
    }

    mutating func invalidate() { invalidated = true }

    func permitsCompletion(frontmostProcessID: pid_t?, clipboardChangeCount: Int) -> Bool {
        !invalidated && clipboardChangeCount == self.clipboardChangeCount &&
        QuickRegionCaptureFocus.permitsCapture(
            frontmostProcessID: frontmostProcessID, limaProcessID: limaProcessID,
            sourceProcessID: sourceProcessID
        )
    }
}

/// Shared by direct capture and Studio. No global input monitoring or new
/// system permissions are needed: workspace/display notifications suffice.
@MainActor
final class ScreenshotCaptureContext: NSObject {
    private var state: ScreenshotCaptureContextState
    private let pasteboard: NSPasteboard

    init(sourceProcessID: pid_t?, pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        state = ScreenshotCaptureContextState(
            limaProcessID: ProcessInfo.processInfo.processIdentifier,
            sourceProcessID: sourceProcessID,
            clipboardChangeCount: pasteboard.changeCount
        )
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(displayConfigurationChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    var isCurrent: Bool {
        state.permitsCompletion(
            frontmostProcessID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            clipboardChangeCount: pasteboard.changeCount
        )
    }

    @objc private func applicationActivated(_ notification: Notification) {
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        state.observeActivation(application?.processIdentifier)
    }

    @objc private func displayConfigurationChanged(_ notification: Notification) {
        state.invalidate()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }
}
