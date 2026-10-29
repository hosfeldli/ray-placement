import AppKit
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
    @State private var finishedNoteID: UUID?
    @State private var savedNoteContentSHA256: String?
    @State private var savedProposal: MailManualActionNoteProposal?
    @State private var reminderAttempted = false
    @State private var reminderStatus: String?
    @State private var reminderStatusIsWarning = false
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
                Text("Only the reviewed action, source metadata, and excerpt are saved in the note—not the full email body. Creating a note does not alter Apple Mail; a Reminder requires a separate click after saving.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let status {
                Text(status)
                    .foregroundStyle(finished ? Color.primary : Color.orange)
                    .textSelection(.enabled)
            }
            if let reminderStatus {
                Text(reminderStatus)
                    .foregroundStyle(reminderStatusIsWarning ? Color.orange : Color.primary)
                    .textSelection(.enabled)
            }

            if isWorking {
                ProgressView("Checking source and applying reviewed changes…")
            } else if let finishedNoteID {
                HStack {
                    Button("Create Reminder") {
                        Task { await createReminder() }
                    }
                    .disabled(reminderAttempted || savedProposal == nil || savedNoteContentSHA256 == nil)
                    .help("Create one source-linked Apple Reminder after checking the Mail evidence again.")
                    Button("Open Note") {
                        if (NSApp.delegate as? AppDelegate)?
                            .openReviewedNote(finishedNoteID) != true {
                            status = "The Note was saved, but Lima could not open the Notes workspace."
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
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
            let savedID = try notesStore.createMailActionNote(draft)
            finishedNoteID = savedID
            savedNoteContentSHA256 = notesStore.contentSHA256(for: savedID)
            savedProposal = proposal
            finished = true
            status = "Mail-linked note is ready."
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

    private func createReminder() async {
        guard !isWorking, let finishedNoteID, let savedNoteContentSHA256,
              let savedProposal, !reminderAttempted else { return }
        isWorking = true
        reminderStatus = nil
        defer { isWorking = false }
        do {
            let fresh = try await service.message(savedProposal.source, origin: .userInterface)
            guard isPresented, !Task.isCancelled else {
                reminderStatus = "The review closed before creating a Reminder. The Note remains saved."
                reminderStatusIsWarning = true
                return
            }
            let task = try savedProposal.reviewedTask(from: fresh)
            let result = try await EventKitCapabilityService.shared
                .createMailLinkedReminders(
                    from: [task], noteID: finishedNoteID,
                    expectedNoteContentSHA256: savedNoteContentSHA256
                )
            reminderAttempted = result.failure != nil || !result.createdIDs.isEmpty || !result.stopped
            if let failure = result.failure {
                reminderStatus = "Created \(result.createdIDs.count) Reminder(s); found \(result.existingIDs.count) existing. " + failure + " The Note remains saved."
                reminderStatusIsWarning = true
            } else if result.stopped {
                reminderStatus = "Stopped before the Reminder transfer completed. The Note remains saved."
                reminderStatusIsWarning = true
            } else if result.createdIDs.isEmpty {
                reminderStatus = "A matching Reminder already exists. The Note remains saved."
                reminderStatusIsWarning = false
            } else {
                reminderStatus = "Created a Mail-linked Reminder. Open the Lima Note for source evidence."
                reminderStatusIsWarning = false
            }
        } catch let error as MailActionReviewError {
            reminderStatus = error == .unverifiedEvidence
                ? "The supporting excerpt no longer matches Mail. No Reminder was created."
                : "The reviewed action is invalid. No Reminder was created."
            reminderStatusIsWarning = true
        } catch {
            reminderStatus = "\(error.localizedDescription) No Reminder was created; the Note remains saved."
            reminderStatusIsWarning = true
        }
    }
}
