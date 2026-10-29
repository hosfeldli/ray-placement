import AppKit
import Foundation

/// The only Mail Apple Events endpoint. Reads return source identity for
/// policy revalidation; writes are separately gated by the capability service.
actor AppleMailAdapter: MailProvider {
    private let runner = AppleMailScriptRunner()

    func supportedOperations() async -> Set<MailOperation> {
        [.listAccounts, .listMailboxes, .search, .getMessage,
         .openMessage, .createDraft, .reply, .forward, .send,
         .move, .delete]
    }

    func accounts() async throws -> [MailAccount] {
        try await runner.accounts()
    }

    func mailboxes(accountID: String) async throws -> [MailMailbox] {
        try await runner.mailboxes(accountID: accountID)
    }

    func search(_ request: MailSearchRequest) async throws -> MailSearchResult {
        try await runner.search(request)
    }

    func message(_ reference: MailMessageReference) async throws -> MailMessage {
        try await runner.message(reference)
    }

    func sendingIdentities(accountID: String) async throws -> [String] {
        try await runner.sendingIdentities(accountID: accountID)
    }

    func replyTarget(_ reference: MailMessageReference) async throws -> MailReplyTarget {
        try await runner.replyTarget(reference)
    }

    func openMessage(_ reference: MailMessageReference) async throws {
        try await runner.openMessage(reference)
    }

    func saveDraft(_ request: MailOutgoingRequest) async throws -> MailDraftReceipt {
        try await runner.saveDraft(request)
    }

    func send(_ request: MailOutgoingRequest) async throws -> MailSendReceipt {
        try await runner.send(request)
    }

    func applyMessageAction(_ request: MailMessageActionRequest) async throws {
        try await runner.applyMessageAction(request)
    }
}

/// NSAppleScript is synchronous. One dedicated serial queue keeps it off the
/// main actor, and a single in-flight slot prevents overlapping Mail events.
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

    func mailboxes(accountID: String) async throws -> [MailMailbox] {
        let source = try AppleMailReadScripts.mailboxesSource(accountID: accountID)
        return try await perform(source: source, deadline: 12) {
            try AppleMailReadScripts.parseMailboxes($0, accountID: accountID)
        }
    }

    func search(_ request: MailSearchRequest) async throws -> MailSearchResult {
        let source = try AppleMailReadScripts.searchSource(request)
        return try await perform(source: source, deadline: 20) {
            try AppleMailReadScripts.parseSearch($0, request: request)
        }
    }

    func message(_ reference: MailMessageReference) async throws -> MailMessage {
        let source = try AppleMailReadScripts.messageSource(reference)
        return try await perform(source: source, deadline: 10) {
            try AppleMailReadScripts.parseMessage($0, reference: reference)
        }
    }

    func sendingIdentities(accountID: String) async throws -> [String] {
        let source = try AppleMailWriteScripts.sendingIdentitiesSource(accountID: accountID)
        return try await perform(source: source, deadline: 10) {
            try AppleMailWriteScripts.parseSendingIdentities($0)
        }
    }

    func replyTarget(_ reference: MailMessageReference) async throws -> MailReplyTarget {
        let source = try AppleMailWriteScripts.replyTargetSource(reference)
        return try await perform(source: source, deadline: 10) {
            try AppleMailWriteScripts.parseReplyTarget($0, reference: reference)
        }
    }

    func openMessage(_ reference: MailMessageReference) async throws {
        let source = try AppleMailWriteScripts.openSource(reference)
        try await perform(source: source, deadline: 10) {
            try AppleMailWriteScripts.parseOpen($0)
        }
    }

    func saveDraft(_ request: MailOutgoingRequest) async throws -> MailDraftReceipt {
        for attachment in request.attachments { try attachment.verifyCurrent() }
        let source = try AppleMailWriteScripts.outgoingSource(request, saveOnly: true)
        return try await perform(source: source, deadline: 30) {
            try AppleMailWriteScripts.parseDraft($0)
        }
    }

    func send(_ request: MailOutgoingRequest) async throws -> MailSendReceipt {
        for attachment in request.attachments { try attachment.verifyCurrent() }
        let source = try AppleMailWriteScripts.outgoingSource(request, saveOnly: false)
        return try await perform(source: source, deadline: 30) {
            try AppleMailWriteScripts.parseSend($0)
        }
    }

    func applyMessageAction(_ request: MailMessageActionRequest) async throws {
        let source = try AppleMailWriteScripts.messageActionSource(request)
        try await perform(source: source, deadline: 20) {
            try AppleMailWriteScripts.parseMessageAction($0, kind: request.kind)
        }
    }

    /// The serial slot remains occupied after a caller stops waiting until the
    /// underlying Apple Event actually returns. A timed-out call cannot queue
    /// another script behind a still-running Mail operation.
    private func perform<Value: Sendable>(
        source: String, deadline: TimeInterval,
        parse: @escaping @Sendable (NSAppleEventDescriptor) throws -> Value
    ) async throws -> Value {
        let completion = MailCallCompletion<Value>()
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
                    guard !completion.isFinished else {
                        release()
                        return
                    }
                    let result: Result<Value, Error>
                    if let script = NSAppleScript(source: source) {
                        var errorInfo: NSDictionary?
                        let descriptor = script.executeAndReturnError(&errorInfo)
                        if let errorInfo {
                            let number = errorInfo["NSAppleScriptErrorNumber"] as? Int
                            switch number {
                            case -1743:
                                result = .failure(MailCapabilityError.automationDenied)
                            case -1712:
                                result = .failure(MailCapabilityError.timedOut)
                            case -128:
                                result = .failure(CancellationError())
                            case -1728:
                                result = .failure(MailCapabilityError.invalidRequest)
                            default:
                                // Raw diagnostics may include private message
                                // text, account names, or mailbox names.
                                result = .failure(MailCapabilityError.unavailable)
                            }
                        } else {
                            result = Result { try parse(descriptor) }
                        }
                    } else {
                        result = .failure(MailCapabilityError.unavailable)
                    }
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
