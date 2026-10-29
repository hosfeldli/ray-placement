import Foundation
import RayPlacementCore

/// Provider-scoped cooldowns are durable. Timers exist only while Lima runs;
/// a terminated app has no background recovery process.
actor AIProviderRecoveryScheduler {
    static let shared = AIProviderRecoveryScheduler()

    struct Cooldown: Codable, Sendable {
        let key: String
        let until: Date
    }

    private let url: URL
    private let fileStore = PrivateFileStore()
    private var cooldowns: [String: Cooldown]
    private var callbacks: [String: [(runID: UUID, action: @Sendable () async -> Void)]] = [:]
    private var timers: [String: DispatchSourceTimer] = [:]
    private var loadFailed = false

    init(url: URL? = nil) {
        if let url {
            self.url = url
        } else if let testURL = LimaTestEnvironment.storageURL(relativePath: "AI/provider-cooldowns.json") {
            self.url = testURL
        } else {
            self.url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Lima/AI/provider-cooldowns.json")
        }
        let result = fileStore.loadJSON([String: Cooldown].self, from: self.url)
        switch result.result.state {
        case .missing:
            cooldowns = [:]
        case .loaded:
            cooldowns = result.value ?? [:]
            loadFailed = result.value == nil
        case .corrupt, .unreadable:
            cooldowns = [:]
            loadFailed = true
        }
    }

    func preflight(key: String, now: Date = Date()) throws -> Date? {
        guard !loadFailed else { throw AIExecutionCheckpointStore.StoreError.unavailable }
        guard let until = cooldowns[key]?.until, until > now else { return nil }
        return until
    }

    func schedule(
        key: String,
        runID: UUID,
        until: Date,
        action: @escaping @Sendable () async -> Void
    ) throws {
        guard !loadFailed else { throw AIExecutionCheckpointStore.StoreError.unavailable }
        let current = cooldowns[key]?.until ?? .distantPast
        let next = max(current, until)
        var durable = cooldowns
        durable[key] = Cooldown(key: key, until: next)
        try fileStore.write(durable, to: url, backupExisting: false)
        cooldowns = durable
        callbacks[key, default: []].removeAll { $0.runID == runID }
        callbacks[key, default: []].append((runID, action))
        arm(key: key, until: next)
    }

    func cancel(runID: UUID) {
        for key in callbacks.keys {
            callbacks[key]?.removeAll { $0.runID == runID }
        }
    }

    func markRecovered(key: String) throws {
        guard !loadFailed else { throw AIExecutionCheckpointStore.StoreError.unavailable }
        guard cooldowns[key] != nil || callbacks[key]?.isEmpty == false else { return }
        var durable = cooldowns
        durable.removeValue(forKey: key)
        try fileStore.write(durable, to: url, backupExisting: false)
        cooldowns = durable
        timers.removeValue(forKey: key)?.cancel()
        let waiting = callbacks.removeValue(forKey: key) ?? []
        for item in waiting { Task { await item.action() } }
    }

    private func arm(key: String, until: Date) {
        timers.removeValue(forKey: key)?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + max(0, until.timeIntervalSinceNow))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.fire(key: key) }
        }
        timers[key] = timer
        timer.resume()
    }

    private func fire(key: String) async {
        timers.removeValue(forKey: key)?.cancel()
        guard let cooldown = cooldowns[key] else { return }
        if cooldown.until > Date() {
            arm(key: key, until: cooldown.until)
            return
        }
        // Trigger only one real inference attempt for this shared bucket. Other
        // conversations remain suspended until the provider is known recovered.
        guard var queue = callbacks[key], !queue.isEmpty else { return }
        let first = queue.removeFirst()
        callbacks[key] = queue
        await first.action()
    }
}
