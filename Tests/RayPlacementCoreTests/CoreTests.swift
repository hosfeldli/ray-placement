import Foundation
import Testing
@testable import RayPlacementCore

@Test func SQLNetworkPortsUsePlainDigitsAndValidateRange() {
    #expect(SQLNetworkPort.parsePlainDigits("1521") == 1521)
    #expect(SQLNetworkPort.parsePlainDigits("1,521") == nil)
    #expect(SQLNetworkPort.parsePlainDigits("0") == nil)
    #expect(SQLNetworkPort.parsePlainDigits("65536") == nil)
}

@Test func OracleConnectionIdentifiersPreserveNormalOracleNameRules() {
    #expect(SQLOracleConnectionSyntax.identifier(for: "lima_test") == "lima_test")
    #expect(SQLOracleConnectionSyntax.identifier(for: "  APP_USER  ") == "APP_USER")
    #expect(SQLOracleConnectionSyntax.identifier(for: "Mixed Name") == "\"Mixed Name\"")
}

@Test func fuzzyMatching() {
    #expect(FuzzyMatcher.score("Visual Studio Code", query: "vsc") != nil)
    #expect(FuzzyMatcher.score("Calendar", query: "xyz") == nil)
}

@Test func visualSQLBuildsForeignKeyJoin() {
    let join = SQLJoinSuggestion(
        name: "fk_order_customer",
        fromTable: "ops.orders",
        fromColumn: "customer_id",
        toTable: "ops.customers",
        toColumn: "id"
    )
    let query = SQLVisualQuery(
        tables: ["ops.orders", "ops.customers"],
        projections: ["ops.orders.*", "ops.customers.name"],
        joins: [join],
        predicate: "ops.orders.status = 'OPEN'",
        limit: 50
    )
    let sql = query.sql(for: .mysql)
    #expect(sql.contains("JOIN ops.customers ON ops.orders.customer_id = ops.customers.id"))
    #expect(sql.contains("WHERE ops.orders.status = 'OPEN'"))
    #expect(sql.contains("LIMIT 50"))
}

@Test func schemaReturnsOnlyCompatibleForeignKeyJoins() {
    let key = SQLForeignKey(
        name: "fk_order_customer",
        sourceTable: "ops.orders",
        sourceColumn: "customer_id",
        destinationTable: "ops.customers",
        destinationColumn: "id"
    )
    let orders = SQLTable(schema: "ops", name: "orders", columns: [SQLColumn(name: "customer_id", dataType: "NUMBER", nullable: false, ordinal: 1)])
    let customers = SQLTable(schema: "ops", name: "customers", columns: [SQLColumn(name: "id", dataType: "NUMBER", nullable: false, ordinal: 1)])
    let snapshot = SQLSchemaSnapshot(profileID: UUID(), tables: [orders, customers], foreignKeys: [key])
    let joins = snapshot.joins(for: ["ops.orders"])
    #expect(joins.count == 1)
    #expect(joins.first?.toTable == "ops.customers")
    #expect(snapshot.joins(for: ["ops.orders", "ops.customers"]).isEmpty)

    let incomplete = SQLSchemaSnapshot(profileID: UUID(), tables: [orders, SQLTable(schema: "ops", name: "customers")], foreignKeys: [key])
    #expect(incomplete.joins(for: ["ops.orders"]).isEmpty)
}

@Test func schemaClutterFiltersCanBeConfiguredAndOverridden() {
    var profile = SQLConnectionProfile(name: "Test", environment: "Dev", driver: .oracle, host: "db", database: "svc", username: "user")
    let filter = SQLSchemaFilter(profile: profile)
    #expect(filter.isHidden(SQLTable(schema: "OPS", name: "TEMP_EXPORT")))
    #expect(filter.isHidden(SQLTable(schema: "OPS", name: "AB_ORDERS")))
    #expect(filter.isHidden(SQLTable(schema: "OPS", name: "ORDERS_X")))
    #expect(!filter.isHidden(SQLTable(schema: "OPS", name: "ORDERS")))
    #expect(!filter.isHidden(SQLTable(schema: "OPS", name: "_ORDERS")))
    #expect(!filter.isHidden(SQLTable(schema: "OPS", name: "ORDERS_")))

    profile.tableIncludeOverrides = ["OPS.AB_ORDERS"]
    profile.tableExclusionTerms = ["ARCHIVE"]
    let customized = SQLSchemaFilter(profile: profile)
    #expect(!customized.isHidden(SQLTable(schema: "OPS", name: "AB_ORDERS")))
    #expect(customized.isHidden(SQLTable(schema: "OPS", name: "ORDERS_ARCHIVE")))
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
    #expect(NotesWindowLayout.dockedFrame(edge: .right, visibleFrame: screen, preferredWidth: 100).width == 390)
    #expect(NotesWindowLayout.dockedFrame(edge: .right, visibleFrame: screen, preferredWidth: 900).width == 560)

    let clamped = NotesWindowLayout.clampedWorkspaceFrame(
        CGRect(x: -200, y: 600, width: 500, height: 900),
        visibleFrame: screen
    )
    #expect(clamped == CGRect(x: 0, y: 0, width: 800, height: 800))
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

@Test func dynamicFormFieldsDecodeConditionalLayout() throws {
    let data = #"""
    {
      "schemaVersion": 2,
      "id": "local.dynamic",
      "name": "Dynamic",
      "commands": [{
        "id": "flow",
        "title": "Flow",
        "action": {
          "type": "form",
          "value": "",
          "form": {
            "fields": [
              { "id": "mode", "label": "Mode", "type": "picker", "options": ["Simple", "Advanced"] },
              { "id": "path", "label": "Folder", "type": "directory", "section": "Input", "visibleWhen": { "field": "mode", "equals": "Advanced" } },
              { "id": "headers", "label": "Headers", "type": "keyValue", "helpText": "One pair per line" },
              { "id": "workers", "label": "Workers", "type": "slider", "minimum": 1, "maximum": 12 }
            ],
            "execution": { "type": "shell", "executable": "/usr/bin/true" }
          }
        }
      }]
    }
    """#.data(using: .utf8)!
    let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
    let fields = try #require(manifest.commands.first?.action.form?.fields)
    #expect(fields.map(\.type) == [.picker, .directory, .keyValue, .slider])
    #expect(fields[1].visibleWhen?.field == "mode")
    #expect(fields[1].visibleWhen?.equals == "Advanced")
    #expect(fields[3].maximum == 12)
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

@Test func securityToolsManifestDecodes() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let data = try Data(contentsOf: packageRoot.appendingPathComponent("Extensions/security-tools/manifest.json"))
    let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
    #expect(manifest.id == "local.security-tools")
    #expect(manifest.commands.map(\.action.type) == [.openPasswordGenerator])
}

@Test func focusedFileLauncherManifestDecodes() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let data = try Data(contentsOf: packageRoot.appendingPathComponent("Extensions/vscode-directories/manifest.json"))
    let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
    #expect(manifest.id == "local.focused-file-launcher")
    #expect(manifest.commands.count == 1)
    #expect(manifest.commands.first?.action.type == .openFocusedFileLauncher)
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

@Test func appManagementManifestDecodes() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let data = try Data(contentsOf: packageRoot.appendingPathComponent("Extensions/app-management/manifest.json"))
    let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
    #expect(manifest.id == "local.app-management")
    #expect(manifest.commands.map(\.action.type) == [.uninstallApplication])
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
    #expect(decoded.speakerNames.isEmpty)

    let favorite = MarkdownNote(title: "Favorite", isFavorite: true, speakerNames: [1: "Liam", 2: "Morgan"])
    let roundTrip = try JSONDecoder().decode(MarkdownNote.self, from: JSONEncoder().encode(favorite))
    #expect(roundTrip.isFavorite)
    #expect(roundTrip.speakerNames == [1: "Liam", 2: "Morgan"])
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
    #expect(MeetingDictationPlan.localWhisperSegmentDuration == 15)
    #expect(MeetingDictationPlan.appleSpeechSegmentDuration == 8)
    #expect(MeetingDictationPlan.maximumDuration >= 60 * 60)
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

@Test func markdownNotesSupportTagsWikiLinksAndTemplates() {
    #expect(MarkdownNoteLinks.normalizedTags([" #Work ", "work", "", "follow-up"]) == ["Work", "follow-up"])
    #expect(MarkdownNoteLinks.targets(in: "See [[Project Brief]] and [[abc]]; [[Project Brief]].") == ["Project Brief", "abc"])
    #expect(MarkdownNoteTemplate.meetingNotes.content.contains("## Action Items"))
    #expect(MarkdownNoteTemplate.projectBrief.content.contains("## Success Criteria"))
}

@Test func markdownNoteNewFieldsRemainBackwardCompatible() throws {
    let note = MarkdownNote(title: "New", tags: ["work"], revisionHistory: [NoteRevision(title: "Old", content: "Before")])
    let encoded = try JSONEncoder().encode(note)
    let decoded = try JSONDecoder().decode(MarkdownNote.self, from: encoded)
    #expect(decoded.tags == ["work"])
    #expect(decoded.revisionHistory.count == 1)
    #expect(decoded.revisionHistory.first?.content == "Before")
}

@Test func mediaDurationsNormalizeSpotifyMillisecondsAndAppleSeconds() {
    #expect(MediaDurationNormalization.seconds(from: 245_000, source: "spotify") == 245)
    #expect(MediaDurationNormalization.seconds(from: 125_000, source: "spotify") == 125)
    #expect(MediaDurationNormalization.seconds(from: 245, source: "appleMusic") == 245)
    #expect(MediaDurationNormalization.seconds(from: 0, source: "spotify") == 0)
    #expect(MediaDurationNormalization.seconds(from: 2_500_000, source: "appleMusic") == 2_500)
}

@Test func markdownNoteRemovesMalformedEmptyPlaceholdersButPreservesEditableTasks() {
    let source = """
    # Daily Plan

    - [ ] -
    - [ ]
    - [x] Finished work

    ## Done
    -

    ## Meaningful Done
    - Completed item
    """
    let normalized = MarkdownNote.normalizedContent(source)
    #expect(!normalized.contains("- [ ] -"))
    #expect(!normalized.contains("## Done"))
    #expect(normalized.contains("- [ ]"))
    #expect(normalized.contains("- [x] Finished work"))
    #expect(normalized.contains("## Meaningful Done"))
    #expect(normalized.contains("- Completed item"))
}

@Test func markdownBlockParserSkipsMalformedEmptyTaskRows() {
    let blocks = MarkdownBlockParser.parse(MarkdownNote.normalizedContent("- [ ] -\n- [ ]\n- [x] Done"))
    #expect(!blocks.contains(.task(checked: false, text: "-")))
    #expect(blocks.contains(.task(checked: false, text: "")))
    #expect(blocks.contains(.task(checked: true, text: "Done")))
}
