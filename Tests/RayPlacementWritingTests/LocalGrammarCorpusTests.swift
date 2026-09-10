import Foundation
import Testing

@Test func localGrammarRegressionCorpus() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let checker = repository
        .appendingPathComponent("Packaging/Vendor/PythonGrammar/grammar_check.py")

    let cases: [(String, String)] = [
        ("u really is a great", "You really are a great"),
        ("Hi; whot where you thinking, about", "Hi, what were you thinking about?"),
        ("A user opened a URL.", "A user opened a URL."),
        ("The EDI/TMS job writes to /Users/liam/project/config.json.", "The EDI/TMS job writes to /Users/liam/project/config.json."),
        ("Already-correct prose stays unchanged.", "Already-correct prose stays unchanged."),
        ("Run `swift test` before release.", "Run `swift test` before release."),
    ]

    for (source, expected) in cases {
        let payload: [String: String] = [
            "text": source,
            "preserve": "Lima EDI TMS URL"
        ]
        let input = try JSONSerialization.data(withJSONObject: payload)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [checker.path]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(input)
        stdin.fileHandleForWriting.closeFile()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(String(data: output, encoding: .utf8) == expected)
    }
}
