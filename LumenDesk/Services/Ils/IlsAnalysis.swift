import Foundation

/// The analysis timeline served by the iLightShow API, decoded from its
/// protobuf payload.
///
/// Schema and field numbers were read from the generated protobuf classes
/// in the 4.0.0-beta APK (root: `defpackage/c.java`, item:
/// `defpackage/b.java`). Frame rates come from the playback engine: the app
/// divides `frameInTrack` by 100 (`C0666n0.java:964`), so every item is a
/// 100 Hz frame of the track.
struct IlsAnalysis {
    var duration: TimeInterval = 0
    var title = ""
    var artist = ""
    var isrc = ""
    /// Raw Shazam fingerprint bytes (field 5).
    var shazamFingerprint: [UInt8] = []
    var chromaprint = ""
    /// Per-frame timeline, ordered by frame.
    var items: [IlsItem] = []
    var tempo = 0.0

    /// Upper bound on a frame index when allocating per-frame buffers:
    /// one hour at 100 Hz. A corrupt or adversarial `frameInTrack` can be
    /// any 64-bit value, so the envelope is never sized past this.
    static let maxFrames = 360_000

    /// The 100 Hz frame this item describes.
    struct IlsItem {
        var frameInTrack = 0
        var frameInPortion = 0
        var drum = false
        var buildup = false
        var strobe = false
        var beat = false
        var downbeat = false
        var section = false
        var singleLightUse = false
        /// Intensity (0…~100) the app uses to scale effects.
        var drumAct = 0
        var buildupAct = 0
        var strobeAct = 0
        var beatAct = 0
        var downbeatAct = 0
        var sectionAct = 0
        var aggressiveAct = 0
        var partyAct = 0
        var timeBeforeNextDrum = 0.0
        var timeBeforeNextBeat = 0.0

        /// Seconds into the track (the app's playback engine divides the
        /// frame by 100).
        var time: TimeInterval { TimeInterval(frameInTrack) / 100.0 }
    }
}

/// A minimal forward-only protobuf wire-format reader, sized for the
/// iLightShow analysis schema (varints, 64-bit fixed, length-delimited
/// strings/bytes/messages; no groups, no packed repeated fields).
struct IlsProtobufReader {
    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isExhausted: Bool { index >= bytes.count }

    /// Reads the next field tag, or nil at the end of the message.
    mutating func nextField() -> (field: Int, wireType: Int)? {
        guard let raw = readVarint() else { return nil }
        return (Int(raw >> 3), Int(raw & 0x7))
    }

    mutating func readVarint() -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while shift < 64 {
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    mutating func readFixed64() -> UInt64? {
        guard index + 8 <= bytes.count else { return nil }
        var value: UInt64 = 0
        for offset in 0..<8 {
            value |= UInt64(bytes[index + offset]) << (8 * offset)
        }
        index += 8
        return value
    }

    mutating func readBytes(count: Int) -> [UInt8]? {
        guard count >= 0, index + count <= bytes.count else { return nil }
        let slice = Array(bytes[index..<(index + count)])
        index += count
        return slice
    }

    mutating func skip(wireType: Int) -> Bool {
        switch wireType {
        case 0:
            return readVarint() != nil
        case 1:
            return index + 8 <= bytes.count && { index += 8; return true }()
        case 2:
            guard let count = readVarint() else { return false }
            guard count <= UInt64(bytes.count - index) else { return false }
            index += Int(count)
            return true
        case 5:
            return index + 4 <= bytes.count && { index += 4; return true }()
        default:
            return false
        }
    }
}

/// Throwing reads layered over `IlsProtobufReader`, so a truncated stream
/// raises `truncatedInput` instead of silently yielding a default (a
/// missing bool read as `true`, a missing double read as 0, etc.).
private extension IlsProtobufReader {
    mutating func requireVarint() throws -> UInt64 {
        guard let value = readVarint() else { throw IlsDecodeError.truncatedInput }
        return value
    }

    /// A signed protobuf integer. Negative `int32`/`int64` values arrive as a
    /// 10-byte sign-extended two's-complement `UInt64` (≥ 2^63); reinterpret
    /// the bit pattern rather than letting `Int(_:)` trap on overflow.
    mutating func requireSignedInt() throws -> Int {
        Int(Int64(bitPattern: try requireVarint()))
    }

    mutating func requireBool() throws -> Bool {
        try requireVarint() != 0
    }

    mutating func requireDouble() throws -> Double {
        guard let bits = readFixed64() else { throw IlsDecodeError.truncatedInput }
        return Double(bitPattern: bits)
    }
}

/// Decoding errors for the iLightShow analysis payload.
enum IlsDecodeError: Error, Equatable {
    case truncatedInput
    case fieldNotDecoded(field: Int, wireType: Int)
}

/// Protobuf decoders for the iLightShow analysis schema.
enum IlsProtobuf {
    /// Decodes the root analysis message (root fields from the 4.0.0-beta
    /// generated class `c.java`: 1 duration, 2 title, 3 artist, 4 isrc,
    /// 5 shazam, 7 chromaprint, 8 items, 9 tempo).
    static func decodeAnalysis(_ bytes: [UInt8]) throws -> IlsAnalysis {
        var reader = IlsProtobufReader(bytes)
        var analysis = IlsAnalysis()
        while let (field, wireType) = reader.nextField() {
            switch (field, wireType) {
            case (1, 1):
                analysis.duration = try reader.requireDouble()
            case (2, 2):
                analysis.title = try string(field: 2, wireType: 2, reader: &reader)
            case (3, 2):
                analysis.artist = try string(field: 3, wireType: 2, reader: &reader)
            case (4, 2):
                analysis.isrc = try string(field: 4, wireType: 2, reader: &reader)
            case (5, 2):
                let count = try length(reader: &reader)
                guard let fingerprint = reader.readBytes(count: count) else { throw IlsDecodeError.truncatedInput }
                analysis.shazamFingerprint = fingerprint
            case (7, 2):
                analysis.chromaprint = try string(field: 7, wireType: 2, reader: &reader)
            case (8, 2):
                let count = try length(reader: &reader)
                guard let itemBytes = reader.readBytes(count: count) else { throw IlsDecodeError.truncatedInput }
                analysis.items.append(try decodeItem(itemBytes))
            case (9, 1):
                analysis.tempo = try reader.requireDouble()
            default:
                guard reader.skip(wireType: wireType) else {
                    throw IlsDecodeError.fieldNotDecoded(field: field, wireType: wireType)
                }
            }
        }
        return analysis
    }

    /// Decodes one 100 Hz timeline item (fields from `b.java`: see above).
    static func decodeItem(_ bytes: [UInt8]) throws -> IlsAnalysis.IlsItem {
        var reader = IlsProtobufReader(bytes)
        var item = IlsAnalysis.IlsItem()
        while let (field, wireType) = reader.nextField() {
            switch (field, wireType) {
            case (1, 0):
                item.frameInTrack = try reader.requireSignedInt()
            case (2, 0):
                item.frameInPortion = try reader.requireSignedInt()
            case (3, 0):
                item.drum = try reader.requireBool()
            case (4, 0):
                item.drumAct = try reader.requireSignedInt()
            case (5, 0):
                item.buildup = try reader.requireBool()
            case (6, 0):
                item.buildupAct = try reader.requireSignedInt()
            case (7, 0):
                item.strobe = try reader.requireBool()
            case (8, 0):
                item.strobeAct = try reader.requireSignedInt()
            case (9, 0):
                item.beat = try reader.requireBool()
            case (10, 0):
                item.beatAct = try reader.requireSignedInt()
            case (11, 0):
                item.downbeat = try reader.requireBool()
            case (12, 0):
                item.downbeatAct = try reader.requireSignedInt()
            case (13, 0):
                item.section = try reader.requireBool()
            case (14, 0):
                item.sectionAct = try reader.requireSignedInt()
            case (15, 0):
                item.aggressiveAct = try reader.requireSignedInt()
            case (16, 0):
                item.partyAct = try reader.requireSignedInt()
            case (17, 1):
                item.timeBeforeNextDrum = try reader.requireDouble()
            case (18, 1):
                item.timeBeforeNextBeat = try reader.requireDouble()
            case (19, 0):
                item.singleLightUse = try reader.requireBool()
            default:
                guard reader.skip(wireType: wireType) else {
                    throw IlsDecodeError.fieldNotDecoded(field: field, wireType: wireType)
                }
            }
        }
        return item
    }

    /// Reads a length-delimited payload's length, throwing on truncation.
    private static func length(reader: inout IlsProtobufReader) throws -> Int {
        guard let raw = reader.readVarint(), raw <= Int32.max else {
            throw IlsDecodeError.truncatedInput
        }
        return Int(raw)
    }

    /// Reads a length-delimited UTF-8 string field.
    private static func string(field: Int, wireType: Int, reader: inout IlsProtobufReader) throws -> String {
        guard wireType == 2 else { throw IlsDecodeError.fieldNotDecoded(field: field, wireType: wireType) }
        let count = try length(reader: &reader)
        guard let bytes = reader.readBytes(count: count) else { throw IlsDecodeError.truncatedInput }
        return String(decoding: bytes, as: UTF8.self)
    }
}

extension IlsAnalysis {
    /// The mapping of this timeline onto LumenDesk's `BeatMap`.
    ///
    /// The server's frame grid is exactly `BeatMap.envelopeRate` (100 Hz),
    /// so this is a direct copy — no resampling. Beats, downbeats, drums,
    /// sections, and tempos all come straight from the timeline.
    var beatMap: BeatMap? {
        // `BeatMap.beats` must be strictly ascending (the grid's binary
        // search and the nearest-beat scan below both rely on it); wire
        // order is not guaranteed, so sort and drop duplicate frames.
        var seenFrames = Set<Int>()
        let beatItems = items
            .filter(\.beat)
            .sorted { $0.frameInTrack < $1.frameInTrack }
            .filter { seenFrames.insert($0.frameInTrack).inserted }
        guard beatItems.count >= 4 else { return nil }

        let beats = beatItems.map(\.time)

        // Downbeat phase: which beat of the 4-beat bar carries the downbeat
        // (mode of the nearest-beat index % 4). Defaults to 0.
        var downbeatOffset = 0
        let downbeats = items.filter(\.downbeat).sorted { $0.frameInTrack < $1.frameInTrack }
        if !downbeats.isEmpty {
            var phases: [Int: Int] = [:]
            var beatIndex = 0
            for downbeat in downbeats {
                while beatIndex < beats.count - 1,
                      abs(beats[beatIndex + 1] - downbeat.time) <= abs(beats[beatIndex] - downbeat.time) {
                    beatIndex += 1
                }
                phases[beatIndex % BeatMap.beatsPerBar, default: 0] += 1
            }
            // Mode, tie-broken toward the lowest phase for a stable result
            // (Dictionary iteration order is otherwise randomized), matching
            // BeatMapBuilder.downbeatOffset.
            downbeatOffset = phases
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .first?.key ?? 0
        }

        // Envelope at 100 Hz: strongest event per frame wins. The frame
        // count is clamped so a corrupt `frameInTrack` cannot force a
        // multi-gigabyte allocation.
        let maxFrame = items.lazy.map(\.frameInTrack).filter { $0 >= 0 }.max() ?? 0
        let lastFrame = min(maxFrame, IlsAnalysis.maxFrames)
        var envelope = [Double](repeating: 0, count: lastFrame + 1)
        for item in items {
            guard item.frameInTrack >= 0, item.frameInTrack < envelope.count else { continue }
            var strength = 0.0
            if item.beat { strength = max(strength, 1.0) }
            if item.downbeat { strength = max(strength, 1.0) }
            if item.drum { strength = max(strength, 0.7) }
            if item.buildup { strength = max(strength, 0.5) }
            if item.strobe { strength = max(strength, 0.4) }
            if item.section { strength = max(strength, 0.8) }
            // The server already sends per-event intensities (0…~100); fold
            // the strongest in so a quiet drum is not identical to a loud one.
            let act = Double(max(item.beatAct, item.drumAct, item.sectionAct, item.aggressiveAct, item.partyAct))
            if act > 0 { strength = max(strength, min(1.0, act / 100.0)) }
            // Preserve the strongest event when two items share a frame.
            envelope[item.frameInTrack] = max(envelope[item.frameInTrack], strength)
        }

        // Confidence: how evenly spaced the beats are (1 - relative spread).
        var confidence = 0.0
        if beats.count >= 4 {
            var intervals: [Double] = []
            for i in 1..<beats.count {
                let interval = beats[i] - beats[i - 1]
                if interval > 0 { intervals.append(interval) }
            }
            if intervals.count >= 4 {
                let mean = intervals.reduce(0, +) / Double(intervals.count)
                if mean > 0 {
                    let variance = intervals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(intervals.count)
                    let spread = variance.squareRoot() / mean
                    confidence = min(1, max(0, 1 - spread))
                }
            }
        }

        // Bar energy: mean envelope value inside each bar window, so loud and
        // quiet bars differ (a max would read 1.0 on every bar that holds a
        // beat). Bar length comes from downbeat spacing when present, else the
        // median 4-beat span.
        var barLength: Double = 0
        let downbeatTimes = downbeats.map(\.time)
        if downbeatTimes.count >= 2 {
            var spacings: [Double] = []
            for i in 1..<downbeatTimes.count {
                let spacing = downbeatTimes[i] - downbeatTimes[i - 1]
                if spacing > 0.05 { spacings.append(spacing) }
            }
            if !spacings.isEmpty { spacings.sort(); barLength = spacings[spacings.count / 2] }
        } else if beats.count > BeatMap.beatsPerBar {
            var spans: [Double] = []
            for i in 0..<(beats.count - BeatMap.beatsPerBar) {
                let span = beats[i + BeatMap.beatsPerBar] - beats[i]
                if span > 0.05 { spans.append(span) }
            }
            if !spans.isEmpty { spans.sort(); barLength = spans[spans.count / 2] }
        }
        var barEnergy: [Double] = []
        if barLength > 0.05, beats.count >= BeatMap.beatsPerBar {
            for index in stride(from: downbeatOffset, to: beats.count - BeatMap.beatsPerBar + 1, by: BeatMap.beatsPerBar) {
                let start = beats[index]
                let end = start + barLength
                let first = max(0, Int(start * BeatMap.envelopeRate))
                let last = min(envelope.count - 1, Int(end * BeatMap.envelopeRate))
                if last >= first {
                    let window = envelope[first...last]
                    barEnergy.append(window.reduce(0, +) / Double(window.count))
                }
            }
        }

        return BeatMap(
            version: BeatMap.currentVersion,
            duration: max(duration, beats.last ?? 0),
            tempo: tempo > 0 ? tempo : inferredTempo(from: beats),
            beats: beats,
            downbeatOffset: downbeatOffset,
            barEnergy: barEnergy,
            envelope: envelope,
            confidence: confidence
        )
    }

    /// Tempo from the median beat interval, when the server omits one.
    private func inferredTempo(from beats: [TimeInterval]) -> Double {
        guard beats.count >= 2 else { return 0 }
        var intervals: [Double] = []
        for i in 1..<beats.count {
            let interval = beats[i] - beats[i - 1]
            if interval > 0.05 && interval < 2 { intervals.append(interval) }
        }
        guard !intervals.isEmpty else { return 0 }
        intervals.sort()
        return 60.0 / intervals[intervals.count / 2]
    }
}
