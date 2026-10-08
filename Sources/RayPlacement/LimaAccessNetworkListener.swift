import Darwin
import Foundation
import Network
import Security

/// One-request-per-connection HTTPS transport bound to one selected private IP.
/// All mutable connection state is confined to `queue`; MCP work runs through
/// the MainActor service, which rechecks authorization after asynchronous work.
final class LimaAccessNetworkListener: @unchecked Sendable {
    static let port: UInt16 = 43822

    private final class RequestState: @unchecked Sendable {
        var bytes = Data()
        var reading = true
        var deadline: DispatchWorkItem?
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.liam.lima.access.network", qos: .utility)
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let handler: (Data) async -> Data
    private let stateChanged: (Bool, String?) -> Void

    init(address: String, identity: SecIdentity,
         handler: @escaping (Data) async -> Data,
         stateChanged: @escaping (Bool, String?) -> Void) throws {
        guard LimaAccessTLSIdentity.isPrivateIPv4(address),
              LimaAccessTLSIdentity.availableAddresses().contains(address),
              let port = NWEndpoint.Port(rawValue: Self.port),
              let networkIdentity = sec_identity_create(identity) else {
            throw NSError(domain: "LimaAccessNetwork", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "A current private address and TLS identity are required."])
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, networkIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: port)
        parameters.includePeerToPeer = false
        listener = try NWListener(using: parameters)
        // TXT contains no bearer token, pairing secret, or user content.
        listener.service = NWListener.Service(
            name: "Lima",
            type: "_lima-mcp._tcp",
            txtRecord: NetService.data(fromTXTRecord: [
                "tls": Data("true".utf8),
                "pairing": Data("true".utf8),
                "version": Data("1".utf8)
            ])
        )
        self.handler = handler
        self.stateChanged = stateChanged
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // requiredLocalEndpoint is the binding contract. Refuse to run if
                // the listener is also reachable through the loopback address.
                guard !Self.loopbackListenerPresent() else {
                    self.stateChanged(false, "Network listener unexpectedly accepts loopback connections.")
                    self.stop()
                    return
                }
                self.stateChanged(true, nil)
            case .waiting(let error), .failed(let error):
                // A disappeared interface or unavailable port must clear the
                // opt-in instead of leaving Settings claiming TLS is live.
                self.stateChanged(false, "Network AI Connections stopped: \(error.localizedDescription)")
                self.stop()
            case .cancelled:
                self.stateChanged(false, nil)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        queue.async { [weak self] in
            guard let self else { return }
            for connection in self.connections.values { connection.cancel() }
            self.connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 4 else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        let state = RequestState()
        connections[id] = connection
        connection.start(queue: queue)
        let deadline = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection, state.reading else { return }
            self.close(connection, id: id, state: state)
        }
        state.deadline = deadline
        queue.asyncAfter(deadline: .now() + LimaAccessHTTP.maximumRequestSeconds, execute: deadline)
        receive(connection, id: id, state: state)
    }

    private func receive(_ connection: NWConnection, id: ObjectIdentifier, state: RequestState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) {
            [weak self] chunk, _, isComplete, error in
            guard let self, state.reading, self.connections[id] != nil else { return }
            if let chunk { state.bytes.append(chunk) }
            guard error == nil, state.bytes.count <= LimaAccessHTTP.maximumRequestBytes else {
                self.close(connection, id: id, state: state)
                return
            }
            if let expected = LimaAccessHTTP.expectedRequestLength(state.bytes) {
                if state.bytes.count > expected {
                    self.close(connection, id: id, state: state)
                    return
                }
                if state.bytes.count == expected {
                    guard LimaAccessHTTP.parse(state.bytes) != nil else {
                        self.close(connection, id: id, state: state)
                        return
                    }
                    state.reading = false
                    state.deadline?.cancel()
                    let request = state.bytes
                    Task { [weak self] in
                        guard let self else { return }
                        let response = await self.handler(request)
                        self.queue.async {
                            guard self.connections[id] != nil else { return }
                            connection.send(content: response, completion: .contentProcessed { _ in
                                self.close(connection, id: id, state: state)
                            })
                        }
                    }
                    return
                }
            } else if state.bytes.count > 8_196 &&
                        state.bytes.range(of: Data([13, 10, 13, 10])) == nil {
                self.close(connection, id: id, state: state)
                return
            }
            if isComplete {
                self.close(connection, id: id, state: state)
            } else {
                self.receive(connection, id: id, state: state)
            }
        }
    }

    private static func loopbackListenerPresent() -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return true }
        defer { Darwin.close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: Darwin.inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private func close(_ connection: NWConnection, id: ObjectIdentifier,
                       state: RequestState) {
        state.reading = false
        state.deadline?.cancel()
        connection.cancel()
        connections.removeValue(forKey: id)
    }
}
