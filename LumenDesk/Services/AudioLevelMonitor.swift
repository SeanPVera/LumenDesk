import AVFoundation
import Accelerate
#if os(macOS)
import CoreGraphics
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
        /// macOS only: Screen Recording is not granted. We requested it once this
        /// launch (if it hadn't been asked before); the user must grant it in
        /// System Settings and relaunch. Never falls back to the microphone.
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
    private var beatCooldown = 0
    // Slowly-decaying peak for automatic gain: keeps the show looking the same
    // whether the music is quiet or cranked.
    private var peakLevel: Double = 0.02
    // Adaptive onset threshold and persistent show envelopes / counters.
    private var noveltyBaseline: Double = 0
    private var energyBaseline: Double = 0
    private var pulseEnv: Double = 0
    private var dropEnv: Double = 0
    private var beatCount: Int = 0
    // Cached DFT twiddle factors (cos/sin), rebuilt only when the window size
    // changes. Lets bandEnergy index a table instead of calling cos/sin per
    // sample — identical result, far less CPU. Touched only on the analysis
    // queue, so no synchronization is needed.
    private var twiddleN = 0
    private var twiddleCos: [Float] = []
    private var twiddleSin: [Float] = []

    init(sourceDescription: String) { self.sourceDescription = sourceDescription }

    private func ensureTwiddles(_ n: Int) {
        guard n != twiddleN else { return }
        twiddleN = n
        twiddleCos = (0..<n).map { Float(cos(-2 * Double.pi * Double($0) / Double(n))) }
        twiddleSin = (0..<n).map { Float(sin(-2 * Double.pi * Double($0) / Double(n))) }
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

        let bass = bandEnergy(samples: mono, sampleRate: sampleRate, low: 45, high: 160)
        let mids = bandEnergy(samples: mono, sampleRate: sampleRate, low: 350, high: 2200)
        let highs = bandEnergy(samples: mono, sampleRate: sampleRate, low: 3200, high: 12000)
        // Onsets are rectified jumps in each band (spectral flux), so they fire
        // on transients — the actual hits — rather than on sustained tones.
        let kick = clamp((bass - previousBass) * 6)
        let snare = clamp((mids - previousMids) * 5 + (highs - previousHighs) * 3)
        let percussion = clamp((highs - previousHighs) * 7)
        let energy = clamp(level * 0.4 + bass * 0.3 + mids * 0.16 + highs * 0.14)

        // Beat = a novelty spike above an adaptive threshold, rate-limited by a
        // short refractory window so a single hit isn't counted repeatedly.
        let novelty = max(kick, snare * 0.85, percussion * 0.7)
        noveltyBaseline = noveltyBaseline * 0.95 + novelty * 0.05
        let isBeat = novelty > max(0.12, noveltyBaseline * 1.4) && beatCooldown == 0
        let beat: Double
        if isBeat {
            beat = novelty
            beatCooldown = 2
            beatCount += 1
        } else {
            beat = 0
            beatCooldown = max(0, beatCooldown - 1)
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

    private func bandEnergy(samples: [Float], sampleRate: Double, low: Double, high: Double) -> Double {
        let n = min(samples.count, 1024)
        guard n > 8 else { return 0 }
        ensureTwiddles(n)
        var real = [Float](repeating: 0, count: n)
        var imag = [Float](repeating: 0, count: n)
        for k in 0..<n {
            let frequency = Double(k) * sampleRate / Double(n)
            guard frequency >= low && frequency <= high else { continue }
            var r: Float = 0, i: Float = 0
            for t in stride(from: 0, to: n, by: 4) {
                // cos(-2π·k·t/n) == twiddleCos[(k·t) mod n]; same value, no trig.
                let idx = (k * t) % n
                r += samples[t] * twiddleCos[idx]
                i += samples[t] * twiddleSin[idx]
            }
            real[k] = r; imag[k] = i
        }
        var mags = zip(real, imag).map { sqrt($0 * $0 + $1 * $1) / Float(n) }
        var mean: Float = 0
        vDSP_meanv(&mags, 1, &mean, vDSP_Length(mags.count))
        return clamp(Double(mean) * 18)
    }

    private func clamp(_ value: Double) -> Double { max(0, min(1, value)) }
}

#if os(macOS)
/// Result of attempting to start ScreenCaptureKit system-audio capture.
private enum SystemAudioStartResult {
    case started
    case needsScreenRecording   // not granted; we requested once this launch
    case unavailable            // OS too old / no display / capture error
}

/// Screen Recording (TCC) permission, scoped to ScreenCaptureKit.
///
/// macOS only applies a fresh grant to a *freshly launched* app, so the model
/// is: preflight → if granted, capture; if not, request once and ask the user
/// to grant + relaunch. We request at most once per launch (the in-memory flag)
/// so we never nag repeatedly within a session.
private enum ScreenRecordingPermission {
    /// True if THIS process currently holds Screen Recording (valid for SCStream).
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    private static var didRequestThisLaunch = false

    /// Shows the system prompt at most once per launch when ungranted. The grant
    /// does not take effect for ScreenCaptureKit until the app relaunches, so the
    /// caller must not start the stream on the strength of this call.
    static func requestOnceThisLaunch() {
        guard !didRequestThisLaunch else { return }
        didRequestThisLaunch = true
        // Triggers the OS prompt if (and only if) not already granted.
        _ = CGRequestScreenCaptureAccess()
    }
}

private final class SystemAudioCapture: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private let onBuffer: (AVAudioPCMBuffer) -> Void

    init(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) { self.onBuffer = onBuffer }

    func start(completion: @escaping (SystemAudioStartResult) -> Void) {
        guard #available(macOS 13.0, *) else { completion(.unavailable); return }

        // System-audio capture goes through ScreenCaptureKit, gated by the
        // Screen Recording permission. If we already hold it, capture now.
        guard ScreenRecordingPermission.isGranted else {
            // Not granted: ask once this launch, then tell the caller to surface
            // the grant + relaunch instructions. We never start the microphone
            // as a fallback — system audio is the required source on macOS.
            ScreenRecordingPermission.requestOnceThisLaunch()
            completion(.needsScreenRecording)
            return
        }

        Task {
            do {
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
                // A throw while still ungranted means the permission isn't live
                // for this process yet (needs relaunch); otherwise a real error.
                let result: SystemAudioStartResult = ScreenRecordingPermission.isGranted ? .unavailable : .needsScreenRecording
                await MainActor.run { completion(result) }
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
