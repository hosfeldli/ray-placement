import AppKit
import Combine
import SwiftUI

/// Favorites are persisted by stable Core Audio UID, never by transient object ID
/// or display name. Disconnected favorites remain saved for later reconnects.
@MainActor
final class AudioOutputFavoriteStore {
    private let defaults: UserDefaults
    private let key = "lima.audio.favoriteOutputUIDs"

    init(defaults: UserDefaults = LimaTestEnvironment.userDefaults) {
        self.defaults = defaults
    }

    var uids: [String] {
        var seen = Set<String>()
        return (defaults.stringArray(forKey: key) ?? []).filter { uid in
            !uid.isEmpty && uid.utf8.count <= 512 && seen.insert(uid).inserted
        }
    }

    @discardableResult
    func toggle(_ uid: String) -> [String] {
        guard !uid.isEmpty, uid.utf8.count <= 512 else { return uids }
        var updated = uids
        if let index = updated.firstIndex(of: uid) {
            updated.remove(at: index)
        } else if updated.count < 20 {
            updated.append(uid)
        }
        defaults.set(updated, forKey: key)
        return updated
    }
}

/// A user-operated picker. Search opens this surface; typing in Search never
/// enumerates devices and cannot change the system default by itself.
@MainActor
final class AudioOutputPickerModel: ObservableObject {
    @Published private(set) var devices: [AudioOutputDevice] = []
    @Published private(set) var favoriteUIDs: [String] = []
    @Published var selectedUID: String?
    @Published private(set) var isWorking = false
    @Published var message: String?

    private let service: AudioOutputService
    private let favorites: AudioOutputFavoriteStore

    init(service: AudioOutputService = AudioOutputService(),
         favorites: AudioOutputFavoriteStore? = nil) {
        let resolvedFavorites = favorites ?? AudioOutputFavoriteStore()
        self.service = service
        self.favorites = resolvedFavorites
        self.favoriteUIDs = resolvedFavorites.uids
    }

    func isFavorite(_ uid: String) -> Bool { favoriteUIDs.contains(uid) }

    func toggleFavorite(_ uid: String) {
        favoriteUIDs = favorites.toggle(uid)
        refresh()
    }

    func switchFavorite(at index: Int, onSuccess: @escaping () -> Void) {
        guard favoriteUIDs.indices.contains(index) else { return }
        let uid = favoriteUIDs[index]
        guard devices.contains(where: { $0.uid == uid }) else {
            message = "That favorite output is not connected."
            return
        }
        selectedUID = uid
        switchSelection(onSuccess: onSuccess)
    }

    func start() {
        refresh()
        service.observeChanges { [weak self] in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func stop() { service.stopObserving() }

    func refresh() {
        do {
            let listed = try service.listOutputs()
            devices = listed.sorted { left, right in
                let leftRank = favoriteUIDs.firstIndex(of: left.uid) ?? Int.max
                let rightRank = favoriteUIDs.firstIndex(of: right.uid) ?? Int.max
                if leftRank != rightRank { return leftRank < rightRank }
                if left.isDefault != right.isDefault { return left.isDefault }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
            if selectedUID == nil || !listed.contains(where: { $0.uid == selectedUID }) {
                selectedUID = listed.first(where: \.isDefault)?.uid
            }
            message = listed.isEmpty ? "No system output devices are available." : nil
        } catch {
            devices = []
            selectedUID = nil
            message = error.localizedDescription
        }
    }

    func switchSelection(onSuccess: @escaping () -> Void) {
        guard !isWorking, let selectedUID else { return }
        isWorking = true
        message = nil
        Task {
            do {
                _ = try await service.setOutput(uid: selectedUID)
                isWorking = false
                refresh()
                onSuccess()
            } catch {
                isWorking = false
                message = error.localizedDescription
                refreshAfterFailure()
            }
        }
    }

    private func refreshAfterFailure() {
        let failure = message
        refresh()
        message = failure
    }
}

@MainActor
final class AudioOutputWindowController: NSObject, NSWindowDelegate {
    static let shared = AudioOutputWindowController()

    private let model = AudioOutputPickerModel()
    private var panel: NSPanel?
    private weak var returnApplication: NSRunningApplication?

    func present(returningTo application: NSRunningApplication? = nil) {
        if let application, application.bundleIdentifier != Bundle.main.bundleIdentifier {
            returnApplication = application
        }
        if panel == nil {
            let panel = AudioOutputPanel(
                contentRect: NSRect(x: 0, y: 0, width: 430, height: 380),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            panel.title = "Switch Audio Output"
            panel.onCancel = { [weak self] in self?.dismiss() }
            panel.onFavoriteShortcut = { [weak self] index in
                guard let self else { return }
                self.model.switchFavorite(at: index) { [weak self] in self?.dismiss() }
            }
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: AudioOutputPickerView(
                model: model,
                cancel: { [weak self] in self?.dismiss() },
                switched: { [weak self] in self?.dismiss() }
            ))
            panel.center()
            self.panel = panel
        }
        model.start()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        returnApplication?.activate(options: [.activateIgnoringOtherApps])
    }

    private func dismiss() {
        model.stop()
        panel?.orderOut(nil)
        returnApplication?.activate(options: [.activateIgnoringOtherApps])
    }
}

private final class AudioOutputPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onFavoriteShortcut: ((Int) -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           let digits = event.charactersIgnoringModifiers,
           let number = Int(digits), (1...9).contains(number) {
            onFavoriteShortcut?(number - 1)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
private struct AudioOutputPickerView: View {
    @ObservedObject var model: AudioOutputPickerModel
    let cancel: () -> Void
    let switched: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Switch Audio Output").font(.title2.weight(.semibold))
            Text("Choose a system output device. Star favorites; press ⌘1–⌘9 to switch a connected favorite. Changes are verified before closing.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("audio-output-message")
            }
            List(model.devices, id: \.uid, selection: $model.selectedUID) { device in
                HStack(spacing: 10) {
                    Image(systemName: device.isDefault ? "speaker.wave.2.fill" : "speaker.wave.2")
                        .frame(width: 22)
                    Text(device.name).lineLimit(1)
                    Spacer()
                    if let rank = model.favoriteUIDs.firstIndex(of: device.uid), rank < 9 {
                        Text("⌘\(rank + 1)").font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if device.isDefault {
                        Text("Current").font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        model.toggleFavorite(device.uid)
                    } label: {
                        Image(systemName: model.isFavorite(device.uid) ? "star.fill" : "star")
                    }
                    .buttonStyle(.borderless)
                    .help(model.isFavorite(device.uid) ? "Remove favorite" : "Add favorite")
                    .accessibilityLabel(model.isFavorite(device.uid) ? "Remove favorite \(device.name)" : "Favorite \(device.name)")
                }
                .tag(device.uid)
            }
            .accessibilityIdentifier("audio-output-list")
            HStack {
                Button("Refresh") { model.refresh() }.disabled(model.isWorking)
                Spacer()
                Button("Cancel", action: cancel)
                Button("Switch Output") { model.switchSelection(onSuccess: switched) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isWorking || model.selectedUID == nil)
            }
        }
        .padding(18)
        .frame(width: 430, height: 380)
    }
}
