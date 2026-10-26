import AudioToolbox
import CoreAudio
import Foundation

enum AudioOutputTransport: String, Sendable, Equatable {
    case builtIn, bluetooth, usb, display, airPlay, virtual, other

    var label: String {
        switch self {
        case .builtIn: "Built-in"
        case .bluetooth: "Bluetooth"
        case .usb: "USB"
        case .display: "Display"
        case .airPlay: "AirPlay"
        case .virtual: "Virtual"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .builtIn, .display, .other: "speaker.wave.2"
        case .bluetooth: "headphones"
        case .usb: "hifispeaker"
        case .airPlay: "airplayaudio"
        case .virtual: "waveform"
        }
    }
}

struct AudioOutputHardwareDevice: Sendable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: AudioOutputTransport

    init(id: AudioObjectID, uid: String, name: String, transport: AudioOutputTransport = .other) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
    }
}

struct AudioOutputDevice: Identifiable, Sendable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: AudioOutputTransport
    let isDefault: Bool
}

enum AudioOutputError: LocalizedError {
    case unavailable(String)
    case deviceDisconnected
    case changeNotVerified
    case volumeUnavailable
    case muteUnavailable
    case invalidVolume

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail): return "Audio output is unavailable: \(detail)"
        case .deviceDisconnected: return "That audio output is no longer connected."
        case .changeNotVerified: return "macOS did not confirm the audio output change."
        case .volumeUnavailable: return "This output does not offer an adjustable system volume."
        case .muteUnavailable: return "This output does not offer a system mute control."
        case .invalidVolume: return "Volume must be between 0 and 100 percent."
        }
    }
}

protocol AudioOutputHardware: AnyObject {
    func outputDevices() throws -> [AudioOutputHardwareDevice]
    func defaultOutputID() throws -> AudioObjectID
    func setDefaultOutputID(_ id: AudioObjectID) throws
    func volume(for id: AudioObjectID) throws -> Float?
    func volumeIsWritable(for id: AudioObjectID) throws -> Bool
    func setVolume(_ value: Float, for id: AudioObjectID) throws
    func muted(for id: AudioObjectID) throws -> Bool?
    func setMuted(_ muted: Bool, for id: AudioObjectID) throws
    func observeChanges(_ onChange: @escaping @Sendable () -> Void)
    func stopObserving()
}

extension AudioOutputHardware {
    func volumeIsWritable(for id: AudioObjectID) throws -> Bool {
        try volume(for: id) != nil
    }
}

/// Shared native implementation for the UI and future AI/extension adapters.
/// Adapters must perform their own exact-call authority checks before invoking
/// a mutation; a manifest capability declaration does not grant access here.
final class AudioOutputService {
    private let hardware: AudioOutputHardware

    init(hardware: AudioOutputHardware = CoreAudioOutputHardware()) {
        self.hardware = hardware
    }

    func listOutputs() throws -> [AudioOutputDevice] {
        let current = try hardware.defaultOutputID()
        return try hardware.outputDevices()
            .map { AudioOutputDevice(id: $0.id, uid: $0.uid, name: $0.name,
                                     transport: $0.transport, isDefault: $0.id == current) }
            .sorted {
                if $0.isDefault != $1.isDefault { return $0.isDefault }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    func currentOutput() throws -> AudioOutputDevice {
        guard let current = try listOutputs().first(where: \.isDefault) else {
            throw AudioOutputError.unavailable("No active output device")
        }
        return current
    }

    func setOutput(uid: String) async throws -> AudioOutputDevice {
        guard let device = try hardware.outputDevices().first(where: { $0.uid == uid }) else {
            throw AudioOutputError.deviceDisconnected
        }
        try hardware.setDefaultOutputID(device.id)
        // Bluetooth and aggregate-device handoffs may settle asynchronously.
        for attempt in 0..<7 {
            if try hardware.defaultOutputID() == device.id {
                guard let verified = try listOutputs().first(where: {
                    $0.id == device.id && $0.uid == uid && $0.isDefault
                }) else {
                    throw AudioOutputError.deviceDisconnected
                }
                return verified
            }
            if attempt < 6 { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        throw AudioOutputError.changeNotVerified
    }

    func getVolume() throws -> Int? {
        let id = try hardware.defaultOutputID()
        guard let scalar = try hardware.volume(for: id) else { return nil }
        return Int((max(0, min(1, scalar)) * 100).rounded())
    }

    func canSetVolume() throws -> Bool {
        try hardware.volumeIsWritable(for: hardware.defaultOutputID())
    }

    func getMute() throws -> Bool? {
        try hardware.muted(for: hardware.defaultOutputID())
    }

    func setVolume(_ percent: Int) throws -> Int {
        guard (0...100).contains(percent) else { throw AudioOutputError.invalidVolume }
        let id = try hardware.defaultOutputID()
        guard try hardware.volumeIsWritable(for: id) else {
            throw AudioOutputError.volumeUnavailable
        }
        try hardware.setVolume(Float(percent) / 100, for: id)
        guard let actual = try hardware.volume(for: id) else {
            throw AudioOutputError.volumeUnavailable
        }
        let verified = Int((max(0, min(1, actual)) * 100).rounded())
        guard abs(verified - percent) <= 2 else { throw AudioOutputError.changeNotVerified }
        return verified
    }

    func toggleMute() throws -> Bool {
        let id = try hardware.defaultOutputID()
        guard let old = try hardware.muted(for: id) else {
            throw AudioOutputError.muteUnavailable
        }
        try hardware.setMuted(!old, for: id)
        guard let actual = try hardware.muted(for: id), actual == !old else {
            throw AudioOutputError.changeNotVerified
        }
        return actual
    }

    func observeChanges(_ onChange: @escaping @Sendable () -> Void) {
        hardware.observeChanges(onChange)
    }

    func stopObserving() { hardware.stopObserving() }
}

/// macOS 13-compatible Core Audio HAL backend. Device UIDs are stable across
/// reconnects; transient AudioObjectIDs are used only for the current call.
final class CoreAudioOutputHardware: AudioOutputHardware {
    private var listener: AudioObjectPropertyListenerBlock?
    private let listenerQueue = DispatchQueue(label: "dev.lima.audio-output-events")

    func outputDevices() throws -> [AudioOutputHardwareDevice] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var bytes: UInt32 = 0
        try Self.check(AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &bytes
        ))
        var ids = [AudioObjectID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioObjectID>.size)
        guard !ids.isEmpty else { return [] }
        try ids.withUnsafeMutableBytes { buffer in
            var actual = bytes
            try Self.check(AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                &actual, buffer.baseAddress!
            ))
        }
        return ids.compactMap { id in
            guard isAlive(id), hasOutputChannels(id),
                  let uid = try? Self.stringProperty(kAudioDevicePropertyDeviceUID, of: id),
                  !uid.isEmpty else { return nil }
            let name = (try? Self.stringProperty(kAudioObjectPropertyName, of: id)) ?? uid
            return AudioOutputHardwareDevice(id: id, uid: uid, name: name,
                                             transport: transport(for: id))
        }
    }

    func defaultOutputID() throws -> AudioObjectID {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try Self.check(AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        ))
        guard id != AudioObjectID(kAudioObjectUnknown) else {
            throw AudioOutputError.unavailable("No default output")
        }
        return id
    }

    func setDefaultOutputID(_ id: AudioObjectID) throws {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var value = id
        try Self.check(AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &value
        ))
    }

    func volume(for id: AudioObjectID) throws -> Float? {
        var address = Self.outputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        try Self.check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value))
        return value
    }

    func volumeIsWritable(for id: AudioObjectID) throws -> Bool {
        var address = Self.outputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(id, &address) else { return false }
        var settable: DarwinBoolean = false
        try Self.check(AudioObjectIsPropertySettable(id, &address, &settable))
        return settable.boolValue
    }

    func setVolume(_ value: Float, for id: AudioObjectID) throws {
        var address = Self.outputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard try volumeIsWritable(for: id) else { throw AudioOutputError.volumeUnavailable }
        var scalar = Float32(value)
        try Self.check(AudioObjectSetPropertyData(
            id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar
        ))
    }

    func muted(for id: AudioObjectID) throws -> Bool? {
        var address = Self.outputAddress(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try Self.check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value))
        return value != 0
    }

    func setMuted(_ muted: Bool, for id: AudioObjectID) throws {
        var address = Self.outputAddress(kAudioDevicePropertyMute)
        var settable: DarwinBoolean = false
        try Self.check(AudioObjectIsPropertySettable(id, &address, &settable))
        guard settable.boolValue else { throw AudioOutputError.muteUnavailable }
        var value: UInt32 = muted ? 1 : 0
        try Self.check(AudioObjectSetPropertyData(
            id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
        ))
    }

    func observeChanges(_ onChange: @escaping @Sendable () -> Void) {
        stopObserving()
        let callback: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        var devices = Self.address(kAudioHardwarePropertyDevices)
        var selected = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectAddPropertyListenerBlock(
            system, &devices, listenerQueue, callback
        ) == noErr else { return }
        guard AudioObjectAddPropertyListenerBlock(
            system, &selected, listenerQueue, callback
        ) == noErr else {
            AudioObjectRemovePropertyListenerBlock(system, &devices, listenerQueue, callback)
            return
        }
        listener = callback
    }

    func stopObserving() {
        guard let listener else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var devices = Self.address(kAudioHardwarePropertyDevices)
        var selected = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(system, &devices, listenerQueue, listener)
        AudioObjectRemovePropertyListenerBlock(system, &selected, listenerQueue, listener)
        self.listener = nil
    }

    deinit { stopObserving() }

    private func isAlive(_ id: AudioObjectID) -> Bool {
        var address = Self.address(kAudioDevicePropertyDeviceIsAlive)
        guard AudioObjectHasProperty(id, &address) else { return true }
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &alive) == noErr else { return false }
        return alive != 0
    }

    private func transport(for id: AudioObjectID) -> AudioOutputTransport {
        var address = Self.address(kAudioDevicePropertyTransportType)
        guard AudioObjectHasProperty(id, &address) else { return .other }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return .other }
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return .display
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        case kAudioDeviceTransportTypeVirtual: return .virtual
        default: return .other
        }
    }

    private func hasOutputChannels(_ id: AudioObjectID) -> Bool {
        var address = Self.outputAddress(kAudioDevicePropertyStreamConfiguration)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &bytes) == noErr,
              bytes >= MemoryLayout<AudioBufferList>.size else { return false }
        let memory = UnsafeMutableRawPointer.allocate(
            byteCount: Int(bytes), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &bytes, memory) == noErr else {
            return false
        }
        let buffers = UnsafeMutableAudioBufferListPointer(
            memory.assumingMemoryBound(to: AudioBufferList.self)
        )
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector,
                                       of id: AudioObjectID) throws -> String {
        var address = self.address(selector)
        var string: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try withUnsafeMutablePointer(to: &string) { pointer in
            try check(AudioObjectGetPropertyData(
                id, &address, 0, nil, &size, UnsafeMutableRawPointer(pointer)
            ))
        }
        return string?.takeRetainedValue() as String? ?? ""
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func outputAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else {
            throw AudioOutputError.unavailable("Core Audio error \(status)")
        }
    }
}
