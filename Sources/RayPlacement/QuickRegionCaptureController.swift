import AppKit
import Foundation

enum QuickRegionCaptureKind: Sendable {
    case image
    case text

    var selectionInstruction: String {
        switch self {
        case .image: "Drag within one display to copy an image • Esc to cancel"
        case .text: "Drag within one display to read text • Esc to cancel"
        }
    }
}

enum QuickRegionCapturePayload: Equatable, Sendable {
    case image(Data)
    case text(String)

    static func prepare(
        kind: QuickRegionCaptureKind,
        pngData: Data,
        recognize: (Data) throws -> String? = ScreenshotTextRecognizer.recognize
    ) throws -> Self {
        switch kind {
        case .image:
            return .image(pngData)
        case .text:
            guard let text = try recognize(pngData)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                throw QuickRegionCaptureError.noText
            }
            return .text(text)
        }
    }

    @MainActor
    func copy(to pasteboard: NSPasteboard = .general) -> Bool {
        switch self {
        case .image(let data):
            return ScreenshotClipboard.copyPNG(data, to: pasteboard)
        case .text(let value):
            pasteboard.clearContents()
            return pasteboard.setString(value, forType: .string)
        }
    }
}

enum QuickRegionCaptureError: LocalizedError {
    case noDisplay
    case noText
    case clipboardUnavailable

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display is available for region capture."
        case .noText: return "No readable text was found. The clipboard was not changed."
        case .clipboardUnavailable: return "The captured content could not be copied to the clipboard."
        }
    }
}

enum QuickRegionCaptureFocus {
    static func permitsCapture(frontmostProcessID: pid_t?, limaProcessID: pid_t,
                               sourceProcessID: pid_t?) -> Bool {
        guard let frontmostProcessID else { return false }
        return frontmostProcessID == limaProcessID || frontmostProcessID == sourceProcessID
    }
}

/// A direct, user-initiated region-to-clipboard flow. It deliberately does not
/// open Screenshot Studio, write a file, or import a Screenshot History record.
@MainActor
final class QuickRegionCaptureController {
    static let shared = QuickRegionCaptureController()

    private let captureService = ScreenshotCaptureService.shared
    private let regionSelection = ScreenshotRegionSelectionController()
    private let toast = ActionToastController()
    private var activeRunID: UUID?
    private var returnApplication: NSRunningApplication?
    private var captureContext: ScreenshotCaptureContext?

    func start(_ kind: QuickRegionCaptureKind, returningTo application: NSRunningApplication?) {
        guard activeRunID == nil else { return }
        guard #available(macOS 14.0, *) else {
            toast.show(ScreenshotCaptureError.unsupportedSystem.localizedDescription,
                       style: .error, duration: 4)
            return
        }
        if !captureService.hasScreenRecordingPermission {
            _ = captureService.requestScreenRecordingPermission()
            guard captureService.hasScreenRecordingPermission else {
                toast.show(ScreenshotCaptureError.permissionRequired.localizedDescription,
                           style: .error, duration: 5)
                return
            }
        }

        let runID = UUID()
        activeRunID = runID
        returnApplication = application?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : application
        captureContext = ScreenshotCaptureContext(sourceProcessID: returnApplication?.processIdentifier)

        Task { [weak self] in
            guard let self else { return }
            do {
                let displays = try await captureService.availableTargets()
                    .filter { $0.kind == .display }
                guard activeRunID == runID else { return }
                guard captureContextIsCurrent else {
                    finish(runID: runID, result: nil, restoreApplication: false)
                    return
                }
                guard !displays.isEmpty else { throw QuickRegionCaptureError.noDisplay }
                _ = regionSelection.present(
                    displays: displays,
                    instruction: kind.selectionInstruction,
                    onSelect: { [weak self] target in
                        self?.capture(target, kind: kind, runID: runID)
                    },
                    onCancel: { [weak self] in
                        self?.finish(runID: runID, result: nil)
                    },
                    onTakeover: { [weak self] in
                        self?.finish(runID: runID, result: nil, restoreApplication: false)
                    }
                )
            } catch {
                finish(runID: runID, result: .failure(error))
            }
        }
    }

    private func capture(_ target: ScreenshotCaptureTarget,
                         kind: QuickRegionCaptureKind, runID: UUID) {
        guard activeRunID == runID else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                // Selection overlays must leave the compositor before capture.
                try await Task.sleep(nanoseconds: 180_000_000)
                guard activeRunID == runID else { return }
                guard captureContextIsCurrent else {
                    finish(runID: runID, result: nil, restoreApplication: false)
                    return
                }
                let captured = try await captureService.capture(target)
                guard activeRunID == runID else { return }
                guard captureContextIsCurrent else {
                    finish(runID: runID, result: nil, restoreApplication: false)
                    return
                }
                if kind == .text {
                    toast.show("Reading region…", style: .working, duration: 20)
                }
                let payload = try await Task.detached(priority: .userInitiated) {
                    try QuickRegionCapturePayload.prepare(
                        kind: kind, pngData: captured.pngData
                    )
                }.value
                guard activeRunID == runID else { return }
                guard captureContextIsCurrent else {
                    finish(runID: runID, result: nil, restoreApplication: false)
                    return
                }
                guard payload.copy() else { throw QuickRegionCaptureError.clipboardUnavailable }
                finish(runID: runID, result: .success(kind))
            } catch {
                finish(runID: runID, result: .failure(error))
            }
        }
    }

    /// A user switch to a third application is a takeover, not a reason to
    /// capture its pixels or overwrite the user's clipboard. The source app
    /// may legitimately become foreground again after the overlay closes.
    private var captureContextIsCurrent: Bool {
        captureContext?.isCurrent == true
    }

    private func finish(runID: UUID, result: Result<QuickRegionCaptureKind, Error>?,
                        restoreApplication: Bool = true) {
        guard activeRunID == runID else { return }
        // Failed asynchronous work must not steal focus after a takeover.
        // A successful copy changes the clipboard count itself.
        let contextCurrent: Bool
        if case .success = result { contextCurrent = true }
        else { contextCurrent = captureContextIsCurrent }
        regionSelection.dismiss(notifyCancel: false)
        activeRunID = nil
        let application = returnApplication
        returnApplication = nil
        captureContext = nil
        if restoreApplication && contextCurrent {
            application?.activate(options: [.activateIgnoringOtherApps])
        }
        guard contextCurrent else { toast.dismiss(); return }
        switch result {
        case .success(.image):
            toast.show("Region image copied to clipboard")
        case .success(.text):
            toast.show("Region text copied to clipboard")
        case .failure(let error):
            toast.show(error.localizedDescription, style: .error, duration: 4)
        case nil:
            toast.dismiss()
        }
    }
}
