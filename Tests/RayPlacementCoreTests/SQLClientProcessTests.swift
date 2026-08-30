import Foundation
import Testing
@testable import RayPlacementCore

@Test func oracleCatalogCSVPreservesLongDefaultsAndQuotedFields() {
    let result = SQLOracleOutput.parse("Connected.\n\"NAME\"|\"DEFAULT\"|\"POSITION\"\n\"a|b\"|\"line one\nline \"\"two\"\"\"|1\n\"empty\"||2\n")
    #expect(result.columns == ["NAME", "DEFAULT", "POSITION"])
    #expect(result.rows == [["a|b", "line one\nline \"two\"", "1"], ["empty", "", "2"]])
}

@Test func sqlClientDrainsLargeStdoutAndStderrWithoutDeadlocking() throws {
    let client = Process()
    client.executableURL = URL(fileURLWithPath: "/bin/zsh")
    client.arguments = ["-c", "head -c 1048576 /dev/zero; head -c 1048576 /dev/zero >&2"]
    let result = try SQLClientProcess.run(client, input: Data(), timeout: 10)
    #expect(result.stdout.count == 1_048_576)
    #expect(result.stderr.count == 1_048_576)
    #expect(client.terminationStatus == 0)
}

@Test func sqlClientTimesOutAnUnresponsiveClient() throws {
    let client = Process()
    client.executableURL = URL(fileURLWithPath: "/bin/sleep")
    client.arguments = ["30"]
    #expect(throws: SQLClientProcess.Timeout.self) {
        try SQLClientProcess.run(client, input: Data(), timeout: 0.1)
    }
    #expect(!client.isRunning)
}
