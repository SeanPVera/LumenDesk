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
