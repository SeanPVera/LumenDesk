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
    private var previousEnergy: Double = 0
    private var beatCooldown = 0

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
        noiseFloor = noiseFloor * 0.995 + min(rms, noiseFloor + 0.002) * 0.005
        let level = clamp((rms - noiseFloor) * 9)

        let sampleRate = buffer.format.sampleRate
        let bass = bandEnergy(samples: mono, sampleRate: sampleRate, low: 45, high: 160)
        let mids = bandEnergy(samples: mono, sampleRate: sampleRate, low: 350, high: 2200)
        let highs = bandEnergy(samples: mono, sampleRate: sampleRate, low: 3200, high: 12000)
        let kick = clamp((bass - previousBass * 0.78) * 7)
        let percussion = clamp((highs - previousHighs * 0.74) * 8)
        let snare = clamp((mids * 0.55 + highs * 0.45 - previousEnergy * 0.35) * 3.5)
        let energy = clamp(level * 0.45 + bass * 0.28 + mids * 0.14 + highs * 0.13)
        let novelty = max(kick, percussion * 0.85, snare * 0.7)
        let beat: Double
        if novelty > 0.33 && beatCooldown == 0 {
            beat = novelty
            beatCooldown = 2
        } else {
            beat = 0
            beatCooldown = max(0, beatCooldown - 1)
        }
        let mood = clamp(0.48 + highs * 0.26 + mids * 0.08 - bass * 0.16)

        previousBass = bass
        previousHighs = highs
        previousEnergy = energy
        return AudioReactiveSnapshot(level: level, beat: beat, kick: kick, snare: snare, percussion: percussion, bass: bass, mids: mids, highs: highs, energy: energy, mood: mood, confidence: min(1, level * 1.8), sourceDescription: sourceDescription)
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
