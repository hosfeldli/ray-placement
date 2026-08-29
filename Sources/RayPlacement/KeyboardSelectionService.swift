import AppKit
import CoreGraphics
import Foundation

/// A user-initiated copy transaction for editors that do not expose selected
/// text through Accessibility (many browser, Electron, and custom controls).
/// The previous clipboard is restored when no other app changed it meanwhile.
@MainActor
enum KeyboardSelectionService {
    struct Capture {
        let processIdentifier: pid_t
        let text: String
    }

    enum CaptureError: LocalizedError {
        case applicationUnavailable
        case activationFailed
        case copyUnavailable
        case emptySelection

        var errorDescription: String? {
            switch self {
            case .applicationUnavailable:
                return "The source app is no longer available."
            case .activationFailed:
                return "The source app did not become ready for the keyboard command."
            case .copyUnavailable:
                return "RayPlacement sent Copy, but the app did not place readable text on the clipboard."
            case .emptySelection:
                return "The app copied no text. Highlight text in the source app and try again."
            }
        }
    }

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]

        init(_ pasteboard: NSPasteboard) {
            items = (pasteboard.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                })
            }
        }

        func restore(to pasteboard: NSPasteboard, ifUnchangedSince changeCount: Int) {
            guard pasteboard.changeCount == changeCount else { return }
            pasteboard.clearContents()
            guard !items.isEmpty else { return }
            let restored = items.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            pasteboard.writeObjects(restored)
        }
    }

    static func capture(
        from application: NSRunningApplication,
        clipboardHistory: ClipboardHistoryService,
        completion: @escaping (Result<Capture, Error>) -> Void
    ) {
        guard !application.isTerminated else {
            completion(.failure(CaptureError.applicationUnavailable))
            return
        }

        activate(application) { ready in
            guard ready else {
                completion(.failure(CaptureError.activationFailed))
                return
            }
            let pasteboard = NSPasteboard.general
            let snapshot = PasteboardSnapshot(pasteboard)
            let originalChangeCount = pasteboard.changeCount
            guard postCommandKey(keyCode: 8) else {
                completion(.failure(CaptureError.copyUnavailable))
                return
            }
            waitForCopy(
                pasteboard: pasteboard,
                originalChangeCount: originalChangeCount,
                attemptsRemaining: 60
            ) { result in
                switch result {
                case .success(let copiedChangeCount):
                    let text = pasteboard.string(forType: .string) ?? ""
                    // Rich editors may publish extra pasteboard flavors shortly
                    // after the string. Restore after that small write window.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
                        snapshot.restore(to: pasteboard, ifUnchangedSince: copiedChangeCount)
                        clipboardHistory.synchronizePasteboardChangeCount()
                    }
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        completion(.failure(CaptureError.emptySelection))
                        return
                    }
                    completion(.success(Capture(
                        processIdentifier: application.processIdentifier,
                        text: text
                    )))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    static func paste(
        into application: NSRunningApplication,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        activate(application) { ready in
            guard ready else {
                completion(.failure(CaptureError.activationFailed))
                return
            }
            guard postCommandKey(keyCode: 9) else {
                completion(.failure(CaptureError.copyUnavailable))
                return
            }
            // Some Electron and Office editors consume the pasteboard on their
            // next event-loop turn. Do not report completion before that turn.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                completion(.success(()))
            }
        }
    }

    /// Pastes a supplied string as an atomic clipboard transaction and restores
    /// the user's previous clipboard after the target had time to consume it.
    static func paste(
        _ text: String,
        into application: NSRunningApplication,
        clipboardHistory: ClipboardHistoryService,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        activate(application) { ready in
            guard ready else {
                completion(.failure(CaptureError.activationFailed))
                return
            }
            let pasteboard = NSPasteboard.general
            let snapshot = PasteboardSnapshot(pasteboard)
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                completion(.failure(CaptureError.copyUnavailable))
                return
            }
            let replacementChangeCount = pasteboard.changeCount
            clipboardHistory.synchronizePasteboardChangeCount()
            guard postCommandKey(keyCode: 9) else {
                snapshot.restore(to: pasteboard, ifUnchangedSince: replacementChangeCount)
                clipboardHistory.synchronizePasteboardChangeCount()
                completion(.failure(CaptureError.copyUnavailable))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                completion(.success(()))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.90) {
                snapshot.restore(to: pasteboard, ifUnchangedSince: replacementChangeCount)
                clipboardHistory.synchronizePasteboardChangeCount()
            }
        }
    }

    private static func activate(
        _ application: NSRunningApplication,
        completion: @escaping (Bool) -> Void
    ) {
        guard !application.isTerminated else {
            completion(false)
            return
        }
        application.unhide()
        application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        waitUntilFrontmost(application, attemptsRemaining: 30, completion: completion)
    }

    private static func waitUntilFrontmost(
        _ application: NSRunningApplication,
        attemptsRemaining: Int,
        completion: @escaping (Bool) -> Void
    ) {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if application.isActive || frontmostPID == application.processIdentifier {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { completion(true) }
            return
        }
        guard attemptsRemaining > 0, !application.isTerminated else {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            waitUntilFrontmost(
                application,
                attemptsRemaining: attemptsRemaining - 1,
                completion: completion
            )
        }
    }

    private static func waitForCopy(
        pasteboard: NSPasteboard,
        originalChangeCount: Int,
        attemptsRemaining: Int,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        if pasteboard.changeCount != originalChangeCount {
            completion(.success(pasteboard.changeCount))
            return
        }
        guard attemptsRemaining > 0 else {
            completion(.failure(CaptureError.copyUnavailable))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            waitForCopy(
                pasteboard: pasteboard,
                originalChangeCount: originalChangeCount,
                attemptsRemaining: attemptsRemaining - 1,
                completion: completion
            )
        }
    }

    private static func postCommandKey(keyCode: CGKeyCode) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
