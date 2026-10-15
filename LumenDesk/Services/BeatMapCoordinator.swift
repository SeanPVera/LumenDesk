import AVFoundation
import Foundation

/// What the beat-map side of Music Mode is doing, for the status line.
enum BeatMapStatus: Equatable {
    case off
    case analyzingFile(progress: Double)
    case fileReady(tempo: Double)
    case noSteadyBeat
    case waitingForPlayer
    case learning(app: String, title: String, coverage: Double)
    case following(app: String, title: String, tempo: Double)
    case automationDenied

    var summary: String {
        switch self {
        case .off:
            return "Listening live"
        case .analyzingFile(let progress):
            return "Mapping beats… \(Int((progress * 100).rounded()))%. Live listening runs meanwhile."
        case .fileReady(let tempo):
            return "Beat map ready · \(Int(tempo.rounded())) BPM. Lights follow the file's own clock."
        case .noSteadyBeat:
            return "No steady beat found, so the show keeps listening live."
        case .waitingForPlayer:
            return "Waiting for Spotify or Music to play."
        case .learning(let app, let title, let coverage):
            let name = title.isEmpty ? "this track" : "“\(title)”"
            return "Learning \(name) from \(app) · \(Int((coverage * 100).rounded()))%. The next listen plays from its beat map."
        case .following(let app, let title, let tempo):
            let name = title.isEmpty ? "the track" : "“\(title)”"
            return "Following \(name) in \(app) from its beat map · \(Int(tempo.rounded())) BPM."
        case .automationDenied:
            return "LumenDesk is not allowed to ask Spotify or Music where the song is. Allow it in System Settings › Privacy & Security › Automation."
        }
    }

    /// True while a map is setting the grid.
    var isPlayingMap: Bool {
        switch self {
        case .fileReady, .following: return true
        default: return false
        }
    }
}

/// Turns beat maps into timing for a running show: analyses a playing file
/// ahead of time, or follows Spotify and Music by position, learning each
/// streamed track on its first listen and aligning later listens against the
/// live audio. Main thread only.
final class BeatMapCoordinator {
    var onStatusChange: ((BeatMapStatus) -> Void)?
    private(set) var status: BeatMapStatus = .off {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }

    private enum Source { case none, file, following }

    private final class AnalysisToken {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    }

    private let store: BeatMapStore
    private let now: () -> TimeInterval
    private var source: Source = .none
    private var map: BeatMap?

    private var analysis: AnalysisToken?
    private var fileKey: String?

    private(set) var clock = PlaybackClock()
    private var learner: BeatMapLearner?
    private var current: NowPlayingSample?
    private var liveOnsets: [HopFeature] = []
    private var lastAlignment = -Double.greatestFiniteMagnitude
    private var automationDenied = false
    #if os(macOS)
    private var monitor: NowPlayingMonitor?
    #endif

    /// Seconds of live onsets kept for alignment.
    private static let alignmentWindow: TimeInterval = 6
    private static let alignmentInterval: TimeInterval = 2

    init(store: BeatMapStore = BeatMapStore(),
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.store = store
        self.now = now
    }

    var isFollowing: Bool { source == .following }

    func stop() {
        analysis?.cancel()
        analysis = nil
        fileKey = nil
        endTrack()
        #if os(macOS)
        monitor?.stop()
        monitor = nil
        #endif
        source = .none
        map = nil
        clock.reset()
        current = nil
        liveOnsets.removeAll()
        automationDenied = false
        status = .off
    }

    // MARK: - Files

    /// Starts using a map for a playing file: the cached one, or one analysed
    /// now on a background queue while the live show runs.
    func beginFile(reader: AVAudioFile, key: String) {
        if source == .file, fileKey == key { return }
        stop()
        source = .file
        fileKey = key
        if let cached = store.load(key: key) {
            adoptFileMap(cached)
            return
        }
        status = .analyzingFile(progress: 0)
        let token = AnalysisToken()
        analysis = token
        let store = self.store
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var lastReported = -1.0
            let built = BeatMapBuilder.analyze(file: reader, progress: { fraction in
                guard fraction - lastReported >= 0.05 || fraction >= 1 else { return }
                lastReported = fraction
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.analysis === token else { return }
                    self.status = .analyzingFile(progress: fraction)
                }
            }, shouldContinue: { !token.isCancelled })
            if let built { store.save(built, key: key) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.analysis === token else { return }
                self.analysis = nil
                if let built {
                    self.adoptFileMap(built)
                } else {
                    self.status = .noSteadyBeat
                }
            }
        }
    }

    private func adoptFileMap(_ candidate: BeatMap) {
        if candidate.isPlayable {
            map = candidate
            status = .fileReady(tempo: candidate.tempo)
        } else {
            map = nil
            status = .noSteadyBeat
        }
    }

    // MARK: - Following Spotify and Music

    /// Starts asking Spotify and Music where the song is. macOS only.
    func beginFollowing() {
        #if os(macOS)
        guard source != .following else { return }
        stop()
        source = .following
        status = .waitingForPlayer
        let monitor = NowPlayingMonitor(now: now)
        monitor.onSample = { [weak self] sample in self?.receive(sample) }
        monitor.onPermission = { [weak self] permission in
            guard let self else { return }
            self.automationDenied = permission == .denied
            self.updateFollowingStatus()
        }
        self.monitor = monitor
        monitor.start()
        #endif
    }

    /// One reading from the player, or nil when nothing is playing.
    func receive(_ sample: NowPlayingSample?) {
        guard source == .following else { return }
        guard let sample, sample.duration > 0 else {
            endTrack()
            current = nil
            map = nil
            clock.reset()
            updateFollowingStatus()
            return
        }
        let key = sample.app.trackKey(sample.trackID)
        if current.map({ $0.app.trackKey($0.trackID) }) != key {
            endTrack()
            clock.reset()
            liveOnsets.removeAll()
            if let cached = store.load(key: key), cached.isPlayable {
                map = cached
                learner = nil
            } else {
                map = nil
                learner = BeatMapLearner(key: key, duration: sample.duration)
            }
        }
        current = sample
        clock.report(position: sample.position, at: sample.sampledAt, playing: sample.isPlaying)
        updateFollowingStatus()
    }

    /// Hops analysed since the last render tick, with host times.
    func consume(hops: [HopFeature]) {
        guard source == .following, clock.isKnown, !hops.isEmpty else { return }
        for hop in hops {
            liveOnsets.append(hop)
            if clock.isPlaying { learner?.add(hop, position: clock.position(at: hop.time)) }
        }
        if let newest = liveOnsets.last?.time,
           let drop = liveOnsets.firstIndex(where: { $0.time >= newest - Self.alignmentWindow - 1 }), drop > 0 {
            liveOnsets.removeFirst(drop)
        }
        // A track heard to its end becomes a map before it ends, so a repeat
        // or a replay plays from it straight away.
        if let learner, learner.isComplete, let current,
           clock.position(at: now()) >= current.duration - 3 {
            finishLearning(learner)
        }
        updateFollowingStatus()
    }

    // MARK: - Rendering

    /// The snapshot the show should render: the map's grid when one is
    /// playing, otherwise the live snapshot unchanged.
    func apply(to snapshot: AudioReactiveSnapshot, at timestamp: TimeInterval,
               filePosition: TimeInterval?) -> AudioReactiveSnapshot {
        guard let map else { return snapshot }
        switch source {
        case .file:
            guard let filePosition else { return snapshot }
            return map.apply(to: snapshot, position: filePosition, timestamp: timestamp)
        case .following:
            guard clock.isKnown, clock.isPlaying else { return snapshot }
            alignIfDue(map, at: timestamp)
            return map.apply(to: snapshot, position: clock.position(at: timestamp), timestamp: timestamp)
        case .none:
            return snapshot
        }
    }

    // MARK: - Private

    private func alignIfDue(_ map: BeatMap, at timestamp: TimeInterval) {
        guard timestamp - lastAlignment >= Self.alignmentInterval,
              let first = liveOnsets.first, let last = liveOnsets.last,
              last.time - first.time >= 4 else { return }
        lastAlignment = timestamp
        let rate = BeatMap.envelopeRate
        let count = Int(min(Self.alignmentWindow, last.time - first.time) * rate)
        guard count > 1 else { return }
        var live = [Double](repeating: 0, count: count)
        var j = 0
        for i in 0..<count {
            let t = last.time - Double(count - 1 - i) / rate
            while j + 1 < liveOnsets.count, liveOnsets[j + 1].time <= t { j += 1 }
            let a = liveOnsets[j], b = liveOnsets[min(j + 1, liveOnsets.count - 1)]
            if b.time > a.time, t > a.time {
                live[i] = a.onset + (b.onset - a.onset) * (t - a.time) / (b.time - a.time)
            } else {
                live[i] = a.onset
            }
        }
        let expectedEnd = clock.position(at: last.time)
        if let result = BeatMapAligner.align(live: live, map: map, endPosition: expectedEnd), result.isTrustworthy {
            clock.nudge(result.offset)
        }
    }

    /// Saves what the learner heard if it covers the track; a track cut short is dropped.
    private func endTrack() {
        guard let learner else { return }
        self.learner = nil
        guard learner.isComplete else { return }
        let store = self.store
        DispatchQueue.global(qos: .utility).async {
            if let built = learner.makeMap() { store.save(built, key: learner.key) }
        }
    }

    private func finishLearning(_ finished: BeatMapLearner) {
        learner = nil
        let store = self.store
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let built = finished.makeMap()
            if let built { store.save(built, key: finished.key) }
            DispatchQueue.main.async { [weak self] in
                guard let self, let built, built.isPlayable, self.source == .following,
                      let current = self.current, current.app.trackKey(current.trackID) == finished.key else { return }
                self.map = built
                self.updateFollowingStatus()
            }
        }
    }

    private func updateFollowingStatus() {
        guard source == .following else { return }
        if automationDenied { status = .automationDenied; return }
        guard let current else { status = .waitingForPlayer; return }
        if let map {
            status = .following(app: current.app.displayName, title: current.title, tempo: map.tempo)
        } else if let learner {
            // Whole 5 % steps, so the status line does not redraw every frame.
            status = .learning(app: current.app.displayName, title: current.title,
                               coverage: (learner.coverage * 20).rounded(.down) / 20)
        } else {
            status = .waitingForPlayer
        }
    }
}
