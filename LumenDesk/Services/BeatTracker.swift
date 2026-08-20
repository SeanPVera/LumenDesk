import Foundation

/// The tempo grid Music Mode choreographs against.
///
/// `lastBeatTime` and `interval` are the contract downstream code renders
/// from: any renderer can extrapolate an exact beat phase for its own frame
/// time instead of waiting for an analysis callback to tell it a beat
/// happened.
struct BeatGrid: Equatable {
    /// Beats per minute. Zero until a tempo has been estimated.
    var tempo: Double = 0
    /// Seconds between beats. Zero until a tempo has been estimated.
    var interval: TimeInterval = 0
    /// 0…1 measure of how strongly the recent audio supports this grid.
    var confidence: Double = 0
    /// Time of the most recent beat on the predicted grid, on the caller's clock.
    var lastBeatTime: TimeInterval = 0
    /// Position of `lastBeatTime` inside an assumed four-beat bar.
    var beatInBar: Int = 0
    /// Monotonic count of beats emitted on the grid.
    var beatCount: Int = 0
    /// True once the grid is trustworthy enough to choreograph against.
    var isLocked: Bool = false
}

/// Estimates tempo and beat phase from an onset-detection function (ODF).
///
/// Music Mode used to treat every onset as a beat, which is why dense
/// material read as indiscriminate flashing: a sixteenth-note hi-hat pattern
/// manufactured eight "beats" a second, and nothing in the pipeline knew what
/// the actual pulse of the song was. This class separates the two ideas.
///
/// Two stages, both standard beat-tracking practice:
///
/// 1. **Periodicity.** Autocorrelate several seconds of ODF, comb-sum each
///    candidate lag with its second and third multiples so a half- or
///    double-time peak cannot outvote the true beat period, and weight the
///    result by a log-normal prior around 120 BPM.
/// 2. **Phase.** Find the offset within one beat period that best explains
///    where recent onsets actually landed, then run a phase-locked loop that
///    predicts the next beat and nudges itself toward observed onsets.
///
/// Consumers render from the predicted grid, so beats keep arriving through a
/// sustained note and stop arriving between them. Nothing here touches
/// AVFoundation or Accelerate, so tests drive it with synthetic onset
/// envelopes and exact timestamps.
final class BeatTracker {
    static let minimumTempo: Double = 60
    static let maximumTempo: Double = 200
    static let beatsPerBar = 4

    /// Seconds of ODF history retained for periodicity analysis. Long enough
    /// to hold four bars at 60 BPM, short enough to follow a tempo change.
    private static let historyDuration: TimeInterval = 8
    /// How often the (comparatively expensive) tempo search runs.
    private static let estimationInterval: TimeInterval = 0.25
    /// Periodicity needs a few beats of evidence before it means anything.
    /// Three and a half seconds is also what the comb sum needs to reach the
    /// third multiple of a 60 BPM candidate without running off the history.
    private static let minimumHistoryDuration: TimeInterval = 3.5

    private(set) var grid = BeatGrid()

    private var frameInterval: TimeInterval
    private var capacity: Int
    private var history: [Double]
    private var writeIndex = 0
    private var frameCount = 0

    private var latestFrameTime: TimeInterval = 0
    private var nextBeatTime: TimeInterval = 0
    private var lastEstimateTime = -Double.greatestFiniteMagnitude
    private var smoothedConfidence: Double = 0
    private var onsetScale: Double = 0.001
    private var barEnergies = [Double](repeating: 0, count: BeatTracker.beatsPerBar)
    private var barOffset = 0
    private var pendingBarSlot = 0
    private var pendingBarEnergy: Double = 0
    private var nextBarEnergy: Double = 0
    private var scratch: [Double] = []
    private var autocorrelation: [Double] = []
    private var combScores: [Double] = []

    init(frameInterval: TimeInterval = 512.0 / 48_000.0) {
        let interval = max(0.001, frameInterval)
        self.frameInterval = interval
        capacity = max(64, Int((BeatTracker.historyDuration / interval).rounded()))
        history = [Double](repeating: 0, count: capacity)
    }

    /// Re-anchors the tracker when the capture format changes. A different hop
    /// duration invalidates every lag in the history, so the history is dropped
    /// rather than reinterpreted.
    func configure(frameInterval newInterval: TimeInterval) {
        let interval = max(0.001, newInterval)
        guard abs(interval - frameInterval) > frameInterval * 0.01 else { return }
        frameInterval = interval
        capacity = max(64, Int((Self.historyDuration / interval).rounded()))
        history = [Double](repeating: 0, count: capacity)
        reset()
    }

    func reset() {
        grid = BeatGrid()
        writeIndex = 0
        frameCount = 0
        latestFrameTime = 0
        nextBeatTime = 0
        lastEstimateTime = -Double.greatestFiniteMagnitude
        smoothedConfidence = 0
        onsetScale = 0.001
        for index in barEnergies.indices { barEnergies[index] = 0 }
        barOffset = 0
        pendingBarSlot = 0
        pendingBarEnergy = 0
        nextBarEnergy = 0
        for index in history.indices { history[index] = 0 }
    }

    /// Feeds one ODF frame and returns the number of grid beats that fell in it
    /// (normally 0 or 1).
    ///
    /// - Parameters:
    ///   - onset: Broadband onset strength for this frame, normalized to 0…1.
    ///   - lowFrequencyOnset: Onset strength restricted to the kick region.
    ///     Used only to decide which beat of the bar is the downbeat.
    ///   - time: Frame time on the caller's clock. Must increase monotonically.
    @discardableResult
    func process(onset: Double, lowFrequencyOnset: Double, at time: TimeInterval) -> Int {
        let clampedOnset = max(0, min(1, onset))
        history[writeIndex] = clampedOnset
        writeIndex = (writeIndex + 1) % capacity
        frameCount += 1
        latestFrameTime = time
        onsetScale = clampedOnset > onsetScale
            ? onsetScale + (clampedOnset - onsetScale) * 0.3
            : max(0.001, onsetScale * 0.9995)

        if time - lastEstimateTime >= Self.estimationInterval {
            lastEstimateTime = time
            updateTempo(now: time)
        }

        guard grid.interval > 0 else { return 0 }
        correctPhase(onset: clampedOnset, at: time)
        let emitted = emitBeats(upTo: time)
        accumulateBarEnergy(lowFrequencyOnset, at: time)
        return emitted
    }

    // MARK: - Beat emission

    private func emitBeats(upTo time: TimeInterval) -> Int {
        if nextBeatTime <= 0 { nextBeatTime = time + grid.interval }
        // A stalled or restarted capture can leave the predicted grid far in
        // the past. Re-anchor instead of emitting a burst of catch-up beats.
        if time - nextBeatTime > grid.interval * 2 {
            grid.lastBeatTime = time
            nextBeatTime = time + grid.interval
            return 0
        }

        var emitted = 0
        // Half a frame of tolerance so a beat landing between frames is
        // reported on the nearer frame rather than always one frame late.
        while nextBeatTime <= time + frameInterval * 0.5 && emitted < 2 {
            grid.lastBeatTime = nextBeatTime
            grid.beatCount += 1
            nextBeatTime += grid.interval
            emitted += 1
            rotateBarEnergy()
        }
        return emitted
    }

    /// Credits kick energy to the beat it is *nearest* to: a beat owns half an
    /// interval either side of itself. Crediting whichever beat was emitted
    /// most recently would instead hand a kick that lands a little early to the
    /// beat before it, and how early counts as "a little" would depend on
    /// frame timing rather than on the music.
    private func accumulateBarEnergy(_ lowFrequencyOnset: Double, at time: TimeInterval) {
        guard grid.interval > 0, grid.lastBeatTime > 0 else { return }
        let value = max(0, lowFrequencyOnset)
        if time - grid.lastBeatTime < grid.interval * 0.5 {
            pendingBarEnergy = max(pendingBarEnergy, value)
        } else {
            nextBarEnergy = max(nextBarEnergy, value)
        }
    }

    /// Picks the downbeat by accumulating kick energy per position in a
    /// four-beat bar. It is a heuristic, not metre detection: the strongest
    /// position wins, and sustained disagreement moves it.
    private func rotateBarEnergy() {
        // A new beat means the previous beat's window is complete, so fold it
        // in and start the new beat's window with whatever already arrived in
        // its leading half.
        for index in barEnergies.indices { barEnergies[index] *= 0.94 }
        barEnergies[pendingBarSlot] += pendingBarEnergy
        pendingBarSlot = ((grid.beatCount % Self.beatsPerBar) + Self.beatsPerBar) % Self.beatsPerBar
        pendingBarEnergy = nextBarEnergy
        nextBarEnergy = 0

        var strongest = 0
        for index in barEnergies.indices where barEnergies[index] > barEnergies[strongest] {
            strongest = index
        }
        barOffset = strongest
        grid.beatInBar = ((pendingBarSlot - barOffset) % Self.beatsPerBar + Self.beatsPerBar) % Self.beatsPerBar
    }

    // MARK: - Phase

    private func correctPhase(onset: Double, at time: TimeInterval) {
        guard grid.interval > 0, grid.lastBeatTime > 0 else { return }
        guard onset > onsetScale * 0.45, onset > 0.1 else { return }
        let error = time - nearestBeatTime(to: time)
        // Onsets more than a quarter beat away are syncopation, not evidence
        // that the grid is wrong.
        guard abs(error) < grid.interval * 0.25 else { return }
        let strength = min(1, onset / max(0.001, onsetScale))
        let gain = 0.08 * strength
        shiftGrid(by: error * gain)
        // Let a persistent, one-sided error stretch the period slightly so a
        // live or drifting tempo stays locked between full re-estimates.
        let adjusted = grid.interval + error * gain * 0.05
        grid.interval = min(60 / Self.minimumTempo, max(60 / Self.maximumTempo, adjusted))
        grid.tempo = 60 / grid.interval
    }

    private func nearestBeatTime(to time: TimeInterval) -> TimeInterval {
        let beats = ((time - grid.lastBeatTime) / grid.interval).rounded()
        return grid.lastBeatTime + beats * grid.interval
    }

    private func shiftGrid(by delta: TimeInterval) {
        grid.lastBeatTime += delta
        nextBeatTime += delta
    }

    private func resyncPhase(now: TimeInterval) {
        guard grid.interval > 0 else { return }
        guard let anchor = estimatePhaseAnchor(interval: grid.interval) else {
            grid.lastBeatTime = now
            nextBeatTime = now + grid.interval
            return
        }
        var last = anchor
        let steps = floor((now - last) / grid.interval)
        if steps > 0 { last += steps * grid.interval }
        grid.lastBeatTime = last
        nextBeatTime = last + grid.interval
    }

    /// Returns the time of a beat implied by the ODF: the offset within one
    /// period whose sampled frames carry the most onset energy, weighted
    /// toward the present.
    private func estimatePhaseAnchor(interval: TimeInterval) -> TimeInterval? {
        let lagFrames = max(2, Int((interval / frameInterval).rounded()))
        let available = min(frameCount, capacity)
        guard available > lagFrames * 2 else { return nil }

        var bestOffset = 0
        var bestScore = -1.0
        for offset in 0..<lagFrames {
            var score = 0.0
            var weight = 1.0
            var framesAgo = offset
            while framesAgo < available && weight > 0.05 {
                score += historyValue(framesAgo: framesAgo) * weight
                weight *= 0.85
                framesAgo += lagFrames
            }
            if score > bestScore {
                bestScore = score
                bestOffset = offset
            }
        }
        guard bestScore > 0 else { return nil }
        return latestFrameTime - Double(bestOffset) * frameInterval
    }

    // MARK: - Tempo

    private func updateTempo(now: TimeInterval) {
        guard let estimate = estimateTempo() else {
            smoothedConfidence *= 0.8
            applyLockState()
            return
        }

        smoothedConfidence = smoothedConfidence * 0.7 + estimate.confidence * 0.3
        if grid.interval <= 0 {
            grid.interval = estimate.interval
            resyncPhase(now: now)
        } else {
            let ratio = estimate.interval / grid.interval
            if abs(ratio - 1) < 0.06 {
                grid.interval = grid.interval * 0.85 + estimate.interval * 0.15
            } else if estimate.confidence > 0.45 {
                // A different period this confident means a new track or a
                // real tempo change: adopt it and re-derive the phase.
                grid.interval = estimate.interval
                resyncPhase(now: now)
            }
        }
        grid.tempo = 60 / grid.interval

        // Re-confirm the phase even while locked so a track that drifts, or a
        // passage the phase-locked loop drifted through, re-anchors instead of
        // free-running.
        if let anchor = estimatePhaseAnchor(interval: grid.interval) {
            let error = anchor - nearestBeatTime(to: anchor)
            shiftGrid(by: error * (abs(error) > grid.interval * 0.12 ? 0.5 : 0.15))
        }
        applyLockState()
    }

    private func applyLockState() {
        smoothedConfidence = max(0, min(1, smoothedConfidence))
        // Hysteresis: locking needs real evidence, staying locked does not, so
        // a quiet bar or a breakdown does not drop the show off the grid.
        grid.isLocked = smoothedConfidence >= (grid.isLocked ? 0.22 : 0.38)
        grid.confidence = smoothedConfidence
    }

    private struct TempoEstimate {
        let interval: TimeInterval
        let confidence: Double
    }

    private func estimateTempo() -> TempoEstimate? {
        let available = min(frameCount, capacity)
        guard Double(available) * frameInterval >= Self.minimumHistoryDuration else { return nil }

        if scratch.count != available { scratch = [Double](repeating: 0, count: available) }
        var total = 0.0
        for index in 0..<available {
            let value = historyValue(framesAgo: available - 1 - index)
            scratch[index] = value
            total += value
        }
        let mean = total / Double(available)
        var variance = 0.0
        for index in 0..<available {
            scratch[index] -= mean
            variance += scratch[index] * scratch[index]
        }
        variance /= Double(available)
        guard variance > 1e-9 else { return nil }

        let minimumLag = max(2, Int((60 / Self.maximumTempo) / frameInterval))
        // The comb sum reads the second and third multiple of every candidate,
        // so every candidate lag needs three periods of history behind it.
        // Capping the search there keeps the comb term available for every
        // candidate — dropping it for the longest lags alone would bias the
        // whole search toward faster tempos.
        let maximumLag = min(available / 3 - 1, Int((60 / Self.minimumTempo) / frameInterval))
        guard minimumLag + 2 < maximumLag else { return nil }
        let combLimit = maximumLag * 3
        guard combLimit < available else { return nil }

        if autocorrelation.count != combLimit + 1 {
            autocorrelation = [Double](repeating: 0, count: combLimit + 1)
        }
        for lag in 1...combLimit {
            var sum = 0.0
            var index = lag
            while index < available {
                sum += scratch[index] * scratch[index - lag]
                index += 1
            }
            autocorrelation[lag] = sum / (Double(available - lag) * variance)
        }

        if combScores.count != maximumLag + 1 {
            combScores = [Double](repeating: 0, count: maximumLag + 1)
        }
        var bestLag = minimumLag
        var bestScore = -Double.greatestFiniteMagnitude
        var scoreTotal = 0.0
        for lag in minimumLag...maximumLag {
            // Comb-summing the multiples is what keeps a strong offbeat from
            // being read as the beat: the true period correlates with itself
            // at every multiple, half the period does not.
            let comb = (autocorrelation[lag]
                + 0.5 * autocorrelation[lag * 2]
                + 0.25 * autocorrelation[lag * 3]) / 1.75
            let bpm = 60 / (Double(lag) * frameInterval)
            let score = max(0, comb) * Self.tempoPrior(bpm: bpm)
            combScores[lag] = score
            scoreTotal += score
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }
        guard bestScore > 0 else { return nil }

        let refinedLag = Double(bestLag) + Self.parabolicOffset(
            previous: bestLag > minimumLag ? combScores[bestLag - 1] : 0,
            peak: combScores[bestLag],
            next: bestLag < maximumLag ? combScores[bestLag + 1] : 0
        )
        let interval = min(60 / Self.minimumTempo, max(60 / Self.maximumTempo, refinedLag * frameInterval))

        let meanScore = scoreTotal / Double(maximumLag - minimumLag + 1)
        let prominence = (bestScore - meanScore) / bestScore
        let coefficient = max(0, autocorrelation[bestLag])
        // Silence and unstructured noise autocorrelate weakly; requiring ODF
        // activity as well keeps a quiet room from "locking" onto anything.
        let activity = min(1, sqrt(variance) * 6)
        let confidence = min(1, coefficient * 1.8) * min(1, prominence * 2.2) * activity
        return TempoEstimate(interval: interval, confidence: max(0, min(1, confidence)))
    }

    private static func tempoPrior(bpm: Double) -> Double {
        let octaves = log2(bpm / 120) / 0.9
        return exp(-0.5 * octaves * octaves)
    }

    /// Sub-frame peak position from three samples, clamped to the neighbouring
    /// bins so a flat or noisy peak cannot throw the estimate.
    private static func parabolicOffset(previous: Double, peak: Double, next: Double) -> Double {
        let denominator = previous - 2 * peak + next
        guard abs(denominator) > 1e-12 else { return 0 }
        let offset = 0.5 * (previous - next) / denominator
        return max(-0.5, min(0.5, offset))
    }

    private func historyValue(framesAgo: Int) -> Double {
        let available = min(frameCount, capacity)
        guard framesAgo >= 0, framesAgo < available else { return 0 }
        var index = writeIndex - 1 - framesAgo
        while index < 0 { index += capacity }
        return history[index % capacity]
    }
}
