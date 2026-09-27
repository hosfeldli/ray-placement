import Combine
import Foundation
import RayPlacementCore

@MainActor
final class ContextShelfStore: ObservableObject {
    static let shared = ContextShelfStore()

    @Published private(set) var items: [ContextShelfItem] = []
    @Published var selectedIDs: Set<UUID> = []
    @Published private(set) var lastRemoved: [ContextShelfItem] = []
    @Published private(set) var lastCleared: [ContextShelfItem] = []

    private let storageURL: URL
    private let fileStore = PrivateFileStore()
    private let maxUnpinnedItems = 30
    private let maxTextCharacters = 100_000
    private let duplicateWindow: TimeInterval = 3

    init(storageURL: URL = ApplicationPaths.contextShelf, loadPersisted: Bool = true) {
        self.storageURL = storageURL
        guard loadPersisted else { return }
        let loaded = fileStore.loadJSON([ContextShelfItem].self, from: storageURL)
        guard let persisted = loaded.value else { return }
        items = persisted.filter(\.isPinned)
    }

    var selectedItems: [ContextShelfItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    var count: Int { items.count }
    var selectedCount: Int { selectedItems.count }

    @discardableResult
    func add(_ item: ContextShelfItem) -> UUID {
        let normalized = normalizedItem(item)
        if let duplicate = recentDuplicate(of: normalized) {
            selectedIDs.insert(duplicate.id)
            return duplicate.id
        }

        items.insert(normalized, at: 0)
        enforceUnpinnedLimit()
        persistPinnedItems()
        return normalized.id
    }

    @discardableResult
    func addText(
        _ text: String,
        title: String,
        kind: ContextShelfItemKind,
        source: ContextShelfSource,
        isPinned: Bool = false
    ) -> UUID {
        let trimmed = String(text.prefix(maxTextCharacters))
        let item = ContextShelfItem(
            id: UUID(),
            kind: kind,
            title: title,
            preview: ContextShelfTextFormatting.preview(for: trimmed),
            payload: .text(trimmed),
            source: source,
            createdAt: Date(),
            isPinned: isPinned
        )
        return add(item)
    }

    @discardableResult
    func remove(id: UUID) -> ContextShelfItem? {
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        items.removeAll { $0.id == id }
        selectedIDs.remove(id)
        lastRemoved = [item]
        lastCleared.removeAll()
        persistPinnedItems()
        return item
    }

    @discardableResult
    func remove(items requested: [ContextShelfItem]) -> [ContextShelfItem] {
        let ids = Set(requested.map(\.id))
        let removed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        selectedIDs.subtract(ids)
        lastRemoved = removed
        lastCleared.removeAll()
        persistPinnedItems()
        return removed
    }

    @discardableResult
    func removeSelected() -> [ContextShelfItem] {
        let ids = selectedIDs
        let removed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        selectedIDs.removeAll()
        lastRemoved = removed
        lastCleared.removeAll()
        persistPinnedItems()
        return removed
    }

    @discardableResult
    func clear() -> [ContextShelfItem] {
        let removed = items.filter { !$0.isPinned }
        items.removeAll { !$0.isPinned }
        selectedIDs = selectedIDs.filter { id in items.contains { $0.id == id } }
        lastCleared = removed
        lastRemoved.removeAll()
        persistPinnedItems()
        return removed
    }

    func undoLastRemove() {
        let restored = lastRemoved
        guard !restored.isEmpty else { return }
        lastRemoved.removeAll()
        for item in restored.reversed() where !items.contains(where: { $0.id == item.id }) {
            items.insert(item, at: 0)
        }
        enforceUnpinnedLimit()
        persistPinnedItems()
    }

    func undoClear() {
        let restored = lastCleared
        guard !restored.isEmpty else { return }
        lastCleared.removeAll()
        for item in restored.reversed() where !items.contains(where: { $0.id == item.id }) {
            items.append(item)
        }
        enforceUnpinnedLimit()
        persistPinnedItems()
    }

    func togglePinned(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isPinned.toggle()
        persistPinnedItems()
    }

    func select(id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        selectedIDs = [id]
    }

    func toggleSelection(id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    func selectAll() {
        selectedIDs = Set(items.map(\.id))
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        items.move(fromOffsets: offsets, toOffset: destination)
        persistPinnedItems()
    }

    func persistPinnedItems() {
        do {
            try fileStore.write(items.filter(\.isPinned), to: storageURL, backupExisting: false)
        } catch {
            // Shelf capture must not interrupt the source application because
            // a local persistence write failed. The next pin or termination
            // gives the store another opportunity to save.
        }
    }

    private func normalizedItem(_ item: ContextShelfItem) -> ContextShelfItem {
        var item = item
        if let text = item.textValue {
            let clipped = String(text.prefix(maxTextCharacters))
            switch item.payload {
            case .text:
                item.payload = .text(clipped)
            case .terminal(let command, _):
                item.payload = .terminal(command: command, output: clipped)
            case .dictation:
                item.payload = .dictation(transcript: clipped)
            case .file, .note:
                break
            }
            item.preview = ContextShelfTextFormatting.preview(for: clipped)
        }
        item.title = String(item.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        return item
    }

    private func recentDuplicate(of item: ContextShelfItem) -> ContextShelfItem? {
        guard let text = item.textValue else { return nil }
        return items.first { existing in
            guard existing.kind == item.kind,
                  sourceMatches(existing.source, item.source),
                  let existingText = existing.textValue else { return false }
            return existingText == text && item.createdAt.timeIntervalSince(existing.createdAt) >= 0
                && item.createdAt.timeIntervalSince(existing.createdAt) <= duplicateWindow
        }
    }

    private func sourceMatches(_ lhs: ContextShelfSource, _ rhs: ContextShelfSource) -> Bool {
        lhs.type == rhs.type &&
        lhs.applicationName == rhs.applicationName &&
        lhs.bundleIdentifier == rhs.bundleIdentifier &&
        lhs.commandID == rhs.commandID &&
        lhs.extensionID == rhs.extensionID &&
        lhs.noteID == rhs.noteID
    }

    private func enforceUnpinnedLimit() {
        while items.filter({ !$0.isPinned }).count > maxUnpinnedItems {
            guard let index = items.lastIndex(where: { !$0.isPinned }) else { break }
            selectedIDs.remove(items[index].id)
            items.remove(at: index)
        }
    }
}

enum ContextShelfTextFormatting {
    static func normalizedWhitespace(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func title(for text: String) -> String {
        let normalized = normalizedWhitespace(text)
        guard normalized.count > 24 else { return "Selected Text" }
        return String(normalized.prefix(72)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static func preview(for text: String) -> String {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { normalizedWhitespace(String($0)) }
            .filter { !$0.isEmpty }
        let preview = lines.prefix(3).joined(separator: "\n")
        if preview.count <= 360 { return preview }
        return String(preview.prefix(357)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
