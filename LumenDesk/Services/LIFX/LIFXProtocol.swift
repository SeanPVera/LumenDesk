import Foundation

/// LIFX LAN protocol primitives. Packets are little-endian with a fixed 36-byte
/// header followed by a per-message payload. See:
/// https://lan.developer.lifx.com/docs/header-description
enum LIFXMessage: UInt16 {
    case getService = 2
    case stateService = 3
    case getHostFirmware = 14
    case stateLabel = 25
    case getVersion = 32
    case stateVersion = 33
    case setLightPower = 117
    case stateLightPower = 118
    case lightGet = 101
    case lightSetColor = 102
    case lightState = 107
    case getDeviceChain = 701
    case stateDeviceChain = 702
    case get64 = 707
    case state64 = 711
    case set64 = 715
}

struct LIFXHSBK: Equatable {
    var hue: UInt16          // 0…65535 → 0…360°
    var saturation: UInt16   // 0…65535
    var brightness: UInt16   // 0…65535
    var kelvin: UInt16       // 2500…9000
}

struct LIFXMatrixDevice: Equatable {
    var width: Int
    var height: Int
    var vendorID: UInt32
    var productID: UInt32
}

enum LIFXProtocol {
    static let port: UInt16 = 56700
    static let broadcastAddress = "255.255.255.255"
    static let headerSize = 36
    private static let zeros2 = Data(repeating: 0, count: 2)
    private static let zeros6 = Data(repeating: 0, count: 6)
    private static let zeros8 = Data(repeating: 0, count: 8)

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
        data.reserveCapacity(Int(size))
        data.appendLE(size)

        // protocol(12 bits = 1024) | addressable(1) | tagged(1) | origin(2) = uint16 LE
        let tagged = target.isEmpty
        var flags: UInt16 = 1024
        flags |= 0x1000           // addressable
        if tagged { flags |= 0x2000 }
        data.appendLE(flags)

        data.appendLE(source)

        // Target: 6 byte MAC padded to 8 bytes (LE byte order on the wire).
        let targetCount = min(6, target.count)
        if targetCount > 0 { data.append(target.prefix(targetCount)) }
        data.append(zeros8.prefix(8 - targetCount))

        data.append(zeros6) // reserved

        var respFlags: UInt8 = 0
        if resRequired { respFlags |= 0x01 }
        if ackRequired { respFlags |= 0x02 }
        data.append(respFlags)
        data.append(sequence)

        data.append(zeros8) // reserved

        data.appendLE(type.rawValue)
        data.append(zeros2) // reserved

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
        guard size >= headerSize, Int(size) == data.count else { return nil }
        let source: UInt32 = data.readLE(at: 4)
        let target = data.subdata(in: (data.startIndex + 8)..<(data.startIndex + 14))
        let sequence = data[data.startIndex + 23]
        let type: UInt16 = data.readLE(at: 32)
        let payload = data.subdata(in: (data.startIndex + headerSize)..<(data.startIndex + Int(size)))
        return ParsedHeader(size: size, source: source, target: target,
                            sequence: sequence, type: type, payload: payload)
    }

    // MARK: Payload builders

    static func setColorPayload(_ c: LIFXHSBK, durationMS: UInt32 = 250) -> Data {
        var p = Data()
        p.reserveCapacity(13)
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
        p.reserveCapacity(6)
        p.appendLE(UInt16(on ? 65535 : 0))
        p.appendLE(durationMS)
        return p
    }

    static func get64Payload(width: Int, tileIndex: UInt8 = 0, length: UInt8 = 1) -> Data {
        var p = Data()
        p.reserveCapacity(6)
        p.append(tileIndex)
        p.append(length)
        p.append(0) // reserved
        p.append(0) // x
        p.append(0) // y
        p.append(UInt8(clamping: width))
        return p
    }

    /// Matrix devices always expect a fixed array of 64 HSBK values. Devices
    /// with fewer physical zones ignore cells outside their reported bounds.
    static func set64Payload(colors: [LIFXHSBK], width: Int,
                             durationMS: UInt32 = 250,
                             tileIndex: UInt8 = 0, length: UInt8 = 1) -> Data {
        var p = Data()
        p.reserveCapacity(522)
        p.append(tileIndex)
        p.append(length)
        p.append(0) // visible frame buffer
        p.append(0) // x
        p.append(0) // y
        p.append(UInt8(clamping: width))
        p.appendLE(durationMS)

        let off = LIFXHSBK(hue: 0, saturation: 0, brightness: 0, kelvin: 3_500)
        for index in 0..<64 {
            let color = colors.indices.contains(index) ? colors[index] : off
            p.appendLE(color.hue)
            p.appendLE(color.saturation)
            p.appendLE(color.brightness)
            p.appendLE(color.kelvin)
        }
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

    static func parseVersion(_ payload: Data) -> (vendorID: UInt32, productID: UInt32)? {
        guard payload.count >= 12 else { return nil }
        return (payload.readLE(at: 0), payload.readLE(at: 4))
    }

    /// StateDeviceChain contains 16 fixed-width Tile structures followed by
    /// the number that are valid. Luna is a single matrix device, so the first
    /// structure supplies its geometry and product identity.
    static func parseMatrixDevice(_ payload: Data) -> LIFXMatrixDevice? {
        let tileSize = 55
        let tileCountOffset = 1 + 16 * tileSize
        guard payload.count > tileCountOffset, payload[tileCountOffset] > 0 else { return nil }
        let firstTile = 1
        let width = Int(payload[firstTile + 16])
        let height = Int(payload[firstTile + 17])
        guard width > 0, height > 0, width * height <= 64 else { return nil }
        let vendor: UInt32 = payload.readLE(at: firstTile + 19)
        let product: UInt32 = payload.readLE(at: firstTile + 23)
        return LIFXMatrixDevice(width: width, height: height,
                                vendorID: vendor, productID: product)
    }

    static func parseState64(_ payload: Data) -> (width: Int, colors: [LIFXHSBK])? {
        guard payload.count >= 5 + 64 * 8 else { return nil }
        let width = Int(payload[4])
        guard width > 0 else { return nil }
        var colors: [LIFXHSBK] = []
        colors.reserveCapacity(64)
        for index in 0..<64 {
            let offset = 5 + index * 8
            colors.append(LIFXHSBK(
                hue: payload.readLE(at: offset),
                saturation: payload.readLE(at: offset + 2),
                brightness: payload.readLE(at: offset + 4),
                kelvin: payload.readLE(at: offset + 6)
            ))
        }
        return (width, colors)
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
