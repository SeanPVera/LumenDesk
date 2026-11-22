import Foundation

/// Govee LAN API. The user must enable "LAN Control" in the Govee Home app on
/// each supported bulb. Reference:
/// https://app-h5.govee.com/user-manual/wlan-guide
enum GoveeProtocol {
    static let multicastGroup = "239.255.255.250"
    static let discoveryPort: UInt16 = 4001
    static let responsePort: UInt16 = 4002
    static let controlPort: UInt16 = 4003
    // GoveeClient decodes on one serial queue, so reusing the decoder is safe.
    // Command markers also avoid attempting a full ScanResponse decode for
    // every routine status heartbeat.
    private static let decoder = JSONDecoder()
    private static let scanMarker = Data(#""scan""#.utf8)
    private static let statusMarker = Data(#""devStatus""#.utf8)

    struct ScanResponse: Decodable {
        let msg: Inner
        struct Inner: Decodable {
            let cmd: String
            let data: ScanData
        }
        struct ScanData: Decodable {
            let ip: String
            let device: String
            let sku: String?
            let deviceName: String?
        }
    }

    struct StatusResponse: Decodable {
        let msg: Inner
        struct Inner: Decodable {
            let cmd: String
            let data: StatusData
        }
        struct StatusData: Decodable {
            let onOff: Int
            let brightness: Int
            let color: RGB?
            let colorTemInKelvin: Int?
            struct RGB: Decodable {
                let r: Int
                let g: Int
                let b: Int
            }

            private enum CodingKeys: String, CodingKey { case onOff, brightness, color, colorTemInKelvin }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                onOff = try container.decode(Int.self, forKey: .onOff)
                brightness = try container.decode(Int.self, forKey: .brightness)
                color = try container.decodeIfPresent(RGB.self, forKey: .color)
                colorTemInKelvin = try container.decodeIfPresent(Int.self, forKey: .colorTemInKelvin)
                guard (0...1).contains(onOff), (0...100).contains(brightness),
                      color.map({ (0...255).contains($0.r) && (0...255).contains($0.g) && (0...255).contains($0.b) }) ?? true,
                      colorTemInKelvin.map({ $0 == 0 || (1200...9000).contains($0) }) ?? true else {
                    throw DecodingError.dataCorruptedError(forKey: .brightness, in: container,
                                                          debugDescription: "Invalid Govee status range")
                }
            }
        }
    }

    static func decodeScanResponse(_ data: Data) -> ScanResponse? {
        guard data.range(of: scanMarker) != nil,
              let response = try? decoder.decode(ScanResponse.self, from: data),
              response.msg.cmd == "scan", !response.msg.data.ip.isEmpty,
              !response.msg.data.device.isEmpty else { return nil }
        return response
    }

    static func decodeStatusResponse(_ data: Data) -> StatusResponse? {
        guard data.range(of: statusMarker) != nil,
              let response = try? decoder.decode(StatusResponse.self, from: data),
              response.msg.cmd == "devStatus" else { return nil }
        return response
    }

    static func scanRequest() -> Data {
        Data(#"{"msg":{"cmd":"scan","data":{"account_topic":"reserve"}}}"#.utf8)
    }

    static func statusRequest() -> Data {
        Data(#"{"msg":{"cmd":"devStatus","data":{}}}"#.utf8)
    }

    static func turnRequest(on: Bool) -> Data {
        Data(#"{"msg":{"cmd":"turn","data":{"value":\#(on ? 1 : 0)}}}"#.utf8)
    }

    static func brightnessRequest(_ value: Int) -> Data {
        let clamped = max(0, min(100, value))
        return Data(#"{"msg":{"cmd":"brightness","data":{"value":\#(clamped)}}}"#.utf8)
    }

    /// Set color or color temperature. If `kelvin` > 0, RGB is ignored by the bulb.
    static func colorRequest(r: Int, g: Int, b: Int, kelvin: Int = 0) -> Data {
        let rr = max(0, min(255, r)); let gg = max(0, min(255, g)); let bb = max(0, min(255, b))
        return Data(#"{"msg":{"cmd":"colorwc","data":{"color":{"r":\#(rr),"g":\#(gg),"b":\#(bb)},"colorTemInKelvin":\#(kelvin)}}}"#.utf8)
    }

    // MARK: - Segment control (community-documented LAN extensions)
    //
    // RGBIC devices (COB strips, neon ropes, string/curtain lights) accept two
    // LAN commands beyond the documented five, reverse-engineered by the
    // OpenRGB and govee2mqtt projects:
    //
    //  * `razer` — the real-time streaming mode used by Razer Chroma sync
    //    ("DreamView"). A binary packet is base64-encoded into `pt`. While
    //    enabled, each frame paints every segment at once. The overlay is
    //    volatile: disabling razer mode returns the device to its last static
    //    state.
    //  * `ptReal` — relays the same 20-byte packets the Govee Home app writes
    //    over Bluetooth, base64-encoded into a `command` array. This is how a
    //    static per-segment layout (color 0x33/0x05/0x15/0x01, brightness
    //    0x33/0x05/0x15/0x02, gradient 0x33/0xA3) is applied durably.

    /// Number of segments addressable by the static segment-color packet:
    /// its bitmask field is 7 bytes (offsets 12…18 of the 19-byte payload).
    static let maxSegments = 56

    /// XOR of every byte — the trailing checksum both packet families use.
    private static func xorChecksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(0) { $0 ^ $1 }
    }

    // MARK: Razer streaming packets

    private static func razerRequest(_ packet: [UInt8]) -> Data {
        let pt = Data(packet).base64EncodedString()
        return Data(#"{"msg":{"cmd":"razer","data":{"pt":"\#(pt)"}}}"#.utf8)
    }

    /// Razer packets: 0xBB, big-endian payload length, subcommand, payload,
    /// XOR checksum. Mode subcommand is 0xB1 with payload 01=on / 00=off.
    static func razerModeRequest(on: Bool) -> Data {
        var packet: [UInt8] = [0xBB, 0x00, 0x01, 0xB1, on ? 0x01 : 0x00]
        packet.append(xorChecksum(packet))
        return razerRequest(packet)
    }

    /// One streaming frame: subcommand 0xB0 carries a blend flag (0x00 blends
    /// neighboring colors like DreamView, 0x01 keeps hard segment edges)
    /// followed by the color count and RGB triplets.
    static func razerFrameRequest(colors: [(r: Int, g: Int, b: Int)], blend: Bool) -> Data {
        let capped = colors.prefix(255)
        let length = 2 + capped.count * 3
        var packet: [UInt8] = [0xBB, UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF), 0xB0,
                               blend ? 0x00 : 0x01, UInt8(capped.count)]
        for color in capped {
            packet.append(UInt8(max(0, min(255, color.r))))
            packet.append(UInt8(max(0, min(255, color.g))))
            packet.append(UInt8(max(0, min(255, color.b))))
        }
        packet.append(xorChecksum(packet))
        return razerRequest(packet)
    }

    // MARK: ptReal (Bluetooth-format) packets

    /// Wraps prebuilt 20-byte BLE packets into one ptReal datagram.
    static func ptRealRequest(packets: [[UInt8]]) -> Data {
        let commands = packets.map { #""\#(Data($0).base64EncodedString())""# }.joined(separator: ",")
        return Data(#"{"msg":{"cmd":"ptReal","data":{"command":[\#(commands)]}}}"#.utf8)
    }

    /// Pads a payload to 19 bytes and appends the XOR checksum, producing the
    /// fixed 20-byte packet the firmware expects.
    static func blePacket(_ payload: [UInt8]) -> [UInt8] {
        var packet = payload
        if packet.count < 19 { packet.append(contentsOf: [UInt8](repeating: 0, count: 19 - packet.count)) }
        packet = Array(packet.prefix(19))
        packet.append(xorChecksum(packet))
        return packet
    }

    /// Little-endian segment bitmask: bit 0 of the first byte is segment 0.
    private static func segmentMask(_ segments: [Int], byteCount: Int) -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: byteCount)
        for segment in segments where segment >= 0 && segment < byteCount * 8 {
            mask[segment / 8] |= UInt8(1 << (segment % 8))
        }
        return mask
    }

    /// Static color for a set of segments:
    /// `33 05 15 01 <r g b> <5 reserved bytes> <7-byte segment mask>`.
    static func segmentColorPacket(r: Int, g: Int, b: Int, segments: [Int]) -> [UInt8] {
        var payload: [UInt8] = [0x33, 0x05, 0x15, 0x01,
                                UInt8(max(0, min(255, r))), UInt8(max(0, min(255, g))), UInt8(max(0, min(255, b))),
                                0x00, 0x00, 0x00, 0x00, 0x00]
        payload.append(contentsOf: segmentMask(segments, byteCount: 7))
        return blePacket(payload)
    }

    /// White point for a set of segments, in the same frame as a colour:
    /// `33 05 15 01 FF FF FF <K hi> <K lo> <white r g b> <7-byte segment mask>`.
    /// The five bytes after the colour carry the Kelvin (big-endian) and its
    /// RGB white, with the colour set to FF FF FF. Verified on hardware by
    /// lasswellt/govee-homeassistant issue #223 (H1252: 2700 K = 0A 8C,
    /// 6500 K = 19 64) and listed as "segment temperature" for H6088/H61E0
    /// in SamWiIIiams/govee-lan-bridge. Only used for durable (non-stream)
    /// segment writes; stream frames are RGB and carry the mixed white.
    static func segmentWhitePacket(kelvin: Int, white: (r: Int, g: Int, b: Int), segments: [Int]) -> [UInt8] {
        let k = max(1_000, min(9_000, kelvin))
        var payload: [UInt8] = [0x33, 0x05, 0x15, 0x01, 0xFF, 0xFF, 0xFF,
                                UInt8((k >> 8) & 0xFF), UInt8(k & 0xFF),
                                UInt8(max(0, min(255, white.r))), UInt8(max(0, min(255, white.g))),
                                UInt8(max(0, min(255, white.b)))]
        payload.append(contentsOf: segmentMask(segments, byteCount: 7))
        return blePacket(payload)
    }

    // MARK: H60B0 Uplighter sections

    /// The H60B0 Uplighter's three sections, as its firmware numbers them.
    ///
    /// Evidence: SamWiIIiams/govee-lan-bridge (README "Protocol notes",
    /// `bridge.py`, byte-for-byte `test_bridge.py`), frames derived from the
    /// Govee Home app's Bluetooth traffic and verified on an H60B0 over LAN
    /// `ptReal`; the same table is posted in lasswellt/govee-homeassistant
    /// #211. Govee's Developer API names the same three parts
    /// `rippleLightToggle`, `sideLightToggle` and `bottomLightToggle` (#83).
    enum UplighterSection: UInt8, CaseIterable {
        case ripple = 1
        case side = 2
        case down = 3
    }

    /// The H60B0's side ring has 8 segments; `FF` addresses all of them.
    static let uplighterSideMaskAll: UInt8 = 0xFF
    static let uplighterKelvinRange = 2_700...6_500

    /// Section on/off: `33 30 <section> 01|00`. The lamp runs at most two.
    static func uplighterSectionPowerPacket(_ section: UplighterSection, on: Bool) -> [UInt8] {
        blePacket([0x33, 0x30, section.rawValue, on ? 0x01 : 0x00])
    }

    /// Ripple or side colour: `33 05 2c <sec> 01 RR GG BB KK KK` (Kelvin
    /// `00 00` for a plain colour); the side ring takes its segment mask
    /// after the Kelvin bytes. The down light has no colour (see
    /// `uplighterDownKelvinPacket`), so asking for one returns nil.
    static func uplighterColorPacket(_ section: UplighterSection,
                                     rgb: (r: Int, g: Int, b: Int), kelvin: Int? = nil) -> [UInt8]? {
        guard section != .down else { return nil }
        let k = kelvin.map { max(uplighterKelvinRange.lowerBound, min(uplighterKelvinRange.upperBound, $0)) } ?? 0
        var payload: [UInt8] = [0x33, 0x05, 0x2C, section.rawValue, 0x01,
                                UInt8(max(0, min(255, rgb.r))), UInt8(max(0, min(255, rgb.g))),
                                UInt8(max(0, min(255, rgb.b))),
                                UInt8((k >> 8) & 0xFF), UInt8(k & 0xFF)]
        if section == .side { payload.append(uplighterSideMaskAll) }
        return blePacket(payload)
    }

    /// Section brightness 1…100: `33 05 2c <sec> 02 <pct>`; the side ring
    /// needs its segment mask after the value or the lamp ignores it.
    static func uplighterBrightnessPacket(_ section: UplighterSection, percent: Int) -> [UInt8] {
        var payload: [UInt8] = [0x33, 0x05, 0x2C, section.rawValue, 0x02, UInt8(max(1, min(100, percent)))]
        if section == .side { payload.append(uplighterSideMaskAll) }
        return blePacket(payload)
    }

    /// Down-light white point: `33 05 2c 03 01 KK KK`, no RGB bytes. Colour
    /// bytes or a Kelvin outside 2700–6500 black the lamp out, so the value
    /// is always clamped.
    static func uplighterDownKelvinPacket(_ kelvin: Int) -> [UInt8] {
        let k = max(uplighterKelvinRange.lowerBound, min(uplighterKelvinRange.upperBound, kelvin))
        return blePacket([0x33, 0x05, 0x2C, 0x03, 0x01, UInt8((k >> 8) & 0xFF), UInt8(k & 0xFF)])
    }

    /// Ripple flow (the rotating lens's speed) 0…100: `33 05 2c 01 03 <v>`.
    /// 0 effectively stops the ripple.
    static func uplighterFlowPacket(_ value: Int) -> [UInt8] {
        blePacket([0x33, 0x05, 0x2C, 0x01, 0x03, UInt8(max(0, min(100, value)))])
    }

    /// Per-segment brightness (1…100 percent):
    /// `33 05 15 02 <percent> <14-byte segment mask>`.
    static func segmentBrightnessPacket(percent: Int, segments: [Int]) -> [UInt8] {
        var payload: [UInt8] = [0x33, 0x05, 0x15, 0x02, UInt8(max(1, min(100, percent)))]
        payload.append(contentsOf: segmentMask(segments, byteCount: 14))
        return blePacket(payload)
    }

    /// Blend neighboring segment colors into each other (COB strips):
    /// `33 A3 <01 on / 00 off>`.
    static func gradientPacket(on: Bool) -> [UInt8] {
        blePacket([0x33, 0xA3, on ? 0x01 : 0x00])
    }
}
