import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

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
    /// Detected musical metre. Overlay only — `BeatTracker.beatsPerBar` stays 4
    /// so the existing four-four downbeat heuristic and its tests stay intact.
    var metre: Int = 4
    var metreConfidence: Double = 0
    var timeFeel: TimeFeel = .straight
    /// Seconds between felt pulses after half/double-time is applied.
    var feltInterval: TimeInterval = 0
    var feltTempo: Double = 0
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
///    result by a log-normal prior around 120 BPM. The kick band is
///    autocorrelated *separately* and votes alongside the broadband function:
///    mixed into one signal before the transform, dense hi-hats correlate as
///    strongly at a subdivision or a dotted relative as the kick does at the
///    beat, and the search follows the hats.
/// 2. **Phase.** Find the offset within one beat period that best explains
///    where recent onsets actually landed, then run a phase-locked loop that
///    predicts the next beat and nudges itself toward observed onsets.
///
/// Confidence measures how far the winning period is ahead of its nearest
/// *rival* period, not how far it is above the average of every lag. The
/// latter stays near 1 while two candidates are neck and neck, which let the
/// estimate flip between a beat and its dotted relative several times a second
/// while still reporting full confidence — and every flip re-anchored the
/// phase, restarting the light show's contour at an arbitrary point. Locking
/// also requires the onset function to be peaky, because variance alone lets a
/// sustained chord's analysis ripple lock a tempo onto music with no pulse.
///
/// Consumers render from the predicted grid, so beats keep arriving through a
/// sustained note and stop arriving between them. Nothing here touches
/// AVFoundation, so tests drive it with synthetic onset envelopes and exact
/// timestamps. Accelerate only speeds up the same correlation dot products.
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
    /// Linear interpolation of the first three harmonics has breakpoints at
    /// whole, half, and third hops. A sixth-hop grid includes all of them.
    private static let tempoSubdivisions = 6
    private static let octaveMargin = pow(2.0, 0.14)

    private(set) var grid = BeatGrid()

    private var frameInterval: TimeInterval
    private var capacity: Int
    private var history: [Double]
    /// Kick-band onsets over the same window, so periodicity can be scored on
    /// the pulse separately from the full spectrum.
    private var kickHistory: [Double]
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
    private var kickScratch: [Double] = []
    private var autocorrelation: [Double] = []
    private var kickAutocorrelation: [Double] = []
    private var smoothedCorrelation: [Double] = []
    private var smoothedKickCorrelation: [Double] = []
    private var combScores: [Double] = []
    private var tempoPriors: [Double] = []
    private var phaseScores: [Double] = []
    /// A period that disagrees with the current one has to win the same
    /// argument several estimates running before the grid moves.
    private var challengerInterval: TimeInterval = 0
    private var challengerStreak = 0
    private let metreTracker = MetreTracker()

    init(frameInterval: TimeInterval = 512.0 / 48_000.0) {
        let interval = max(0.001, frameInterval)
        self.frameInterval = interval
        capacity = max(64, Int((BeatTracker.historyDuration / interval).rounded()))
        history = [Double](repeating: 0, count: capacity)
        kickHistory = [Double](repeating: 0, count: capacity)
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
        kickHistory = [Double](repeating: 0, count: capacity)
        tempoPriors.removeAll(keepingCapacity: true)
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
        for index in kickHistory.indices { kickHistory[index] = 0 }
        challengerInterval = 0
        challengerStreak = 0
        metreTracker.reset()
    }

    /// Feeds one ODF frame and returns the number of grid beats that fell in it
    /// (normally 0 or 1).
    ///
    /// - Parameters:
    ///   - onset: Broadband onset strength for this frame, normalized to 0…1.
    ///   - lowFrequencyOnset: Onset strength restricted to the kick region.
    ///     Scores the pulse separately from broadband onsets and identifies
    ///     which beat of the bar is the downbeat.
    ///   - time: Frame time on the caller's clock. Must increase monotonically.
    @discardableResult
    func process(onset: Double, lowFrequencyOnset: Double, at time: TimeInterval) -> Int {
        let clampedOnset = max(0, min(1, onset))
        history[writeIndex] = clampedOnset
        kickHistory[writeIndex] = max(0, min(1, lowFrequencyOnset))
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
        if emitted > 0 {
            applyDetectedMusicalTime()
        }
        return emitted
    }

    /// Overlays detected metre and feel onto the grid without changing the
    /// four-four downbeat accumulator that `beatsPerBar` still owns.
    private func applyDetectedMusicalTime() {
        let detected = metreTracker.current()
        grid.metre = detected.metre
        grid.metreConfidence = detected.metreConfidence
        grid.timeFeel = detected.feel
        let multiplier = detected.feel.intervalMultiplier
        grid.feltInterval = grid.interval * multiplier
        grid.feltTempo = grid.tempo / max(0.25, multiplier)
        // Leave `beatInBar` to the four-four downbeat heuristic. Choreography
        // remaps through `snapshot.metre` so existing downbeat tests keep the
        // grid they were written against.
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
        // The predicted beat callback can precede the actual onset. Observe
        // the completed nearest-beat window, not that one arbitrary FFT hop.
        metreTracker.observe(beatCount: grid.beatCount - 1, kick: pendingBarEnergy,
                             tempo: grid.tempo, locked: grid.isLocked)
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
        let lagFrames = max(2, interval / frameInterval)
        let available = min(frameCount, capacity)
        guard Double(available) > lagFrames * 2 else { return nil }

        // Preserve the measured period between frames: rounding it to whole
        // hops accumulates timing error on every tooth of the phase comb.
        let offsets = Int(ceil(lagFrames))
        if phaseScores.count < offsets {
            phaseScores = [Double](repeating: 0, count: offsets)
        } else {
            for offset in 0..<offsets { phaseScores[offset] = 0 }
        }
        var weight = 1.0
        var framesAgo = 0.0
        while framesAgo < Double(available), weight > 0.05 {
            let first = Int(framesAgo)
            let fraction = framesAgo - Double(first)
            let count = min(offsets, available - first - (fraction > 0 ? 1 : 0))
            var index = writeIndex - 1 - first
            if index < 0 { index += capacity }
            // Integer offsets share this tooth's interpolation fraction. Walk
            // the ring directly rather than dividing and indexing per sample.
            for offset in 0..<count {
                let next = index == 0 ? capacity - 1 : index - 1
                phaseScores[offset] += (history[index] * (1 - fraction) + history[next] * fraction) * weight
                index = next
            }
            weight *= 0.85
            framesAgo += lagFrames
        }
        var bestOffset = 0
        var bestScore = -1.0
        for offset in 0..<offsets {
            if phaseScores[offset] > bestScore {
                bestScore = phaseScores[offset]
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
                challengerStreak = 0
            } else {
                // A different period has to win the same argument several
                // estimates running before the grid moves. Adopting each one
                // immediately let a tie between the beat and a dotted or
                // halved relative teleport the grid several times a second,
                // and every jump re-anchored the phase, restarting the
                // brightness contour at an arbitrary point — which is what
                // reads as flashing that has nothing to do with the music.
                let near = challengerInterval > 0
                    && abs(estimate.interval / challengerInterval - 1) < 0.06
                challengerInterval = near
                    ? challengerInterval * 0.6 + estimate.interval * 0.4
                    : estimate.interval
                // Only an estimate that would itself justify the move counts
                // toward the streak. Counting every estimate let a run of
                // ambiguous ones plus a single marginal win re-anchor the grid,
                // which is the opposite of what the streak is for.
                let convincing = estimate.confidence > 0.45
                if near {
                    challengerStreak = convincing ? challengerStreak + 1 : challengerStreak
                } else {
                    challengerStreak = convincing ? 1 : 0
                }
                let required = Self.isSimpleRelative(estimate.interval, of: grid.interval) ? 4 : 2
                if challengerStreak >= required, convincing {
                    // A new track or a real tempo change: adopt it and
                    // re-derive the phase.
                    grid.interval = challengerInterval
                    resyncPhase(now: now)
                    challengerStreak = 0
                }
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

        // Keep the buffers at their final size while history fills. The tempo
        // search still uses exactly the available frames, without reallocating
        // two growing buffers on every estimate during the first eight seconds.
        if scratch.count != capacity {
            scratch = [Double](repeating: 0, count: capacity)
            kickScratch = [Double](repeating: 0, count: capacity)
        }
        var total = 0.0
        var kickTotal = 0.0
        var peak = 0.0
        var historyIndex = writeIndex - available
        if historyIndex < 0 { historyIndex += capacity }
        for index in 0..<available {
            let value = history[historyIndex]
            let kick = kickHistory[historyIndex]
            scratch[index] = value
            kickScratch[index] = kick
            total += value
            kickTotal += kick
            peak = max(peak, value)
            historyIndex += 1
            if historyIndex == capacity { historyIndex = 0 }
        }
        guard peak > 0 else { return nil }
        let mean = total / Double(available)
        var variance = 0.0
        for index in 0..<available {
            scratch[index] -= mean
            variance += scratch[index] * scratch[index]
        }
        variance /= Double(available)
        guard variance > 1e-9 else { return nil }

        let kickMean = kickTotal / Double(available)
        var kickVariance = 0.0
        for index in 0..<available {
            kickScratch[index] -= kickMean
            kickVariance += kickScratch[index] * kickScratch[index]
        }
        kickVariance /= Double(available)

        // How peaky the onset function is over the window. Drums give a tall
        // crest against a low floor; a held chord's analysis ripple does not.
        // Only the first means there is a pulse to find.
        let peakiness = mean > 1e-6 ? peak / mean : 0

        let minimumLag = max(2, Int((60 / Self.maximumTempo) / frameInterval))
        // The comb sum reads the second and third multiple of every candidate,
        // so every candidate lag needs three periods of history behind it.
        // Capping the search there keeps the comb term available for every
        // candidate — dropping it for the longest lags alone would bias the
        // whole search toward faster tempos.
        // Include the enclosing hop so a boundary tempo can still be scored
        // at its fractional period (60 BPM is 93.75 hops at 48 kHz).
        let maximumLag = min(available / 3 - 1, Int(ceil((60 / Self.minimumTempo) / frameInterval)))
        guard minimumLag + 2 < maximumLag else { return nil }
        let combLimit = maximumLag * 3
        guard combLimit < available else { return nil }

        if autocorrelation.count != combLimit + 1 {
            autocorrelation = [Double](repeating: 0, count: combLimit + 1)
            kickAutocorrelation = [Double](repeating: 0, count: combLimit + 1)
            smoothedCorrelation = [Double](repeating: 0, count: combLimit + 1)
            smoothedKickCorrelation = [Double](repeating: 0, count: combLimit + 1)
        }
        // The comb only reads candidate lags and their multiples. Preserve
        // the one lower neighbour needed by smoothing, and skip every shorter
        // lag: none of them contributes to a tempo candidate or its confidence.
        let firstCorrelationLag = minimumLag - 1
        correlate(into: &autocorrelation, from: scratch, available: available, variance: variance,
                  firstLag: firstCorrelationLag, limit: combLimit)
        smooth(into: &smoothedCorrelation, from: autocorrelation, firstLag: minimumLag, limit: combLimit)
        let hasKick = kickVariance > 1e-9
        if hasKick {
            correlate(into: &kickAutocorrelation, from: kickScratch, available: available, variance: kickVariance,
                      firstLag: firstCorrelationLag, limit: combLimit)
            smooth(into: &smoothedKickCorrelation, from: kickAutocorrelation, firstLag: minimumLag, limit: combLimit)
        }

        // Score harmonics at the same fractional period. Rounding each
        // candidate to one whole hop can sample its second and third peaks
        // one or two hops away, while its half-time relative lands exactly on
        // every peak. That made a 150 BPM pulse at 48 kHz win as 75 BPM.
        let firstCandidate = minimumLag * Self.tempoSubdivisions
        let lastCandidate = maximumLag * Self.tempoSubdivisions
        if combScores.count != lastCandidate + 1 {
            combScores = [Double](repeating: 0, count: lastCandidate + 1)
        }
        if tempoPriors.count != lastCandidate + 1 {
            tempoPriors = [Double](repeating: 0, count: lastCandidate + 1)
            for candidate in firstCandidate...lastCandidate {
                let lag = Double(candidate) / Double(Self.tempoSubdivisions)
                tempoPriors[candidate] = Self.tempoPrior(bpm: 60 / (lag * frameInterval))
            }
        }
        var bestCandidate = firstCandidate
        var bestScore = -Double.greatestFiniteMagnitude
        for candidate in firstCandidate...lastCandidate {
            // Comb-summing the multiples is what keeps a strong offbeat from
            // being read as the beat: the true period correlates with itself
            // at every multiple, half the period does not.
            let lag = Double(candidate) / Double(Self.tempoSubdivisions)
            let broad = comb(smoothedCorrelation, lag: lag)
            // The kick band votes separately. Material with no kick at all
            // falls back to the broadband term.
            let kick = hasKick ? comb(smoothedKickCorrelation, lag: lag) : broad
            let score = max(0, 0.55 * broad + 0.45 * kick) * tempoPriors[candidate]
            combScores[candidate] = score
            if score > bestScore {
                bestScore = score
                bestCandidate = candidate
            }
        }
        guard bestScore > 0 else { return nil }

        // Every pulse also repeats at twice its period. The tempo prior can
        // favour that slower octave (90 over 180 BPM), even when onsets fill
        // both of its halves equally. Prefer the shorter, primitive pulse
        // only when both bands support nearly the same comb periodicity and
        // a strong first-harmonic peak there. Actual half-time accents and
        // subdivisions with no kick do not meet those conditions.
        for _ in 0..<2 {
            let lower = bestCandidate / 2
            let upper = (bestCandidate + 1) / 2
            guard lower >= firstCandidate else { break }
            let candidate = combScores[upper] > combScores[lower] ? upper : lower
            let shortLag = Double(candidate) / Double(Self.tempoSubdivisions)
            let longLag = Double(bestCandidate) / Double(Self.tempoSubdivisions)
            let shortBroad = comb(smoothedCorrelation, lag: shortLag)
            let longBroad = comb(smoothedCorrelation, lag: longLag)
            let shortKick = hasKick ? comb(smoothedKickCorrelation, lag: shortLag) : shortBroad
            let longKick = hasKick ? comb(smoothedKickCorrelation, lag: longLag) : longBroad
            let broad = correlation(smoothedCorrelation, lag: shortLag)
            let anchor = correlation(smoothedCorrelation, lag: longLag)
            let kick = hasKick ? correlation(smoothedKickCorrelation, lag: shortLag) : broad
            let anchorKick = hasKick ? correlation(smoothedKickCorrelation, lag: longLag) : anchor
            guard shortBroad >= longBroad * 0.9, shortKick >= longKick * 0.9,
                  broad >= max(0.18, anchor * 0.85), kick >= max(0.18, anchorKick * 0.85) else { break }
            bestCandidate = candidate
            // Confidence compares support for this octave family against
            // genuinely different periods. Keep its original winning score:
            // the prior favours 100 over 200 BPM, but that cannot weaken an
            // otherwise validated 200 BPM pulse merely by naming its octave.
        }

        // The best score among genuinely different periods, skipping the
        // winner's own peak. Measuring prominence against the mean of every
        // lag instead stays high even when a rival is neck and neck.
        var rivalScore = 0.0
        let octaveLower = Double(bestCandidate) / Self.octaveMargin
        let octaveUpper = Double(bestCandidate) * Self.octaveMargin
        for candidate in firstCandidate...lastCandidate {
            // A periodic pulse necessarily correlates at every octave of its
            // period, so half and double are the same pulse counted at another
            // metrical level rather than a rival reading of the music. Skipping
            // whole octaves — and, at distance zero, the winner's own peak —
            // leaves the genuinely different periods, which is where the
            // flipping actually came from: the dotted relative at 1.5x.
            //
            // Counting the octave as a rival kept a clean 180 BPM pulse below
            // the lock threshold indefinitely, because the 120-centred prior
            // scores its half at 90 slightly *higher* than 180 itself, so the
            // two tied and separation collapsed.
            // Only quarter-to-fourfold octave peaks can lie within the search.
            // Scaling by powers of two gives the same ±0.14-octave exclusion as log2,
            // without recalculating a logarithm for every fractional candidate.
            let value = Double(candidate)
            let half = value * 0.5
            let double = value * 2
            let quarter = value * 0.25
            let quadruple = value * 4
            if (value >= octaveLower && value <= octaveUpper)
                || (half >= octaveLower && half <= octaveUpper)
                || (double >= octaveLower && double <= octaveUpper)
                || (quarter >= octaveLower && quarter <= octaveUpper)
                || (quadruple >= octaveLower && quadruple <= octaveUpper) { continue }
            if combScores[candidate] > rivalScore { rivalScore = combScores[candidate] }
        }
        let separation = max(0, (bestScore - rivalScore) / bestScore)

        let refinedLag = (Double(bestCandidate) + Self.parabolicOffset(
            previous: bestCandidate > firstCandidate ? combScores[bestCandidate - 1] : 0,
            peak: combScores[bestCandidate],
            next: bestCandidate < lastCandidate ? combScores[bestCandidate + 1] : 0
        )) / Double(Self.tempoSubdivisions)
        let interval = min(60 / Self.minimumTempo, max(60 / Self.maximumTempo, refinedLag * frameInterval))

        let bestLag = Double(bestCandidate) / Double(Self.tempoSubdivisions)
        let coefficient = max(0, correlation(smoothedCorrelation, lag: bestLag))
        // Silence and unstructured noise autocorrelate weakly; requiring ODF
        // activity as well keeps a quiet room from "locking" onto anything.
        let activity = min(1, sqrt(variance) * 6)
        let rhythmic = min(1, max(0, (peakiness - 2.2) / 3.5))
        // A pulse has to be strong, clearly ahead of its rivals, loud enough
        // to measure, and actually percussive.
        let confidence = min(1, coefficient * 1.8)
            * min(1, separation * 2.4)
            * activity
            * (0.25 + 0.75 * rhythmic)
        return TempoEstimate(interval: interval, confidence: max(0, min(1, confidence)))
    }

    private func correlation(_ table: [Double], lag: Double) -> Double {
        let lower = Int(lag)
        let upper = min(lower + 1, table.count - 1)
        let fraction = lag - Double(lower)
        return table[lower] + (table[upper] - table[lower]) * fraction
    }

    private func comb(_ table: [Double], lag: Double) -> Double {
        (correlation(table, lag: lag) + 0.5 * correlation(table, lag: lag * 2)
            + 0.25 * correlation(table, lag: lag * 3)) / 1.75
    }

    private func correlate(
        into table: inout [Double],
        from source: [Double],
        available: Int,
        variance: Double,
        firstLag: Int,
        limit: Int
    ) {
        #if canImport(Accelerate)
        // Each lag is a dot product over the same contiguous history. Keep
        // its normalization and Double precision, while letting Accelerate
        // vectorize the expensive inner loop without allocating slices.
        source.withUnsafeBufferPointer { samples in
            guard let base = samples.baseAddress else { return }
            for lag in firstLag...limit {
                var sum = 0.0
                vDSP_dotprD(base.advanced(by: lag), 1, base, 1, &sum,
                           vDSP_Length(available - lag))
                table[lag] = sum / (Double(available - lag) * variance)
            }
        }
        #else
        for lag in firstLag...limit {
            var sum = 0.0
            var index = lag
            while index < available {
                sum += source[index] * source[index - lag]
                index += 1
            }
            table[lag] = sum / (Double(available - lag) * variance)
        }
        #endif
    }

    /// Three-tap smoothing. A beat period rarely lands on a whole number of
    /// analysis hops, so its correlation peak is split across two lags; a rival
    /// period that happens to land on one would otherwise win on bin alignment
    /// alone rather than on the music.
    private func smooth(into table: inout [Double], from source: [Double], firstLag: Int, limit: Int) {
        for lag in firstLag...limit {
            let previous = lag > 1 ? source[lag - 1] : source[lag]
            let next = lag < limit ? source[lag + 1] : source[lag]
            table[lag] = 0.25 * previous + 0.5 * source[lag] + 0.25 * next
        }
    }

    /// True when `candidate` is within a few percent of a simple musical
    /// relative of `current` — half, double, three halves, and so on. Those are
    /// the likeliest ways to be wrong, so they have to argue longer.
    private static func isSimpleRelative(_ candidate: TimeInterval, of current: TimeInterval) -> Bool {
        guard current > 0, candidate > 0 else { return false }
        let ratio = candidate / current
        for relative in [0.5, 2, 1.5, 2.0 / 3, 3, 1.0 / 3, 4.0 / 3, 0.75] where abs(ratio / relative - 1) < 0.05 {
            return true
        }
        return false
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

}

/// Estimates 3/4/5/6/7 from kick-energy periodicity and half/double feel
/// from even-versus-odd beat weight. Folded into BeatTracker.swift so it
/// needs no new pbxproj file ID.
final class MetreTracker {
    private static let candidates = [3, 4, 5, 6, 7]

    private var kickHistory: [Double] = []
    private var evenEnergy: Double = 0
    private var oddEnergy: Double = 0
    private var metre = 4
    private var metreConfidence: Double = 0
    private var feel: TimeFeel = .straight
    private var lastBeat = -1

    func reset() {
        kickHistory.removeAll(keepingCapacity: true)
        evenEnergy = 0
        oddEnergy = 0
        metre = 4
        metreConfidence = 0
        feel = .straight
        lastBeat = -1
    }

    func observe(beatCount: Int, kick: Double, tempo: Double, locked: Bool) {
        guard beatCount != lastBeat else { return }
        lastBeat = beatCount
        kickHistory.append(max(0, kick))
        if kickHistory.count > 64 { kickHistory.removeFirst(kickHistory.count - 64) }

        let decay = 0.92
        if beatCount.isMultiple(of: 2) {
            evenEnergy = evenEnergy * decay + kick
        } else {
            oddEnergy = oddEnergy * decay + kick
        }

        guard locked, kickHistory.count >= 12 else { return }

        // Score four first so a tied prominence (four-on-the-floor, every beat
        // equally loud) cannot be stolen by 3 just because it is listed first.
        var best = 4
        var bestScore = scoreMetre(4)
        var scores: [Int: Double] = [4: bestScore]
        for n in Self.candidates where n != 4 {
            let score = scoreMetre(n)
            scores[n] = score
            if score > bestScore {
                bestScore = score
                best = n
            }
        }

        let fourScore = scores[4] ?? 0
        let adopt = best == metre || bestScore > fourScore * 1.12
        let next = adopt ? best : metre
        if next != metre {
            if bestScore > metreConfidence + 0.08 { metre = next }
        } else {
            metre = next
        }
        metreConfidence = max(0, min(1, bestScore))

        // The first tracked beat can fall on either side of an alternating
        // pulse. Compare stronger and weaker positions so feel does not
        // depend on that arbitrary even/odd origin.
        let ratio = max(evenEnergy, oddEnergy) / max(0.0001, min(evenEnergy, oddEnergy))
        if tempo >= 125, ratio > 2.15 {
            feel = .half
        } else if tempo <= 88, ratio < 1.25, evenEnergy + oddEnergy > 0.4 {
            feel = .double
        } else {
            feel = .straight
        }
    }

    func current() -> (metre: Int, metreConfidence: Double, feel: TimeFeel) {
        (metre, metreConfidence, feel)
    }

    private func scoreMetre(_ n: Int) -> Double {
        var bins = [Double](repeating: 0, count: n)
        var counts = [Int](repeating: 0, count: n)
        let oldest = lastBeat - kickHistory.count + 1
        for (index, value) in kickHistory.enumerated() {
            let beat = oldest + index
            let slot = ((beat % n) + n) % n
            bins[slot] += value
            counts[slot] += 1
        }
        // Average per slot so a leftover sample cannot fake a downbeat.
        // 40 equal kicks would otherwise make 3 look more periodic than 4
        // because 40 % 3 leaves an extra hit in bin 0.
        for i in 0..<n where counts[i] > 0 {
            bins[i] /= Double(counts[i])
        }
        guard let maxBin = bins.max(), maxBin > 1e-6 else { return 0 }
        let mean = bins.reduce(0, +) / Double(n)
        let prominence = (maxBin - mean) / maxBin
        let downbeatIndex = bins.firstIndex(of: maxBin) ?? 0
        var grouped = 0.0
        if n == 6 {
            let a = bins[0] + bins[3]
            let b = bins[1] + bins[4]
            let c = bins[2] + bins[5]
            // Waltz (equal weight on 1 and 4 of a 6-count) must not outscore 3/4.
            // True 6/8 has a heavier downbeat than the secondary grouping.
            if a > b, a > c, bins[0] > bins[3] * 1.15 {
                grouped = 0.18
            }
        }
        let alignment = downbeatIndex == 0 ? 0.12 : 0
        return max(0, min(1, prominence * 0.85 + grouped + alignment))
    }
}
