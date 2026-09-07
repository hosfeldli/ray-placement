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

@Test func updateArchivePolicyRejectsUnsafeAndUnexpectedRoots() throws {
    try UpdateVerificationPolicy.validateArchiveEntries([
        "LimaUpdate/",
        "LimaUpdate/Package.swift",
        "LimaUpdate/Packaging/Info.plist"
    ])
    #expect(throws: UpdateValidationError.invalidEntry("../Package.swift")) {
        try UpdateVerificationPolicy.validateArchiveEntries(["../Package.swift"])
    }
    #expect(throws: UpdateValidationError.invalidEntry("OtherRoot/file")) {
        try UpdateVerificationPolicy.validateArchiveEntries(["OtherRoot/file"])
    }
    #expect(throws: UpdateValidationError.emptyArchive) {
        try UpdateVerificationPolicy.validateArchiveEntries([])
    }
}

@Test func updatePackagePolicyRequiresMatchingVersionAndBuild() throws {
    try UpdateVerificationPolicy.validatePackage(
        packagedVersion: "3.12.2",
        expectedVersion: "v3.12.2",
        packagedBuild: "3122",
        expectedBuild: "3122"
    )
    #expect(throws: UpdateValidationError.versionMismatch) {
        try UpdateVerificationPolicy.validatePackage(packagedVersion: "3.12.1", expectedVersion: "3.12.2")
    }
    #expect(throws: UpdateValidationError.buildMismatch) {
        try UpdateVerificationPolicy.validatePackage(packagedVersion: "3.12.2", expectedVersion: "3.12.2", packagedBuild: "3121", expectedBuild: "3122")
    }
    #expect(throws: UpdateValidationError.buildMismatch) {
        try UpdateVerificationPolicy.validatePackage(packagedVersion: "3.12.2", expectedVersion: "3.12.2", expectedBuild: "3122")
    }
}

@Test func authorizationSecretReferenceIsBackwardCompatible() throws {
    let id = UUID()
    let authorization = PostmanAuthorization(kind: .bearer, values: ["token": "ignored-placeholder"], secretReferenceID: id)
    let data = try JSONEncoder().encode(authorization)
    let decoded = try JSONDecoder().decode(PostmanAuthorization.self, from: data)
    #expect(decoded.secretReferenceID == id)
    #expect(decoded.kind == .bearer)

    let oldData = #"{"kind":"bearer","values":{"token":"legacy"}}"#.data(using: .utf8)!
    let legacy = try JSONDecoder().decode(PostmanAuthorization.self, from: oldData)
    #expect(legacy.secretReferenceID == nil)
    #expect(legacy.values["token"] == "legacy")
}

@Test func workspaceStateAndProfilesDecodeLegacyData() throws {
    let oldState = #"{"schemaVersion":1,"windowFrames":{}}"#.data(using: .utf8)!
    let state = try JSONDecoder().decode(WorkspaceState.self, from: oldState)
    #expect(state.apiCollectionID == nil)
    #expect(state.windowFrames.isEmpty)

    let oldProfile = #"{"id":"00000000-0000-0000-0000-000000000001","name":"Default","favoriteCommandIDs":[]}"#.data(using: .utf8)!
    let profile = try JSONDecoder().decode(CommandProfile.self, from: oldProfile)
    #expect(profile.name == "Default")
    #expect(profile.favoriteCommandOrder.isEmpty)
}


@Test func updateFaultInjectionRejectsEveryUnsafePackageCondition() throws {
    #expect(throws: UpdateValidationError.invalidEntryType("LimaUpdate/link")) {
        try UpdateVerificationPolicy.validateArchiveTypes([(path: "LimaUpdate/link", type: .symbolicLink)])
    }
    #expect(throws: UpdateValidationError.missingRequiredFile("Packaging/Info.plist")) {
        try UpdateVerificationPolicy.validateRequiredFiles(["Package.swift"], required: ["Package.swift", "Packaging/Info.plist"])
    }
    #expect(throws: UpdateValidationError.invalidSignature) {
        try UpdateVerificationPolicy.validateSignature(isValid: false)
    }
    #expect(throws: UpdateValidationError.buildMismatch) {
        try UpdateVerificationPolicy.validateManifest(version: "3.12.2", build: "3121", expectedVersion: "3.12.2", expectedBuild: "3122")
    }
}

@Test func applicationStateIntegrationRoundTripsSearchAndWorkspaceSelection() throws {
    let collectionID = UUID()
    let requestID = UUID()
    let state = WorkspaceState(
        apiCollectionID: collectionID,
        apiRequestID: requestID,
        apiEnvironmentID: UUID(),
        terminalSessionID: UUID(),
        windowFrames: ["launcher": "{10, 20} 680 452"]
    )
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(WorkspaceState.self, from: data)
    #expect(decoded == state)
    #expect(decoded.apiCollectionID == collectionID)
    #expect(decoded.apiRequestID == requestID)
}
