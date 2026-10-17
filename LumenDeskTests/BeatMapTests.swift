import XCTest
#if canImport(AVFoundation)
import AVFoundation
#endif
@testable import LumenDesk

/// Beat maps, the playback clock, the aligner, tap calibration and the energy
/// gears. The synthetic vectors match `web/app/test/beat-map.test.mjs`, so the
/// two implementations are held to the same answers.
final class BeatMapTests: XCTestCase {
    private static let hop = 512.0 / 48_000

    func testEquallyLoudBarsGetEqualEnergyRegardlessOfOrderOrBarCount() {
        let beats = (0..<16).map { Double($0) * 0.5 }
        let energy = [Double](repeating: 0.45, count: 800)
        let bars = BeatMapBuilder.barEnergies(beats: beats, downbeatOffset: 0, energy: energy)
        XCTAssertEqual(bars.count, 4)
        for value in bars { XCTAssertEqual(value, 0.56, accuracy: 1e-9) }
        XCTAssertEqual(BeatMapBuilder.barEnergies(beats: Array(beats.prefix(4)), downbeatOffset: 0, energy: energy)[0], bars[0], accuracy: 1e-9)
        let mixed = (0..<800).map { $0 < 400 ? 0.2 : 0.8 }
        let ranked = BeatMapBuilder.barEnergies(beats: beats, downbeatOffset: 0, energy: mixed)
        XCTAssertEqual(ranked[0], ranked[1], accuracy: 1e-9)
        XCTAssertEqual(ranked[2], ranked[3], accuracy: 1e-9)
        XCTAssertGreaterThan(ranked[2], ranked[0])
    }

    func testRapidOrBackwardsCalibrationTapsCannotCountAsSeparateBeats() {
        var taps = TapCalibrator()
        for i in 0..<8 { taps.tap(at: 100.06 + Double(i) * 0.01, beatReference: 100, interval: 0.5) }
        XCTAssertEqual(taps.count, 1)
        XCTAssertNil(taps.suggestedOffset(current: 0))
        taps.tap(at: 100, beatReference: 100, interval: 0.5)
        taps.tap(at: 100.56, beatReference: 100.5, interval: 0.5)
        XCTAssertEqual(taps.count, 2)
    }

    /// A beat every `interval` seconds from `firstBeat`, the downbeat on beat
    /// `downbeatBeat` of each four, louder kicks on downbeats, and an energy
    /// step at `loudFrom`.
    private static func syntheticHops(seconds: Double = 60, interval: Double = 0.5, firstBeat: Double = 0.25,
                                      downbeatBeat: Int = 0, loudFrom: Double = 30) -> [HopFeature] {
        var hops: [HopFeature] = []
        var t = 0.0
        while t <= seconds {
            let sinceFirst = t - firstBeat
            let index = Int(floor(sinceFirst / interval))
            let phase = sinceFirst - Double(index) * interval
            let onBeat = sinceFirst >= 0 ? exp(-phase / 0.03) : 0
            let isDownbeat = ((index - downbeatBeat) % 4 + 4) % 4 == 0
            hops.append(HopFeature(
                time: t,
                onset: min(1, onBeat * 0.9 + 0.02),
                kick: onBeat * (isDownbeat ? 1 : 0.35),
                energy: t >= loudFrom ? 0.8 : 0.35
            ))
            t += hop
        }
        return hops
    }

    private static func map(_ hops: [HopFeature] = syntheticHops()) throws -> BeatMap {
        try XCTUnwrap(BeatMapBuilder.build(hops: hops))
    }

    // MARK: - Building

    func testA120BPMGridIsRecoveredWithItsBeatsDownbeatAndLouderSecondHalf() throws {
        let map = try Self.map()
        XCTAssertEqual(map.tempo, 120, accuracy: 1.5)
        for i in 1..<map.beats.count {
            XCTAssertEqual(map.beats[i] - map.beats[i - 1], 0.5, accuracy: 0.03, "interval at \(i)")
        }
        for beat in map.beats {
            let nearest = 0.25 + ((beat - 0.25) / 0.5).rounded() * 0.5
            XCTAssertEqual(beat, nearest, accuracy: 0.03)
        }
        let firstDownbeat = map.beats[map.downbeatOffset]
        XCTAssertLessThan(((firstDownbeat - 0.25) / 0.5).truncatingRemainder(dividingBy: 4), 0.1)
        let early = map.barEnergy[1..<10], late = map.barEnergy[(map.barEnergy.count - 10)..<(map.barEnergy.count - 1)]
        XCTAssertGreaterThan(try XCTUnwrap(late.min()), try XCTUnwrap(early.max()))
        XCTAssertGreaterThan(map.confidence, 0.2)
        XCTAssertEqual(map.envelope.count, Int(floor(map.duration * BeatMap.envelopeRate)) + 1)
        XCTAssertTrue(map.isPlayable)
    }

    func testAPickupPutsTheDownbeatOnTheRightBeatAndGridPositionsOnMultiplesOfFour() throws {
        let map = try Self.map(Self.syntheticHops(downbeatBeat: 2))
        let firstDownbeat = map.beats[map.downbeatOffset]
        let beatNumber = Int(((firstDownbeat - 0.25) / 0.5).rounded())
        XCTAssertEqual(((beatNumber - 2) % 4 + 4) % 4, 0)
        let grid = try XCTUnwrap(map.grid(at: firstDownbeat + 0.01))
        XCTAssertEqual(grid.beatInBar, 0)
        XCTAssertEqual(grid.gridBeatPosition % 4, 0)
        let later = try XCTUnwrap(map.grid(at: map.beats[map.downbeatOffset + 3] + 0.01))
        XCTAssertEqual(later.beatInBar, 3)
    }

    func testTooLittleAudioOrNoPulseBuildsNoMap() {
        XCTAssertNil(BeatMapBuilder.build(hops: Self.syntheticHops(seconds: 5)))
        let flat = Self.syntheticHops(seconds: 30).map {
            HopFeature(time: $0.time, onset: 0.3, kick: 0.1, energy: $0.energy)
        }
        XCTAssertNil(BeatMapBuilder.build(hops: flat))
    }

    // MARK: - Playing

    func testTheGridIsAbsentBeforeTheFirstBeatAndAfterTheLast() throws {
        let map = try Self.map()
        XCTAssertNil(map.grid(at: map.beats[0] - 0.2))
        XCTAssertNil(map.grid(at: try XCTUnwrap(map.beats.last) + 2))
        let middle = try XCTUnwrap(map.grid(at: map.beats[20] + 0.1))
        XCTAssertEqual(middle.beatIndex, 20)
        XCTAssertEqual(middle.interval, 0.5, accuracy: 0.03)
    }

    func testApplyingAMapReplacesTheInferredGridButKeepsLiveLoudness() throws {
        let map = try Self.map()
        var live = AudioReactiveSnapshot()
        live.level = 0.6
        live.energy = 0.7
        live.beatCount = 900
        let applied = map.apply(to: live, position: map.beats[70] + 0.1, timestamp: 500)
        XCTAssertTrue(applied.isTempoLocked)
        XCTAssertTrue(applied.beatMapActive)
        XCTAssertEqual(applied.beatReferenceTime, 500 - 0.1, accuracy: 1e-9)
        XCTAssertEqual(applied.level, 0.6)
        XCTAssertEqual(applied.energy, 0.7)
        XCTAssertEqual(applied.gridBeatPosition, applied.beatCount)
        XCTAssertEqual(applied.beatInBar, try XCTUnwrap(applied.gridBeatPosition) % 4)
        XCTAssertGreaterThan(try XCTUnwrap(applied.barEnergy), 0.5)

        let outside = map.apply(to: live, position: -3, timestamp: 500)
        XCTAssertFalse(outside.beatMapActive)
        XCTAssertNil(outside.barEnergy)
        XCTAssertEqual(outside.beatCount, 900)
    }

    func testTheAlignerFindsAShiftedLiveEnvelopeAndPrefersTheNearestBeat() throws {
        let map = try Self.map()
        let truth = 20.0, shift = 0.12, seconds = 6.0
        let n = Int(seconds * BeatMap.envelopeRate)
        // The live capture is really at truth + shift, while the clock thinks truth.
        let base = Int(((truth + shift - seconds) * BeatMap.envelopeRate).rounded())
        var live: [Double] = []
        for i in 0..<n {
            let noise: Double = 0.02 * sin(Double(i) * 1.7)
            live.append(map.envelope[base + i + 1] + noise)
        }
        let result = try XCTUnwrap(BeatMapAligner.align(live: live, map: map, endPosition: truth))
        XCTAssertTrue(result.isTrustworthy, "\(result)")
        XCTAssertEqual(result.offset, shift, accuracy: 0.02)
        let exact = try XCTUnwrap(BeatMapAligner.align(live: live, map: map, endPosition: truth + shift))
        XCTAssertEqual(exact.offset, 0, accuracy: 0.02)
        XCTAssertNil(BeatMapAligner.align(live: Array(live.prefix(50)), map: map, endPosition: truth))
        XCTAssertNil(BeatMapAligner.align(live: live.map { _ in 0.5 }, map: map, endPosition: truth))
    }

    func testThePlaybackClockDeadReckonsAbsorbsJitterReanchorsOnSeeksAndTakesNudges() {
        var clock = PlaybackClock()
        XCTAssertEqual(clock.report(position: 10, at: 100, playing: true), .started)
        XCTAssertEqual(clock.position(at: 101.5), 11.5, accuracy: 1e-9)
        XCTAssertEqual(clock.report(position: 12.1, at: 102, playing: true), .held)
        XCTAssertEqual(clock.position(at: 102), 12.01, accuracy: 1e-9, "a jittered report only nudges the anchor")
        XCTAssertTrue(clock.nudge(0.1))
        XCTAssertEqual(clock.correction, 0.06, accuracy: 1e-9)
        XCTAssertFalse(clock.nudge(0.005))
        XCTAssertFalse(clock.nudge(0.5))
        XCTAssertEqual(clock.report(position: 60, at: 103, playing: true), .jumped)
        XCTAssertEqual(clock.correction, 0)
        XCTAssertEqual(clock.position(at: 104), 61, accuracy: 1e-9)
        XCTAssertEqual(clock.report(position: 61, at: 104, playing: false), .held)
        XCTAssertEqual(clock.position(at: 110), 61, accuracy: 1e-9, "paused clocks hold still")
    }

    // MARK: - Learning, storing and calibrating

    func testALearnerKeepsHeardSectionsAcrossSeeksAndBuildsAMapWhenItCoversTheTrack() throws {
        let hops = Self.syntheticHops(seconds: 40)
        var learner = BeatMapLearner(key: "spotify:x", duration: 40)
        for hop in hops.prefix(hops.count / 2) { learner.add(hop, position: hop.time) }
        XCTAssertFalse(learner.isComplete)
        XCTAssertNil(learner.makeMap())
        let coverage = learner.coverage
        // Replaying a heard section neither erases nor doubles its coverage.
        learner.add(hops[10], position: hops[10].time)
        XCTAssertEqual(learner.coverage, coverage)
        learner.restart()
        XCTAssertEqual(learner.coverage, coverage, "a pause breaks interpolation, not learning")
        for hop in hops { learner.add(hop, position: hop.time) }
        XCTAssertTrue(learner.isComplete)
        let map = try XCTUnwrap(learner.makeMap())
        XCTAssertEqual(map.tempo, 120, accuracy: 1.5)
    }

    func testPartialLearningSurvivesStoreRecreationWithoutCountingUnheardGaps() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = "com.spotify.client:track:partial"
        let hops = Self.syntheticHops(seconds: 40)
        var learner = BeatMapLearner(key: key, duration: 40)
        for hop in hops where hop.time < 10 { learner.add(hop, position: hop.time) }
        learner.restart()
        for hop in hops where hop.time >= 30 { learner.add(hop, position: hop.time) }
        XCTAssertEqual(learner.coverage, 0.5, accuracy: 0.01)
        XCTAssertFalse(learner.isComplete, "seeking over the middle does not teach it")
        BeatMapStore(directory: directory).saveLearning(learner)
        let store = BeatMapStore(directory: directory)
        var restored = try XCTUnwrap(store.loadLearning(key: key, duration: 40))
        XCTAssertEqual(restored.coverage, learner.coverage)
        XCTAssertNil(store.loadLearning(key: key, duration: 90))
        for hop in hops where hop.time >= 10 && hop.time < 30 { restored.add(hop, position: hop.time) }
        XCTAssertTrue(restored.isComplete)
        let map = try XCTUnwrap(restored.makeMap())
        XCTAssertEqual(map.tempo, 120, accuracy: 1.5)
        store.save(map, key: key)
        store.removeLearning(key: key)
        XCTAssertEqual(BeatMapStore(directory: directory).load(key: key), map)
        XCTAssertNil(store.loadLearning(key: key, duration: 40))
    }

    func testLearnedMapsUseLiveTimingInSectionsSkippedDuringLearning() throws {
        var learner = BeatMapLearner(key: "skipped-bridge", duration: 40)
        for hop in Self.syntheticHops(seconds: 40) where hop.time < 5 || hop.time >= 9 {
            learner.add(hop, position: hop.time)
        }
        XCTAssertTrue(learner.isComplete)
        let map = try XCTUnwrap(learner.makeMap())
        XCTAssertNil(map.grid(at: 7), "an unheard bridge must not claim a learned grid")
        XCTAssertNotNil(map.grid(at: 20))
        XCTAssertFalse(map.apply(to: AudioReactiveSnapshot(), position: 7, timestamp: 100).beatMapActive)
        let restored = try JSONDecoder().decode(BeatMap.self, from: JSONEncoder().encode(map))
        XCTAssertEqual(restored.learnedRanges, map.learnedRanges)
        XCTAssertNil(restored.grid(at: 7))
    }

    func testTheStoreRoundTripsMapsUnderHashedNamesAndPrunesToCapacity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeatMapTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BeatMapStore(directory: directory, capacity: 2)
        let map = try Self.map()
        store.save(map, key: "file:a")
        XCTAssertEqual(store.load(key: "file:a"), map)
        XCTAssertNil(store.load(key: "file:b"))
        XCTAssertTrue(BeatMapStore.fileName(for: "spotify:track:1/../../x").hasSuffix(".json"))
        XCTAssertFalse(BeatMapStore.fileName(for: "a/b").contains("/"))
        XCTAssertEqual(BeatMapStore.fileName(for: "same"), BeatMapStore.fileName(for: "same"))
        store.save(map, key: "file:b")
        store.save(map, key: "file:c")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.count, 2)

        var stale = map
        stale.version = BeatMap.currentVersion + 1
        store.save(stale, key: "file:stale")
        XCTAssertNil(store.load(key: "file:stale"), "a map from another format version is analysed again")
    }

    func testTapsThatLandConsistentlyLateMoveTheTimingEarlierByThatMuch() throws {
        var calibrator = TapCalibrator()
        for beat in 0..<7 { calibrator.tap(at: 100 + Double(beat) * 0.5 + 0.06, beatReference: 100, interval: 0.5) }
        XCTAssertNil(calibrator.suggestedOffset(current: 0), "seven taps are not enough")
        calibrator.tap(at: 100 + 7 * 0.5 + 0.07, beatReference: 100, interval: 0.5)
        XCTAssertEqual(try XCTUnwrap(calibrator.lateness), 0.06, accuracy: 0.006)
        XCTAssertEqual(try XCTUnwrap(calibrator.suggestedOffset(current: 0.02)), 0.08, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(calibrator.suggestedOffset(current: 0.28)), MusicModeConfiguration.latencyOffsetLimit)

        var early = TapCalibrator()
        for beat in 0..<8 { early.tap(at: 200 + Double(beat) * 0.6 - 0.04, beatReference: 200, interval: 0.6) }
        XCTAssertEqual(try XCTUnwrap(early.suggestedOffset(current: 0)), -0.04, accuracy: 1e-9)

        var scattered = TapCalibrator()
        for beat in 0..<10 {
            scattered.tap(at: 300 + Double(beat) * 0.5 + (beat.isMultiple(of: 2) ? 0.2 : -0.15),
                          beatReference: 300, interval: 0.5)
        }
        XCTAssertNil(scattered.lateness, "taps all over the beat measure nothing")
    }

    func testPresetsKeepTheRoomsTimingAndOldArchivesDecodeWithout() throws {
        var current = MusicModeConfiguration.configuration(for: .balanced)
        current.outputLatencyOffset = 0.07
        current.followsPlaybackApps = true
        let concert = MusicModeConfiguration.configuration(for: .concert).preservingRoomCalibration(from: current)
        XCTAssertEqual(concert.preset, .concert)
        XCTAssertEqual(concert.outputLatencyOffset, 0.07)
        XCTAssertTrue(concert.followsPlaybackApps)

        var wild = current
        wild.outputLatencyOffset = 4
        XCTAssertEqual(wild.normalized().outputLatencyOffset, MusicModeConfiguration.latencyOffsetLimit)
        wild.outputLatencyOffset = .nan
        XCTAssertEqual(wild.normalized().outputLatencyOffset, 0)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        object.removeValue(forKey: "outputLatencyOffset")
        object.removeValue(forKey: "followsPlaybackApps")
        let old = try JSONDecoder().decode(MusicModeConfiguration.self,
                                           from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old.outputLatencyOffset, 0)
        XCTAssertFalse(old.followsPlaybackApps)
    }

    // MARK: - Energy gears and timing in the engine

    func testEnergyTiersFollowMappedBarsWithHysteresisAndLiveBarsOneBarLate() {
        var mapped = EnergyTierTracker()
        XCTAssertEqual(mapped.tier, 3)
        XCTAssertEqual(mapped.update(energy: 0.5, dt: 0.05, barPosition: 0, gridStrength: 1, mappedBarEnergy: 1), 5)
        XCTAssertEqual(mapped.update(energy: 0.5, dt: 0.05, barPosition: 0, gridStrength: 1, mappedBarEnergy: 0.9), 5,
                       "inside the hysteresis band")
        XCTAssertEqual(mapped.update(energy: 0.5, dt: 0.05, barPosition: 0, gridStrength: 1, mappedBarEnergy: 0.85), 4)
        XCTAssertEqual(mapped.update(energy: 0.5, dt: 0.05, barPosition: 0, gridStrength: 1, mappedBarEnergy: 0.02), 0)

        var live = EnergyTierTracker()
        var bar = 0.0
        func run(_ energy: Double, bars: Int) {
            for frame in 0..<(bars * 40) {
                live.update(energy: energy, dt: 0.05, barPosition: bar + Double(frame) / 40, gridStrength: 1)
            }
            bar += Double(bars)
        }
        run(0.1, bars: 4)
        let quiet = live.tier
        live.update(energy: 0.9, dt: 0.05, barPosition: bar, gridStrength: 1)
        XCTAssertEqual(live.tier, quiet, "the loud bar has not finished yet")
        run(0.9, bars: 2)
        XCTAssertGreaterThan(live.tier, quiet)
    }

    private static func quietMap(_ energy: Double) throws -> BeatMap {
        var map = try Self.map(syntheticHops(interval: 0.4, firstBeat: 0.2))
        map.barEnergy = map.barEnergy.map { _ in energy }
        return map
    }

    private static func engineSnapshot(_ map: BeatMap, position: Double, timestamp: Double) -> AudioReactiveSnapshot {
        var live = AudioReactiveSnapshot()
        live.level = 0.6
        live.energy = 0.6
        live.confidence = 1
        live.analysisTimestamp = timestamp
        return map.apply(to: live, position: position, timestamp: timestamp)
    }

    private static let room = [MusicFixtureDescriptor(id: "a", label: "a", transport: .lifxLAN)]
    private static var hitTopology: FixtureTopology {
        var topology = FixtureTopology()
        topology.roles["a"] = .hit
        return topology
    }

    func testCalmMusicKeepsTheDetectedBeatInAutoWithoutSwitchingToHalfTime() throws {
        func rises(_ feel: TimeFeel) throws -> Int {
            let map = try Self.quietMap(0.2)
            let engine = MusicChoreographyEngine()
            var config = MusicModeConfiguration.configuration(for: .balanced)
            config.timeFeel = feel
            config.movementAmount = 0
            config.stereoImage = 0
            let start = map.beats[map.downbeatOffset + 8]
            var series: [Double] = []
            for step in 0..<(8 * 8) {
                let position = start + Double(step) * (0.4 / 8)
                let frame = engine.makeFrame(
                    snapshot: Self.engineSnapshot(map, position: position, timestamp: 1000 + position),
                    configuration: config, topology: Self.hitTopology, fixtures: Self.room,
                    timestamp: 1000 + position, sequenceNumber: UInt64(step + 1))
                series.append(frame.states[0].brightness)
                XCTAssertEqual(frame.energyTier, 1)
            }
            // A rise is a step up after a flat or falling step. The native
            // engine's weak-beat accents are shallower than the browser's, so
            // its threshold is lower than the web test's.
            var count = 0
            for i in 18..<series.count
            where series[i] - series[i - 1] > 0.006 && series[i - 1] - series[i - 2] <= 0.002 {
                count += 1
            }
            return count
        }
        let auto = try rises(.auto), straight = try rises(.straight)
        XCTAssertEqual(auto, straight, "energy tiers must not change the detected clock")
        XCTAssertGreaterThanOrEqual(straight, 5, "straight rises \(straight)")
    }

    func testHighTiersStepColourOnTheBeatAndLowTiersHoldItForTheBar() throws {
        func huesPerBeat(_ energy: Double) throws -> Int {
            let map = try Self.quietMap(energy)
            let engine = MusicChoreographyEngine()
            var config = MusicModeConfiguration.configuration(for: .balanced)
            config.movementAmount = 0
            config.stereoImage = 0
            config.colorChangeIntensity = 0.2
            let start = map.beats[map.downbeatOffset + 8]
            var hues: Set<String> = []
            for step in 0..<(4 * 16) {
                let position = start + Double(step) * (0.4 / 16)
                let frame = engine.makeFrame(
                    snapshot: Self.engineSnapshot(map, position: position, timestamp: 2000 + position),
                    configuration: config, topology: Self.hitTopology, fixtures: Self.room,
                    timestamp: 2000 + position, sequenceNumber: UInt64(step + 1))
                if step % 16 == 15 { hues.insert(String(format: "%.3f", frame.states[0].hue)) }
            }
            return hues.count
        }
        XCTAssertEqual(try huesPerBeat(0.3), 1, "one colour through the bar")
        XCTAssertGreaterThanOrEqual(try huesPerBeat(1), 3, "a new colour on most beats")
    }

    func testDoubleTimeColourStepsStayBelowThreePerSecond() throws {
        var map = try Self.quietMap(1)
        map.beats = (0..<300).map { Double($0) * 0.3 }
        let engine = MusicChoreographyEngine()
        var config = MusicModeConfiguration.configuration(for: .balanced)
        config.timeFeel = .double
        config.movementAmount = 0
        config.stereoImage = 0
        var previousHue: Double?
        var previousDelta = 0.0
        var changes: [Double] = []
        for step in 0..<1000 {
            let position = 5 + Double(step) * 0.01, timestamp = 1000 + position
            var snapshot = Self.engineSnapshot(map, position: position, timestamp: timestamp)
            snapshot.timeFeel = .double
            snapshot.feltInterval = snapshot.beatInterval * 0.5
            let frame = engine.makeFrame(snapshot: snapshot, configuration: config,
                                         topology: FixtureTopology(), fixtures: Self.room,
                                         timestamp: timestamp, sequenceNumber: UInt64(step))
            let hue = try XCTUnwrap(frame.states.first).hue
            if let previousHue {
                let delta = abs(hue - previousHue)
                if delta > 1e-6, previousDelta <= 1e-6 { changes.append(timestamp) }
                previousDelta = delta
            }
            previousHue = hue
        }
        XCTAssertGreaterThan(changes.count, 10)
        for (a, b) in zip(changes, changes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 1 / 3.0 - 0.011)
        }
    }

    func testTempoJitterAtTheColourSubdivisionThresholdDoesNotFreezeFades() {
        let engine = MusicChoreographyEngine()
        var config = MusicModeConfiguration.configuration(for: .balanced)
        config.movementAmount = 0
        config.stereoImage = 0
        var hues: Set<String> = []
        for step in 0..<300 {
            let elapsed = Double(step) * 0.01, timestamp = 100 + elapsed
            let beat = Int(floor(elapsed * 3))
            let interval = step.isMultiple(of: 2) ? 0.332 : 0.335
            var snapshot = AudioReactiveSnapshot(level: 0.6, energy: 0.6, confidence: 1)
            snapshot.analysisTimestamp = timestamp
            snapshot.beatConfidence = 1; snapshot.isTempoLocked = true
            snapshot.tempo = 60 / interval; snapshot.beatInterval = interval; snapshot.feltInterval = interval
            snapshot.beatReferenceTime = 100 + Double(beat) / 3
            snapshot.gridBeatPosition = beat; snapshot.beatCount = beat; snapshot.beatInBar = beat % 4
            snapshot.barEnergy = 1
            let frame = engine.makeFrame(snapshot: snapshot, configuration: config,
                                         topology: FixtureTopology(), fixtures: Self.room,
                                         timestamp: timestamp, sequenceNumber: UInt64(step))
            if let state = frame.states.first { hues.insert(String(format: "%.3f", state.hue)) }
        }
        XCTAssertGreaterThan(hues.count, 3, "tempo jitter must leave a fade enough time to complete")
    }

    func testTheTopTierAsksForADownbeatFlashOnlyThroughTheLimiter() throws {
        func flashes(safe: Bool) throws -> Int {
            let map = try Self.quietMap(1)
            let engine = MusicChoreographyEngine()
            var config = MusicModeConfiguration.configuration(for: .concert)
            config.photosensitivitySafeMode = safe
            config.allowsFlashes = true
            config.flashIntensity = 1
            config.percussionSensitivity = 0
            config.phraseAware = false
            config.maximumFlashFrequency = 3
            let start = map.beats[map.downbeatOffset + 8]
            var count = 0
            for step in 0..<(8 * 16) {
                let position = start + Double(step) * (0.4 / 16)
                let frame = engine.makeFrame(
                    snapshot: Self.engineSnapshot(map, position: position, timestamp: 3000 + position),
                    configuration: config, topology: Self.hitTopology, fixtures: Self.room,
                    timestamp: 3000 + position, sequenceNumber: UInt64(step + 1))
                if frame.flashApplied { count += 1 }
            }
            return count
        }
        XCTAssertEqual(try flashes(safe: true), 0)
        XCTAssertEqual(try flashes(safe: false), 2, "one per bar across two bars")
    }

    func testTheLightTimingOffsetMovesThePredictedBeatByExactlyItsValue() {
        let engine = MusicChoreographyEngine()
        var snapshot = AudioReactiveSnapshot()
        snapshot.tempo = 120
        snapshot.beatInterval = 0.5
        snapshot.feltInterval = 0.5
        snapshot.beatConfidence = 1
        snapshot.beatReferenceTime = 100
        snapshot.isTempoLocked = true
        snapshot.gridBeatPosition = 0
        let base = MusicModeConfiguration.configuration(for: .balanced)
        var early = base
        early.outputLatencyOffset = 0.1
        let plain = engine.musicalClock(snapshot: snapshot, timestamp: 100.1, configuration: base,
                                        attackTime: 0.026, halfTime: false)
        let ahead = engine.musicalClock(snapshot: snapshot, timestamp: 100.1, configuration: early,
                                        attackTime: 0.026, halfTime: false)
        XCTAssertEqual(ahead.phase - plain.phase, 0.2, accuracy: 1e-9)
    }

    // MARK: - Coordinator

    func testACachedFileMapSetsTheGridFromTheFilePosition() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeatMapTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BeatMapStore(directory: directory)
        let map = try Self.map()
        store.save(map, key: "file:song")
        let coordinator = BeatMapCoordinator(store: store, now: { 0 })
        var statuses: [BeatMapStatus] = []
        coordinator.onStatusChange = { statuses.append($0) }
        #if canImport(AVFoundation)
        let url = try Self.writeClicks(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        coordinator.beginFile(reader: try AVAudioFile(forReading: url), key: "file:song")
        XCTAssertEqual(statuses.last, .fileReady(tempo: map.tempo))
        let applied = coordinator.apply(to: AudioReactiveSnapshot(), at: 50, filePosition: map.beats[30] + 0.05)
        XCTAssertTrue(applied.beatMapActive)
        XCTAssertEqual(applied.beatReferenceTime, 50 - 0.05, accuracy: 1e-9)
        XCTAssertFalse(coordinator.apply(to: AudioReactiveSnapshot(), at: 50, filePosition: nil).beatMapActive)
        coordinator.stop()
        XCTAssertEqual(statuses.last, .off)
        #endif
    }

    #if canImport(AVFoundation)
    /// A mono file of 60 Hz kicks every half second, louder on the bar.
    private static func writeClicks(seconds: Double) throws -> URL {
        let rate = 44_100.0
        let frames = AVAudioFrameCount(rate * seconds)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clicks-\(UUID().uuidString).caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData)[0]
        for i in 0..<Int(frames) { data[i] = 0 }
        var beat = 0
        while Double(beat) * 0.5 < seconds {
            let start = Int((0.1 + Double(beat) * 0.5) * rate)
            let loud: Float = beat % 4 == 0 ? 0.9 : 0.5
            for i in 0..<Int(rate * 0.08) where start + i < Int(frames) {
                let t = Double(i) / rate
                data[start + i] += loud * Float(sin(2 * .pi * 60 * t) * exp(-t / 0.03))
            }
            beat += 1
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        return url
    }

    func testAFileIsAnalysedIntoAMapFasterThanItPlays() throws {
        let url = try Self.writeClicks(seconds: 20)
        defer { try? FileManager.default.removeItem(at: url) }
        var progress = 0.0
        let started = Date()
        let map = try XCTUnwrap(BeatMapBuilder.analyze(file: AVAudioFile(forReading: url), progress: { progress = $0 }))
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
        XCTAssertEqual(progress, 1)
        XCTAssertEqual(map.tempo, 120, accuracy: 2)
        XCTAssertNil(BeatMapBuilder.analyze(file: try AVAudioFile(forReading: url), shouldContinue: { false }))
    }
    #endif

    #if os(macOS)
    func testPauseSeekAndCaptureGapsPreserveLearningAndDiscardOldQueuedHops() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let learningQueue = DispatchQueue(label: "test.learning-discontinuities")
        var time = 100.0
        let coordinator = BeatMapCoordinator(store: BeatMapStore(directory: directory),
                                             learningQueue: learningQueue, now: { time })
        coordinator.beginFollowing(startMonitor: false)
        defer {
            coordinator.stop()
            learningQueue.sync {}
            try? FileManager.default.removeItem(at: directory)
        }
        var sample = NowPlayingSample(app: .music, trackID: UUID().uuidString, title: "Song", artist: "Artist",
                                      duration: 120, position: 0, isPlaying: true, sampledAt: time)
        coordinator.receive(sample)
        func feed(_ start: Double, _ end: Double) {
            let count = Int((end - start) * 100)
            coordinator.consume(hops: (0...count).map {
                HopFeature(time: start + Double($0) / 100, onset: 0.5, kick: 0.5, energy: 0.5)
            })
        }
        feed(100, 110)
        XCTAssertEqual(coordinator.status, .learning(app: "Music", title: "Song", coverage: 0.05))
        time = 110; sample.sampledAt = time; sample.position = 10; sample.isPlaying = false
        coordinator.receive(sample)
        XCTAssertEqual(coordinator.status, .waitingForPlayer)
        feed(110, 111)
        time = 111; sample.sampledAt = time; sample.isPlaying = true
        coordinator.receive(sample)
        feed(109, 112) // Queued hops before the resume must be discarded.
        XCTAssertEqual(coordinator.status, .learning(app: "Music", title: "Song", coverage: 0.05))
        time = 112; sample.sampledAt = time; sample.position = 0
        coordinator.receive(sample)
        feed(112, 122)
        XCTAssertEqual(coordinator.status, .learning(app: "Music", title: "Song", coverage: 0.05))
        feed(124, 125)
        XCTAssertEqual(coordinator.status, .learning(app: "Music", title: "Song", coverage: 0.1))
    }

    func testStopAndRestartReusePartialLearningBeforeItsDiskWriteCompletes() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DispatchQueue(label: "test.suspended-learning")
        queue.suspend()
        defer { queue.resume(); queue.sync {} }
        var time = 100.0
        let coordinator = BeatMapCoordinator(store: BeatMapStore(directory: directory), learningQueue: queue, now: { time })
        var sample = NowPlayingSample(app: .music, trackID: "partial", title: "Song", artist: "Artist",
                                      duration: 120, position: 0, isPlaying: true, sampledAt: time)
        coordinator.beginFollowing(startMonitor: false)
        coordinator.receive(sample)
        coordinator.consume(hops: Self.syntheticHops(seconds: 10).map {
            HopFeature(time: 100 + $0.time, onset: $0.onset, kick: $0.kick, energy: $0.energy)
        })
        let progress = coordinator.status
        coordinator.stop()
        time = 200
        sample.sampledAt = time
        coordinator.beginFollowing(startMonitor: false)
        coordinator.receive(sample)
        XCTAssertEqual(coordinator.status, progress)
        XCTAssertEqual(progress, .learning(app: "Music", title: "Song", coverage: 0.05))
        coordinator.stop()
    }

    func testStoppingDuringAnEarlierBuildCheckpointsNewlyHeardSections() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BeatMapStore(directory: directory)
        let queue = DispatchQueue(label: "test.in-flight-learning")
        queue.suspend()
        var suspended = true
        defer { if suspended { queue.resume() }; queue.sync {} }
        var time = 100.0
        let coordinator = BeatMapCoordinator(store: store, learningQueue: queue, now: { time })
        coordinator.beginFollowing(startMonitor: false)
        coordinator.receive(NowPlayingSample(app: .music, trackID: "in-flight", title: "Song", artist: "Artist",
                                              duration: 40, position: 0, isPlaying: true, sampledAt: time))
        let hops = Self.syntheticHops(seconds: 40)
        func feed(_ section: [HopFeature]) {
            coordinator.consume(hops: section.map {
                HopFeature(time: 100 + $0.time, onset: $0.onset, kick: $0.kick, energy: $0.energy)
            })
        }
        time = 135
        feed(hops.filter { $0.time < 35 }) // 87.5% starts the queued build.
        time = 138
        feed(hops.filter { $0.time >= 35 && $0.time < 38 }) // Another 7.5% is heard.
        coordinator.stop()
        queue.resume()
        suspended = false
        queue.sync {}
        let restored = try XCTUnwrap(store.loadLearning(key: PlaybackApp.music.trackKey("in-flight"), duration: 40))
        XCTAssertGreaterThan(restored.coverage, 0.94, "Stop must persist the newer learner, not just the old build's snapshot")
        XCTAssertGreaterThan(try XCTUnwrap(restored.hops.last).time, 37.9)
    }

    func testLearningFinishesBeforeTheOutroAndAnImmediateRepeatReusesTheMap() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BeatMapStore(directory: directory)
        var time = 100.0
        let learningQueue = DispatchQueue(label: "test.beat-map-learning")
        let coordinator = BeatMapCoordinator(store: store, learningQueue: learningQueue, now: { time })
        coordinator.beginFollowing(startMonitor: false)
        defer { coordinator.stop() }
        var sample = NowPlayingSample(app: .music, trackID: "repeat", title: "Song", artist: "Artist",
                                      duration: 40, position: 0, isPlaying: true, sampledAt: time)
        coordinator.receive(sample)
        let ready = expectation(description: "the completed map follows the repeated track")
        ready.assertForOverFulfill = false
        coordinator.onStatusChange = { status in
            if case .following = status { ready.fulfill() }
        }
        let recorded = Self.syntheticHops(seconds: 35)
        time = 135
        coordinator.consume(hops: recorded.map {
            HopFeature(time: 100 + $0.time, onset: $0.onset, kick: $0.kick, energy: $0.energy)
        })
        // Repeat the same track before its background build finishes.
        sample.sampledAt = time
        sample.position = 0
        coordinator.receive(sample)
        wait(for: [ready], timeout: 5)
        let key = PlaybackApp.music.trackKey("repeat")
        let stored = try XCTUnwrap(BeatMapStore(directory: directory).load(key: key))
        XCTAssertTrue(stored.isPlayable)
        XCTAssertTrue(coordinator.status.isPlayingMap)
        // Keep recording the outro while the early map is already playing.
        time = 175
        coordinator.consume(hops: Self.syntheticHops(seconds: 40).filter { $0.time >= 35 }.map {
            HopFeature(time: 135 + $0.time, onset: $0.onset, kick: $0.kick, energy: $0.energy)
        })
        learningQueue.sync {}
        XCTAssertGreaterThan(try XCTUnwrap(store.load(key: key)).duration, 39,
                             "an early usable map must keep extending through the outro")
        coordinator.stop()
        let restarted = BeatMapCoordinator(store: BeatMapStore(directory: directory), now: { time })
        restarted.beginFollowing(startMonitor: false)
        defer { restarted.stop() }
        restarted.receive(sample)
        XCTAssertTrue(restarted.status.isPlayingMap, "a later app session must reuse the saved map")
    }

    func testAnAllowedIdlePlayerDoesNotHideAnotherPlayersAutomationDenial() {
        let monitor = NowPlayingMonitor(running: { _ in true }, read: { app in
            (nil, app == .spotify ? .denied : .granted)
        })
        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(monitor.permission, .denied)
    }

    func testAnAllowedPlayingAppCanBeFollowedWhenTheOtherAppIsDenied() {
        let sample = NowPlayingSample(app: .music, trackID: "42", title: "Song", artist: "Artist",
                                      duration: 60, position: 10, isPlaying: true, sampledAt: 0)
        let monitor = NowPlayingMonitor(running: { _ in true }, read: { app in
            app == .spotify ? (nil, .denied) : (sample, .granted)
        })
        var received: NowPlayingSample?
        monitor.onSample = { received = $0 }
        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(monitor.permission, .granted)
        XCTAssertEqual(received, sample)
    }

    func testAPausedPlayerIsWaitingEvenWhenItsTrackHasAMap() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeatMapTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BeatMapStore(directory: directory)
        let map = try Self.map()
        store.save(map, key: PlaybackApp.music.trackKey("42"))
        let coordinator = BeatMapCoordinator(store: store, now: { 0 })
        coordinator.beginFollowing()
        defer { coordinator.stop() }
        var sample = NowPlayingSample(app: .music, trackID: "42", title: "Song", artist: "Artist",
                                      duration: 60, position: 10, isPlaying: false, sampledAt: 0)
        coordinator.receive(sample)
        XCTAssertEqual(coordinator.status, .waitingForPlayer)
        XCTAssertFalse(coordinator.apply(to: AudioReactiveSnapshot(), at: 0, filePosition: nil).beatMapActive)
        sample.isPlaying = true
        coordinator.receive(sample)
        XCTAssertEqual(coordinator.status, .following(app: "Music", title: "Song", tempo: map.tempo))
        XCTAssertTrue(coordinator.apply(to: AudioReactiveSnapshot(), at: 0, filePosition: nil).beatMapActive)
    }

    func testNowPlayingRepliesParseIntoSamples() throws {
        let reply = NSAppleEventDescriptor.list()
        reply.insert(NSAppleEventDescriptor(string: "playing"), at: 1)
        reply.insert(NSAppleEventDescriptor(string: "spotify:track:abc"), at: 2)
        reply.insert(NSAppleEventDescriptor(double: 215.5), at: 3)
        reply.insert(NSAppleEventDescriptor(double: 42.25), at: 4)
        reply.insert(NSAppleEventDescriptor(string: "Song"), at: 5)
        reply.insert(NSAppleEventDescriptor(string: "Artist"), at: 6)
        let sample = try XCTUnwrap(NowPlayingMonitor.parse(reply, app: .spotify, sampledAt: 9))
        XCTAssertEqual(sample.trackID, "spotify:track:abc")
        XCTAssertEqual(sample.duration, 215.5)
        XCTAssertEqual(sample.position, 42.25)
        XCTAssertTrue(sample.isPlaying)
        XCTAssertEqual(sample.title, "Song")
        XCTAssertEqual(sample.sampledAt, 9)
        XCTAssertEqual(PlaybackApp.spotify.trackKey(sample.trackID), "com.spotify.client:spotify:track:abc")

        let stopped = NSAppleEventDescriptor.list()
        stopped.insert(NSAppleEventDescriptor(string: "stopped"), at: 1)
        XCTAssertNil(NowPlayingMonitor.parse(stopped, app: .music, sampledAt: 0))
    }
    #endif
}
