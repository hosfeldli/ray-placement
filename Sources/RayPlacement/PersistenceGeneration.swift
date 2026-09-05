import Foundation

/// Monotonically invalidates delayed persistence snapshots.
///
/// DispatchWorkItem.cancel() does not prevent a work item that has already
/// started from writing. Each delayed write therefore captures a generation and
/// verifies it immediately before persisting.
final class PersistenceGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    @discardableResult
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    func isCurrent(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value == generation
    }
}
