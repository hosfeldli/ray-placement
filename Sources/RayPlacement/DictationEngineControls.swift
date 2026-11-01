import SwiftUI

struct DictationEngineControls: View {
    @ObservedObject var service: NoteDictationService
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcribe with").limaFont(.caption.weight(.semibold))
                .foregroundStyle(LimaTheme.textSecondary)
            Picker("Transcribe with", selection: $settings.dictationEngine) {
                Text("Apple Live").tag(DictationEngine.appleSpeech)
                Text("Whisper").tag(DictationEngine.localWhisper)
                Text("OpenAI API · Live").tag(DictationEngine.openAICloud)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .disabled(service.isBusy)
            if settings.dictationEngine == .openAICloud {
                Toggle("Detect speakers", isOn: $service.speakerLabelsEnabled)
                    .toggleStyle(.checkbox).disabled(service.isBusy)
                Text("Audio is uploaded about every 10 seconds. Speaker labels belong to each window; they do not identify the same person across windows.")
                    .limaFont(.caption2).foregroundStyle(LimaTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Audio stays on this Mac", systemImage: "lock.shield")
                    .limaFont(.caption2).foregroundStyle(LimaTheme.textSecondary)
            }
        }
        .padding(10)
        .background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("dictation.engine-controls")
    }
}
