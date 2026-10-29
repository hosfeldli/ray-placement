import AppKit
import CryptoKit
import RayPlacementCore
import SwiftUI

/// An AI proposal can only open this local review. The user chooses which
/// source-backed tasks to keep and the exact Note destination.
@MainActor
struct MailAIActionReviewView: View {
    let review: MailActionReview
    let service: MailCapabilityService
    let onDismiss: () -> Void
    let onBusyChanged: (Bool) -> Void

    @ObservedObject private var notesStore = NotesStore.shared
    @State private var noteTitle: String
    @State private var approvedTaskIDs: Set<UUID>
    @State private var targetNoteID: UUID?
    @State private var expectedContentSHA256: String?
    @State private var isWorking = false
    @State private var saveTask: Task<Void, Never>?
    @State private var isPresented = false
    @State private var finishedNoteID: UUID?
    @State private var savedNoteContentSHA256: String?
    @State private var savedTasks: [ExtractedMailTask] = []
    @State private var remindersAttempted = false
    @State private var reminderStatus: String?
    @State private var reminderStatusIsWarning = false
    @State private var status: String?

    init(review: MailActionReview, title: String,
         targetNoteID: UUID? = nil,
         expectedContentSHA256: String? = nil,
         service: MailCapabilityService = .shared,
         onDismiss: @escaping () -> Void,
         onBusyChanged: @escaping (Bool) -> Void) {
        self.review = review
        self.service = service
        self.onDismiss = onDismiss
        self.onBusyChanged = onBusyChanged
        _noteTitle = State(initialValue: title)
        _targetNoteID = State(initialValue: targetNoteID)
        _expectedContentSHA256 = State(initialValue: expectedContentSHA256)
        _approvedTaskIDs = State(initialValue: Set(review.tasks
            .filter { $0.status == .active || $0.status == .proposed }
            .map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review Mail Action Items")
                .font(.title2.weight(.semibold))
            Text("These are AI interpretations of selected-account messages, not completed changes. Review each task and its exact evidence before saving. Canceled, completed, and superseded requests are not added as new checkboxes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(review.tasks) { task in
                        taskRow(task)
                    }
                }
                .padding(.vertical, 3)
            }
            .frame(minHeight: 240)

            Divider()
            HStack(spacing: 10) {
                Menu {
                    Button("Create a new Note") {
                        targetNoteID = nil
                        expectedContentSHA256 = nil
                    }
                    Divider()
                    ForEach(notesStore.notes) { note in
                        Button(note.displayTitle) { selectTarget(note) }
                    }
                } label: {
                    Label(destinationTitle, systemImage: "note.text")
                }
                .disabled(isWorking || finishedNoteID != nil)
                if targetNoteID == nil {
                    TextField("New Note title", text: $noteTitle)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isWorking || finishedNoteID != nil)
                }
            }
            Text(targetNoteID == nil
                 ? "Create a native Lima checklist Note with the selected source links. After saving, you can separately create matching Apple Reminders."
                 : "Append only new tasks to the selected Note. Existing text and completed checkboxes remain unchanged; if the Note changed during review, saving stops. Reminders require a separate click.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(finishedNoteID == nil ? Color.orange : Color.primary)
                    .textSelection(.enabled)
            }
            if let reminderStatus {
                Text(reminderStatus)
                    .font(.caption)
                    .foregroundStyle(reminderStatusIsWarning ? Color.orange : Color.primary)
                    .textSelection(.enabled)
            }
            HStack {
                if isWorking {
                    ProgressView("Checking sources and applying reviewed changes…")
                }
                Spacer()
                Button(isWorking ? "Stop" :
                       finishedNoteID == nil ? "Cancel" : "Close") {
                    if isWorking { saveTask?.cancel() }
                    else { onDismiss() }
                }
                if let finishedNoteID {
                    Button("Create Reminders") {
                        saveTask = Task { await createReminders() }
                    }
                    .disabled(isWorking || remindersAttempted || savedTasks.isEmpty || savedNoteContentSHA256 == nil)
                    .help("Create source-linked Apple Reminders for the reviewed tasks. Existing matching Reminders are skipped.")
                    Button("Open Note") {
                        guard (NSApp.delegate as? AppDelegate)?
                            .openReviewedNote(finishedNoteID) == true else {
                            status = "The Note was saved, but Lima could not open the Notes workspace."
                            return
                        }
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking)
                } else {
                    Button(targetNoteID == nil ? "Create Note" : "Update Note") {
                        saveTask = Task { await save() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || approvedTaskIDs.isEmpty ||
                              (targetNoteID == nil &&
                               noteTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 560)
        .interactiveDismissDisabled(isWorking)
        .onAppear { isPresented = true }
        .onDisappear {
            isPresented = false
            saveTask?.cancel()
        }
    }

    private var destinationTitle: String {
        guard let targetNoteID,
              let note = notesStore.notes.first(where: { $0.id == targetNoteID }) else {
            return "Create a new Note"
        }
        return "Update: \(note.displayTitle)"
    }

    private func taskRow(_ task: ExtractedMailTask) -> some View {
        let selectable = task.status == .active || task.status == .proposed ||
            task.status == .uncertain
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                if selectable {
                    Toggle(isOn: Binding(
                        get: { approvedTaskIDs.contains(task.id) },
                        set: { selected in
                            if selected { approvedTaskIDs.insert(task.id) }
                            else { approvedTaskIDs.remove(task.id) }
                        }
                    )) {
                        Text(task.title).fontWeight(.semibold)
                    }
                    .disabled(isWorking || finishedNoteID != nil)
                } else {
                    Label(task.title, systemImage: "minus.circle")
                        .fontWeight(.semibold)
                }
                Spacer(minLength: 8)
                Text(task.status.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(task.status == .uncertain ? Color.orange : Color.secondary)
            }
            if let details = task.details {
                Text(details).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            let facts = [
                task.owner.map { "Owner: \($0)" },
                task.dueDate.map {
                    "Due: \($0.formatted(date: .abbreviated, time: .omitted))" +
                    (task.inferred ? " (inferred)" : "")
                },
                task.priority.map { "Priority: \($0.rawValue.capitalized)" }
            ].compactMap { $0 }
            if !facts.isEmpty {
                Text(facts.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(task.evidence.enumerated()), id: \.offset) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(item.element.reference.subject) — \(item.element.reference.sender)")
                        .font(.caption2.weight(.semibold))
                    Text("“\(item.element.excerpt)”")
                        .font(.caption2)
                        .textSelection(.enabled)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private func selectTarget(_ note: MarkdownNote) {
        targetNoteID = note.id
        expectedContentSHA256 = SHA256.hash(data: Data(note.content.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func aiMailPolicyStillAllows(_ references: [MailMessageReference]) -> Bool {
        let policy = MailCapabilityPolicyStore.load()
        return policy.readEnabled && policy.allowsAIRead &&
            references.allSatisfy { policy.selectedAccountIDs.contains($0.accountID) }
    }

    private func save() async {
        guard !isWorking, finishedNoteID == nil, !approvedTaskIDs.isEmpty else { return }
        isWorking = true
        onBusyChanged(true)
        status = nil
        defer {
            isWorking = false
            saveTask = nil
            onBusyChanged(false)
        }
        let selected = review.tasks.filter { approvedTaskIDs.contains($0.id) }
        let references = Dictionary(
            selected.flatMap(\.evidence).map { ($0.reference.id, $0.reference) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.receivedAt < $1.receivedAt }
        guard aiMailPolicyStillAllows(references) else {
            status = "AI Mail access or the selected account changed. No Note was changed."
            return
        }
        do {
            var freshMessages: [MailMessage] = []
            for reference in references {
                try Task.checkCancellation()
                freshMessages.append(
                    try await service.message(reference, origin: .userInterface)
                )
            }
            guard isPresented, !Task.isCancelled,
                  aiMailPolicyStillAllows(references) else {
                status = "Mail access changed or this review closed. No Note was changed."
                return
            }
            let freshReview = try MailActionReview.build(
                candidates: selected, from: freshMessages,
                capturedAt: review.capturedAt
            )
            try Task.checkCancellation()
            let draft = try freshReview.snapshotNote(
                title: noteTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Mail follow-ups" : noteTitle,
                approvedTaskIDs: approvedTaskIDs
            )
            let savedID: UUID
            let candidateReminderTasks: [ExtractedMailTask]
            if let targetNoteID {
                guard let expectedContentSHA256 else {
                    status = "Choose the destination Note again. No Note was changed."
                    return
                }
                let result = try notesStore.updateMailActionNote(
                    draft, in: targetNoteID,
                    expectedContentSHA256: expectedContentSHA256
                )
                savedID = result.noteID
                candidateReminderTasks = selected.filter { result.reminderEligibleTaskIDs.contains($0.id) }
                status = "Added \(result.addedTaskCount) task(s) to the Note; skipped \(result.skippedDuplicateCount) existing-title item(s). \(candidateReminderTasks.count) source-matched task(s) can be linked to Reminders."
            } else {
                savedID = try notesStore.createMailActionNote(draft)
                candidateReminderTasks = selected
                status = "Mail-linked checklist Note is ready."
            }
            savedTasks = candidateReminderTasks.filter { notesStore.containsOpenMailTask($0, in: savedID) }
            savedNoteContentSHA256 = notesStore.contentSHA256(for: savedID)
            finishedNoteID = savedID
        } catch is CancellationError {
            status = "Canceled before changing a Note."
        } catch let error as MailActionReviewError {
            switch error {
            case .invalidProposal:
                status = "The proposed tasks are invalid or duplicate one another. No Note was changed."
            case .unverifiedEvidence:
                status = "A quoted excerpt no longer matches its source email. No Note was changed."
            case .invalidApproval:
                status = "The selected tasks could not be saved. No Note was changed."
            }
        } catch {
            status = "\(error.localizedDescription) No Note was changed."
        }
    }

    private func createReminders() async {
        guard !isWorking, let finishedNoteID, let savedNoteContentSHA256,
              !remindersAttempted, !savedTasks.isEmpty else { return }
        isWorking = true
        onBusyChanged(true)
        reminderStatus = nil
        defer {
            isWorking = false
            saveTask = nil
            onBusyChanged(false)
        }
        let references = Dictionary(
            savedTasks.flatMap(\.evidence).map { ($0.reference.id, $0.reference) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.receivedAt < $1.receivedAt }
        guard aiMailPolicyStillAllows(references) else {
            reminderStatus = "AI Mail access or the selected account changed. No Reminder was created; the Note remains saved."
            reminderStatusIsWarning = true
            return
        }
        do {
            var freshMessages: [MailMessage] = []
            for reference in references {
                try Task.checkCancellation()
                freshMessages.append(
                    try await service.message(reference, origin: .userInterface)
                )
            }
            guard isPresented, !Task.isCancelled,
                  aiMailPolicyStillAllows(references) else {
                reminderStatus = "Mail access changed or this review closed. No Reminder was created; the Note remains saved."
                reminderStatusIsWarning = true
                return
            }
            let freshReview = try MailActionReview.build(
                candidates: savedTasks, from: freshMessages,
                capturedAt: review.capturedAt
            )
            try Task.checkCancellation()
            let result = try await EventKitCapabilityService.shared
                .createMailLinkedReminders(
                    from: freshReview.tasks, noteID: finishedNoteID,
                    expectedNoteContentSHA256: savedNoteContentSHA256
                )
            remindersAttempted = result.failure != nil || !result.createdIDs.isEmpty || !result.stopped
            let summary = "Created \(result.createdIDs.count) Reminder(s); found \(result.existingIDs.count) existing."
            if let failure = result.failure {
                reminderStatus = summary + " " + failure + " The Note remains saved."
                reminderStatusIsWarning = true
            } else if result.stopped {
                reminderStatus = summary + " Stopped before remaining tasks. Completed changes were not undone."
                reminderStatusIsWarning = true
            } else {
                reminderStatus = summary + " Open the Lima Note for Mail source evidence."
                reminderStatusIsWarning = false
            }
        } catch is CancellationError {
            reminderStatus = "Stopped before creating a Reminder. The Note remains saved."
            reminderStatusIsWarning = true
        } catch let error as MailActionReviewError {
            reminderStatus = error == .unverifiedEvidence
                ? "A quoted excerpt no longer matches its email. No Reminder was created; the Note remains saved."
                : "The reviewed task evidence is invalid. No Reminder was created; the Note remains saved."
            reminderStatusIsWarning = true
        } catch {
            reminderStatus = "\(error.localizedDescription) No Reminder was created; the Note remains saved."
            reminderStatusIsWarning = true
        }
    }
}

/// One review window at a time prevents an AI run from replacing the user's
/// pending task selection while a Mail read or Note write is in progress.
@MainActor
final class MailAIActionReviewWindowController: NSObject, NSWindowDelegate {
    static let shared = MailAIActionReviewWindowController()
    private var window: NSWindow?
    private var isBusy = false

    @discardableResult
    func present(_ review: MailActionReview, title: String,
                 targetNoteID: UUID? = nil,
                 expectedContentSHA256: String? = nil) -> Bool {
        if let window, window.isVisible || window.isMiniaturized || isBusy {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return false
        }
        window?.close()
        let view = MailAIActionReviewView(
            review: review, title: title,
            targetNoteID: targetNoteID,
            expectedContentSHA256: expectedContentSHA256,
            onDismiss: { [weak self] in self?.window?.close() },
            onBusyChanged: { [weak self] busy in self?.isBusy = busy }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Review Mail Action Items"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: LimaTypographyRoot(content: view))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !isBusy }
}
