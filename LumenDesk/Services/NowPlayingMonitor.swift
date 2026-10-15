import Foundation
#if os(macOS)
import AppKit
#endif

/// A music app LumenDesk can ask where the song is.
enum PlaybackApp: String, CaseIterable, Equatable {
    case spotify = "com.spotify.client"
    case music = "com.apple.Music"

    var displayName: String {
        switch self {
        case .spotify: return "Spotify"
        case .music: return "Music"
        }
    }

    /// Track IDs from different apps never collide in the beat-map store.
    func trackKey(_ trackID: String) -> String { "\(rawValue):\(trackID)" }
}

/// One reading of a music app's player.
struct NowPlayingSample: Equatable {
    var app: PlaybackApp
    var trackID: String
    var title: String
    var artist: String
    var duration: TimeInterval
    var position: TimeInterval
    var isPlaying: Bool
    /// Host time halfway through the request, which is the best estimate of
    /// when `position` was true.
    var sampledAt: TimeInterval
}

enum NowPlayingPermission: Equatable {
    case unknown, granted, denied
}

#if os(macOS)
/// Polls Spotify and Music over Apple Events once a second. Only apps that
/// are already running are asked, so LumenDesk never launches one, and
/// compiling a script for an app that is not installed never shows the
/// "Where is…" dialog. Main thread only: NSAppleScript is not thread-safe.
final class NowPlayingMonitor {
    var onSample: ((NowPlayingSample?) -> Void)?
    var onPermission: ((NowPlayingPermission) -> Void)?

    private let now: () -> TimeInterval
    private var timer: Timer?
    private var scripts: [PlaybackApp: NSAppleScript] = [:]
    private(set) var permission: NowPlayingPermission = .unknown {
        didSet { if permission != oldValue { onPermission?(permission) } }
    }

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    func start() {
        guard timer == nil else { return }
        poll()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }

    private func poll() {
        var paused: NowPlayingSample?
        for app in PlaybackApp.allCases where isRunning(app) {
            guard let sample = read(app) else { continue }
            // A playing app wins over a paused one.
            if sample.isPlaying { onSample?(sample); return }
            if paused == nil { paused = sample }
        }
        onSample?(paused)
    }

    private func isRunning(_ app: PlaybackApp) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: app.rawValue).isEmpty
    }

    private func read(_ app: PlaybackApp) -> NowPlayingSample? {
        guard let script = script(for: app) else { return nil }
        let before = now()
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        let after = now()
        if let error {
            // -1743: the user declined Automation for this app.
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 { permission = .denied }
            return nil
        }
        permission = .granted
        return Self.parse(result, app: app, sampledAt: (before + after) / 2)
    }

    private func script(for app: PlaybackApp) -> NSAppleScript? {
        if let cached = scripts[app] { return cached }
        // A list keeps numbers as numbers: coercing a real to text would use
        // the user's decimal separator. The timeout bounds a busy app.
        let source: String
        switch app {
        case .spotify:
            source = """
            with timeout of 1 second
                tell application id "com.spotify.client"
                    set playerState to (player state as text)
                    if playerState is "stopped" then return {playerState}
                    set theTrack to current track
                    return {playerState, (id of theTrack), ((duration of theTrack) / 1000), player position, (name of theTrack), (artist of theTrack)}
                end tell
            end timeout
            """
        case .music:
            source = """
            with timeout of 1 second
                tell application id "com.apple.Music"
                    set playerState to (player state as text)
                    if playerState is "stopped" then return {playerState}
                    set theTrack to current track
                    return {playerState, (persistent ID of theTrack), (duration of theTrack), player position, (name of theTrack), (artist of theTrack)}
                end tell
            end timeout
            """
        }
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        guard script.compileAndReturnError(&error) else { return nil }
        scripts[app] = script
        return script
    }

    /// Reads the list the scripts return. Exposed for tests.
    static func parse(_ descriptor: NSAppleEventDescriptor, app: PlaybackApp, sampledAt: TimeInterval) -> NowPlayingSample? {
        guard descriptor.numberOfItems >= 6,
              let state = descriptor.atIndex(1)?.stringValue,
              let trackID = descriptor.atIndex(2)?.stringValue, !trackID.isEmpty,
              let durationItem = descriptor.atIndex(3), let positionItem = descriptor.atIndex(4) else { return nil }
        let duration = durationItem.doubleValue
        let position = positionItem.doubleValue
        guard duration.isFinite, position.isFinite, position >= 0 else { return nil }
        return NowPlayingSample(
            app: app,
            trackID: trackID,
            title: descriptor.atIndex(5)?.stringValue ?? "",
            artist: descriptor.atIndex(6)?.stringValue ?? "",
            duration: max(0, duration),
            position: position,
            isPlaying: state == "playing",
            sampledAt: sampledAt
        )
    }
}
#endif
