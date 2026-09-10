import Foundation
import Testing
@testable import RayPlacementCore

private func packageRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}


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

@Test func notesDockLayoutSupportsResponsiveWidthClasses() {
    let widthClasses: [(screenWidth: CGFloat, expectedDockWidth: CGFloat)] = [
        (320, 320),
        (420, 420),
        (600, 560),
        (900, 560)
    ]

    for widthClass in widthClasses {
        let visibleFrame = CGRect(x: 0, y: 0, width: widthClass.screenWidth, height: 800)
        let left = NotesWindowLayout.dockedFrame(
            edge: .left,
            visibleFrame: visibleFrame,
            preferredWidth: 900
        )
        let right = NotesWindowLayout.dockedFrame(
            edge: .right,
            visibleFrame: visibleFrame,
            preferredWidth: 900
        )

        #expect(left.width == widthClass.expectedDockWidth)
        #expect(right.width == widthClass.expectedDockWidth)
        #expect(left.minX == visibleFrame.minX)
        #expect(right.maxX == visibleFrame.maxX)
    }
}

@Test func semanticVersionsCompareReleaseTags() {
    #expect(SemanticVersion("v1.7.0") == SemanticVersion("1.7"))
    #expect(SemanticVersion("1.6.9")! < SemanticVersion("1.7.0")!)
    #expect(SemanticVersion("1.10.0")! > SemanticVersion("1.9.9")!)
    #expect(SemanticVersion("not-a-version") == nil)
}


@Test func extensionSecurityRejectsTraversalAndUnapprovedExternalExecutables() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lima-extension-security-\(UUID().uuidString)", isDirectory: true)
    let extensionDirectory = root.appendingPathComponent("Extension", isDirectory: true)
    try FileManager.default.createDirectory(at: extensionDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(throws: ExtensionSecurityError.traversalOutsideExtension) {
        try ExtensionSecurityPolicy.resolvePath("../outside.sh", relativeTo: extensionDirectory, capabilities: [.shell, .filesystem], executable: true)
    }
    #expect(throws: ExtensionSecurityError.externalExecutionNotApproved) {
        try ExtensionSecurityPolicy.resolvePath("/usr/bin/true", relativeTo: extensionDirectory, capabilities: [.shell, .filesystem], executable: true)
    }
    let external = try ExtensionSecurityPolicy.resolvePath("/usr/bin/true", relativeTo: extensionDirectory, capabilities: [.shell, .filesystem, .externalExecution], executable: true)
    #expect(external.path == "/usr/bin/true")
}

@Test func extensionSecurityRejectsSymlinkEscapeAndHashesManifestsDeterministically() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lima-extension-links-\(UUID().uuidString)", isDirectory: true)
    let extensionDirectory = root.appendingPathComponent("Extension", isDirectory: true)
    let outsideDirectory = root.appendingPathComponent("Outside", isDirectory: true)
    try FileManager.default.createDirectory(at: extensionDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let link = extensionDirectory.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideDirectory)
    #expect(throws: ExtensionSecurityError.traversalOutsideExtension) {
        try ExtensionSecurityPolicy.resolvePath("linked/file", relativeTo: extensionDirectory, capabilities: [.filesystem], executable: false)
    }

    let manifest = Data(#"{"id":"test","capabilities":["filesystem"]}"#.utf8)
    #expect(ExtensionSecurityPolicy.manifestHash(manifest) == ExtensionSecurityPolicy.manifestHash(manifest))
    #expect(ExtensionSecurityPolicy.manifestHash(manifest).count == 64)
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


@Test func canonicalBundledExtensionPacksDecodeWithStableMetadata() throws {
    let manifests = [
        ("Extensions/lima-essentials/manifest.json", "local.lima-essentials", "Lima Essentials", "Essentials"),
        ("Extensions/window-management/manifest.json", "local.window-management", "Window Management", "Window Management"),
        ("Extensions/system-controls/manifest.json", "local.system-controls", "System & Applications", "System Controls"),
        ("Extensions/writing-tools/manifest.json", "local.writing-tools", "Writing Tools", "Writing")
    ]

    for (relativePath, id, pack, category) in manifests {
        let manifest = try JSONDecoder().decode(
            ExtensionManifest.self,
            from: Data(contentsOf: packageRoot().appendingPathComponent(relativePath))
        )
        #expect(manifest.id == id)
        #expect(manifest.pack == pack)
        #expect(manifest.category == category)
        #expect(manifest.bundled)
        #expect(manifest.provenance == .bundled)
        #expect(manifest.trust == .bundled)
        #expect(manifest.version != nil)
    }
}

@Test func bundledCommandsUseGenericCapabilityActions() throws {
    let essentials = try JSONDecoder().decode(
        ExtensionManifest.self,
        from: Data(contentsOf: packageRoot().appendingPathComponent("Extensions/lima-essentials/manifest.json"))
    )
    #expect(essentials.commands.map { "\($0.action.type.rawValue):\($0.action.operation ?? "")" } == [
        "picker:emoji",
        "picker:file",
        "picker:timezone",
        "picker:password"
    ])

    let windows = try JSONDecoder().decode(
        ExtensionManifest.self,
        from: Data(contentsOf: packageRoot().appendingPathComponent("Extensions/window-management/manifest.json"))
    )
    #expect(windows.commands.count == 19)
    #expect(windows.commands.allSatisfy { $0.action.type == .window })
    #expect(windows.commands.contains { $0.action.operation == "restorePrevious" })
    #expect(windows.commands.contains { $0.action.operation == "nextDisplay" })

    let system = try JSONDecoder().decode(
        ExtensionManifest.self,
        from: Data(contentsOf: packageRoot().appendingPathComponent("Extensions/system-controls/manifest.json"))
    )
    #expect(system.commands.filter { $0.action.type == .application }.count == 4)
    #expect(system.commands.filter { $0.action.type == .system }.count == 6)
    #expect(system.commands.contains { $0.action.operation == "forceQuit" && $0.action.target == "picker" })
    #expect(system.commands.contains { $0.action.operation == "restart" && $0.action.confirmation == true })
}

@Test func bundledMaintenanceAndWritingCommandsUsePublicWorkspaceActions() throws {
    let maintenance = try JSONDecoder().decode(
        ExtensionManifest.self,
        from: Data(contentsOf: packageRoot().appendingPathComponent("Extensions/extension-maintenance/manifest.json"))
    )
    #expect(maintenance.pack == "Extension Maintenance")
    #expect(maintenance.commands.first?.action.type == .workspace)
    #expect(maintenance.commands.first?.action.operation == "repairExtensions")

    let writing = try JSONDecoder().decode(
        ExtensionManifest.self,
        from: Data(contentsOf: packageRoot().appendingPathComponent("Extensions/writing-tools/manifest.json"))
    )
    #expect(writing.commands.map { "\($0.action.type.rawValue):\($0.action.operation ?? "")" } == [
        "clipboard:pastePlainText",
        "workspace:writingReview"
    ])
}

@Test func emojiPickerManifestRetainsDoubleCommandShortcut() throws {
    let manifest = try JSONDecoder().decode(
        ExtensionManifest.self,
        from: Data(contentsOf: packageRoot().appendingPathComponent("Extensions/lima-essentials/manifest.json"))
    )
    let emoji = try #require(manifest.commands.first { $0.id == "emoji-picker" })
    #expect(emoji.action.type == .picker)
    #expect(emoji.action.operation == "emoji")
    #expect(ShortcutSpec(string: emoji.hotkey ?? "")?.displayString == "⌘ twice")
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

@Test func plainTextPastePreservesEmojiSequencesAndUnicode() {
    let text = "Emoji: 👨‍💻 ❤️ 🏳️‍🌈\n日本語 — café"

    #expect(PlainTextPastePolicy.normalize(text) == text)
    #expect(PlainTextPastePolicy.normalize("👩🏽‍🚀") == "👩🏽‍🚀")
}

@Test func plainTextPasteNormalizesOnlyLineEndings() {
    let text = "first\r\nsecond\rthird\n👨‍👩‍👧‍👦"

    #expect(PlainTextPastePolicy.normalize(text) == "first\nsecond\nthird\n👨‍👩‍👧‍👦")
}

@Test func singleLineTabbedProseIsNotConvertedToATable() {
    #expect(TabularDataParser.parse(text: "Owner\tStatus") == nil)
    #expect(TabularDataParser.parse(text: "hello, world") == nil)
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
    let data = try Data(contentsOf: packageRoot().appendingPathComponent("Extensions/document-formatter/manifest.json"))
    let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
    #expect(manifest.id == "local.document-formatter")
    #expect(manifest.commands.first?.action.type == .workspace)
    #expect(manifest.commands.first?.action.operation == "formatter")
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


@Test func extensionApprovalLifecycleRequiresNewApprovalMetadata() {
    let id = "test.approval.\(UUID().uuidString)"
    defer { ExtensionApprovalStore.revoke(extensionID: id) }
    let firstHash = String(repeating: "a", count: 64)
    let secondHash = String(repeating: "b", count: 64)
    ExtensionApprovalStore.approve(extensionID: id, manifestHash: firstHash, capabilities: [.shell])
    #expect(ExtensionApprovalStore.record(for: id)?.manifestHash == firstHash)
    #expect(ExtensionApprovalStore.record(for: id)?.capabilities == [.shell])
    ExtensionApprovalStore.approve(extensionID: id, manifestHash: secondHash, capabilities: [.shell, .externalExecution])
    #expect(ExtensionApprovalStore.record(for: id)?.manifestHash == secondHash)
    #expect(ExtensionApprovalStore.record(for: id)?.capabilities == [.shell, .externalExecution])
    ExtensionApprovalStore.revoke(extensionID: id)
    #expect(ExtensionApprovalStore.record(for: id) == nil)
}


@Test func workspaceStateIgnoresObsoletePersistedFieldsAndRoundTripsCurrentWorkspaces() throws {
    let legacyObject: [String: Any] = [
        "apiCollectionID": UUID().uuidString,
        "apiRequestID": UUID().uuidString,
        "apiEnvironmentID": UUID().uuidString,
        String(["sql", "Workspace"].joined()): "removed",
        "schemaVersion": 1,
        "windowFrames": [:]
    ]
    let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
    let legacy = try JSONDecoder().decode(WorkspaceState.self, from: legacyData)
    #expect(legacy.windowFrames.isEmpty)
    #expect(legacy.terminalSessionID == nil)

    let state = WorkspaceState(
        activeWorkspace: "terminal",
        notesSection: "favorites",
        selectedNoteID: UUID(),
        selectedDictationID: UUID(),
        terminalSessionID: UUID(),
        windowFrames: ["launcher": "{10, 20} 680 452"],
        dockMode: "right"
    )
    let decoded = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(state))
    #expect(decoded == state)
}

@Test func commandProfilesRemainBackwardCompatible() throws {
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
    #expect(throws: UpdateValidationError.wrongBundleIdentifier) {
        try UpdateVerificationPolicy.validateBundleIdentifier("com.example.OtherApp")
    }
    #expect(throws: UpdateValidationError.versionNotNewer) {
        try UpdateVerificationPolicy.validateNewerVersion("3.12.4", than: "3.12.4")
    }
    #expect(throws: UpdateValidationError.versionNotNewer) {
        try UpdateVerificationPolicy.validateNewerVersion("3.12.3", than: "3.12.4")
    }
    #expect(throws: UpdateValidationError.wrongCertificate) {
        try UpdateVerificationPolicy.validateSigningIdentity(
            certificateFingerprint: "bad", expectedCertificateFingerprint: "good",
            teamIdentifier: "TEAM", expectedTeamIdentifier: "TEAM",
            signingIdentity: "Developer ID Application: Lima", expectedSigningIdentity: "Developer ID Application: Lima"
        )
    }
    #expect(throws: UpdateValidationError.wrongTeamIdentifier) {
        try UpdateVerificationPolicy.validateSigningIdentity(
            certificateFingerprint: "good", expectedCertificateFingerprint: "good",
            teamIdentifier: "WRONG", expectedTeamIdentifier: "TEAM",
            signingIdentity: "Developer ID Application: Lima", expectedSigningIdentity: "Developer ID Application: Lima"
        )
    }
    #expect(throws: UpdateValidationError.wrongSigningIdentity) {
        try UpdateVerificationPolicy.validateSigningIdentity(
            certificateFingerprint: "good", expectedCertificateFingerprint: "good",
            teamIdentifier: "TEAM", expectedTeamIdentifier: "TEAM",
            signingIdentity: "Wrong Identity", expectedSigningIdentity: "Developer ID Application: Lima"
        )
    }
    #expect(throws: UpdateValidationError.buildMismatch) {
        try UpdateVerificationPolicy.validateManifest(version: "3.12.2", build: "3121", expectedVersion: "3.12.2", expectedBuild: "3122")
    }
}


@Test func currentWorkspaceStateIntegrationRoundTripsTerminalNotesAndFrames() throws {
    let state = WorkspaceState(
        activeWorkspace: "notes",
        notesSection: "all",
        selectedNoteID: UUID(),
        selectedDictationID: UUID(),
        terminalSessionID: UUID(),
        windowFrames: ["launcher": "{10, 20} 680 452", "notes": "{40, 50} 900 700"],
        dockMode: "left"
    )
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(WorkspaceState.self, from: data)
    #expect(decoded == state)
    #expect(decoded.activeWorkspace == "notes")
    #expect(decoded.terminalSessionID == state.terminalSessionID)
    #expect(decoded.windowFrames.count == 2)
}
