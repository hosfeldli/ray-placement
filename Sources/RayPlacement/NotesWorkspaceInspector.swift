import SwiftUI
import RayPlacementCore

enum NotesWorkspaceFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case today = "Today"
    case pinned = "Pinned"
    case favorites = "Favorites"
    var id: String { rawValue }

    func includes(_ note: MarkdownNote, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .all: true
        case .today: calendar.isDate(note.modifiedAt, inSameDayAs: now)
        case .pinned: note.isPinned
        case .favorites: note.isFavorite
        }
    }
}

private enum NotesInspectorTab: String, CaseIterable, Identifiable {
    case assistant = "AI Assistant"
    case context = "Context"
    case references = "References"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .assistant: "sparkles"
        case .context: "tray"
        case .references: "doc.text"
        }
    }
}

/// Note-local tools remain useful offline. AI actions prepare an attached draft;
/// they never submit the note or claim that an unrequested summary was generated.
struct NotesWorkspaceInspector: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var ai: AIChatViewModel
    let showOutline: () -> Void
    let showTasks: () -> Void
    let showTags: () -> Void
    let showHistory: () -> Void
    let appendClipboard: () -> Void
    let openAI: () -> Void
    @State private var tab: NotesInspectorTab = .assistant

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                tabBar
                if let note = store.selectedNote {
                    switch tab {
                    case .assistant: assistantPane(note)
                    case .context: contextPane(note)
                    case .references: referencesPane()
                    }
                }
            }
            .padding(12)
        }
        .background(LimaTheme.surfaceSecondary)
        .accessibilityIdentifier("lima-note-inspector")
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(NotesInspectorTab.allCases) { destination in
                Button {
                    tab = destination
                } label: {
                    Label(destination.rawValue, systemImage: destination.symbol)
                        .limaFont(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity, minHeight: 31)
                        .foregroundStyle(tab == destination ? LimaTheme.accentInk : LimaTheme.textSecondary)
                        .background(tab == destination ? LimaTheme.accentSoft : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == destination ? .isSelected : [])
            }
        }
        .padding(3)
        .background(LimaTheme.surfacePrimary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LimaTheme.borderSubtle, lineWidth: 0.6))
        .accessibilityLabel("Note inspector")
    }

    @ViewBuilder
    private func assistantPane(_ note: MarkdownNote) -> some View {
        LimaWorkspaceCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Label("At a glance", systemImage: "sparkles")
                        .limaFont(.callout.weight(.semibold))
                        .foregroundStyle(LimaTheme.accentInk)
                    Spacer(minLength: 4)
                    if ai.hasProviderAPIKey {
                        Button("Summarize") {
                            prepareAI(note, prompt: "Summarize the attached note clearly and concisely. Distinguish facts in the note from suggestions.")
                        }
                        .buttonStyle(.borderless)
                        .limaFont(.caption)
                        .disabled(ai.canEndTask)
                    }
                }
                Text(notePreview(note))
                    .limaFont(.system(size: 12))
                    .foregroundStyle(LimaTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Excerpt from this note · not an AI-generated summary")
                    .limaFont(.caption2)
                    .foregroundStyle(LimaTheme.textSecondary)
                if ai.hasProviderAPIKey {
                    HStack(spacing: 6) {
                        compactAIAction("Make shorter", symbol: "line.3.horizontal.decrease",
                                        prompt: "Make the attached note shorter while preserving its key facts.", note: note)
                        compactAIAction("Expand", symbol: "line.3.horizontal.increase",
                                        prompt: "Suggest a more detailed version of the attached note without inventing facts.", note: note)
                    }
                }
            }
        }
        .overlay(inspectorEdge)

        LimaWorkspaceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Action items", systemImage: "checkmark.square")
                        .limaFont(.callout.weight(.semibold))
                    Spacer(minLength: 4)
                    Button("View all", action: showTasks)
                        .buttonStyle(.borderless)
                        .limaFont(.caption)
                }
                let tasks = store.tasks(for: note.id)
                if tasks.isEmpty {
                    Text("No Markdown checklist items in this note.")
                        .limaFont(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                } else {
                    ForEach(tasks.prefix(7)) { task in
                        Button { _ = store.toggleTask(task) } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: task.checked ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(task.checked ? LimaTheme.accentInk : LimaTheme.textSecondary)
                                Text(task.text)
                                    .strikethrough(task.checked)
                                    .foregroundStyle(LimaTheme.textPrimary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .limaFont(.system(size: 11))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(task.checked ? "Mark incomplete" : "Mark complete"): \(task.text)")
                    }
                    if tasks.count > 7 {
                        Button("Show all \(tasks.count) items", action: showTasks)
                            .buttonStyle(.borderless)
                            .limaFont(.caption)
                    }
                }
            }
        }
        .overlay(inspectorEdge)

        if ai.hasProviderAPIKey {
            LimaWorkspaceCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Suggested next steps", systemImage: "arrow.right.circle")
                        .limaFont(.callout.weight(.semibold))
                    let openTasks = store.tasks(for: note.id).filter { !$0.checked }
                    if openTasks.isEmpty {
                        aiAction("Identify next steps", detail: "Prepare a draft grounded in this note",
                                 symbol: "sparkles", note: note,
                                 prompt: "Identify practical next steps supported by the attached note. Do not invent deadlines or owners.")
                    } else {
                        ForEach(openTasks.prefix(3)) { task in
                            aiAction(task.text, detail: "Plan this action in AI Chat",
                                     symbol: "arrow.up.right", note: note,
                                     prompt: "Help me plan this action from the attached note: \(task.text). Do not invent facts.")
                        }
                    }
                    Text("AI actions open an unsent draft with this note attached.")
                        .limaFont(.caption2)
                        .foregroundStyle(LimaTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .overlay(inspectorEdge)
        }

        LimaWorkspaceCard {
            VStack(alignment: .leading, spacing: 9) {
                Label("Note tools", systemImage: "slider.horizontal.3")
                    .limaFont(.callout.weight(.semibold))
                LimaWorkspaceActionRow(title: "Heading outline", detail: "Jump to a section", symbol: "list.bullet.indent", action: showOutline)
                LimaWorkspaceActionRow(title: "Task dashboard", detail: "Review all your checklists", symbol: "checklist", action: showTasks)
                LimaWorkspaceActionRow(title: "Append clipboard", detail: "Add copied text to this note", symbol: "doc.on.clipboard", action: appendClipboard)
                LimaWorkspaceActionRow(title: "Edit tags", detail: "Organize this note", symbol: "tag", action: showTags)
            }
        }
    }

    private func contextPane(_ note: MarkdownNote) -> some View {
        LimaWorkspaceCard {
            VStack(alignment: .leading, spacing: 13) {
                Label("Note context", systemImage: "info.circle")
                    .limaFont(.callout.weight(.semibold))
                Text(note.displayTitle).limaFont(.headline)
                LabeledContent("Words", value: note.content.split(whereSeparator: { $0.isWhitespace }).count.formatted())
                LabeledContent("Characters", value: note.content.count.formatted())
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last edited").foregroundStyle(LimaTheme.textSecondary)
                    Text(note.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                }
                .limaFont(.caption)
                LimaWorkspaceBadge(title: "Stored on this Mac", symbol: "lock")
                if !note.tags.isEmpty {
                    Text(note.tags.map { "#" + $0 }.joined(separator: "  "))
                        .limaFont(.caption)
                        .foregroundStyle(LimaTheme.accentInk)
                }
                Button(note.isPinned ? "Unpin note" : "Pin note", action: store.togglePin)
                    .buttonStyle(.bordered)
                Button(note.isFavorite ? "Remove favorite" : "Add to favorites", action: store.toggleFavorite)
                    .buttonStyle(.bordered)
                LimaWorkspaceActionRow(title: "Revision history", detail: "Review or restore a saved version",
                                       symbol: "clock.arrow.circlepath", action: showHistory)
                LimaWorkspaceActionRow(title: "Edit tags", detail: "Organize and find this note",
                                       symbol: "tag", action: showTags)
            }
        }
    }

    private func referencesPane() -> some View {
        let outgoing = store.referencedNotes()
        let incoming = store.backlinks().filter { backlink in
            !outgoing.contains { $0.id == backlink.id }
        }
        return LimaWorkspaceCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Referenced notes", systemImage: "link")
                    .limaFont(.callout.weight(.semibold))
                if outgoing.isEmpty && incoming.isEmpty {
                    Text("No linked notes yet. Add a wiki link in the editor to connect your work.")
                        .limaFont(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(outgoing) { linked in
                    LimaWorkspaceActionRow(title: linked.displayTitle, detail: "Referenced here", symbol: "doc.text") {
                        store.selectNote(linked.id)
                    }
                }
                ForEach(incoming) { linked in
                    LimaWorkspaceActionRow(title: linked.displayTitle, detail: "Links to this note", symbol: "arrow.turn.down.right", action: {
                        store.selectNote(linked.id)
                    })
                }
            }
        }
    }

    private var inspectorEdge: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(
                LinearGradient(colors: [LimaTheme.accentInk.opacity(0.75), LimaTheme.borderSubtle,
                                        LimaTheme.accentInk.opacity(0.4)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 0.8
            )
            .allowsHitTesting(false)
    }

    private func notePreview(_ note: MarkdownNote) -> String {
        let lines = String(note.content.prefix(4_000)).components(separatedBy: .newlines)
        let prose = lines.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { line in
                !line.isEmpty && !line.hasPrefix("#") && !line.hasPrefix("- [")
                    && !line.hasPrefix("- ") && !line.hasPrefix("* ") && !line.hasPrefix("|")
            }
        return prose.map { String($0.prefix(360)) } ?? "This note has no prose to preview yet."
    }

    private func prepareAI(_ note: MarkdownNote, prompt: String) {
        guard !ai.canEndTask, ai.prepareNoteDraft(note, prompt: prompt) else { return }
        openAI()
    }

    private func compactAIAction(_ title: String, symbol: String, prompt: String, note: MarkdownNote) -> some View {
        Button { prepareAI(note, prompt: prompt) } label: {
            Label(title, systemImage: symbol)
                .limaFont(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .disabled(ai.canEndTask)
    }

    private func aiAction(_ title: String, detail: String, symbol: String,
                          note: MarkdownNote, prompt: String) -> some View {
        LimaWorkspaceActionRow(title: title, detail: detail, symbol: symbol) {
            prepareAI(note, prompt: prompt)
        }
        .disabled(ai.canEndTask)
    }
}
