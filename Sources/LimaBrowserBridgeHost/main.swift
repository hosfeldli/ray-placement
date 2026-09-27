import Darwin
import Foundation
import Network
import RayPlacementCore

@main
private struct LimaBrowserBridgeHost {
    static func main() {
        // Firefox passes the native manifest path and verified extension ID.
        guard CommandLine.arguments.dropFirst().contains(BrowserBridgeIdentity.extensionID) else {
            fail()
        }
        var socketURL = BrowserBridgeIdentity.socketURL
        #if DEBUG
        if ProcessInfo.processInfo.environment["LIMA_TEST_MODE"] == "1",
           let path = ProcessInfo.processInfo.environment["LIMA_BROWSER_BRIDGE_TEST_SOCKET"] {
            socketURL = URL(fileURLWithPath: path)
        }
        #endif
        var info = stat()
        guard lstat(socketURL.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK,
              info.st_uid == getuid() else { fail() }
        let connection = NWConnection(to: .unix(path: socketURL.path), using: .tcp)
        let channel = BrowserBridgeChannel(connection: connection, receive: { message in
            guard ["request", "cancel"].contains(message.kind) else { fail() }
            do {
                let frame = try FirefoxNativeMessageFrame.encode(JSONEncoder().encode(message))
                try FileHandle.standardOutput.write(contentsOf: frame)
            } catch { fail() }
        }, disconnected: { exit(EXIT_SUCCESS) })
        channel.start()
        // The socket queue continuously forwards app requests while stdin blocks.
        do {
            while let header = try readExactly(4, allowEOF: true) {
                let count = try FirefoxNativeMessageFrame.payloadLength(fromHeader: header)
                guard count > 0, let payload = try readExactly(count, allowEOF: false) else { fail() }
                let message = try JSONDecoder().decode(BrowserBridgeMessage.self, from: payload)
                guard message.isValid, ["hello", "response"].contains(message.kind) else { fail() }
                channel.send(message)
            }
        } catch { fail() }
        channel.cancel()
    }

    private static func fail() -> Never {
        try? FileHandle.standardError.write(contentsOf: Data("Lima Browser Bridge connection unavailable or invalid.\n".utf8))
        exit(EXIT_FAILURE)
    }

    private static func readExactly(_ count: Int, allowEOF: Bool) throws -> Data? {
        var data = Data()
        while data.count < count {
            guard let part = try FileHandle.standardInput.read(upToCount: count - data.count), !part.isEmpty else {
                if data.isEmpty && allowEOF { return nil }
                throw CocoaError(.fileReadCorruptFile)
            }
            data.append(part)
        }
        return data
    }
}
