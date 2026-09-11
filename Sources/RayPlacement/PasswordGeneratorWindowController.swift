import AppKit
import Security
import SwiftUI

/// State for the launcher password surface. Only generation preferences are
/// persisted; the generated credential remains memory-only.
@MainActor
final class PasswordGeneratorModel: ObservableObject {
    private enum Key {
        static let length = "passwordGenerator.length"
        static let lowercase = "passwordGenerator.lowercase"
        static let uppercase = "passwordGenerator.uppercase"
        static let numbers = "passwordGenerator.numbers"
        static let symbols = "passwordGenerator.symbols"
        static let excludeAmbiguous = "passwordGenerator.excludeAmbiguous"
    }

    @Published var password = ""
    @Published var length: Int { didSet { savePreferences(); generate() } }
    @Published var lowercase: Bool { didSet { savePreferences(); generate() } }
    @Published var uppercase: Bool { didSet { savePreferences(); generate() } }
    @Published var numbers: Bool { didSet { savePreferences(); generate() } }
    @Published var symbols: Bool { didSet { savePreferences(); generate() } }
    @Published var excludeAmbiguous: Bool { didSet { savePreferences(); generate() } }
    @Published var copied = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedLength = defaults.object(forKey: Key.length) as? Int ?? 16
        length = min(max(storedLength, 8), 20)
        lowercase = defaults.object(forKey: Key.lowercase) as? Bool ?? true
        uppercase = defaults.object(forKey: Key.uppercase) as? Bool ?? true
        numbers = defaults.object(forKey: Key.numbers) as? Bool ?? true
        symbols = defaults.object(forKey: Key.symbols) as? Bool ?? true
        excludeAmbiguous = defaults.object(forKey: Key.excludeAmbiguous) as? Bool ?? true
        generate()
    }

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

    func setLength(_ value: Int) {
        length = min(max(value, 8), 20)
    }

    func generate() {
        let groups = enabledGroups
        guard !groups.isEmpty else {
            password = "Select at least one character set"
            copied = false
            return
        }
        var values: [Character] = []
        values.reserveCapacity(length)
        for group in groups {
            guard let character = secureCharacter(from: group) else {
                password = "Unable to generate securely"
                copied = false
                return
            }
            values.append(character)
        }
        let all = groups.flatMap { $0 }
        while values.count < length {
            guard let character = secureCharacter(from: all) else {
                password = "Unable to generate securely"
                copied = false
                return
            }
            values.append(character)
        }
        guard secureShuffle(&values) else {
            password = "Unable to generate securely"
            copied = false
            return
        }
        password = String(values.prefix(length))
        copied = false
    }

    func copy() {
        // Error/status text is held in the same display property as the
        // generated value; only copy a value that has the configured length.
        guard password.utf16.count == length else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(password, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.copied = false
        }
    }

    private func savePreferences() {
        defaults.set(length, forKey: Key.length)
        defaults.set(lowercase, forKey: Key.lowercase)
        defaults.set(uppercase, forKey: Key.uppercase)
        defaults.set(numbers, forKey: Key.numbers)
        defaults.set(symbols, forKey: Key.symbols)
        defaults.set(excludeAmbiguous, forKey: Key.excludeAmbiguous)
    }

    private var enabledGroups: [[Character]] {
        var groups: [[Character]] = []
        if lowercase { groups.append(Array(filtered("abcdefghijklmnopqrstuvwxyz"))) }
        if uppercase { groups.append(Array(filtered("ABCDEFGHIJKLMNOPQRSTUVWXYZ"))) }
        if numbers { groups.append(Array(filtered("0123456789"))) }
        if symbols { groups.append(Array(filtered("!@#$%^&*()-_=+[]{};:,.?/"))) }
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
        guard let index = secureIndex(upperBound: characters.count) else { return nil }
        return characters[index]
    }

    private func secureIndex(upperBound: Int) -> Int? {
        guard upperBound > 1 else { return 0 }
        let bound = UInt64(upperBound)
        let threshold = (0 &- bound) % bound
        var value: UInt64 = 0
        repeat {
            guard SecRandomCopyBytes(kSecRandomDefault, MemoryLayout<UInt64>.size, &value) == errSecSuccess else {
                return nil
            }
        } while value < threshold
        return Int(value % bound)
    }

    private func secureShuffle(_ values: inout [Character]) -> Bool {
        guard values.count > 1 else { return true }
        for index in stride(from: values.count - 1, through: 1, by: -1) {
            guard let randomIndex = secureIndex(upperBound: index + 1) else { return false }
            values.swapAt(index, randomIndex)
        }
        return true
    }
}

/// Reusable content for interactive generator extensions embedded in the
/// launcher. The model is intentionally independent of the launcher so other
/// inline extension sessions can adopt the same surface contract.
struct PasswordGeneratorSurface: View {
    @ObservedObject var model: PasswordGeneratorModel

    var body: some View {
        VStack(spacing: LimaDesign.sectionGap) {
            HStack(spacing: 10) {
                Text(model.password)
                    .limaFont(.system(size: 17, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                Button(action: model.generate) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Generate another password")
                Button(action: model.copy) {
                    Label(model.copied ? "Copied" : "Copy", systemImage: model.copied ? "checkmark" : "doc.on.doc")
                }
                .limaButton(prominent: true)
            }
            .padding(LimaDesign.sectionGap)
            .liquidGlass(cornerRadius: LimaDesign.panelCorner, depth: .raised, accentOpacity: 0.024)

            VStack(spacing: 12) {
                HStack {
                    Text("Length")
                        .limaFont(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Stepper(value: Binding(
                        get: { model.length },
                        set: { model.setLength($0) }
                    ), in: 8...20) {
                        Text(String(model.length))
                            .limaFont(.caption.monospacedDigit())
                            .frame(width: 28, alignment: .trailing)
                    }
                    .labelsHidden()
                    Text(String(model.length))
                        .limaFont(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                }

                HStack(spacing: 6) {
                    Text("Presets")
                        .limaFont(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach([12, 16, 20], id: \.self) { value in
                        Button(String(value)) { model.setLength(value) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(model.length == value ? SettingsStore.shared.accentTheme.readablePrimary : .secondary)
                    }
                    Spacer()
                }

                HStack(spacing: 14) {
                    option("a-z", isOn: Binding(get: { model.lowercase }, set: { model.lowercase = $0 }))
                    option("A-Z", isOn: Binding(get: { model.uppercase }, set: { model.uppercase = $0 }))
                    option("0-9", isOn: Binding(get: { model.numbers }, set: { model.numbers = $0 }))
                    option("!@#", isOn: Binding(get: { model.symbols }, set: { model.symbols = $0 }))
                    Spacer()
                }

                Toggle("Exclude ambiguous characters", isOn: Binding(
                    get: { model.excludeAmbiguous },
                    set: { model.excludeAmbiguous = $0 }
                ))
                .limaFont(.caption)
            }
            .padding(LimaDesign.sectionGap)
            .liquidGlass(cornerRadius: LimaDesign.panelCorner, depth: .recessed, accentOpacity: 0.010)
        }
        .padding(10)
        .tint(SettingsStore.shared.accentTheme.readablePrimary)
    }

    private func option(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn)
            .toggleStyle(.checkbox)
            .limaFont(.caption.monospaced())
    }
}
