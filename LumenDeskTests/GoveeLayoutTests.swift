import XCTest
import SwiftUI
@testable import LumenDesk

/// Glide chain mapping, per-pod white points, Luna level scaling and the
/// menu bar companion's rules. Pure functions only: nothing is sent.
final class GoveeLayoutTests: XCTestCase {

    // MARK: H6062 Glide chain

    func testSixPlusOneKitCoversEverySegmentOnce() {
        let chain = GlideChain.kitSixPlusOne
        XCTAssertEqual(chain.ledCount, 6 * 9 + 3)
        XCTAssertEqual(chain.barCount, 6)
        let ranges = chain.segmentRanges(segmentCount: 28)
        XCTAssertEqual(ranges.count, chain.pieces.count)
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, 28)
        for (a, b) in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(a.upperBound, b.lowerBound, "Ranges are contiguous and never overlap")
        }
        XCTAssertEqual(ranges.map(\.count).reduce(0, +), 28)
        // The corner (3 of 57 LEDs) still owns at least one segment.
        XCTAssertFalse(ranges[3].isEmpty)
        XCTAssertLessThan(ranges[3].count, ranges[0].count)
    }

    func testChainLabelsAndEmptyChain() {
        let chain = GlideChain.kitSixPlusOne
        XCTAssertEqual(chain.label(0), "Bar 1")
        XCTAssertEqual(chain.label(3), "Corner 1")
        XCTAssertEqual(chain.label(4), "Bar 4")
        XCTAssertEqual(GlideChain(pieces: []).segmentRanges(segmentCount: 28), [])
        XCTAssertEqual(GlideChain(pieces: [.bar]).segmentRanges(segmentCount: 28), [0..<28])
    }

    func testCornersTurnTheChain() {
        let right = GlideChain(pieces: [.bar, .cornerRight, .bar]).geometry()
        XCTAssertEqual(right.count, 3)
        // First bar runs along +x, the bar after a right corner along +y.
        XCTAssertEqual(right[0].end.x - right[0].start.x, 1, accuracy: 0.001)
        XCTAssertEqual(right[0].end.y - right[0].start.y, 0, accuracy: 0.001)
        XCTAssertEqual(right[2].end.x - right[2].start.x, 0, accuracy: 0.001)
        XCTAssertEqual(right[2].end.y - right[2].start.y, 1, accuracy: 0.001)
        let left = GlideChain(pieces: [.bar, .cornerLeft, .bar]).geometry()
        XCTAssertEqual(left[2].end.y - left[2].start.y, -1, accuracy: 0.001)
        // Each piece starts where the previous one ended.
        for (a, b) in zip(right, right.dropFirst()) {
            XCTAssertEqual(a.end.x, b.start.x, accuracy: 0.001)
            XCTAssertEqual(a.end.y, b.start.y, accuracy: 0.001)
        }
    }

    func testChainPersistsPerDevice() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        XCTAssertNil(GlideChainStore.load(deviceID: "glide", defaults: defaults))
        GlideChainStore.save(.kitEightPlusFour, deviceID: "glide", defaults: defaults)
        XCTAssertEqual(GlideChainStore.load(deviceID: "glide", defaults: defaults), .kitEightPlusFour)
        XCTAssertNil(GlideChainStore.load(deviceID: "other", defaults: defaults))
        GlideChainStore.save(nil, deviceID: "glide", defaults: defaults)
        XCTAssertNil(GlideChainStore.load(deviceID: "glide", defaults: defaults))
    }

    func testPaintingAPieceOnlyTouchesItsSegments() {
        var state = GoveeSegmentState(colors: (0..<28).map { _ in GoveeSegmentColor(hex: 0x0000FF, brightness: 0.5) })
        state.colors[20].isOn = false
        let range = GlideChain.kitSixPlusOne.segmentRanges(segmentCount: 28)[5]
        let next = GlideChainPainter.painting(state, range: range, color: Color(red: 1, green: 0, blue: 0))
        for index in 0..<28 {
            if range.contains(index) {
                XCTAssertEqual(next.colors[index].rgb255.r, 255)
                XCTAssertEqual(next.colors[index].brightness, 0.5, accuracy: 0.001, "Keeps the segment's level")
                XCTAssertEqual(next.colors[index].isOn, state.colors[index].isOn, "Keeps the segment's power")
            } else {
                XCTAssertEqual(next.colors[index], state.colors[index])
            }
        }
    }

    // MARK: H608B per-pod white

    func testSegmentWhitePacketEncoding() {
        let packet = GoveeProtocol.segmentWhitePacket(kelvin: 2_700, white: (r: 255, g: 167, b: 87), segments: [0, 2, 9])
        XCTAssertEqual(packet.count, 20)
        XCTAssertEqual(Array(packet.prefix(12)), [0x33, 0x05, 0x15, 0x01, 0xFF, 0xFF, 0xFF, 0x0A, 0x8C, 255, 167, 87])
        XCTAssertEqual(Array(packet[12..<19]), [0b0000_0101, 0b0000_0010, 0, 0, 0, 0, 0])
        XCTAssertEqual(packet[19], packet.prefix(19).reduce(0, ^), "Last byte is the XOR checksum")

        let daylight = GoveeProtocol.segmentWhitePacket(kelvin: 6_500, white: (r: 255, g: 255, b: 255), segments: [1])
        XCTAssertEqual(Array(daylight[7..<9]), [0x19, 0x64])
        XCTAssertEqual(GoveeProtocol.segmentWhitePacket(kelvin: 50_000, white: (0, 0, 0), segments: [0])[7..<9].map { $0 },
                       [0x23, 0x28], "Kelvin is clamped to 9000")
    }

    func testDurableApplySendsWhitesAsKelvinAndColoursAsRGB() {
        let state = GoveeSegmentState(colors: [.white(kelvin: 2_700), .white(kelvin: 2_700), GoveeSegmentColor(hex: 0xFF0000)])
        let packets = state.durableSegmentPackets(supportsGradient: false)
        let white = packets.first { $0.count > 8 && Array($0[4..<7]) == [0xFF, 0xFF, 0xFF] && Array($0[7..<9]) == [0x0A, 0x8C] }
        XCTAssertNotNil(white, "Pods holding a white point get the Kelvin segment packet")
        XCTAssertEqual(white?[12], 0b0000_0011, "Both 2700 K pods share one packet")
        let red = packets.first { $0.count > 6 && Array($0[0..<7]) == [0x33, 0x05, 0x15, 0x01, 0xFF, 0x00, 0x00] }
        XCTAssertNotNil(red, "A colour pod keeps the RGB packet")
    }

    func testWhiteSegmentsMixRGBAndRoundTrip() throws {
        let warm = GoveeSegmentColor.white(kelvin: 2_700)
        XCTAssertEqual(warm.kelvin, 2_700)
        XCTAssertGreaterThan(warm.red, warm.blue, "Warm white leans red")
        let cool = GoveeSegmentColor.white(kelvin: 6_500)
        XCTAssertGreaterThan(cool.blue, warm.blue)
        XCTAssertEqual(GoveeSegmentColor.white(kelvin: 200).kelvin, 1_000)

        let data = try JSONEncoder().encode(GoveeSegmentState(colors: [warm, GoveeSegmentColor(hex: 0x00FF00)]))
        let decoded = try JSONDecoder().decode(GoveeSegmentState.self, from: data)
        XCTAssertEqual(decoded.colors[0].kelvin, 2_700)
        XCTAssertNil(decoded.colors[1].kelvin)
    }

    func testPodWhitePointChips() {
        XCTAssertEqual(GoveeSegmentEditorView.whitePoints(in: 2_700...6_500), [2_700, 3_700, 4_600, 5_600, 6_500])
        XCTAssertEqual(GoveeSegmentProfile.detect(sku: "H608B")?.segmentWhiteRange, 2_700...6_500)
    }

    // MARK: LIFX Luna level

    private func lunaMatrix(_ levels: [UInt16]) -> LIFXMatrixState {
        let colors = levels.map { LIFXMatrixColor(hue: 1_000, saturation: 65_535, brightness: $0, kelvin: 3_500) }
        return LIFXMatrixState(productID: 219, width: 5, height: 6, colors: colors)
    }

    func testScaledMatrixKeepsRelativeLevels() {
        var levels = [UInt16](repeating: 20_000, count: 30)
        levels[7] = 10_000
        levels[8] = 0
        let matrix = lunaMatrix(levels)
        let scaled = LookDraftBuilder.scaledMatrix(matrix, from: 0.4, to: 0.8)
        XCTAssertEqual(scaled.colors[6].brightness, 40_000)
        XCTAssertEqual(scaled.colors[7].brightness, 20_000, "Half as bright as its neighbour, still")
        XCTAssertEqual(scaled.colors[8].brightness, 0, "A dark zone stays dark")
        XCTAssertEqual(scaled.zoneCount, 26)
        XCTAssertEqual(Array(scaled.colors[30...]), Array(matrix.colors[30...]), "Firmware-owned cells are untouched")
        XCTAssertEqual(scaled.colors[6].hue, matrix.colors[6].hue)
    }

    func testScaledMatrixStopsAtTheBrightestZone() {
        var levels = [UInt16](repeating: 30_000, count: 30)
        levels[12] = 60_000
        let scaled = LookDraftBuilder.scaledMatrix(lunaMatrix(levels), from: 0.3, to: 1.0)
        XCTAssertEqual(scaled.colors[12].brightness, 65_535)
        XCTAssertEqual(Double(scaled.colors[6].brightness), 30_000 * 65_535 / 60_000, accuracy: 1)
        let dimmed = LookDraftBuilder.scaledMatrix(lunaMatrix(levels), from: 1.0, to: 0.000001)
        XCTAssertEqual(dimmed.colors[6].brightness, 1, "A lit zone never rounds down to off")
    }

    func testLevelOnlyEditScalesTheLunaZones() {
        let matrix = lunaMatrix((0..<30).map { UInt16(10_000 + $0 * 1_000) })
        let original = LightingScene(name: "Moon", snapshots: [
            "luna": DeviceSnapshot(isOn: true, brightness: 0.5, hue: 0.1, saturation: 1, kelvin: 3_500, matrix: matrix)
        ])
        let opening = [LookDraftRow(id: "luna", included: true, rgb: LookDraftBuilder.rgb(hue: 0.1, saturation: 1), level: 0.5)]
        var edited = opening
        edited[0].level = 0.25
        let snap = LookDraftBuilder.snapshots(edited, kelvins: [:], original: original, originalRows: opening)["luna"]
        let saved = snap?.matrix
        XCTAssertNotNil(saved, "The Luna keeps its zones")
        XCTAssertEqual(saved?.width, 5)
        XCTAssertEqual(saved?.height, 6)
        XCTAssertEqual(saved?.zoneCount, 26)
        XCTAssertEqual(saved?.colors[6].brightness, matrix.colors[6].brightness / 2)
        XCTAssertEqual(saved?.colors[20].brightness, matrix.colors[20].brightness / 2)
        XCTAssertEqual(snap?.brightness ?? 0, 0.25, accuracy: 0.001)
    }

    // MARK: Menu bar companion

    func testRecentLooksPutTheLastAppliedFirst() {
        let old = LightingScene(name: "Old", snapshots: ["a": DeviceSnapshot(isOn: true, brightness: 1, hue: 0, saturation: 0)],
                                createdAt: Date(timeIntervalSince1970: 1))
        let new = LightingScene(name: "New", snapshots: ["a": DeviceSnapshot(isOn: true, brightness: 1, hue: 0, saturation: 0)],
                                createdAt: Date(timeIntervalSince1970: 3))
        let elsewhere = LightingScene(name: "Elsewhere", snapshots: ["z": DeviceSnapshot(isOn: true, brightness: 1, hue: 0, saturation: 0)],
                                      createdAt: Date(timeIntervalSince1970: 5))
        let looks = [old, new, elsewhere]
        XCTAssertEqual(MenuBarCompanion.recentLooks(looks, roomLightIDs: ["a"], lastAppliedID: nil).map(\.name), ["New", "Old"])
        XCTAssertEqual(MenuBarCompanion.recentLooks(looks, roomLightIDs: ["a"], lastAppliedID: old.id).map(\.name), ["Old", "New"])
        XCTAssertEqual(MenuBarCompanion.recentLooks(looks, roomLightIDs: ["a"], lastAppliedID: nil, limit: 1).map(\.name), ["New"])
        XCTAssertEqual(MenuBarCompanion.recentLooks(looks, roomLightIDs: [], lastAppliedID: nil), [])
    }

    func testPowerSummary() {
        XCTAssertEqual(MenuBarCompanion.powerSummary(on: 0, total: 0), "No lights yet")
        XCTAssertEqual(MenuBarCompanion.powerSummary(on: 0, total: 4), "All off")
        XCTAssertEqual(MenuBarCompanion.powerSummary(on: 1, total: 1), "On")
        XCTAssertEqual(MenuBarCompanion.powerSummary(on: 4, total: 4), "All 4 on")
        XCTAssertEqual(MenuBarCompanion.powerSummary(on: 2, total: 5), "2 of 5 on")
    }
}
