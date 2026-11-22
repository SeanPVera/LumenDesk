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
                analysis.duration = Double(bitPattern: reader.readFixed64() ?? 0)
            case (2, 2):
                analysis.title = try string(field: 2, wireType: 2, reader: &reader)
            case (3, 2):
                analysis.artist = try string(field: 3, wireType: 2, reader: &reader)
            case (4, 2):
                analysis.isrc = try string(field: 4, wireType: 2, reader: &reader)
            case (5, 2):
                analysis.shazamFingerprint = reader.readBytes(count: try length(reader: &reader)) ?? []
            case (7, 2):
                analysis.chromaprint = try string(field: 7, wireType: 2, reader: &reader)
            case (8, 2):
                let count = try length(reader: &reader)
                guard let itemBytes = reader.readBytes(count: count) else { throw IlsDecodeError.truncatedInput }
                analysis.items.append(try decodeItem(itemBytes))
            case (9, 1):
                analysis.tempo = Double(bitPattern: reader.readFixed64() ?? 0)
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
                item.frameInTrack = Int(reader.readVarint() ?? 0)
            case (2, 0):
                item.frameInPortion = Int(reader.readVarint() ?? 0)
            case (3, 0):
                item.drum = reader.readVarint() != 0
            case (4, 0):
                item.drumAct = Int(reader.readVarint() ?? 0)
            case (5, 0):
                item.buildup = reader.readVarint() != 0
            case (6, 0):
                item.buildupAct = Int(reader.readVarint() ?? 0)
            case (7, 0):
                item.strobe = reader.readVarint() != 0
            case (8, 0):
                item.strobeAct = Int(reader.readVarint() ?? 0)
            case (9, 0):
                item.beat = reader.readVarint() != 0
            case (10, 0):
                item.beatAct = Int(reader.readVarint() ?? 0)
            case (11, 0):
                item.downbeat = reader.readVarint() != 0
            case (12, 0):
                item.downbeatAct = Int(reader.readVarint() ?? 0)
            case (13, 0):
                item.section = reader.readVarint() != 0
            case (14, 0):
                item.sectionAct = Int(reader.readVarint() ?? 0)
            case (15, 0):
                item.aggressiveAct = Int(reader.readVarint() ?? 0)
            case (16, 0):
                item.partyAct = Int(reader.readVarint() ?? 0)
            case (17, 1):
                item.timeBeforeNextDrum = Double(bitPattern: reader.readFixed64() ?? 0)
            case (18, 1):
                item.timeBeforeNextBeat = Double(bitPattern: reader.readFixed64() ?? 0)
            case (19, 0):
                item.singleLightUse = reader.readVarint() != 0
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
        let beatItems = items.filter(\.beat)
        guard beatItems.count >= 4 else { return nil }

        let beats = beatItems.map(\.time)

        // Downbeat phase: which beat of the 4-beat bar carries the downbeat
        // (mode of the nearest-beat index % 4). Defaults to 0.
        var downbeatOffset = 0
        let downbeats = items.filter(\.downbeat).sorted(by: { $0.frameInTrack < $1.frameInTrack })
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
            downbeatOffset = phases.max { $0.value < $1.value }?.key ?? 0
        }

        // Envelope at 100 Hz: strongest event per frame wins.
        let lastFrame = items.map(\.frameInTrack).max() ?? 0
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
            envelope[item.frameInTrack] = strength
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

        // Bar energy: strongest envelope value inside each bar window.
        // Bar length comes from downbeat spacing when present, else the
        // median 4-beat span.
        var barLength: Double = 0
        let downbeatTimes = items.filter(\.downbeat).map(\.time).sorted()
        if downbeatTimes.count >= 2 {
            var spacings: [Double] = []
            for i in 1..<downbeatTimes.count {
                let spacing = downbeatTimes[i] - downbeatTimes[i - 1]
                if spacing > 0.05 { spacings.append(spacing) }
            }
            if !spacings.isEmpty { spacings.sort(); barLength = spacings[spacings.count / 2] }
        } else if beats.count >= BeatMap.beatsPerBar {
            var spans: [Double] = []
            for i in 0...max(beats.count - BeatMap.beatsPerBar, 0) {
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
                    barEnergy.append(envelope[first...last].max() ?? 0)
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
