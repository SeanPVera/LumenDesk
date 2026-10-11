import XCTest
@testable import LumenDesk

/// Beat tracking is driven from recorded onset envelopes and exact timestamps,
/// so every case here is deterministic and needs no audio or sleeping.
final class BeatTrackerTests: XCTestCase {
    private let frameInterval = 0.01

    func testLocksOntoASteadyPulseAndPlacesBeatsOnIt() {
        let tracker = BeatTracker(frameInterval: frameInterval)
        let period = 0.5
        let beats = run(tracker, seconds: 12) { time in
            (self.click(at: time, period: period), self.click(at: time, period: period))
        }

        XCTAssertTrue(tracker.grid.isLocked)
        XCTAssertEqual(tracker.grid.tempo, 120, accuracy: 4)
        XCTAssertEqual(tracker.grid.interval, period, accuracy: 0.02)

        let settled = beats.filter { $0.time > 8 }
        XCTAssertGreaterThan(settled.count, 5)
        for beat in settled {
            let phase = beat.time.truncatingRemainder(dividingBy: period)
            let error = min(phase, period - phase)
            XCTAssertLessThan(error, 0.06, "beat at \(beat.time)s sits \(error)s away from the pulse")
        }
    }

    func testKeepsBeatingThroughAGapInOnsets() {
        let tracker = BeatTracker(frameInterval: frameInterval)
        let period = 0.5
        _ = run(tracker, seconds: 10) { time in
            (self.click(at: time, period: period), self.click(at: time, period: period))
        }
        XCTAssertTrue(tracker.grid.isLocked)

        // A held note or a breakdown produces no onsets at all. An onset
        // detector goes quiet here; a beat grid keeps running, which is the
        // whole point of predicting beats instead of reacting to transients.
        let duringGap = run(tracker, seconds: 2, from: 10) { _ in (0, 0) }
        XCTAssertGreaterThanOrEqual(duringGap.count, 3)
        XCTAssertLessThanOrEqual(duringGap.count, 5)
        XCTAssertTrue(tracker.grid.isLocked)
    }

    func testFractionalTemposStayOnPulseAtNativeCaptureHopRates() {
        for tempo in [90.0, 120.0, 137.0, 150.0, 180.0, 200.0] {
            let period = 60 / tempo
            for sampleRate in [44_100.0, 48_000.0] {
                let hopInterval = 512 / sampleRate
                let tracker = BeatTracker(frameInterval: hopInterval)
                var settledBeats = 0
                for frame in 0..<Int(14 / hopInterval) {
                    let time = Double(frame) * hopInterval
                    let kick = click(at: time, period: period)
                    let hats = click(at: time, period: period / 4, width: 0.015) * 0.35
                    if tracker.process(onset: max(kick, hats), lowFrequencyOnset: kick, at: time) > 0,
                       time > 10, tracker.grid.isLocked {
                        settledBeats += 1
                        let phase = tracker.grid.lastBeatTime.truncatingRemainder(dividingBy: period)
                        XCTAssertLessThan(min(phase, period - phase), 0.06,
                                          "\(tempo) BPM at \(sampleRate) Hz drifted away from the pulse")
                    }
                }
                XCTAssertTrue(tracker.grid.isLocked, "\(sampleRate) Hz pulse did not lock")
                XCTAssertEqual(tracker.grid.tempo, tempo, accuracy: 4)
                XCTAssertGreaterThan(settledBeats, 3)
                if tempo == 200 {
                    XCTAssertGreaterThan(tracker.grid.confidence, 0.5,
                                         "The tempo prior must not weaken a coherent 200 BPM pulse")
                }
            }
        }
    }

    func testAlternatingWeakBeatsPreserveTheHalfTimePulse() {
        for sampleRate in [44_100.0, 48_000.0] {
            let hopInterval = 512 / sampleRate
            let tracker = BeatTracker(frameInterval: hopInterval)
            let period = 60.0 / 150
            for frame in 0..<Int(16 / hopInterval) {
                let time = Double(frame) * hopInterval
                let beat = Int((time / period).rounded())
                let onset = click(at: time, period: period) * (beat.isMultiple(of: 2) ? 1 : 0.12)
                tracker.process(onset: onset, lowFrequencyOnset: onset, at: time)
            }
            XCTAssertTrue(tracker.grid.isLocked)
            XCTAssertEqual(tracker.grid.tempo, 75, accuracy: 3)
        }
    }

    func testFractionalPeriodsKeepPhaseAlignedAfterTheHistoryWraps() {
        for tempo in [90.0, 137.0, 150.0, 180.0, 200.0] {
            for sampleRate in [44_100.0, 48_000.0] {
                for hasKick in [false, true] {
                    let hopInterval = 512 / sampleRate
                    let period = 60 / tempo
                    let offset = 0.093
                    let tracker = BeatTracker(frameInterval: hopInterval)
                    var totalError = 0.0
                    var observed = 0
                    for frame in 0..<Int(18 / hopInterval) {
                        let time = Double(frame) * hopInterval
                        let onset = click(at: time - offset + period, period: period, width: 0.025)
                        tracker.process(onset: onset, lowFrequencyOnset: hasKick ? onset : 0, at: time)
                        guard time > 12, tracker.grid.isLocked else { continue }
                        let phase = (tracker.grid.lastBeatTime - offset).truncatingRemainder(dividingBy: period)
                        totalError += min(phase, period - phase)
                        observed += 1
                    }
                    XCTAssertGreaterThan(observed, 400)
                    if observed > 0 {
                        XCTAssertLessThan(totalError / Double(observed), 0.003,
                                          "\(tempo) BPM at \(sampleRate) Hz, kick=\(hasKick)")
                    }
                }
            }
        }
    }

    func testBroadbandPulseStaysOnTimeAfterHistoryWrapAndCaptureReconfiguration() {
        let tracker = BeatTracker()
        for (sampleRate, tempo) in [(48_000.0, 137.0), (44_100.0, 103.0)] {
            let hopInterval = 512 / sampleRate
            tracker.configure(frameInterval: hopInterval)
            tracker.reset()
            let period = 60 / tempo
            var settledBeats = 0
            for frame in 0..<Int(14 / hopInterval) {
                let time = Double(frame) * hopInterval
                let onset = click(at: time, period: period)
                if tracker.process(onset: onset, lowFrequencyOnset: 0, at: time) > 0,
                   time > 10, tracker.grid.isLocked {
                    settledBeats += 1
                    let phase = tracker.grid.lastBeatTime.truncatingRemainder(dividingBy: period)
                    XCTAssertLessThan(min(phase, period - phase), 0.06,
                                      "\(sampleRate) Hz broadband pulse drifted after history wrapped")
                }
            }
            XCTAssertTrue(tracker.grid.isLocked)
            XCTAssertEqual(tracker.grid.tempo, tempo, accuracy: 4)
            XCTAssertGreaterThan(settledBeats, 5)
        }
    }

    func testSlowPulseKeepsItsTempoAndPhaseThroughTheLongestCombLag() {
        for sampleRate in [44_100.0, 48_000.0] {
            let hopInterval = 512 / sampleRate
            let tracker = BeatTracker(frameInterval: hopInterval)
            var settledBeats = 0
            for frame in 0..<Int(18 / hopInterval) {
                let time = Double(frame) * hopInterval
                let onset = click(at: time, period: 1)
                if tracker.process(onset: onset, lowFrequencyOnset: onset, at: time) > 0, time > 12 {
                    settledBeats += 1
                    let phase = tracker.grid.lastBeatTime.truncatingRemainder(dividingBy: 1)
                    XCTAssertLessThan(min(phase, 1 - phase), 0.03)
                }
            }
            XCTAssertTrue(tracker.grid.isLocked)
            XCTAssertEqual(tracker.grid.tempo, 60, accuracy: 0.3)
            XCTAssertGreaterThan(settledBeats, 3)
        }
    }

    func testDoesNotLockOntoUnstructuredInput() {
        let tracker = BeatTracker(frameInterval: frameInterval)
        var noise = DeterministicNoise(seed: 7)
        _ = run(tracker, seconds: 14) { _ in
            let value = noise.next()
            return (value, value)
        }
        XCTAssertFalse(tracker.grid.isLocked)
        XCTAssertLessThan(tracker.grid.confidence, 0.38)
    }

    func testFollowsATempoChange() {
        let tracker = BeatTracker(frameInterval: frameInterval)
        _ = run(tracker, seconds: 10) { time in
            (self.click(at: time, period: 0.5), self.click(at: time, period: 0.5))
        }
        XCTAssertEqual(tracker.grid.tempo, 120, accuracy: 4)

        _ = run(tracker, seconds: 14, from: 10) { time in
            let local = time - 10
            return (self.click(at: local, period: 0.4), self.click(at: local, period: 0.4))
        }
        XCTAssertTrue(tracker.grid.isLocked)
        XCTAssertEqual(tracker.grid.tempo, 150, accuracy: 5)
    }

    func testDownbeatFollowsTheStrongestKickPosition() {
        let tracker = BeatTracker(frameInterval: frameInterval)
        let period = 0.5
        // Every beat gets a click; every fourth also gets a strong kick. The
        // beat a frame belongs to is its *nearest* one, so a frame a hair
        // before the boundary counts toward the beat it is announcing.
        let beats = run(tracker, seconds: 16) { time in
            let onset = self.click(at: time, period: period)
            let beatIndex = Int((time / period).rounded())
            let kick = beatIndex.isMultiple(of: BeatTracker.beatsPerBar) ? onset : onset * 0.25
            return (onset, kick)
        }

        XCTAssertTrue(tracker.grid.isLocked)
        let settled = beats.filter { $0.time > 12 }
        XCTAssertGreaterThan(settled.count, 5)
        for beat in settled {
            let beatIndex = Int((beat.time / period).rounded())
            XCTAssertEqual(
                beat.beatInBar,
                beatIndex % BeatTracker.beatsPerBar,
                "beat at \(beat.time)s was labelled \(beat.beatInBar) in the bar"
            )
        }
    }

    func testConfiguringADifferentFrameIntervalStartsClean() {
        let tracker = BeatTracker(frameInterval: frameInterval)
        _ = run(tracker, seconds: 10) { time in
            (self.click(at: time, period: 0.5), self.click(at: time, period: 0.5))
        }
        XCTAssertTrue(tracker.grid.isLocked)

        tracker.configure(frameInterval: 512 / 44_100)
        XCTAssertFalse(tracker.grid.isLocked)
        XCTAssertEqual(tracker.grid.tempo, 0)
        XCTAssertEqual(tracker.grid.beatCount, 0)
    }

    func testMetreTrackerPrefersThreeOnAWaltzKick() {
        let tracker = MetreTracker()
        for beat in 0..<40 {
            let kick = beat.isMultiple(of: 3) ? 1.0 : 0.08
            tracker.observe(beatCount: beat, kick: kick, tempo: 90, locked: beat >= 12)
        }
        let current = tracker.current()
        XCTAssertEqual(current.metre, 3)
        XCTAssertGreaterThan(current.metreConfidence, 0.2)
    }

    func testMetreTrackerStaysOnFourForFourOnTheFloor() {
        let tracker = MetreTracker()
        for beat in 0..<40 {
            tracker.observe(beatCount: beat, kick: 0.9, tempo: 128, locked: beat >= 12)
        }
        XCTAssertEqual(tracker.current().metre, 4)
    }

    func testHalfTimeFeelFollowsAlternatingWeightAtEitherBeatOffset() {
        for strongParity in 0...1 {
            let tracker = MetreTracker()
            for beat in 0..<64 {
                let kick = beat % 2 == strongParity ? 1.0 : 0.1
                tracker.observe(beatCount: beat, kick: kick, tempo: 150, locked: true)
                if beat >= 24 {
                    XCTAssertEqual(tracker.current().feel, .half,
                                   "Strong parity \(strongParity), beat \(beat)")
                }
            }
        }
    }

    func testSlowAlternatingWeightDoesNotInventDoubleTimeAtEitherBeatOffset() {
        for strongParity in 0...1 {
            let tracker = MetreTracker()
            for beat in 0..<64 {
                let kick = beat % 2 == strongParity ? 1.0 : 0.1
                tracker.observe(beatCount: beat, kick: kick, tempo: 78, locked: true)
                if beat >= 24 {
                    XCTAssertEqual(tracker.current().feel, .straight,
                                   "Strong parity \(strongParity), beat \(beat)")
                }
            }
        }
    }

    func testBalancedSlowPulseUsesDoubleTimeAtEitherBeatOffset() {
        for offset in 0...1 {
            let tracker = MetreTracker()
            for index in 0..<64 {
                tracker.observe(beatCount: index + offset, kick: 0.8, tempo: 78, locked: true)
                if index >= 24 {
                    XCTAssertEqual(tracker.current().feel, .double,
                                   "Offset \(offset), beat \(index)")
                }
            }
        }
    }

    // MARK: - Helpers

    private struct EmittedBeat {
        let time: TimeInterval
        let beatInBar: Int
    }

    /// Drives the tracker frame by frame and records the beats it emits.
    /// `signal` returns the broadband onset and the low-frequency onset for a
    /// frame time.
    private func run(
        _ tracker: BeatTracker,
        seconds: Double,
        from start: TimeInterval = 0,
        signal: (TimeInterval) -> (Double, Double)
    ) -> [EmittedBeat] {
        var emitted: [EmittedBeat] = []
        var time = start
        while time < start + seconds {
            let (onset, low) = signal(time)
            if tracker.process(onset: onset, lowFrequencyOnset: low, at: time) > 0 {
                emitted.append(EmittedBeat(time: tracker.grid.lastBeatTime, beatInBar: tracker.grid.beatInBar))
            }
            time += frameInterval
        }
        return emitted
    }

    /// A triangular onset spike centred on every multiple of `period`.
    private func click(at time: TimeInterval, period: Double, width: Double = 0.03) -> Double {
        let phase = time.truncatingRemainder(dividingBy: period)
        let distance = min(phase, period - phase)
        return distance < width ? 1 - distance / width : 0
    }

    private struct DeterministicNoise {
        private var state: UInt64

        init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }

        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((state >> 33) % 1_000) / 1_000
        }
    }
}
