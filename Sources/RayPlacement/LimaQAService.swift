#if LIMA_QA
import AppKit
import ApplicationServices
import Combine
import Darwin
import Foundation
import LimaQAProtocol

@MainActor
final class LimaQAService: ObservableObject {
    static let shared = LimaQAService()
    static let enabledPreferenceKey = "lima.qaMCP.enabled"

    private weak var launcher: LauncherController?
    private var listenerDescriptor: Int32 = -1
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage: String?
    private let socketPath = LimaQASocketClient.defaultSocketPath
    private let connectionLimit = DispatchSemaphore(value: 4)

    private init() {}

    func configure(launcher: LauncherController) {
        self.launcher = launcher
    }

    var runtimeAuthorized: Bool {
        LimaQAAuthorization.isAuthorized(environment: ProcessInfo.processInfo.environment)
    }

    var displaySocketPath: String { socketPath }

    var clientConfiguration: String? {
        let executable = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/LimaQAMCPServer")
            .path
        guard FileManager.default.isExecutableFile(atPath: executable),
              let data = try? JSONSerialization.data(
                withJSONObject: ["mcpServers": ["lima-qa": ["command": executable, "args": []]]],
                options: [.prettyPrinted, .sortedKeys]
              ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func startIfEnabledAtLaunch() {
        let environment = ProcessInfo.processInfo.environment
        let userEnabled = UserDefaults.standard.bool(forKey: Self.enabledPreferenceKey)
        guard LimaQAAuthorization.shouldStartAtLaunch(environment: environment, userEnabled: userEnabled) else { return }
        _ = startIfAuthorized(environment: environment)
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledPreferenceKey)
        if enabled {
            if !startIfAuthorized() {
                UserDefaults.standard.set(false, forKey: Self.enabledPreferenceKey)
            }
        } else {
            stop()
            statusMessage = "QA MCP is off."
        }
    }

    @discardableResult
    func startIfAuthorized(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard LimaQAAuthorization.isAuthorized(environment: environment) else {
            statusMessage = "QA MCP requires a QA build launched with both runtime opt-ins."
            return false
        }
        guard !isRunning else { return true }
        do {
            listenerDescriptor = try Self.makeListener(path: socketPath)
            isRunning = true
            statusMessage = "QA MCP is running on this Mac."
            let descriptor = listenerDescriptor
            let semaphore = connectionLimit
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                Self.acceptLoop(descriptor: descriptor, semaphore: semaphore) { [weak self] client, request in
                    Task { @MainActor [weak self] in
                        defer { semaphore.signal() }
                        guard let self else {
                            Self.write(LimaQAResponse(id: request.id, ok: false, error: "Lima QA service stopped."), to: client)
                            Darwin.close(client)
                            return
                        }
                        let response = self.handle(request)
                        Self.write(response, to: client)
                        Darwin.close(client)
                    }
                }
            }
            return true
        } catch {
            listenerDescriptor = -1
            isRunning = false
            statusMessage = "QA MCP could not create its local control socket."
            return false
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        Darwin.shutdown(listenerDescriptor, SHUT_RDWR)
        Darwin.close(listenerDescriptor)
        listenerDescriptor = -1
        Self.removeOwnedSocket(path: socketPath)
        statusMessage = "QA MCP is off."
    }

    private func handle(_ request: LimaQARequest) -> LimaQAResponse {
        let result: [String: Any]
        switch request.method {
        case "status":
            result = status()
        case "surfaces.list":
            result = ["surfaces": ["search", "notes", "ai", "context", "settings"]]
        case "surface.open":
            guard let surface = request.params["surface"], launcher?.openQASurface(surface) == true else {
                return failure(request, "Unsupported Lima surface.")
            }
            result = ["opened": surface]
        case "surface.close":
            guard let surface = request.params["surface"], launcher?.closeQASurface(surface) == true else {
                return failure(request, "The requested surface is not open or cannot be closed through this QA route.")
            }
            result = ["closed": surface]
        case "ui.inspect":
            result = inspectUI()
        case "ui.find":
            guard let target = request.params["target"], LimaQAIdentifiers.knownIdentifiers.contains(target) else {
                return failure(request, "Use a known Lima semantic accessibility identifier.")
            }
            if let control = LimaQAAccessibility.control(identifier: target) {
                result = ["found": true, "control": control.summary]
            } else {
                result = ["found": false, "target": target]
            }
        case "ui.activate":
            guard let target = request.params["target"], LimaQAIdentifiers.knownIdentifiers.contains(target) else {
                return failure(request, "Use a known Lima semantic accessibility identifier.")
            }
            guard LimaQAAccessibility.activate(identifier: target) else {
                return failure(request, "The requested visible control could not be activated.")
            }
            result = ["activated": target]
        case "ui.setText":
            guard let target = request.params["target"],
                  let text = request.params["text"],
                  text.utf8.count <= 16_000,
                  LimaQAIdentifiers.textEntryIdentifiers.contains(target) else {
                return failure(request, "Text entry is limited to known Lima fields and 16,000 UTF-8 bytes.")
            }
            guard LimaQAAccessibility.setText(text, identifier: target) else {
                return failure(request, "The requested visible text field could not be updated.")
            }
            result = ["setText": target, "characterCount": text.count]
        case "ui.pressKey":
            guard let key = request.params["key"], Self.pressKey(key) else {
                return failure(request, "Use one supported key: return, escape, tab, arrows, space, or delete.")
            }
            result = ["pressedKey": key]
        case "app.state":
            result = appState()
        case "tasks.list":
            result = taskProjection()
        case "ai.activity":
            result = launcher?.qaAIActivitySnapshot() ?? ["available": false, "steps": []]
        default:
            return failure(request, "Unknown Lima QA operation.")
        }

        return success(request, result)
    }

    private func status() -> [String: Any] {
        [
            "app": "Lima",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "processID": getpid(),
            "qaBuild": true,
            "runtimeAuthorized": true,
            "transport": "user-only Unix domain socket",
            "socketMode": "0600",
            "activeTaskCount": TaskRegistry.shared.activeTasks.count
        ]
    }

    private func appState() -> [String: Any] {
        let workspace = WorkspaceStateRegistry.shared.state
        let visibleWindows = NSApp.windows.filter(\.isVisible).prefix(12).map { window in
            [
                "identifier": window.identifier?.rawValue ?? "",
                "key": window.isKeyWindow,
                "main": window.isMainWindow
            ] as [String: Any]
        }
        return [
            "launcher": ["visibleWindowCount": visibleWindows.count],
            "workspace": [
                "activeWorkspace": workspace.activeWorkspace as Any? ?? NSNull(),
                "activeModule": workspace.activeModule as Any? ?? NSNull()
            ],
            "ai": launcher?.qaAIStateSnapshot() ?? [:],
            "browserBridge": ["status": BrowserBridgeService.shared.status],
            "visibleWindows": visibleWindows,
            "tasks": taskProjection()["tasks"] ?? []
        ]
    }

    private func taskProjection() -> [String: Any] {
        let tasks = TaskRegistry.shared.activeTasks + Array(TaskRegistry.shared.recentTasks.prefix(30))
        return [
            "activeCount": TaskRegistry.shared.activeTasks.count,
            "tasks": tasks.map { task in
                [
                    "id": task.id.uuidString,
                    "kind": task.kind.rawValue,
                    "title": task.title,
                    "state": task.state.rawValue,
                    "isCancellable": task.isCancellable
                ] as [String: Any]
            }
        ]
    }

    private func inspectUI() -> [String: Any] {
        let windows = NSApp.windows.filter(\.isVisible).prefix(8).map { window in
            [
                "role": "window",
                "identifier": window.identifier?.rawValue ?? "",
                "focused": window.isKeyWindow
            ] as [String: Any]
        }
        let controls = LimaQAAccessibility.visibleControls(limit: 100)
        return [
            "surface": NSApp.keyWindow?.identifier?.rawValue ?? "unknown",
            "module": WorkspaceStateRegistry.shared.state.activeModule as Any? ?? NSNull(),
            "focusedTarget": controls.first(where: { $0["focused"] as? Bool == true })?["identifier"] as Any? ?? NSNull(),
            "windows": windows,
            "controls": controls
        ]
    }

    private func success(_ request: LimaQARequest, _ value: [String: Any]) -> LimaQAResponse {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let payload = String(data: data, encoding: .utf8) else {
            return failure(request, "Lima could not encode the bounded QA result.")
        }
        return LimaQAResponse(id: request.id, ok: true, payload: payload)
    }

    private func failure(_ request: LimaQARequest, _ message: String) -> LimaQAResponse {
        LimaQAResponse(id: request.id, ok: false, error: message)
    }

    private static func pressKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        let keyInfo: (code: CGKeyCode, characters: String)?
        switch normalized {
        case "return", "enter": keyInfo = (36, "\r")
        case "escape", "esc": keyInfo = (53, "\u{1b}")
        case "tab": keyInfo = (48, "\t")
        case "up": keyInfo = (126, "\u{f700}")
        case "down": keyInfo = (125, "\u{f701}")
        case "left": keyInfo = (123, "\u{f702}")
        case "right": keyInfo = (124, "\u{f703}")
        case "space": keyInfo = (49, " ")
        case "delete", "backspace": keyInfo = (51, "\u{8}")
        default: keyInfo = nil
        }
        guard let keyInfo, let window = NSApp.keyWindow else { return false }
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: timestamp,
            windowNumber: window.windowNumber, context: nil,
            characters: keyInfo.characters, charactersIgnoringModifiers: keyInfo.characters,
            isARepeat: false, keyCode: keyInfo.code
        ), let up = NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: [], timestamp: timestamp,
            windowNumber: window.windowNumber, context: nil,
            characters: keyInfo.characters, charactersIgnoringModifiers: keyInfo.characters,
            isARepeat: false, keyCode: keyInfo.code
        ) else { return false }
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
        return true
    }

    private nonisolated static func acceptLoop(
        descriptor: Int32,
        semaphore: DispatchSemaphore?,
        handler: @escaping @Sendable (Int32, LimaQARequest) -> Void
    ) {
        while true {
            let client = Darwin.accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            guard let semaphore, semaphore.wait(timeout: .now()) == .success else {
                Darwin.close(client)
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async {
                Self.setSocketTimeout(client)
                guard let request = Self.readRequest(from: client) else {
                    Darwin.close(client)
                    semaphore.signal()
                    return
                }
                handler(client, request)
                // The main-actor handler owns this client and releases the slot.
            }
        }
    }

    private nonisolated static func readRequest(from descriptor: Int32) -> LimaQARequest? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while data.count <= LimaQAWire.maximumMessageBytes {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.recv(descriptor, $0.baseAddress, $0.count, 0)
            }
            guard count > 0 else { return nil }
            data.append(contentsOf: buffer.prefix(count))
            if data.contains(10) { break }
        }
        guard data.count <= LimaQAWire.maximumMessageBytes else { return nil }
        return try? LimaQAWire.decodeRequest(data)
    }

    private nonisolated static func write(_ response: LimaQAResponse, to descriptor: Int32) {
        guard let data = try? LimaQAWire.encodeResponse(response) else { return }
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.send(descriptor, base.advanced(by: offset), buffer.count - offset, 0)
                guard count > 0 else { return }
                offset += count
            }
        }
    }

    private nonisolated static func setSocketTimeout(_ descriptor: Int32) {
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            Darwin.setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) {
            Darwin.setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
    }

    private nonisolated static func makeListener(path: String) throws -> Int32 {
        guard path.utf8.count < MemoryLayout<sockaddr_un>.size - 2 else { throw LimaQAWireError.invalidSocketPath }
        try removeStaleSocket(path: path)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LimaQAWireError.connectionFailed(errno) }
        setSocketTimeout(descriptor)

        var address = try makeAddress(path)
        let previousMask = umask(mode_t(S_IRWXG | S_IRWXO))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        _ = umask(previousMask)
        guard bindResult == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw LimaQAWireError.connectionFailed(code)
        }
        let chmodResult = path.withCString { Darwin.chmod($0, mode_t(S_IRUSR | S_IWUSR)) }
        guard chmodResult == 0, Darwin.listen(descriptor, 8) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            removeOwnedSocket(path: path)
            throw LimaQAWireError.connectionFailed(code)
        }
        return descriptor
    }

    private nonisolated static func removeStaleSocket(path: String) throws {
        var metadata = stat()
        let result = path.withCString { Darwin.lstat($0, &metadata) }
        guard result == 0 else {
            if errno == ENOENT { return }
            throw LimaQAWireError.connectionFailed(errno)
        }
        guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK),
              metadata.st_uid == getuid() else {
            throw LimaQAWireError.connectionFailed(EACCES)
        }

        let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if probe >= 0 {
            var address = try makeAddress(path)
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            Darwin.close(probe)
            if connected == 0 { throw LimaQAWireError.connectionFailed(EADDRINUSE) }
            guard errno == ECONNREFUSED || errno == ENOENT else {
                throw LimaQAWireError.connectionFailed(errno)
            }
        }
        guard path.withCString({ Darwin.unlink($0) }) == 0 else {
            throw LimaQAWireError.connectionFailed(errno)
        }
    }

    private nonisolated static func removeOwnedSocket(path: String) {
        var metadata = stat()
        guard path.withCString({ Darwin.lstat($0, &metadata) }) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK),
              metadata.st_uid == getuid() else { return }
        _ = path.withCString { Darwin.unlink($0) }
    }

    private nonisolated static func makeAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = path.utf8CString.map { UInt8(bitPattern: $0) }
        let copied = withUnsafeMutableBytes(of: &address.sun_path) { buffer -> Bool in
            guard bytes.count <= buffer.count else { return false }
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            return true
        }
        guard copied else { throw LimaQAWireError.invalidSocketPath }
        return address
    }
}

private struct LimaQAAccessibilityControl {
    let element: AXUIElement
    let summary: [String: Any]
}

private enum LimaQAAccessibility {
    static func visibleControls(limit: Int) -> [[String: Any]] {
        var rawWindows: CFTypeRef?
        let app = AXUIElementCreateApplication(getpid())
        guard AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &rawWindows) == .success,
              let windows = rawWindows as? [AXUIElement] else { return [] }
        var controls: [[String: Any]] = []
        var visited = 0
        for window in windows.prefix(8) {
            walk(window, depth: 0, visited: &visited, controls: &controls, limit: limit)
            if controls.count >= limit || visited >= 1_500 { break }
        }
        return controls
    }

    static func control(identifier: String) -> LimaQAAccessibilityControl? {
        var rawWindows: CFTypeRef?
        let app = AXUIElementCreateApplication(getpid())
        guard AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &rawWindows) == .success,
              let windows = rawWindows as? [AXUIElement] else { return nil }
        var visited = 0
        var controls: [[String: Any]] = []
        var found: LimaQAAccessibilityControl?
        for window in windows.prefix(8) {
            find(window, identifier: identifier, depth: 0, visited: &visited, controls: &controls, found: &found)
            if found != nil || visited >= 1_500 { break }
        }
        return found
    }

    static func activate(identifier: String) -> Bool {
        guard let control = control(identifier: identifier) else { return false }
        return AXUIElementPerformAction(control.element, "AXPress" as CFString) == .success
    }

    static func setText(_ text: String, identifier: String) -> Bool {
        guard LimaQAIdentifiers.textEntryIdentifiers.contains(identifier),
              let control = control(identifier: identifier),
              let role = control.summary["role"] as? String,
              ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) else { return false }
        return AXUIElementSetAttributeValue(control.element, "AXValue" as CFString, text as CFString) == .success
    }

    private static func walk(
        _ element: AXUIElement,
        depth: Int,
        visited: inout Int,
        controls: inout [[String: Any]],
        limit: Int
    ) {
        guard depth <= 12, visited < 1_500, controls.count < limit else { return }
        visited += 1
        if let value = summary(for: element), LimaQAIdentifiers.knownIdentifiers.contains(value["identifier"] as? String ?? "") {
            controls.append(value)
        }
        for child in children(of: element).prefix(80) {
            walk(child, depth: depth + 1, visited: &visited, controls: &controls, limit: limit)
            if controls.count >= limit || visited >= 1_500 { return }
        }
    }

    private static func find(
        _ element: AXUIElement,
        identifier: String,
        depth: Int,
        visited: inout Int,
        controls: inout [[String: Any]],
        found: inout LimaQAAccessibilityControl?
    ) {
        guard found == nil, depth <= 12, visited < 1_500 else { return }
        visited += 1
        if let value = summary(for: element), value["identifier"] as? String == identifier {
            found = LimaQAAccessibilityControl(element: element, summary: value)
            return
        }
        for child in children(of: element).prefix(80) {
            find(child, identifier: identifier, depth: depth + 1, visited: &visited, controls: &controls, found: &found)
            if found != nil || visited >= 1_500 { return }
        }
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var rawChildren: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &rawChildren) == .success else { return [] }
        return rawChildren as? [AXUIElement] ?? []
    }

    private static func summary(for element: AXUIElement) -> [String: Any]? {
        guard let identifier = attribute("AXIdentifier", from: element) as? String,
              LimaQAIdentifiers.knownIdentifiers.contains(identifier) else { return nil }
        var summary: [String: Any] = [
            "identifier": identifier,
            "role": attribute("AXRole", from: element) as? String ?? "unknown",
            "visible": true,
            "enabled": attribute("AXEnabled", from: element) as? Bool ?? false,
            "selected": attribute("AXSelected", from: element) as? Bool ?? false,
            "focused": attribute("AXFocused", from: element) as? Bool ?? false
        ]
        if let label = (attribute("AXDescription", from: element) as? String) ?? (attribute("AXTitle", from: element) as? String) {
            summary["label"] = String(label.prefix(256))
        }
        if LimaQAIdentifiers.textEntryIdentifiers.contains(identifier),
           let value = attribute("AXValue", from: element) as? String {
            summary["value"] = String(value.prefix(512))
        }
        return summary
    }

    private static func attribute(_ name: String, from element: AXUIElement) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
#endif
