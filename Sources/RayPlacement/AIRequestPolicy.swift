import Foundation

/// A single gate for all provider traffic. Revocation invalidates the old session,
/// including requests racing with the switch; enabling creates a fresh session.
final class AIRequestPolicy: @unchecked Sendable {
    static let preferenceKey = "lima.ai.enabled"
    static let changed = Notification.Name("Lima.aiAvailabilityChanged")
    static let shared = AIRequestPolicy(enabled: LimaTestEnvironment.userDefaults.object(forKey: preferenceKey) as? Bool ?? true)
    static let disabledMessage = "AI is turned off. Enable AI in Settings to use this action."

    struct Disabled: LocalizedError {
        var errorDescription: String? { AIRequestPolicy.disabledMessage }
    }

    private let lock = NSLock()
    private var enabled: Bool
    private var session: URLSession?
    init(enabled: Bool) { self.enabled = enabled }

    var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }

    func setEnabled(_ value: Bool) {
        lock.lock()
        guard enabled != value else { lock.unlock(); return }
        enabled = value
        let previous = session
        session = nil
        lock.unlock()
        previous?.invalidateAndCancel()
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    func check() throws {
        guard isEnabled else { throw Disabled() }
    }

    func checkedSession() throws -> URLSession {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { throw Disabled() }
        if let session { return session }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        let created = URLSession(configuration: configuration)
        session = created
        return created
    }
}
