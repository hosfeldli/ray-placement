import AppKit
import Foundation

@MainActor
final class ContextShelfCaptureService {
    struct CapturedSelection {
        let text: String
        let applicationName: String?
        let bundleIdentifier: String?
        let captureMethod: CaptureMethod
    }

    enum CaptureMethod {
        case accessibility
        case clipboardFallback
    }

    enum CaptureError: LocalizedError {
        case noSourceApplication
        case limaSource
        case emptySelection
        case unavailable(Error)

        var errorDescription: String? {
            switch self {
            case .noSourceApplication:
                return "Select text in another app, then try again."
            case .limaSource:
                return "Lima cannot capture a selection from its own interface."
            case .emptySelection:
                return "Select some text in the source app, then try again."
            case .unavailable(let error):
                return error.localizedDescription
            }
        }
    }

    private let clipboard: ClipboardHistoryService
    private let store: ContextShelfStore

    init() {
        self.clipboard = .shared
        self.store = .shared
    }

    init(clipboard: ClipboardHistoryService, store: ContextShelfStore) {
        self.clipboard = clipboard
        self.store = store
    }

    func capture(
        from sourceApplication: NSRunningApplication?,
        completion: @escaping (Result<ContextShelfItem, Error>) -> Void
    ) {
        guard let application = sourceApplication,
              !application.isTerminated else {
            completion(.failure(CaptureError.noSourceApplication))
            return
        }
        guard application.bundleIdentifier != Bundle.main.bundleIdentifier else {
            completion(.failure(CaptureError.limaSource))
            return
        }

        let processIdentifier = application.processIdentifier
        if let accessibilitySelection = try? SelectedTextService.selectionContext(in: processIdentifier),
           !accessibilitySelection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finish(
                CapturedSelection(
                    text: accessibilitySelection.text,
                    applicationName: application.localizedName,
                    bundleIdentifier: application.bundleIdentifier,
                    captureMethod: .accessibility
                ),
                completion: completion
            )
            return
        }

        KeyboardSelectionService.capture(from: application, clipboardHistory: clipboard) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let capture):
                self.finish(
                    CapturedSelection(
                        text: capture.text,
                        applicationName: application.localizedName,
                        bundleIdentifier: application.bundleIdentifier,
                        captureMethod: .clipboardFallback
                    ),
                    completion: completion
                )
            case .failure(let error):
                completion(.failure(CaptureError.unavailable(error)))
            }
        }
    }

    private func finish(
        _ selection: CapturedSelection,
        completion: @escaping (Result<ContextShelfItem, Error>) -> Void
    ) {
        let trimmed = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.failure(CaptureError.emptySelection))
            return
        }
        let source = ContextShelfSource.application(
            name: selection.applicationName,
            bundleIdentifier: selection.bundleIdentifier
        )
        let item = ContextShelfItem(
            id: UUID(),
            kind: .selectedText,
            title: ContextShelfTextFormatting.title(for: trimmed),
            preview: ContextShelfTextFormatting.preview(for: trimmed),
            payload: .text(trimmed),
            source: source,
            createdAt: Date(),
            isPinned: false
        )
        _ = store.add(item)
        completion(.success(item))
    }
}
