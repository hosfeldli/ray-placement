import Foundation
import Network
import Testing
@testable import RayPlacementCore

@Test func browserBridgeEnvelopeRejectsInvalidVersionsIDsAndKinds() throws {
    var message = BrowserBridgeMessage(command: "browser.read", arguments: ["tabID": .number(1)])
    #expect(message.isValid)
    #expect(try JSONDecoder().decode(BrowserBridgeMessage.self, from: JSONEncoder().encode(message)).isValid)
    message.version = 99
    #expect(!message.isValid)
    message.version = 1
    message.id = "../bad"
    #expect(!message.isValid)
    message.id = UUID().uuidString
    message.kind = "evaluate_javascript"
    #expect(!message.isValid)
}

@Test func browserBridgeManifestInstallRepairAndRemovalStayRestricted() throws {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("bridge-install-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = URL(fileURLWithPath: "/usr/bin/true")
    try BrowserBridgeInstallation.install(executable: executable, home: root)
    #expect(BrowserBridgeInstallation.isInstalled(executable: executable, home: root))
    let paths = BrowserBridgeInstallation.manifestURLs(home: root)
    #expect(paths.count == 2)
    for path in paths {
        let manifest = try JSONDecoder().decode(BrowserBridgeNativeManifest.self, from: Data(contentsOf: path))
        #expect(manifest.allowed_extensions == [BrowserBridgeIdentity.extensionID])
        #expect(manifest.path == executable.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
    try BrowserBridgeInstallation.install(executable: executable, home: root)
    try BrowserBridgeInstallation.uninstall(home: root)
    #expect(!BrowserBridgeInstallation.isInstalled(executable: executable, home: root))
}

@Test func browserBridgeInstallerDoesNotOverwriteForeignManifestOrFollowSymlink() throws {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("bridge-safety-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let path = BrowserBridgeInstallation.manifestURLs(home: root)[0]
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("unrelated content".utf8).write(to: path)
    #expect(throws: (any Error).self) { try BrowserBridgeInstallation.install(executable: URL(fileURLWithPath: "/usr/bin/true"), home: root) }
    #expect(try String(contentsOf: path, encoding: .utf8) == "unrelated content")
    #expect(throws: (any Error).self) { try BrowserBridgeInstallation.uninstall(home: root) }
    try FileManager.default.removeItem(at: path)
    try FileManager.default.createSymbolicLink(at: path, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
    #expect(throws: (any Error).self) { try BrowserBridgeInstallation.install(executable: URL(fileURLWithPath: "/usr/bin/true"), home: root) }
}

private final class BridgeTransportProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedIDs: [String] = []
    private var channels: [BrowserBridgeChannel] = []
    func record(_ message: BrowserBridgeMessage) { lock.lock(); receivedIDs.append(message.id); lock.unlock() }
    func retain(_ channel: BrowserBridgeChannel) { lock.lock(); channels.append(channel); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return receivedIDs.count }
    func stop() { lock.lock(); let old = channels; channels = []; lock.unlock(); old.forEach { $0.cancel() } }
}

@Test func browserBridgeUnixSocketCarriesMultipleBoundedFrames() async throws {
    let directory = URL(fileURLWithPath: "/tmp/lima-bridge-\(UUID().uuidString.prefix(12))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    let path = directory.appendingPathComponent("socket").path
    defer { try? FileManager.default.removeItem(at: directory) }
    let probe = BridgeTransportProbe()
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = .unix(path: path)
    let listener = try NWListener(using: params)
    listener.newConnectionHandler = { connection in
        let channel = BrowserBridgeChannel(connection: connection, receive: { probe.record($0) }, disconnected: {})
        probe.retain(channel)
        channel.start()
    }
    listener.start(queue: DispatchQueue(label: "bridge-test-listener"))
    defer { probe.stop(); listener.cancel() }
    // Wait for listener setup, then exercise Network.framework's real Unix path.
    for _ in 0..<100 {
        if FileManager.default.fileExists(atPath: path) { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let connection = NWConnection(to: .unix(path: path), using: .tcp)
    let channel = BrowserBridgeChannel(connection: connection, receive: { _ in }, disconnected: {})
    channel.start()
    defer { channel.cancel() }
    channel.send(BrowserBridgeMessage(command: "browser.current"))
    channel.send(BrowserBridgeMessage(command: "browser.tabs"))
    for _ in 0..<200 {
        if probe.count == 2 { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(probe.count == 2)
}
