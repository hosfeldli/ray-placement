import AppKit
import Foundation

enum QuickRegionCaptureKind: Sendable {
    case image
    case text
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

        Task { [weak self] in
            guard let self else { return }
            do {
                let displays = try await captureService.availableTargets()
                    .filter { $0.kind == .display }
                guard activeRunID == runID else { return }
                guard !displays.isEmpty else { throw QuickRegionCaptureError.noDisplay }
                _ = regionSelection.present(
                    displays: displays,
                    onSelect: { [weak self] target in
                        self?.capture(target, kind: kind, runID: runID)
                    },
                    onCancel: { [weak self] in
                        self?.finish(runID: runID, result: nil)
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
                let captured = try await captureService.capture(target)
                if kind == .text {
                    toast.show("Reading region…", style: .working, duration: 20)
                }
                let payload = try await Task.detached(priority: .userInitiated) {
                    try QuickRegionCapturePayload.prepare(
                        kind: kind, pngData: captured.pngData
                    )
                }.value
                guard activeRunID == runID else { return }
                guard payload.copy() else { throw QuickRegionCaptureError.clipboardUnavailable }
                finish(runID: runID, result: .success(kind))
            } catch {
                finish(runID: runID, result: .failure(error))
            }
        }
    }

    private func finish(runID: UUID, result: Result<QuickRegionCaptureKind, Error>?) {
        guard activeRunID == runID else { return }
        regionSelection.dismiss(notifyCancel: false)
        activeRunID = nil
        let application = returnApplication
        returnApplication = nil
        application?.activate(options: [.activateIgnoringOtherApps])
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
