import Foundation
import SwiftUI

enum MusicAudioSourceStatus: Equatable {
    case idle
    case requestingPermission
    case systemAudio
    case microphone
    case syntheticDemo
    case permissionDenied
    case unavailable

    var displayName: String {
        switch self {
        case .idle: return "Not running"
        case .requestingPermission: return "Checking permission"
        case .systemAudio: return "System audio"
        case .microphone: return "Microphone input"
        case .syntheticDemo: return "Synthetic demo rhythm"
        case .permissionDenied: return "Permission required"
        case .unavailable: return "Audio source unavailable"
        }
    }
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
        let startedAt: TimeInterval
        let engine = MusicChoreographyEngine()
        let onFrame: (MusicLightingFrame) -> Void

        init(
            configuration: MusicModeConfiguration,
            topology: FixtureTopology,
            fixtures: [MusicFixtureDescriptor],
            reducedMotion: Bool,
            synthetic: Bool,
            startedAt: TimeInterval,
            onFrame: @escaping (MusicLightingFrame) -> Void
        ) {
            self.configuration = configuration
            self.topology = topology
            self.fixtures = fixtures
            self.reducedMotion = reducedMotion
            self.synthetic = synthetic
            self.startedAt = startedAt
            self.onFrame = onFrame
        }
    }

    @Published private(set) var latestSnapshot = AudioReactiveSnapshot()
    @Published private(set) var sourceStatus: MusicAudioSourceStatus = .idle
    @Published private(set) var activeScopeIDs: Set<LightScope> = []
    @Published private(set) var latestFrames: [LightScope: MusicLightingFrame] = [:]
    @Published private(set) var isAudioPlaying = false

    private let captureService: AudioCaptureService
    private let now: () -> TimeInterval
    private var subscriptionToken: AudioCaptureService.SubscriptionToken?
    private var sessions: [LightScope: Session] = [:]
    private var renderTimer: Timer?
    private var sequenceNumber: UInt64 = 0

    init(
        captureService: AudioCaptureService = AudioCaptureService(),
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.captureService = captureService
        self.now = now
        subscriptionToken = captureService.subscribe { [weak self] snapshot in
            Task { @MainActor in
                guard let self else { return }
                self.latestSnapshot = snapshot
                self.isAudioPlaying = snapshot.confidence >= 0.025
                    || snapshot.level >= 0.025
                    || snapshot.energy >= 0.035
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
        onFrame: @escaping (MusicLightingFrame) -> Void,
        completion: @escaping (AudioCaptureService.AudioStartResult) -> Void
    ) {
        let startTime = now()
        sessions[scope] = Session(
            configuration: configuration,
            topology: topology,
            fixtures: fixtures,
            reducedMotion: reducedMotion,
            synthetic: useSyntheticPattern,
            startedAt: startTime,
            onFrame: onFrame
        )
        activeScopeIDs.insert(scope)
        startRenderTimerIfNeeded()

        if useSyntheticPattern {
            sourceStatus = .syntheticDemo
            isAudioPlaying = true
            completion(.started)
            return
        }

        sourceStatus = .requestingPermission
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
        renderTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.renderTick() }
        }
        renderTimer?.tolerance = 0.004
    }

    private func renderTick() {
        guard !sessions.isEmpty else { return }
        let timestamp = now()
        sequenceNumber &+= 1
        for (scope, session) in sessions {
            let snapshot = session.synthetic
                ? syntheticSnapshot(elapsed: max(0, timestamp - session.startedAt))
                : latestSnapshot
            if session.synthetic {
                latestSnapshot = snapshot
                isAudioPlaying = true
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
            latestFrames[scope] = frame
            session.onFrame(frame)
        }
    }

    private func syntheticSnapshot(elapsed: TimeInterval) -> AudioReactiveSnapshot {
        let beatLength = 0.5
        let beatIndex = Int(floor(elapsed / beatLength))
        let beatPhase = elapsed.truncatingRemainder(dividingBy: beatLength)
        let quarterPhase = elapsed.truncatingRemainder(dividingBy: beatLength / 2)
        let pulse = max(0, 1 - beatPhase / 0.16)
        let highTick = max(0, 1 - quarterPhase / 0.055)
        let kick = beatIndex.isMultiple(of: 2) ? pulse : pulse * 0.3
        let snare = beatIndex.isMultiple(of: 2) ? pulse * 0.18 : pulse * 0.9
        let bass = 0.3 + 0.45 * (0.5 + 0.5 * sin(elapsed * .pi))
        let mids = 0.28 + 0.24 * (0.5 + 0.5 * sin(elapsed * 1.7 + 0.8))
        let highs = 0.18 + highTick * 0.55
        let energy = min(1, 0.32 + bass * 0.34 + pulse * 0.28 + highs * 0.12)
        return AudioReactiveSnapshot(
            level: 0.38 + pulse * 0.34,
            beat: beatPhase < 0.04 ? max(kick, snare) : 0,
            kick: kick,
            snare: snare,
            percussion: highTick,
            bass: bass,
            mids: mids,
            highs: highs,
            energy: energy,
            mood: 0.42 + highs * 0.25,
            confidence: 1,
            pulse: pulse,
            drop: energy > 0.72 ? 0.7 : 0,
            beatCount: beatIndex,
            sourceDescription: "Synthetic demo rhythm"
        )
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
        isAudioPlaying = false
    }
}
