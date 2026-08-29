import AppKit
import Foundation

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
    }

    let source: Source
    let title: String
    let artist: String
    let album: String
}

@MainActor
final class MusicNowPlayingService: ObservableObject {
    enum TransportAction {
        case previous
        case playPause
        case next
    }

    @Published private(set) var nowPlaying: MediaNowPlayingSnapshot?
    @Published private(set) var isPerformingTransport = false

    private let scriptQueue = DispatchQueue(
        label: "dev.rayplacement.music-now-playing",
        qos: .utility
    )
    private var timer: Timer?
    private var queryInFlight = false
    private var mostRecentSource: MediaNowPlayingSnapshot.Source?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 0.8
    }

    deinit {
        timer?.invalidate()
    }

    func perform(_ action: TransportAction) {
        guard let source = nowPlaying?.source ?? firstRunningSource else { return }
        guard !isPerformingTransport else { return }
        isPerformingTransport = true
        let command: String
        switch action {
        case .previous: command = "previous track"
        case .playPause: command = "playpause"
        case .next: command = "next track"
        }
        scriptQueue.async { [weak self] in
            _ = Self.execute("tell application id \"\(source.applicationID)\" to \(command)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self?.refresh()
            }
        }
    }

    func refresh() {
        let runningSources = MediaNowPlayingSnapshot.Source.allCases.filter(isRunning)
        guard !runningSources.isEmpty else {
            nowPlaying = nil
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
                if let snapshot { self.mostRecentSource = snapshot.source }
                self.isPerformingTransport = false
            }
        }
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

    nonisolated private static func parse(
        _ raw: String,
        source: MediaNowPlayingSnapshot.Source
    ) -> MediaNowPlayingSnapshot? {
        let pieces = raw.components(separatedBy: "\u{1F}")
        guard pieces.count >= 3, !pieces[0].isEmpty else { return nil }
        return MediaNowPlayingSnapshot(source: source, title: pieces[0], artist: pieces[1], album: pieces[2])
    }

    nonisolated private static func nowPlayingScript(
        for source: MediaNowPlayingSnapshot.Source
    ) -> String {
        switch source {
        case .spotify:
            return """
            tell application id "com.spotify.client"
                if player state is not playing then return ""
                return name of current track & ASCII character 31 & artist of current track & ASCII character 31 & album of current track
            end tell
            """
        case .appleMusic:
            return """
            tell application id "com.apple.Music"
                if player state is not playing then return ""
                set trackName to ""
                set artistName to ""
                set albumName to ""
                try
                    set trackName to name of current track
                    set artistName to artist of current track
                    set albumName to album of current track
                end try
                return trackName & ASCII character 31 & artistName & ASCII character 31 & albumName
            end tell
            """
        }
    }
}
