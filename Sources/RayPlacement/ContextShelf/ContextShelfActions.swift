import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum ContextShelfMarkdownFormatter {
    static func format(_ item: ContextShelfItem) -> String {
        let source = item.source.applicationName ?? sourceTitle(for: item.source.type)
        switch item.payload {
        case .text(let text):
            if item.kind == .selectedText {
                return "> Selected from \(source)\n\n\(text)"
            }
            return text
        case .terminal(let command, let output):
            let heading = command.map { "### Terminal — `\($0)`" } ?? "### Terminal"
            return "\(heading)\n\n```text\n\(output)\n```"
        case .file(let path, _):
            return "`\(path)`"
        case .note(_, let title):
            return "[[\(title)]]"
        case .dictation(let transcript):
            return "### Dictation\n\n\(transcript)"
        }
    }

    static func format(_ items: [ContextShelfItem]) -> String {
        items.map(format).joined(separator: "\n\n")
    }

    static func plainText(_ item: ContextShelfItem) -> String {
        switch item.payload {
        case .text(let text): return text
        case .terminal(_, let output): return output
        case .file(let path, _): return path
        case .note(_, let title): return title
        case .dictation(let transcript): return transcript
        }
    }

    static func previewSource(for item: ContextShelfItem) -> String {
        item.source.applicationName
            ?? item.source.commandID
            ?? item.source.extensionID
            ?? sourceTitle(for: item.source.type)
    }

    static func relativeTime(for date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }

    private static func sourceTitle(for type: ContextShelfSource.SourceType) -> String {
        switch type {
        case .application: return "Application"
        case .clipboard: return "Clipboard"
        case .terminal: return "Terminal"
        case .file: return "File"
        case .dictation: return "Dictation"
        case .extensionOutput: return "Extension"
        case .note: return "Note"
        case .lima: return "Lima"
        case .unknown: return "Unknown source"
        }
    }
}

enum ShelfActionResult: Equatable {
    case selected
    case copied
    case removed
    case pinned
    case appended
    case createdNote
}

struct ShelfActionDescriptor {
    let id: String
    let title: String
    let icon: String
    let supportedKinds: Set<ContextShelfItemKind>
    let allowsMultipleItems: Bool
    let handler: @MainActor ([ContextShelfItem]) async throws -> ShelfActionResult

    func supports(_ items: [ContextShelfItem]) -> Bool {
        !items.isEmpty
            && items.allSatisfy { supportedKinds.contains($0.kind) }
            && (allowsMultipleItems || items.count == 1)
    }
}

@MainActor
final class ContextShelfActionRegistry {
    static let shared = ContextShelfActionRegistry()

    private(set) var descriptors: [ShelfActionDescriptor] = []
    private var contextDescriptors: [ShelfActionDescriptor] = []

    init(registerDefaults: Bool = true) {
        if registerDefaults { registerDefaultActions() }
    }

    func register(_ descriptor: ShelfActionDescriptor) {
        descriptors.removeAll { $0.id == descriptor.id }
        descriptors.append(descriptor)
    }

    func actions(for items: [ContextShelfItem]) -> [ShelfActionDescriptor] {
        (descriptors + contextDescriptors).filter { $0.supports(items) }
    }

    func registerContextAction(_ descriptor: ShelfActionDescriptor) {
        contextDescriptors.removeAll { $0.id == descriptor.id }
        contextDescriptors.append(descriptor)
    }

    private func registerDefaultActions() {
        let allKinds = Set(ContextShelfItemKind.allCases)

        register(ShelfActionDescriptor(
            id: "copy",
            title: "Copy",
            icon: "doc.on.doc",
            supportedKinds: allKinds,
            allowsMultipleItems: true,
            handler: { items in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(items.map(ContextShelfMarkdownFormatter.plainText).joined(separator: "\n\n"), forType: .string)
                return .copied
            }
        ))
        register(ShelfActionDescriptor(
            id: "copy-markdown",
            title: "Copy as Markdown",
            icon: "text.badge.checkmark",
            supportedKinds: allKinds,
            allowsMultipleItems: true,
            handler: { items in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ContextShelfMarkdownFormatter.format(items), forType: .string)
                return .copied
            }
        ))
        register(ShelfActionDescriptor(
            id: "append-quick-note",
            title: "Append to Quick Note",
            icon: "note.text.badge.plus",
            supportedKinds: allKinds,
            allowsMultipleItems: true,
            handler: { items in
                guard NotesStore.shared.appendShelfItemsToQuickNote(items) != nil else {
                    throw NSError(domain: "ContextShelf", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose or create a Quick Note before appending Shelf items."])
                }
                return .appended
            }
        ))
        register(ShelfActionDescriptor(
            id: "send-to-note",
            title: "Send to Note…",
            icon: "square.and.pencil",
            supportedKinds: allKinds,
            allowsMultipleItems: true,
            handler: { items in
                NotesStore.shared.createNoteFromShelf(items)
                return .createdNote
            }
        ))
        register(ShelfActionDescriptor(
            id: "pin",
            title: "Pin",
            icon: "pin",
            supportedKinds: allKinds,
            allowsMultipleItems: true,
            handler: { items in
                let store = ContextShelfStore.shared
                for item in items where !item.isPinned { store.togglePinned(id: item.id) }
                return .pinned
            }
        ))
        register(ShelfActionDescriptor(
            id: "remove",
            title: "Remove",
            icon: "trash",
            supportedKinds: allKinds,
            allowsMultipleItems: true,
            handler: { items in
                ContextShelfStore.shared.remove(items: items)
                return .removed
            }
        ))
        register(ShelfActionDescriptor(
            id: "undo-remove",
            title: "Undo Remove",
            icon: "arrow.uturn.backward",
            supportedKinds: allKinds,
            allowsMultipleItems: true,
            handler: { _ in ContextShelfStore.shared.undoLastRemove(); return .removed }
        ))
        register(ShelfActionDescriptor(
            id: "undo-clear",
            title: "Undo Clear",
            icon: "arrow.uturn.backward.circle",
            supportedKinds: allKinds,
            allowsMultipleItems: true,
            handler: { _ in ContextShelfStore.shared.undoClear(); return .removed }
        ))
    }
}

@MainActor
struct ContextShelfView: View {
    @ObservedObject var store: ContextShelfStore
    @State private var activeID: UUID?
    @State private var errorMessage: String?
    @State private var detailItem: ContextShelfItem?
    @Binding var searchQuery: String
    @State private var compareItems: [ContextShelfItem] = []
    @State private var destinationMode: DestinationMode?

    init(store: ContextShelfStore, searchQuery: Binding<String> = .constant("")) {
        self.store = store
        self._searchQuery = searchQuery
    }

    fileprivate enum DestinationMode: Identifiable {
        case append, create
        var id: String { self == .append ? "append" : "create" }
        var title: String { self == .append ? "Append Shelf Items" : "Send Shelf Items to Note" }
    }

    private var activeItem: ContextShelfItem? {
        if let activeID, let item = store.items.first(where: { $0.id == activeID }) { return item }
        return store.items.first
    }

    private var visibleItems: [ContextShelfItem] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return store.items }
        return store.items.filter { item in
            [item.title, item.preview, item.source.applicationName ?? "", item.source.commandID ?? ""]
                .joined(separator: " ").lowercased().contains(query)
        }
    }

    private var pinnedItems: [ContextShelfItem] {
        visibleItems.filter(\.isPinned)
    }

    private var recentItems: [ContextShelfItem] {
        visibleItems.filter { !$0.isPinned }
    }

    private var actionItems: [ContextShelfItem] {
        let selected = store.selectedItems
        return selected.isEmpty ? (activeItem.map { [$0] } ?? []) : selected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            LimaWorkspaceSearchField(placeholder: "Search context…", text: $searchQuery)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .limaFont(.caption)
                    .foregroundStyle(LimaTheme.warning)
            }

            if store.items.isEmpty {
                emptyState
            } else if visibleItems.isEmpty {
                searchEmptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if !pinnedItems.isEmpty {
                            sectionHeader("PINNED")
                            ForEach(pinnedItems) { item in
                                shelfRow(item)
                            }
                        }
                        if !recentItems.isEmpty {
                            sectionHeader("RECENT")
                            ForEach(recentItems) { item in
                                shelfRow(item)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.automatic)
            }

            if store.selectedCount > 0 {
                selectionActionBar
            }
        }
        .padding(16)
        .background(LimaTheme.surfacePrimary)
        .overlay(alignment: .topLeading) {
            ContextShelfKeyboardHandler { command in
                handle(command)
            }
            .frame(width: 1, height: 1)
            .opacity(0.01)
        }
        .onAppear {
            activeID = activeID ?? store.items.first?.id
        }
        .onChange(of: store.items.map { $0.id }) { ids in
            if let activeID, ids.contains(activeID) { return }
            activeID = ids.first
        }
        .sheet(item: $detailItem) { item in
            ContextShelfDetailView(item: item)
        }
        .sheet(item: $destinationMode) { mode in
            ContextShelfDestinationView(mode: mode, items: actionItems, store: store) {
                destinationMode = nil
            }
        }
        .sheet(isPresented: Binding(get: { !compareItems.isEmpty }, set: { if !$0 { compareItems = [] } })) {
            ContextShelfComparisonView(items: compareItems)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            LimaWorkspaceBadge(
                title: store.selectedCount > 0
                    ? "\(store.selectedCount) selected"
                    : "\(store.count) item\(store.count == 1 ? "" : "s")",
                symbol: store.selectedCount > 0 ? "checkmark.circle.fill" : "tray.full"
            )
            Spacer()
            Menu {
                let actions = ContextShelfActionRegistry.shared.actions(for: actionItems)
                if actions.isEmpty {
                    Text("Select an item")
                } else {
                    ForEach(actions.filter { !["append-quick-note", "send-to-note", "undo-remove", "undo-clear"].contains($0.id) }, id: \.id) { descriptor in
                        Button { run(descriptor) } label: { Label(descriptor.title, systemImage: descriptor.icon) }
                    }
                    Divider()
                    Button { destinationMode = .append } label: { Label("Append to Note…", systemImage: "note.text.badge.plus") }
                    Button { destinationMode = .create } label: { Label("Send to Note…", systemImage: "square.and.pencil") }
                    if actionItems.count == 2 {
                        Button { compareItems = actionItems } label: { Label("Compare Selected Items", systemImage: "rectangle.split.2x1") }
                    }
                }
                Divider()
                Button("Select All") { store.selectAll() }
                Button("Clear Selection") { store.selectedIDs.removeAll() }
                Button("Undo Remove") { store.undoLastRemove() }.disabled(store.lastRemoved.isEmpty)
                Button("Undo Clear") { store.undoClear() }.disabled(store.lastCleared.isEmpty)
                Button("Clear Unpinned", role: .destructive) { store.clear() }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .help("Context actions and shelf management")
            .accessibilityLabel("Context actions")
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .limaFont(.system(size: 9, weight: .bold))
            .tracking(1)
            .foregroundStyle(LimaTheme.textTertiary)
            .padding(.horizontal, 10)
            .padding(.top, 6)
    }

    private var selectionActionBar: some View {
        HStack(spacing: 8) {
            Text("\(store.selectedCount) selected")
                .limaFont(.caption.weight(.medium))
                .foregroundStyle(LimaTheme.textSecondary)
            Spacer(minLength: 0)
            Button {
                destinationMode = .append
            } label: {
                Label("Add to Note", systemImage: "note.text.badge.plus")
            }
            .buttonStyle(.bordered)
            Menu {
                ForEach(ContextShelfActionRegistry.shared.actions(for: store.selectedItems)
                    .filter { !["append-quick-note", "send-to-note", "undo-remove", "undo-clear"].contains($0.id) }, id: \.id) { descriptor in
                    Button { run(descriptor, items: store.selectedItems) } label: {
                        Label(descriptor.title, systemImage: descriptor.icon)
                    }
                }
                if store.selectedCount == 2 {
                    Divider()
                    Button {
                        compareItems = store.selectedItems
                    } label: {
                        Label("Compare Selected Items", systemImage: "rectangle.split.2x1")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(10)
        .background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous)
                .strokeBorder(LimaTheme.borderSubtle, lineWidth: LimaDesign.hairlineWidth)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            LimaFeatureIcon(symbol: "tray", tint: .violet, size: 42)
            Text("No context yet").limaFont(.headline)
                .foregroundStyle(LimaTheme.textPrimary)
            Text("Capture highlighted text, terminal output, or a result to keep it close to this work.")
                .limaFont(.caption)
                .foregroundStyle(LimaTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(16)
        .background(LimaTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous))
    }

    private var searchEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(LimaTheme.textSecondary)
            Text("No matching context").limaFont(.callout.weight(.semibold))
                .foregroundStyle(LimaTheme.textPrimary)
            Text("Try another phrase or clear the search.")
                .limaFont(.caption)
                .foregroundStyle(LimaTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    private func shelfRow(_ item: ContextShelfItem) -> some View {
        let isActive = activeID == item.id
        let isSelected = store.selectedIDs.contains(item.id)
        return HStack(alignment: .top, spacing: 8) {
            Button {
                store.toggleSelection(id: item.id)
                activeID = item.id
            } label: {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? LimaTheme.accentInk : LimaTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Select for a batch action")

            Image(systemName: icon(for: item.kind))
                .frame(width: 18)
                .foregroundStyle(LimaTheme.textSecondary)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(item.title)
                        .limaFont(.callout.weight(.medium))
                        .foregroundStyle(LimaTheme.textPrimary)
                        .lineLimit(1)
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(LimaTheme.textSecondary)
                    }
                    Spacer(minLength: 4)
                    Text(ContextShelfMarkdownFormatter.relativeTime(for: item.createdAt))
                        .limaFont(.caption2)
                        .foregroundStyle(LimaTheme.textTertiary)
                }
                Text(ContextShelfMarkdownFormatter.previewSource(for: item))
                    .limaFont(.caption2)
                    .foregroundStyle(LimaTheme.textSecondary)
                    .lineLimit(1)
                Text(item.preview)
                    .limaFont(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            isActive ? LimaTheme.surfaceSelected : LimaTheme.surfaceRaised,
            in: RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous)
                .stroke(isActive ? LimaTheme.borderStrong : LimaTheme.borderSubtle, lineWidth: LimaDesign.hairlineWidth)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            activeID = item.id
        }
        .onDrag {
            let provider = NSItemProvider()
            let typeIdentifier = ContextShelfIntegration.itemUTType.identifier
            provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .all) { completion in
                completion(Data(item.id.uuidString.utf8), nil)
                return nil
            }
            return provider
        }
        .contextMenu {
            Button("Inspect") { detailItem = item }
            ForEach(ContextShelfActionRegistry.shared.actions(for: [item]), id: \.id) { descriptor in
                Button(descriptor.title) { run(descriptor, items: [item]) }
            }
        }
    }

    private func run(_ descriptor: ShelfActionDescriptor, items: [ContextShelfItem]? = nil) {
        let items = items ?? actionItems
        Task { @MainActor in
            do {
                _ = try await descriptor.handler(items)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handle(_ command: ContextShelfKeyboardHandler.Command) {
        guard !store.items.isEmpty else { return }
        let ids = store.items.map(\.id)
        let currentIndex = activeID.flatMap { ids.firstIndex(of: $0) } ?? 0
        switch command {
        case .up:
            activeID = ids[max(0, currentIndex - 1)]
        case .down:
            activeID = ids[min(ids.count - 1, currentIndex + 1)]
        case .space:
            store.toggleSelection(id: ids[currentIndex])
        case .return:
            detailItem = store.items[currentIndex]
        case .delete:
            store.remove(id: ids[currentIndex])
        }
    }

    private func icon(for kind: ContextShelfItemKind) -> String {
        switch kind {
        case .selectedText: return "text.quote"
        case .clipboard: return "clipboard"
        case .terminalOutput: return "terminal"
        case .file: return "doc"
        case .dictation: return "waveform"
        case .extensionOutput: return "puzzlepiece.extension"
        case .noteReference: return "note.text"
        case .plainText: return "text.alignleft"
        }
    }
}

private struct ContextShelfDetailView: View {
    let item: ContextShelfItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(item.title, systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            Text(ContextShelfMarkdownFormatter.format(item))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
        .frame(minWidth: 460, minHeight: 280)
    }
}


private struct ContextShelfDestinationView: View {
    let mode: ContextShelfView.DestinationMode
    let items: [ContextShelfItem]
    @ObservedObject var store: ContextShelfStore
    let dismiss: () -> Void
    @ObservedObject private var notes = NotesStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(mode.title).font(.headline); Spacer(); Button("Cancel", action: dismiss) }
            if mode == .create {
                Button {
                    notes.createNoteFromShelf(items)
                    dismiss()
                } label: { Label("Create New Note", systemImage: "plus") }
            }
            List(notes.notes) { note in
                Button {
                    notes.appendShelfItems(items, to: note.id)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: note.id == notes.selectedNoteID ? "checkmark.circle.fill" : "note.text")
                        VStack(alignment: .leading) { Text(note.displayTitle); Text(note.modifiedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(minWidth: 380, minHeight: 360)
    }
}

private struct ContextShelfComparisonView: View {
    let items: [ContextShelfItem]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Label("Compare Shelf Items", systemImage: "rectangle.split.2x1").font(.headline); Spacer(); Button("Done") { dismiss() } }
            HStack(alignment: .top, spacing: 10) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.subheadline.bold())
                        Text(ContextShelfMarkdownFormatter.format(item)).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(8).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
        }
        .padding(16).frame(minWidth: 760, minHeight: 420)
    }
}

private struct ContextShelfKeyboardHandler: NSViewRepresentable {
    enum Command { case up, down, space, `return`, delete }
    let onCommand: (Command) -> Void

    func makeNSView(context: Context) -> HandlerView {
        let view = HandlerView()
        view.onCommand = onCommand
        return view
    }

    func updateNSView(_ nsView: HandlerView, context: Context) {
        nsView.onCommand = onCommand
        DispatchQueue.main.async {
            if nsView.window?.firstResponder !== nsView { nsView.window?.makeFirstResponder(nsView) }
        }
    }

    final class HandlerView: NSView {
        var onCommand: ((ContextShelfKeyboardHandler.Command) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 126: onCommand?(.up)
            case 125: onCommand?(.down)
            case 49: onCommand?(.space)
            case 36, 76: onCommand?(.return)
            case 51, 117: onCommand?(.delete)
            default: super.keyDown(with: event)
            }
        }
    }
}

