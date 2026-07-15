import XCTest
@testable import LumenDesk

final class ProtocolTests: XCTestCase {
    func testLIFXPacketEncoding() {
        let target = Data([0xD0, 0x73, 0xD5, 0x12, 0x34, 0x56])
        let payload = LIFXProtocol.setPowerPayload(on: true, durationMS: 500)
        let packet = LIFXProtocol.packet(
            type: .setLightPower,
            source: 0x1234_5678,
            target: target,
            payload: payload,
            sequence: 7,
            resRequired: true,
            ackRequired: true
        )

        XCTAssertEqual(packet.count, LIFXProtocol.headerSize + payload.count)
        XCTAssertEqual(packet.readLE(at: 0) as UInt16, UInt16(packet.count))
        XCTAssertEqual(packet.readLE(at: 2) as UInt16, 0x1400)
        XCTAssertEqual(packet.readLE(at: 4) as UInt32, 0x1234_5678)
        XCTAssertEqual(packet.subdata(in: 8..<14), target)
        XCTAssertEqual(packet[22], 0x03)
        XCTAssertEqual(packet[23], 7)
        XCTAssertEqual(packet.readLE(at: 32) as UInt16, LIFXMessage.setLightPower.rawValue)
        XCTAssertEqual(packet.suffix(payload.count), payload)
    }

    func testLIFXResponseDecoding() {
        var payload = Data()
        payload.appendLE(UInt16(10_000))
        payload.appendLE(UInt16(20_000))
        payload.appendLE(UInt16(30_000))
        payload.appendLE(UInt16(4_000))
        payload.append(Data(count: 2))
        payload.appendLE(UInt16.max)
        var label = Data("Desk Lamp".utf8)
        label.append(Data(count: 32 - label.count))
        payload.append(label)
        payload.append(Data(count: 8))

        let datagram = LIFXProtocol.packet(
            type: .lightState,
            source: 99,
            target: Data([1, 2, 3, 4, 5, 6]),
            payload: payload,
            sequence: 4
        )

        let header = LIFXProtocol.parse(datagram)
        XCTAssertEqual(header?.size, UInt16(datagram.count))
        XCTAssertEqual(header?.source, 99)
        XCTAssertEqual(header?.sequence, 4)
        XCTAssertEqual(header?.type, LIFXMessage.lightState.rawValue)

        let state = header.flatMap { LIFXProtocol.parseLightState($0.payload) }
        XCTAssertEqual(state?.color, LIFXHSBK(hue: 10_000, saturation: 20_000, brightness: 30_000, kelvin: 4_000))
        XCTAssertEqual(state?.power, UInt16.max)
        XCTAssertEqual(state?.label, "Desk Lamp")
    }

    func testGoveeDiscoveryMessageEncoding() throws {
        let root = try jsonObject(GoveeProtocol.scanRequest())
        let message = try XCTUnwrap(root["msg"] as? [String: Any])
        XCTAssertEqual(message["cmd"] as? String, "scan")
        let data = try XCTUnwrap(message["data"] as? [String: Any])
        XCTAssertEqual(data["account_topic"] as? String, "reserve")
    }

    func testGoveeCommandJSON() throws {
        let turn = try message(in: GoveeProtocol.turnRequest(on: true))
        XCTAssertEqual(turn["cmd"] as? String, "turn")
        XCTAssertEqual((turn["data"] as? [String: Any])?["value"] as? Int, 1)

        let brightness = try message(in: GoveeProtocol.brightnessRequest(140))
        XCTAssertEqual(brightness["cmd"] as? String, "brightness")
        XCTAssertEqual((brightness["data"] as? [String: Any])?["value"] as? Int, 100)

        let color = try message(in: GoveeProtocol.colorRequest(r: -4, g: 42, b: 999, kelvin: 3_500))
        XCTAssertEqual(color["cmd"] as? String, "colorwc")
        let colorData = try XCTUnwrap(color["data"] as? [String: Any])
        let rgb = try XCTUnwrap(colorData["color"] as? [String: Any])
        XCTAssertEqual(rgb["r"] as? Int, 0)
        XCTAssertEqual(rgb["g"] as? Int, 42)
        XCTAssertEqual(rgb["b"] as? Int, 255)
        XCTAssertEqual(colorData["colorTemInKelvin"] as? Int, 3_500)
    }

    func testGoveeResponseDecoding() {
        let scan = Data(#"{"msg":{"cmd":"scan","data":{"ip":"192.168.1.20","device":"AA:BB","sku":"H619A","deviceName":"Desk"}}}"#.utf8)
        let scanResponse = GoveeProtocol.decodeScanResponse(scan)
        XCTAssertEqual(scanResponse?.msg.data.ip, "192.168.1.20")
        XCTAssertEqual(scanResponse?.msg.data.device, "AA:BB")
        XCTAssertEqual(scanResponse?.msg.data.sku, "H619A")

        let status = Data(#"{"msg":{"cmd":"devStatus","data":{"onOff":1,"brightness":72,"color":{"r":1,"g":2,"b":3},"colorTemInKelvin":4200}}}"#.utf8)
        let statusResponse = GoveeProtocol.decodeStatusResponse(status)
        XCTAssertEqual(statusResponse?.msg.data.onOff, 1)
        XCTAssertEqual(statusResponse?.msg.data.brightness, 72)
        XCTAssertEqual(statusResponse?.msg.data.color?.g, 2)
        XCTAssertEqual(statusResponse?.msg.data.colorTemInKelvin, 4_200)
    }

    func testH612BDiscoveryResponseIsAccepted() {
        let response = Data(#"{"msg":{"cmd":"scan","data":{"ip":"192.168.1.44","device":"11:22:33:44:55:66","sku":"H612B","deviceName":"Strip Light S"}}}"#.utf8)
        let decoded = GoveeProtocol.decodeScanResponse(response)

        XCTAssertEqual(decoded?.msg.data.ip, "192.168.1.44")
        XCTAssertEqual(decoded?.msg.data.device, "11:22:33:44:55:66")
        XCTAssertEqual(decoded?.msg.data.sku, "H612B")
        XCTAssertEqual(decoded?.msg.data.deviceName, "Strip Light S")
    }

    func testSegmentCommandByteGeneration() {
        let color = GoveeProtocol.segmentColorPacket(r: 300, g: -1, b: 64, segments: [0, 8, 55, 56, -1])
        XCTAssertEqual(color.count, 20)
        XCTAssertEqual(Array(color.prefix(7)), [0x33, 0x05, 0x15, 0x01, 0xFF, 0x00, 0x40])
        XCTAssertEqual(color[12], 0x01)
        XCTAssertEqual(color[13], 0x01)
        XCTAssertEqual(color[18], 0x80)
        XCTAssertEqual(color[19], color.prefix(19).reduce(0, ^))

        let brightness = GoveeProtocol.segmentBrightnessPacket(percent: 0, segments: [0, 63, 111, 112])
        XCTAssertEqual(brightness.count, 20)
        XCTAssertEqual(Array(brightness.prefix(5)), [0x33, 0x05, 0x15, 0x02, 0x01])
        XCTAssertEqual(brightness[5], 0x01)
        XCTAssertEqual(brightness[12], 0x80)
        XCTAssertEqual(brightness[18], 0x80)
        XCTAssertEqual(brightness[19], brightness.prefix(19).reduce(0, ^))
    }

    func testMalformedResponsesAreRejected() {
        XCTAssertNil(LIFXProtocol.parse(Data(repeating: 0, count: 35)))
        var badLength = LIFXProtocol.packet(type: .getService, source: 1, target: Data(), payload: Data())
        badLength[0] = 0xFF
        badLength[1] = 0x7F
        XCTAssertNil(LIFXProtocol.parse(badLength))
        XCTAssertNil(LIFXProtocol.parseLightState(Data(repeating: 0, count: 51)))

        XCTAssertNil(GoveeProtocol.decodeScanResponse(Data("not json".utf8)))
        let wrongCommand = Data(#"{"msg":{"cmd":"devStatus","data":{"ip":"192.168.1.20","device":"AA:BB"}}}"#.utf8)
        XCTAssertNil(GoveeProtocol.decodeScanResponse(wrongCommand))
        XCTAssertNil(GoveeProtocol.decodeStatusResponse(Data(#"{"msg":{"cmd":"devStatus","data":{"onOff":1}}}"#.utf8)))
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func message(in data: Data) throws -> [String: Any] {
        let root = try jsonObject(data)
        return try XCTUnwrap(root["msg"] as? [String: Any])
    }
}
