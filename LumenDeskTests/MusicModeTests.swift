import AVFoundation
import CoreMIDI
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
        var sample = 0
        let first = try XCTUnwrap(analyzer.analyze(buffer(frequency: 880, amplitude: 0.5, startSample: sample)))
        var last = first
        for _ in 0..<10 {
            sample += 1024
            last = try XCTUnwrap(analyzer.analyze(buffer(frequency: 880, amplitude: 0.5, startSample: sample)))
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
        var sample = 0
        var quiet = try XCTUnwrap(analyzer.analyze(buffer(frequency: 440, amplitude: 0.08, startSample: sample)))
        for _ in 0..<8 {
            sample += 1024
            quiet = try XCTUnwrap(analyzer.analyze(buffer(frequency: 440, amplitude: 0.08, startSample: sample)))
        }
        sample += 1024
        let loud = try XCTUnwrap(analyzer.analyze(buffer(frequency: 440, amplitude: 0.9, startSample: sample)))
        XCTAssertGreaterThan(quiet.level, 0.15)
        for value in [quiet.level, quiet.bass, quiet.mids, quiet.highs, loud.level, loud.energy] {
            XCTAssertTrue((0...1).contains(value))
        }
    }

    func testAnalyzerTracksTheMusicalBeatRatherThanEveryTransient() throws {
        let analyzer = MusicFeatureAnalyzer(sourceDescription: "Test")
        let sampleRate = 48_000.0
        let period = 0.5
        let frames: AVAudioFrameCount = 1_024
        var sample = 0
        var lockPoint: (time: TimeInterval, beatCount: Int)?
        var latest: AudioReactiveSnapshot?
        var latestTime: TimeInterval = 0

        while sample < Int(sampleRate * 14) {
            let time = Double(sample) / sampleRate
            let buffer = rhythmBuffer(
                startSample: sample,
                frames: frames,
                sampleRate: sampleRate,
                beatPeriod: period,
                includeHiHats: true
            )
            if let snapshot = analyzer.analyze(buffer, hostTime: time) {
                latest = snapshot
                latestTime = time
                if snapshot.isTempoLocked, lockPoint == nil {
                    lockPoint = (time, snapshot.beatCount)
                }
            }
            sample += Int(frames)
        }

        let snapshot = try XCTUnwrap(latest)
        let lock = try XCTUnwrap(lockPoint, "the analyzer never locked onto a 120 BPM pattern")
        XCTAssertEqual(snapshot.tempo, 120, accuracy: 6)
        XCTAssertEqual(snapshot.beatInterval, period, accuracy: 0.03)
        XCTAssertLessThan(lock.time, 8)

        // Sixteenth-note hats arrive eight times a second. Counting onsets, as
        // the analyzer used to, reports roughly that many "beats" a second and
        // the show cuts colour on every one of them. A beat grid reports two —
        // the pulse a listener would clap to.
        let expectedBeats = (latestTime - lock.time) / period
        XCTAssertEqual(Double(snapshot.beatCount - lock.beatCount), expectedBeats, accuracy: 2.5)
    }

    func testChoreographyPulsesOnTheBeatWhenTempoIsLocked() {
        let engine = MusicChoreographyEngine()
        let fixture = MusicFixtureDescriptor(id: "f", label: "Fixture", transport: .lifxLAN)
        var config = MusicModeConfiguration.configuration(for: .balanced)
        // Isolate the beat: no spatial movement, no flashes.
        config.movementAmount = 0
        config.allowsFlashes = false

        let interval = 0.5
        let reference = 100.0
        var onBeat: [Double] = []
        var offBeat: [Double] = []
        for frame in 0..<160 {
            let timestamp = reference + Double(frame) * 0.025
            let state = engine.makeFrame(
                snapshot: lockedSnapshot(at: timestamp, reference: reference, interval: interval),
                configuration: config,
                topology: FixtureTopology(),
                fixtures: [fixture],
                timestamp: timestamp,
                sequenceNumber: UInt64(frame)
            ).states.first
            // The engine renders slightly ahead to pay for transport latency,
            // so phase is measured the same way it chooses to render.
            let beats = (timestamp + 0.045 - reference) / interval
            let phase = beats - floor(beats)
            guard let brightness = state?.brightness, frame > 20 else { continue }
            if phase < 0.15 { onBeat.append(brightness) }
            if (0.4...0.6).contains(phase) { offBeat.append(brightness) }
        }

        XCTAssertGreaterThan(onBeat.count, 5)
        XCTAssertGreaterThan(offBeat.count, 5)
        let onBeatMean = onBeat.reduce(0, +) / Double(onBeat.count)
        let offBeatMean = offBeat.reduce(0, +) / Double(offBeat.count)
        XCTAssertGreaterThan(
            onBeatMean, offBeatMean * 1.25,
            "brightness should swell on the beat (\(onBeatMean)) versus between beats (\(offBeatMean))"
        )
    }

    func testPaletteHoldsThroughABarInsteadOfChasingTransients() {
        let engine = MusicChoreographyEngine()
        let fixture = MusicFixtureDescriptor(id: "f", label: "Fixture", transport: .lifxLAN)
        let config = MusicModeConfiguration.configuration(for: .balanced)
        let interval = 0.5
        let reference = 50.0

        var hues: [Int] = []
        for frame in 0..<200 {
            let timestamp = reference + Double(frame) * 0.025
            let state = engine.makeFrame(
                snapshot: lockedSnapshot(at: timestamp, reference: reference, interval: interval),
                configuration: config,
                topology: FixtureTopology(),
                fixtures: [fixture],
                timestamp: timestamp,
                sequenceNumber: UInt64(frame)
            ).states.first
            if let hue = state?.hue { hues.append(Int((hue * 1_000).rounded())) }
        }

        let distinct = Set(hues)
        XCTAssertGreaterThan(distinct.count, 1, "the palette should still move across bars")
        // Five seconds is two and a half bars. Colour is held for each musical
        // division and only crosses over at its boundary, so the overwhelming
        // majority of frames repeat the colour of the frame before them.
        XCTAssertLessThan(distinct.count, hues.count / 3)
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

    func testOffRoleIsDroppedFromTargetsLikeExclusion() throws {
        let fixtures = [
            MusicFixtureDescriptor(id: "z", label: "Window", transport: .lifxLAN, role: .wash),
            MusicFixtureDescriptor(id: "a", label: "Desk", transport: .goveeLAN, role: .off),
            MusicFixtureDescriptor(id: "s", label: "Strip", transport: .goveeRealtimeSegments, segmentCount: 3, role: .motion)
        ]
        let topology = FixtureTopology(layout: .custom, fixtureOrder: ["z", "a", "s"])
        XCTAssertEqual(topology.includedFixtures(fixtures).map(\.id), ["z", "s"])
        let targets = topology.expandedTargets(for: fixtures)
        XCTAssertFalse(targets.contains { $0.fixtureID == "a" })
        XCTAssertEqual(targets.map(\.role), [.wash, .motion, .motion, .motion])
    }

    func testHitFixturesAreBrighterOnTheDownbeatThanWash() {
        let engine = MusicChoreographyEngine()
        let hit = MusicFixtureDescriptor(id: "hit", label: "Downstage", transport: .lifxLAN, role: .hit)
        let wash = MusicFixtureDescriptor(id: "wash", label: "Wash", transport: .lifxLAN, role: .wash)
        var config = MusicModeConfiguration.configuration(for: .club)
        config.movementAmount = 0
        config.allowsFlashes = false
        config.photosensitivitySafeMode = true
        let interval = 0.5
        let reference = 40.0
        var hitOn: [Double] = []
        var washOn: [Double] = []
        for frame in 0..<80 {
            let timestamp = reference + Double(frame) * 0.025
            var snapshot = lockedSnapshot(at: timestamp, reference: reference, interval: interval)
            snapshot.kick = 0.9
            snapshot.energy = 0.7
            snapshot.metre = 4
            snapshot.feltInterval = interval
            let frameStates = engine.makeFrame(
                snapshot: snapshot,
                configuration: config,
                topology: FixtureTopology(layout: .custom, fixtureOrder: ["hit", "wash"]),
                fixtures: [hit, wash],
                timestamp: timestamp,
                sequenceNumber: UInt64(frame)
            ).states
            let phase = ((timestamp + 0.045 - reference) / interval)
            let fraction = phase - floor(phase)
            guard frame > 16, fraction < 0.12 else { continue }
            if let hitBrightness = frameStates.first(where: { $0.fixtureID == "hit" })?.brightness {
                hitOn.append(hitBrightness)
            }
            if let washBrightness = frameStates.first(where: { $0.fixtureID == "wash" })?.brightness {
                washOn.append(washBrightness)
            }
        }
        XCTAssertGreaterThan(hitOn.count, 4)
        let hitMean = hitOn.reduce(0, +) / Double(hitOn.count)
        let washMean = washOn.reduce(0, +) / Double(washOn.count)
        XCTAssertGreaterThan(hitMean, washMean, "hit layer should punch harder on the downbeat than wash")
    }

    func testClubHalftimeAndWaltzPresets() {
        let club = MusicModeConfiguration.configuration(for: .club)
        XCTAssertEqual(club.metreOverride, .four)
        XCTAssertEqual(club.timeFeel, .straight)
        let half = MusicModeConfiguration.configuration(for: .halftime)
        XCTAssertEqual(half.timeFeel, .half)
        let waltz = MusicModeConfiguration.configuration(for: .waltz)
        XCTAssertEqual(waltz.metreOverride, .three)
        XCTAssertEqual(MusicModePreset.allCases.count, 9)
    }

    func testLegacyMusicModeConfigurationDecodesWithoutNewKeys() throws {
        let legacyJSON = Data("""
        {"preset":"cinematic","masterBrightness":0.78,"effectIntensity":0.7,"beatSensitivity":0.48,"bassSensitivity":0.68,"percussionSensitivity":0.38,"colorChangeIntensity":0.54,"movementAmount":0.74,"movementDirection":"forward","movementSpeed":0.28,"minimumBrightness":0.08,"maximumBrightness":0.9,"allowsFlashes":true,"flashIntensity":0.34,"maximumFlashFrequency":0.75,"palette":[{"hex":16763914},{"hex":16743628},{"hex":14896243},{"hex":7682959}],"silenceBehavior":"holdPalette","photosensitivitySafeMode":true,"restorePreviousState":true}
        """.utf8)
        let decoded = try JSONDecoder().decode(MusicModeConfiguration.self, from: legacyJSON)
        XCTAssertEqual(decoded.preset, .cinematic)
        XCTAssertNil(decoded.metreOverride)
        XCTAssertEqual(decoded.timeFeel, .auto)
        XCTAssertEqual(decoded.stereoImage, 0.7, accuracy: 0.001)
        XCTAssertTrue(decoded.phraseAware)
        XCTAssertTrue(decoded.photosensitivitySafeMode)
    }

    func testExcludedFixturesAreDroppedFromTargetsAndSpacingCloses() throws {
        let fixtures = [
            MusicFixtureDescriptor(id: "z", label: "Window", transport: .lifxLAN),
            MusicFixtureDescriptor(id: "a", label: "Desk", transport: .goveeLAN),
            MusicFixtureDescriptor(id: "s", label: "Strip", transport: .goveeRealtimeSegments, segmentCount: 3)
        ]
        var topology = FixtureTopology(layout: .custom, fixtureOrder: ["z", "a", "s"])
        topology.excludedFixtureIDs = ["a"]

        XCTAssertEqual(topology.includedFixtures(fixtures).map(\.id), ["z", "s"])

        let targets = topology.expandedTargets(for: fixtures)
        XCTAssertFalse(targets.contains { $0.fixtureID == "a" })
        XCTAssertEqual(targets.count, 4) // "z" plus the 3 segments of "s", "a" excluded
        // With "a" gone, "z" and the start of "s" should bound the sweep,
        // closing the gap "a" would otherwise have left in the middle.
        XCTAssertEqual(try XCTUnwrap(targets.first).position, 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(targets.last).position, 1, accuracy: 0.001)

        // A stale ID from a fixture no longer present should be harmless.
        topology.excludedFixtureIDs = ["a", "no-longer-connected"]
        XCTAssertEqual(topology.includedFixtures(fixtures).map(\.id), ["z", "s"])
    }

    func testFixtureTopologyDecodesWithoutExcludedFixtureIDsKey() throws {
        // Simulates an archive saved before `excludedFixtureIDs` existed.
        let legacyJSON = Data("""
        {"layout":"custom","fixtureOrder":["z","a","s"]}
        """.utf8)
        let decoded = try JSONDecoder().decode(FixtureTopology.self, from: legacyJSON)
        XCTAssertEqual(decoded.fixtureOrder, ["z", "a", "s"])
        XCTAssertEqual(decoded.excludedFixtureIDs, [])
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

    @MainActor
    func testStartMusicModeLeavesExcludedFixtureUntouched() throws {
        let manager = LightManager(persistenceStore: MusicModePersistenceSpy())
        manager.enterDemoMode()
        var config = MusicModeConfiguration.configuration(for: .balanced)
        config.usesSyntheticDemoPattern = true
        let roomScope = LightScope.room(try XCTUnwrap(manager.rooms.first).id)
        let roomDevices = manager.devices(in: roomScope)
        XCTAssertGreaterThanOrEqual(roomDevices.count, 2)
        let excluded = roomDevices[0]
        let included = roomDevices[1]
        excluded.isOn = false
        let excludedOriginalPower = excluded.isOn
        let excludedOriginalBrightness = excluded.brightness
        let excludedOriginalColor = excluded.color

        var topology = manager.fixtureTopology(for: roomScope)
        topology.excludedFixtureIDs = [excluded.id]
        manager.setFixtureTopology(topology, for: roomScope)

        manager.startMusicMode(configuration: config, scope: roomScope)
        // Excluded fixtures are never powered on at start, unlike the rest
        // of the room, and shouldn't be part of the run's undo/restore set.
        XCTAssertEqual(excluded.isOn, excludedOriginalPower)
        XCTAssertTrue(included.isOn)

        manager.musicModeController.renderNowForTesting()
        manager.stopEffect(scope: roomScope)
        XCTAssertEqual(excluded.isOn, excludedOriginalPower)
        XCTAssertEqual(excluded.brightness, excludedOriginalBrightness, accuracy: 0.001)
        XCTAssertLessThan(excluded.color.rgbDistance(to: excludedOriginalColor), 0.001)

        // Toggling exclusion back on while nothing is running still applies.
        manager.setFixtureTopology(FixtureTopology(), for: roomScope)
        XCTAssertTrue(manager.fixtureTopology(for: roomScope).excludedFixtureIDs.isEmpty)
    }

    @MainActor
    func testFixtureExclusionCannotChangeMidShowButLayoutStillCan() throws {
        // A fixture newly included mid-show would receive color frames
        // without ever being powered on or captured in the run's restore
        // snapshot, so exclusion is frozen for the run's lifetime. Order and
        // layout carry no such ownership implications and stay live.
        let manager = LightManager(persistenceStore: MusicModePersistenceSpy())
        manager.enterDemoMode()
        var config = MusicModeConfiguration.configuration(for: .balanced)
        config.usesSyntheticDemoPattern = true
        let roomScope = LightScope.room(try XCTUnwrap(manager.rooms.first).id)
        let fixture = try XCTUnwrap(manager.devices(in: roomScope).first)

        manager.startMusicMode(configuration: config, scope: roomScope)
        XCTAssertTrue(manager.fixtureTopology(for: roomScope).excludedFixtureIDs.isEmpty)

        var attempt = manager.fixtureTopology(for: roomScope)
        attempt.excludedFixtureIDs = [fixture.id]
        attempt.layout = .circular
        manager.setFixtureTopology(attempt, for: roomScope)

        XCTAssertTrue(manager.fixtureTopology(for: roomScope).excludedFixtureIDs.isEmpty)
        XCTAssertEqual(manager.fixtureTopology(for: roomScope).layout, .circular)

        manager.stopEffect(scope: roomScope)
        manager.setFixtureTopology(attempt, for: roomScope)
        XCTAssertEqual(manager.fixtureTopology(for: roomScope).excludedFixtureIDs, [fixture.id])
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

    @MainActor
    func testConcurrentLiveStartsSharePermissionRequestAndBothComplete() {
        let backend = MusicCaptureStub()
        var creations = 0
        let capture = AudioCaptureService(makeSystemAudioCapture: { _ in
            creations += 1
            return backend
        })
        var results: [AudioCaptureService.AudioStartResult] = []
        capture.requestAccessAndStart { results.append($0) }
        capture.requestAccessAndStart { results.append($0) }
        XCTAssertEqual(creations, 1)
        backend.completions.last?(.started)
        XCTAssertEqual(results, [.started, .started])
        capture.stop()
    }

    @MainActor
    func testStopCancelsPendingCaptureImmediately() {
        let backend = MusicCaptureStub()
        let capture = AudioCaptureService(makeSystemAudioCapture: { _ in backend })
        var completed = false
        capture.requestAccessAndStart { _ in completed = true }
        capture.stop()
        XCTAssertGreaterThan(backend.stops, 0)
        backend.completions.last?(.started)
        XCTAssertFalse(capture.isRunning)
        XCTAssertFalse(completed)
    }

    @MainActor
    func testStoppedRoomIgnoresSharedCaptureCompletion() {
        let backend = MusicCaptureStub()
        let capture = AudioCaptureService(makeSystemAudioCapture: { _ in backend })
        let controller = AudioReactiveSessionController(captureService: capture)
        let scopes = [LightScope.room(UUID()), .room(UUID())]
        var completed: [LightScope] = []
        for scope in scopes {
            controller.start(scope: scope, configuration: .configuration(for: .balanced),
                topology: FixtureTopology(), fixtures: [], reducedMotion: false,
                useSyntheticPattern: false, onFrame: { _ in },
                completion: { _ in completed.append(scope) })
        }
        controller.stop(scope: scopes[0])
        backend.completions.last?(.started)
        XCTAssertEqual(completed, [scopes[1]])
        XCTAssertEqual(controller.activeScopeIDs, [scopes[1]])
        controller.stopAll()
    }

    @MainActor
    func testOffRoleCannotChangeMembershipDuringShow() throws {
        let manager = LightManager(persistenceStore: MusicModePersistenceSpy())
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let scope = LightScope.room(try XCTUnwrap(manager.rooms.first).id)
        let devices = manager.devices(in: scope)
        let omitted = try XCTUnwrap(devices.first)
        let included = try XCTUnwrap(devices.last)
        var topology = manager.fixtureTopology(for: scope)
        topology.roles[omitted.id] = .off
        manager.setFixtureTopology(topology, for: scope)
        var config = MusicModeConfiguration.configuration(for: .balanced)
        config.usesSyntheticDemoPattern = true
        manager.startMusicMode(configuration: config, scope: scope)
        topology.roles[omitted.id] = .hit
        topology.roles[included.id] = .off
        manager.setFixtureTopology(topology, for: scope)
        XCTAssertEqual(manager.fixtureTopology(for: scope).role(for: omitted.id), .off)
        XCTAssertNotEqual(manager.fixtureTopology(for: scope).role(for: included.id), .off)
        topology = manager.fixtureTopology(for: scope)
        topology.roles[included.id] = .wash
        manager.setFixtureTopology(topology, for: scope)
        XCTAssertEqual(manager.fixtureTopology(for: scope).role(for: included.id), .wash)
    }

    @MainActor
    func testSecondRoomCannotReplaceSharedSource() {
        let backend = MusicCaptureStub()
        let capture = AudioCaptureService(makeSystemAudioCapture: { _ in backend })
        let controller = AudioReactiveSessionController(captureService: capture)
        let first = LightScope.room(UUID())
        let second = LightScope.room(UUID())
        controller.start(scope: first, configuration: .configuration(for: .balanced),
            topology: FixtureTopology(), fixtures: [], reducedMotion: false,
            useSyntheticPattern: false, onFrame: { _ in }, completion: { _ in })
        backend.completions.last?(.started)
        var result: AudioCaptureService.AudioStartResult?
        controller.start(scope: second, configuration: .configuration(for: .balanced),
            topology: FixtureTopology(), fixtures: [], reducedMotion: false,
            useSyntheticPattern: false, capture: .file(URL(fileURLWithPath: "/missing.wav")),
            onFrame: { _ in }, completion: { result = $0 })
        XCTAssertEqual(result, .unavailable)
        XCTAssertTrue(capture.isRunning)
        XCTAssertEqual(controller.sourceStatus, .systemAudio)
        XCTAssertEqual(controller.activeScopeIDs, [first])
        controller.stopAll()
    }

    func testHalfTimeDoesNotPulseAgainOnInterveningGridBeat() {
        let engine = MusicChoreographyEngine()
        let fixture = MusicFixtureDescriptor(id: "hit", label: "Hit", transport: .lifxLAN, role: .hit)
        var config = MusicModeConfiguration.configuration(for: .halftime)
        config.movementAmount = 0
        config.allowsFlashes = false
        var feltPeaks: [Double] = []
        var intervening: [Double] = []
        for index in 0..<400 {
            let time = 100 + Double(index) * 0.025
            var snapshot = lockedSnapshot(at: time, reference: 100, interval: 0.5)
            snapshot.timeFeel = .half
            snapshot.feltInterval = 1
            let frame = engine.makeFrame(snapshot: snapshot, configuration: config,
                topology: FixtureTopology(), fixtures: [fixture], timestamp: time,
                sequenceNumber: UInt64(index))
            let phase = (time + 0.045 - 100).truncatingRemainder(dividingBy: 1)
            guard index > 40, let brightness = frame.states.first?.brightness else { continue }
            if phase < 0.15 { feltPeaks.append(brightness) }
            if (0.5..<0.65).contains(phase) { intervening.append(brightness) }
        }
        let peak = feltPeaks.reduce(0, +) / Double(feltPeaks.count)
        let between = intervening.reduce(0, +) / Double(intervening.count)
        XCTAssertGreaterThan(peak, between * 1.25)
    }

    func testMIDIClockTracksTempoAndHonorsStopContinueAndStart() {
        var tracker = MIDIBeatClockTracker()
        var time = 10.0
        var latest: AudioReactiveSnapshot?
        for _ in 0..<240 {
            time += 60 / (90 * 24)
            if let snapshot = tracker.receive(0xF8, at: time) { latest = snapshot }
        }
        XCTAssertEqual(latest?.tempo ?? 0, 90, accuracy: 0.1)
        XCTAssertEqual(latest?.beatCount, 9)
        let stopped = tracker.receive(0xFC, at: time)
        XCTAssertEqual(stopped?.isTempoLocked, false)
        for _ in 0..<48 {
            time += 0.02
            XCTAssertNil(tracker.receive(0xF8, at: time))
        }
        _ = tracker.receive(0xFB, at: time)
        for _ in 0..<24 {
            time += 60 / (90 * 24)
            if let snapshot = tracker.receive(0xF8, at: time) { latest = snapshot }
        }
        XCTAssertEqual(latest?.beatCount, 10)
        _ = tracker.receive(0xFA, at: time)
        for _ in 0..<24 {
            time += 60 / (90 * 24)
            if let snapshot = tracker.receive(0xF8, at: time) { latest = snapshot }
        }
        XCTAssertEqual(latest?.beatInBar, 0)
        XCTAssertEqual(latest?.beatCount, 0)
    }

    func testMIDIStartPlacesDownbeatOnFirstClockTick() {
        var tracker = MIDIBeatClockTracker()
        _ = tracker.receive(0xFA, at: 100)
        let first = tracker.receive(0xF8, at: 100)
        XCTAssertEqual(first?.beatInBar, 0)
        XCTAssertEqual(first?.beatReferenceTime, 100)
        for tick in 1..<24 {
            XCTAssertNil(tracker.receive(0xF8, at: 100 + Double(tick) / 48))
        }
        XCTAssertEqual(tracker.receive(0xF8, at: 100.5)?.beatInBar, 1)
    }

    func testMIDIReadsEveryPacketAndPreservesTimestamps() throws {
        let storage = UnsafeMutableRawPointer.allocate(byteCount: 1024, alignment: 8)
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: MIDIPacketList.self, capacity: 1)
        var packet = MIDIPacketListInit(list)
        for index in 0..<24 {
            var byte: UInt8 = 0xF8
            packet = try XCTUnwrap(MIDIPacketListAdd(list, 1024, packet, UInt64(index + 1), 1, &byte))
        }
        var timestamps: [MIDITimeStamp] = []
        MIDIClockSource.forEachMessage(in: UnsafePointer(list)) { byte, timestamp in
            XCTAssertEqual(byte, 0xF8)
            timestamps.append(timestamp)
        }
        XCTAssertEqual(timestamps, (1...24).map(UInt64.init))
    }

    @MainActor
    func testFailedStartupRestoresLightsEvenWhenRestoreOnStopIsDisabled() throws {
        let backend = MusicCaptureStub()
        let controller = AudioReactiveSessionController(
            captureService: AudioCaptureService(makeSystemAudioCapture: { _ in backend }))
        let manager = LightManager(persistenceStore: MusicModePersistenceSpy(), musicModeController: controller)
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let device = try XCTUnwrap(manager.devices.first)
        device.isOn = false
        let brightness = device.brightness
        let color = device.color
        var config = MusicModeConfiguration.configuration(for: .balanced)
        config.usesSyntheticDemoPattern = false
        config.restorePreviousState = false
        manager.startMusicMode(configuration: config)
        XCTAssertTrue(device.isOn)
        backend.completions.last?(.needsScreenRecording)
        XCTAssertFalse(device.isOn)
        XCTAssertEqual(device.brightness, brightness, accuracy: 0.001)
        XCTAssertLessThan(device.color.rgbDistance(to: color), 0.001)
        XCTAssertTrue(manager.activeEffects.isEmpty)
    }

    @MainActor
    func testRestorePreferenceUpdatesDuringShow() throws {
        let manager = LightManager(persistenceStore: MusicModePersistenceSpy())
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let device = try XCTUnwrap(manager.devices.first)
        device.isOn = false
        var config = MusicModeConfiguration.configuration(for: .balanced)
        config.usesSyntheticDemoPattern = true
        manager.startMusicMode(configuration: config)
        config.restorePreviousState = false
        manager.setMusicModeConfiguration(config)
        manager.stopAllEffects()
        XCTAssertTrue(device.isOn)
    }

    @MainActor
    func testAudioFilesAtDifferentFormatsReachAnalyzer() async throws {
        // Silent PCM exercises real file playback and the tap without making
        // sound or contacting a light. The analyzer must receive both formats.
        for (sampleRate, channels) in [(44_100.0, AVAudioChannelCount(1)), (48_000.0, AVAudioChannelCount(2))] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("music-\(UUID()).caf")
            defer { try? FileManager.default.removeItem(at: url) }
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192))
            pcm.frameLength = 8192
            for channel in 0..<Int(channels) {
                pcm.floatChannelData![channel].initialize(repeating: 0, count: 8192)
            }
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: pcm)
            }
            let capture = AudioCaptureService()
            defer { capture.stop() }
            let received = expectation(description: "File feeds analyzer at \(sampleRate) Hz, \(channels) channels")
            var fulfilled = false
            capture.onSnapshot = { snapshot in
                guard !fulfilled else { return }
                fulfilled = true
                XCTAssertEqual(snapshot.sourceDescription, "Audio file")
                XCTAssertLessThan(snapshot.level, 0.001)
                received.fulfill()
            }
            var result: AudioCaptureService.AudioStartResult?
            capture.startFromFile(url: url) { result = $0 }
            XCTAssertEqual(result, .started)
            await fulfillment(of: [received], timeout: 5)
            capture.stop()
            XCTAssertFalse(capture.isRunning)
        }
    }

    /// `startSample` continues the waveform across successive buffers. Analysis
    /// is gapless and its windows straddle buffer boundaries, so restarting the
    /// phase every buffer would put a broadband click at each seam and a "steady
    /// tone" would not be steady.
    private func buffer(
        frequency: Double? = nil,
        amplitude: Float = 0,
        impulse: Bool = false,
        startSample: Int = 0,
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
                let position = Double(startSample + index)
                samples[index] = amplitude * sin(Float(2 * Double.pi * frequency * position / 48_000))
            } else {
                samples[index] = 0
            }
        }
        return buffer
    }

    /// A kick on every beat, optionally with sixteenth-note hats, so onset
    /// density and musical pulse are deliberately different rates.
    private func rhythmBuffer(
        startSample: Int,
        frames: AVAudioFrameCount,
        sampleRate: Double,
        beatPeriod: Double,
        includeHiHats: Bool
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frames) {
            let time = Double(startSample + index) / sampleRate
            let beatPhase = time.truncatingRemainder(dividingBy: beatPeriod)
            var value = 0.9 * exp(-beatPhase / 0.06) * sin(2 * Double.pi * 55 * beatPhase)
            if includeHiHats {
                let hatPhase = time.truncatingRemainder(dividingBy: beatPeriod / 4)
                let decay = exp(-hatPhase / 0.01)
                value += 0.3 * decay * (sin(2 * Double.pi * 8_000 * hatPhase)
                    + 0.7 * sin(2 * Double.pi * 11_500 * hatPhase))
            }
            samples[index] = Float(max(-1, min(1, value)))
        }
        return buffer
    }

    /// The snapshot a locked live session publishes: a beat reference that
    /// advances with the music, which the engine extrapolates its own phase
    /// from.
    private func lockedSnapshot(
        at time: TimeInterval,
        reference: TimeInterval,
        interval: TimeInterval
    ) -> AudioReactiveSnapshot {
        let beats = floor((time - reference) / interval)
        return AudioReactiveSnapshot(
            level: 0.7, beat: 0, kick: 0, snare: 0, percussion: 0,
            bass: 0.5, mids: 0.5, highs: 0.4, energy: 0.6, mood: 0.5,
            confidence: 1, pulse: 0, drop: 0, beatCount: Int(beats),
            tempo: 60 / interval,
            beatInterval: interval,
            beatConfidence: 1,
            beatReferenceTime: reference + beats * interval,
            beatInBar: Int(beats) % BeatTracker.beatsPerBar,
            isTempoLocked: true,
            sourceDescription: "Test"
        )
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

private final class MusicCaptureStub: SystemAudioCapturing {
    var completions: [(SystemAudioStartResult) -> Void] = []
    var stops = 0
    func start(completion: @escaping (SystemAudioStartResult) -> Void) { completions.append(completion) }
    func stop() { stops += 1 }
}

/// The plain-language layer is user-facing writing, so it is guarded the same
/// way behaviour is: every case has to carry copy, that copy has to say
/// something the technical `summary` does not, and it may not smuggle desk
/// jargon back in through the words it uses.
final class MusicModeHelpCopyTests: XCTestCase {
    /// Words that mean nothing to someone who just wants their lamps to blink
    /// along with a song. Appearing in plain-language copy is a failure.
    private let jargon = [
        "topology", "fixture", "rgbic", "hsbk", "onset", "vendor",
        "razer", "ptreal", "downstage", "coalesc", "choreograph",
        "normalized", "hysteresis", "entitlement", "daw"
    ]

    func testEveryPresetCarriesPlainCopy() {
        for preset in MusicModePreset.allCases {
            XCTAssertFalse(preset.plainSummary.isEmpty, "\(preset) has no plain summary")
            XCTAssertFalse(preset.bestFor.isEmpty, "\(preset) has no audience line")
            XCTAssertNotEqual(preset.plainSummary, preset.summary,
                              "\(preset) plain copy just repeats the technical summary")
            assertPlain(preset.plainSummary, label: "preset \(preset)")
            assertPlain(preset.bestFor, label: "preset \(preset) bestFor")
        }
    }

    func testEveryRoleExplainsWhatTheLightDoes() {
        for role in FixtureRole.allCases {
            XCTAssertFalse(role.plainSummary.isEmpty, "\(role) has no plain summary")
            XCTAssertNotEqual(role.plainSummary, role.summary,
                              "\(role) plain copy just repeats the technical summary")
            assertPlain(role.plainSummary, label: "role \(role)")
        }
    }

    func testRemainingChoicesCarryPlainCopy() {
        for value in MusicSilenceBehavior.allCases { assertPlain(value.plainSummary, label: "silence \(value)") }
        for value in MusicMetre.allCases { assertPlain(value.plainSummary, label: "metre \(value)") }
        for value in TimeFeel.allCases { assertPlain(value.plainSummary, label: "feel \(value)") }
        for value in MusicMovementDirection.allCases { assertPlain(value.plainSummary, label: "direction \(value)") }
        for value in FixtureTopologyLayout.allCases { assertPlain(value.plainSummary, label: "layout \(value)") }
    }

    func testPlainCopyIsDistinctPerCase() {
        let presets = Set(MusicModePreset.allCases.map(\.plainSummary))
        XCTAssertEqual(presets.count, MusicModePreset.allCases.count, "two presets share the same explanation")
        let roles = Set(FixtureRole.allCases.map(\.plainSummary))
        XCTAssertEqual(roles.count, FixtureRole.allCases.count, "two roles share the same explanation")
    }

    func testQuickStartIsThreeNumberedSteps() {
        let steps = MusicModeHelp.quickStart
        XCTAssertEqual(steps.map(\.id), [1, 2, 3])
        for step in steps {
            XCTAssertFalse(step.title.isEmpty)
            assertPlain(step.detail, label: "quick start step \(step.id)")
        }
    }

    func testControlHelpAvoidsJargon() {
        let strings: [(String, String)] = [
            ("masterBrightness", MusicModeHelp.masterBrightness),
            ("effectIntensity", MusicModeHelp.effectIntensity),
            ("beatSensitivity", MusicModeHelp.beatSensitivity),
            ("bassSensitivity", MusicModeHelp.bassSensitivity),
            ("percussionSensitivity", MusicModeHelp.percussionSensitivity),
            ("colorChangeIntensity", MusicModeHelp.colorChangeIntensity),
            ("movementAmount", MusicModeHelp.movementAmount),
            ("movementSpeed", MusicModeHelp.movementSpeed),
            ("minimumBrightness", MusicModeHelp.minimumBrightness),
            ("maximumBrightness", MusicModeHelp.maximumBrightness),
            ("allowsFlashes", MusicModeHelp.allowsFlashes),
            ("flashIntensity", MusicModeHelp.flashIntensity),
            ("maximumFlashFrequency", MusicModeHelp.maximumFlashFrequency),
            ("photosensitivitySafeMode", MusicModeHelp.photosensitivitySafeMode),
            ("palette", MusicModeHelp.palette),
            ("stereoImage", MusicModeHelp.stereoImage),
            ("phraseAware", MusicModeHelp.phraseAware),
            ("restorePreviousState", MusicModeHelp.restorePreviousState),
            ("reducedMotion", MusicModeHelp.reducedMotion),
            ("systemAudioSource", MusicModeHelp.systemAudioSource),
            ("fileSource", MusicModeHelp.fileSource),
            ("midiSource", MusicModeHelp.midiSource),
            ("roles", MusicModeHelp.roles),
            ("order", MusicModeHelp.order),
            ("sharedSource", MusicModeHelp.sharedSource),
            ("readout", MusicModeHelp.readout)
        ]
        for (name, copy) in strings { assertPlain(copy, label: name) }
    }

    /// The flash ceiling is a safety promise, so the copy has to keep stating
    /// it even if someone rewrites the sentence around it.
    func testFlashCopyStatesTheHardCeiling() {
        XCTAssertTrue(MusicModeHelp.maximumFlashFrequency.contains("three per second"),
                      "flash copy must state the hard ceiling in words")
        XCTAssertEqual(FlashSafetyLimiter.hardMaximumFrequency, 3, accuracy: 0.0001)
    }

    private func assertPlain(_ copy: String, label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(copy.isEmpty, "\(label) is empty", file: file, line: line)
        let lowered = copy.lowercased()
        for word in jargon where lowered.contains(word) {
            XCTFail("\(label) uses desk jargon: \(word)", file: file, line: line)
        }
    }
}
