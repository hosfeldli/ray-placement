import CoreAudio
import Foundation
import Testing
@testable import RayPlacement

private final class FakeAudioOutputHardware: AudioOutputHardware {
    var devices = [
        AudioOutputHardwareDevice(id: 10, uid: "builtin-speakers", name: "MacBook Speakers"),
        AudioOutputHardwareDevice(id: 20, uid: "wireless-headphones", name: "Headphones")
    ]
    var selectedID: AudioObjectID = 10
    var ignoreSwitch = false
    var volumeValue: Float? = 0.48
    var mutedValue: Bool? = false
    var onChange: (@Sendable () -> Void)?

    func outputDevices() throws -> [AudioOutputHardwareDevice] { devices }
    func defaultOutputID() throws -> AudioObjectID { selectedID }
    func setDefaultOutputID(_ id: AudioObjectID) throws {
        if !ignoreSwitch { selectedID = id; onChange?() }
    }
    func volume(for id: AudioObjectID) throws -> Float? { volumeValue }
    func setVolume(_ value: Float, for id: AudioObjectID) throws { volumeValue = value }
    func muted(for id: AudioObjectID) throws -> Bool? { mutedValue }
    func setMuted(_ muted: Bool, for id: AudioObjectID) throws { mutedValue = muted }
    func observeChanges(_ onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    func stopObserving() { onChange = nil }
}

@Test func audioOutputSwitchesByStableUIDAndVerifiesDefault() async throws {
    let hardware = FakeAudioOutputHardware()
    let service = AudioOutputService(hardware: hardware)
    let initial = try service.listOutputs()
    #expect(initial.count == 2)
    #expect(initial.first?.uid == "builtin-speakers")
    #expect(initial.first?.isDefault == true)

    let switched = try await service.setOutput(uid: "wireless-headphones")
    #expect(switched.uid == "wireless-headphones")
    #expect(switched.isDefault)
    #expect(hardware.selectedID == 20)
    #expect(try service.currentOutput().uid == "wireless-headphones")

    hardware.devices.removeAll { $0.uid == "wireless-headphones" }
    do {
        _ = try await service.setOutput(uid: "wireless-headphones")
        Issue.record("Expected a disconnected device to be rejected")
    } catch AudioOutputError.deviceDisconnected {
        // Expected.
    }
}

@Test func audioOutputDoesNotClaimSuccessWhenHALSetterIsIgnored() async throws {
    let hardware = FakeAudioOutputHardware()
    hardware.ignoreSwitch = true
    let service = AudioOutputService(hardware: hardware)
    do {
        _ = try await service.setOutput(uid: "wireless-headphones")
        Issue.record("Expected verification failure")
    } catch AudioOutputError.changeNotVerified {
        #expect(hardware.selectedID == 10)
    }
}

@Test func audioOutputVolumeAndMuteRespectHardwareSupport() throws {
    let hardware = FakeAudioOutputHardware()
    let service = AudioOutputService(hardware: hardware)
    #expect(try service.getVolume() == 48)
    #expect(try service.setVolume(76) == 76)
    #expect(try service.toggleMute())
    #expect(hardware.mutedValue == true)

    hardware.volumeValue = nil
    #expect(try service.getVolume() == nil)
    do {
        _ = try service.setVolume(20)
        Issue.record("Expected volume-unavailable result")
    } catch AudioOutputError.volumeUnavailable {
        // Expected.
    }
    hardware.mutedValue = nil
    do {
        _ = try service.toggleMute()
        Issue.record("Expected mute-unavailable result")
    } catch AudioOutputError.muteUnavailable {
        // Expected.
    }
}

@Test @MainActor func audioFavoritesPersistStableUIDsAndSurviveDisconnect() throws {
    let suite = "AudioFavorites.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let favorites = AudioOutputFavoriteStore(defaults: defaults)
    #expect(favorites.uids.isEmpty)
    #expect(favorites.toggle("wireless-headphones") == ["wireless-headphones"])
    #expect(AudioOutputFavoriteStore(defaults: defaults).uids == ["wireless-headphones"])

    let hardware = FakeAudioOutputHardware()
    let model = AudioOutputPickerModel(service: AudioOutputService(hardware: hardware),
                                       favorites: favorites)
    model.refresh()
    #expect(model.devices.first?.uid == "wireless-headphones")
    #expect(model.isFavorite("wireless-headphones"))
    hardware.devices.removeAll { $0.uid == "wireless-headphones" }
    model.refresh()
    #expect(model.favoriteUIDs == ["wireless-headphones"])
    model.switchFavorite(at: 0, onSuccess: { Issue.record("Disconnected favorite must not switch") })
    #expect(model.message == "That favorite output is not connected.")
    model.toggleFavorite("wireless-headphones")
    #expect(favorites.uids.isEmpty)
}

@Test @MainActor func audioPickerKeepsSelectionByUIDAndStopsObservation() {
    let hardware = FakeAudioOutputHardware()
    let model = AudioOutputPickerModel(service: AudioOutputService(hardware: hardware))
    model.start()
    #expect(model.selectedUID == "builtin-speakers")
    #expect(hardware.onChange != nil)

    model.selectedUID = "wireless-headphones"
    hardware.devices.append(AudioOutputHardwareDevice(
        id: 30, uid: "display-audio", name: "External Display"
    ))
    model.refresh()
    #expect(model.selectedUID == "wireless-headphones")

    hardware.devices.removeAll { $0.uid == "wireless-headphones" }
    model.refresh()
    #expect(model.selectedUID == "builtin-speakers")
    model.stop()
    #expect(hardware.onChange == nil)
}
