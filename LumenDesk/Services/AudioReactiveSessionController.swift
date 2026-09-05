import Foundation
import SwiftUI

enum MusicAudioSourceStatus: Equatable {
    case idle
    case requestingPermission
    case systemAudio
    case microphone
    case syntheticDemo
    case filePlayback
    case midiClock
    case permissionDenied
    case unavailable

    var displayName: String {
        switch self {
        case .idle: return "Not running"
        case .requestingPermission: return "Checking permission"
        case .systemAudio: return "System audio"
        case .microphone: return "Microphone input"
        case .syntheticDemo: return "Synthetic demo rhythm"
        case .filePlayback: return "Audio file"
        case .midiClock: return "MIDI clock"
        case .permissionDenied: return "Permission required"
        case .unavailable: return "Audio source unavailable"
        }
    }
}

enum MusicCapturePreference: Equatable {
    case platformDefault
    case file(URL)
    case midiClock
}

struct MusicGroove: Equatable, Identifiable {
    let id: String
    let name: String
    let bpm: Double
    let metre: Int
    let feel: TimeFeel
    let summary: String

    static let all: [MusicGroove] = [
        MusicGroove(id: "four", name: "Four on the floor", bpm: 128, metre: 4, feel: .straight, summary: "Kick every beat, snare on 2 and 4."),
        MusicGroove(id: "halftime", name: "Head-nod", bpm: 140, metre: 4, feel: .half, summary: "140 grid, felt 70. Snare on 3."),
        MusicGroove(id: "waltz", name: "Waltz", bpm: 90, metre: 3, feel: .straight, summary: "Kick on 1, lift on 3."),
        MusicGroove(id: "sixeight", name: "Six-eight", bpm: 72, metre: 6, feel: .straight, summary: "Two groups of three. Weight on 1 and 4."),
        MusicGroove(id: "five", name: "Five-count", bpm: 110, metre: 5, feel: .straight, summary: "Odd metre. Kick on 1, snare on 4."),
        MusicGroove(id: "seven", name: "Seven", bpm: 105, metre: 7, feel: .straight, summary: "3+2+2. Kick on 1, snare on 4 and 6."),
        MusicGroove(id: "breaks", name: "Breaks", bpm: 168, metre: 4, feel: .straight, summary: "Fast grid, snare chatter, hats between.")
    ]

    static let fourOnTheFloor = all[0]
}

/// Owns one shared capture service and any number of non-overlapping Music
/// Mode sessions. Analysis arrives continuously; lighting samples it on one
/// controlled render timer rather than sending from raw audio callbacks.
@MainActor
final class AudioReactiveSessionController: ObservableObject {
    private final class Session {
        var configuration: MusicModeConfiguration
        var topology: FixtureTopology
        var fixtures: [MusicFixtureDescriptor]
        var reducedMotion: Bool
        let synthetic: Bool
        var groove: MusicGroove
        let startedAt: TimeInterval
        let engine = MusicChoreographyEngine()
        let onFrame: (MusicLightingFrame) -> Void
        var lastPreviewPublishedAt = -Double.greatestFiniteMagnitude

        init(
            configuration: MusicModeConfiguration,
            topology: FixtureTopology,
            fixtures: [MusicFixtureDescriptor],
            reducedMotion: Bool,
            synthetic: Bool,
            groove: MusicGroove,
            startedAt: TimeInterval,
            onFrame: @escaping (MusicLightingFrame) -> Void
        ) {
            self.configuration = configuration
            self.topology = topology
            self.fixtures = fixtures
            self.reducedMotion = reducedMotion
            self.synthetic = synthetic
            self.groove = groove
            self.startedAt = startedAt
            self.onFrame = onFrame
        }
    }

    @Published private(set) var latestSnapshot = AudioReactiveSnapshot()
    @Published private(set) var sourceStatus: MusicAudioSourceStatus = .idle
    @Published private(set) var activeScopeIDs: Set<LightScope> = []
    @Published private(set) var latestFrames: [LightScope: MusicLightingFrame] = [:]
    @Published private(set) var isAudioPlaying = false
    @Published var selectedGrooveID: String = MusicGroove.fourOnTheFloor.id

    private let captureService: AudioCaptureService
    private let now: () -> TimeInterval
    private var subscriptionToken: AudioCaptureService.SubscriptionToken?
    private var sessions: [LightScope: Session] = [:]
    private var renderTimer: Timer?
    private var sequenceNumber: UInt64 = 0
    private var analysisSnapshot = AudioReactiveSnapshot()
    private var lastSnapshotPublishedAt = -Double.greatestFiniteMagnitude
    private let previewPublicationInterval: TimeInterval = 0.1

    init(
        captureService: AudioCaptureService = AudioCaptureService(),
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.captureService = captureService
        self.now = now
        subscriptionToken = captureService.subscribe { [weak self] snapshot in
            Task { @MainActor in
                guard let self else { return }
                self.analysisSnapshot = snapshot
                let isPlaying = snapshot.confidence >= 0.025
                    || snapshot.level >= 0.025
                    || snapshot.energy >= 0.035
                if self.isAudioPlaying != isPlaying {
                    self.isAudioPlaying = isPlaying
                }
                let timestamp = self.now()
                if snapshot.beat > 0 || timestamp - self.lastSnapshotPublishedAt >= self.previewPublicationInterval {
                    self.latestSnapshot = snapshot
                    self.lastSnapshotPublishedAt = timestamp
                }
            }
        }
    }

    func start(
        scope: LightScope,
        configuration: MusicModeConfiguration,
        topology: FixtureTopology,
        fixtures: [MusicFixtureDescriptor],
        reducedMotion: Bool,
        useSyntheticPattern: Bool,
        capture: MusicCapturePreference = .platformDefault,
        onFrame: @escaping (MusicLightingFrame) -> Void,
        completion: @escaping (AudioCaptureService.AudioStartResult) -> Void
    ) {
        let startTime = now()
        let groove = MusicGroove.all.first { $0.id == selectedGrooveID } ?? MusicGroove.fourOnTheFloor
        sessions[scope] = Session(
            configuration: configuration,
            topology: topology,
            fixtures: fixtures,
            reducedMotion: reducedMotion,
            synthetic: useSyntheticPattern,
            groove: groove,
            startedAt: startTime,
            onFrame: onFrame
        )
        activeScopeIDs.insert(scope)
        startRenderTimerIfNeeded()

        if useSyntheticPattern {
            sourceStatus = .syntheticDemo
            if !isAudioPlaying { isAudioPlaying = true }
            completion(.started)
            return
        }

        sourceStatus = .requestingPermission
        switch capture {
        case .file(let url):
            captureService.startFromFile(url: url) { [weak self] result in
                guard let self else { return }
                switch result {
                case .started:
                    self.sourceStatus = .filePlayback
                case .needsScreenRecording:
                    self.removeFailedSession(scope)
                    self.sourceStatus = .permissionDenied
                case .unavailable:
                    self.removeFailedSession(scope)
                    self.sourceStatus = .unavailable
                }
                completion(result)
            }
        case .midiClock:
            captureService.startFromMIDI { [weak self] result in
                guard let self else { return }
                switch result {
                case .started:
                    self.sourceStatus = .midiClock
                default:
                    self.removeFailedSession(scope)
                    self.sourceStatus = .unavailable
                }
                completion(result)
            }
        case .platformDefault:
            captureService.requestAccessAndStart { [weak self] result in
                guard let self else { return }
                switch result {
                case .started:
                    #if os(macOS)
                    self.sourceStatus = .systemAudio
                    #else
                    self.sourceStatus = .microphone
                    #endif
                case .needsScreenRecording:
                    self.removeFailedSession(scope)
                    self.sourceStatus = .permissionDenied
                case .unavailable:
                    self.removeFailedSession(scope)
                    self.sourceStatus = .unavailable
                }
                completion(result)
            }
        }
    }

    func update(
        scope: LightScope,
        configuration: MusicModeConfiguration,
        topology: FixtureTopology,
        fixtures: [MusicFixtureDescriptor],
        reducedMotion: Bool
    ) {
        guard let session = sessions[scope] else { return }
        session.configuration = configuration
        session.topology = topology
        session.fixtures = fixtures
        session.reducedMotion = reducedMotion
    }

    func setGroove(_ grooveID: String) {
        selectedGrooveID = grooveID
        let groove = MusicGroove.all.first { $0.id == grooveID } ?? MusicGroove.fourOnTheFloor
        for session in sessions.values where session.synthetic {
            session.groove = groove
        }
    }

    func stop(scope: LightScope) {
        sessions.removeValue(forKey: scope)
        activeScopeIDs.remove(scope)
        latestFrames.removeValue(forKey: scope)
        refreshCaptureAndTimerState()
    }

    func stopAll() {
        sessions.removeAll(keepingCapacity: true)
        activeScopeIDs.removeAll(keepingCapacity: true)
        latestFrames.removeAll(keepingCapacity: true)
        refreshCaptureAndTimerState()
    }

    func latestFrame(for scope: LightScope) -> MusicLightingFrame? {
        latestFrames[scope]
    }

    func renderNowForTesting() {
        renderTick()
    }

    private func startRenderTimerIfNeeded() {
        guard renderTimer == nil else { return }
        renderTick()
        // Lighting and preview output do not benefit from display-refresh
        // cadence. Twenty frames per second remains fluid and cuts a third of
        // the choreography, allocation, and main-thread publication work.
        renderTimer = Timer.scheduledTimer(withTimeInterval: 1 / 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.renderTick() }
        }
        renderTimer?.tolerance = 0.01
    }

    private func renderTick() {
        guard !sessions.isEmpty else { return }
        let timestamp = now()
        sequenceNumber &+= 1
        for (scope, session) in sessions {
            let snapshot = applyMusicalPolicy(
                session.synthetic
                    ? syntheticSnapshot(groove: session.groove, startedAt: session.startedAt, timestamp: timestamp)
                    : analysisSnapshot,
                configuration: session.configuration
            )
            if session.synthetic {
                analysisSnapshot = snapshot
                if timestamp - lastSnapshotPublishedAt >= previewPublicationInterval {
                    latestSnapshot = snapshot
                    lastSnapshotPublishedAt = timestamp
                }
                if !isAudioPlaying { isAudioPlaying = true }
            }
            let frame = session.engine.makeFrame(
                snapshot: snapshot,
                configuration: session.configuration,
                topology: session.topology,
                fixtures: session.fixtures,
                timestamp: timestamp,
                sequenceNumber: sequenceNumber,
                reducedMotion: session.reducedMotion
            )
            // Network output keeps the 20 Hz render cadence, but preview cards
            // only need 10 Hz. Keeping those clocks separate prevents every
            // transport frame from invalidating the entire Music Mode UI.
            if frame.flashApplied
                || snapshot.beat > 0
                || timestamp - session.lastPreviewPublishedAt >= previewPublicationInterval {
                latestFrames[scope] = frame
                session.lastPreviewPublishedAt = timestamp
            }
            session.onFrame(frame)
        }
    }

    /// A deterministic pattern for Demo Mode. It reports the same beat grid a
    /// locked live session would, so demo choreography exercises the
    /// beat-synchronized path rather than a separate one. Grooves cover 3/4,
    /// 5/4, 6/8, 7/8 and half-time in addition to four-on-the-floor.
    private func syntheticSnapshot(groove: MusicGroove, startedAt: TimeInterval, timestamp: TimeInterval) -> AudioReactiveSnapshot {
        let elapsed = max(0, timestamp - startedAt)
        let beatLength = 60 / max(1, groove.bpm)
        let metre = max(1, groove.metre)
        let feelMul = groove.feel.intervalMultiplier
        let feltLength = beatLength * feelMul
        let beatIndex = Int(floor(elapsed / beatLength))
        let beatPhase = elapsed.truncatingRemainder(dividingBy: beatLength)
        let feltIndex = Int(floor(elapsed / feltLength))
        let feltPhase = elapsed.truncatingRemainder(dividingBy: feltLength)
        let pulse = hitEnvelope(phase: feltPhase, length: feltLength, decay: groove.feel == .half ? 0.28 : 0.16)
        let hatPhase = elapsed.truncatingRemainder(dividingBy: beatLength / 2)
        let hat = hitEnvelope(phase: hatPhase, length: beatLength / 2, decay: 0.08) * (groove.id == "breaks" ? 0.95 : 0.7)
        let beatInBar = ((beatIndex % metre) + metre) % metre

        var kick = pulse * 0.18
        var snare = 0.06
        switch groove.id {
        case "halftime":
            kick = beatInBar == 0 || beatInBar == 2 ? pulse : pulse * 0.12
            snare = beatInBar == 2 ? pulse * 0.95 : 0.05
        case "waltz":
            kick = beatInBar == 0 ? pulse : beatInBar == 2 ? pulse * 0.35 : pulse * 0.16
            snare = beatInBar == 2 ? pulse * 0.55 : 0.07
        case "sixeight":
            kick = beatInBar == 0 || beatInBar == 3 ? pulse : pulse * 0.14
            snare = beatInBar == 3 ? pulse * 0.7 : (beatInBar == 1 || beatInBar == 4 ? pulse * 0.22 : 0.06)
        case "five":
            kick = beatInBar == 0 ? pulse : beatInBar == 2 ? pulse * 0.4 : pulse * 0.16
            snare = beatInBar == 3 ? pulse * 0.92 : 0.07
        case "seven":
            kick = beatInBar == 0 ? pulse : beatInBar == 3 ? pulse * 0.55 : pulse * 0.14
            snare = beatInBar == 3 || beatInBar == 5 ? pulse * 0.88 : 0.06
        case "breaks":
            kick = beatInBar == 0 || beatInBar == 2 ? pulse : pulse * 0.28
            snare = beatInBar == 1 || beatInBar == 3 ? pulse * 0.95 : hat * 0.35
        default:
            kick = pulse
            snare = beatInBar == 1 || beatInBar == 3 ? pulse * 0.9 : 0.08
        }

        let energy = min(1, 0.32 + kick * 0.34 + snare * 0.2 + hat * 0.12)
        let phrase = feltIndex % 8
        let lift = phrase >= 6 ? 0.12 : 0
        return AudioReactiveSnapshot(
            level: 0.34 + pulse * 0.36 + lift,
            beat: beatPhase < 0.035 ? max(kick, snare) : 0,
            kick: kick,
            snare: snare,
            percussion: hat,
            bass: 0.3 + kick * 0.55,
            mids: 0.26 + snare * 0.34,
            highs: 0.16 + hat * 0.55,
            energy: min(1, energy + lift),
            mood: 0.4 + hat * 0.22 + (groove.metre == 3 ? 0.08 : 0),
            confidence: 1,
            pulse: pulse,
            drop: phrase >= 7 ? 0.7 : (energy > 0.72 ? 0.45 : 0.1),
            beatCount: beatIndex,
            tempo: groove.bpm,
            beatInterval: beatLength,
            beatConfidence: 1,
            beatReferenceTime: startedAt + Double(beatIndex) * beatLength,
            beatInBar: beatInBar,
            isTempoLocked: true,
            metre: metre,
            metreConfidence: 1,
            timeFeel: groove.feel,
            feltInterval: feltLength,
            feltTempo: groove.bpm / feelMul,
            stereo: 0.5 + 0.1 * sin(elapsed * 0.65),
            chroma: [0.22, 0.04, 0.42, 0.05, 0.72, 0.12, 0.06, 0.5, 0.04, 0.24, 0.08, 0.14],
            phrasePosition: phrase,
            energySlope: sin(elapsed / 8) * 0.22 + (phrase >= 6 ? 0.2 : 0),
            sourceDescription: "\(groove.name) · demo grid"
        )
    }

    private func hitEnvelope(phase: TimeInterval, length: TimeInterval, decay: Double) -> Double {
        guard length > 0 else { return 0 }
        let t = max(0, min(1, phase / length))
        if t < 0.018 { return t / 0.018 }
        return exp(-(t - 0.018) / decay)
    }

    /// Applies a preset's metre/feel override on top of the detected grid so
    /// Club stays 4/4, Waltz stays 3/4, and Half-time feels every other beat.
    private func applyMusicalPolicy(
        _ snapshot: AudioReactiveSnapshot,
        configuration: MusicModeConfiguration
    ) -> AudioReactiveSnapshot {
        var next = snapshot
        if let metre = configuration.metreOverride {
            next.metre = metre.rawValue
            if metre.rawValue > 0 {
                next.beatInBar = ((next.beatCount % metre.rawValue) + metre.rawValue) % metre.rawValue
            }
        }
        if configuration.timeFeel != .auto {
            next.timeFeel = configuration.timeFeel
        }
        if next.beatInterval > 0 {
            let multiplier = next.timeFeel.intervalMultiplier
            next.feltInterval = next.beatInterval * multiplier
            next.feltTempo = next.tempo / max(0.25, multiplier)
        }
        return next
    }

    private func removeFailedSession(_ scope: LightScope) {
        sessions.removeValue(forKey: scope)
        activeScopeIDs.remove(scope)
        latestFrames.removeValue(forKey: scope)
        refreshCaptureAndTimerState()
    }

    private func refreshCaptureAndTimerState() {
        let hasLiveSession = sessions.values.contains { !$0.synthetic }
        if !hasLiveSession { captureService.stop() }
        guard sessions.isEmpty else {
            if sessions.values.allSatisfy(\.synthetic) { sourceStatus = .syntheticDemo }
            return
        }
        renderTimer?.invalidate()
        renderTimer = nil
        sourceStatus = .idle
        latestSnapshot = AudioReactiveSnapshot()
        analysisSnapshot = AudioReactiveSnapshot()
        lastSnapshotPublishedAt = -Double.greatestFiniteMagnitude
        isAudioPlaying = false
    }
}
