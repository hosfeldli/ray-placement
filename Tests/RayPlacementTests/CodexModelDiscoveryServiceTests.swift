import Foundation
import Testing
@testable import RayPlacement

@Test func codexModelListParsesAdvertisedModelsWithoutClaimingAccess() throws {
    let result: [String: Any] = [
        "data": [
            [
                "id": "internal-1",
                "model": "gpt-6-sol",
                "displayName": "GPT-6 Sol",
                "hidden": false,
                "supportedReasoningEfforts": [
                    ["reasoningEffort": "low"],
                    ["reasoningEffort": "medium"],
                    ["reasoningEffort": "high"]
                ]
            ],
            ["id": "hidden", "model": "gpt-hidden", "displayName": "Hidden", "hidden": true],
            ["id": "invalid", "model": "--unsafe", "displayName": "Invalid", "hidden": false]
        ],
        "nextCursor": "page-2"
    ]
    let parsed = try CodexModelDiscoveryService.parseModelListResult(result)
    #expect(parsed.models.map(\.id) == ["gpt-6-sol"])
    #expect(parsed.models.first?.displayName == "GPT-6 Sol")
    #expect(parsed.models.first?.supportedReasoningEfforts == [.low, .medium, .high])
    #expect(parsed.nextCursor == "page-2")
}

@Test func codexModelListPagesThroughAppServerProtocol() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lima-codex-model-list-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("fake-codex")
    let requests = directory.appendingPathComponent("requests.log")
    let source = """
    #!/bin/sh
    IFS= read -r request || exit 2
    printf 'initialize: %s\\n' "$request" >> "\(requests.path)"
    case "$request" in *'"method":"initialize"'*) ;; *) exit 3 ;; esac
    echo accepted-initialize >> "\(requests.path)"
    echo '{"id":1,"result":{}}'
    IFS= read -r request || exit 4
    printf 'initialized: %s\\n' "$request" >> "\(requests.path)"
    case "$request" in *'"method":"initialized"'*) ;; *) exit 5 ;; esac
    IFS= read -r request || exit 6
    printf 'page1: %s\\n' "$request" >> "\(requests.path)"
    # JSONSerialization may escape the slash in model/list.
    case "$request" in *'"method":"model'*'list"'*) ;; *) exit 7 ;; esac
    echo '{"method":"codex/event/model-list-updated","params":{}}'
    echo '{"id":2,"result":{"data":[{"model":"gpt-first","displayName":"First","hidden":false}],"nextCursor":"page-2"}}'
    IFS= read -r request || exit 8
    printf 'page2: %s\\n' "$request" >> "\(requests.path)"
    case "$request" in *'"cursor":"page-2"'*) ;; *) exit 9 ;; esac
    echo '{"id":3,"result":{"data":[{"model":"gpt-second","displayName":"Second","hidden":false}],"nextCursor":null}}'
    """
    try source.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    do {
        let models = try await CodexModelDiscoveryService.listModels(executableURL: executable)
        #expect(models.map(\.id) == ["default", "gpt-first", "gpt-second"])
    } catch {
        let trace = (try? String(contentsOf: requests, encoding: .utf8)) ?? "No request trace"
        Issue.record("Fake app-server protocol: \(trace)")
        throw error
    }
}

@Test func codexModelListCancellationStopsWaitingAppServer() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lima-codex-model-cancel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("waiting-codex")
    let source = """
    #!/bin/sh
    IFS= read -r request || exit 2
    echo '{"id":1,"result":{}}'
    IFS= read -r request || exit 3
    IFS= read -r request || exit 4
    IFS= read -r request
    """
    try source.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    let discovery = Task { try await CodexModelDiscoveryService.listModels(executableURL: executable) }
    try await Task.sleep(for: .milliseconds(100))
    discovery.cancel()
    do {
        _ = try await discovery.value
        Issue.record("Cancelled Codex discovery unexpectedly returned a model catalog.")
    } catch {
        #expect(error is CancellationError)
    }
}

@Test func codexModelListTimeoutStopsWaitingAppServer() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lima-codex-model-timeout-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("waiting-codex")
    let source = """
    #!/bin/sh
    IFS= read -r request || exit 2
    echo '{"id":1,"result":{}}'
    IFS= read -r request || exit 3
    IFS= read -r request || exit 4
    IFS= read -r request
    """
    try source.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    do {
        _ = try await CodexModelDiscoveryService.listModels(executableURL: executable, timeout: 0.2)
        Issue.record("A nonresponding app-server unexpectedly returned a model catalog.")
    } catch {
        #expect(error as? CodexModelDiscoveryService.Failure == .unavailable)
    }
}

@Test func codexModelListEarlyExitCannotSignalTheApp() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lima-codex-model-exit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("exiting-codex")
    let source = """
    #!/bin/sh
    IFS= read -r request || exit 2
    echo '{"id":1,"result":{}}'
    exit 0
    """
    try source.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    do {
        _ = try await CodexModelDiscoveryService.listModels(executableURL: executable)
        Issue.record("An app-server that exits after initialization unexpectedly returned a catalog.")
    } catch {
        #expect(error is CodexModelDiscoveryService.Failure)
    }
}

@Test func codexModelListRejectsMalformedCatalog() {
    #expect(throws: CodexModelDiscoveryService.Failure.self) {
        _ = try CodexModelDiscoveryService.parseModelListResult(["models": []])
    }
}
