import AVFoundation
import SwiftUI
import XCTest
@testable import LumenDesk

final class MusicModeTests: XCTestCase {
    func testSilenceProducesQuietBoundedFeatures() throws {
        let analyzer = MusicFeatureAnalyzer(sourceDescription: "Test")
        let snapshot = try XCTUnwrap(analyzer.analyze(buffer()))
        XCTAssertEqual(snapshot.level, 0, accuracy: 0.001)
        XCTAssertEqual(snapshot.energy, 0, accuracy: 0.001)
        XCTAssertEqual(snapshot.beatCount, 0)
        XCTAssertEqual(snapshot.sourceDescription, "Test")
    }

    func testSteadyToneCreatesOneOnsetThenSettles() throws {
        let analyzer = MusicFeatureAnalyzer(sourceDescription: "Test")
        let first = try XCTUnwrap(analyzer.analyze(buffer(frequency: 880, amplitude: 0.5)))
        var last = first
        for _ in 0..<10 {
            last = try XCTUnwrap(analyzer.analyze(buffer(frequency: 880, amplitude: 0.5)))
        }
        XCTAssertGreaterThan(first.snare + first.percussion, last.snare + last.percussion)
        XCTAssertLessThanOrEqual(last.beatCount, 1)
    }

    func testBassFrequencyDominatesHighBand() throws {
        let analyzer = MusicFeatureAnalyzer(sourceDescription: "Test")
        let snapshot = try XCTUnwrap(analyzer.analyze(buffer(frequency: 94, amplitude: 0.65)))
        XCTAssertGreaterThan(snapshot.bass, snapshot.highs)
        XCTAssertGreaterThan(snapshot.kick, 0.1)
    }

    func testPercussiveImpulseProducesOnset() throws {
        let analyzer = MusicFeatureAnalyzer(sourceDescription: "Test")
        let snapshot = try XCTUnwrap(analyzer.analyze(buffer(impulse: true)))
        XCTAssertGreaterThan(max(snapshot.kick, snapshot.snare, snapshot.percussion), 0.1)
        XCTAssertGreaterThan(snapshot.pulse, 0.1)
    }

    func testBeatCooldownRejectsRapidSecondImpulse() throws {
        let analyzer = MusicFeatureAnalyzer(sourceDescription: "Test")
        let first = try XCTUnwrap(analyzer.analyze(buffer(impulse: true)))
        _ = analyzer.analyze(buffer())
        let tooSoon = try XCTUnwrap(analyzer.analyze(buffer(impulse: true)))
        XCTAssertEqual(tooSoon.beatCount, first.beatCount)

        for _ in 0..<7 { _ = analyzer.analyze(buffer()) }
        let afterCooldown = try XCTUnwrap(analyzer.analyze(buffer(impulse: true)))
        XCTAssertGreaterThan(afterCooldown.beatCount, tooSoon.beatCount)
    }

    func testAdaptiveNormalizationMakesQuietSignalUsefulAndAlwaysBounded() throws {
        let analyzer = MusicFeatureAnalyzer(sourceDescription: "Test")
        var quiet = try XCTUnwrap(analyzer.analyze(buffer(frequency: 440, amplitude: 0.08)))
        for _ in 0..<8 {
            quiet = try XCTUnwrap(analyzer.analyze(buffer(frequency: 440, amplitude: 0.08)))
        }
        let loud = try XCTUnwrap(analyzer.analyze(buffer(frequency: 440, amplitude: 0.9)))
        XCTAssertGreaterThan(quiet.level, 0.15)
        for value in [quiet.level, quiet.bass, quiet.mids, quiet.highs, loud.level, loud.energy] {
            XCTAssertTrue((0...1).contains(value))
        }
    }

    func testTopologyUsesDeterministicFallbackAndExplicitOrder() throws {
        let fixtures = [
            MusicFixtureDescriptor(id: "z", label: "Window", transport: .lifxLAN),
            MusicFixtureDescriptor(id: "a", label: "Desk", transport: .goveeLAN),
            MusicFixtureDescriptor(id: "s", label: "Strip", transport: .goveeRealtimeSegments, segmentCount: 3)
        ]
        let fallback = FixtureTopology()
        XCTAssertEqual(fallback.orderedFixtures(fixtures).map(\.id), ["a", "s", "z"])

        let explicit = FixtureTopology(layout: .custom, fixtureOrder: ["z", "a", "s"])
        XCTAssertEqual(explicit.orderedFixtures(fixtures).map(\.id), ["z", "a", "s"])
        let targets = explicit.expandedTargets(for: fixtures)
        XCTAssertEqual(targets.count, 5)
        XCTAssertEqual(targets.filter { $0.fixtureID == "s" }.compactMap(\.segmentID), [0, 1, 2])
        XCTAssertEqual(try XCTUnwrap(targets.first).position, 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(targets.last).position, 1, accuracy: 0.001)
    }

    func testWaveProgressionAndLightingBounds() {
        let engine = MusicChoreographyEngine()
        let fixtures = (0..<4).map {
            MusicFixtureDescriptor(id: "f\($0)", label: "Fixture \($0)", transport: .lifxLAN)
        }
        let snapshot = AudioReactiveSnapshot(
            level: 0.7, beat: 0.8, kick: 0.9, snare: 0.4, percussion: 0.5,
            bass: 0.8, mids: 0.5, highs: 0.4, energy: 0.75, mood: 0.6,
            confidence: 1, pulse: 0.9, drop: 0, beatCount: 4, sourceDescription: "Test"
        )
        var config = MusicModeConfiguration.configuration(for: .balanced)
        config.movementAmount = 1
        config.movementSpeed = 1
        let first = engine.makeFrame(
            snapshot: snapshot, configuration: config, topology: FixtureTopology(),
            fixtures: fixtures, timestamp: 10, sequenceNumber: 1
        )
        let second = engine.makeFrame(
            snapshot: snapshot, configuration: config, topology: FixtureTopology(),
            fixtures: fixtures, timestamp: 10.25, sequenceNumber: 2
        )
        XCTAssertNotEqual(first.states.map(\.brightness), second.states.map(\.brightness))
        XCTAssertGreaterThan(Set(first.states.map { Int($0.brightness * 1_000) }).count, 1)
        for state in first.states + second.states {
            XCTAssertTrue((0...1).contains(state.hue))
            XCTAssertTrue((0...1).contains(state.saturation))
            XCTAssertTrue((0...1).contains(state.brightness))
        }
    }

    func testFlashFrequencyCannotBeBypassedByRapidEvents() {
        let engine = MusicChoreographyEngine()
        let fixture = MusicFixtureDescriptor(id: "f", label: "Fixture", transport: .lifxLAN)
        var config = MusicModeConfiguration.configuration(for: .concert)
        config.photosensitivitySafeMode = false
        config.allowsFlashes = true
        config.maximumFlashFrequency = 2
        config.flashIntensity = 1
        let impulse = AudioReactiveSnapshot(
            level: 1, beat: 1, kick: 1, snare: 1, percussion: 1, bass: 1,
            mids: 1, highs: 1, energy: 1, mood: 0.5, confidence: 1,
            pulse: 1, drop: 1, beatCount: 1, sourceDescription: "Test"
        )
        let frames = (0..<100).map { index in
            engine.makeFrame(
                snapshot: impulse,
                configuration: config,
                topology: FixtureTopology(),
                fixtures: [fixture],
                timestamp: Double(index) * 0.01,
                sequenceNumber: UInt64(index)
            )
        }
        XCTAssertLessThanOrEqual(frames.filter(\.flashApplied).count, 2)

        config.maximumFlashFrequency = 100
        XCTAssertEqual(config.normalized().maximumFlashFrequency, FlashSafetyLimiter.hardMaximumFrequency)
        config.photosensitivitySafeMode = true
        let safeFrame = MusicChoreographyEngine().makeFrame(
            snapshot: impulse, configuration: config, topology: FixtureTopology(),
            fixtures: [fixture], timestamp: 0, sequenceNumber: 0
        )
        XCTAssertFalse(safeFrame.flashApplied)
    }

    func testRendererCoalescesAndPacesProvidersIndependently() {
        let renderer = MusicLightingRenderer()
        let fast = MusicFixtureDescriptor(id: "fast", label: "Strip", transport: .goveeRealtimeSegments, segmentCount: 1)
        let slow = MusicFixtureDescriptor(id: "slow", label: "Bulb", transport: .goveeLAN)
        let fixtures = [fast, slow]
        func frame(_ sequence: UInt64, brightness: Double) -> MusicLightingFrame {
            MusicLightingFrame(
                states: [
                    .init(fixtureID: "fast", segmentID: 0, hue: 0.2, saturation: 1, brightness: brightness, transitionDuration: 0.04),
                    .init(fixtureID: "slow", hue: 0.8, saturation: 1, brightness: brightness, transitionDuration: 0.1)
                ],
                timestamp: Double(sequence), sequenceNumber: sequence,
                sustainedEnergyEvent: false, flashApplied: false
            )
        }
        XCTAssertEqual(renderer.enqueue(frame(1, brightness: 0.2), fixtures: fixtures, at: 0).count, 2)
        XCTAssertTrue(renderer.enqueue(frame(2, brightness: 0.4), fixtures: fixtures, at: 0.02).isEmpty)
        let fastOnly = renderer.flush(fixtures: fixtures, at: 0.05)
        XCTAssertEqual(fastOnly.map(\.fixtureID), ["fast"])
        XCTAssertEqual(fastOnly.first?.sequenceNumber, 2)
        XCTAssertEqual(fastOnly.first?.states.first?.brightness, 0.4)
        let slowLater = renderer.flush(fixtures: fixtures, at: 0.11)
        XCTAssertEqual(slowLater.map(\.fixtureID), ["slow"])
        XCTAssertEqual(slowLater.first?.sequenceNumber, 2)
    }

    @MainActor
    func testSyntheticSessionStartsStopsAndSupportsMultipleScopes() {
        var time: TimeInterval = 20
        let controller = AudioReactiveSessionController(now: { time })
        let fixture = MusicFixtureDescriptor(id: "f", label: "Fixture", transport: .lifxLAN)
        let roomID = UUID()
        var completions = 0
        for scope: LightScope in [.all, .room(roomID)] {
            controller.start(
                scope: scope,
                configuration: .configuration(for: .balanced),
                topology: FixtureTopology(),
                fixtures: [fixture],
                reducedMotion: false,
                useSyntheticPattern: true,
                onFrame: { _ in },
                completion: { if $0 == .started { completions += 1 } }
            )
        }
        time += 0.25
        controller.renderNowForTesting()
        XCTAssertEqual(completions, 2)
        XCTAssertEqual(controller.activeScopeIDs.count, 2)
        XCTAssertEqual(controller.sourceStatus, .syntheticDemo)
        XCTAssertNotNil(controller.latestFrame(for: .all))
        controller.stop(scope: .all)
        XCTAssertEqual(controller.activeScopeIDs, [.room(roomID)])
        controller.stopAll()
        XCTAssertEqual(controller.sourceStatus, .idle)
    }

    @MainActor
    func testManagerRestoresMusicStateAndAllowsNonOverlappingRoomSessions() throws {
        let manager = LightManager(persistenceStore: MusicModePersistenceSpy())
        manager.enterDemoMode()
        var config = MusicModeConfiguration.configuration(for: .balanced)
        config.usesSyntheticDemoPattern = true
        let roomScopes = manager.rooms.map { LightScope.room($0.id) }
        XCTAssertEqual(roomScopes.count, 2)

        let device = try XCTUnwrap(manager.devices(in: roomScopes[0]).first)
        let originalPower = device.isOn
        let originalBrightness = device.brightness
        let originalColor = device.color
        manager.startMusicMode(configuration: config, scope: roomScopes[0])
        manager.startMusicMode(configuration: config, scope: roomScopes[1])
        manager.musicModeController.renderNowForTesting()
        XCTAssertEqual(manager.activeEffects.count, 2)
        manager.stopEffect(scope: roomScopes[0])
        XCTAssertEqual(device.isOn, originalPower)
        XCTAssertEqual(device.brightness, originalBrightness, accuracy: 0.001)
        XCTAssertLessThan(device.color.rgbDistance(to: originalColor), 0.001)
        XCTAssertEqual(manager.activeEffects.count, 1)
        manager.exitDemoMode()
        XCTAssertFalse(manager.isDemoMode)
        XCTAssertTrue(manager.activeEffects.isEmpty)
    }

    func testMusicConfigurationAndTopologyRoundTripAndMigrate() throws {
        let store = temporaryStore()
        var state = PersistedApplicationState()
        state.musicModeConfiguration = .configuration(for: .cinematic)
        state.fixtureTopologies = ["all": FixtureTopology(layout: .circular, fixtureOrder: ["b", "a"])]
        try store.save(state)
        XCTAssertEqual(store.load().musicModeConfiguration, state.musicModeConfiguration)
        XCTAssertEqual(store.load().fixtureTopologies, state.fixtureTopologies)

        let archive = try store.exportConfiguration(from: state)
        let imported = try store.importingConfiguration(from: archive, into: PersistedApplicationState())
        XCTAssertEqual(imported.musicModeConfiguration, state.musicModeConfiguration)
        XCTAssertEqual(imported.fixtureTopologies, state.fixtureTopologies)

        let legacy = Data("{\"schemaVersion\":1,\"rooms\":[],\"favoriteIDs\":[],\"favoriteRoomIDs\":[],\"favoriteSceneIDs\":[],\"scenes\":[],\"customNames\":{},\"collapsedRooms\":[],\"sunriseHour\":6,\"sunriseMinute\":30,\"sunsetHour\":20,\"sunsetMinute\":30,\"brightnessPresets\":[]}".utf8)
        let migrated = try store.importingConfiguration(from: legacy, into: PersistedApplicationState())
        XCTAssertEqual(migrated.musicModeConfiguration.preset, .soundcheck)
        XCTAssertTrue(migrated.musicModeConfiguration.photosensitivitySafeMode)
    }

    private func buffer(
        frequency: Double? = nil,
        amplitude: Float = 0,
        impulse: Bool = false,
        frames: AVAudioFrameCount = 1024
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frames) {
            if impulse {
                samples[index] = index < 12 ? (index.isMultiple(of: 2) ? 1 : -1) : 0
            } else if let frequency {
                samples[index] = amplitude * sin(Float(2 * Double.pi * frequency * Double(index) / 48_000))
            } else {
                samples[index] = 0
            }
        }
        return buffer
    }

    private func temporaryStore() -> PersistenceStore {
        PersistenceStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("LumenDeskMusicModeTests-\(UUID().uuidString)")
            .appendingPathComponent("state.json"))
    }
}

private final class MusicModePersistenceSpy: ApplicationPersistence {
    private var state = PersistedApplicationState()
    func load() -> PersistedApplicationState { state }
    func save(_ state: PersistedApplicationState) throws { self.state = state }
    func exportConfiguration(from state: PersistedApplicationState) throws -> Data { try JSONEncoder().encode(state) }
    func importingConfiguration(from data: Data, into currentState: PersistedApplicationState) throws -> PersistedApplicationState {
        try JSONDecoder().decode(PersistedApplicationState.self, from: data)
    }
}
