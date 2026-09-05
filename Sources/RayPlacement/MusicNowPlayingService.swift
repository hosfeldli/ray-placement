import AppKit
import ApplicationServices
import AudioToolbox
import Foundation
import SwiftUI

/// Metadata for the actively playing supported local media source. This is
/// intentionally opt-in: RayPlacement never opens, starts, or scans a player.
struct MediaNowPlayingSnapshot: Equatable, Sendable {
    enum Source: String, CaseIterable, Sendable {
        case spotify
        case appleMusic

        var bundleIdentifier: String {
            switch self {
            case .spotify: return "com.spotify.client"
            case .appleMusic: return "com.apple.Music"
            }
        }

        var applicationID: String {
            switch self {
            case .spotify: return "com.spotify.client"
            case .appleMusic: return "com.apple.Music"
            }
        }

        var title: String {
            switch self {
            case .spotify: return "Spotify"
            case .appleMusic: return "Music"
            }
        }

        var symbol: String {
            switch self {
            case .spotify: return "waveform"
            case .appleMusic: return "music.note"
            }
        }

        var accent: Color {
            switch self {
            case .spotify: return Color(red: 0.30, green: 0.86, blue: 0.48)
            case .appleMusic: return Color(red: 1.00, green: 0.35, blue: 0.46)
            }
        }
    }

    let source: Source
    let title: String
    let artist: String
    let album: String
    let isPlaying: Bool
    let artworkURL: URL?
    let duration: Double
    let position: Double
}

@MainActor
final class MusicNowPlayingService: ObservableObject {
    enum TransportAction {
        case previous
        case playPause
        case next
    }

    @Published private(set) var nowPlaying: MediaNowPlayingSnapshot?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var isPerformingTransport = false
    @Published private(set) var transportMessage: String?
    @Published private(set) var controlAvailabilityMessage: String?
    @Published private(set) var outputVolume: Double = 0
    @Published private(set) var outputAudioLevel: Double = 0

    private let scriptQueue = DispatchQueue(
        label: "dev.rayplacement.music-now-playing",
        qos: .utility
    )
    private var timer: Timer?
    private var volumeTimer: Timer?
    private var progressTimer: Timer?
    private var audioLevelMonitor: SystemAudioLevelMonitor?
    private var hasLiveOutputMeter = false
    private var queryInFlight = false
    private var mostRecentSource: MediaNowPlayingSnapshot.Source?
    private var nowPlayingUpdatedAt: Date?
    private var artworkKey: String?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 0.8
        volumeTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshOutputVolume() }
        }
        volumeTimer?.tolerance = 0.08
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advancePlaybackProgress() }
        }
        progressTimer?.tolerance = 0.2
        refreshOutputVolume()
        if #available(macOS 14.2, *) {
            let monitor = SystemAudioLevelMonitor { [weak self] level in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.outputAudioLevel = (self.outputAudioLevel * 0.54) + (level * 0.46)
                }
            }
            hasLiveOutputMeter = monitor.start()
            if hasLiveOutputMeter { audioLevelMonitor = monitor }
        }
    }

    deinit {
        timer?.invalidate()
        volumeTimer?.invalidate()
        progressTimer?.invalidate()
        audioLevelMonitor?.stop()
    }

    func openSource() {
        guard let source = nowPlaying?.source ?? firstRunningSource,
              let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleIdentifier) else { return }
        NSWorkspace.shared.open(applicationURL)
    }

    func perform(_ action: TransportAction) {
        guard let source = nowPlaying?.source ?? firstRunningSource else { return }
        guard !isPerformingTransport else { return }
        isPerformingTransport = true
        transportMessage = action.feedback
        if AXIsProcessTrusted(), Self.postMediaKey(action.mediaKeyCode) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                self?.isPerformingTransport = false
                self?.refresh()
            }
            controlAvailabilityMessage = nil
            clearTransportMessageSoon(action.feedback)
            return
        }
        let command: String
        switch action {
        case .previous: command = "previous track"
        case .playPause: command = "playpause"
        case .next: command = "next track"
        }
        scriptQueue.async { [weak self] in
            let outcome = Self.executeCommand("tell application id \"\(source.applicationID)\" to \(command)")
            DispatchQueue.main.async {
                self?.transportMessage = outcome.succeeded
                    ? action.feedback
                    : "Playback unavailable · allow Lima in Automation"
                self?.controlAvailabilityMessage = outcome.succeeded
                    ? nil
                    : "Allow Lima to control \(source.title) in System Settings → Privacy & Security → Automation."
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self?.refresh()
                }
                if outcome.succeeded { self?.clearTransportMessageSoon(action.feedback) }
            }
        }
    }

    private func clearTransportMessageSoon(_ expected: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard self?.transportMessage == expected else { return }
            self?.transportMessage = nil
        }
    }

    func setOutputVolume(_ value: Double) {
        let clamped = min(1, max(0, value))
        guard Self.setDefaultOutputVolume(clamped) else { return }
        outputVolume = clamped
    }

    private func refreshOutputVolume() {
        outputVolume = Self.defaultOutputVolume() ?? outputVolume
        if !hasLiveOutputMeter { outputAudioLevel = outputVolume }
    }

    /// Posts the same system media command generated by a Mac keyboard. This is
    /// player-independent, so it remains reliable when Spotify, Music, or a
    /// different active media app owns the system now-playing session.
    nonisolated private static func postMediaKey(_ keyCode: Int) -> Bool {
        let flagsDown = (keyCode << 16) | (0xA << 8)
        let flagsUp = (keyCode << 16) | (0xB << 8)
        guard let down = NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, subtype: 8, data1: flagsDown, data2: -1
        )?.cgEvent,
        let up = NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, subtype: 8, data1: flagsUp, data2: -1
        )?.cgEvent else { return false }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    nonisolated private static func defaultOutputVolume() -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        ) == noErr, device != 0 else { return nil }
        address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume = Float32(0)
        size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else { return nil }
        return min(1, max(0, Double(volume)))
    }

    nonisolated private static func setDefaultOutputVolume(_ value: Double) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return false }
        address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume = Float32(value)
        size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &volume) == noErr
    }

    func refresh() {
        let runningSources = MediaNowPlayingSnapshot.Source.allCases.filter(isRunning)
        guard !runningSources.isEmpty else {
            nowPlaying = nil
            artwork = nil
            artworkKey = nil
            nowPlayingUpdatedAt = nil
            isPerformingTransport = false
            return
        }
        guard !queryInFlight else { return }
        queryInFlight = true
        scriptQueue.async { [weak self] in
            let snapshots = runningSources.compactMap { source in
                Self.execute(Self.nowPlayingScript(for: source)).flatMap { Self.parse($0, source: source) }
            }
            DispatchQueue.main.async {
                self?.queryInFlight = false
                guard let self else { return }
                let snapshot = snapshots.first(where: { $0.source == self.mostRecentSource })
                    ?? snapshots.first
                self.nowPlaying = snapshot
                self.nowPlayingUpdatedAt = snapshot == nil ? nil : Date()
                if let snapshot { self.mostRecentSource = snapshot.source }
                self.loadArtworkIfNeeded(for: snapshot)
                self.isPerformingTransport = false
            }
        }
    }

    private func advancePlaybackProgress() {
        guard var snapshot = nowPlaying,
              snapshot.isPlaying,
              snapshot.duration > 0,
              let updatedAt = nowPlayingUpdatedAt else { return }
        let elapsed = max(0, Date().timeIntervalSince(updatedAt))
        let position = min(snapshot.duration, max(0, snapshot.position + elapsed))
        guard abs(position - snapshot.position) >= 0.01 else { return }
        snapshot = MediaNowPlayingSnapshot(
            source: snapshot.source,
            title: snapshot.title,
            artist: snapshot.artist,
            album: snapshot.album,
            isPlaying: snapshot.isPlaying,
            artworkURL: snapshot.artworkURL,
            duration: snapshot.duration,
            position: position
        )
        nowPlaying = snapshot
        nowPlayingUpdatedAt = Date()
    }

    private var firstRunningSource: MediaNowPlayingSnapshot.Source? {
        MediaNowPlayingSnapshot.Source.allCases.first(where: isRunning)
    }

    private func isRunning(_ source: MediaNowPlayingSnapshot.Source) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleIdentifier).isEmpty
    }

    nonisolated private static func execute(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return result.stringValue
    }

    nonisolated private static func executeCommand(_ source: String) -> (succeeded: Bool, detail: String?) {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return (false, "Invalid playback command") }
        _ = script.executeAndReturnError(&error)
        return error == nil ? (true, nil) : (false, error?[NSAppleScript.errorMessage] as? String)
    }

    nonisolated private static func executeData(_ source: String) -> Data? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return result.data
    }

    nonisolated private static func parse(
        _ raw: String,
        source: MediaNowPlayingSnapshot.Source
    ) -> MediaNowPlayingSnapshot? {
        let pieces = raw.components(separatedBy: "\u{1F}")
        guard pieces.count >= 4, !pieces[0].isEmpty else { return nil }
        return MediaNowPlayingSnapshot(
            source: source,
            title: pieces[0],
            artist: pieces[1],
            album: pieces[2],
            isPlaying: pieces[3] == "playing",
            artworkURL: pieces.count > 4 ? URL(string: pieces[4]) : nil,
            duration: pieces.count > 5 ? Double(pieces[5]) ?? 0 : 0,
            position: pieces.count > 6 ? Double(pieces[6]) ?? 0 : 0
        )
    }

    nonisolated private static func nowPlayingScript(
        for source: MediaNowPlayingSnapshot.Source
    ) -> String {
        switch source {
        case .spotify:
            return """
            tell application id "com.spotify.client"
                set playState to player state as string
                set artAddress to ""
                try
                    set artAddress to artwork url of current track
                end try
                return name of current track & ASCII character 31 & artist of current track & ASCII character 31 & album of current track & ASCII character 31 & playState & ASCII character 31 & artAddress & ASCII character 31 & (duration of current track as string) & ASCII character 31 & (player position as string)
            end tell
            """
        case .appleMusic:
            return """
            tell application id "com.apple.Music"
                set playState to player state as string
                set trackName to ""
                set artistName to ""
                set albumName to ""
                try
                    set trackName to name of current track
                    set artistName to artist of current track
                    set albumName to album of current track
                end try
                return trackName & ASCII character 31 & artistName & ASCII character 31 & albumName & ASCII character 31 & playState & ASCII character 31 & ASCII character 31 & (duration of current track as string) & ASCII character 31 & (player position as string)
            end tell
            """
        }
    }

    private func loadArtworkIfNeeded(for snapshot: MediaNowPlayingSnapshot?) {
        guard let snapshot else {
            artwork = nil
            artworkKey = nil
            return
        }
        let key = "\(snapshot.source.rawValue)|\(snapshot.title)|\(snapshot.artist)|\(snapshot.album)"
        guard key != artworkKey else { return }
        artworkKey = key
        artwork = nil
        scriptQueue.async { [weak self] in
            let data: Data?
            switch snapshot.source {
            case .spotify:
                data = snapshot.artworkURL.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
            case .appleMusic:
                data = Self.executeData("""
                tell application id "com.apple.Music"
                    try
                        return data of artwork 1 of current track
                    on error
                        return missing value
                    end try
                end tell
                """)
            }
            let image: NSImage?
            if let payload = data, payload.count <= 8 * 1024 * 1024 {
                image = NSImage(data: payload)
            } else {
                image = nil
            }
            DispatchQueue.main.async {
                guard self?.artworkKey == key else { return }
                self?.artwork = image
            }
        }
    }
}

private extension MusicNowPlayingService.TransportAction {
    var mediaKeyCode: Int {
        switch self {
        case .playPause: return 16
        case .next: return 17
        case .previous: return 18
        }
    }

    var feedback: String {
        switch self {
        case .playPause: return "Playback updated"
        case .next: return "Skipping forward…"
        case .previous: return "Skipping back…"
        }
    }
}
