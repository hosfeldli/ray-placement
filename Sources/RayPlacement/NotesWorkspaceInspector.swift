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

/// Local actions stay available without accounts. AI actions only prepare a
/// visible draft with a note snapshot; they never send text in the background.
struct NotesWorkspaceInspector: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var ai: AIChatViewModel
    let showOutline: () -> Void
    let showTasks: () -> Void
    let showTags: () -> Void
    let showHistory: () -> Void
    let appendClipboard: () -> Void
    let openAI: () -> Void
    @State private var tab = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Note inspector", selection: $tab) {
                    Text("Actions").tag(0)
                    Text("Info").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if let note = store.selectedNote {
                    if tab == 0 {
                        LimaWorkspaceCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("Work with this note", systemImage: "sparkles")
                                    .limaFont(.callout.weight(.semibold))
                                LimaWorkspaceActionRow(title: "Heading outline", detail: "Jump to a section", symbol: "list.bullet.indent", action: showOutline)
                                LimaWorkspaceActionRow(title: "Task dashboard", detail: "Review checklists across your notes", symbol: "checklist", action: showTasks)
                                LimaWorkspaceActionRow(title: "Append clipboard", detail: "Add copied text to this note", symbol: "doc.on.clipboard", action: appendClipboard)
                                LimaWorkspaceActionRow(title: "Edit tags", detail: "Organize and find this note", symbol: "tag", action: showTags)
                            }
                        }
                        if ai.hasProviderAPIKey {
                            LimaWorkspaceCard {
                                VStack(alignment: .leading, spacing: 10) {
                                    Label("Ask about this note", systemImage: "sparkles")
                                        .limaFont(.callout.weight(.semibold))
                                    aiAction("Summarize", detail: "Prepare a concise overview", symbol: "text.alignleft",
                                             prompt: "Summarize the attached note clearly and concisely.")
                                    aiAction("Extract tasks", detail: "Find action items and next steps", symbol: "checklist",
                                             prompt: "Extract the action items from the attached note as a Markdown checklist. Do not invent owners or dates.")
                                    aiAction("Improve writing", detail: "Review a clearer version in AI Chat", symbol: "wand.and.stars",
                                             prompt: "Improve the clarity of the attached note while preserving its meaning.")
                                    Text("Opens a draft in AI Chat. Nothing is sent until you press Send.")
                                        .limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        let related = store.referencedNotes() + store.backlinks().filter { backlink in
                            !store.referencedNotes().contains { $0.id == backlink.id }
                        }
                        if !related.isEmpty {
                            LimaWorkspaceCard {
                                VStack(alignment: .leading, spacing: 9) {
                                    Label("Related notes", systemImage: "link").limaFont(.callout.weight(.semibold))
                                    ForEach(related) { linked in
                                        LimaWorkspaceActionRow(title: linked.displayTitle, detail: "", symbol: "doc.text") {
                                            store.selectNote(linked.id)
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        LimaWorkspaceCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Label("Note information", systemImage: "info.circle").limaFont(.callout.weight(.semibold))
                                Text(note.displayTitle).limaFont(.headline)
                                LabeledContent("Words", value: note.content.split(whereSeparator: { $0.isWhitespace }).count.formatted())
                                LabeledContent("Characters", value: note.content.count.formatted())
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Last edited").foregroundStyle(LimaTheme.textSecondary)
                                    Text(note.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                                }
                                .limaFont(.caption)
                                LimaWorkspaceBadge(title: "Stored on this Mac", symbol: "lock")
                                Button(note.isPinned ? "Unpin note" : "Pin note", action: store.togglePin)
                                    .buttonStyle(.bordered)
                                Button(note.isFavorite ? "Remove favorite" : "Add to favorites", action: store.toggleFavorite)
                                    .buttonStyle(.bordered)
                                LimaWorkspaceActionRow(title: "Revision history", detail: "Review or restore a saved version", symbol: "clock.arrow.circlepath", action: showHistory)
                                if !note.tags.isEmpty {
                                    Text(note.tags.map { "#" + $0 }.joined(separator: "  "))
                                        .limaFont(.caption).foregroundStyle(LimaTheme.accentInk)
                                }
                                Button("Edit tags", action: showTags).buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
        .background(LimaTheme.surfaceSecondary)
        .accessibilityIdentifier("lima-note-inspector")
    }

    private func aiAction(_ title: String, detail: String, symbol: String, prompt: String) -> some View {
        LimaWorkspaceActionRow(title: title, detail: detail, symbol: symbol) {
            guard let note = store.selectedNote, ai.prepareNoteDraft(note, prompt: prompt) else { return }
            openAI()
        }
        .disabled(ai.canEndTask)
    }
}
