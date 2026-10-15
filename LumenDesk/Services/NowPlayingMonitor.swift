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
/// "Where is…" dialog. Main thread only: Apple lists NSAppleScript as a
/// main-thread-only class. Because a busy app can hold the main thread (and
/// the lighting timer) until the script times out, an app that answers slowly
/// is left alone for a while and the app that last played is asked first.
final class NowPlayingMonitor {
    var onSample: ((NowPlayingSample?) -> Void)?
    var onPermission: ((NowPlayingPermission) -> Void)?

    private let now: () -> TimeInterval
    private let running: (PlaybackApp) -> Bool
    private let sampleReader: ((PlaybackApp) -> (NowPlayingSample?, NowPlayingPermission))?
    private var appPermissions: [PlaybackApp: NowPlayingPermission] = [:]
    private var timer: Timer?
    private var scripts: [PlaybackApp: NSAppleScript] = [:]
    /// Until when each slow app is skipped.
    private var restingUntil: [PlaybackApp: TimeInterval] = [:]
    private var lastPlaying: PlaybackApp?
    /// A reply slower than this costs the show visible frames.
    private static let slowReply: TimeInterval = 0.25
    private static let restAfterSlowReply: TimeInterval = 10
    private(set) var permission: NowPlayingPermission = .unknown {
        didSet { if permission != oldValue { onPermission?(permission) } }
    }

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         running: @escaping (PlaybackApp) -> Bool = {
             !NSRunningApplication.runningApplications(withBundleIdentifier: $0.rawValue).isEmpty
         },
         read: ((PlaybackApp) -> (NowPlayingSample?, NowPlayingPermission))? = nil) {
        self.now = now
        self.running = running
        self.sampleReader = read
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
        let time = now()
        var order = PlaybackApp.allCases
        if let lastPlaying { order.removeAll { $0 == lastPlaying }; order.insert(lastPlaying, at: 0) }
        let runningApps = order.filter(running)
        for app in runningApps where (restingUntil[app] ?? 0) <= time {
            guard let sample = read(app) else { continue }
            // A playing app wins over a paused one.
            if sample.isPlaying {
                permission = .granted
                lastPlaying = app
                onSample?(sample)
                return
            }
            if paused == nil { paused = sample }
        }
        // An allowed idle app must not overwrite a denial from the other app.
        // A playing allowed app already returned above and can still be followed.
        permission = runningApps.contains { appPermissions[$0] == .denied } ? .denied
            : runningApps.contains { appPermissions[$0] == .granted } ? .granted : .unknown
        onSample?(paused)
    }

    private func read(_ app: PlaybackApp) -> NowPlayingSample? {
        if let sampleReader {
            let (sample, permission) = sampleReader(app)
            appPermissions[app] = permission
            return sample
        }
        guard let script = script(for: app) else { return nil }
        let before = now()
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        let after = now()
        if after - before > Self.slowReply { restingUntil[app] = after + Self.restAfterSlowReply }
        if let error {
            // -1743: the user declined Automation for this app.
            appPermissions[app] = (error[NSAppleScript.errorNumber] as? Int) == -1743 ? .denied : .unknown
            return nil
        }
        appPermissions[app] = .granted
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
