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
            return "Learning \(name) from \(app) · \(Int((coverage * 100).rounded()))%. Progress is saved between listens."
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
    private let learningQueue: DispatchQueue
    /// Makes an immediate repeat independent of an outstanding disk write.
    private var savedLearning: [String: BeatMapLearner] = [:]
    private var savedLearningOrder: [String] = []
    private var buildsInFlight: Set<String> = []
    private var builtCoverage: [String: Double] = [:]
    private var lastCheckpointAt = -Double.greatestFiniteMagnitude
    private var current: NowPlayingSample?
    private var liveOnsets: [HopFeature] = []
    private var lastAlignment = -Double.greatestFiniteMagnitude
    private var acceptsHopsSince = -Double.greatestFiniteMagnitude
    private var automationDenied = false
    #if os(macOS)
    private var monitor: NowPlayingMonitor?
    #endif

    /// Seconds of live onsets kept for alignment.
    private static let alignmentWindow: TimeInterval = 6
    private static let alignmentInterval: TimeInterval = 2

    init(store: BeatMapStore = BeatMapStore(),
         learningQueue: DispatchQueue = DispatchQueue(label: "LumenDesk.beat-map-learning", qos: .utility),
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.store = store
        self.learningQueue = learningQueue
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
        lastAlignment = -Double.greatestFiniteMagnitude
        acceptsHopsSince = -Double.greatestFiniteMagnitude
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
    func beginFollowing(startMonitor: Bool = true) {
        #if os(macOS)
        guard source != .following else { return }
        stop()
        source = .following
        status = .waitingForPlayer
        guard startMonitor else { return }
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
            resetLiveHistory(since: now())
            updateFollowingStatus()
            return
        }
        let key = sample.app.trackKey(sample.trackID)
        if current.map({ $0.app.trackKey($0.trackID) }) != key {
            endTrack()
            clock.reset()
            resetLiveHistory(since: sample.sampledAt)
            let progress = savedLearning[key].flatMap { abs($0.duration - sample.duration) < 1 ? $0 : nil }
                ?? store.loadLearning(key: key, duration: sample.duration)
            if let cached = store.load(key: key) {
                map = cached.isPlayable ? cached : nil
                // Extend an early map through the rest of the track while it
                // already drives the show. Existing full maps need no learner.
                learner = progress ?? (cached.duration < sample.duration * 0.98
                    ? BeatMapLearner(key: key, duration: sample.duration) : nil)
            } else {
                map = nil
                if !buildsInFlight.contains(key) { builtCoverage.removeValue(forKey: key) }
                learner = progress ?? BeatMapLearner(key: key, duration: sample.duration)
            }
            learner?.restart()
            lastCheckpointAt = sample.sampledAt
        }
        current = sample
        let wasPlaying = clock.isPlaying
        let result = clock.report(position: sample.position, at: sample.sampledAt, playing: sample.isPlaying)
        if result == .jumped || wasPlaying != sample.isPlaying {
            // A clock discontinuity invalidates the old correspondence between
            // host time and track position, even if a pause kept that position.
            learner?.restart()
            resetLiveHistory(since: sample.sampledAt)
        }
        updateFollowingStatus()
    }

    /// Hops analysed since the last render tick, with host times.
    func consume(hops: [HopFeature]) {
        guard source == .following, clock.isKnown, clock.isPlaying, !hops.isEmpty else { return }
        for hop in hops where hop.time >= acceptsHopsSince {
            if let previous = liveOnsets.last {
                if hop.time <= previous.time { continue }
                if hop.time - previous.time > 0.5 {
                    learner?.restart()
                    resetLiveHistory(since: hop.time)
                }
            }
            liveOnsets.append(hop)
            learner?.add(hop, position: clock.position(at: hop.time))
        }
        if let newest = liveOnsets.last?.time,
           let drop = liveOnsets.firstIndex(where: { $0.time >= newest - Self.alignmentWindow - 1 }), drop > 0 {
            liveOnsets.removeFirst(drop)
        }
        // Build as soon as enough audio is known. Waiting for the last three
        // seconds loses the map to crossfade, skip and same-track repeat.
        if let learner {
            if needsBuild(learner) {
                finishLearning(learner)
            } else if now() - lastCheckpointAt >= 15 {
                checkpoint(learner)
            }
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

    private func resetLiveHistory(since timestamp: TimeInterval) {
        liveOnsets.removeAll(keepingCapacity: true)
        lastAlignment = -Double.greatestFiniteMagnitude
        acceptsHopsSince = timestamp
    }

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

    private func checkpoint(_ progress: BeatMapLearner) {
        savedLearning[progress.key] = progress
        savedLearningOrder.removeAll { $0 == progress.key }
        savedLearningOrder.append(progress.key)
        // Disk remains the durable cache; keep only a few recent recordings in RAM.
        if savedLearningOrder.count > 8 {
            savedLearning.removeValue(forKey: savedLearningOrder.removeFirst())
        }
        lastCheckpointAt = now()
        let store = self.store
        learningQueue.async { store.saveLearning(progress) }
    }

    /// Save partial progress too. A pause, skip, Stop or relaunch must not
    /// require another uninterrupted playthrough from the beginning.
    private func endTrack() {
        guard let learner else { return }
        self.learner = nil
        if needsBuild(learner) {
            finishLearning(learner)
        } else if (builtCoverage[learner.key] ?? 0) < 0.99 {
            checkpoint(learner)
        }
    }

    private func needsBuild(_ progress: BeatMapLearner) -> Bool {
        let built = builtCoverage[progress.key] ?? 0
        return progress.isComplete && (progress.coverage - built >= 0.05
            || (progress.coverage >= 0.99 && built < 0.99))
    }

    private func finishLearning(_ finished: BeatMapLearner) {
        guard buildsInFlight.insert(finished.key).inserted else { return }
        builtCoverage[finished.key] = finished.coverage
        checkpoint(finished)
        let store = self.store
        learningQueue.async { [weak self] in
            let built = finished.makeMap()
            if let built {
                store.save(built, key: finished.key)
                if finished.coverage >= 0.99 { store.removeLearning(key: finished.key) }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.buildsInFlight.remove(finished.key)
                if built != nil, finished.coverage >= 0.99 {
                    self.savedLearning.removeValue(forKey: finished.key)
                    self.savedLearningOrder.removeAll { $0 == finished.key }
                }
                guard self.source == .following,
                      let current = self.current, current.app.trackKey(current.trackID) == finished.key else { return }
                // A failed refinement must not replace an already usable map.
                if let built, built.isPlayable { self.map = built }
                if finished.coverage >= 0.99 { self.learner = nil }
                self.updateFollowingStatus()
            }
        }
    }

    private func updateFollowingStatus() {
        guard source == .following else { return }
        if automationDenied { status = .automationDenied; return }
        guard let current else { status = .waitingForPlayer; return }
        // A paused player plays no map and teaches nothing, so don't claim either.
        guard current.isPlaying else { status = .waitingForPlayer; return }
        if let map {
            status = .following(app: current.app.displayName, title: current.title, tempo: map.tempo)
        } else if let learner {
            // Whole 5 % steps, so the status line does not redraw every frame.
            status = .learning(app: current.app.displayName, title: current.title,
                               coverage: (learner.coverage * 20).rounded(.down) / 20)
        } else {
            status = .noSteadyBeat
        }
    }
}
