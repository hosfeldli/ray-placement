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

@Test func markdownNotesParseRichBlocks() {
    let markdown = """
    # Project plan

    Intro with **bold** text.

    - [x] Ship parser
    - Regular item
    2. Verify preview
    > Local and private

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
    #expect(blocks.contains(.code(language: "swift", text: "let ready = true")))
}

@Test func markdownNoteUsesContentWhenTitleIsBlank() {
    let note = MarkdownNote(title: "  ", content: "# Derived title\n\nBody")
    #expect(note.displayTitle == "Derived title")
    #expect(note.preview == "Derived title")
}

@Test func meetingDictationPlanCoversOneHourWithBoundedSegments() {
    let segments = MeetingDictationPlan.segments(for: 60 * 60)
    #expect(segments.count == 80)
    #expect(segments.first == MeetingDictationSegment(start: 0, duration: 45))
    #expect(segments.last == MeetingDictationSegment(start: 3_555, duration: 45))
    #expect(segments.allSatisfy { $0.duration > 0 && $0.duration <= 45 })
}

@Test func meetingDictationPlanBoundsStorageAndDuration() {
    let segments = MeetingDictationPlan.segments(for: 2 * 60 * 60)
    #expect(segments.count == 80)
    #expect(MeetingDictationPlan.estimatedEncodedByteCount(for: 60 * 60) == 14_400_000)
}
