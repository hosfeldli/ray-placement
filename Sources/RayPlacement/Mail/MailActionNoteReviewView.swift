import SwiftUI

/// A non-AI path from one opened message to an editable, source-linked note.
/// The user writes the action and selects a short exact supporting excerpt.
/// Lima reads the selected message again before committing the local note.
@MainActor
struct MailActionNoteReviewView: View {
    let message: MailMessage
    let service: MailCapabilityService

    @ObservedObject private var notesStore = NotesStore.shared
    @State private var noteTitle = "Mail follow-up"
    @State private var actionTitle = ""
    @State private var evidenceExcerpt = ""
    @State private var taskID = UUID()
    @State private var capturedAt = Date()
    @State private var isWorking = false
    @State private var isPresented = false
    @State private var finished = false
    @State private var status: String?

    init(message: MailMessage, service: MailCapabilityService = .shared) {
        self.message = message
        self.service = service
    }

    var body: some View {
        Form {
            Section("Source message") {
                LabeledContent("Subject", value: message.reference.subject.isEmpty ? "(No subject)" : message.reference.subject)
                LabeledContent("From", value: message.reference.sender)
                LabeledContent("Received", value: message.reference.receivedAt.formatted(date: .abbreviated, time: .shortened))
                ScrollView {
                    Text(message.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 100, maxHeight: 180)
            }

            Section("Review action note") {
                TextField("Note title", text: $noteTitle)
                    .accessibilityLabel("Mail action note title")
                    .disabled(isWorking || finished)
                TextField("Action item", text: $actionTitle)
                    .accessibilityLabel("Mail action item")
                    .disabled(isWorking || finished)
                Text("Copy a short, exact supporting excerpt from the source message. Lima checks it against a fresh read before saving.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $evidenceExcerpt)
                    .frame(minHeight: 70, maxHeight: 110)
                    .accessibilityLabel("Exact Mail evidence excerpt")
                    .disabled(isWorking || finished)
                Text("Only the reviewed action, source metadata, and excerpt are saved in the note—not the full email body. Creating a note does not alter Apple Mail.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let status {
                Text(status)
                    .foregroundStyle(finished ? Color.primary : Color.orange)
                    .textSelection(.enabled)
            }

            if isWorking {
                ProgressView("Checking source and creating note…")
            } else if !finished {
                Button("Create Mail-Linked Note") {
                    Task { await createNote() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(noteTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          actionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          evidenceExcerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          evidenceExcerpt.count > 350)
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .interactiveDismissDisabled(isWorking)
        .onAppear { isPresented = true }
        .onDisappear { isPresented = false }
    }

    private func createNote() async {
        guard !isWorking, !finished else { return }
        isWorking = true
        status = nil
        defer { isWorking = false }
        let proposal = MailManualActionNoteProposal(
            source: message.reference, noteTitle: noteTitle,
            actionTitle: actionTitle, evidenceExcerpt: evidenceExcerpt,
            taskID: taskID, capturedAt: capturedAt
        )
        do {
            let fresh = try await service.message(message.reference, origin: .userInterface)
            guard isPresented, !Task.isCancelled else { return }
            let draft = try proposal.draft(from: fresh)
            _ = try notesStore.createMailActionNote(draft)
            finished = true
            status = "Mail-linked note created. Open Lima Notes to edit it."
        } catch let error as MailCapabilityError {
            status = error.localizedDescription
        } catch let error as MailActionReviewError {
            switch error {
            case .invalidProposal:
                status = "Enter a valid note title, action, and excerpt of at most 350 characters."
            case .unverifiedEvidence:
                status = "The excerpt must still appear exactly in the source message."
            case .invalidApproval:
                status = "The reviewed note could not be created."
            }
        } catch {
            status = "Lima could not create the Mail-linked note."
        }
    }
}
