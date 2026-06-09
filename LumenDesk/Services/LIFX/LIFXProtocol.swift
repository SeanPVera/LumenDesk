import Foundation

/// LIFX LAN protocol primitives. Packets are little-endian with a fixed 36-byte
/// header followed by a per-message payload. See:
/// https://lan.developer.lifx.com/docs/header-description
enum LIFXMessage: UInt16 {
    case getService = 2
    case stateService = 3
    case getHostFirmware = 14
    case stateLabel = 25
    case setLightPower = 117
    case stateLightPower = 118
    case lightGet = 101
    case lightSetColor = 102
    case lightState = 107
}

struct LIFXHSBK: Equatable {
    var hue: UInt16          // 0…65535 → 0…360°
    var saturation: UInt16   // 0…65535
    var brightness: UInt16   // 0…65535
    var kelvin: UInt16       // 2500…9000
}

enum LIFXProtocol {
    static let port: UInt16 = 56700
    static let broadcastAddress = "255.255.255.255"
    static let headerSize = 36

    /// Build a LIFX LAN packet.
    /// - target: 6-byte MAC (empty Data for broadcast / tagged messages)
    static func packet(type: LIFXMessage,
                       source: UInt32,
                       target: Data,
                       payload: Data,
                       sequence: UInt8 = 0,
                       resRequired: Bool = false,
                       ackRequired: Bool = false) -> Data {
        var data = Data()
        let size = UInt16(headerSize + payload.count)
        data.appendLE(size)

        // protocol(12 bits = 1024) | addressable(1) | tagged(1) | origin(2) = uint16 LE
        let tagged = target.isEmpty
        var flags: UInt16 = 1024
        flags |= 0x1000           // addressable
        if tagged { flags |= 0x2000 }
        data.appendLE(flags)

        data.appendLE(source)

        // Target: 6 byte MAC padded to 8 bytes (LE byte order on the wire).
        var t = Data(count: 8)
        if !target.isEmpty {
            let n = min(6, target.count)
            t.replaceSubrange(0..<n, with: target.prefix(n))
        }
        data.append(t)

        data.append(Data(count: 6)) // reserved

        var respFlags: UInt8 = 0
        if resRequired { respFlags |= 0x01 }
        if ackRequired { respFlags |= 0x02 }
        data.append(respFlags)
        data.append(sequence)

        data.append(Data(count: 8)) // reserved

        data.appendLE(type.rawValue)
        data.append(Data(count: 2)) // reserved

        data.append(payload)
        return data
    }

    struct ParsedHeader {
        var size: UInt16
        var source: UInt32
        var target: Data       // 6 bytes
        var sequence: UInt8
        var type: UInt16
        var payload: Data
    }

    static func parse(_ data: Data) -> ParsedHeader? {
        guard data.count >= headerSize else { return nil }
        let size: UInt16 = data.readLE(at: 0)
        let source: UInt32 = data.readLE(at: 4)
        let target = data.subdata(in: (data.startIndex + 8)..<(data.startIndex + 14))
        let sequence = data[data.startIndex + 23]
        let type: UInt16 = data.readLE(at: 32)
        let payload = data.subdata(in: (data.startIndex + headerSize)..<data.endIndex)
        return ParsedHeader(size: size, source: source, target: target,
                            sequence: sequence, type: type, payload: payload)
    }

    // MARK: Payload builders

    static func setColorPayload(_ c: LIFXHSBK, durationMS: UInt32 = 250) -> Data {
        var p = Data()
        p.append(0) // reserved
        p.appendLE(c.hue)
        p.appendLE(c.saturation)
        p.appendLE(c.brightness)
        p.appendLE(c.kelvin)
        p.appendLE(durationMS)
        return p
    }

    static func setPowerPayload(on: Bool, durationMS: UInt32 = 250) -> Data {
        var p = Data()
        p.appendLE(UInt16(on ? 65535 : 0))
        p.appendLE(durationMS)
        return p
    }

    // MARK: Payload parsers

    static func parseLightState(_ payload: Data) -> (color: LIFXHSBK, power: UInt16, label: String)? {
        guard payload.count >= 52 else { return nil }
        let hue: UInt16 = payload.readLE(at: 0)
        let sat: UInt16 = payload.readLE(at: 2)
        let bri: UInt16 = payload.readLE(at: 4)
        let kel: UInt16 = payload.readLE(at: 6)
        // payload[8..<10] reserved
        let power: UInt16 = payload.readLE(at: 10)
        let labelBytes = payload.subdata(in: (payload.startIndex + 12)..<(payload.startIndex + 12 + 32))
        let label = String(bytes: labelBytes.prefix { $0 != 0 }, encoding: .utf8) ?? ""
        return (LIFXHSBK(hue: hue, saturation: sat, brightness: bri, kelvin: kel), power, label)
    }
}

extension Data {
    mutating func appendLE(_ v: UInt16) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ v: UInt32) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }

    func readLE<T: FixedWidthInteger>(at offset: Int) -> T {
        precondition(offset >= 0 && offset + MemoryLayout<T>.size <= count, "Out of bounds LIFX read")
        return withUnsafeBytes { raw in
            T(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: T.self))
        }
    }
}
