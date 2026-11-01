import SwiftUI

struct AIScheduledTasksView: View {
    @ObservedObject var model: AIChatViewModel
    @ObservedObject private var store: AIScheduledTaskStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var instructions = ""
    @State private var runAt = Date().addingTimeInterval(3600)
    @State private var graceMinutes = 30
    @State private var error: String?
    @State private var creating = false
    @State private var browserMode = BrowserApprovalMode.askForActions

    init(model: AIChatViewModel, store: AIScheduledTaskStore? = nil, initiallyCreating: Bool = false) {
        self.model = model
        self.store = store ?? .shared
        _creating = State(initialValue: initiallyCreating)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Scheduled tasks", systemImage: "clock.badge.checkmark")
                        .font(.title2.weight(.semibold))
                    Text("Pick up the work when the time is right.")
                        .foregroundStyle(LimaTheme.textSecondary)
                }
                Spacer()
                Button("New task", systemImage: "plus") { creating.toggle() }
                    .disabled(model.selectedConversationID == nil)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "desktopcomputer").foregroundStyle(.tint)
                Text("Keep Lima running and your Mac awake. Tasks start when the chat is idle, use current permissions, and pause for any required approval. Missed start windows expire safely.")
                    .font(.callout).foregroundStyle(LimaTheme.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(12).background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
            .layoutPriority(1)

            if let message = error ?? store.error {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            if store.tasks.isEmpty && !creating {
                VStack(spacing: 10) {
                    Image(systemName: "moon.stars").font(.system(size: 36)).foregroundStyle(LimaTheme.textSecondary)
                    Text("Let Lima come back to it").font(.headline)
                    Text("“Try the reservation when tables open at midnight.”\nSave the instructions, a start time, and how late it may begin.")
                        .multilineTextAlignment(.center).foregroundStyle(LimaTheme.textSecondary)
                    Button("Schedule a task") { creating = true }
                        .disabled(model.selectedConversationID == nil)
                }.frame(maxWidth: .infinity, minHeight: 220)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if creating { editor }
                        ForEach(store.tasks.sorted {
                            $0.state.sortPriority == $1.state.sortPriority ? $0.runAt < $1.runAt : $0.state.sortPriority < $1.state.sortPriority
                        }) { task in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(task.title).font(.headline)
                                    Spacer()
                                    Text(task.state.title).font(.caption.weight(.semibold))
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(LimaTheme.surfaceSelected, in: Capsule())
                                }
                                Text(task.runAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: .current)) + " · " + TimeZone.current.identifier)
                                    .font(.callout)
                                Text(task.detail).font(.caption).foregroundStyle(LimaTheme.textSecondary)
                                DisclosureGroup("Instructions and start window") {
                                    Text(task.instructions).frame(maxWidth: .infinity, alignment: .leading)
                                    Text("Start no later than \(task.expiresAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: .current))). Scheduled timezone: \(task.timeZone).")
                                        .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                                }.font(.callout)
                                HStack {
                                    Button(task.state == .running ? "Open active task" : "Open conversation") {
                                        model.select(task.conversationID)
                                        if model.selectedConversationID == task.conversationID { dismiss() }
                                    }.disabled(model.canEndTask && model.selectedConversationID != task.conversationID)
                                    Spacer()
                                    if task.state == .scheduled || task.state == .running {
                                        Button("Cancel task", role: .destructive) { AIScheduledTaskRunner.shared.cancel(task.id) }
                                    } else {
                                        Button("Remove from list") {
                                            do { try store.remove(task.id) } catch { self.error = error.localizedDescription }
                                        }
                                    }
                                }
                            }.padding(14).background(LimaTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
                .frame(minHeight: 0, maxHeight: .infinity)
                .clipped()
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24).frame(minWidth: 600, idealWidth: 680, minHeight: 520, idealHeight: 680)
            .foregroundStyle(LimaTheme.textPrimary)
            .background(LimaTheme.windowBackground)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Task name", text: $title)
            Text("Instructions").font(.callout.weight(.semibold))
            TextEditor(text: $instructions).frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(LimaTheme.borderSubtle))
                .accessibilityLabel("Instructions, constraints, website, and desired outcome")
            Text("Include the website, exact date, party size, budget, and what Lima should do if unavailable.")
                .font(.caption).foregroundStyle(LimaTheme.textSecondary)
            Picker("Browser autonomy", selection: $browserMode) {
                ForEach(BrowserApprovalMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            Text("Payments and protected actions always pause for review. Include the exact website URLs when enabling unattended browsing.").font(.caption).foregroundStyle(LimaTheme.textSecondary)
            DatePicker("Start at", selection: $runAt, in: Date()...)
            Stepper("May start up to \(graceMinutes) minutes late", value: $graceMinutes, in: 1...1440)
            HStack {
                Text(TimeZone.current.identifier).font(.caption).foregroundStyle(LimaTheme.textSecondary)
                Spacer()
                Button("Save schedule") {
                    do {
                        guard let conversationID = model.selectedConversationID else { return }
                        _ = try store.create(conversationID: conversationID, title: title, instructions: instructions,
                            runAt: runAt, expiresAt: runAt.addingTimeInterval(Double(graceMinutes) * 60),
                            timeZone: TimeZone.current.identifier, autoApproveNonpayment: browserMode != .askForActions,
                            independentBrowser: browserMode == .independent)
                        creating = false; title = ""; instructions = ""; error = nil
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(14).background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
    }
}
