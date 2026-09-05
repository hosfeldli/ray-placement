import Foundation

struct DictationConversation: Codable, Identifiable, Hashable {
    let id: UUID
    let startedAt: Date
    var modifiedAt: Date
    var segments: [String]
    var isComplete: Bool

    init(id: UUID = UUID(), startedAt: Date = Date(), segments: [String] = [], isComplete: Bool = false) {
        self.id = id
        self.startedAt = startedAt
        self.modifiedAt = startedAt
        self.segments = segments
        self.isComplete = isComplete
    }

    var title: String {
        "Dictation · \(startedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    var transcript: String {
        segments.joined(separator: "\n\n")
    }

    var characterCount: Int {
        segments.reduce(0) { $0 + $1.count } + max(0, segments.count - 1) * 2
    }

    var hasContent: Bool {
        segments.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var preview: String {
        let limit = 180
        var result = ""
        for segment in segments {
            let clean = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            if !result.isEmpty { result += " " }
            let remaining = limit - result.count
            guard remaining > 0 else { break }
            result += String(clean.prefix(remaining))
            if result.count >= limit { break }
        }
        return result
    }
}

@MainActor
final class DictationConversationStore: ObservableObject {
    static let maximumConversations = 100
    static let maximumCharactersPerConversation = 200_000

    @Published private(set) var conversations: [DictationConversation]
    @Published var selectedConversationID: UUID?

    private let persistenceQueue = DispatchQueue(label: "dev.rayplacement.dictation-persistence", qos: .utility)
    private let persistenceGeneration = PersistenceGeneration()
    private var pendingSave: DispatchWorkItem?
    private var activeConversationID: UUID?
    private var resumableConversationID: UUID?

    init() {
        conversations = Self.load()
        selectedConversationID = conversations.first?.id
    }

    var selectedConversation: DictationConversation? {
        guard let selectedConversationID else { return conversations.first }
        return conversations.first { $0.id == selectedConversationID }
    }

    func beginConversation() {
        if let activeConversationID,
           conversations.contains(where: { $0.id == activeConversationID }) {
            selectedConversationID = activeConversationID
            return
        }

        let conversation = DictationConversation()
        conversations.insert(conversation, at: 0)
        resumableConversationID = nil
        activeConversationID = conversation.id
        selectedConversationID = conversation.id
        trimAndSave()
    }

    func beginRetryConversation() {
        if let resumableConversationID,
           let index = conversations.firstIndex(where: { $0.id == resumableConversationID }) {
            conversations[index].isComplete = false
            conversations[index].modifiedAt = Date()
            activeConversationID = resumableConversationID
            self.resumableConversationID = nil
            selectedConversationID = resumableConversationID
            scheduleSave()
            return
        }
        beginConversation()
    }

    func append(_ transcript: String) {
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if activeConversationID == nil { beginConversation() }
        guard let activeConversationID,
              let index = conversations.firstIndex(where: { $0.id == activeConversationID }) else { return }

        let hasContent = conversations[index].hasContent
        let separator = hasContent ? "\n\n" : ""
        let available = Self.maximumCharactersPerConversation - conversations[index].characterCount - separator.count
        guard available > 0 else { return }
        conversations[index].segments.append(String(clean.prefix(available)))
        conversations[index].modifiedAt = Date()
        selectedConversationID = activeConversationID
        scheduleSave()
    }

    func finishConversation() {
        guard let activeConversationID,
              let index = conversations.firstIndex(where: { $0.id == activeConversationID }) else { return }
        if !conversations[index].hasContent {
            conversations.remove(at: index)
            selectedConversationID = conversations.first?.id
        } else {
            conversations[index].isComplete = true
            conversations[index].modifiedAt = Date()
        }
        self.activeConversationID = nil
        resumableConversationID = nil
        scheduleSave()
    }

    func failConversationForRetry() {
        guard let activeConversationID,
              let index = conversations.firstIndex(where: { $0.id == activeConversationID }) else { return }
        if !conversations[index].hasContent {
            conversations.remove(at: index)
            selectedConversationID = conversations.first?.id
            resumableConversationID = nil
        } else {
            conversations[index].isComplete = true
            conversations[index].modifiedAt = Date()
            resumableConversationID = activeConversationID
            selectedConversationID = activeConversationID
        }
        self.activeConversationID = nil
        scheduleSave()
    }

    func delete(_ conversation: DictationConversation) {
        conversations.removeAll { $0.id == conversation.id }
        if activeConversationID == conversation.id { activeConversationID = nil }
        if resumableConversationID == conversation.id { resumableConversationID = nil }
        selectedConversationID = conversations.first?.id
        scheduleSave()
    }

    func flush() {
        // Invalidate every delayed snapshot before waiting for the queue. A
        // canceled DispatchWorkItem may already be executing, so cancellation
        // alone is not a sufficient stale-write barrier.
        _ = persistenceGeneration.next()
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = conversations
        persistenceQueue.sync { Self.persist(snapshot) }
    }

    private func trimAndSave() {
        conversations = Array(conversations.prefix(Self.maximumConversations))
        scheduleSave()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = conversations
        let generation = persistenceGeneration.next()
        let gate = persistenceGeneration
        let work = DispatchWorkItem {
            guard gate.isCurrent(generation) else { return }
            Self.persist(snapshot)
        }
        pendingSave = work
        persistenceQueue.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private static func load() -> [DictationConversation] {
        guard let data = try? Data(contentsOf: ApplicationPaths.dictationConversations),
              let decoded = try? JSONDecoder().decode([DictationConversation].self, from: data) else { return [] }
        return Array(decoded
            .filter { $0.characterCount <= maximumCharactersPerConversation }
            .prefix(maximumConversations))
    }

    private nonisolated static func persist(_ conversations: [DictationConversation]) {
        guard let data = try? JSONEncoder().encode(conversations) else { return }
        try? FileManager.default.createDirectory(
            at: ApplicationPaths.applicationSupport,
            withIntermediateDirectories: true
        )
        try? data.write(to: ApplicationPaths.dictationConversations, options: .atomic)
    }
}
