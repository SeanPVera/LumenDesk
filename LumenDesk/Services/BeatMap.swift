import AVFoundation
import Foundation

/// One analysis hop's features, used to build and align beat maps.
struct HopFeature: Equatable {
    /// Seconds: stream or host time while analysing, track position once stored.
    var time: TimeInterval
    /// The beat tracker's onset input (broadband onset mixed with kick).
    var onset: Double
    var kick: Double
    var energy: Double
}

/// A whole song analysed ahead of time: every beat, where each bar starts,
/// how loud each bar is, and the onset envelope that lets live capture find
/// its place in the song again.
///
/// Live analysis only hears the past, so it infers the grid and can't know
/// the next bar's energy until it has heard it. With a map the show knows
/// what is coming and plays it against a clock instead.
///
/// Kept in lockstep with `web/app/src/music/beat-map.ts`: the algorithms,
/// constants and test vectors are the same on both sides.
struct BeatMap: Codable, Equatable {
    static let currentVersion = 2
    /// Samples per second of every envelope a map stores or is built from.
    static let envelopeRate = 100.0
    /// Bars in a map always hold four beats; metre overrides still apply on top.
    static let beatsPerBar = 4

    var version: Int
    /// Seconds of audio the map covers, from the start of the track.
    var duration: TimeInterval
    /// Dominant tempo in BPM. Local intervals come from `beats`.
    var tempo: Double
    /// Beat times in seconds from the start of the track, ascending.
    var beats: [TimeInterval]
    /// Index in `beats` of the first downbeat, 0…3. Earlier beats are a pickup.
    var downbeatOffset: Int
    /// 0…1 energy per bar. Bar k starts at `beats[downbeatOffset + 4k]`.
    var barEnergy: [Double]
    /// Onset strength at `envelopeRate`; sample i is at i / envelopeRate seconds.
    var envelope: [Double]
    /// 0…1: how periodic the onset envelope is at the chosen tempo.
    var confidence: Double

    /// Maps below this confidence describe no steady beat and are never played.
    static let minimumPlayableConfidence = 0.08
    var isPlayable: Bool { confidence >= Self.minimumPlayableConfidence && beats.count >= 2 }
}

/// Where a track position falls on a map.
struct BeatMapGrid: Equatable {
    var beatIndex: Int
    var beatTime: TimeInterval
    var interval: TimeInterval
    /// Beat index shifted so every downbeat is a multiple of four.
    var gridBeatPosition: Int
    var beatInBar: Int
    var barIndex: Int
    var barEnergy: Double
}

// MARK: - Building

enum BeatMapBuilder {
    private static let minimumBPM = 55.0
    private static let maximumBPM = 220.0
    private static let priorBPM = 120.0
    private static let priorOctaveWidth = 0.9
    /// How strongly the dynamic program holds beats to the estimated period.
    private static let tightness = 100.0
    private static let minimumDuration: TimeInterval = 8

    struct Envelopes {
        var onset: [Double]
        var kick: [Double]
        var energy: [Double]
        var duration: TimeInterval
    }

    /// Resamples hop features onto the fixed envelope rate by linear
    /// interpolation. Hop times are track positions in seconds.
    static func resample(_ input: [HopFeature], rate: Double = BeatMap.envelopeRate) -> Envelopes {
        let hops = zip(input, input.dropFirst()).allSatisfy({ $0.time <= $1.time })
            ? input : input.sorted { $0.time < $1.time }
        let duration = max(0, hops.last?.time ?? 0)
        let count = hops.isEmpty ? 0 : Int(floor(duration * rate)) + 1
        var onset = [Double](repeating: 0, count: count)
        var kick = onset, energy = onset
        guard !hops.isEmpty else { return Envelopes(onset: onset, kick: kick, energy: energy, duration: duration) }
        var j = 0
        for i in 0..<count {
            let t = Double(i) / rate
            while j + 1 < hops.count, hops[j + 1].time <= t { j += 1 }
            let a = hops[j], b = hops[min(j + 1, hops.count - 1)]
            if t <= a.time || b.time <= a.time {
                onset[i] = a.onset; kick[i] = a.kick; energy[i] = a.energy
            } else {
                let f = (t - a.time) / (b.time - a.time)
                onset[i] = a.onset + (b.onset - a.onset) * f
                kick[i] = a.kick + (b.kick - a.kick) * f
                energy[i] = a.energy + (b.energy - a.energy) * f
            }
        }
        return Envelopes(onset: onset, kick: kick, energy: energy, duration: duration)
    }

    /// Onset novelty: the envelope minus its half-second moving average,
    /// rectified, so loud passages don't correlate with everything.
    static func novelty(_ envelope: [Double], rate: Double = BeatMap.envelopeRate) -> [Double] {
        let n = envelope.count
        guard n > 0 else { return [] }
        let half = max(1, Int((rate * 0.25).rounded()))
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + envelope[i] }
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - half), hi = min(n, i + half + 1)
            let mean = (prefix[hi] - prefix[lo]) / Double(hi - lo)
            out[i] = max(0, envelope[i] - mean)
        }
        return out
    }

    /// Global tempo from the novelty's autocorrelation, weighted by a
    /// log-normal prior around 120 BPM. Each lag also scores half of its
    /// double, which favours the beat over the bar while the prior keeps
    /// eighth notes out. Returns the period in envelope samples and a 0…1
    /// confidence.
    static func estimatePeriod(_ novelty: [Double], rate: Double = BeatMap.envelopeRate) -> (period: Double, confidence: Double) {
        let n = novelty.count
        let minLag = max(2, Int(floor(60 / maximumBPM * rate)))
        let maxLag = Int(ceil(60 / minimumBPM * rate))
        guard n >= maxLag * 4 else { return (0, 0) }
        let mean = novelty.reduce(0, +) / Double(n)
        let centred = novelty.map { $0 - mean }
        let zeroLag = centred.reduce(0) { $0 + $1 * $1 }
        guard zeroLag > 1e-12 else { return (0, 0) }
        var correlation = [Double](repeating: 0, count: maxLag * 2 + 2)
        var lag = minLag
        while lag < correlation.count, lag < n {
            var sum = 0.0
            for i in 0..<(n - lag) { sum += centred[i] * centred[i + lag] }
            correlation[lag] = (sum / Double(n - lag)) / (zeroLag / Double(n))
            lag += 1
        }
        let priorLag = 60 / priorBPM * rate
        var bestLag = 0, bestScore = -Double.infinity
        var scores = [Double](repeating: 0, count: maxLag + 2)
        for lag in minLag...maxLag {
            let octaves = log2(Double(lag) / priorLag) / priorOctaveWidth
            let weight = exp(-0.5 * octaves * octaves)
            let double = lag * 2 < correlation.count ? correlation[lag * 2] : 0
            let score = weight * (correlation[lag] + 0.5 * double)
            scores[lag] = score
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        guard bestLag > 0, bestScore > 0 else { return (0, 0) }
        var period = Double(bestLag)
        if bestLag > minLag, bestLag < maxLag {
            let a = scores[bestLag - 1], b = scores[bestLag], c = scores[bestLag + 1]
            let denominator = a - 2 * b + c
            if denominator < 0 { period += max(-0.5, min(0.5, 0.5 * (a - c) / denominator)) }
        }
        return (period, max(0, min(1, correlation[bestLag])))
    }

    /// Dynamic-programming beat tracking (Ellis 2007): each frame's score is
    /// its novelty plus the best predecessor score, penalised by how far the
    /// gap is from the period in log terms. Returns beat frames ascending.
    static func trackBeats(_ novelty: [Double], period: Double) -> [Int] {
        let n = novelty.count
        guard period > 1, Double(n) >= period * 2 else { return [] }
        let mean = novelty.reduce(0, +) / Double(n)
        let square = novelty.reduce(0) { $0 + $1 * $1 } / Double(n)
        let deviation = sqrt(max(0, square - mean * mean))
        guard deviation > 1e-12 else { return [] }
        let local = novelty.map { $0 / deviation }
        var score = [Double](repeating: 0, count: n)
        var back = [Int](repeating: -1, count: n)
        let nearest = max(1, Int((period / 2).rounded()))
        let farthest = max(nearest + 1, Int((period * 2).rounded()))
        for t in 0..<n {
            var best = -Double.infinity, from = -1
            let first = max(0, t - farthest), last = t - nearest
            if first <= last {
                for p in first...last {
                    let gap = log(Double(t - p) / period)
                    let candidate = score[p] - tightness * gap * gap
                    if candidate > best { best = candidate; from = p }
                }
            }
            if from >= 0, best > 0 {
                score[t] = local[t] + best
                back[t] = from
            } else {
                score[t] = local[t]
            }
        }
        var end = n - 1
        for t in max(0, n - Int(period.rounded()))..<n where score[t] > score[end] { end = t }
        var beats: [Int] = []
        var t = end
        while t >= 0 {
            beats.append(t)
            let previous = back[t]
            if previous < 0 { break }
            t = previous
        }
        beats.reverse()
        return trimSilentEnds(beats, local: local, period: period)
    }

    /// Drops beats at either end whose surroundings hold almost no onset energy.
    private static func trimSilentEnds(_ beats: [Int], local: [Double], period: Double) -> [Int] {
        guard beats.count >= 3 else { return beats }
        let reach = max(1, Int((period / 2).rounded()))
        let strength: [Double] = beats.map { frame in
            let lo = max(0, frame - reach), hi = min(local.count - 1, frame + reach)
            guard lo <= hi else { return 0 }
            var sum = 0.0
            for i in lo...hi { sum += local[i] }
            return sum / Double(hi - lo + 1)
        }
        let sorted = strength.sorted()
        let floor = sorted[sorted.count / 2] * 0.15
        var first = 0, last = beats.count - 1
        while first < last, strength[first] < floor { first += 1 }
        while last > first, strength[last] < floor { last -= 1 }
        return Array(beats[first...last])
    }

    /// Which of the four beat phases is the downbeat: the one where the low
    /// band hits hardest, with a little help from broadband onsets.
    static func downbeatOffset(beatFrames: [Int], kick: [Double], onset: [Double]) -> Int {
        guard beatFrames.count >= BeatMap.beatsPerBar * 2, !kick.isEmpty else { return 0 }
        var sums = [Double](repeating: 0, count: BeatMap.beatsPerBar)
        var counts = sums
        for (index, frame) in beatFrames.enumerated() {
            var peakKick = 0.0, peakOnset = 0.0
            let lo = max(0, frame - 3), hi = min(kick.count - 1, frame + 3)
            if lo <= hi {
                for i in lo...hi {
                    peakKick = max(peakKick, kick[i])
                    if i < onset.count { peakOnset = max(peakOnset, onset[i]) }
                }
            }
            let phase = index % BeatMap.beatsPerBar
            sums[phase] += peakKick + 0.25 * peakOnset
            counts[phase] += 1
        }
        var best = 0
        for phase in 1..<BeatMap.beatsPerBar
        where sums[phase] / max(1, counts[phase]) > sums[best] / max(1, counts[best]) + 1e-9 {
            best = phase
        }
        return best
    }

    /// 0…1 energy per bar: 60 % absolute loudness (a mean energy of 0.75 is
    /// full), 40 % rank within the song. The absolute part keeps a quiet
    /// song's loudest bar from reading as a club drop; the rank part still
    /// lets a song move.
    static func barEnergies(beats: [TimeInterval], downbeatOffset: Int, energy: [Double],
                            rate: Double = BeatMap.envelopeRate) -> [Double] {
        var means: [Double] = []
        var start = downbeatOffset
        while start < beats.count {
            let from = beats[start]
            let interval = start + 1 < beats.count ? beats[start + 1] - beats[start] : 0.5
            let to = start + BeatMap.beatsPerBar < beats.count
                ? beats[start + BeatMap.beatsPerBar] : from + interval * Double(BeatMap.beatsPerBar)
            let a = max(0, Int(floor(from * rate))), b = min(energy.count, Int(ceil(to * rate)))
            if b > a {
                var sum = 0.0
                for i in a..<b { sum += energy[i] }
                means.append(sum / Double(b - a))
            } else {
                means.append(0)
            }
            start += BeatMap.beatsPerBar
        }
        guard !means.isEmpty else { return [] }
        let order = means.indices.sorted { means[$0] < means[$1] || (means[$0] == means[$1] && $0 < $1) }
        var rank = [Double](repeating: 0, count: means.count)
        // Tied bars share their average rank instead of inventing a build-up
        // through a steady passage. One bar has the neutral rank.
        var first = 0
        while first < order.count {
            var end = first + 1
            while end < order.count, means[order[end]] - means[order[first]] < 1e-9 { end += 1 }
            let percentile = means.count == 1 ? 0.5 : Double(first + end - 1) / Double(2 * (means.count - 1))
            for i in first..<end { rank[order[i]] = percentile }
            first = end
        }
        return means.indices.map { index in
            let absolute = max(0, min(1, means[index] / 0.75))
            return max(0, min(1, 0.6 * absolute + 0.4 * rank[index]))
        }
    }

    /// Builds a map from hop features whose times are track positions.
    /// Returns nil for audio too short or too irregular to hold a grid.
    static func build(hops: [HopFeature], rate: Double = BeatMap.envelopeRate) -> BeatMap? {
        let envelopes = resample(hops, rate: rate)
        guard envelopes.duration >= minimumDuration else { return nil }
        let noveltyCurve = novelty(envelopes.onset, rate: rate)
        let (period, confidence) = estimatePeriod(noveltyCurve, rate: rate)
        guard period > 0 else { return nil }
        let frames = trackBeats(noveltyCurve, period: period)
        guard frames.count >= BeatMap.beatsPerBar * 2 else { return nil }
        let offset = downbeatOffset(beatFrames: frames, kick: envelopes.kick, onset: envelopes.onset)
        let beats = frames.map { Double($0) / rate }
        return BeatMap(
            version: BeatMap.currentVersion,
            duration: envelopes.duration,
            tempo: 60 * rate / period,
            beats: beats,
            downbeatOffset: offset,
            barEnergy: barEnergies(beats: beats, downbeatOffset: offset, energy: envelopes.energy, rate: rate),
            envelope: envelopes.onset.map { ($0 * 1000).rounded() / 1000 },
            confidence: confidence
        )
    }

    /// Runs the live analyzer over a whole file, faster than real time, and
    /// builds its map. Call off the main thread; `shouldContinue` cancels.
    static func analyze(file: AVAudioFile,
                        progress: ((Double) -> Void)? = nil,
                        shouldContinue: () -> Bool = { true }) -> BeatMap? {
        let format = file.processingFormat
        let total = file.length
        guard total > 0, format.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192) else { return nil }
        let analyzer = MusicFeatureAnalyzer(sourceDescription: "Beat map")
        var hops: [HopFeature] = []
        hops.reserveCapacity(Int(Double(total) / 512) + 16)
        analyzer.hopObserver = { hop, _ in hops.append(hop) }
        file.framePosition = 0
        var read: AVAudioFramePosition = 0
        var step = 0
        while read < total {
            guard shouldContinue() else { return nil }
            do { try file.read(into: buffer, frameCount: 8_192) } catch { return nil }
            guard buffer.frameLength > 0 else { break }
            read += AVAudioFramePosition(buffer.frameLength)
            // Stream end time as the host time keeps the analyzer's
            // continuity check satisfied and its hop times on track position.
            _ = analyzer.analyze(buffer, hostTime: Double(read) / format.sampleRate)
            step += 1
            if step % 32 == 0 { progress?(Double(read) / Double(total)) }
        }
        progress?(1)
        guard shouldContinue() else { return nil }
        return build(hops: hops)
    }
}

// MARK: - Playing a map

extension BeatMap {
    /// Where `position` falls on the map, or nil before the first beat or after the last.
    func grid(at position: TimeInterval) -> BeatMapGrid? {
        guard beats.count >= 2, position.isFinite, position >= beats[0] - 0.05 else { return nil }
        var lo = 0, hi = beats.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if beats[mid] <= position { lo = mid } else { hi = mid - 1 }
        }
        let index = lo
        let lastIndex = beats.count - 1
        let interval = index < lastIndex
            ? beats[index + 1] - beats[index] : beats[lastIndex] - beats[lastIndex - 1]
        guard interval > 0 else { return nil }
        if index == lastIndex, position - beats[lastIndex] > interval * 1.5 { return nil }
        let shift = (Self.beatsPerBar - (downbeatOffset % Self.beatsPerBar)) % Self.beatsPerBar
        let gridBeatPosition = index + shift
        let barIndex = Int(floor(Double(index - downbeatOffset) / Double(Self.beatsPerBar)))
        let energy = barEnergy.isEmpty ? 0.5 : barEnergy[max(0, min(barEnergy.count - 1, barIndex))]
        return BeatMapGrid(
            beatIndex: index,
            beatTime: beats[index],
            interval: interval,
            gridBeatPosition: gridBeatPosition,
            beatInBar: gridBeatPosition % Self.beatsPerBar,
            barIndex: barIndex,
            barEnergy: energy
        )
    }

    /// Replaces the snapshot's inferred grid with the map's. `position` is
    /// the track position at `timestamp`, both on the renderer's clock.
    /// Loudness and transients stay live, so the bed still follows what is
    /// actually playing.
    func apply(to snapshot: AudioReactiveSnapshot, position: TimeInterval, timestamp: TimeInterval) -> AudioReactiveSnapshot {
        var next = snapshot
        guard isPlayable, let grid = grid(at: position) else {
            next.barEnergy = nil
            next.beatMapActive = false
            return next
        }
        next.beatReferenceTime = timestamp - (position - grid.beatTime)
        next.beatInterval = grid.interval
        next.tempo = 60 / grid.interval
        next.beatConfidence = max(0, min(1, 0.55 + confidence * 1.5))
        next.isTempoLocked = true
        next.gridBeatPosition = grid.gridBeatPosition
        next.beatCount = grid.gridBeatPosition
        next.beatInBar = grid.beatInBar
        next.metre = Self.beatsPerBar
        next.metreConfidence = 1
        next.timeFeel = .straight
        next.feltInterval = grid.interval
        next.feltTempo = 60 / grid.interval
        next.barEnergy = grid.barEnergy
        next.beatMapActive = true
        return next
    }
}

// MARK: - Finding the place again

struct BeatMapAlignment: Equatable {
    /// Seconds to add to the expected position.
    var offset: TimeInterval
    var correlation: Double
    /// How far the best lag beats the best lag at least 60 ms away.
    var margin: Double

    /// A correction worth applying: clear peak, clear winner.
    var isTrustworthy: Bool { correlation >= 0.3 && margin >= 0.04 }
}

enum BeatMapAligner {
    /// Normalised cross-correlation of a live onset envelope against the map
    /// around where the clock says the song is. `live` is sampled at the map
    /// rate and its last sample sits at `endPosition`. Small offsets are
    /// preferred, so a neighbouring beat that correlates as well cannot pull
    /// the clock away.
    static func align(live: [Double], map: BeatMap, endPosition: TimeInterval,
                      radius: TimeInterval = 0.4, rate: Double = BeatMap.envelopeRate) -> BeatMapAlignment? {
        let n = live.count
        guard Double(n) >= rate * 2, let liveNormal = zScore(live) else { return nil }
        let startIndex = Int(((endPosition - Double(n - 1) / rate) * rate).rounded())
        let steps = max(1, Int((radius * rate).rounded()))
        var scores: [(lag: Int, score: Double, correlation: Double)] = []
        var segment = [Double](repeating: 0, count: n)
        for lag in -steps...steps {
            let first = startIndex + lag
            guard first >= 0, first + n <= map.envelope.count else { continue }
            for i in 0..<n { segment[i] = map.envelope[first + i] }
            guard let normal = zScore(segment) else { continue }
            var sum = 0.0
            for i in 0..<n { sum += liveNormal[i] * normal[i] }
            let correlation = sum / Double(n)
            scores.append((lag, correlation - 0.15 * Double(abs(lag)) / rate, correlation))
        }
        guard var best = scores.first else { return nil }
        for entry in scores where entry.score > best.score { best = entry }
        let apart = Int((0.06 * rate).rounded())
        var rival = -Double.infinity
        for entry in scores where abs(entry.lag - best.lag) >= apart { rival = max(rival, entry.score) }
        return BeatMapAlignment(
            offset: Double(best.lag) / rate,
            correlation: best.correlation,
            margin: rival.isFinite ? best.score - rival : best.score
        )
    }

    private static func zScore(_ values: [Double]) -> [Double]? {
        let n = Double(values.count)
        guard n > 0 else { return nil }
        let mean = values.reduce(0, +) / n
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        let deviation = sqrt(variance)
        guard deviation > 1e-9 else { return nil }
        return values.map { ($0 - mean) / deviation }
    }
}

/// Dead-reckons a player's position between reports. Reports close to the
/// prediction only nudge the anchor, because poll timing jitters; a report
/// far from it is a seek, a skip or a stall and re-anchors outright.
/// `correction` carries what the aligner learned on top of the reports.
struct PlaybackClock {
    enum ReportResult: Equatable { case started, jumped, held }

    private var anchorPosition: TimeInterval = 0
    private var anchorTime: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var isKnown = false
    var correction: TimeInterval = 0

    @discardableResult
    mutating func report(position: TimeInterval, at time: TimeInterval, playing: Bool,
                         tolerance: TimeInterval = 0.25) -> ReportResult {
        guard isKnown else {
            anchor(position, at: time, playing: playing)
            correction = 0
            return .started
        }
        let predicted = anchorPosition + (isPlaying ? time - anchorTime : 0)
        if playing != isPlaying || abs(position - predicted) > tolerance {
            let jumped = abs(position - predicted) > tolerance
            anchor(position, at: time, playing: playing)
            if jumped { correction = 0; return .jumped }
            return .held
        }
        // Within tolerance: drift a tenth of the way toward the report.
        anchor(predicted + (position - predicted) * 0.1, at: time, playing: playing)
        return .held
    }

    func position(at time: TimeInterval) -> TimeInterval {
        anchorPosition + (isPlaying ? time - anchorTime : 0) + correction
    }

    /// Applies part of an aligner offset. Tiny offsets are noise, large ones a wrong match.
    @discardableResult
    mutating func nudge(_ offset: TimeInterval) -> Bool {
        guard abs(offset) >= 0.015, abs(offset) <= 0.35 else { return false }
        correction += offset * 0.6
        return true
    }

    mutating func reset() {
        isKnown = false
        isPlaying = false
        correction = 0
    }

    private mutating func anchor(_ position: TimeInterval, at time: TimeInterval, playing: Bool) {
        anchorPosition = position
        anchorTime = time
        isPlaying = playing
        isKnown = true
    }
}

// MARK: - Light timing calibration

/// Measures how late the lights land by timing taps against the beat grid.
/// Each tap is made when the person sees a pulse, so its distance from the
/// nearest beat is the lights' lateness plus the person's own lag. The median
/// of enough consistent taps moves the light timing offset by that much.
///
/// Kept in lockstep with `TapCalibrator` in `web/app/src/music/beat-map.ts`.
struct TapCalibrator {
    static let minimumTaps = 8
    static let maximumTaps = 32
    /// Taps scattered wider than this (median absolute deviation) are guesses.
    static let maximumSpread: TimeInterval = 0.06

    private(set) var errors: [TimeInterval] = []
    private var lastTap: TimeInterval?
    var count: Int { errors.count }

    mutating func tap(at time: TimeInterval, beatReference: TimeInterval, interval: TimeInterval) {
        guard interval >= 0.2, interval <= 2, time.isFinite, beatReference.isFinite else { return }
        if let lastTap, time - lastTap < interval * 0.5 { return }
        lastTap = time
        let beats = (time - beatReference) / interval
        errors.append((beats - beats.rounded()) * interval)
        if errors.count > Self.maximumTaps { errors.removeFirst(errors.count - Self.maximumTaps) }
    }

    /// Median lateness once there are enough consistent taps. Positive means
    /// the lights land after the beat.
    var lateness: TimeInterval? {
        guard errors.count >= Self.minimumTaps else { return nil }
        let middle = Self.median(errors)
        guard Self.median(errors.map { abs($0 - middle) }) <= Self.maximumSpread else { return nil }
        return middle
    }

    /// The offset that would cancel the measured lateness, to the nearest
    /// 10 ms and inside the offset's limits.
    func suggestedOffset(current: Double) -> Double? {
        guard let lateness else { return nil }
        let limit = MusicModeConfiguration.latencyOffsetLimit
        return max(-limit, min(limit, ((current + lateness) * 100).rounded() / 100))
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }
}

// MARK: - Learning a streamed track

/// Records a streamed track's analysis against its playback position on the
/// first listen, so the second listen can play from a map. Only one unbroken
/// pass counts: a seek, a skip or a pause long enough to re-anchor the clock
/// starts the recording over, because stitched passes would put beats in the
/// wrong place.
struct BeatMapLearner {
    let key: String
    let duration: TimeInterval
    private(set) var hops: [HopFeature] = []
    private var lastPosition: TimeInterval?

    init(key: String, duration: TimeInterval) {
        self.key = key
        self.duration = duration
        hops.reserveCapacity(Int(max(0, duration) * 90))
    }

    /// The span of the track heard so far, as a fraction of its length.
    var coverage: Double {
        guard duration > 0, let first = hops.first?.time, let last = hops.last?.time else { return 0 }
        return max(0, min(1, (last - first) / duration))
    }

    /// Whether what was heard is enough to build a map from.
    var isComplete: Bool {
        guard let first = hops.first?.time else { return false }
        return coverage >= 0.85 && first <= 10
    }

    mutating func add(_ hop: HopFeature, position: TimeInterval) {
        guard position.isFinite, position >= 0, duration <= 0 || position <= duration + 1 else { return }
        if let lastPosition {
            let step = position - lastPosition
            // Hops are about 11 ms apart. Anything going backwards, or skipping
            // more than half a second, breaks the pass.
            if step < -0.05 || step > 0.5 { restart() }
        }
        lastPosition = position
        hops.append(HopFeature(time: position, onset: hop.onset, kick: hop.kick, energy: hop.energy))
    }

    mutating func restart() {
        hops.removeAll(keepingCapacity: true)
        lastPosition = nil
    }

    func makeMap() -> BeatMap? {
        guard isComplete else { return nil }
        return BeatMapBuilder.build(hops: hops)
    }
}

// MARK: - Storage

/// Beat maps on disk, one JSON file per track or file, in Application
/// Support. Keys are hashed into file names, so track titles never become
/// paths. The oldest maps are pruned past `capacity`.
final class BeatMapStore {
    private let directory: URL
    private let capacity: Int
    private let fileManager: FileManager

    init(directory: URL? = nil, capacity: Int = 400, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.capacity = max(1, capacity)
        if let directory {
            self.directory = directory
        } else {
            let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                             appropriateFor: nil, create: true))
                ?? fileManager.temporaryDirectory
            self.directory = base.appendingPathComponent("LumenDesk", isDirectory: true)
                .appendingPathComponent("BeatMaps", isDirectory: true)
        }
    }

    func load(key: String) -> BeatMap? {
        guard let data = try? Data(contentsOf: url(for: key)),
              let map = try? JSONDecoder().decode(BeatMap.self, from: data),
              map.version == BeatMap.currentVersion else { return nil }
        return map
    }

    func save(_ map: BeatMap, key: String) {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(map)
            try data.write(to: url(for: key), options: .atomic)
            prune()
        } catch {
            // A map is a cache. Failing to save it only means analysing again.
        }
    }

    func url(for key: String) -> URL {
        directory.appendingPathComponent(Self.fileName(for: key))
    }

    /// FNV-1a 64 of the key, so the name is stable across launches and platforms.
    static func fileName(for key: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx.json", hash)
    }

    private func prune() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]),
              files.count > capacity else { return }
        let dated = files.map { file -> (URL, Date) in
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (file, date)
        }.sorted { $0.1 < $1.1 }
        for (file, _) in dated.prefix(files.count - capacity) {
            try? fileManager.removeItem(at: file)
        }
    }
}

/// A stable identity for an audio file: name, size, modification date and
/// length in frames. Renaming or editing the file means a new map.
enum BeatMapKey {
    static func file(url: URL, frames: AVAudioFramePosition, sampleRate: Double) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "file:\(url.lastPathComponent):\(size):\(Int(modified)):\(frames):\(Int(sampleRate))"
    }
}
