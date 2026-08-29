import AppKit
import Security
import SwiftUI

@MainActor
final class PasswordGeneratorWindowController: NSWindowController {
    private let model = PasswordGeneratorModel()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 430),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Password Generator"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 520, height: 360)
        window.setAccessibilityLabel("RayPlacement password generator")
        self.init(window: window)
        window.contentView = NSHostingView(rootView: PasswordGeneratorView(model: model))
    }

    func present() {
        model.generate()
        window?.center()
        if let window { WorkspaceWindowCoordinator.shared.present(window) }
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class PasswordGeneratorModel: ObservableObject {
    @Published var password = ""
    @Published var length = 24
    @Published var lowercase = true
    @Published var uppercase = true
    @Published var numbers = true
    @Published var symbols = true
    @Published var excludeAmbiguous = true
    @Published var copied = false

    var entropyBits: Int {
        guard characterSet.count > 1 else { return 0 }
        return Int((Double(length) * log2(Double(characterSet.count))).rounded())
    }

    var strength: String {
        switch entropyBits {
        case 0..<50: return "Weak"
        case 50..<80: return "Good"
        case 80..<120: return "Strong"
        default: return "Excellent"
        }
    }

    func generate() {
        let groups = enabledGroups
        guard !groups.isEmpty else {
            password = "Select at least one character set"
            return
        }
        let count = max(length, groups.count)
        var values = groups.compactMap { secureCharacter(from: $0) }
        let all = groups.flatMap { $0 }
        while values.count < count, let character = secureCharacter(from: all) { values.append(character) }
        secureShuffle(&values)
        password = String(values.prefix(count))
        copied = false
    }

    func copy() {
        guard !password.isEmpty, !password.hasPrefix("Select") else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(password, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.copied = false }
    }

    private var enabledGroups: [[Character]] {
        var groups: [[Character]] = []
        if lowercase { groups.append(Array(filtered("abcdefghijklmnopqrstuvwxyz"))) }
        if uppercase { groups.append(Array(filtered("ABCDEFGHIJKLMNOPQRSTUVWXYZ"))) }
        if numbers { groups.append(Array(filtered("0123456789"))) }
        if symbols { groups.append(Array("!@#$%^&*()-_=+[]{};:,.?/")) }
        return groups.filter { !$0.isEmpty }
    }

    private var characterSet: [Character] { enabledGroups.flatMap { $0 } }

    private func filtered(_ input: String) -> String {
        guard excludeAmbiguous else { return input }
        let ambiguous = Set("Il1O0o")
        return String(input.filter { !ambiguous.contains($0) })
    }

    private func secureCharacter(from characters: [Character]) -> Character? {
        guard !characters.isEmpty else { return nil }
        return characters[secureIndex(upperBound: characters.count)]
    }

    private func secureIndex(upperBound: Int) -> Int {
        guard upperBound > 1 else { return 0 }
        let limit = UInt64.max - UInt64.max % UInt64(upperBound)
        var value: UInt64 = 0
        repeat { _ = SecRandomCopyBytes(kSecRandomDefault, MemoryLayout<UInt64>.size, &value) } while value >= limit
        return Int(value % UInt64(upperBound))
    }

    private func secureShuffle(_ values: inout [Character]) {
        guard values.count > 1 else { return }
        for index in stride(from: values.count - 1, through: 1, by: -1) {
            values.swapAt(index, secureIndex(upperBound: index + 1))
        }
    }
}

private struct PasswordGeneratorView: View {
    @ObservedObject var model: PasswordGeneratorModel

    var body: some View {
        ZStack {
            LiquidGlassBackdrop(material: .underWindowBackground, blendingMode: .behindWindow)
            VStack(spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: "key.fill").foregroundStyle(SettingsStore.shared.accentTheme.gradient)
                    Text("Password Generator").font(.system(size: 15, weight: .semibold, design: .rounded))
                    Spacer()
                    Text("\(model.entropyBits) bits · \(model.strength)")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(model.entropyBits >= 80 ? .green : .secondary)
                }
                .padding(.horizontal, 13)
                .frame(height: 42)
                .liquidGlass(cornerRadius: 14, depth: .raised, accentOpacity: 0.04)

                HStack(spacing: 10) {
                    Text(model.password)
                        .font(.system(size: 17, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    Button(action: model.generate) { Image(systemName: "arrow.clockwise") }.help("Generate another")
                    Button(action: model.copy) {
                        Label(model.copied ? "Copied" : "Copy", systemImage: model.copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(14)
                .liquidGlass(cornerRadius: 16, depth: .floating, accentOpacity: 0.035)

                VStack(spacing: 13) {
                    HStack {
                        Text("Length").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Slider(value: Binding(get: { Double(model.length) }, set: { model.length = Int($0); model.generate() }), in: 8...128, step: 1)
                        Text(String(model.length)).font(.caption.monospacedDigit()).frame(width: 30, alignment: .trailing)
                    }
                    HStack(spacing: 16) {
                        option("a-z", isOn: $model.lowercase)
                        option("A-Z", isOn: $model.uppercase)
                        option("0-9", isOn: $model.numbers)
                        option("!@#", isOn: $model.symbols)
                        Spacer()
                    }
                    Toggle("Exclude ambiguous characters", isOn: $model.excludeAmbiguous)
                        .font(.caption)
                }
                .onChange(of: model.lowercase) { _ in model.generate() }
                .onChange(of: model.uppercase) { _ in model.generate() }
                .onChange(of: model.numbers) { _ in model.generate() }
                .onChange(of: model.symbols) { _ in model.generate() }
                .onChange(of: model.excludeAmbiguous) { _ in model.generate() }
                .padding(15)
                .liquidGlass(cornerRadius: 16, depth: .recessed, accentOpacity: 0.015)
                Spacer(minLength: 0)
            }
            .padding(10)
        }
        .preferredColorScheme(.dark)
        .tint(SettingsStore.shared.accentTheme.primary)
    }

    private func option(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn).toggleStyle(.checkbox).font(.caption.monospaced())
    }
}
