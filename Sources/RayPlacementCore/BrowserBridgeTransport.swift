import Foundation
import Network

/// No page content is persisted by this transport. The browser owns site grants.
public enum BrowserBridgeIdentity {
    public static let extensionID = "lima-browser-bridge@liamhosfeld.com"
    public static let hostName = "com.lima.browser_bridge"
    public static var socketURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lima/BrowserBridge/bridge.sock")
    }
}

public struct BrowserBridgeMessage: Codable, Sendable {
    public var version: Int
    public var id: String
    public var kind: String
    public var command: String
    public var arguments: [String: JSONValue]
    public var result: JSONValue?
    public var error: String?

    public init(id: String = UUID().uuidString, kind: String = "request", command: String,
                arguments: [String: JSONValue] = [:], result: JSONValue? = nil, error: String? = nil) {
        self.version = 1
        self.id = id
        self.kind = kind
        self.command = command
        self.arguments = arguments
        self.result = result
        self.error = error
    }

    public var isValid: Bool {
        version == 1 && UUID(uuidString: id) != nil
            && ["request", "response", "hello", "cancel"].contains(kind)
            && command.utf8.count <= 64
            && arguments.count <= 12
            && (error?.utf8.count ?? 0) <= 256
    }
}

/// Serial queue confinement prevents interleaved frames and unbounded buffering.
public final class BrowserBridgeChannel: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.lima.browser-bridge.channel")
    private let receive: @Sendable (BrowserBridgeMessage) async -> Void
    private let disconnected: @Sendable () -> Void
    private var closed = false
    private var pendingWrites = 0

    public init(connection: NWConnection,
                receive: @escaping @Sendable (BrowserBridgeMessage) async -> Void,
                disconnected: @escaping @Sendable () -> Void) {
        self.connection = connection
        self.receive = receive
        self.disconnected = disconnected
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.readHeader()
            case .failed, .cancelled, .waiting: self.finish()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ message: BrowserBridgeMessage) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            guard message.isValid, self.pendingWrites < 32,
                  let data = try? JSONEncoder().encode(message),
                  let frame = try? FirefoxNativeMessageFrame.encode(data) else {
                self.finish()
                return
            }
            self.pendingWrites += 1
            self.connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.pendingWrites -= 1
                if error != nil { self.finish() }
            })
        }
    }

    public func cancel() { queue.async { [weak self] in self?.finish() } }

    private func finish() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        disconnected()
    }

    private func readHeader() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            guard error == nil, let data, data.count == 4,
                  let length = try? FirefoxNativeMessageFrame.payloadLength(fromHeader: data),
                  length > 0 else { self.finish(); return }
            self.readPayload(length)
        }
    }

    private func readPayload(_ length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self, !self.closed else { return }
            guard error == nil, let data, data.count == length,
                  let message = try? JSONDecoder().decode(BrowserBridgeMessage.self, from: data),
                  message.isValid else { self.finish(); return }
            // Backpressure: deliver one message before reading another frame.
            // A fast peer cannot enqueue unbounded MainActor work or reorder hello.
            Task {
                await self.receive(message)
                self.queue.async { [weak self] in self?.readHeader() }
            }
        }
    }
}
