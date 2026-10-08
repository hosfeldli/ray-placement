import Darwin
import Foundation

public struct LimaQARequest: Codable, Sendable, Equatable {
    public let id: String
    public let method: String
    public let params: [String: String]

    public init(id: String, method: String, params: [String: String] = [:]) {
        self.id = String(id.prefix(128))
        self.method = String(method.prefix(128))
        self.params = Dictionary(params.prefix(32).map { (String($0.key.prefix(128)), String($0.value.prefix(16_000))) }, uniquingKeysWith: { first, _ in first })
    }
}

public struct LimaQAResponse: Codable, Sendable, Equatable {
    public let id: String
    public let ok: Bool
    /// JSON-encoded result payload, bounded by the wire protocol.
    public let payload: String?
    public let error: String?

    public init(id: String, ok: Bool, payload: String? = nil, error: String? = nil) {
        self.id = String(id.prefix(128))
        self.ok = ok
        self.payload = payload.map { String($0.prefix(LimaQAWire.maximumMessageBytes / 2)) }
        self.error = error.map { String($0.prefix(1_024)) }
    }
}

public enum LimaQAAuthorization {
    /// Compile-time QA gating is enforced by SwiftPM; runtime opt-in is an
    /// independent requirement so a QA build is inert by default.
    public static func isAuthorized(environment: [String: String]) -> Bool {
        environment["LIMA_TEST_MODE"] == "1" && environment["LIMA_ENABLE_QA_MCP"] == "1"
    }

    public static func shouldStartAtLaunch(environment: [String: String], userEnabled: Bool) -> Bool {
        userEnabled && isAuthorized(environment: environment)
    }
}

public enum LimaQAWire {
    public static let maximumMessageBytes = 262_144

    public static func encodeRequest(_ request: LimaQARequest) throws -> Data {
        try encodeLine(request)
    }

    public static func decodeRequest(_ data: Data) throws -> LimaQARequest {
        guard data.count <= maximumMessageBytes else { throw LimaQAWireError.messageTooLarge }
        let line = Data(data.prefix { $0 != 10 && $0 != 13 })
        guard !line.isEmpty else { throw LimaQAWireError.emptyMessage }
        return try JSONDecoder().decode(LimaQARequest.self, from: line)
    }

    public static func encodeResponse(_ response: LimaQAResponse) throws -> Data {
        try encodeLine(response)
    }

    public static func decodeResponse(_ data: Data) throws -> LimaQAResponse {
        guard data.count <= maximumMessageBytes else { throw LimaQAWireError.messageTooLarge }
        let line = Data(data.prefix { $0 != 10 && $0 != 13 })
        guard !line.isEmpty else { throw LimaQAWireError.emptyMessage }
        return try JSONDecoder().decode(LimaQAResponse.self, from: line)
    }

    private static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        guard data.count < maximumMessageBytes else { throw LimaQAWireError.messageTooLarge }
        data.append(10)
        return data
    }
}

public enum LimaQAWireError: Error, Equatable {
    case emptyMessage
    case messageTooLarge
    case invalidSocketPath
    case connectionFailed(Int32)
    case writeFailed(Int32)
    case readFailed(Int32)
    case responseClosed
}

public enum LimaQASocketClient {
    public static var defaultSocketPath: String {
        "/tmp/limaqa-\(getuid()).sock"
    }

    public static func send(_ request: LimaQARequest, socketPath: String = defaultSocketPath) throws -> LimaQAResponse {
        guard socketPath.utf8.count < MemoryLayout<sockaddr_un>.size - 2 else {
            throw LimaQAWireError.invalidSocketPath
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LimaQAWireError.connectionFailed(errno) }
        defer { Darwin.close(descriptor) }

        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) {
            Darwin.setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            Darwin.setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        _ = withUnsafePointer(to: &timeout) {
            Darwin.setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }

        var address = try makeAddress(socketPath)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw LimaQAWireError.connectionFailed(errno) }

        try writeAll(try LimaQAWire.encodeRequest(request), to: descriptor)
        let responseData = try readLine(from: descriptor)
        return try LimaQAWire.decodeResponse(responseData)
    }

    private static func makeAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = path.utf8CString.map { UInt8(bitPattern: $0) }
        let copied = withUnsafeMutableBytes(of: &address.sun_path) { buffer -> Bool in
            guard pathBytes.count <= buffer.count else { return false }
            for (index, byte) in pathBytes.enumerated() { buffer[index] = byte }
            return true
        }
        guard copied else { throw LimaQAWireError.invalidSocketPath }
        return address
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { throw LimaQAWireError.emptyMessage }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.send(descriptor, baseAddress.advanced(by: offset), buffer.count - offset, 0)
                guard written > 0 else { throw LimaQAWireError.writeFailed(errno) }
                offset += written
            }
        }
    }

    private static func readLine(from descriptor: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while result.count <= LimaQAWire.maximumMessageBytes {
            let received = buffer.withUnsafeMutableBytes {
                Darwin.recv(descriptor, $0.baseAddress, $0.count, 0)
            }
            if received < 0 { throw LimaQAWireError.readFailed(errno) }
            if received == 0 {
                guard !result.isEmpty else { throw LimaQAWireError.responseClosed }
                return result
            }
            result.append(contentsOf: buffer.prefix(received))
            if result.contains(10) { return result }
        }
        throw LimaQAWireError.messageTooLarge
    }
}
