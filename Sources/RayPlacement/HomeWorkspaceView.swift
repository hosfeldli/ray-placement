import AppKit
import RayPlacementCore
import SwiftUI

struct HomeQuickAction: Identifiable {
    enum Destination {
        case workspace(LimaWorkspaceModule)
        case contextShelf
        case commandSearch(String)
    }

    let title: String
    let detail: String
    let symbol: String
    let tint: AppAccentTheme
    let destination: Destination
    var id: String { title }

    static let all: [HomeQuickAction] = [
        .init(title: "Open Notes", detail: "Create a note or find your next thought", symbol: "note.text", tint: .orange, destination: .workspace(.notes)),
        .init(title: "Dictation", detail: "Record speech and review local transcripts", symbol: "mic.fill", tint: .rose, destination: .workspace(.dictation)),
        .init(title: "Check Writing", detail: "Review spelling and grammar on this Mac", symbol: "textformat.abc", tint: .green, destination: .workspace(.grammar)),
        .init(title: "Ask AI", detail: "Write, analyze, and work with your context", symbol: "sparkles", tint: .violet, destination: .workspace(.ai)),
        .init(title: "Clipboard History", detail: "Find and reuse text you have copied", symbol: "clipboard", tint: .mint, destination: .workspace(.clipboard)),
        .init(title: "Manage Extensions", detail: "Configure the tools already on this Mac", symbol: "puzzlepiece.extension.fill", tint: .cyan, destination: .workspace(.extensions)),
        .init(title: "Generate Password", detail: "Create a strong, unique password", symbol: "lock.fill", tint: .rose, destination: .commandSearch("password")),
        .init(title: "Formatter", detail: "Format and inspect structured documents", symbol: "curlybraces", tint: .blue, destination: .workspace(.formatter)),
        .init(title: "Terminal", detail: "Open your persistent local shell", symbol: "terminal", tint: .graphite, destination: .workspace(.terminal)),
        .init(title: "Context Shelf", detail: "Carry snippets between your tools", symbol: "tray.full", tint: .violet, destination: .contextShelf)
    ]

    static func matching(_ query: String) -> [HomeQuickAction] {
        let terms = query.split(whereSeparator: { $0.isWhitespace })
        return all.filter { item in
            terms.allSatisfy { (item.title + " " + item.detail).localizedCaseInsensitiveContains(String($0)) }
        }
    }
}

/// Every item is an existing destination; there are no promotional or sample actions.
@MainActor
struct HomeWorkspaceView: View {
    @ObservedObject var store: NotesStore
    let open: (LimaWorkspaceModule) -> Void
    let openShelf: () -> Void
    let openCommandSearch: (String) -> Void

    @State private var query = ""
    @State private var selectedID = HomeQuickAction.all[0].id
    @State private var statusMessage: String?
    @FocusState private var searchFocused: Bool

    private var actions: [HomeQuickAction] {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Array(HomeQuickAction.all.prefix(6)) : HomeQuickAction.matching(query)
    }
    private var selectedAction: HomeQuickAction? { actions.first { $0.id == selectedID } ?? actions.first }
    private var matchingNotes: [MarkdownNote] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.notes.sorted { $0.modifiedAt > $1.modifiedAt }.filter {
            term.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(term)
                || $0.content.localizedCaseInsensitiveContains(term)
                || $0.tags.contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                LimaWorkspaceSearchField(placeholder: "Search notes, tools, or run a command…", text: $query, submit: openSelection)
                    .focused($searchFocused)
                    .onMoveCommand { direction in
                        if direction == .up { moveSelection(-1) }
                        if direction == .down { moveSelection(1) }
                    }
                    .padding(20)

                if proxy.size.width >= 740 {
                    HStack(alignment: .top, spacing: 18) {
                        actionList(showsInspector: true)
                        if let selectedAction {
                            ScrollView { actionInspector(selectedAction) }
                                .frame(width: min(310, proxy.size.width * 0.36))
                        }
                    }
                    .padding(.horizontal, 20)
                } else {
                    actionList(showsInspector: false).padding(.horizontal, 12)
                }

                if let message = statusMessage ?? store.lastError {
                    Text(message).limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                }
                HStack(spacing: 10) {
                    if proxy.size.width >= 500 {
                        Image(systemName: "arrow.up.arrow.down")
                        Text("Navigate")
                        Text("↩ Open")
                    }
                    Spacer()
                    Menu("Quick actions") {
                        Button("New note") { store.createNote(); open(.notes) }
                        Button("Capture clipboard", action: captureClipboard)
                        Button("Context Shelf", action: openShelf)
                    }.menuStyle(.borderlessButton).fixedSize()
                    Button("All commands") { openCommandSearch(query) }
                        .buttonStyle(.borderless)
                        .help("Open the full command and app catalog")
                        .fixedSize()
                }
                .limaFont(.caption)
                .foregroundStyle(LimaTheme.textSecondary)
                .padding(.horizontal, 22)
                .frame(height: 42)
                .background(LimaTheme.surfaceSecondary)
            }
            .background(LimaTheme.surfacePrimary)
        }
        .background {
            Button("") { searchFocused = true }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        }
        .onChange(of: query) { _ in selectedID = actions.first?.id ?? "" }
        .accessibilityIdentifier("lima-home-workspace")
    }

    private func actionList(showsInspector: Bool) -> some View {
        ScrollViewReader { scroll in
         ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(query.isEmpty ? "Suggested for you" : "Matching tools")
                    .limaFont(.callout.weight(.medium))
                    .foregroundStyle(LimaTheme.textSecondary)
                    .padding(.bottom, 5)

                ForEach(actions) { item in
                    HStack(spacing: 0) {
                        Button {
                            selectedID = item.id
                            if !showsInspector { perform(item) }
                        } label: {
                            HStack(spacing: 13) {
                                LimaFeatureIcon(symbol: item.symbol, tint: item.tint)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).limaFont(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(LimaTheme.textPrimary)
                                    Text(item.detail).limaFont(.callout)
                                        .foregroundStyle(LimaTheme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 4)
                            }
                            .padding(12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(selectedAction?.id == item.id ? "Selected" : "")
                        Button { perform(item) } label: {
                            Image(systemName: "arrow.turn.down.left").frame(width: 34, height: 34)
                        }
                        .buttonStyle(.bordered)
                        .help("Open \(item.title)")
                        .accessibilityLabel("Open \(item.title)")
                        .padding(.trailing, 12)
                    }
                    .background(selectedAction?.id == item.id ? LimaTheme.surfaceSelected : Color.clear,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .id(item.id)
                }

                if actions.isEmpty {
                    LimaWorkspaceActionRow(title: "Search all commands", detail: "No workspace tools match this search.", symbol: "magnifyingglass") {
                        openCommandSearch(query)
                    }
                }

                Divider().padding(.vertical, 12)
                HStack {
                    Text(query.isEmpty ? "Recent notes" : "Matching notes").limaFont(.callout.weight(.medium))
                    Spacer()
                    Button("See all") { open(.notes) }.buttonStyle(.borderless)
                }
                .foregroundStyle(LimaTheme.textSecondary)
                ForEach(matchingNotes.prefix(5)) { note in
                    LimaWorkspaceActionRow(title: note.displayTitle, detail: note.preview, symbol: note.isPinned ? "pin" : "doc.text") {
                        store.selectNote(note.id)
                        open(.notes)
                    }
                }
                if matchingNotes.isEmpty {
                    Text(query.isEmpty ? "Create your first local note to see it here." : "No matching notes.")
                        .limaFont(.callout).foregroundStyle(LimaTheme.textSecondary)
                        .padding(.vertical, 12)
                }
            }
            .padding(.bottom, 18)
         }
         .onChange(of: selectedID) { id in scroll.scrollTo(id) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func actionInspector(_ item: HomeQuickAction) -> some View {
        LimaWorkspaceCard {
            VStack(alignment: .leading, spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 25)
                        .fill(item.tint.primary.opacity(0.12))
                        .frame(width: 120, height: 100)
                        .rotationEffect(.degrees(-10))
                    LimaFeatureIcon(symbol: item.symbol, tint: item.tint, size: 86)
                        .rotationEffect(.degrees(5))
                }
                .frame(maxWidth: .infinity, minHeight: 142)
                Text(item.title).limaFont(.title2.weight(.semibold))
                Text(item.detail + ".")
                    .limaFont(.body).foregroundStyle(LimaTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { perform(item) } label: {
                    HStack { Text(item.title); Spacer(); Image(systemName: "arrow.right") }
                        .frame(minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .tint(LimaTheme.accentInk)
                Divider()
                Text("Quick actions").limaFont(.callout.weight(.semibold))
                LimaWorkspaceActionRow(title: "Create new note", detail: "Saved locally as you type", symbol: "plus") {
                    store.createNote()
                    open(.notes)
                }
                LimaWorkspaceActionRow(title: "Capture clipboard", detail: "Create a note from copied text", symbol: "doc.on.clipboard", action: captureClipboard)
                if let pinned = store.notes.first(where: \.isPinned) {
                    LimaWorkspaceActionRow(title: "Open pinned note", detail: pinned.displayTitle, symbol: "pin") {
                        store.selectNote(pinned.id)
                        open(.notes)
                    }
                }
                LimaWorkspaceActionRow(title: "Context Shelf", detail: "Review your saved snippets", symbol: "tray.full", action: openShelf)
                if let message = statusMessage ?? store.lastError {
                    Text(message).limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func perform(_ item: HomeQuickAction) {
        switch item.destination {
        case .workspace(let module): open(module)
        case .contextShelf: openShelf()
        case .commandSearch(let term): openCommandSearch(term)
        }
    }

    private func openSelection() {
        if let selectedAction { perform(selectedAction) }
        else if let note = matchingNotes.first { store.selectNote(note.id); open(.notes) }
        else { openCommandSearch(query) }
    }

    private func moveSelection(_ delta: Int) {
        guard !actions.isEmpty else { return }
        let current = actions.firstIndex { $0.id == selectedAction?.id } ?? 0
        selectedID = actions[min(max(current + delta, 0), actions.count - 1)].id
    }

    private func captureClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "The clipboard does not contain text."
            return
        }
        let previousID = store.selectedNoteID
        store.createQuickNote(with: text)
        if store.selectedNoteID != previousID { open(.notes) }
        else { statusMessage = store.lastError }
    }
}
