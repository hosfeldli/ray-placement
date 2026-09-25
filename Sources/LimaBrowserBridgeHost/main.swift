import Darwin
import Foundation

private struct RuntimeConfiguration: Decodable {
    let schemaVersion: Int
    let host: String
    let port: Int
    let token: String
}

private enum Framing {
    static let maximumMessageBytes = 4 * 1_024 * 1_024

    static func readNativeMessage() -> Data? {
        guard let header = readExactly(from: FileHandle.standardInput, count: 4) else { return nil }
        let length = header.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        guard length > 0, length <= maximumMessageBytes else { return nil }
        return readExactly(from: FileHandle.standardInput, count: Int(length))
    }

    static func writeNativeMessage(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maximumMessageBytes else { return false }
        var length = UInt32(data.count).littleEndian
        var payload = Data(bytes: &length, count: 4)
        payload.append(data)
        do {
            try FileHandle.standardOutput.write(contentsOf: payload)
            return true
        } catch {
            return false
        }
    }

    static func readSocketFrame(_ descriptor: Int32) -> Data? {
        guard let header = readExactly(from: descriptor, count: 4) else { return nil }
        let length = header.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        guard length > 0, length <= maximumMessageBytes else { return nil }
        return readExactly(from: descriptor, count: Int(length))
    }

    static func writeSocketFrame(_ data: Data, descriptor: Int32) -> Bool {
        guard !data.isEmpty, data.count <= maximumMessageBytes else { return false }
        var length = UInt32(data.count).littleEndian
        let header = Data(bytes: &length, count: 4)
        return writeExactly(header, descriptor: descriptor) && writeExactly(data, descriptor: descriptor)
    }

    private static func readExactly(from handle: FileHandle, count: Int) -> Data? {
        var output = Data()
        output.reserveCapacity(count)
        while output.count < count {
            do {
                guard let chunk = try handle.read(upToCount: count - output.count), !chunk.isEmpty else { return nil }
                output.append(chunk)
            } catch {
                return nil
            }
        }
        return output
    }

    private static func readExactly(from descriptor: Int32, count: Int) -> Data? {
        var output = Data(count: count)
        var offset = 0
        let success = output.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while offset < count {
                let amount = Darwin.read(descriptor, base.advanced(by: offset), count - offset)
                if amount == 0 { return false }
                if amount < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += amount
            }
            return true
        }
        return success ? output : nil
    }

    private static func writeExactly(_ data: Data, descriptor: Int32) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while offset < data.count {
                let amount = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
                if amount < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if amount == 0 { return false }
                offset += amount
            }
            return true
        }
    }
}

private func runtimeConfigurationURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Lima", isDirectory: true)
        .appendingPathComponent("browser-bridge-runtime.json")
}

private func loadConfiguration() throws -> RuntimeConfiguration {
    let data = try Data(contentsOf: runtimeConfigurationURL())
    let configuration = try JSONDecoder().decode(RuntimeConfiguration.self, from: data)
    guard configuration.schemaVersion == 1,
          configuration.host == "127.0.0.1",
          (1...65_535).contains(configuration.port),
          !configuration.token.isEmpty else {
        throw NSError(domain: "LimaBrowserBridgeHost", code: 1)
    }
    return configuration
}

private func connectToLima(_ configuration: RuntimeConfiguration) throws -> Int32 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw NSError(domain: "LimaBrowserBridgeHost", code: 2) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(configuration.port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr(configuration.host))

    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard result == 0 else {
        Darwin.close(descriptor)
        throw NSError(domain: "LimaBrowserBridgeHost", code: 3)
    }
    return descriptor
}

do {
    let configuration = try loadConfiguration()
    let socketDescriptor = try connectToLima(configuration)

    let hello: [String: Any] = [
        "type": "hello",
        "token": configuration.token,
        "hostVersion": 1
    ]
    let helloData = try JSONSerialization.data(withJSONObject: hello)
    guard Framing.writeSocketFrame(helloData, descriptor: socketDescriptor) else {
        Darwin.close(socketDescriptor)
        exit(1)
    }

    let group = DispatchGroup()

    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        while let message = Framing.readNativeMessage() {
            if !Framing.writeSocketFrame(message, descriptor: socketDescriptor) { break }
        }
        Darwin.shutdown(socketDescriptor, SHUT_RDWR)
        group.leave()
    }

    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        while let message = Framing.readSocketFrame(socketDescriptor) {
            if !Framing.writeNativeMessage(message) { break }
        }
        Darwin.shutdown(socketDescriptor, SHUT_RDWR)
        group.leave()
    }

    group.wait()
    Darwin.close(socketDescriptor)
} catch {
    fputs("Lima browser bridge host failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
