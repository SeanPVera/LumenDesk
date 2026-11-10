import XCTest
import SwiftUI
@testable import LumenDesk

/// H60B0 Uplighter: zone ↔ section mapping and the section packets.
/// Byte vectors are the ones SamWiIIiams/govee-lan-bridge's `test_bridge.py`
/// checks against frames verified on a real H60B0. Nothing is sent.
final class UplighterSectionTests: XCTestCase {

    private func hex(_ packet: [UInt8]?) -> String {
        (packet ?? []).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    func testZonesAreTheFirmwareSectionsInOrder() throws {
        let profile = try XCTUnwrap(GoveeSegmentProfile.detect(sku: "H60B0"))
        XCTAssertTrue(profile.usesUplighterSections)
        XCTAssertFalse(profile.appliesViaStream)
        XCTAssertEqual(profile.zoneNames, ["Ripple", "Side ring", "Down light"])
        XCTAssertEqual(UplighterSection.ripple.rawValue, 1)
        XCTAssertEqual(UplighterSection.side.rawValue, 2)
        XCTAssertEqual(UplighterSection.down.rawValue, 3)
        for section in UplighterSection.allCases {
            XCTAssertEqual(section.zoneIndex, Int(section.rawValue) - 1)
        }
        XCTAssertFalse(GoveeSegmentProfile.detect(sku: "H612B")?.usesUplighterSections ?? true)
    }

    func testSectionPacketsMatchTheVerifiedFrames() {
        XCTAssertEqual(hex(GoveeProtocol.uplighterSectionPowerPacket(.down, on: false)),
                       "33 30 03 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
        XCTAssertEqual(hex(GoveeProtocol.uplighterSectionPowerPacket(.ripple, on: true)),
                       "33 30 01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 03")
        XCTAssertEqual(hex(GoveeProtocol.uplighterDownKelvinPacket(2_700)),
                       "33 05 2c 03 01 0a 8c 00 00 00 00 00 00 00 00 00 00 00 00 9e")
        XCTAssertEqual(hex(GoveeProtocol.uplighterDownKelvinPacket(6_500)),
                       "33 05 2c 03 01 19 64 00 00 00 00 00 00 00 00 00 00 00 00 65")
        XCTAssertEqual(hex(GoveeProtocol.uplighterBrightnessPacket(.down, percent: 1)),
                       "33 05 2c 03 02 01 00 00 00 00 00 00 00 00 00 00 00 00 00 1a")
        XCTAssertEqual(hex(GoveeProtocol.uplighterBrightnessPacket(.ripple, percent: 100)),
                       "33 05 2c 01 02 64 00 00 00 00 00 00 00 00 00 00 00 00 00 7d")
        XCTAssertEqual(hex(GoveeProtocol.uplighterFlowPacket(55)),
                       "33 05 2c 01 03 37 00 00 00 00 00 00 00 00 00 00 00 00 00 2f")
        XCTAssertEqual(hex(GoveeProtocol.uplighterColorPacket(.ripple, rgb: (0, 255, 255))),
                       "33 05 2c 01 01 00 ff ff 00 00 00 00 00 00 00 00 00 00 00 1a")
    }

    func testSideRingCarriesItsSegmentMaskAndDownLightNeverTakesColour() {
        XCTAssertTrue(hex(GoveeProtocol.uplighterBrightnessPacket(.side, percent: 1)).hasPrefix("33 05 2c 02 02 01 ff"))
        XCTAssertTrue(hex(GoveeProtocol.uplighterColorPacket(.side, rgb: (255, 0, 0))).hasPrefix("33 05 2c 02 01 ff 00 00 00 00 ff"))
        XCTAssertNil(GoveeProtocol.uplighterColorPacket(.down, rgb: (255, 0, 0)))
        // Out-of-range white points are clamped (they black the lamp out).
        XCTAssertTrue(hex(GoveeProtocol.uplighterDownKelvinPacket(9_000)).hasPrefix("33 05 2c 03 01 19 64"))
        XCTAssertTrue(hex(GoveeProtocol.uplighterDownKelvinPacket(1_000)).hasPrefix("33 05 2c 03 01 0a 8c"))
        XCTAssertTrue(hex(GoveeProtocol.uplighterFlowPacket(300)).hasPrefix("33 05 2c 01 03 64"))
        for packet in [GoveeProtocol.uplighterFlowPacket(10), GoveeProtocol.uplighterSectionPowerPacket(.side, on: true)] {
            XCTAssertEqual(packet.count, 20)
            XCTAssertEqual(packet[19], packet.prefix(19).reduce(0, ^))
        }
    }

    /// Sean's report: the "lower" control lit the ripple. The down zone must
    /// address section 3 only, as a white point.
    func testDownLightZoneOnlyDrivesSectionThree() {
        let state = GoveeSegmentState(colors: [
            GoveeSegmentColor(hex: 0x0000FF, isOn: false),
            GoveeSegmentColor(hex: 0xFF00FF, isOn: false),
            .white(kelvin: 3_000, brightness: 0.4)
        ])
        let packets = state.uplighterSectionPackets().map(hex)
        XCTAssertEqual(packets.count, 5)
        XCTAssertTrue(packets[0].hasPrefix("33 30 01 00"))
        XCTAssertTrue(packets[1].hasPrefix("33 30 02 00"))
        XCTAssertTrue(packets[2].hasPrefix("33 30 03 01"))
        XCTAssertTrue(packets[3].hasPrefix("33 05 2c 03 01 0b b8 00"), "3000 K, no RGB bytes")
        XCTAssertTrue(packets[4].hasPrefix("33 05 2c 03 02 28"))
        XCTAssertFalse(packets.contains { $0.hasPrefix("33 05 2c 01") }, "nothing reaches the ripple")
    }

    func testRippleColourBrightnessAndFlow() {
        var state = GoveeSegmentState(colors: [
            GoveeSegmentColor(hex: 0x0000FF, brightness: 0.8),
            .white(kelvin: 4_600),
            GoveeSegmentColor(hex: 0xFFF2CC, isOn: false)
        ])
        state.rippleFlow = 30
        let packets = state.uplighterSectionPackets().map(hex)
        XCTAssertEqual(packets.first.map { $0.hasPrefix("33 30 03 00") }, true, "the dark section goes off first")
        XCTAssertTrue(packets.contains { $0.hasPrefix("33 30 01 01") })
        XCTAssertTrue(packets.contains { $0.hasPrefix("33 05 2c 01 01 00 00 ff 00 00") }, "ripple blue, plain colour")
        XCTAssertTrue(packets.contains { $0.hasPrefix("33 05 2c 01 02 50") })
        XCTAssertTrue(packets.contains { $0.hasPrefix("33 05 2c 01 03 1e") })
        // A white side ring carries its Kelvin (4600 = 11 f8) and the mask.
        XCTAssertTrue(packets.contains { $0.hasPrefix("33 05 2c 02 01") && $0.contains("11 f8 ff") })
        XCTAssertFalse(packets.contains { $0.hasPrefix("33 05 2c 03") }, "settings for a dark section aren't sent")
        XCTAssertLessThanOrEqual(packets.count, 12, "fits one ptReal datagram")
    }

    func testFlowIsLeftAloneUntilSet() {
        let state = GoveeSegmentState(colors: [GoveeSegmentColor(hex: 0x00FFFF), GoveeSegmentColor(hex: 0xFF0000),
                                               GoveeSegmentColor(hex: 0xFFFFFF, isOn: false)])
        XCTAssertFalse(state.uplighterSectionPackets().map(hex).contains { $0.hasPrefix("33 05 2c 01 03") })
    }

    func testLegacyColourOnTheDownLightBecomesItsNearestWhite() {
        XCTAssertEqual(GoveeSegmentState.uplighterKelvin(.white(kelvin: 3_500)), 3_500)
        let warm = KelvinRGB.components(2_700)
        XCTAssertEqual(KelvinRGB.nearestKelvin(red: warm.red, green: warm.green, blue: warm.blue), 2_700)
        let cool = KelvinRGB.components(6_500)
        XCTAssertEqual(KelvinRGB.nearestKelvin(red: cool.red * 0.3, green: cool.green * 0.3, blue: cool.blue * 0.3), 6_500,
                       "dimness doesn't change the white point")
        XCTAssertTrue((2_700...6_500).contains(GoveeSegmentState.uplighterKelvin(GoveeSegmentColor(hex: 0x0000FF))))
    }

    func testRippleFlowSurvivesSaving() throws {
        var state = GoveeSegmentState(colors: [GoveeSegmentColor(hex: 0x0000FF)])
        state.rippleFlow = 0
        let decoded = try JSONDecoder().decode(GoveeSegmentState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.rippleFlow, 0)
        let legacy = try JSONDecoder().decode(GoveeSegmentState.self,
                                              from: Data(#"{"colors":[],"gradient":false,"isActive":false}"#.utf8))
        XCTAssertNil(legacy.rippleFlow)
    }
}
