import SwiftUI

/// The General → Audio surface uses the same native picker model as Search and
/// the Activity Shelf. Core Audio notifications keep it current while visible.
@MainActor
struct AudioOutputSettingsView: View {
    @StateObject private var model = AudioOutputPickerModel()

    var body: some View {
        AudioOutputPickerView(model: model, cancel: {}, switched: {}, showsCancel: false)
            .onAppear { model.start() }
            .onDisappear { model.stop() }
            .accessibilityIdentifier("settings-audio-output")
    }
}
