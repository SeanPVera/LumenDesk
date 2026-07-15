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
    // "heartbeat" the light show pulses brightness to.
    var pulse: Double = 0
    // 0…1 strength of a sustained high-intensity section. Choreography treats
    // this as evidence, not as a guaranteed musical "drop."
    var drop: Double = 0
    // Monotonic count of detected beats. The renderer steps colors by the
    // delta so no beat is dropped even when frames are throttled.
    var beatCount: Int = 0
    var sourceDescription: String = "Microphone input"
}

final class AudioCaptureService {
    struct SubscriptionToken: Hashable {
        fileprivate let id: UUID
    }

    private let engine = AVAudioEngine()
    private var analyzer = MusicFeatureAnalyzer(sourceDescription: "Microphone input")
    // Mic taps deliver on the AVAudioEngine render thread while system-audio
    // taps deliver on their own capture queue; serialize both onto this queue
    // before touching the analyzer's mutable state.
    private let analysisQueue = DispatchQueue(label: "LumenDesk.audioAnalysis")
    // Audio callbacks can arrive faster than spectral analysis during a CPU
    // spike. A single-slot pipeline drops superseded buffers instead of
    // retaining an unbounded queue of stale audio. Twenty analyses per second
    // is enough to catch onsets while leaving substantially more CPU headroom
    // for the UI and network transports.
    private let analysisSlot = DispatchSemaphore(value: 1)
    private var nextAnalysisUptime: UInt64 = 0
    private let analysisIntervalNanoseconds: UInt64 = 50_000_000
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
        analyzer = MusicFeatureAnalyzer(sourceDescription: preferredSourceDescription)
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
                self.analyzer.sourceDescription = "System audio"
                startResult = .started
            case .needsScreenRecording:
                self.analyzer.sourceDescription = "System audio unavailable — Screen Recording off"
                self.systemAudioCapture = nil
                startResult = .needsScreenRecording
            case .unavailable:
                self.analyzer.sourceDescription = "System audio unavailable"
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
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= nextAnalysisUptime else {
            analysisSlot.signal()
            return
        }
        nextAnalysisUptime = now &+ analysisIntervalNanoseconds
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
            guard let snapshot = self.analyzer.analyze(analysisBuffer) else { return }
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
    /// Copying the accepted (already throttled) buffer makes the asynchronous
    /// analyzer safe without retaining every callback under load.
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

final class MusicFeatureAnalyzer {
    var sourceDescription: String
    private var noiseFloor: Double = 0.01
    private var previousBass: Double = 0
    private var previousHighs: Double = 0
    private var previousMids: Double = 0
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
    // One Accelerate real FFT replaces three nested per-bin/per-sample DFTs.
    // The setup and scratch buffers are reused on the serial analysis queue.
    private var fftSetup: FFTSetup?
    private var fftSize = 0
    private var fftLog2Size: vDSP_Length = 0
    private var fftReal: [Float] = []
    private var fftImaginary: [Float] = []
    private var fftMagnitudes: [Float] = []
    private var monoSamples: [Float] = []

    init(sourceDescription: String) { self.sourceDescription = sourceDescription }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    func analyze(_ buffer: AVAudioPCMBuffer) -> AudioReactiveSnapshot? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }
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
        let divisor = Float(max(1, channels))
        var divisorValue = divisor
        vDSP_vsdiv(monoSamples, 1, &divisorValue, &monoSamples, 1, vDSP_Length(frameCount))

        var meanSquare: Float = 0
        vDSP_measqv(monoSamples, 1, &meanSquare, vDSP_Length(frameCount))
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
        // Compute the spectrum once, then reduce three bin ranges. The former
        // implementation repeated a direct DFT for every bin in every band,
        // doing tens of thousands of scalar multiply/adds per audio buffer.
        // A 1024-point radix-2 FFT gives bass the resolution it needs and is
        // also cheaper than any one of those direct band calculations.
        guard let spectrumSize = updateSpectrum(from: monoSamples) else { return nil }
        let bassRaw = bandEnergy(sampleRate: sampleRate, low: 45, high: 160, spectrumSize: spectrumSize)
        let midsRaw = bandEnergy(sampleRate: sampleRate, low: 350, high: 2200, spectrumSize: spectrumSize)
        let highsRaw = bandEnergy(sampleRate: sampleRate, low: 3200, high: 12000, spectrumSize: spectrumSize)
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

        // Legacy compatibility signal: sustained energy above the running baseline.
        // Music Mode treats this as evidence, not as guaranteed section/drop detection.
        energyBaseline = energyBaseline * 0.985 + energy * 0.015
        let intensity = clamp((energy - 0.5) * 2.4) * clamp((energy - energyBaseline) * 4 + 0.3)
        dropEnv = max(dropEnv * exp(-dt / 0.3), intensity)
        let drop = clamp(dropEnv)

        // Mood: treble-leaning reads bright/airy (→1), bass-leaning dark/heavy (→0).
        let mood = clamp(0.5 + (highs - bass) * 0.6 + mids * 0.05)

        previousBass = bass
        previousMids = mids
        previousHighs = highs
        return AudioReactiveSnapshot(level: level, beat: beat, kick: kick, snare: snare, percussion: percussion, bass: bass, mids: mids, highs: highs, energy: energy, mood: mood, confidence: clamp(level * 1.8), pulse: pulse, drop: drop, beatCount: beatCount, sourceDescription: sourceDescription)
    }

    /// Updates a normalized half-spectrum and returns the FFT size. The input
    /// is capped at 1024 samples and rounded down to a power of two so the
    /// radix-2 setup remains fast even if a capture source changes buffer size.
    private func updateSpectrum(from samples: [Float]) -> Int? {
        let cappedSize = min(1_024, samples.count)
        guard cappedSize >= 16 else { return nil }
        let log2Size = vDSP_Length(floor(log2(Double(cappedSize))))
        let size = 1 << Int(log2Size)

        if size != fftSize {
            if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
            guard let newSetup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2)) else {
                fftSetup = nil
                fftSize = 0
                return nil
            }
            fftSetup = newSetup
            fftSize = size
            fftLog2Size = log2Size
            fftReal = [Float](repeating: 0, count: size / 2)
            fftImaginary = [Float](repeating: 0, count: size / 2)
            fftMagnitudes = [Float](repeating: 0, count: size / 2)
        }

        guard let fftSetup else { return nil }
        for index in 0..<(size / 2) {
            fftReal[index] = samples[index * 2]
            fftImaginary[index] = samples[index * 2 + 1]
        }
        fftReal.withUnsafeMutableBufferPointer { real in
            fftImaginary.withUnsafeMutableBufferPointer { imaginary in
                guard let realBase = real.baseAddress, let imaginaryBase = imaginary.baseAddress else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imaginaryBase)
                vDSP_fft_zrip(fftSetup, &split, 1, fftLog2Size, FFTDirection(FFT_FORWARD))
                fftMagnitudes.withUnsafeMutableBufferPointer { magnitudes in
                    guard let magnitudeBase = magnitudes.baseAddress else { return }
                    vDSP_zvabs(&split, 1, magnitudeBase, 1, vDSP_Length(size / 2))
                }
            }
        }
        var scale = 1 / Float(size)
        vDSP_vsmul(fftMagnitudes, 1, &scale, &fftMagnitudes, 1, vDSP_Length(size / 2))
        return size
    }

    /// Mean normalized magnitude inside one frequency band. Only the band's
    /// bins participate so narrow bass energy is not diluted by the spectrum.
    private func bandEnergy(sampleRate: Double, low: Double, high: Double, spectrumSize: Int) -> Double {
        let firstBin = max(1, Int(ceil(low * Double(spectrumSize) / sampleRate)))
        let lastBin = min(fftMagnitudes.count - 1, Int(floor(high * Double(spectrumSize) / sampleRate)))
        guard firstBin <= lastBin else { return 0 }
        var mean: Float = 0
        fftMagnitudes.withUnsafeBufferPointer { magnitudes in
            guard let base = magnitudes.baseAddress else { return }
            vDSP_meanv(
                base.advanced(by: firstBin), 1,
                &mean,
                vDSP_Length(lastBin - firstBin + 1)
            )
        }
        return Double(mean)
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
