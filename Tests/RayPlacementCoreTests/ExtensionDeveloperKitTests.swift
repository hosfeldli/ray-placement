import Foundation
import Testing
@testable import RayPlacementCore

private func kitDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LimaKit-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func extensionKitCreatesWorkingV3StartersWithoutOverwritingFiles() throws {
    let root = try kitDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    for template in ExtensionDeveloperKit.Template.allCases {
        let directory = root.appendingPathComponent(template.rawValue)
        let result = try ExtensionDeveloperKit.create(at: directory, id: "local.fixture.\(template.rawValue)", name: "Fixture", template: template)
        #expect(result.isValid)
        #expect(result.manifest?.schemaVersion == 3)
        #expect(result.manifest?.commands.count == (template == .aiTool ? 0 : 1))
        if template == .aiTool { #expect(result.manifest?.contributions.tools.first?.isEligibleForReadOnlyHostAdapter == true) }
        let original = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        #expect(throws: (any Error).self) { try ExtensionDeveloperKit.create(at: directory, id: "replacement", name: "Replacement", template: template) }
        #expect(try Data(contentsOf: directory.appendingPathComponent("manifest.json")) == original)
        if [.script, .form].contains(template) { #expect(FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("bin/run").path)) }
    }
}

@Test func extensionKitGivesActionableDiagnosticsAndNeverExecutesInspection() throws {
    let root = try kitDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("script")
    let inspection = try ExtensionDeveloperKit.create(at: directory, id: "local.inspect", name: "Inspect", template: .script)
    var manifest = try #require(inspection.manifest)
    manifest.capabilities = []
    manifest.commands.append(manifest.commands[0])
    try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
    let result = ExtensionDeveloperKit.inspect(directory)
    #expect(!result.isValid)
    #expect(result.diagnostics.contains { $0.message.contains("Missing permissions") })
    #expect(result.diagnostics.contains { $0.path.hasSuffix(".id") })
    #expect(result.diagnostics.allSatisfy { !$0.fix.isEmpty })
    try #"{"schemaVersion":3,"id":"broken","name":"Broken","commands":[{"id":"go","title":"Go","action":{"type":"not-a-real-action"}}]}"#.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    #expect(ExtensionDeveloperKit.inspect(directory).diagnostics.first?.path.contains("type") == true)
}

@Test func extensionKitChecksFormReferencesSurfaceAndExecutableBoundaries() throws {
    let root = try kitDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("form")
    let result = try ExtensionDeveloperKit.create(at: directory, id: "local.form", name: "Form", template: .form)
    var manifest = try #require(result.manifest)
    manifest.commands[0].action.form?.execution.arguments = ["{{unknown_field}}"]
    manifest.commands[0].presentation = .background
    manifest.commands[0].action.form?.execution.executable = "../escape"
    try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
    let errors = ExtensionDeveloperKit.inspect(directory).diagnostics
    #expect(errors.contains { $0.message.contains("Unknown field") })
    #expect(errors.contains { $0.message.contains("background") })
    #expect(errors.contains { $0.fix.contains("inside this extension") })
}

@Test func extensionKitCopiesVisibleFilesPreservesPermissionsAndRollsBackLinks() throws {
    let root = try kitDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    _ = try ExtensionDeveloperKit.create(at: source, id: "local.copy", name: "Copy", template: .script)
    try "not exported".write(to: source.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    let destination = root.appendingPathComponent("copy")
    try ExtensionDeveloperKit.copyPackage(from: source, to: destination)
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent(".env").path))
    #expect(FileManager.default.isExecutableFile(atPath: destination.appendingPathComponent("bin/run").path))
    try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("linked"), withDestinationURL: root)
    let rejected = root.appendingPathComponent("rejected")
    #expect(throws: (any Error).self) { try ExtensionDeveloperKit.copyPackage(from: source, to: rejected) }
    #expect(!FileManager.default.fileExists(atPath: rejected.path))
}

@Test func extensionKitMigratesOnlyKnownLegacyCommandKeysAndPreservesChoices() {
    let command = LoadedExtensionCommand(extensionID: "local.tools", extensionName: "Tools", directory: URL(fileURLWithPath: "/tmp"), command: .init(id: "run", title: "Run", action: .init(type: .clipboard, value: "fixture")))
    let profile = CommandProfile(name: "Personal", enabledCommandIDs: ["local.tools.run", "builtin.notes"], disabledCommandIDs: ["local.tools.run"], favoriteCommandIDs: ["local.tools.run"], favoriteCommandOrder: ["local.tools.run", "extension.local.tools.run", "unrelated"], confirmationRequiredCommandIDs: ["local.tools.run"])
    let result = ExtensionDeveloperKit.migrateProfile(profile, commands: [command])
    #expect(result.enabledCommandIDs == ["extension.local.tools.run", "builtin.notes"])
    #expect(result.disabledCommandIDs == [command.launcherIdentifier])
    #expect(result.favoriteCommandOrder == [command.launcherIdentifier, "unrelated"])
    #expect(result.confirmationRequiredCommandIDs == [command.launcherIdentifier])
    #expect(ExtensionDeveloperKit.migrateProfile(result, commands: [command]) == result)
}

@Test func extensionTemplatesNeverReinterpretValuesAsMoreTemplates() {
    #expect(ExtensionTemplate.render("Message: {{message}} · {{other}}", values: ["message": "{{other}}; echo literal", "other": "value"]) == "Message: {{other}}; echo literal · value")
}

@Test func extensionKitRejectsMisspelledFieldsInsteadOfSilentlyDroppingThem() throws {
    let root = try kitDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("package")
    _ = try ExtensionDeveloperKit.create(at: folder, id: "local.typo", name: "Typo", template: .link)
    let url = folder.appendingPathComponent("manifest.json")
    var body = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    body["permisisons"] = ["network"]
    try JSONSerialization.data(withJSONObject: body).write(to: url)
    let check = ExtensionDeveloperKit.inspect(folder)
    #expect(!check.isValid)
    #expect(check.diagnostics.contains { $0.path == "permisisons" && $0.message.contains("Unknown field") })
}
