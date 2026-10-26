import AppKit
import Foundation

/// The only Mail Apple Events endpoint. Account discovery is implemented first;
/// search, body reads, and all writes remain unavailable until scoped scripts
/// have been validated with synthetic accounts on the macOS QA machine.
actor AppleMailAdapter: MailProvider {
    private let runner = AppleMailScriptRunner()

    func supportedOperations() async -> Set<MailOperation> { [.listAccounts] }

    func accounts() async throws -> [MailAccount] {
        try await runner.accounts()
    }

    func mailboxes(accountID: String) async throws -> [MailMailbox] {
        throw MailCapabilityError.unavailable
    }

    func search(_ request: MailSearchRequest) async throws -> MailSearchResult {
        throw MailCapabilityError.unavailable
    }

    func message(_ reference: MailMessageReference) async throws -> MailMessage {
        throw MailCapabilityError.unavailable
    }
}

/// NSAppleScript is synchronous. One dedicated serial queue keeps it off the
/// main actor, and a single in-flight slot prevents unbounded queued reads.
/// A timeout or cancellation stops waiting; it does not claim that macOS
/// interrupted an Apple Event already executing.
private final class AppleMailScriptRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.liam.lima.mail.apple-events", qos: .utility)
    private let deadlineQueue = DispatchQueue(label: "dev.liam.lima.mail.deadlines", qos: .utility)
    private let lock = NSLock()
    private var isExecuting = false
    private let deadline: TimeInterval = 8

    // This fixed script contains no user input. Mail.sdef on the supported Mac
    // defines receiving account IDs and names; no password or email body is read.
    private static let accountDiscoveryScript = """
    tell application id "com.apple.mail"
        set accountRows to {}
        repeat with mailAccount in (get every account)
            set end of accountRows to {(id of mailAccount as text), (name of mailAccount as text)}
        end repeat
        return accountRows
    end tell
    """

    func accounts() async throws -> [MailAccount] {
        let completion = MailCallCompletion<[MailAccount]>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                if Task.isCancelled {
                    completion.finish(.failure(CancellationError()))
                    return
                }
                guard claim() else {
                    completion.finish(.failure(MailCapabilityError.busy))
                    return
                }
                deadlineQueue.asyncAfter(deadline: .now() + deadline) {
                    completion.finish(.failure(MailCapabilityError.timedOut))
                }
                queue.async { [self] in
                    // A queued operation canceled before it began must not
                    // trigger an Automation prompt or launch Mail.
                    guard !completion.isFinished else {
                        release()
                        return
                    }
                    let result = Self.discoverAccountRows()
                    release()
                    completion.finish(result)
                }
            }
        } onCancel: {
            completion.finish(.failure(CancellationError()))
        }
    }

    private func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isExecuting else { return false }
        isExecuting = true
        return true
    }

    private func release() {
        lock.lock()
        isExecuting = false
        lock.unlock()
    }

    private static func discoverAccountRows() -> Result<[MailAccount], Error> {
        guard let script = NSAppleScript(source: accountDiscoveryScript) else {
            return .failure(MailCapabilityError.unavailable)
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = errorInfo["NSAppleScriptErrorNumber"] as? Int
            if number == -1743 { return .failure(MailCapabilityError.automationDenied) }
            if number == -1712 { return .failure(MailCapabilityError.timedOut) }
            // Do not surface raw AppleScript diagnostics: they may contain
            // private account or mailbox names.
            return .failure(MailCapabilityError.unavailable)
        }
        guard result.numberOfItems <= 100 else {
            return .failure(MailCapabilityError.malformedResponse)
        }
        guard result.numberOfItems > 0 else { return .success([]) }
        var accounts: [MailAccount] = []
        var seen = Set<String>()
        for index in 1...result.numberOfItems {
            guard let row = result.atIndex(index),
                  row.numberOfItems == 2,
                  let id = row.atIndex(1)?.stringValue,
                  let name = row.atIndex(2)?.stringValue,
                  !id.isEmpty, id.utf8.count <= 256,
                  !name.isEmpty, name.utf8.count <= 256,
                  seen.insert(id).inserted else {
                return .failure(MailCapabilityError.malformedResponse)
            }
            accounts.append(MailAccount(id: id, name: name))
        }
        return .success(accounts)
    }
}

private final class MailCallCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var finished: Result<Value, Error>?

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished != nil
    }

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let finished {
            lock.unlock()
            continuation.resume(with: finished)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard finished == nil else {
            lock.unlock()
            return
        }
        finished = result
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
