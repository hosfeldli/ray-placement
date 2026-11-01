import Foundation
import SwiftUI

/// User-assigned names are separate from automatic turn detection. No voice
/// identification or alternating two-person assumption is made on device.
struct DictationSpeakerAttribution {
    private var previous: String?
    private var hasOutput = false
    mutating func label(_ text: String, speaker: String?) -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let name = speaker.flatMap { value -> String? in
            let clean = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
            return clean.isEmpty ? nil : clean
        }
        defer { previous = name; hasOutput = true }
        if let name, !hasOutput || name != previous {
            return (hasOutput ? "\n\n" : "") + name + ": " + text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if hasOutput, name != previous { return "\n\n" + text }
        return text
    }
}

struct DictationParticipantControls: View {
    @ObservedObject var service: NoteDictationService
    @ObservedObject var store: DictationConversationStore
    let conversation: DictationConversation
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "person.2.wave.2").foregroundStyle(LimaTheme.accentInk)
                Picker("Speaking", selection: Binding(get: {
                    (conversation.participants ?? []).contains(service.selectedSpeakerName ?? "") ? service.selectedSpeakerName ?? "" : ""
                }, set: { service.selectSpeaker($0.isEmpty ? nil : $0) })) {
                    Text("Unlabelled / detected turns").tag("")
                    ForEach(conversation.participants ?? [], id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Choose who is speaking")
            }
            HStack(spacing: 7) {
                TextField("Add a person's name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button(action: add) { Image(systemName: "plus").frame(width: 24, height: 24) }
                    .buttonStyle(.borderless)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Add participant")
            }
            Text("Choose a name before that person speaks. Detected turns are estimates, not identified people.")
                .limaFont(.caption2).foregroundStyle(LimaTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled([.requestingPermission, .stopping, .transcribing].contains(service.phase)
            || (service.isBusy && service.currentTarget != .conversation(conversation.id)))
        .padding(9)
        .background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func add() {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if store.addParticipant(clean, to: conversation.id) {
            service.selectSpeaker(clean)
            name = ""
        }
    }
}
