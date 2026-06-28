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

    func requestAccessAndStart(completion: @escaping (Bool) -> Void) {
        analyzer = MusicFeatureAnalyzer(sourceDescription: preferredSourceDescription)
        #if os(macOS)
        systemAudioCapture = SystemAudioCapture { [weak self] buffer in
            self?.consume(buffer)
        }
        systemAudioCapture?.start { [weak self] started in
            guard let self else { return }
            self.analyzer.sourceDescription = started ? "Apple Music / system audio with microphone calibration" : "Microphone calibration"
            self.startMicrophone(completion: completion)
        }
        #else
        startMicrophone(completion: completion)
        #endif
    }

    private var preferredSourceDescription: String {
        #if os(macOS)
        "Apple Music / system audio with microphone calibration"
        #else
        "Microphone calibration"
        #endif
    }

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
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, options: [.mixWithOthers, .defaultToSpeaker])
        try? session.setActive(true)
        #endif
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
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
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

    init(sourceDescription: String) { self.sourceDescription = sourceDescription }

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
        var real = [Float](repeating: 0, count: n)
        var imag = [Float](repeating: 0, count: n)
        for k in 0..<n {
            let frequency = Double(k) * sampleRate / Double(n)
            guard frequency >= low && frequency <= high else { continue }
            var r: Float = 0, i: Float = 0
            for t in stride(from: 0, to: n, by: 4) {
                let angle = -2 * Double.pi * Double(k * t) / Double(n)
                r += samples[t] * Float(cos(angle))
                i += samples[t] * Float(sin(angle))
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
private final class SystemAudioCapture: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private let onBuffer: (AVAudioPCMBuffer) -> Void

    init(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) { self.onBuffer = onBuffer }

    func start(completion: @escaping (Bool) -> Void) {
        guard #available(macOS 13.0, *) else { completion(false); return }
        // System-audio capture goes through ScreenCaptureKit, which requires the
        // Screen Recording permission. We never prompt for it: Soundcheck works
        // fully on the microphone, and the ScreenCaptureKit permission flow is
        // what nagged users repeatedly (the grant also doesn't persist for an
        // unsigned/ad-hoc build). Only use system audio when the user has
        // ALREADY granted Screen Recording, detected here without prompting.
        guard CGPreflightScreenCaptureAccess() else { completion(false); return }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else { await MainActor.run { completion(false) }; return }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = true
                configuration.excludesCurrentProcessAudio = true
                configuration.width = 2
                configuration.height = 2
                let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "LumenDesk.systemAudio"))
                try await stream.startCapture()
                self.stream = stream
                await MainActor.run { completion(true) }
            } catch {
                await MainActor.run { completion(false) }
            }
        }
    }

    func stop() {
        guard let stream else { return }
        Task { try? await stream.stopCapture() }
        self.stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let buffer = try? sampleBuffer.asPCMBuffer() else { return }
        onBuffer(buffer)
    }
}

private extension CMSampleBuffer {
    func asPCMBuffer() throws -> AVAudioPCMBuffer? {
        guard let formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        return try withAudioBufferList { audioBufferList, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples)) else { return nil }
            buffer.frameLength = buffer.frameCapacity
            let source = audioBufferList.unsafePointer.pointee.mBuffers
            guard let sourceData = source.mData, let destinationData = buffer.floatChannelData?[0] else { return nil }
            let sourcePointer = sourceData.assumingMemoryBound(to: Float.self)
            destinationData.update(from: sourcePointer, count: Int(buffer.frameLength))
            return buffer
        }
    }
}
#endif
