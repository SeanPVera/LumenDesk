import AVFoundation
import Accelerate
#if os(macOS)
import CoreServices
import ScreenCaptureKit
#endif

struct AudioReactiveSnapshot: Equatable {
    var level: Double = 0
    var beat: Double = 0
    var kick: Double = 0
    var snare: Double = 0
    var percussion: Double = 0
    var bass: Double = 0
    var mids: Double = 0
    var highs: Double = 0
    var energy: Double = 0
    var mood: Double = 0.5
    var confidence: Double = 0
    // Fast-attack / slow-decay envelope that spikes on every onset — the
    // "heartbeat" the light show pulses brightness to. Once a tempo is locked
    // its decay is a fraction of the beat interval, so the pulse breathes with
    // the song instead of at one fixed rate.
    var pulse: Double = 0
    // 0…1 strength of a sustained high-intensity section. Choreography treats
    // this as evidence, not as a guaranteed musical "drop."
    var drop: Double = 0
    // Monotonic count of beats. Once the tempo is locked these come from the
    // predicted beat grid, not from raw onsets, so choreography steps once per
    // musical beat rather than once per hi-hat.
    var beatCount: Int = 0
    /// Detected tempo in BPM, or 0 when no tempo is locked.
    var tempo: Double = 0
    /// Seconds per beat, or 0 when no tempo is locked.
    var beatInterval: TimeInterval = 0
    /// 0…1 confidence in the tempo estimate, reported even when unlocked so
    /// choreography can cross-fade between musical and energy-driven behavior.
    var beatConfidence: Double = 0
    /// Host-clock time of the most recent beat on the predicted grid, or 0.
    /// Renderers extrapolate their own beat phase from this and `beatInterval`
    /// so beat timing is limited by their frame clock, not by analysis latency.
    var beatReferenceTime: TimeInterval = 0
    /// Position of `beatReferenceTime` inside an assumed four-beat bar.
    var beatInBar: Int = 0
    /// True once the grid is trustworthy enough to choreograph against.
    var isTempoLocked: Bool = false
    var sourceDescription: String = "Microphone input"
}

final class AudioCaptureService {
    struct SubscriptionToken: Hashable {
        fileprivate let id: UUID
    }

    private let engine = AVAudioEngine()
    // Touched only on `analysisQueue`, which both owns the analyzer's mutable
    // state and serializes it against the capture callbacks.
    private var analyzer = MusicFeatureAnalyzer(sourceDescription: "Microphone input")
    // Mic taps deliver on the AVAudioEngine render thread while system-audio
    // taps deliver on their own capture queue; serialize both onto this queue
    // before touching the analyzer's mutable state.
    private let analysisQueue = DispatchQueue(label: "LumenDesk.audioAnalysis")
    // A single-slot guard sheds buffers only when analysis is genuinely behind,
    // instead of dropping most of the audio on a fixed timer. Beat tracking
    // needs a gapless signal: the previous 20 Hz throttle analyzed 1024 samples
    // out of every 50 ms and never saw the other 60% of the music, so onsets
    // landing in the gaps were invisible and beat times could only ever be
    // accurate to ±25 ms.
    private let analysisSlot = DispatchSemaphore(value: 1)
    // Analysis produces a snapshot per hop (~90 Hz). The main thread only needs
    // the newest one, so publication is throttled independently — except for
    // beats, which are published immediately.
    private let publicationInterval: TimeInterval = 0.04
    private var lastPublishedHostTime = -Double.greatestFiniteMagnitude
    // Several rooms can run the same audio-reactive effect. They share one
    // capture session instead of starting a ScreenCaptureKit/AVAudioEngine
    // pipeline per room.
    private var isStarting = false
    private(set) var isRunning = false
    private var startGeneration = 0
    private var startCompletions: [(AudioStartResult) -> Void] = []
    private var snapshotSubscribers: [UUID: (AudioReactiveSnapshot) -> Void] = [:]
    var onLevel: ((Double) -> Void)?
    var onSnapshot: ((AudioReactiveSnapshot) -> Void)?

    #if os(macOS)
    private var systemAudioCapture: SystemAudioCapture?
    #endif

    /// Outcome of starting the analysis source, so the caller can show the
    /// precise message. On macOS the source is system audio (ScreenCaptureKit);
    /// on iOS it is the microphone.
    enum AudioStartResult: Equatable {
        /// Capture is running and feeding the analyzer.
        case started
        /// macOS only: Screen Recording is not granted. macOS shows its prompt
        /// on the first-ever attempt; after granting, starting Music Mode again
        /// picks the grant up — permission is re-checked live on every start.
        /// Never falls back to the microphone.
        case needsScreenRecording
        /// Source could not start for a non-permission reason (mic denied on iOS,
        /// no display, OS too old, or a capture error).
        case unavailable
    }

    @discardableResult
    func subscribe(_ subscriber: @escaping (AudioReactiveSnapshot) -> Void) -> SubscriptionToken {
        let token = SubscriptionToken(id: UUID())
        snapshotSubscribers[token.id] = subscriber
        return token
    }

    func unsubscribe(_ token: SubscriptionToken) {
        snapshotSubscribers.removeValue(forKey: token.id)
    }

    func requestAccessAndStart(completion: @escaping (AudioStartResult) -> Void) {
        if isRunning {
            completion(.started)
            return
        }
        startCompletions.append(completion)
        guard !isStarting else { return }
        isStarting = true
        startGeneration += 1
        let generation = startGeneration
        resetAnalyzer(sourceDescription: preferredSourceDescription)
        #if os(macOS)
        // macOS: system audio (Apple Music / other apps) is the SOLE source.
        // The microphone is never started here, so room noise can't pollute the
        // music analysis, and there is no silent mic fallback.
        let capture = SystemAudioCapture { [weak self] buffer in
            // SystemAudioCapture already created an owned mono buffer. Avoid
            // allocating and copying it a second time before analysis.
            self?.consume(buffer, requiresOwnedCopy: false)
        }
        systemAudioCapture = capture
        capture.start { [weak self] result in
            guard let self else { return }
            guard self.startGeneration == generation else {
                capture.stop()
                return
            }
            let startResult: AudioStartResult
            switch result {
            case .started:
                self.setSourceDescription("System audio")
                startResult = .started
            case .needsScreenRecording:
                self.setSourceDescription("System audio unavailable — Screen Recording off")
                self.systemAudioCapture = nil
                startResult = .needsScreenRecording
            case .unavailable:
                self.setSourceDescription("System audio unavailable")
                self.systemAudioCapture = nil
                startResult = .unavailable
            }
            self.finishStart(startResult)
        }
        #else
        // iOS: microphone is the only available source (no ScreenCaptureKit).
        startMicrophone { [weak self] started in
            guard let self, self.startGeneration == generation else { return }
            self.finishStart(started ? .started : .unavailable)
        }
        #endif
    }

    private func finishStart(_ result: AudioStartResult) {
        isStarting = false
        isRunning = result == .started
        let completions = startCompletions
        startCompletions.removeAll(keepingCapacity: true)
        for completion in completions { completion(result) }
    }

    /// The analyzer and its publication clock live on the analysis queue, so
    /// replacing or relabelling them is scheduled there rather than racing a
    /// capture callback that is already analyzing a buffer.
    private func resetAnalyzer(sourceDescription: String) {
        analysisQueue.async { [weak self] in
            guard let self else { return }
            self.analyzer = MusicFeatureAnalyzer(sourceDescription: sourceDescription)
            self.lastPublishedHostTime = -Double.greatestFiniteMagnitude
        }
    }

    private func setSourceDescription(_ description: String) {
        analysisQueue.async { [weak self] in
            self?.analyzer.sourceDescription = description
        }
    }

    private var preferredSourceDescription: String {
        #if os(macOS)
        "System audio"
        #else
        "Microphone input"
        #endif
    }

    #if os(iOS)
    private func startMicrophone(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(start())
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    completion(granted && (self?.start() ?? false))
                }
            }
        default:
            completion(false)
        }
    }

    @discardableResult
    private func start() -> Bool {
        guard !engine.isRunning else { return true }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, options: [.mixWithOthers, .defaultToSpeaker])
        try? session.setActive(true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { return false }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }

        do {
            try engine.start()
            return true
        } catch {
            input.removeTap(onBus: 0)
            return false
        }
    }
    #endif

    private func consume(_ buffer: AVAudioPCMBuffer, requiresOwnedCopy: Bool = true) {
        guard analysisSlot.wait(timeout: .now()) == .success else { return }
        let hostTime = ProcessInfo.processInfo.systemUptime
        let analysisBuffer: AVAudioPCMBuffer
        if requiresOwnedCopy {
            guard let ownedBuffer = buffer.ownedFloatCopy() else {
                analysisSlot.signal()
                return
            }
            analysisBuffer = ownedBuffer
        } else {
            analysisBuffer = buffer
        }
        analysisQueue.async { [weak self] in
            guard let self else { return }
            defer { self.analysisSlot.signal() }
            guard let snapshot = self.analyzer.analyze(analysisBuffer, hostTime: hostTime) else { return }
            guard snapshot.beat > 0 || hostTime - self.lastPublishedHostTime >= self.publicationInterval else { return }
            self.lastPublishedHostTime = hostTime
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onLevel?(snapshot.level)
                self.onSnapshot?(snapshot)
                for subscriber in self.snapshotSubscribers.values { subscriber(snapshot) }
            }
        }
    }

    func stop() {
        startGeneration += 1
        isStarting = false
        isRunning = false
        startCompletions.removeAll(keepingCapacity: true)
        #if os(iOS)
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        #endif
        #if os(macOS)
        systemAudioCapture?.stop()
        systemAudioCapture = nil
        #endif
    }
}

/// Source-compatible name for saved call sites while Music Mode moves onto
/// the shared, multi-subscriber capture service.
typealias AudioLevelMonitor = AudioCaptureService

private extension AVAudioPCMBuffer {
    /// AVAudioEngine tap memory is only valid for the duration of the callback.
    /// Copying the accepted buffer makes the asynchronous analyzer safe.
    func ownedFloatCopy() -> AVAudioPCMBuffer? {
        guard !format.isInterleaved,
              let source = floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength),
              let destination = copy.floatChannelData else { return nil }
        copy.frameLength = frameLength
        let frames = Int(frameLength)
        for channel in 0..<Int(format.channelCount) {
            destination[channel].update(from: source[channel], count: frames)
        }
        return copy
    }
}

/// Turns captured audio into the musical features Music Mode choreographs to.
///
/// The analyzer runs a gapless short-time Fourier transform: incoming buffers
/// of any size are accumulated into a ring and analyzed on a fixed 512-sample
/// hop, so every sample is examined and onset times are accurate to about one
/// hop (~11 ms at 48 kHz). Every time constant is expressed in seconds and
/// applied against the hop duration, so envelopes decay at the rate they claim
/// to regardless of the capture buffer size the OS happens to choose.
///
/// Onsets are measured as half-wave-rectified flux of *log* magnitudes across
/// log-spaced bands. Working in the log domain makes onset strength
/// independent of playback volume, and giving each band equal weight keeps a
/// kick drum visible against a wall of cymbals.
///
/// Onsets are not beats. They are fed to `BeatTracker`, which estimates tempo
/// and beat phase; while a tempo is locked, `beatCount` advances on the
/// predicted grid instead of on every transient.
final class MusicFeatureAnalyzer {
    var sourceDescription: String

    private static let windowSize = 2_048
    private static let hopSize = 512
    private static let logCompression = 1_000.0
    /// Floor for the onset auto-gain. Real onsets measure roughly 0.1…0.8 in
    /// these units while a steady tone leaves numerical ripple around 1e-4, so
    /// a floor two orders of magnitude above the ripple keeps a decaying gain
    /// from amplifying a held note back up into phantom onsets, and still lets
    /// genuinely quiet material drive a full show.
    private static let minimumOnsetScale = 0.01

    private struct BinRange {
        let first: Int
        let last: Int
        var count: Int { max(1, last - first + 1) }
    }

    // Gapless STFT plumbing.
    private var ring = [Float](repeating: 0, count: MusicFeatureAnalyzer.windowSize)
    private var ringWriteIndex = 0
    private var samplesUntilHop = MusicFeatureAnalyzer.hopSize
    private var processedSamples: Int64 = 0
    private var monoSamples: [Float] = []
    private var chronologicalSamples = [Float](repeating: 0, count: MusicFeatureAnalyzer.windowSize)
    private var windowedSamples = [Float](repeating: 0, count: MusicFeatureAnalyzer.windowSize)
    private var hannWindow = [Float](repeating: 0, count: MusicFeatureAnalyzer.windowSize)

    // One reusable Accelerate real FFT.
    private var fftSetup: FFTSetup?
    private var fftLog2Size: vDSP_Length = 0
    private var fftReal = [Float](repeating: 0, count: MusicFeatureAnalyzer.windowSize / 2)
    private var fftImaginary = [Float](repeating: 0, count: MusicFeatureAnalyzer.windowSize / 2)
    private var fftMagnitudes = [Float](repeating: 0, count: MusicFeatureAnalyzer.windowSize / 2)
    private var logMagnitudes = [Double](repeating: 0, count: MusicFeatureAnalyzer.windowSize / 2)
    private var previousLogMagnitudes = [Double](repeating: 0, count: MusicFeatureAnalyzer.windowSize / 2)

    // Band layout, rebuilt when the capture format changes.
    private var configuredSampleRate: Double = 0
    private var bassBins = BinRange(first: 1, last: 1)
    private var midsBins = BinRange(first: 1, last: 1)
    private var highsBins = BinRange(first: 1, last: 1)
    private var kickBins = BinRange(first: 1, last: 1)
    private var snareBins = BinRange(first: 1, last: 1)
    private var hatBins = BinRange(first: 1, last: 1)
    private var fluxBands: [BinRange] = []

    // Automatic gain. Everything the show reacts to is normalized against a
    // fast-attack / slow-decay peak so the choreography looks the same whether
    // the music is quiet or cranked.
    private var noiseFloor: Double = 0.01
    private var peakLevel: Double = 0.02
    private var bandPeak: Double = 0.0005
    private var odfScale = MusicFeatureAnalyzer.minimumOnsetScale
    private var kickScale = MusicFeatureAnalyzer.minimumOnsetScale
    private var snareScale = MusicFeatureAnalyzer.minimumOnsetScale
    private var hatScale = MusicFeatureAnalyzer.minimumOnsetScale

    // Show envelopes and onset gating.
    private var noveltyBaseline: Double = 0
    private var noveltyDeviation: Double = 0
    private var beatCooldownRemaining: Double = 0
    private var pulseEnv: Double = 0
    private var dropEnv: Double = 0
    private var energyBaseline: Double = 0
    private var beatCount = 0

    // Beat tracking runs on the analyzer's own sample clock — immune to
    // callback jitter — and is converted to host time for renderers through a
    // slowly-corrected anchor.
    private let beatTracker = BeatTracker()
    private var hostTimeOffset: TimeInterval = 0
    private var hasHostAnchor = false

    init(sourceDescription: String) {
        self.sourceDescription = sourceDescription
        vDSP_hann_window(&hannWindow, vDSP_Length(Self.windowSize), Int32(vDSP_HANN_DENORM))
        fftLog2Size = vDSP_Length(round(log2(Double(Self.windowSize))))
        fftSetup = vDSP_create_fftsetup(fftLog2Size, FFTRadix(kFFTRadix2))
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    /// Consumes one capture buffer and returns the most recent hop's features,
    /// or nil when the buffer did not complete a hop.
    ///
    /// - Parameter hostTime: When the buffer was captured, on the same clock
    ///   the renderer uses. Beat times are reported on that clock.
    func analyze(_ buffer: AVAudioPCMBuffer, hostTime: TimeInterval? = nil) -> AudioReactiveSnapshot? {
        guard let channelData = buffer.floatChannelData, fftSetup != nil else { return nil }
        let frameCount = Int(buffer.frameLength)
        let sampleRate = buffer.format.sampleRate
        guard frameCount > 0, sampleRate > 0 else { return nil }
        configureIfNeeded(sampleRate: sampleRate)

        let channels = Int(buffer.format.channelCount)
        if monoSamples.count != frameCount {
            monoSamples = [Float](repeating: 0, count: frameCount)
        } else {
            vDSP_vclr(&monoSamples, 1, vDSP_Length(frameCount))
        }
        for channel in 0..<channels {
            monoSamples.withUnsafeMutableBufferPointer { destination in
                guard let output = destination.baseAddress else { return }
                vDSP_vadd(
                    output, 1,
                    channelData[channel], 1,
                    output, 1,
                    vDSP_Length(frameCount)
                )
            }
        }
        var divisorValue = Float(max(1, channels))
        vDSP_vsdiv(monoSamples, 1, &divisorValue, &monoSamples, 1, vDSP_Length(frameCount))

        updateHostAnchor(
            hostTime: hostTime ?? ProcessInfo.processInfo.systemUptime,
            streamTime: Double(processedSamples + Int64(frameCount)) / sampleRate
        )

        var latest: AudioReactiveSnapshot?
        var strongestBeat = 0.0
        var index = 0
        while index < frameCount {
            let chunk = max(1, min(samplesUntilHop, frameCount - index))
            copyIntoRing(from: index, count: chunk)
            index += chunk
            processedSamples += Int64(chunk)
            samplesUntilHop -= chunk
            if samplesUntilHop <= 0 {
                samplesUntilHop = Self.hopSize
                let snapshot = analyzeHop(sampleRate: sampleRate)
                strongestBeat = max(strongestBeat, snapshot.beat)
                latest = snapshot
            }
        }
        guard var snapshot = latest else { return nil }
        // A beat can land on any hop in the buffer, not only the last one.
        // Reporting the strongest keeps the beat indicator and the publication
        // gate honest; `beatCount` is monotonic, so choreography never misses
        // one regardless.
        snapshot.beat = strongestBeat
        return snapshot
    }

    // MARK: - Per-hop analysis

    private func analyzeHop(sampleRate: Double) -> AudioReactiveSnapshot {
        let dt = Double(Self.hopSize) / sampleRate
        let streamTime = Double(processedSamples) / sampleRate

        fillChronologicalWindow()
        var meanSquare: Float = 0
        vDSP_measqv(chronologicalSamples, 1, &meanSquare, vDSP_Length(Self.windowSize))
        let rms = Double(sqrt(meanSquare))
        vDSP_vmul(
            chronologicalSamples, 1,
            hannWindow, 1,
            &windowedSamples, 1,
            vDSP_Length(Self.windowSize)
        )
        updateSpectrum()

        // Loudness: track the quiet floor and a fast-attack, slowly-decaying
        // peak, then normalize between them so level reads 0…1 at any volume.
        noiseFloor += (min(rms, noiseFloor + 0.002) - noiseFloor) * decayCoefficient(dt: dt, timeConstant: 10)
        peakLevel = rms > peakLevel
            ? peakLevel + (rms - peakLevel) * 0.25
            : max(0.0005, peakLevel * exp(-dt / 10))
        let level = clamp((rms - noiseFloor) / max(0.015, peakLevel - noiseFloor))

        let bassRaw = bandMagnitude(bassBins)
        let midsRaw = bandMagnitude(midsBins)
        let highsRaw = bandMagnitude(highsBins)
        let loudestBand = max(bassRaw, max(midsRaw, highsRaw))
        bandPeak = loudestBand > bandPeak
            ? bandPeak + (loudestBand - bandPeak) * 0.3
            : max(0.000_02, bandPeak * exp(-dt / 8))
        let bandScale = 0.9 / bandPeak
        let bass = clamp(bassRaw * bandScale)
        let mids = clamp(midsRaw * bandScale)
        let highs = clamp(highsRaw * bandScale)

        // Onsets: rectified flux of log magnitudes. Each log-spaced band is
        // averaged and then weighted equally, so a kick occupying three bins
        // counts as much as cymbals spread over hundreds.
        var bandFluxTotal = 0.0
        for band in fluxBands { bandFluxTotal += positiveFlux(band) }
        let rawOnset = fluxBands.isEmpty ? 0 : bandFluxTotal / Double(fluxBands.count)
        let rawKick = positiveFlux(kickBins)
        let rawSnare = positiveFlux(snareBins)
        let rawHat = positiveFlux(hatBins)
        swap(&logMagnitudes, &previousLogMagnitudes)

        let onset = normalize(rawOnset, scale: &odfScale, dt: dt)
        let kick = normalize(rawKick, scale: &kickScale, dt: dt)
        let snare = normalize(rawSnare, scale: &snareScale, dt: dt)
        let percussion = normalize(rawHat, scale: &hatScale, dt: dt)
        let energy = clamp(level * 0.4 + bass * 0.3 + mids * 0.16 + highs * 0.14)

        // Tempo and phase. The tracker runs on stream time so it is unaffected
        // by callback jitter; its grid is converted to host time below.
        //
        // The onset function it sees leans on the low band, because that is
        // where the beat usually lives. On the equally-weighted broadband
        // function alone, sixteenth-note hi-hats correlate just as strongly at
        // 160 BPM as the kick pattern does at 120, and the search can settle on
        // the hats. Mixing in the kick band breaks that tie toward the pulse a
        // listener would clap to, while the broadband term still carries
        // material with no kick at all.
        let beatOnset = clamp(onset * 0.6 + kick * 0.4)
        let emittedBeats = beatTracker.process(
            onset: beatOnset,
            lowFrequencyOnset: kick,
            at: streamTime
        )
        let grid = beatTracker.grid

        // Adaptive onset gate on the same signal. Only used as a fallback:
        // material without a detectable pulse (ambient, spoken word, sparse
        // acoustic) still gets a show, it is just driven by onsets rather than
        // by a grid.
        let baselineCoefficient = decayCoefficient(dt: dt, timeConstant: 1.5)
        noveltyBaseline += (beatOnset - noveltyBaseline) * baselineCoefficient
        noveltyDeviation += (abs(beatOnset - noveltyBaseline) - noveltyDeviation) * baselineCoefficient
        let onsetThreshold = noveltyBaseline + max(0.09, noveltyDeviation * 2.2)

        var beatStrength = 0.0
        if grid.isLocked {
            if emittedBeats > 0 {
                beatCount += emittedBeats
                beatStrength = clamp(0.6 + onset * 0.4)
            }
        } else if beatOnset > onsetThreshold, beatOnset > 0.18, beatCooldownRemaining <= 0 {
            beatCount += 1
            beatCooldownRemaining = 0.16
            beatStrength = clamp(0.5 + beatOnset * 0.5)
        }
        beatCooldownRemaining = max(0, beatCooldownRemaining - dt)

        // Pulse decays over a fraction of the beat, so it reads as one discrete
        // hit per beat at any tempo instead of a fixed twitch rate.
        let pulseDecay = grid.isLocked ? min(0.34, max(0.1, grid.interval * 0.42)) : 0.16
        pulseEnv = max(pulseEnv * exp(-dt / pulseDecay), onset * 0.85)
        if beatStrength > 0 { pulseEnv = max(pulseEnv, 0.9) }
        let pulse = clamp(pulseEnv)

        // Sustained energy above the running baseline. Music Mode treats this
        // as evidence, not as guaranteed section/drop detection.
        energyBaseline += (energy - energyBaseline) * decayCoefficient(dt: dt, timeConstant: 3.3)
        let intensity = clamp((energy - 0.5) * 2.4) * clamp((energy - energyBaseline) * 4 + 0.3)
        dropEnv = max(dropEnv * exp(-dt / 0.3), intensity)

        // Mood: treble-leaning reads bright/airy (→1), bass-leaning dark/heavy (→0).
        let mood = clamp(0.5 + (highs - bass) * 0.6 + mids * 0.05)

        return AudioReactiveSnapshot(
            level: level,
            beat: beatStrength,
            kick: kick,
            snare: snare,
            percussion: percussion,
            bass: bass,
            mids: mids,
            highs: highs,
            energy: energy,
            mood: mood,
            confidence: clamp(level * 1.8),
            pulse: pulse,
            drop: clamp(dropEnv),
            beatCount: beatCount,
            tempo: grid.isLocked ? grid.tempo : 0,
            beatInterval: grid.isLocked ? grid.interval : 0,
            beatConfidence: grid.confidence,
            beatReferenceTime: grid.lastBeatTime > 0 ? grid.lastBeatTime + hostTimeOffset : 0,
            beatInBar: grid.beatInBar,
            isTempoLocked: grid.isLocked,
            sourceDescription: sourceDescription
        )
    }

    // MARK: - Spectrum

    private func updateSpectrum() {
        guard let fftSetup else { return }
        let size = Self.windowSize
        let half = size / 2
        for index in 0..<half {
            fftReal[index] = windowedSamples[index * 2]
            fftImaginary[index] = windowedSamples[index * 2 + 1]
        }
        fftReal.withUnsafeMutableBufferPointer { real in
            fftImaginary.withUnsafeMutableBufferPointer { imaginary in
                guard let realBase = real.baseAddress, let imaginaryBase = imaginary.baseAddress else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imaginaryBase)
                vDSP_fft_zrip(fftSetup, &split, 1, fftLog2Size, FFTDirection(FFT_FORWARD))
                fftMagnitudes.withUnsafeMutableBufferPointer { magnitudes in
                    guard let magnitudeBase = magnitudes.baseAddress else { return }
                    vDSP_zvabs(&split, 1, magnitudeBase, 1, vDSP_Length(half))
                }
            }
        }
        var scale = 1 / Float(size)
        vDSP_vsmul(fftMagnitudes, 1, &scale, &fftMagnitudes, 1, vDSP_Length(half))
        // Compressed log magnitudes are what the flux is measured on: the
        // difference of two logs is a ratio, so an onset means the same thing
        // at any playback volume. Bin 0 packs DC and Nyquist together and
        // carries rumble and any DC offset, so it never participates in a band.
        for index in 1..<half {
            logMagnitudes[index] = log1p(Double(fftMagnitudes[index]) * Self.logCompression)
        }
    }

    private func bandMagnitude(_ range: BinRange) -> Double {
        var mean: Float = 0
        fftMagnitudes.withUnsafeBufferPointer { magnitudes in
            guard let base = magnitudes.baseAddress else { return }
            vDSP_meanv(base.advanced(by: range.first), 1, &mean, vDSP_Length(range.count))
        }
        return Double(mean)
    }

    private func positiveFlux(_ range: BinRange) -> Double {
        var total = 0.0
        for index in range.first...range.last {
            let difference = logMagnitudes[index] - previousLogMagnitudes[index]
            if difference > 0 { total += difference }
        }
        return total / Double(range.count)
    }

    /// Divides by a fast-attack, slow-decay peak so onset strength is relative
    /// to how hard this material actually hits, not to absolute volume.
    private func normalize(_ value: Double, scale: inout Double, dt: Double) -> Double {
        if value > scale {
            scale += (value - scale) * 0.3
        } else {
            scale = max(Self.minimumOnsetScale, scale * exp(-dt / 6))
        }
        return clamp(value / scale * 0.9)
    }

    // MARK: - Buffering

    private func copyIntoRing(from sourceIndex: Int, count: Int) {
        var copied = 0
        while copied < count {
            let amount = min(Self.windowSize - ringWriteIndex, count - copied)
            let destinationIndex = ringWriteIndex
            let sourceOffset = sourceIndex + copied
            monoSamples.withUnsafeBufferPointer { source in
                guard let sourceBase = source.baseAddress else { return }
                ring.withUnsafeMutableBufferPointer { destination in
                    guard let destinationBase = destination.baseAddress else { return }
                    destinationBase.advanced(by: destinationIndex)
                        .update(from: sourceBase.advanced(by: sourceOffset), count: amount)
                }
            }
            ringWriteIndex = (ringWriteIndex + amount) % Self.windowSize
            copied += amount
        }
    }

    /// Unrolls the ring into oldest-to-newest order. `ringWriteIndex` is the
    /// next slot to write, which is also the oldest retained sample.
    private func fillChronologicalWindow() {
        let size = Self.windowSize
        let head = ringWriteIndex
        let tail = size - head
        chronologicalSamples.withUnsafeMutableBufferPointer { destination in
            ring.withUnsafeBufferPointer { source in
                guard let destinationBase = destination.baseAddress,
                      let sourceBase = source.baseAddress else { return }
                destinationBase.update(from: sourceBase.advanced(by: head), count: tail)
                if head > 0 {
                    destinationBase.advanced(by: tail).update(from: sourceBase, count: head)
                }
            }
        }
    }

    private func configureIfNeeded(sampleRate: Double) {
        guard sampleRate != configuredSampleRate else { return }
        configuredSampleRate = sampleRate
        bassBins = binRange(low: 45, high: 160, sampleRate: sampleRate)
        midsBins = binRange(low: 350, high: 2_200, sampleRate: sampleRate)
        highsBins = binRange(low: 3_200, high: 12_000, sampleRate: sampleRate)
        kickBins = binRange(low: 40, high: 150, sampleRate: sampleRate)
        snareBins = binRange(low: 200, high: 2_000, sampleRate: sampleRate)
        hatBins = binRange(low: 3_000, high: 12_000, sampleRate: sampleRate)
        fluxBands = makeFluxBands(sampleRate: sampleRate)
        beatTracker.configure(frameInterval: Double(Self.hopSize) / sampleRate)
    }

    private func binRange(low: Double, high: Double, sampleRate: Double) -> BinRange {
        let maximumBin = Self.windowSize / 2 - 1
        let first = min(maximumBin, max(1, Int(ceil(low * Double(Self.windowSize) / sampleRate))))
        let last = min(maximumBin, max(first, Int(floor(high * Double(Self.windowSize) / sampleRate))))
        return BinRange(first: first, last: last)
    }

    /// Log-spaced bands for the onset function. Bands that collapse onto the
    /// same bins at the bottom of the spectrum are merged, so the lowest bins
    /// are not counted several times over.
    private func makeFluxBands(sampleRate: Double) -> [BinRange] {
        let bandCount = 24
        let lowest = 40.0
        let highest = min(16_000, sampleRate / 2 - 1)
        guard highest > lowest else { return [] }
        let ratio = pow(highest / lowest, 1 / Double(bandCount))
        var bands: [BinRange] = []
        bands.reserveCapacity(bandCount)
        var lower = lowest
        for _ in 0..<bandCount {
            let upper = lower * ratio
            let range = binRange(low: lower, high: upper, sampleRate: sampleRate)
            if let previous = bands.last, previous.first == range.first, previous.last == range.last {
                lower = upper
                continue
            }
            bands.append(range)
            lower = upper
        }
        return bands
    }

    /// Keeps the analyzer's sample clock aligned with the renderer's clock
    /// without inheriting per-callback jitter.
    private func updateHostAnchor(hostTime: TimeInterval, streamTime: TimeInterval) {
        let target = hostTime - streamTime
        if !hasHostAnchor {
            hostTimeOffset = target
            hasHostAnchor = true
        } else {
            hostTimeOffset += (target - hostTimeOffset) * 0.05
        }
    }

    private func decayCoefficient(dt: Double, timeConstant: Double) -> Double {
        1 - exp(-dt / timeConstant)
    }

    private func clamp(_ value: Double) -> Double { max(0, min(1, value)) }
}

#if os(macOS)
/// Result of attempting to start ScreenCaptureKit system-audio capture.
private enum SystemAudioStartResult {
    case started
    case needsScreenRecording   // Screen Recording not granted (macOS prompts on the first-ever ask)
    case unavailable            // OS too old / no display / capture error
}

private final class SystemAudioCapture: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private var startTask: Task<Void, Never>?
    private let onBuffer: (AVAudioPCMBuffer) -> Void

    init(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) { self.onBuffer = onBuffer }

    func start(completion: @escaping (SystemAudioStartResult) -> Void) {
        guard #available(macOS 13.0, *) else { completion(.unavailable); return }

        // Screen Recording's system sheet may offer to quit and reopen the
        // requesting app. Refresh this exact bundle before asking so Launch
        // Services does not choose a stale DerivedData/test copy that happens
        // to share LumenDesk's bundle identifier.
        _ = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)

        startTask = Task {
            do {
                // Ask ScreenCaptureKit itself whether capture is allowed instead
                // of pre-gating on CGPreflightScreenCaptureAccess(): the preflight
                // only reflects the TCC state from process launch, so it kept
                // answering "denied" after the user granted Screen Recording and
                // Music Mode never noticed the grant. SCShareableContent consults
                // the live TCC state on every call — and shows the system
                // permission prompt on the first-ever request — so each start
                // sees the user's current answer.
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard !Task.isCancelled else { return }
                guard let display = content.displays.first else {
                    await MainActor.run { completion(.unavailable) }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = true
                configuration.excludesCurrentProcessAudio = true
                configuration.sampleRate = 48_000
                configuration.channelCount = 2
                // Minimal, throttled video path (SCK requires a display filter
                // even for audio-only capture).
                configuration.width = 2
                configuration.height = 2
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                configuration.queueDepth = 3
                configuration.showsCursor = false
                let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "LumenDesk.systemAudio"))
                // A display stream always produces video frames. Register a
                // (no-op) screen output too — the delegate ignores non-audio —
                // so the frames are consumed instead of spamming "stream output
                // NOT found / Dropping frame" and churning CPU on the capture
                // pipeline and the log flood.
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "LumenDesk.systemVideo"))
                try await stream.startCapture()
                guard !Task.isCancelled else {
                    try? await stream.stopCapture()
                    return
                }
                self.stream = stream
                self.startTask = nil
                await MainActor.run { completion(.started) }
            } catch {
                guard !Task.isCancelled else { return }
                self.startTask = nil
                // ScreenCaptureKit surfaces a missing Screen Recording grant as
                // .userDeclined; anything else is a genuine capture failure.
                let denied = (error as? SCStreamError)?.code == .userDeclined
                await MainActor.run { completion(denied ? .needsScreenRecording : .unavailable) }
            }
        }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        guard let stream else { return }
        Task { try? await stream.stopCapture() }
        self.stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let buffer = try? sampleBuffer.asMonoPCMBuffer() else { return }
        onBuffer(buffer)
    }
}

private extension CMSampleBuffer {
    /// Copies ScreenCaptureKit's Float32 audio into an OWNED mono buffer by
    /// averaging all channels. Owning the memory makes it safe to hand to the
    /// analysis queue (the no-copy bufferList is only valid during this call),
    /// and iterating every AudioBuffer/channel is the fix for the old code that
    /// read only `mBuffers[0]` and dropped the right channel. Divides by the
    /// number of channels actually summed so loudness is consistent.
    func asMonoPCMBuffer() throws -> AVAudioPCMBuffer? {
        guard let asbd = formatDescription?.audioStreamBasicDescription else { return nil }
        let frames = AVAudioFrameCount(numSamples)
        guard frames > 0,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: asbd.mSampleRate,
                                             channels: 1,
                                             interleaved: false) else { return nil }
        let n = Int(frames)
        return try withAudioBufferList { abl, _ -> AVAudioPCMBuffer? in
            guard let out = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frames),
                  let dst = out.floatChannelData?[0] else { return nil }
            out.frameLength = frames
            var summedChannels = 0
            // Planar audio: one AudioBuffer per channel (mNumberChannels == 1).
            // Interleaved: one buffer with mNumberChannels samples per frame.
            // Handle both so the right channel is never lost.
            for ab in abl {
                guard let mData = ab.mData else { continue }
                let src = mData.assumingMemoryBound(to: Float.self)
                let ch = Int(ab.mNumberChannels)
                let totalFloats = Int(ab.mDataByteSize) / MemoryLayout<Float>.size
                if ch <= 1 {
                    let count = min(n, totalFloats)
                    for i in 0..<count { dst[i] += src[i] }
                    summedChannels += 1
                } else {
                    let count = min(n, totalFloats / ch)
                    for i in 0..<count {
                        var acc: Float = 0
                        for c in 0..<ch { acc += src[i * ch + c] }
                        dst[i] += acc
                    }
                    summedChannels += ch
                }
            }
            guard summedChannels > 0 else { return nil }
            var divisor = Float(summedChannels)
            vDSP_vsdiv(dst, 1, &divisor, dst, 1, vDSP_Length(n))
            return out
        }
    }
}
#endif
