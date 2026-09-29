import RayPlacementCore
import SwiftUI

private struct HomeQuickAction: Identifiable {
    enum Destination {
        case workspace(LimaWorkspaceModule)
        case contextShelf
        case commandSearch(String)
    }

    let title: String
    let detail: String
    let symbol: String
    let destination: Destination

    var id: String { title }
}

/// A local-first landing page: every tile opens an existing Lima workspace or service.
@MainActor
struct HomeWorkspaceView: View {
    @ObservedObject var store: NotesStore
    let open: (LimaWorkspaceModule) -> Void
    let openShelf: () -> Void
    let openCommandSearch: (String) -> Void

    @State private var query = ""

    private var searchTerm: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var quickActions: [HomeQuickAction] {
        [
            HomeQuickAction(title: "Notes", detail: "Create and organize local notes", symbol: "note.text", destination: .workspace(.notes)),
            HomeQuickAction(title: "AI Chat", detail: "Ask, draft, or analyze", symbol: "sparkles", destination: .workspace(.ai)),
            HomeQuickAction(title: "Grammar", detail: "Check writing locally on this Mac", symbol: "textformat.abc", destination: .workspace(.grammar)),
            HomeQuickAction(title: "Dictation", detail: "Record or review transcripts", symbol: "waveform", destination: .workspace(.dictation)),
            HomeQuickAction(title: "Extensions", detail: "Manage installed tools", symbol: "puzzlepiece.extension", destination: .workspace(.extensions)),
            HomeQuickAction(title: "Clipboard", detail: "Search copied text on this Mac", symbol: "clipboard", destination: .workspace(.clipboard)),
            HomeQuickAction(title: "Formatter", detail: "Format and inspect documents", symbol: "wand.and.stars", destination: .workspace(.formatter)),
            HomeQuickAction(title: "Terminal", detail: "Open your persistent shell", symbol: "terminal", destination: .workspace(.terminal)),
            HomeQuickAction(title: "Context Shelf", detail: "Carry snippets between tools", symbol: "tray.full", destination: .contextShelf),
            HomeQuickAction(title: "Generate Password", detail: "Create a secure password", symbol: "lock.fill", destination: .commandSearch("password"))
        ]
    }

    private var matchingActions: [HomeQuickAction] {
        guard !searchTerm.isEmpty else { return quickActions }
        return quickActions.filter {
            $0.title.localizedCaseInsensitiveContains(searchTerm)
                || $0.detail.localizedCaseInsensitiveContains(searchTerm)
        }
    }

    private var matchingNotes: [MarkdownNote] {
        let term = searchTerm
        return store.notes
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .filter { note in
                term.isEmpty
                    || note.displayTitle.localizedCaseInsensitiveContains(term)
                    || note.content.localizedCaseInsensitiveContains(term)
                    || note.tags.contains { $0.localizedCaseInsensitiveContains(term) }
            }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    LimaWayfinderMark()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Your workspace")
                            .limaFont(.title2.weight(.semibold))
                            .foregroundStyle(LimaTheme.textPrimary)
                        Text("Find a note or jump straight into a Lima tool.")
                            .limaFont(.callout)
                            .foregroundStyle(LimaTheme.textSecondary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        store.createNote()
                        open(.notes)
                    } label: {
                        Label("New Note", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LimaTheme.accentInk)
                    .help("Create a local note and open it")
                }

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(LimaTheme.textSecondary)
                    TextField("Search notes, tools, or commands…", text: $query)
                        .textFieldStyle(.plain)
                        .limaFont(.body)
                        .onSubmit { openCommandSearch(searchTerm) }
                        .accessibilityLabel("Search Lima")
                        .accessibilityHint("Press Return to search Lima commands and applications")
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(LimaTheme.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                    }
                    Button {
                        openCommandSearch(searchTerm)
                    } label: {
                        Image(systemName: "arrow.turn.down.left")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(LimaTheme.accentInk)
                    .help("Search all Lima commands and apps")
                    .accessibilityLabel("Search all Lima commands and apps")
                }
                .padding(.horizontal, 13)
                .frame(height: 42)
                .background(LimaTheme.fieldBackground, in: RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous).stroke(LimaTheme.borderSubtle, lineWidth: LimaDesign.hairlineWidth))

                VStack(alignment: .leading, spacing: 10) {
                    LimaSectionLabel(searchTerm.isEmpty ? "QUICK ACCESS" : "MATCHING TOOLS", detail: "\(matchingActions.count) destinations")
                    if matchingActions.isEmpty {
                        Text("No matching tools. Press Return to search every Lima command and app.")
                            .limaFont(.caption)
                            .foregroundStyle(LimaTheme.textSecondary)
                            .padding(.vertical, 8)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], alignment: .leading, spacing: 10) {
                            ForEach(matchingActions) { item in
                                actionCard(item.title, detail: item.detail, symbol: item.symbol) {
                                    perform(item)
                                }
                            }
                        }
                    }
                }

                if searchTerm.isEmpty || !matchingNotes.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            LimaSectionLabel(searchTerm.isEmpty ? "RECENT NOTES" : "MATCHING NOTES", detail: "\(matchingNotes.count) local")
                            Spacer()
                            Button("See all") { open(.notes) }
                                .buttonStyle(.borderless)
                                .disabled(store.notes.isEmpty)
                        }
                        if matchingNotes.isEmpty {
                            VStack(spacing: 7) {
                                Image(systemName: "note.text")
                                    .font(.system(size: 19, weight: .medium))
                                    .foregroundStyle(LimaTheme.textTertiary)
                                Text("No notes yet")
                                    .limaFont(.callout.weight(.semibold))
                                    .foregroundStyle(LimaTheme.textPrimary)
                                Text("Create a note to start your local workspace.")
                                    .limaFont(.caption)
                                    .foregroundStyle(LimaTheme.textSecondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 120)
                            .background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: LimaRadius.card, style: .continuous))
                        } else {
                            ForEach(matchingNotes.prefix(6)) { note in
                                Button {
                                    store.selectNote(note.id)
                                    open(.notes)
                                } label: {
                                    HStack(spacing: 11) {
                                        Image(systemName: note.isPinned ? "pin.fill" : "note.text")
                                            .foregroundStyle(LimaTheme.accentInk)
                                            .frame(width: 26)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(note.displayTitle)
                                                .limaFont(.body.weight(.medium))
                                                .foregroundStyle(LimaTheme.textPrimary)
                                                .lineLimit(1)
                                            Text(note.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(110))
                                                .limaFont(.caption)
                                                .foregroundStyle(LimaTheme.textSecondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Text(note.modifiedAt, style: .relative)
                                            .limaFont(.caption2)
                                            .foregroundStyle(LimaTheme.textTertiary)
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(LimaTheme.textTertiary)
                                    }
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 50)
                                    .background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous))
                                    .contentShape(RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Open this note in Notes")
                            }
                        }
                    }
                }

                if !searchTerm.isEmpty && matchingActions.isEmpty && matchingNotes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No local matches")
                            .limaFont(.callout.weight(.semibold))
                            .foregroundStyle(LimaTheme.textPrimary)
                        Text("Search Lima’s full command and app catalog instead.")
                            .limaFont(.caption)
                            .foregroundStyle(LimaTheme.textSecondary)
                        Button("Search all commands") { openCommandSearch(searchTerm) }
                            .buttonStyle(.borderedProminent)
                            .tint(LimaTheme.accentInk)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: LimaRadius.card, style: .continuous))
                }
            }
            .padding(20)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(LimaTheme.surfacePrimary)
        .accessibilityIdentifier("lima-home-workspace")
    }

    private func perform(_ item: HomeQuickAction) {
        switch item.destination {
        case .workspace(let module):
            open(module)
        case .contextShelf:
            openShelf()
        case .commandSearch(let term):
            openCommandSearch(term)
        }
    }

    private func actionCard(
        _ title: String,
        detail: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LimaTheme.accentInk)
                    .frame(width: 34, height: 34)
                    .background(LimaTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .limaFont(.callout.weight(.semibold))
                        .foregroundStyle(LimaTheme.textPrimary)
                    Text(detail)
                        .limaFont(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LimaTheme.textTertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(LimaTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: LimaRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LimaRadius.card, style: .continuous).stroke(LimaTheme.borderSubtle, lineWidth: LimaDesign.hairlineWidth))
            .contentShape(RoundedRectangle(cornerRadius: LimaRadius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Open \\(title)")
    }
}
