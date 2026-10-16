import Combine
import Foundation
import RayPlacementCore

/// Notes filtering is a feature concern, not work performed by Workspace's
/// structural body. Inactive modules retain inputs but do not scan content.
actor NotesWorkspaceFilterEngine {
    func filter(
        _ notes: [MarkdownNote],
        query: String,
        filter: NotesWorkspaceFilter
    ) -> [MarkdownNote] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return notes.filter { note in
            guard filter.includes(note) else { return false }
            guard !normalized.isEmpty else { return true }
            return note.displayTitle.lowercased().contains(normalized)
                || note.content.prefix(20_000).lowercased().contains(normalized)
                || note.tags.contains { $0.lowercased().contains(normalized) }
        }
    }
}

@MainActor
final class NotesWorkspacePresentationModel: ObservableObject {
    @Published private(set) var filteredNotes: [MarkdownNote] = []

    private var notes: [MarkdownNote] = []
    private var query = ""
    private var filter: NotesWorkspaceFilter = .all
    private var isActive = false
    private var generation: UInt64 = 0
    private var filterTask: Task<Void, Never>?
    private let engine = NotesWorkspaceFilterEngine()

    func setNotes(_ notes: [MarkdownNote]) {
        self.notes = notes
        schedule()
    }

    func setQuery(_ query: String) {
        guard self.query != query else { return }
        self.query = query
        schedule()
    }

    func setFilter(_ filter: NotesWorkspaceFilter) {
        guard self.filter != filter else { return }
        self.filter = filter
        schedule()
    }

    func setActive(_ isActive: Bool) {
        guard self.isActive != isActive else { return }
        self.isActive = isActive
        if isActive { schedule() }
        else { filterTask?.cancel(); filterTask = nil }
    }

    private func schedule() {
        guard isActive else { return }
        generation &+= 1
        let currentGeneration = generation
        filterTask?.cancel()
        let notes = notes
        let query = query
        let filter = filter
        let engine = engine
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filteredNotes = notes.filter { filter.includes($0) }
            filterTask = nil
            return
        }
        filterTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(35))
            guard !Task.isCancelled else { return }
            let matching = await engine.filter(notes, query: query, filter: filter)
            guard !Task.isCancelled, self?.generation == currentGeneration else { return }
            self?.filteredNotes = matching
        }
    }

    func waitForFilteringForTesting() async {
        await filterTask?.value
    }
}
