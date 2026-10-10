import RayPlacementCore
import SwiftUI

/// Home is a continuation surface, not a second search or command catalog.
struct HomeRecentItem: Identifiable {
    enum Destination: Equatable {
        case note(UUID)
        case conversation(UUID)
    }

    let destination: Destination
    let title: String
    let preview: String
    let updatedAt: Date

    var id: String {
        switch destination {
        case .note(let id): return "note-\(id.uuidString)"
        case .conversation(let id): return "conversation-\(id.uuidString)"
        }
    }

    var kindTitle: String {
        switch destination {
        case .note: return "Note"
        case .conversation: return "AI conversation"
        }
    }

    var symbol: String {
        switch destination {
        case .note: return "note.text"
        case .conversation: return "sparkles"
        }
    }

    static func sorted(notes: [MarkdownNote], conversations: [AIConversation]) -> [Self] {
        let noteItems = notes.map {
            Self(destination: .note($0.id), title: $0.displayTitle, preview: $0.preview, updatedAt: $0.modifiedAt)
        }
        // A newly created, empty chat is not work to resume.
        let conversationItems = conversations.filter { !$0.messages.isEmpty }.map {
            Self(destination: .conversation($0.id), title: $0.title, preview: $0.preview, updatedAt: $0.updatedAt)
        }
        return (noteItems + conversationItems).sorted {
            if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
            return $0.updatedAt > $1.updatedAt
        }
    }
}

@MainActor
struct HomeWorkspaceView: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var conversations: AIConversationStore
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var taskRegistry = TaskRegistry.shared
    let open: (LimaWorkspaceModule) -> Void
    let openConversation: (UUID) -> Void
    let startNoteDictation: () -> Void
    let openCommandSearch: (String) -> Void

    private var recent: [HomeRecentItem] {
        HomeRecentItem.sorted(notes: store.notes, conversations: conversations.conversations)
    }

    private var pinnedNotes: [MarkdownNote] {
        Array(store.notes.filter(\.isPinned).sorted { $0.modifiedAt > $1.modifiedAt }.prefix(3))
    }

    private var home: HomeWorkspaceConfiguration { settings.workspaceConfiguration.home }
    private var recentSectionItems: [HomeRecentItem] {
        let eligible = recent.filter {
            switch $0.destination {
            case .note: home.showsRecentNotes
            case .conversation: home.showsRecentAI
            }
        }
        guard home.isVisible(.continueWork), let first = recent.first else { return eligible }
        return eligible.filter { $0.id != first.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                LimaWorkspaceHeading(
                    title: "Home",
                    subtitle: "Pick up where you left off.",
                    symbol: "house",
                    tint: .blue
                )

                ForEach(home.sectionOrder.filter { home.isVisible($0) }) { section in
                    homeSection(section)
                }

                if let error = store.lastError {
                    Text(error).limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
                }

                Button("Search everything") { openCommandSearch("") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(LimaTheme.textSecondary)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .background(Color.clear)
        .accessibilityIdentifier("lima-home-workspace")
    }

    @ViewBuilder
    private func homeSection(_ section: HomeWorkspaceSection) -> some View {
        switch section {
        case .continueWork:
            if let first = recent.first {
                sectionTitle("Continue")
                LimaWorkspaceCard { recentRow(first) }
            } else {
                LimaWorkspaceCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Nothing to resume yet").limaFont(.headline)
                            .foregroundStyle(LimaTheme.textPrimary)
                        Text("Your recent notes and AI conversations will appear here as you work.")
                            .limaFont(.callout).foregroundStyle(LimaTheme.textSecondary)
                        Button("Create a note") { createNote() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        case .recent:
            if !recentSectionItems.isEmpty {
                sectionTitle("Recent")
                LimaWorkspaceCard {
                    VStack(spacing: 6) {
                        ForEach(Array(recentSectionItems.prefix(5))) { item in recentRow(item) }
                    }
                }
            }
        case .quickActions:
            sectionTitle("Quick actions")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                quickAction("New note", symbol: "plus", action: createNote)
                quickAction("Dictate a note", symbol: "waveform", action: startNoteDictation)
                quickAction("Ask Lima", symbol: "sparkles") { open(.ai) }
            }
        case .pinned:
            if !pinnedNotes.isEmpty {
                sectionTitle("Pinned")
                LimaWorkspaceCard {
                    VStack(spacing: 6) {
                        ForEach(pinnedNotes) { note in
                            LimaWorkspaceActionRow(
                                title: note.displayTitle,
                                detail: note.preview,
                                symbol: "pin"
                            ) {
                                store.selectNote(note.id)
                                open(.notes)
                            }
                        }
                    }
                }
            }
        case .activeTasks:
            sectionTitle("Active tasks")
            LimaWorkspaceCard {
                if taskRegistry.activeTasks.isEmpty {
                    Text("No active tasks").limaFont(.callout)
                        .foregroundStyle(LimaTheme.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(taskRegistry.activeTasks.prefix(5))) { task in
                            HStack(spacing: 10) {
                                Image(systemName: task.kind.symbol)
                                    .foregroundStyle(LimaTheme.textSecondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(task.title).limaFont(.callout.weight(.medium))
                                    Text(task.detail ?? task.kind.title).limaFont(.caption)
                                        .foregroundStyle(LimaTheme.textSecondary)
                                }
                                Spacer(minLength: 8)
                                if task.isCancellable {
                                    Button("Stop") { taskRegistry.cancel(task.id) }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .limaFont(.callout.weight(.semibold))
            .foregroundStyle(LimaTheme.textSecondary)
    }

    private func recentRow(_ item: HomeRecentItem) -> some View {
        LimaWorkspaceActionRow(
            title: item.title,
            detail: "\(item.kindTitle) · \(recency(for: item.updatedAt)) · \(item.preview)",
            symbol: item.symbol
        ) {
            switch item.destination {
            case .note(let id):
                store.selectNote(id)
                open(.notes)
            case .conversation(let id):
                openConversation(id)
            }
        }
    }

    private func recency(for date: Date) -> String {
        let now = Date()
        if now.timeIntervalSince(date) < 60 { return "just now" }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
    }

    private func quickAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .limaFont(.callout.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.bordered)
    }

    private func createNote() {
        let previousID = store.selectedNoteID
        store.createNote()
        if store.selectedNoteID != previousID {
            open(.notes)
        }
    }
}
