import AppKit
import Foundation
import RayPlacementCore

struct NoteSummaryProposal: Identifiable, Equatable {
    let id = UUID()
    let noteID: UUID
    let noteTitle: String
    let markdown: String
}

@MainActor
final class NoteSummaryService: ObservableObject {
    @Published private(set) var isSummarizing = false
    @Published private(set) var progressText: String?
    @Published private(set) var proposal: NoteSummaryProposal?
    @Published var lastError: String?

    private let runner = WritingProviderRunner()
    private var requestID: UUID?

    func summarize(_ note: MarkdownNote) {
        guard !isSummarizing else { return }
        let source = note.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            lastError = "Write something in this note before asking Qwen to summarize it."
            return
        }

        isSummarizing = true
        let requestID = UUID()
        self.requestID = requestID
        lastError = nil
        proposal = nil
        progressText = "Preparing the note for Qwen…"
        runner.summarize(source) { [weak self] progress in
            guard self?.requestID == requestID else { return }
            self?.progressText = progress
        } completion: { [weak self] result in
            guard let self, self.requestID == requestID else { return }
            self.requestID = nil
            self.isSummarizing = false
            self.progressText = nil
            switch result {
            case .success(let summary):
                self.proposal = NoteSummaryProposal(
                    noteID: note.id,
                    noteTitle: note.displayTitle,
                    markdown: summary
                )
            case .failure(let error):
                self.lastError = error.localizedDescription
            }
        }
    }

    func cancel() {
        guard isSummarizing else { return }
        requestID = nil
        runner.cancel()
        isSummarizing = false
        progressText = nil
        lastError = "Qwen summarization was cancelled."
    }

    func dismissProposal() {
        proposal = nil
    }

    func copyProposal() {
        guard let proposal else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(proposal.markdown, forType: .string)
    }
}
