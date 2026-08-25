import Foundation
import Testing
@testable import RayPlacementCore

@Test func fuzzyMatching() {
    #expect(FuzzyMatcher.score("Visual Studio Code", query: "vsc") != nil)
    #expect(FuzzyMatcher.score("Calendar", query: "xyz") == nil)
}

@Test func calculatorPrecedenceAndParentheses() throws {
    #expect(try Calculator.evaluate("2 + 3 * 4") == 14)
    #expect(try Calculator.evaluate("(2 + 3) * 4") == 20)
    #expect(try Calculator.evaluate("2 ^ 3 ^ 2") == 512)
}

@Test func shortcutParsing() {
    let shortcut = ShortcutSpec(string: "option+shift+d")
    #expect(shortcut?.displayString == "⌥⇧D")
    #expect(shortcut?.storageString == "option+shift+d")
    #expect(ShortcutSpec(string: "control+kc12:q")?.displayString == "⌃Q")
    #expect(ShortcutSpec(string: "control+kc-1:q") == nil)
    #expect(ShortcutSpec(string: "control+kc128:q") == nil)
    #expect(ShortcutSpec(string: "control+kc4294967296:q") == nil)
    #expect(ShortcutSpec(string: "control+kc12:") == nil)
    #expect(ShortcutSpec(string: "command+command")?.displayString == "⌘ twice")
}

@Test func notesDockLayoutPinsToEitherVisibleScreenEdge() {
    let screen = CGRect(x: 100, y: 40, width: 1_440, height: 860)
    let left = NotesWindowLayout.dockedFrame(edge: .left, visibleFrame: screen, preferredWidth: 420)
    let right = NotesWindowLayout.dockedFrame(edge: .right, visibleFrame: screen, preferredWidth: 420)

    #expect(left == CGRect(x: 100, y: 40, width: 420, height: 860))
    #expect(right == CGRect(x: 1_120, y: 40, width: 420, height: 860))
}

@Test func notesDockLayoutBoundsWidthAndWorkspaceFrame() {
    let screen = CGRect(x: 0, y: 0, width: 1_200, height: 800)
    #expect(NotesWindowLayout.dockedFrame(edge: .right, visibleFrame: screen, preferredWidth: 100).width == 340)
    #expect(NotesWindowLayout.dockedFrame(edge: .right, visibleFrame: screen, preferredWidth: 900).width == 560)

    let clamped = NotesWindowLayout.clampedWorkspaceFrame(
        CGRect(x: -200, y: 600, width: 500, height: 900),
        visibleFrame: screen
    )
    #expect(clamped == CGRect(x: 0, y: 0, width: 720, height: 800))
}

@Test func semanticVersionsCompareReleaseTags() {
    #expect(SemanticVersion("v1.7.0") == SemanticVersion("1.7"))
    #expect(SemanticVersion("1.6.9")! < SemanticVersion("1.7.0")!)
    #expect(SemanticVersion("1.10.0")! > SemanticVersion("1.9.9")!)
    #expect(SemanticVersion("not-a-version") == nil)
}

@Test func manifestDecoding() throws {
    let data = #"{"schemaVersion":1,"id":"dev.test","name":"Test","commands":[{"id":"site","title":"Open Site","action":{"type":"url","value":"https://example.com"}}]}"#.data(using: .utf8)!
    let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
    #expect(manifest.commands.first?.action.type == .url)
}

@Test func exampleManifestDecodes() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let data = try Data(contentsOf: packageRoot.appendingPathComponent("Examples/project-tools/manifest.json"))
    let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
    #expect(manifest.id == "local.project-tools")
    #expect(manifest.commands.count == 3)
    #expect(manifest.commands.contains { $0.action.type == .shell })
}

@Test func endpointFormManifestDecodesAndRendersTemplates() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let data = try Data(contentsOf: packageRoot.appendingPathComponent("Extensions/endpoint-tester/manifest.json"))
    let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
    let command = try #require(manifest.commands.first)
    let form = try #require(command.action.form)
    #expect(manifest.schemaVersion == 2)
    #expect(command.action.type == .form)
    #expect(form.fields.contains { $0.id == "url" && $0.required == true })
    #expect(ExtensionTemplate.render("{{method}} {{url}}", values: ["method": "GET", "url": "https://example.com"]) == "GET https://example.com")
}

@Test func writingToolsManifestDecodes() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let data = try Data(contentsOf: packageRoot.appendingPathComponent("Extensions/writing-tools/manifest.json"))
    let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
    #expect(manifest.id == "local.writing-tools")
    #expect(manifest.commands.map(\.action.type) == [.pastePlainText, .checkWriting])
}

@Test func vscodeDirectoriesManifestDecodes() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let data = try Data(contentsOf: packageRoot.appendingPathComponent("Extensions/vscode-directories/manifest.json"))
    let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
    #expect(manifest.id == "local.vscode-directories")
    #expect(manifest.commands.count == 1)
    #expect(manifest.commands.first?.action.type == .openInVSCode)
    #expect(manifest.commands.allSatisfy { $0.hotkey == nil })
}

@Test func productivityToolsManifestDecodes() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let data = try Data(contentsOf: packageRoot.appendingPathComponent("Extensions/productivity-tools/manifest.json"))
    let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
    #expect(manifest.id == "local.productivity-tools")
    #expect(manifest.commands.map(\.action.type) == [.convertTimezones, .forceQuitApplications, .forceQuitAllApplications])
    #expect(manifest.commands.allSatisfy { $0.hotkey == nil })
}

@Test func emojiPickerManifestDecodesWithDoubleCommand() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let data = try Data(contentsOf: packageRoot.appendingPathComponent("Extensions/emoji-picker/manifest.json"))
    let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
    #expect(manifest.id == "local.emoji-picker")
    #expect(manifest.commands.map(\.action.type) == [.openEmojiPicker])
    #expect(ShortcutSpec(string: manifest.commands.first?.hotkey ?? "")?.displayString == "⌘ twice")
}

@Test func timezoneConversionRespectsDaylightSavingTime() throws {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let reference = utc.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 12))!
    let result = try #require(TimezoneConverter.convert(
        "9:30 AM",
        from: "America/New_York",
        to: "Europe/London",
        now: reference
    ))
    #expect(result.sourceTime == "9:30 AM")
    #expect(result.destinationTime == "2:30 PM")
    #expect(result.destinationZone == "GMT+1")
}

@Test func timezoneConversionHandlesDateRollover() throws {
    let result = try #require(TimezoneConverter.convert(
        "2026-01-02 09:00",
        from: "Asia/Tokyo",
        to: "America/Los_Angeles"
    ))
    #expect(result.destinationTime == "4:00 PM")
    #expect(result.destinationDate == "Thursday, Jan 1")
}

@Test func markdownNotesParseRichBlocks() {
    let markdown = """
    # Project plan

    Intro with **bold** text.

    - [x] Ship parser
    - Regular item
    2. Verify preview
    > Local and private

    | Owner | Status | Target |
    | :--- | :---: | ---: |
    | Maya | Ready | Friday |

    ```swift
    let ready = true
    ```
    """
    let blocks = MarkdownBlockParser.parse(markdown)
    #expect(blocks.contains(.heading(level: 1, text: "Project plan")))
    #expect(blocks.contains(.task(checked: true, text: "Ship parser")))
    #expect(blocks.contains(.bullet("Regular item")))
    #expect(blocks.contains(.numbered(number: 2, text: "Verify preview")))
    #expect(blocks.contains(.quote("Local and private")))
    #expect(blocks.contains(.table(
        headers: ["Owner", "Status", "Target"],
        alignments: [.leading, .center, .trailing],
        rows: [["Maya", "Ready", "Friday"]]
    )))
    #expect(blocks.contains(.code(language: "swift", text: "let ready = true")))
}

@Test func tabularPasteParsesSpreadsheetMarkdownCSVAndHTML() {
    #expect(TabularDataParser.parse(text: "Owner\tStatus\nMaya\tReady") == TabularData(rows: [
        ["Owner", "Status"], ["Maya", "Ready"]
    ]))
    #expect(TabularDataParser.parse(text: "| Owner | Status |\n| --- | --- |\n| Maya | Ready |") == TabularData(rows: [
        ["Owner", "Status"], ["Maya", "Ready"]
    ]))
    #expect(TabularDataParser.parse(text: "Owner,Status\n\"Maya, Sr.\",Ready") == TabularData(rows: [
        ["Owner", "Status"], ["Maya, Sr.", "Ready"]
    ]))
    #expect(TabularDataParser.parse(
        text: "Owner Status",
        html: "<table><tr><th>Owner</th><th>Status</th></tr><tr><td>Maya</td><td>Ready</td></tr></table>"
    ) == TabularData(rows: [["Owner", "Status"], ["Maya", "Ready"]]))
}

@Test func markdownNoteUsesContentWhenTitleIsBlank() {
    let note = MarkdownNote(title: "  ", content: "# Derived title\n\nBody")
    #expect(note.displayTitle == "Derived title")
    #expect(note.preview == "Derived title")
}

@Test func markdownNoteFavoritePersistsAndOldNotesRemainCompatible() throws {
    struct LegacyNote: Encodable {
        let id: UUID
        let title: String
        let content: String
        let createdAt: Date
        let modifiedAt: Date
        let isPinned: Bool
    }

    let identifier = UUID()
    let timestamp = Date(timeIntervalSinceReferenceDate: 123)
    let legacy = LegacyNote(
        id: identifier,
        title: "Legacy",
        content: "Body",
        createdAt: timestamp,
        modifiedAt: timestamp,
        isPinned: true
    )
    let decoded = try JSONDecoder().decode(MarkdownNote.self, from: JSONEncoder().encode(legacy))
    #expect(decoded.id == identifier)
    #expect(decoded.isPinned)
    #expect(!decoded.isFavorite)

    let favorite = MarkdownNote(title: "Favorite", isFavorite: true)
    let roundTrip = try JSONDecoder().decode(MarkdownNote.self, from: JSONEncoder().encode(favorite))
    #expect(roundTrip.isFavorite)
}

@Test func meetingDictationPlanCoversOneHourWithBoundedSegments() {
    let segments = MeetingDictationPlan.segments(for: 60 * 60)
    #expect(segments.count == 80)
    #expect(segments.first == MeetingDictationSegment(start: 0, duration: 45))
    #expect(segments.last == MeetingDictationSegment(start: 3_555, duration: 45))
    #expect(segments.allSatisfy { $0.duration > 0 && $0.duration <= 45 })
}

@Test func meetingDictationPlanBoundsStorageAndDuration() {
    let segments = MeetingDictationPlan.segments(for: 3 * 60 * 60)
    #expect(segments.count == 160)
    #expect(MeetingDictationPlan.estimatedEncodedByteCount(for: 60 * 60) == 115_200_000)
    #expect(MeetingDictationPlan.estimatedEncodedByteCount(for: 3 * 60 * 60) == 230_400_000)
}

@Test func meetingDictationUsesShortRollingAudioSegments() {
    #expect(MeetingDictationPlan.localWhisperSegmentDuration == 60)
    #expect(MeetingDictationPlan.appleSpeechSegmentDuration == 45)
    #expect(MeetingDictationPlan.maximumDuration >= 60 * 60)
}

@Test func noteSummaryPlanPreservesAllTextWithinBoundedChunks() {
    let source = String(repeating: "alpha ", count: 1_300) + "\n\nDecision: ship Friday."
    let chunks = NoteSummaryPlan.chunks(source)
    #expect(chunks.count == 3)
    #expect(chunks.allSatisfy { $0.count <= NoteSummaryPlan.maximumChunkCharacters })
    #expect(chunks.joined().replacingOccurrences(of: "\n\n", with: "") == source.replacingOccurrences(of: "\n\n", with: ""))
}

@Test func documentFormatterPrettyPrintsAndInspectsJSON() throws {
    let result = try DocumentFormatterService.format(#"{"b":2,"a":{"ready":true}}"#, kind: .json)
    #expect(result.isValid)
    #expect(result.output.contains("\n"))
    #expect(result.output.range(of: #""a""#)!.lowerBound < result.output.range(of: #""b""#)!.lowerBound)
    #expect(result.inspection.contains { $0.contains("$.a.ready") })
    #expect(DocumentFormatterService.search("ready", in: result.output) == [3])
}

@Test func documentFormatterValidatesAndMinifiesXML() throws {
    let result = try DocumentFormatterService.format("<root>\n  <item id=\"1\">x</item>\n</root>", kind: .xml, style: .minified)
    #expect(result.isValid)
    #expect(result.output.contains("<item id=\"1\">x</item>"))
    #expect(!result.output.contains("\n  "))
    #expect(result.inspection.contains { $0.contains("/root/item[1]") })
}

@Test func ediFormatterDetectsDelimitersFieldsAndEnvelopeErrors() throws {
    let edi = "ST*214*0001~B10*REF*SHIP*CARRIER~AT7*X3*NS***20260823*1200*ET~SE*4*0001~"
    let result = try DocumentFormatterService.format(edi, kind: .edi, ediSegmentDelimiter: "\n")
    #expect(result.kind == .edi)
    #expect(result.edi?.elementDelimiter == "*")
    #expect(result.edi?.segmentDelimiter == "~")
    #expect(result.edi?.transactionSets == ["214"])
    #expect(result.output.components(separatedBy: "\n").count == 4)
    #expect(result.edi?.fields.contains { $0.path == "B1001" && $0.value == "REF" } == true)
    #expect(result.diagnostics.contains { $0.message.contains("passed") })
}

@Test func ediFormatterReportsControlAndCountProblems() throws {
    let edi = "ST*990*A~B1*X*Y~SE*9*B~"
    let result = try DocumentFormatterService.format(edi, kind: .edi)
    #expect(!result.isValid)
    #expect(result.diagnostics.contains { $0.location == "ST02 / SE02" })
    #expect(result.diagnostics.contains { $0.location == "SE01" })
    #expect(result.diagnostics.contains { $0.message.contains("(A)") && $0.message.contains("B") })
    #expect(result.diagnostics.contains { $0.message.contains("3 segments") && $0.message.contains("9") })
}

@Test func documentFormatterManifestDecodes() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let data = try Data(contentsOf: packageRoot.appendingPathComponent("Extensions/document-formatter/manifest.json"))
    let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
    #expect(manifest.id == "local.document-formatter")
    #expect(manifest.commands.map(\.action.type) == [.openFormatterWorkspace])
}
