import AVFoundation
import Accelerate
#if os(macOS)
import ScreenCaptureKit
#endif

struct AudioReactiveSnapshot {
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
    // "heartbeat" the light show pulses brightness to.
    var pulse: Double = 0
    // 0…1 strength of a sustained high-intensity section (a drop/chorus); the
    // show strobes while this is high.
    var drop: Double = 0
    // Monotonic count of detected beats. The renderer steps colors by the
    // delta so no beat is dropped even when frames are throttled.
    var beatCount: Int = 0
    var sourceDescription: String = "Microphone calibration"
}

final class AudioLevelMonitor {
    private let engine = AVAudioEngine()
    private var analyzer = MusicFeatureAnalyzer(sourceDescription: "Microphone calibration")
    // Mic taps deliver on the AVAudioEngine render thread while system-audio
    // taps deliver on their own capture queue; serialize both onto this queue
    // before touching the analyzer's mutable state.
    private let analysisQueue = DispatchQueue(label: "LumenDesk.audioAnalysis")
    var onLevel: ((Double) -> Void)?
    var onSnapshot: ((AudioReactiveSnapshot) -> Void)?

    #if os(macOS)
    private var systemAudioCapture: SystemAudioCapture?
    #endif

    /// Outcome of starting the analysis source, so the caller can show the
    /// precise message. On macOS the source is system audio (ScreenCaptureKit);
    /// on iOS it is the microphone.
    enum AudioStartResult {
        /// Capture is running and feeding the analyzer.
        case started
        /// macOS only: Screen Recording is not granted. macOS shows its prompt
        /// on the first-ever attempt; after granting, starting Soundcheck again
        /// picks the grant up — permission is re-checked live on every start.
        /// Never falls back to the microphone.
        case needsScreenRecording
        /// Source could not start for a non-permission reason (mic denied on iOS,
        /// no display, OS too old, or a capture error).
        case unavailable
    }

    func requestAccessAndStart(completion: @escaping (AudioStartResult) -> Void) {
        analyzer = MusicFeatureAnalyzer(sourceDescription: preferredSourceDescription)
        #if os(macOS)
        // macOS: system audio (Apple Music / other apps) is the SOLE source.
        // The microphone is never started here, so room noise can't pollute the
        // music analysis, and there is no silent mic fallback.
        let capture = SystemAudioCapture { [weak self] buffer in
            self?.consume(buffer)
        }
        systemAudioCapture = capture
        capture.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .started:
                self.analyzer.sourceDescription = "Apple Music / system audio"
                completion(.started)
            case .needsScreenRecording:
                self.analyzer.sourceDescription = "System audio unavailable — Screen Recording off"
                self.systemAudioCapture = nil
                completion(.needsScreenRecording)
            case .unavailable:
                self.analyzer.sourceDescription = "System audio unavailable"
                self.systemAudioCapture = nil
                completion(.unavailable)
            }
        }
        #else
        // iOS: microphone is the only available source (no ScreenCaptureKit).
        startMicrophone { started in completion(started ? .started : .unavailable) }
        #endif
    }

    private var preferredSourceDescription: String {
        #if os(macOS)
        "Apple Music / system audio"
        #else
        "Microphone calibration"
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

    private func consume(_ buffer: AVAudioPCMBuffer) {
        analysisQueue.async { [weak self] in
            guard let self, let snapshot = self.analyzer.analyze(buffer) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onLevel?(snapshot.level)
                self?.onSnapshot?(snapshot)
            }
        }
    }

    func stop() {
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

private final class MusicFeatureAnalyzer {
    var sourceDescription: String
    private var noiseFloor: Double = 0.01
    private var previousBass: Double = 0
    private var previousHighs: Double = 0
    private var previousMids: Double = 0
    private var previousEnergy: Double = 0
    // Refractory period, in seconds, before another beat can be counted.
    // Measured in time (via `dt`) rather than a fixed number of analyze()
    // calls: the OS's audio buffer size (and therefore how often analyze()
    // runs) isn't under this code's control, and a buffer-count cooldown let
    // one drum transient's multi-frame decay re-cross the onset threshold
    // and get counted as several beats — the show would then cut colors and
    // flash several times per real hit instead of once, reading as
    // indiscriminately fast rather than on the beat.
    private var beatCooldownRemaining: Double = 0
    // Slowly-decaying peak for automatic gain: keeps the show looking the same
    // whether the music is quiet or cranked.
    private var peakLevel: Double = 0.02
    // Slowly-decaying peak of the loudest frequency band; bass/mids/highs are
    // normalized against it (spectral AGC) so the beat/onset detectors see the
    // same 0…1 dynamics at any source volume.
    private var spectralPeak: Double = 0.05
    // Adaptive onset threshold and persistent show envelopes / counters.
    private var noveltyBaseline: Double = 0
    private var energyBaseline: Double = 0
    private var pulseEnv: Double = 0
    private var dropEnv: Double = 0
    private var beatCount: Int = 0
    // Cached DFT twiddle factors (cos/sin) per analysis window size, built once
    // and reused. Lets bandEnergy index a table instead of calling cos/sin per
    // sample — identical result, far less CPU. Touched only on the analysis
    // queue, so no synchronization is needed.
    private var twiddleTables: [Int: (cos: [Float], sin: [Float])] = [:]

    init(sourceDescription: String) { self.sourceDescription = sourceDescription }

    private func twiddles(for n: Int) -> (cos: [Float], sin: [Float]) {
        if let cached = twiddleTables[n] { return cached }
        let tables: (cos: [Float], sin: [Float]) = (
            (0..<n).map { Float(cos(-2 * Double.pi * Double($0) / Double(n))) },
            (0..<n).map { Float(sin(-2 * Double.pi * Double($0) / Double(n))) }
        )
        twiddleTables[n] = tables
        return tables
    }

    func analyze(_ buffer: AVAudioPCMBuffer) -> AudioReactiveSnapshot? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }
        let channels = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: frameCount)
        for channel in 0..<channels {
            for index in 0..<frameCount { mono[index] += channelData[channel][index] }
        }
        let divisor = Float(max(1, channels))
        for index in 0..<frameCount { mono[index] /= divisor }

        var meanSquare: Float = 0
        vDSP_measqv(mono, 1, &meanSquare, vDSP_Length(frameCount))
        let rms = Double(sqrt(meanSquare))
        let sampleRate = buffer.format.sampleRate
        let dt = Double(frameCount) / max(1, sampleRate)

        // Track the quiet floor and a slowly-decaying loud peak, then normalize
        // between them so loudness reads 0…1 regardless of system volume (AGC).
        noiseFloor = noiseFloor * 0.995 + min(rms, noiseFloor + 0.002) * 0.005
        peakLevel = max(peakLevel * 0.9992, rms)
        let level = clamp((rms - noiseFloor) / max(0.015, peakLevel - noiseFloor))

        // Auto-gain the bands the same way `level` is auto-gained: normalize
        // against a slowly decaying peak of the loudest band so kicks, snares,
        // and hats swing across 0…1 whether the source is quiet background
        // music or a cranked mix. Rising instantly and decaying slowly keeps
        // the scale steady within a song.
        //
        // Each band uses its own analysis window rather than a shared 1024
        // samples: bass is only ~3 bins wide even at full resolution (its
        // 45-160Hz range is narrow in absolute Hz), so it needs the long
        // window to have any bins at all. Mids and highs span far more Hz, so
        // a shorter window (fewer bins, and far fewer samples summed per bin)
        // still leaves them plenty of bins — at roughly a tenth of the CPU
        // cost of running all three bands at 1024. This shortens frequency
        // resolution, not the per-sample rate, so it does not reintroduce the
        // decimation aliasing bandEnergy's doc comment warns about.
        let bassRaw = bandEnergy(samples: mono, sampleRate: sampleRate, low: 45, high: 160, window: 1024)
        let midsRaw = bandEnergy(samples: mono, sampleRate: sampleRate, low: 350, high: 2200, window: 512)
        let highsRaw = bandEnergy(samples: mono, sampleRate: sampleRate, low: 3200, high: 12000, window: 256)
        spectralPeak = max(spectralPeak * 0.9992, bassRaw, midsRaw, highsRaw)
        let bandScale = 0.9 / max(0.001, spectralPeak)
        let bass = clamp(bassRaw * bandScale)
        let mids = clamp(midsRaw * bandScale)
        let highs = clamp(highsRaw * bandScale)
        // Onsets are rectified jumps in each band (spectral flux), so they fire
        // on transients — the actual hits — rather than on sustained tones.
        let kick = clamp((bass - previousBass) * 6)
        let snare = clamp((mids - previousMids) * 5 + (highs - previousHighs) * 3)
        let percussion = clamp((highs - previousHighs) * 7)
        let energy = clamp(level * 0.4 + bass * 0.3 + mids * 0.16 + highs * 0.14)

        // Beat = a novelty spike above an adaptive threshold, rate-limited by a
        // short refractory window so a single hit isn't counted repeatedly.
        // 120ms allows over 8 individual hits/sec (fast even for a 16th-note
        // hi-hat run) while comfortably outlasting one transient's decay, so
        // the same kick or snare can't cross the threshold twice on its way
        // down.
        let novelty = max(kick, snare * 0.85, percussion * 0.7)
        noveltyBaseline = noveltyBaseline * 0.95 + novelty * 0.05
        let isBeat = novelty > max(0.12, noveltyBaseline * 1.4) && beatCooldownRemaining <= 0
        let beat: Double
        if isBeat {
            beat = novelty
            beatCooldownRemaining = 0.12
            beatCount += 1
        } else {
            beat = 0
            beatCooldownRemaining = max(0, beatCooldownRemaining - dt)
        }

        // Pulse: snap up on any onset (and guarantee a strong flash on a counted
        // beat), then decay smoothly so each hit reads as a discrete pulse.
        let onset = max(novelty, beat)
        pulseEnv = max(pulseEnv * exp(-dt / 0.16), onset)
        if isBeat { pulseEnv = max(pulseEnv, 0.85) }
        let pulse = clamp(pulseEnv)

        // Drop: sustained high energy above the running baseline → strobe fuel.
        energyBaseline = energyBaseline * 0.985 + energy * 0.015
        let intensity = clamp((energy - 0.5) * 2.4) * clamp((energy - energyBaseline) * 4 + 0.3)
        dropEnv = max(dropEnv * exp(-dt / 0.3), intensity)
        let drop = clamp(dropEnv)

        // Mood: treble-leaning reads bright/airy (→1), bass-leaning dark/heavy (→0).
        let mood = clamp(0.5 + (highs - bass) * 0.6 + mids * 0.05)

        previousBass = bass
        previousMids = mids
        previousHighs = highs
        previousEnergy = energy
        return AudioReactiveSnapshot(level: level, beat: beat, kick: kick, snare: snare, percussion: percussion, bass: bass, mids: mids, highs: highs, energy: energy, mood: mood, confidence: clamp(level * 1.8), pulse: pulse, drop: drop, beatCount: beatCount, sourceDescription: sourceDescription)
    }

    /// Mean DFT-bin magnitude inside [low, high] Hz, normalized per bin
    /// (|X|/n, so a full-scale sine centered on a bin reads ~0.5) and averaged
    /// over ONLY the band's own bins — averaging across the whole spectrum
    /// dilutes a narrow band like bass (~3 bins of 1024) to ~1e-3, which
    /// starves every downstream onset detector and leaves the show reacting
    /// to nothing but loudness. Every sample feeds the sum: decimating the
    /// input aliases the highs band and shrinks magnitudes further. Returns
    /// the raw mean; `analyze` applies the spectral AGC.
    ///
    /// `window` caps the number of samples the DFT covers, independent of the
    /// sample rate — it trades frequency resolution for CPU, not aliasing
    /// safety (every sample within the window is still used). Bands that
    /// span many Hz keep plenty of bins even at a short window, so `analyze`
    /// passes a much smaller window for mids/highs than for bass, which
    /// needs its full resolution just to have any bins at all.
    private func bandEnergy(samples: [Float], sampleRate: Double, low: Double, high: Double, window: Int) -> Double {
        let n = min(samples.count, window)
        guard n > 8 else { return 0 }
        let (cosTable, sinTable) = twiddles(for: n)
        var sum: Float = 0
        var bins = 0
        for k in 0..<n {
            let frequency = Double(k) * sampleRate / Double(n)
            guard frequency >= low && frequency <= high else { continue }
            var r: Float = 0, i: Float = 0
            // idx walks (k·t) mod n without a modulo: it advances by k < n
            // each sample, so a single subtraction wraps it.
            var idx = 0
            for t in 0..<n {
                r += samples[t] * cosTable[idx]
                i += samples[t] * sinTable[idx]
                idx += k
                if idx >= n { idx -= n }
            }
            sum += sqrt(r * r + i * i) / Float(n)
            bins += 1
        }
        guard bins > 0 else { return 0 }
        return Double(sum) / Double(bins)
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
    private let onBuffer: (AVAudioPCMBuffer) -> Void

    init(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) { self.onBuffer = onBuffer }

    func start(completion: @escaping (SystemAudioStartResult) -> Void) {
        guard #available(macOS 13.0, *) else { completion(.unavailable); return }

        Task {
            do {
                // Ask ScreenCaptureKit itself whether capture is allowed instead
                // of pre-gating on CGPreflightScreenCaptureAccess(): the preflight
                // only reflects the TCC state from process launch, so it kept
                // answering "denied" after the user granted Screen Recording and
                // Soundcheck never noticed the grant. SCShareableContent consults
                // the live TCC state on every call — and shows the system
                // permission prompt on the first-ever request — so each start
                // sees the user's current answer.
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
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
                configuration.queueDepth = 5
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
                self.stream = stream
                await MainActor.run { completion(.started) }
            } catch {
                // ScreenCaptureKit surfaces a missing Screen Recording grant as
                // .userDeclined; anything else is a genuine capture failure.
                let denied = (error as? SCStreamError)?.code == .userDeclined
                await MainActor.run { completion(denied ? .needsScreenRecording : .unavailable) }
            }
        }
    }

    func stop() {
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
