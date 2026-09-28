import Foundation
import Testing
@testable import RayPlacement

@Test func progressiveEnterReservesReturnForMultilineEditingAndModifiedShortcuts() {
    #expect(LimaProgressiveEnter.action(
        isReturnKey: true,
        hasNonPrimaryModifiers: false,
        isEditingMultilineText: false
    ) == .performPrimaryAction)
    #expect(LimaProgressiveEnter.action(
        isReturnKey: true,
        hasNonPrimaryModifiers: false,
        isEditingMultilineText: true
    ) == .passthrough)
    #expect(LimaProgressiveEnter.action(
        isReturnKey: true,
        hasNonPrimaryModifiers: true,
        isEditingMultilineText: false
    ) == .passthrough)
    #expect(LimaProgressiveEnter.action(
        isReturnKey: false,
        hasNonPrimaryModifiers: false,
        isEditingMultilineText: false
    ) == .passthrough)
}

@Test func launcherSurfacesAndExtensionsExposeOnePrimaryAction() {
    let formatter = LauncherSurfaceDescriptor(
        id: "formatter",
        title: "Formatter",
        kind: .textEditor,
        primaryActionTitle: "Format"
    )
    #expect(formatter.primaryAction == LimaPrimaryAction(title: "Format"))
    #expect(formatter.primaryActionTitle == "Format")

    let form = ExtensionSurfaceSession(
        id: "example.form",
        title: "Example Form",
        kind: .form,
        preferredHeight: 400,
        canPopOut: false
    )
    let generator = ExtensionSurfaceSession(
        id: "example.generator",
        title: "Example Generator",
        kind: .generator,
        preferredHeight: 400,
        canPopOut: false
    )
    #expect(form.primaryAction == LimaPrimaryAction(title: "Run", symbol: "play.fill"))
    #expect(generator.primaryAction == LimaPrimaryAction(title: "Copy", symbol: "doc.on.doc"))
}

@Test @MainActor func passwordGeneratorOnlyEnablesCopyForGeneratedValues() {
    let suite = "ProgressiveEnterTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        Issue.record("Could not create isolated test defaults")
        return
    }
    defer { defaults.removePersistentDomain(forName: suite) }

    let model = PasswordGeneratorModel(defaults: defaults)
    #expect(model.canCopy)
    model.password = "Unable to generate securely"
    #expect(!model.canCopy)
}
