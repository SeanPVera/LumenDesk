import AVFoundation
import CoreMIDI
import SwiftUI
import XCTest
@testable import LumenDesk

final class MusicModeTests: XCTestCase {
    func testMasterZeroAndLiveCeilingIncludeFlashes() {
        let engine = MusicChoreographyEngine()
        let fixture = MusicFixtureDescriptor(id: "f", label: "Fixture", transport: .lifxLAN)
        var config = MusicModeConfiguration.configuration(for: .concert)
        var input = lockedSnapshot(at: 100, reference: 100, interval: 0.5)
        input.snare = 1; input.percussion = 1
        _ = engine.makeFrame(snapshot: input, configuration: config, topology: FixtureTopology(), fixtures: [fixture], timestamp: 100, sequenceNumber: 1)
        config.photosensitivitySafeMode = false
        config.masterBrightness = 0.5; config.minimumBrightness = 0.08; config.maximumBrightness = 0.2
        let capped = engine.makeFrame(snapshot: input, configuration: config, topology: FixtureTopology(), fixtures: [fixture], timestamp: 100.05, sequenceNumber: 2)
        XCTAssertLessThanOrEqual(capped.states[0].brightness, 0.1)
        config.masterBrightness = 0
        let black = engine.makeFrame(snapshot: input, configuration: config, topology: FixtureTopology(), fixtures: [fixture], timestamp: 100.1, sequenceNumber: 3)
        XCTAssertEqual(black.states[0].brightness, 0)
    }

    func testEveryRolePreservesSingleColorThemeAndZeroHoldsPalette() {
        for role in [FixtureRole.wash, .hit, .accent, .motion] {
            let engine = MusicChoreographyEngine()
            let fixture = MusicFixtureDescriptor(id: "f", label: "Fixture", transport: .lifxLAN, role: role)
            var config = MusicModeConfiguration.configuration(for: .soundcheck)
            config.palette = [MusicPaletteColor(0xFF0000)]
            config.colorChangeIntensity = 0
            for index in 0..<240 {
                let t = 100 + Double(index) * 0.05
                var input = lockedSnapshot(at: t, reference: 100, interval: 0.5)
                input.mood = 1; input.chroma = [0,0,0,0,0,0,1,0,0,0,0,0]
                let state = engine.makeFrame(snapshot: input, configuration: config, topology: FixtureTopology(), fixtures: [fixture], timestamp: t, sequenceNumber: UInt64(index)).states[0]
                XCTAssertEqual(state.hue, 0, accuracy: 0.000001)
            }
        }
        let engine = MusicChoreographyEngine()
        let fixture = MusicFixtureDescriptor(id: "f", label: "Fixture", transport: .lifxLAN)
        var config = MusicModeConfiguration.configuration(for: .soundcheck)
        config.colorChangeIntensity = 0
        var hues: [Double] = []
        for index in 0..<240 {
            let t = 100 + Double(index) * 0.05
            hues.append(engine.makeFrame(snapshot: lockedSnapshot(at: t, reference: 100, interval: 0.5), configuration: config, topology: FixtureTopology(), fixtures: [fixture], timestamp: t, sequenceNumber: UInt64(index)).states[0].hue)
        }
        XCTAssertEqual(hues.min()!, hues.max()!, accuracy: 0.000001)
    }

    func testStaleCaptureSettlesInsteadOfRetriggeringLastOnset() {
        let engine = MusicChoreographyEngine()
        let fixture = MusicFixtureDescriptor(id: "f", label: "Fixture", transport: .lifxLAN)
        var config = MusicModeConfiguration.configuration(for: .soundcheck)
        config.silenceBehavior = .fadeOut
        var input = lockedSnapshot(at: 100, reference: 100, interval: 0.5)
        input.analysisTimestamp = 100; input.pulse = 1; input.snare = 1
        var brightness = 1.0
        for index in 0..<160 {
            brightness = engine.makeFrame(snapshot: input, configuration: config, topology: FixtureTopology(), fixtures: [fixture], timestamp: 100 + Double(index) * 0.05, sequenceNumber: UInt64(index)).states[0].brightness
        }
        XCTAssertFalse(input.fresh(at: 102).isTempoLocked)
        XCTAssertLessThan(brightness, 0.001)
    }

    func testRendererRejectsOldSequenceExpiredFramesAndResetPending() {
        let renderer = MusicLightingRenderer()
        let fixture = MusicFixtureDescriptor(id: "f", label: "Fixture", transport: .goveeLAN)
        func frame(_ sequence: UInt64, _ timestamp: Double) -> MusicLightingFrame {
            MusicLightingFrame(states: [.init(fixtureID: "f", hue: 0, saturation: 1, brightness: 0.5, transitionDuration: 0.1)], timestamp: timestamp, sequenceNumber: sequence, sustainedEnergyEvent: false, flashApplied: false)
        }
        XCTAssertEqual(renderer.enqueue(frame(2,100), fixtures: [fixture], at: 100).count,1)
        XCTAssertTrue(renderer.enqueue(frame(1,100.1), fixtures: [fixture], at: 100.1).isEmpty)
        XCTAssertTrue(renderer.enqueue(frame(3,100), fixtures: [fixture], at: 101).isEmpty)
        _ = renderer.enqueue(frame(4,101), fixtures: [fixture], at: 101)
        _ = renderer.enqueue(frame(5,101.01), fixtures: [fixture], at: 101.01)
        renderer.reset(fixtureIDs: ["f"])
        XCTAssertTrue(renderer.flush(fixtures: [fixture], at: 102).isEmpty)
        XCTAssertEqual(renderer.diagnostics.rejectedStates,2)
    }

    /// This is the production PCM analyzer -> choreography -> renderer, not a
    /// translation. Prints aggregate evidence; optional CSV contains synthetic
    /// features/commands only, never microphone or system-audio recordings.
    func testPCMProductionPipelineAcrossFormatsAndDynamics() throws {
        var csv = "rate,chunk,time,tempo,confidence,onset,beatCount,level,generatedBrightness,handedOff\n"
        for (rate, chunk) in [(48000.0,128), (48000,1024), (44100,512), (44100,2048)] {
            let analyzer = MusicFeatureAnalyzer(sourceDescription: "Synthetic regression")
            let engine = MusicChoreographyEngine()
            let renderer = MusicLightingRenderer()
            let fixtures = [MusicFixtureDescriptor(id: "f", label: "Fixture", transport: .lifxLAN)]
            let config = MusicModeConfiguration.configuration(for: .soundcheck)
            var sample = 0, locked = 0, correct = 0, commands = 0
            var renderAt = 100.0
            while sample < Int(rate * 14) {
                let count = min(chunk, Int(rate * 14) - sample)
                let pcm = rhythmBuffer(startSample: sample, frames: AVAudioFrameCount(count), sampleRate: rate, beatPeriod: 0.5, includeHiHats: true)
                let end = 100 + Double(sample + count) / rate
                if let snapshot = analyzer.analyze(pcm, hostTime: end), end >= renderAt {
                    let frame = engine.makeFrame(snapshot: snapshot, configuration: config, topology: FixtureTopology(), fixtures: fixtures, timestamp: end, sequenceNumber: UInt64(sample))
                    let output = renderer.enqueue(frame, fixtures: fixtures, at: end)
                    commands += output.count
                    if end > 108, snapshot.isTempoLocked {
                        locked += 1
                        if abs(snapshot.tempo - 120) < 6 { correct += 1 }
                    }
                    XCTAssertFalse(frame.flashApplied)
                    XCTAssertLessThanOrEqual(end - (snapshot.analysisTimestamp ?? 0), 512 / rate + 0.001)
                    csv += "\(rate),\(chunk),\(end),\(snapshot.tempo),\(snapshot.beatConfidence),\(snapshot.onset),\(snapshot.beatCount),\(snapshot.level),\(frame.states[0].brightness),\(output.count)\n"
                    renderAt += 0.05
                }
                sample += count
            }
            XCTAssertGreaterThan(locked, 60)
            XCTAssertGreaterThan(Double(correct) / Double(max(1,locked)), 0.9)
            XCTAssertLessThanOrEqual(commands, 235) // <= 1/.06 Hz plus first frame
            print("MUSIC_METRIC native rate=\(rate) chunk=\(chunk) locked=\(locked) correct=\(correct) handoffs=\(commands)")
        }
        if let path = ProcessInfo.processInfo.environment["MUSIC_TRACE_PATH"] {
            try csv.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    func testPCMLevelRetainsQuietLoudContrastAndRejectsDuplicates() throws {
        func level(_ amplitude: Float) throws -> Double {
            let analyzer = MusicFeatureAnalyzer(sourceDescription: "Synthetic")
            var result = 0.0
            for index in 0..<100 {
                let pcm = buffer(frequency: 440, amplitude: amplitude, startSample: index * 1024)
                let snapshot = try XCTUnwrap(analyzer.analyze(pcm, hostTime: 100 + Double((index+1)*1024)/48000))
                result = snapshot.level
                XCTAssertNil(analyzer.analyze(pcm,hostTime:100 + Double((index+1)*1024)/48000))
            }
            return result
        }
        let quiet = try level(0.04), loud = try level(0.8)
        XCTAssertGreaterThan(quiet,0.1)
        XCTAssertGreaterThan(loud-quiet,0.3)
        print("MUSIC_METRIC native quiet=\(quiet) loud=\(loud)")
    }


    func testPCMConfidenceLossAndRecovery() throws {
        let analyzer = MusicFeatureAnalyzer(sourceDescription: "Synthetic loss and recovery")
        var duringSilence: AudioReactiveSnapshot?
        var recovered: AudioReactiveSnapshot?
        for index in 0..<3375 { // 36 seconds at 48 kHz / 512
            let time = Double(index * 512) / 48000
            let pcm = time >= 10 && time < 22
                ? buffer(frames: 512)
                : rhythmBuffer(startSample: index * 512, frames: 512, sampleRate: 48000, beatPeriod: 0.5, includeHiHats: true)
            let snapshot = analyzer.analyze(pcm, hostTime: 100 + time + 512.0/48000)
            if time > 21 && time < 22 { duringSilence = snapshot }
            if time > 35 { recovered = snapshot }
        }
        XCTAssertFalse(try XCTUnwrap(duringSilence).isTempoLocked)
        XCTAssertLessThan(try XCTUnwrap(duringSilence).energy, 0.01)
        XCTAssertTrue(try XCTUnwrap(recovered).isTempoLocked)
        XCTAssertEqual(try XCTUnwrap(recovered).tempo, 120, accuracy: 6)
    }

    @MainActor
    func testLiveReducedMotionAndControlExtremesReachSession() throws {
        let manager = LightManager(persistenceStore: MusicModePersistenceSpy())
        manager.enterDemoMode()
        var config = MusicModeConfiguration.configuration(for: .concert)
        config.usesSyntheticDemoPattern = true
        manager.startMusicMode(configuration: config)
        for value in [0.0,0.5,1.0] {
            config.masterBrightness = value; config.beatSensitivity = value
            config.effectIntensity = value; config.movementAmount = value
            manager.setMusicModeConfiguration(config)
            let effective = try XCTUnwrap(manager.musicModeController.effectiveConfiguration(for: .all))
            XCTAssertEqual(effective.masterBrightness,value)
            XCTAssertEqual(effective.beatSensitivity,value)
            manager.musicModeController.renderNowForTesting()
            let frame = try XCTUnwrap(manager.musicModeController.latestFrame(for: .all))
            XCTAssertTrue(frame.states.allSatisfy { $0.brightness <= config.maximumBrightness * value + 0.000001 })
        }
        manager.setMusicReducedMotion(true)
        let reduced = try XCTUnwrap(manager.musicModeController.effectiveConfiguration(for: .all))
        XCTAssertLessThanOrEqual(reduced.movementAmount,0.18)
        XCTAssertEqual(reduced.flashIntensity,0)
        manager.stopAllEffects()
    }

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

    /// The beat has to be visible, and it has to stop short of a strobe. Both
    /// bounds matter: the engine this replaced hit the upper one, and simply
    /// damping it would have traded one wrong answer for another. Measured at
    /// the render clock the app actually uses (20 Hz), not a finer one.
    func testBeatIsVisibleWithoutBecomingAStrobe() throws {
        let engine = MusicChoreographyEngine()
        let fixture = MusicFixtureDescriptor(id: "f", label: "Fixture", transport: .lifxLAN)
        var config = MusicModeConfiguration.configuration(for: .balanced)
        config.movementAmount = 0
        config.allowsFlashes = false

        let interval = 0.5
        let reference = 100.0
        var byBeat: [Int: [Double]] = [:]
        for frame in 0...240 {
            let timestamp = reference + Double(frame) * MusicModeTests.renderStep
            let brightness = engine.makeFrame(
                snapshot: lockedSnapshot(at: timestamp, reference: reference, interval: interval),
                configuration: config,
                topology: FixtureTopology(),
                fixtures: [fixture],
                timestamp: timestamp,
                sequenceNumber: UInt64(frame)
            ).states.first?.brightness
            guard let brightness, timestamp - reference > 3 else { continue }
            byBeat[Int((timestamp - reference) / interval), default: []].append(brightness)
        }

        let ratios = byBeat.values
            .filter { $0.count >= 4 }
            .compactMap { values -> Double? in
                guard let high = values.max(), let low = values.min(), low > 0 else { return nil }
                return high / low
            }
            .sorted()
        XCTAssertGreaterThan(ratios.count, 10)
        let median = ratios[ratios.count / 2]
        XCTAssertGreaterThan(median, 1.15, "the beat should be clearly visible, not a trickle (\(median))")
        XCTAssertLessThan(median, 2.0, "a beat that swings this far at beat rate reads as flashing (\(median))")
    }

    /// A light that peaks a different amount on every beat regardless of how
    /// loud the music is has thrown its dynamics away. Quiet material must not
    /// be modulated harder than loud material.
    func testQuietMaterialIsNoMoreModulatedThanLoud() throws {
        func perBeatRatio(level: Double, energy: Double, bass: Double) throws -> Double {
            let engine = MusicChoreographyEngine()
            let fixture = MusicFixtureDescriptor(id: "f", label: "Fixture", transport: .lifxLAN)
            var config = MusicModeConfiguration.configuration(for: .balanced)
            config.movementAmount = 0
            config.allowsFlashes = false
            let interval = 0.5
            let reference = 100.0
            var byBeat: [Int: [Double]] = [:]
            for frame in 0...240 {
                let timestamp = reference + Double(frame) * MusicModeTests.renderStep
                var snapshot = lockedSnapshot(at: timestamp, reference: reference, interval: interval)
                snapshot.level = level
                snapshot.energy = energy
                snapshot.bass = bass
                let brightness = engine.makeFrame(
                    snapshot: snapshot, configuration: config, topology: FixtureTopology(),
                    fixtures: [fixture], timestamp: timestamp, sequenceNumber: UInt64(frame)
                ).states.first?.brightness
                guard let brightness, timestamp - reference > 3 else { continue }
                byBeat[Int((timestamp - reference) / interval), default: []].append(brightness)
            }
            let ratios = byBeat.values
                .filter { $0.count >= 4 }
                .compactMap { values -> Double? in
                    guard let high = values.max(), let low = values.min(), low > 0 else { return nil }
                    return high / low
                }
                .sorted()
            return try XCTUnwrap(ratios.isEmpty ? nil : ratios[ratios.count / 2])
        }

        let loud = try perBeatRatio(level: 0.7, energy: 0.6, bass: 0.5)
        let quiet = try perBeatRatio(level: 0.12, energy: 0.1, bass: 0.08)
        XCTAssertLessThanOrEqual(
            quiet, loud + 0.02,
            "a quiet passage (\(quiet)) should be no more modulated than a loud one (\(loud))"
        )
    }

    /// Below the confidence threshold the show must not invent a confident
    /// beat. It falls back to the smoothed energy behaviour, which on a
    /// snapshot carrying no transients means almost no modulation at all.
    func testLowBeatConfidenceDoesNotInventAPulse() throws {
        let engine = MusicChoreographyEngine()
        let fixture = MusicFixtureDescriptor(id: "f", label: "Fixture", transport: .lifxLAN)
        var config = MusicModeConfiguration.configuration(for: .balanced)
        config.movementAmount = 0
        config.allowsFlashes = false
        let interval = 0.5
        let reference = 100.0
        var byBeat: [Int: [Double]] = [:]
        for frame in 0...240 {
            let timestamp = reference + Double(frame) * MusicModeTests.renderStep
            var snapshot = lockedSnapshot(at: timestamp, reference: reference, interval: interval)
            snapshot.beatConfidence = 0.2
            let brightness = engine.makeFrame(
                snapshot: snapshot, configuration: config, topology: FixtureTopology(),
                fixtures: [fixture], timestamp: timestamp, sequenceNumber: UInt64(frame)
            ).states.first?.brightness
            guard let brightness, timestamp - reference > 3 else { continue }
            byBeat[Int((timestamp - reference) / interval), default: []].append(brightness)
        }
        let ratios = byBeat.values
            .filter { $0.count >= 4 }
            .compactMap { values -> Double? in
                guard let high = values.max(), let low = values.min(), low > 0 else { return nil }
                return high / low
            }
            .sorted()
        let median = try XCTUnwrap(ratios.isEmpty ? nil : ratios[ratios.count / 2])
        XCTAssertLessThan(median, 1.08, "an unsure grid should not drive a beat-shaped pulse (\(median))")
    }

    /// The count that matches the complaint: how often a fixture makes a large,
    /// visible jump. A hit fixture used to do it about four times a second at
    /// club tempo — twice per beat, up and down — which is the rate the eye
    /// reads as strobing rather than as a groove.
    func testLargeBrightnessSwingsStayBelowTheFlickerRate() throws {
        let engine = MusicChoreographyEngine()
        let hit = MusicFixtureDescriptor(id: "hit", label: "Downstage", transport: .lifxLAN, role: .hit)
        let wash = MusicFixtureDescriptor(id: "wash", label: "Wash", transport: .lifxLAN, role: .wash)
        var config = MusicModeConfiguration.configuration(for: .club)
        config.movementAmount = 0
        config.allowsFlashes = false
        let interval = 60.0 / 124
        let reference = 100.0
        var series: [String: [Double]] = ["hit": [], "wash": []]
        var samples = 0
        for frame in 0...400 {
            let timestamp = reference + Double(frame) * MusicModeTests.renderStep
            let states = engine.makeFrame(
                snapshot: lockedSnapshot(at: timestamp, reference: reference, interval: interval),
                configuration: config,
                topology: FixtureTopology(layout: .custom, fixtureOrder: ["hit", "wash"]),
                fixtures: [hit, wash],
                timestamp: timestamp,
                sequenceNumber: UInt64(frame)
            ).states
            guard timestamp - reference > 3 else { continue }
            samples += 1
            for state in states { series[state.fixtureID]?.append(state.brightness) }
        }
        let duration = Double(samples) * MusicModeTests.renderStep
        XCTAssertGreaterThan(duration, 10)
        // A hit fixture may accent the strong beats; it may not swing hard on
        // every one. Club tempo is about two beats a second.
        XCTAssertLessThan(Self.largeSwings(series["hit"] ?? []) / duration, 2.5)
        XCTAssertLessThan(Self.largeSwings(series["wash"] ?? []) / duration, 1.0)
    }

    /// Counts monotonic runs that cover at least `minimum` of the brightness
    /// range: one visible jump up or drop down each.
    private static func largeSwings(_ values: [Double], minimum: Double = 0.25) -> Double {
        guard values.count > 2 else { return 0 }
        var runs = 0.0
        var start = 0
        var direction = (values[1] - values[0]).sign
        for index in 1..<values.count {
            let step = values[index] - values[index - 1]
            if step == 0 { continue }
            if step.sign != direction {
                if abs(values[index - 1] - values[start]) >= minimum { runs += 1 }
                start = index - 1
                direction = step.sign
            }
        }
        return runs
    }

    /// Colour is held for a whole number of bars and crossed over at a bar
    /// line, so the window has to be long enough to contain one. The engine
    /// this replaced advanced a free-running accumulator and quantized to its
    /// own boundaries, which drifted against the bar and changed colour about
    /// twice a second at the default setting.
    func testPaletteHoldsAcrossBarsInsteadOfChasingTransients() {
        let engine = MusicChoreographyEngine()
        let fixture = MusicFixtureDescriptor(id: "f", label: "Fixture", transport: .lifxLAN)
        var config = MusicModeConfiguration.configuration(for: .balanced)
        config.movementAmount = 0
        let interval = 0.5
        let reference = 50.0

        var hues: [Int] = []
        for frame in 0...400 {
            let timestamp = reference + Double(frame) * MusicModeTests.renderStep
            let state = engine.makeFrame(
                snapshot: lockedSnapshot(at: timestamp, reference: reference, interval: interval),
                configuration: config,
                topology: FixtureTopology(),
                fixtures: [fixture],
                timestamp: timestamp,
                sequenceNumber: UInt64(frame)
            ).states.first
            guard let hue = state?.hue, timestamp - reference > 3 else { continue }
            hues.append(Int((hue * 1_000).rounded()))
        }

        XCTAssertGreaterThan(hues.count, 300)
        let changing = zip(hues, hues.dropFirst()).filter { $0 != $1 }.count
        XCTAssertGreaterThan(changing, 0, "the palette should still move across bars")
        XCTAssertLessThan(
            Double(changing) / Double(hues.count), 0.2,
            "colour should be held between bar lines, not redrawn every frame"
        )
    }

    /// Chroma is the argmax of a noisy vector and mood is a per-frame band
    /// ratio. Fed straight into the hue they put a visible wobble on every
    /// fixture; smoothed and gated they must not.
    func testHueHoldsThroughChromaAndMoodNoise() {
        let engine = MusicChoreographyEngine()
        let fixture = MusicFixtureDescriptor(id: "f", label: "Fixture", transport: .lifxLAN)
        var config = MusicModeConfiguration.configuration(for: .balanced)
        config.movementAmount = 0
        let interval = 0.5
        let reference = 10.0
        var noise = DeterministicNoise(seed: 7)
        var hues: [Double] = []
        for frame in 0...400 {
            let timestamp = reference + Double(frame) * MusicModeTests.renderStep
            var snapshot = lockedSnapshot(at: timestamp, reference: reference, interval: interval)
            // One clear root with two near-tied neighbours, which is what makes
            // the argmax flip between frames on real music.
            snapshot.chroma = (0..<12).map { index in
                let base = index == 0 ? 0.9 : (index == 4 ? 0.62 : (index == 7 ? 0.61 : 0.1))
                return max(0, min(1, base + (noise.next() - 0.5) * 0.2))
            }
            snapshot.mood = 0.5 + (noise.next() - 0.5) * 0.5
            if let hue = engine.makeFrame(
                snapshot: snapshot, configuration: config, topology: FixtureTopology(),
                fixtures: [fixture], timestamp: timestamp, sequenceNumber: UInt64(frame)
            ).states.first?.hue, timestamp - reference > 3 {
                hues.append(hue)
            }
        }

        XCTAssertGreaterThan(hues.count, 300)
        var travel = 0.0
        var jumps = 0
        for (previous, current) in zip(hues, hues.dropFirst()) {
            var delta = current - previous
            if delta > 0.5 { delta -= 1 }
            if delta < -0.5 { delta += 1 }
            travel += abs(delta)
            if abs(delta) > 1.0 / 12 { jumps += 1 }
        }
        let duration = Double(hues.count) * MusicModeTests.renderStep
        XCTAssertLessThan(travel / duration, 0.1, "hue should not chase chroma noise round the wheel")
        XCTAssertEqual(jumps, 0, "no single frame should move the hue more than thirty degrees")
    }

    /// The render clock Music Mode actually runs at.
    private static let renderStep: TimeInterval = 1.0 / 20

    private struct DeterministicNoise {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((state >> 33) % 1_000) / 1_000
        }
    }

    /// The case the bare-ODF tests miss. Fed an idealised onset function the
    /// old search handled dense subdivisions fine; fed the flux of a real
    /// groove — a swept kick, a noise snare, noise hats and a moving bassline —
    /// it settled on the dotted quarter about as often as on the beat and
    /// switched between the two dozens of times a run, at full confidence.
    /// Every switch re-anchored the phase, which is what the lights showed.
    func testTempoHoldsThePulseThroughDenseRealisticMaterial() throws {
        let analyzer = MusicFeatureAnalyzer(sourceDescription: "Test")
        let bpm = 124.0
        let samples = grooveSamples(bpm: bpm, seconds: 26)
        var tempos: [Double] = []
        var index = 0
        while index < samples.count {
            let count = min(1_024, samples.count - index)
            let time = Double(index + count) / 48_000
            if let snapshot = analyzer.analyze(pcmBuffer(samples, from: index, count: count), hostTime: time),
               time > 6, snapshot.isTempoLocked {
                tempos.append(snapshot.tempo)
            }
            index += count
        }

        XCTAssertGreaterThan(tempos.count, 200, "the analyzer never locked onto the groove")
        let onPulse = tempos.filter { abs($0 / bpm - 1) < 0.04 }.count
        XCTAssertGreaterThan(
            Double(onPulse) / Double(tempos.count), 0.9,
            "the reported tempo should be the pulse, not a dotted or halved relative of it"
        )
        var switches = 0
        for (previous, current) in zip(tempos, tempos.dropFirst()) where abs(log2(current / previous)) > 0.1 {
            switches += 1
        }
        XCTAssertLessThan(switches, 4, "the grid should not jump between periods while it is locked")
    }

    /// A held chord has no pulse. The onset function still ripples, and the
    /// auto-gain amplifies that ripple, so a confidence measure that only asks
    /// "is this lag better than average" locked a tempo onto it and pulsed the
    /// room. Requiring the onset function to be peaky is what stops it.
    func testSustainedChordNeverLocksATempo() throws {
        let analyzer = MusicFeatureAnalyzer(sourceDescription: "Test")
        let sampleRate = 48_000.0
        var samples = [Float](repeating: 0, count: Int(20 * sampleRate))
        for index in samples.indices {
            let time = Double(index) / sampleRate
            samples[index] = Float(
                0.25 * sin(2 * .pi * 220 * time)
                + 0.18 * sin(2 * .pi * 277.2 * time)
                + 0.14 * sin(2 * .pi * 329.6 * time)
            )
        }
        var lockedFrames = 0
        var highestConfidence = 0.0
        var index = 0
        while index < samples.count {
            let count = min(1_024, samples.count - index)
            if let snapshot = analyzer.analyze(pcmBuffer(samples, from: index, count: count),
                                               hostTime: Double(index + count) / sampleRate) {
                if snapshot.isTempoLocked { lockedFrames += 1 }
                highestConfidence = max(highestConfidence, snapshot.beatConfidence)
            }
            index += count
        }
        XCTAssertEqual(lockedFrames, 0, "a pad with no pulse must not produce a locked tempo")
        XCTAssertLessThan(highestConfidence, 0.38, "confidence should stay under the lock threshold")
    }

    /// Kick, backbeat snare, sixteenth hats and an eighth-note bassline. The
    /// hats and the bassline are what make this harder than a bare click track:
    /// they give every subdivision of the beat something to correlate with.
    private func grooveSamples(bpm: Double, seconds: Double) -> [Float] {
        let sampleRate = 48_000.0
        var buffer = [Float](repeating: 0, count: Int(seconds * sampleRate))
        let beat = 60 / bpm
        var noise = DeterministicNoise(seed: 11)
        func add(_ value: Double, at position: Int) {
            guard position >= 0, position < buffer.count else { return }
            buffer[position] += Float(value)
        }
        var index = 0
        var at = 0.5
        while at < seconds - 0.3 {
            let origin = Int(at * sampleRate)
            // Kick: 110 Hz swept down to 45 Hz.
            for offset in 0..<Int(0.18 * sampleRate) {
                let time = Double(offset) / sampleRate
                let frequency = 45 + 65 * exp(-time / 0.02)
                add(0.9 * exp(-time / 0.055) * sin(2 * .pi * frequency * time), at: origin + offset)
            }
            if index % 4 == 1 || index % 4 == 3 {
                for offset in 0..<Int(0.14 * sampleRate) {
                    let time = Double(offset) / sampleRate
                    let body = (noise.next() * 2 - 1) * 0.55 + sin(2 * .pi * 190 * time) * 0.35
                    add(0.7 * exp(-time / 0.045) * body, at: origin + offset)
                }
            }
            for step in 0..<4 {
                let start = Int((at + Double(step) * beat / 4) * sampleRate)
                for offset in 0..<Int(0.045 * sampleRate) {
                    let decay = exp(-(Double(offset) / sampleRate) / 0.012)
                    let sign: Double = offset.isMultiple(of: 2) ? 0.45 : -0.45
                    add((step == 0 ? 0.35 : 0.55) * decay * (noise.next() * 2 - 1) * sign, at: start + offset)
                }
            }
            let notes = [55.0, 55.0, 82.4, 65.4]
            for half in 0..<2 {
                let start = Int((at + Double(half) * beat * 0.5) * sampleRate)
                let frequency = notes[(index * 2 + half) % notes.count]
                for offset in 0..<Int(beat * 0.45 * sampleRate) {
                    let time = Double(offset) / sampleRate
                    let envelope = min(1, time / 0.008) * exp(-time / (beat * 0.35))
                    add(0.32 * envelope * sin(2 * .pi * frequency * time), at: start + offset)
                }
            }
            at += beat
            index += 1
        }
        return buffer
    }

    private func pcmBuffer(_ samples: [Float], from offset: Int, count: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        let channel = buffer.floatChannelData![0]
        for index in 0..<count { channel[index] = samples[offset + index] }
        return buffer
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
    ///
    /// "downstage" is deliberately absent: `resolvedRole` matches that literal
    /// string in a light's name, so the copy explaining Auto has to quote it
    /// for the explanation to be true and actionable.
    private let jargon = [
        "topology", "fixture", "rgbic", "hsbk", "onset", "vendor",
        "razer", "ptreal", "coalesc", "choreograph",
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

    /// The Auto role reads a light's name. If the copy stops naming the words
    /// it matches on, a user has no way to steer the assignment and the
    /// explanation becomes a claim about intelligence the app does not have.
    func testAutoRoleCopyNamesTheWordsItMatchesOn() {
        let copy = FixtureRole.auto.plainSummary.lowercased()
        for word in ["kick", "downstage", "rear", "accent"] {
            XCTAssertTrue(copy.contains(word), "Auto copy no longer mentions \(word)")
        }
        XCTAssertTrue(copy.contains("segment"), "Auto copy no longer mentions the segment check")
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
