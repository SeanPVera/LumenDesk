import Foundation
import XCTest
@testable import LumenDesk

/// Foundation-only coverage for the Shapes topology, geometry, design and
/// wire formats. Expected bytes and layouts come from sources independent of
/// the code under test: Nanoleaf's OpenAPI examples, Hyperion's driver, and
/// layouts reported by real NL42 controllers.
final class NanoleafShapesTests: XCTestCase {

    // MARK: Fixtures

    /// Reported by an NL42 on firmware 9.2.0 (rjbs.cloud, 2023): two mini
    /// triangles and the controller entry, with the deprecated side length
    /// reading 27 even though the panels are 67-unit triangles.
    static let firmware92Layout = """
    {"name":"Shapes B77A","serialNo":"S1","model":"NL42","firmwareVersion":"9.2.0",
     "state":{"on":{"value":true},"brightness":{"value":100,"max":100,"min":0},"hue":{"value":0,"max":360,"min":0},
              "sat":{"value":0,"max":100,"min":0},"ct":{"value":2700,"max":6500,"min":1200},"colorMode":"effect"},
     "effects":{"select":"Beatdrop","effectsList":["Beatdrop"]},
     "panelLayout":{"globalOrientation":{"value":240,"max":360,"min":0},
       "layout":{"numPanels":3,"sideLength":27,"positionData":[
         {"panelId":22456,"x":73,"y":58,"o":0,"shapeType":9},
         {"panelId":9927,"x":106,"y":77,"o":60,"shapeType":9},
         {"panelId":0,"x":47,"y":73,"o":60,"shapeType":12}]}}}
    """

    /// Reported by an NL42 in the ioBroker adapter test thread: a hexagon, a
    /// mini triangle on one of its edges, and the controller, oriented 239°.
    static let hexagonAndTriangleLayout = """
    {"panelLayout":{"globalOrientation":{"value":239,"max":360,"min":0},
      "layout":{"numPanels":3,"sideLength":0,"positionData":[
        {"panelId":42956,"x":106,"y":38,"o":0,"shapeType":7},
        {"panelId":9127,"x":173,"y":0,"o":0,"shapeType":9},
        {"panelId":0,"x":47,"y":72,"o":60,"shapeType":12}]}}}
    """

    /// An asymmetric mixed wall that tiles without overlaps: hexagon 5120 in
    /// the middle, hexagons on its upper-right and upper-left edges, mini
    /// triangles on its lower-right and lower-left edges, and a full triangle
    /// hanging from its bottom edge. Every neighbour sits one apothem plus its
    /// own inradius away along an edge normal, turned so an edge faces back.
    /// Negative coordinates, non-contiguous IDs, listed out of ID order.
    static func mixedWall(reversed: Bool = false) -> Data {
        var entries = [
            #"{"panelId":5120,"x":0,"y":0,"o":0,"shapeType":7}"#,
            #"{"panelId":77,"x":100.5,"y":58.02,"o":0,"shapeType":7}"#,
            #"{"panelId":31000,"x":-100.5,"y":58.02,"o":120,"shapeType":7}"#,
            #"{"panelId":1204,"x":67,"y":-38.68,"o":0,"shapeType":9}"#,
            #"{"panelId":9,"x":-67,"y":-38.68,"o":0,"shapeType":9}"#,
            #"{"panelId":64001,"x":0,"y":-96.7,"o":60,"shapeType":8}"#,
            #"{"panelId":0,"x":-45,"y":105,"o":0,"shapeType":12}"#
        ]
        if reversed { entries.reverse() }
        return Data(#"{"panelLayout":{"globalOrientation":{"value":30,"max":360,"min":0},"layout":{"numPanels":7,"sideLength":0,"positionData":[\#(entries.joined(separator: ","))]}}}"#.utf8)
    }

    private func arrangement(_ json: String) throws -> NanoleafArrangement {
        try arrangement(Data(json.utf8))
    }

    private func arrangement(_ data: Data) throws -> NanoleafArrangement {
        switch NanoleafTopologyParser.parse(data) {
        case .success(let value): return value
        case .failure(let problem): XCTFail("Unexpected problem: \(problem)"); throw problem
        }
    }

    private func problem(_ json: String) -> NanoleafTopologyProblem? {
        if case .failure(let problem) = NanoleafTopologyParser.parse(Data(json.utf8)) { return problem }
        return nil
    }

    private func layoutJSON(_ entries: String, extra: String = "") -> String {
        #"{"panelLayout":{\#(extra)"layout":{"numPanels":2,"positionData":[\#(entries)]}}}"#
    }

    // MARK: Shape types

    func testShapeCodesFollowNanoleafsTable() {
        XCTAssertEqual(NanoleafShapeKind(code: 7), .hexagon)
        XCTAssertEqual(NanoleafShapeKind(code: 8), .triangle)
        XCTAssertEqual(NanoleafShapeKind(code: 9), .miniTriangle)
        XCTAssertEqual(NanoleafShapeKind(code: 12), .controller)
        XCTAssertEqual(NanoleafShapeKind(code: 5), .accessory(code: 5))
        XCTAssertEqual(NanoleafShapeKind(code: 2), .otherFamily(code: 2))
        XCTAssertEqual(NanoleafShapeKind(code: 99), .unknown(code: 99))
        XCTAssertEqual(NanoleafShapeKind(code: nil), .unspecified)
        XCTAssertEqual(NanoleafShapeKind.hexagon.sideLength, 67)
        XCTAssertEqual(NanoleafShapeKind.triangle.sideLength, 134)
        XCTAssertEqual(NanoleafShapeKind.miniTriangle.sideLength, 67)
        for code in [0, 1, 2, 3, 4, 5, 12, 14, 16, 17, 99] {
            XCTAssertFalse(NanoleafShapeKind(code: code).isPaintable, "type \(code) must never be painted")
            XCTAssertNil(NanoleafShapeKind(code: code).sideLength)
        }
        XCTAssertFalse(NanoleafShapeKind.unspecified.isPaintable)
    }

    // MARK: Parsing

    func testRealFirmwareLayoutKeepsTheControllerOutOfThePaintablePanels() throws {
        let value = try arrangement(Self.firmware92Layout)
        XCTAssertEqual(value.layout.panels.count, 3)
        XCTAssertEqual(value.layout.paintablePanels.map(\.panelID), [9927, 22456])
        XCTAssertEqual(value.layout.referenceEntries.map(\.kind), [.controller])
        XCTAssertFalse(value.layout.paintableIDs.contains(0))
        XCTAssertEqual(value.orientation, .reported(value: 240, minimum: 0, maximum: 360))
        XCTAssertEqual(value.globalOrientation, 240)
        XCTAssertEqual(value.layout.legacySideLength, 27)
        XCTAssertFalse(value.layout.isPossiblyIncomplete)
        XCTAssertTrue(value.layout.unsupportedEntries.isEmpty)
        XCTAssertEqual(value.layout.shapeSummary, "2 mini triangles")
    }

    func testReorderedResponsesProduceTheSamePanelsByIdentity() throws {
        let forward = try arrangement(Self.mixedWall())
        let backward = try arrangement(Self.mixedWall(reversed: true))
        XCTAssertEqual(forward.layout.paintablePanels, backward.layout.paintablePanels)
        XCTAssertEqual(forward.layout.paintablePanels.map(\.panelID), [9, 77, 1204, 5120, 31000, 64001])
        for panel in forward.layout.paintablePanels {
            XCTAssertEqual(NanoleafGeometry.outline(of: panel), NanoleafGeometry.outline(of: try XCTUnwrap(backward.layout.panel(withID: panel.panelID))))
        }
        XCTAssertEqual(forward.layout.shapeSummary, "3 hexagons, 2 mini triangles, 1 triangle")
    }

    func testMissingLayoutIsNotReportedRatherThanEmpty() {
        XCTAssertEqual(problem(#"{"name":"Shapes"}"#), .notReported)
        XCTAssertEqual(problem(#"{"panelLayout":{"globalOrientation":{"value":0}}}"#), .notReported)
        XCTAssertEqual(problem("not json"), .malformed("the response was not a JSON object"))
        XCTAssertEqual(problem(#"{"panelLayout":7}"#), .malformed("panelLayout was not an object"))
    }

    func testMalformedEntriesRejectTheWholeLayout() {
        let cases: [(String, String)] = [
            (#"{"panelLayout":{"layout":{"numPanels":1}}}"#, "positionData is missing"),
            (#"{"panelLayout":{"layout":{"positionData":{"panelId":1}}}}"#, "positionData is not a list"),
            (layoutJSON(#"{"panelId":1,"y":0,"o":0,"shapeType":7}"#), "panel 1 has no readable x position"),
            (layoutJSON(#"{"panelId":1,"x":"12","y":0,"o":0,"shapeType":7}"#), "panel 1 has no readable x position"),
            (layoutJSON(#"{"panelId":1,"x":true,"y":0,"o":0,"shapeType":7}"#), "panel 1 has no readable x position"),
            (layoutJSON(#"{"panelId":1,"x":0,"y":0,"shapeType":7}"#), "panel 1 has no readable orientation"),
            (layoutJSON(#"{"x":0,"y":0,"o":0,"shapeType":7}"#), "an entry has no readable panel ID"),
            (layoutJSON(#"{"panelId":70000,"x":0,"y":0,"o":0,"shapeType":7}"#), "a panel ID cannot be addressed"),
            (layoutJSON(#"{"panelId":-3,"x":0,"y":0,"o":0,"shapeType":7}"#), "a panel ID cannot be addressed"),
            (layoutJSON(#"{"panelId":4,"x":0,"y":0,"o":0,"shapeType":7},{"panelId":4,"x":1,"y":0,"o":0,"shapeType":9}"#), "panel ID 4 appears more than once"),
            (layoutJSON(#"{"panelId":4,"x":1e9,"y":0,"o":0,"shapeType":7}"#), "panel 4 is positioned outside any plausible wall"),
            (layoutJSON(#"{"panelId":4,"x":0,"y":0,"o":0,"shapeType":"hex"}"#), "panel 4 has an unreadable shape type"),
            (layoutJSON(#"7"#), "entry 1 is not a panel description")
        ]
        for (json, detail) in cases {
            XCTAssertEqual(problem(json), .malformed(detail), json)
        }
    }

    func testUnknownAndUnlabelledPartsAreKeptButNeverPainted() throws {
        let value = try arrangement(layoutJSON(#"{"panelId":3,"x":0,"y":0,"o":0},{"panelId":8,"x":90,"y":0,"o":0,"shapeType":99}"#))
        XCTAssertEqual(value.layout.panels.map(\.kind), [.unspecified, .unknown(code: 99)])
        XCTAssertTrue(value.layout.paintablePanels.isEmpty)
        XCTAssertEqual(value.layout.unsupportedEntries.count, 2)
        XCTAssertEqual(value.orientation, .notReported)
        XCTAssertNil(value.globalOrientation)
    }

    func testOrientationThatCannotBeReadIsNotReportedAsZero() throws {
        let value = try arrangement(layoutJSON(#"{"panelId":3,"x":0,"y":0,"o":0,"shapeType":7}"#,
                                               extra: #""globalOrientation":{"value":"up"},"#))
        XCTAssertEqual(value.orientation, .unreadable)
        XCTAssertNil(value.globalOrientation)
        let wrapped = try arrangement(layoutJSON(#"{"panelId":3,"x":0,"y":0,"o":0,"shapeType":7}"#,
                                                 extra: #""globalOrientation":{"value":360,"max":360,"min":0},"#))
        XCTAssertEqual(wrapped.globalOrientation, 0)
    }

    func testCountMismatchFlagsAPossiblyIncompleteLayout() throws {
        let value = try arrangement(#"{"panelLayout":{"layout":{"numPanels":5,"positionData":[{"panelId":3,"x":0,"y":0,"o":0,"shapeType":7}]}}}"#)
        XCTAssertTrue(value.layout.isPossiblyIncomplete)
    }

    func testTopologyChangesAreReportedByPanelID() throws {
        let before = try arrangement(Self.mixedWall()).layout
        var panels = before.panels.filter { $0.panelID != 77 }
        panels.append(NanoleafPanel(panelID: 4242, x: 200, y: 0, orientation: 0, shapeCode: 7))
        if let index = panels.firstIndex(where: { $0.panelID == 9 }) {
            panels[index] = NanoleafPanel(panelID: 9, x: -67, y: 38.7, orientation: 60, shapeCode: 9)
        }
        let after = NanoleafLayout(panels: panels)
        let change = NanoleafTopologyChange.between(before, after)
        XCTAssertEqual(change.added, [4242])
        XCTAssertEqual(change.removed, [77])
        XCTAssertEqual(change.moved, [9])
        XCTAssertEqual(change.summary, "1 panel added, 1 panel no longer reported, 1 panel moved")
        XCTAssertTrue(NanoleafTopologyChange.between(before, before).isEmpty)
        XCTAssertTrue(NanoleafTopologyChange.between(nil, before).isEmpty)
    }

    // MARK: Geometry

    private func assertPoint(_ point: NanoleafPoint, _ x: Double, _ y: Double, accuracy: Double = 0.01,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(point.x, x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(point.y, y, accuracy: accuracy, file: file, line: line)
    }

    func testOutlinesMatchNanoleafsVertexConvention() throws {
        let up = try XCTUnwrap(NanoleafGeometry.outline(of: NanoleafPanel(panelID: 1, x: 0, y: 0, orientation: 0, shapeCode: 8)))
        let radius = 134 / 3.0.squareRoot()
        assertPoint(up[0], 0, radius)
        assertPoint(up[1], -67, -radius / 2)
        assertPoint(up[2], 67, -radius / 2)
        let down = try XCTUnwrap(NanoleafGeometry.outline(of: NanoleafPanel(panelID: 2, x: 0, y: 0, orientation: 60, shapeCode: 8)))
        XCTAssertEqual(down.map(\.y).min() ?? 0, -radius, accuracy: 0.01)
        let hexagon = try XCTUnwrap(NanoleafGeometry.outline(of: NanoleafPanel(panelID: 3, x: 10, y: 20, orientation: 0, shapeCode: 7)))
        XCTAssertEqual(hexagon.count, 6)
        assertPoint(hexagon[0], 77, 20)
        XCTAssertNil(NanoleafGeometry.outline(of: NanoleafPanel(panelID: 0, x: 0, y: 0, orientation: 0, shapeCode: 12)))
        XCTAssertEqual(NanoleafGeometry.inradius(of: .hexagon) ?? 0, 58.02, accuracy: 0.01)
        XCTAssertEqual(NanoleafGeometry.inradius(of: .miniTriangle) ?? 0, 19.34, accuracy: 0.01)
    }

    /// Two edges are the same edge when both endpoints coincide, in either
    /// direction. Controllers report integer centroids, so allow a unit.
    private func sharedEdgeExists(_ a: [NanoleafPoint], _ b: [NanoleafPoint], tolerance: Double = 1.2) -> Bool {
        func close(_ p: NanoleafPoint, _ q: NanoleafPoint) -> Bool { hypot(p.x - q.x, p.y - q.y) <= tolerance }
        for i in a.indices {
            let a0 = a[i], a1 = a[(i + 1) % a.count]
            for j in b.indices {
                let b0 = b[j], b1 = b[(j + 1) % b.count]
                if (close(a0, b0) && close(a1, b1)) || (close(a0, b1) && close(a1, b0)) { return true }
            }
        }
        return false
    }

    func testReportedNeighboursShareEdgesUnderTheVertexConvention() throws {
        let triangles = try arrangement(Self.firmware92Layout).layout
        let a = try XCTUnwrap(NanoleafGeometry.outline(of: try XCTUnwrap(triangles.panel(withID: 22456))))
        let b = try XCTUnwrap(NanoleafGeometry.outline(of: try XCTUnwrap(triangles.panel(withID: 9927))))
        XCTAssertTrue(sharedEdgeExists(a, b), "Mini triangles reported side by side must share an edge")

        let mixed = try arrangement(Self.hexagonAndTriangleLayout).layout
        let hexagon = try XCTUnwrap(NanoleafGeometry.outline(of: try XCTUnwrap(mixed.panel(withID: 42956))))
        let mini = try XCTUnwrap(NanoleafGeometry.outline(of: try XCTUnwrap(mixed.panel(withID: 9127))))
        XCTAssertTrue(sharedEdgeExists(hexagon, mini), "A mini triangle reported on a hexagon edge must share it")

        // The alternative conventions do not line up, which is what pins this one.
        let pointyHexagon = NanoleafGeometry.polygon(center: NanoleafPoint(106, 38), circumradius: 67, firstVertexDegrees: 30, count: 6)
        XCTAssertFalse(sharedEdgeExists(pointyHexagon, mini))
        let flippedMini = NanoleafGeometry.polygon(center: NanoleafPoint(173, 0), circumradius: 67 / 3.0.squareRoot(), firstVertexDegrees: 30, count: 3)
        XCTAssertFalse(sharedEdgeExists(hexagon, flippedMini))
    }

    func testWallViewRotatesClockwiseLikeNanoleafsSDK() {
        let wall = NanoleafWallTransform(rotationDegrees: 90, pivot: NanoleafPoint(10, 20))
        // rotateAuroraPanels(layout, 90) moves (100, 0) to (0, -100).
        assertPoint(wall.wall(fromRaw: NanoleafPoint(110, 20)), 0, -100)
        assertPoint(wall.wall(fromRaw: NanoleafPoint(10, 120)), 100, 0)
        for degrees in [0.0, 37, 90, 239, 300, 359] {
            let transform = NanoleafWallTransform(rotationDegrees: degrees, pivot: NanoleafPoint(-3, 8))
            let point = NanoleafPoint(123.5, -77.25)
            assertPoint(transform.raw(fromWall: transform.wall(fromRaw: point)), point.x, point.y, accuracy: 1e-9)
        }
        XCTAssertEqual(NanoleafWallTransform(rotationDegrees: -90, pivot: NanoleafPoint(0, 0)).rotationDegrees, 270)
    }

    func testRotatingNeverChangesTheRawLayout() throws {
        let original = try arrangement(Self.mixedWall()).layout
        let before = original.paintablePanels
        for degrees in stride(from: 0.0, to: 360, by: 15) {
            _ = NanoleafCanvasMapping(layout: original, rotationDegrees: degrees, width: 500, height: 400)
            _ = original.spatialPositions(rotationDegrees: degrees, axis: .leftToRight)
        }
        XCTAssertEqual(original.paintablePanels, before)
    }

    func testEveryPanelIsSelectedWhereItIsDrawnAtEveryOrientation() throws {
        let layout = try arrangement(Self.mixedWall()).layout
        for degrees in [0.0, 30, 90, 180, 239, 300] {
            for fit in [NanoleafCanvasMapping.Fit.tight, .rotationStable] {
                let mapping = NanoleafCanvasMapping(layout: layout, rotationDegrees: degrees, width: 640, height: 420, fit: fit)
                for panel in layout.paintablePanels {
                    XCTAssertEqual(mapping.panelID(atScreen: mapping.screenCenter(of: panel), in: layout), panel.panelID,
                                   "panel \(panel.panelID) at \(degrees)°")
                    // Just inside a vertex still belongs to the same panel.
                    let outline = try XCTUnwrap(mapping.screenOutline(of: panel))
                    let center = mapping.screenCenter(of: panel)
                    let nearCorner = NanoleafPoint(center.x + (outline[0].x - center.x) * 0.8, center.y + (outline[0].y - center.y) * 0.8)
                    XCTAssertEqual(mapping.panelID(atScreen: nearCorner, in: layout), panel.panelID)
                }
                XCTAssertNil(mapping.panelID(atScreen: NanoleafPoint(1, 1), in: layout))
                let controller = try XCTUnwrap(layout.panel(withID: 0))
                XCTAssertNotEqual(mapping.panelID(atScreen: mapping.screenCenter(of: controller), in: layout), 0,
                                  "the controller marker is never a paint target")
            }
        }
    }

    func testTheCanvasFitsTheWallAndPutsTheWallsTopAtTheTop() throws {
        let layout = try arrangement(Self.mixedWall()).layout
        let mapping = NanoleafCanvasMapping(layout: layout, rotationDegrees: 0, width: 600, height: 400, inset: 20)
        let points = layout.panels.compactMap { mapping.screenOutline(of: $0) }.flatMap { $0 }
        XCTAssertGreaterThanOrEqual(points.map(\.x).min() ?? -1, 19.99)
        XCTAssertLessThanOrEqual(points.map(\.x).max() ?? 999, 580.01)
        XCTAssertGreaterThanOrEqual(points.map(\.y).min() ?? -1, 19.99)
        XCTAssertLessThanOrEqual(points.map(\.y).max() ?? 999, 380.01)
        // Raw +y is up on an unrotated wall, so it draws nearer the top.
        let high = try XCTUnwrap(layout.panel(withID: 77))   // y = 58
        let low = try XCTUnwrap(layout.panel(withID: 64001)) // y = -96.7
        XCTAssertLessThan(mapping.screenCenter(of: high).y, mapping.screenCenter(of: low).y)
        // Rotated a quarter turn clockwise, the panel to the right drops below.
        let quarter = NanoleafCanvasMapping(layout: layout, rotationDegrees: 90, width: 600, height: 600)
        let right = try XCTUnwrap(layout.panel(withID: 77))     // x = 100.5
        let left = try XCTUnwrap(layout.panel(withID: 31000))   // x = -100.5
        XCTAssertGreaterThan(quarter.screenCenter(of: right).y, quarter.screenCenter(of: left).y)
    }

    func testMarqueeSelectionUsesDrawnPositions() throws {
        let layout = try arrangement(Self.mixedWall()).layout
        let mapping = NanoleafCanvasMapping(layout: layout, rotationDegrees: 180, width: 600, height: 400)
        let target = try XCTUnwrap(layout.panel(withID: 1204))
        let center = mapping.screenCenter(of: target)
        let ids = mapping.panelIDs(inScreenRectFrom: NanoleafPoint(center.x + 5, center.y + 5),
                                   to: NanoleafPoint(center.x - 5, center.y - 5), in: layout)
        XCTAssertEqual(ids, [1204])
    }

    func testSpatialPositionsFollowTheWallNotTheResponseOrder() throws {
        let layout = try arrangement(Self.mixedWall()).layout
        let leftToRight = layout.spatialPositions(rotationDegrees: 0, axis: .leftToRight)
        XCTAssertEqual(leftToRight.first?.panelID, 31000)
        XCTAssertEqual(leftToRight.last?.panelID, 77)
        XCTAssertEqual(leftToRight.first?.position ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(leftToRight.last?.position ?? -1, 1, accuracy: 1e-9)
        let turned = layout.spatialPositions(rotationDegrees: 180, axis: .leftToRight)
        XCTAssertEqual(turned.first?.panelID, 77, "a half turn reverses left and right on the wall")
        let topDown = layout.spatialPositions(rotationDegrees: 0, axis: .topToBottom)
        XCTAssertEqual(topDown.first?.panelID, 77)
        XCTAssertEqual(topDown.last?.panelID, 64001)
        let around = layout.spatialPositions(rotationDegrees: 0, axis: .clockwise)
        XCTAssertTrue(around.allSatisfy { (0..<1).contains($0.position) })
        XCTAssertEqual(Set(around.map(\.panelID)), layout.paintableIDs)
        let outward = layout.spatialPositions(rotationDegrees: 0, axis: .outward)
        XCTAssertEqual(outward.last?.position ?? 0, 1, accuracy: 1e-9)
        XCTAssertTrue(NanoleafLayout(panels: []).spatialPositions(rotationDegrees: 0, axis: .clockwise).isEmpty)
    }

    // MARK: Colour and design

    func testTypedHexLandsOnTheWireUnchanged() {
        for r in stride(from: 0, through: 255, by: 5) {
            for g in stride(from: 0, through: 255, by: 15) {
                for b in stride(from: 0, through: 255, by: 17) {
                    let rgb = NanoleafRGB(red: UInt8(r), green: UInt8(g), blue: UInt8(b))
                    XCTAssertEqual(NanoleafPanelColor(rgb: rgb).rgb, rgb)
                }
            }
        }
        XCTAssertEqual(NanoleafPanelColor(hex: " #1a2B3c ")?.hexString, "#1A2B3C")
        XCTAssertEqual(NanoleafPanelColor(hex: "80FF00")?.rgb, NanoleafRGB(red: 128, green: 255, blue: 0))
        for bad in ["", "#12345", "#1234567", "#GG0000", "red"] { XCTAssertNil(NanoleafPanelColor(hex: bad), bad) }
    }

    func testIntensityScalesOutputOnceAndBlackIsBlack() {
        let red = NanoleafPanelColor(hue: 0, saturation: 1, intensity: 1)
        XCTAssertEqual(red.rgb, NanoleafRGB(red: 255, green: 0, blue: 0))
        XCTAssertEqual(red.settingIntensity(0.5).rgb, NanoleafRGB(red: 128, green: 0, blue: 0))
        XCTAssertEqual(red.settingIntensity(0.5).chroma, red.rgb)
        XCTAssertTrue(red.settingIntensity(0).isBlack)
        XCTAssertEqual(red.settingIntensity(0).hue, 0)
        XCTAssertEqual(NanoleafPanelColor(hue: 1.25, saturation: 2, intensity: -1),
                       NanoleafPanelColor(hue: 0.25, saturation: 1, intensity: 0))
        XCTAssertEqual(NanoleafPanelColor(hue: .nan, saturation: .infinity, intensity: .nan),
                       NanoleafPanelColor(hue: 0, saturation: 0, intensity: 0))
    }

    func testEditingOnePanelLeavesEveryOtherPanelAlone() throws {
        let layout = try arrangement(Self.mixedWall()).layout
        let white = NanoleafPanelColor.white
        var design = NanoleafPanelDesign.uniform(white, panelIDs: layout.paintableIDs)
        let before = design
        let blue = NanoleafPanelColor(hue: 0.66, saturation: 1, intensity: 1)
        design.paint(blue, panels: [1204])
        for id in layout.paintableIDs where id != 1204 { XCTAssertEqual(design[id], before[id]) }
        XCTAssertEqual(design[1204], blue)

        design.setIntensity(0.25, panels: [77, 9])
        XCTAssertEqual(design[77]?.intensity, 0.25)
        XCTAssertEqual(design[9]?.intensity, 0.25)
        XCTAssertEqual(design[5120], white)

        design.recolor(NanoleafPanelColor(hue: 0.33, saturation: 1, intensity: 1), panels: [77, 5120])
        XCTAssertEqual(design[77]?.intensity, 0.25, "recolouring keeps a dimmed panel dim")
        XCTAssertEqual(design[77]?.hue ?? 0, 0.33, accuracy: 1e-9)
        XCTAssertEqual(design[5120]?.intensity, 1)

        design.setIntensity(0, panels: [31000])
        let frames = design.frames(for: layout, transition: 1)
        XCTAssertEqual(frames.first { $0.panelID == 31000 }?.rgb, .black)
        XCTAssertEqual(frames.map(\.panelID), layout.paintablePanels.map(\.panelID))
        XCTAssertFalse(frames.contains { $0.panelID == 0 }, "the controller is never addressed")
    }

    func testDesignsReconcileByPanelIDAndRemapOnlyWhenAsked() throws {
        let layout = try arrangement(Self.mixedWall()).layout
        var design = NanoleafPanelDesign.uniform(.white, panelIDs: [9, 77, 5555])
        let reconciliation = design.reconciliation(against: layout)
        XCTAssertEqual(reconciliation.covered, [9, 77])
        XCTAssertEqual(reconciliation.missing, [5555])
        XCTAssertEqual(reconciliation.uncovered, [1204, 5120, 31000, 64001])
        XCTAssertEqual(reconciliation.summary, "1 panel is no longer on the wall; 4 panels aren't in this design and will show dark.")
        let frames = design.frames(for: layout, transition: 3)
        XCTAssertEqual(frames.count, layout.paintablePanels.count)
        XCTAssertEqual(frames.first { $0.panelID == 1204 }?.rgb, .black)
        XCTAssertFalse(frames.contains { $0.panelID == 5555 })
        design.remap(from: 5555, to: 1204)
        XCTAssertNil(design[5555])
        XCTAssertEqual(design[1204], .white)
    }

    func testADesignSummarisesAsTheChromaCoveringMostLitPanels() throws {
        let layout = try arrangement(Self.mixedWall()).layout
        let orange = NanoleafPanelColor(hex: "#FF8000")!
        var design = NanoleafPanelDesign.uniform(orange, panelIDs: [9, 77])
        design.paint(orange.settingIntensity(0.3), panels: [1204]) // same chroma, dimmer
        design.paint(NanoleafPanelColor(hex: "#0040FF")!, panels: [5120, 31000])
        design.paint(.black, panels: [64001])
        XCTAssertEqual(design.representativeChroma, NanoleafRGB(hex: "#FF8000"),
                       "intensity does not split a colour: three orange panels outvote two blue")
        XCTAssertTrue(design.lightsAnyPanel(of: layout))
        let dark = NanoleafPanelDesign.uniform(.black, panelIDs: layout.paintableIDs)
        XCTAssertNil(dark.representativeChroma)
        XCTAssertFalse(dark.lightsAnyPanel(of: layout))
        XCTAssertFalse(NanoleafPanelDesign.uniform(.white, panelIDs: [5555]).lightsAnyPanel(of: layout),
                       "a panel the wall no longer has lights nothing")
    }

    func testTheEditorDrawsOnlyColoursItCanJustify() throws {
        let layout = try arrangement(Self.mixedWall()).layout
        let orange = NanoleafRGB(hex: "#FF8000")!
        let sent: [Int: NanoleafRGB] = [9: orange, 5555: orange]
        let design = NanoleafDisplayFixtures.design

        let draft = NanoleafPanelDisplay.resolve(layout: layout, output: .nativeEffect(name: "Forest"),
                                                 lastSent: sent, draft: design, wholeWall: nil)
        XCTAssertEqual(draft.source, .draft, "an open draft is what the editor shows, whatever is playing")
        XCTAssertEqual(draft.colors.count, layout.paintablePanels.count)

        let shown = NanoleafPanelDisplay.resolve(layout: layout, output: .design(confirmed: true),
                                                 lastSent: sent, draft: nil, wholeWall: nil)
        XCTAssertEqual(shown.source, .sent)
        XCTAssertEqual(shown.colors, [9: orange], "a panel the wall no longer has is not drawn")

        let white = NanoleafRGB.approximatingKelvin(2700)
        let solid = NanoleafPanelDisplay.resolve(layout: layout, output: .white, lastSent: sent, draft: nil, wholeWall: white)
        XCTAssertEqual(solid.source, .wholeWall)
        XCTAssertEqual(Set(solid.colors.values), [white])
        XCTAssertEqual(solid.colors.count, layout.paintablePanels.count)
        XCTAssertEqual(NanoleafPanelDisplay.resolve(layout: layout, output: .solid, lastSent: [:], draft: nil, wholeWall: nil).source,
                       .unknown, "without the whole-wall colour a solid wall is not guessed")

        let off = NanoleafPanelDisplay.resolve(layout: layout, output: .off, lastSent: sent, draft: nil, wholeWall: white)
        XCTAssertEqual(off.source, .off)
        XCTAssertEqual(Set(off.colors.values), [.black])

        for output: NanoleafOutputState in [.unknown, .nativeEffect(name: "Forest"), .external("Other app")] {
            let unknown = NanoleafPanelDisplay.resolve(layout: layout, output: output, lastSent: sent, draft: nil, wholeWall: white)
            XCTAssertEqual(unknown.source, .unknown)
            XCTAssertTrue(unknown.colors.isEmpty, "\(output) never draws last-sent colours as if they were showing")
        }
    }

    func testWhitePointsAndMasterBrightnessPreviewSensibly() {
        let warm = NanoleafRGB.approximatingKelvin(2700)
        XCTAssertEqual(warm.red, 255)
        XCTAssertGreaterThan(warm.red, warm.green)
        XCTAssertGreaterThan(warm.green, warm.blue)
        let daylight = NanoleafRGB.approximatingKelvin(6500)
        XCTAssertGreaterThanOrEqual(min(daylight.red, daylight.green, daylight.blue), 240)
        XCTAssertLessThan(NanoleafRGB.approximatingKelvin(1800).blue, warm.blue)
        XCTAssertEqual(NanoleafRGB(red: 200, green: 100, blue: 0).scaled(by: 0.5), NanoleafRGB(red: 100, green: 50, blue: 0))
        XCTAssertEqual(NanoleafRGB(red: 200, green: 100, blue: 0).scaled(by: .nan), .black)
    }

    func testPanelsAreNumberedAlongTheWallAsOrientedAndFillSelectionsInOrder() throws {
        let layout = try arrangement(Self.mixedWall()).layout
        XCTAssertEqual(layout.panelNumbers(rotationDegrees: 0),
                       [31000: 1, 9: 2, 5120: 3, 64001: 4, 1204: 5, 77: 6])
        XCTAssertEqual(layout.panelNumbers(rotationDegrees: 180),
                       [77: 1, 1204: 2, 5120: 3, 64001: 4, 9: 5, 31000: 6])
        let tones: [(hue: Double, saturation: Double, level: Double)] = [(0, 1, 1), (1.0 / 3, 1, 1), (2.0 / 3, 1, 0.5)]
        let filled = NanoleafDesignBuilder.colors(tones: tones, panels: [77, 9, 5120], layout: layout, rotationDegrees: 0)
        XCTAssertEqual(filled[9]?.rgb, NanoleafRGB(red: 255, green: 0, blue: 0))
        XCTAssertEqual(filled[5120]?.rgb, NanoleafRGB(red: 0, green: 255, blue: 0))
        XCTAssertEqual(filled[77]?.rgb, NanoleafRGB(red: 0, green: 0, blue: 128))
        XCTAssertNil(filled[31000], "panels outside the selection are left alone")
    }

    func testDesignsRoundTripAndRejectDamagedEntries() throws {
        var design = NanoleafPanelDesign.uniform(NanoleafPanelColor(hue: 0.1, saturation: 0.5, intensity: 0.7), panelIDs: [3, 1, 2])
        design.paint(.black, panels: [2])
        let data = try JSONEncoder().encode(design)
        XCTAssertEqual(try JSONDecoder().decode(NanoleafPanelDesign.self, from: data), design)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""panels""#))
        let duplicate = Data(#"{"panels":[{"id":1,"hue":0,"saturation":0,"intensity":1},{"id":1,"hue":0,"saturation":0,"intensity":0}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(NanoleafPanelDesign.self, from: duplicate))
        let outOfRange = Data(#"{"panels":[{"id":99999,"hue":0,"saturation":0,"intensity":1}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(NanoleafPanelDesign.self, from: outOfRange))
    }

    func testDamagedShapesEntriesAreDroppedOneAtATime() throws {
        let designs = #"{"kept":{"panels":[{"id":1,"hue":0,"saturation":0,"intensity":1}]},"duplicate":{"panels":[{"id":1,"hue":0,"saturation":0,"intensity":1},{"id":1,"hue":0,"saturation":0,"intensity":0}]},"number":7}"#
        let decodedDesigns = try JSONDecoder().decode(LossyDictionary<NanoleafPanelDesign>.self, from: Data(designs.utf8))
        XCTAssertEqual(Array(decodedDesigns.values.keys), ["kept"])

        let saved = NanoleafSavedDesign(name: "Keep", deviceID: "nanoleaf:S1", design: .uniform(.white, panelIDs: [1]))
        let savedJSON = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
        let list = "[7, \(savedJSON), \"junk\", {\"name\":\"broken\"}, [1,2], null, \(savedJSON)]"
        let decodedList = try JSONDecoder().decode(LossyArray<NanoleafSavedDesign>.self, from: Data(list.utf8))
        XCTAssertEqual(decodedList.values, [saved, saved], "every readable entry survives, in order, past any damage")
    }

    // MARK: Wire formats

    func testStaticAnimDataMatchesNanoleafsDocumentedExample() throws {
        // OpenAPI 3.2.6.1 "Temporary static display".
        let documented = "3 82 1 255 0 255 0 20 60 1 0 255 255 0 20 118 1 0 0 0 0 20"
        let frames = [
            NanoleafPanelFrame(panelID: 82, rgb: NanoleafRGB(red: 255, green: 0, blue: 255), transition: 20),
            NanoleafPanelFrame(panelID: 60, rgb: NanoleafRGB(red: 0, green: 255, blue: 255), transition: 20),
            NanoleafPanelFrame(panelID: 118, rgb: .black, transition: 20)
        ]
        XCTAssertEqual(NanoleafAnimData.staticString(frames), documented)
        let parsed = try NanoleafAnimData.parse(documented)
        XCTAssertEqual(parsed[60], [.init(rgb: NanoleafRGB(red: 0, green: 255, blue: 255), white: 0, transition: 20)])
        XCTAssertEqual(try NanoleafAnimData.settledColors(documented)[82], NanoleafRGB(red: 255, green: 0, blue: 255))
    }

    func testCustomAnimDataFromTheDocumentedLibraryParses() throws {
        // OpenAPI 3.2.4.4, the "Slow" custom effect.
        let slow = "7 224 7 0 0 0 0 0 0 0 0 255 5 0 0 0 0 5 0 0 0 255 5 0 0 0 0 5 0 0 0 255 5 0 0 0 0 5 89 2 0 0 0 0 0 255 0 0 0 10 210 2 0 0 0 0 0 255 255 0 0 15 116 2 0 0 0 0 0 0 255 0 0 20 173 2 0 0 0 0 0 0 255 255 0 25 126 2 0 0 0 0 0 0 0 255 0 30 81 2 0 0 0 0 0 255 0 255 0 35"
        let parsed = try NanoleafAnimData.parse(slow)
        XCTAssertEqual(parsed.count, 7)
        XCTAssertEqual(parsed[224]?.count, 7)
        XCTAssertEqual(parsed[81]?.last, .init(rgb: NanoleafRGB(red: 255, green: 0, blue: 255), white: 0, transition: 35))
        for bad in ["2 1 1 0 0 0 0 1", "1 1 1 256 0 0 0 1", "1 1 1 0 0 0 0 1 9", "1 1 1 0 0 0 0 -2", "x", "2 5 1 0 0 0 0 1 5 1 0 0 0 0 1"] {
            XCTAssertThrowsError(try NanoleafAnimData.parse(bad), bad)
        }
    }

    func testStreamPacketMatchesNanoleafsDocumentedV2Bytes() {
        // OpenAPI 3.2.6.2: panels 374, 651 and 235 as a v2 byte stream.
        let frames = [
            NanoleafPanelFrame(panelID: 374, rgb: NanoleafRGB(red: 255, green: 0, blue: 255), transition: 12),
            NanoleafPanelFrame(panelID: 651, rgb: NanoleafRGB(red: 255, green: 255, blue: 0), transition: 128),
            NanoleafPanelFrame(panelID: 235, rgb: NanoleafRGB(red: 0, green: 255, blue: 255), transition: 451)
        ]
        let documented: [UInt8] = [0x00, 0x03, 0x01, 0x76, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x0C,
                                   0x02, 0x8B, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x80,
                                   0x00, 0xEB, 0x00, 0xFF, 0xFF, 0x00, 0x01, 0xC3]
        XCTAssertEqual([UInt8](NanoleafStreamPacket.encode(frames)), documented)
        XCTAssertEqual([UInt8](NanoleafStreamPacket.encode([])), [0, 0])
        XCTAssertEqual(NanoleafStreamPacket.defaultPort, 60222)
        XCTAssertEqual(NanoleafStreamPacket.minimumFrameInterval, 0.1)
    }

    private func object(_ body: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testRequestBodiesMatchTheDocumentedContracts() throws {
        XCTAssertEqual(try object(NanoleafCommand.orientation(120)) as NSDictionary,
                       ["globalOrientation": ["value": 120]] as NSDictionary)
        XCTAssertEqual(try object(NanoleafCommand.select("Northern Lights")) as NSDictionary, ["select": "Northern Lights"] as NSDictionary)
        // Hyperion's driver sends exactly this string to start v2 streaming.
        let hyperion = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"{"write" : {"command" : "display", "animType" : "extControl", "extControlVersion" : "v2"}}"#.utf8)) as? [String: Any])
        XCTAssertEqual(try object(NanoleafCommand.externalControl) as NSDictionary, hyperion as NSDictionary)

        let frames = [NanoleafPanelFrame(panelID: 9, rgb: NanoleafRGB(red: 1, green: 2, blue: 3), transition: 1)]
        let display = try XCTUnwrap(try object(NanoleafCommand.displayStatic(frames))["write"] as? [String: Any])
        XCTAssertEqual(display["command"] as? String, "display")
        XCTAssertEqual(display["animType"] as? String, "static")
        XCTAssertEqual(display["animData"] as? String, "1 9 1 1 2 3 0 1")
        XCTAssertEqual(display["loop"] as? Bool, false)
        XCTAssertNil(display["animName"], "a preview is never stored under a name")
        let add = try XCTUnwrap(try object(NanoleafCommand.addStatic(name: "Evening", frames: frames))["write"] as? [String: Any])
        XCTAssertEqual(add["command"] as? String, "add")
        XCTAssertEqual(add["animName"] as? String, "Evening")
    }

    func testPanelIdentificationIsTemporaryAndOnlyTouchesLightPanels() throws {
        let layout = try arrangement(Self.mixedWall()).layout
        let write = try XCTUnwrap(try object(NanoleafCommand.identifyPanel(1204, in: layout, seconds: 90))["write"] as? [String: Any])
        XCTAssertEqual(write["command"] as? String, "displayTemp")
        XCTAssertEqual(write["duration"] as? Int, 30)
        let frames = try NanoleafAnimData.parse(try XCTUnwrap(write["animData"] as? String))
        XCTAssertEqual(Set(frames.keys), layout.paintableIDs)
        XCTAssertEqual(frames[1204]?.count, 2)
        XCTAssertTrue(frames.filter { $0.key != 1204 }.values.allSatisfy { $0.count == 1 })
        XCTAssertTrue(frames.values.flatMap { $0 }.allSatisfy { $0.transition >= 3 }, "no hard cuts: every change fades")
    }

    // MARK: Output, orientation and editing state

    func testOutputIsAttributedOnlyToWhatLumenDeskActuallySent() {
        let list = ["Northern Lights", "Evening"]
        func state(_ on: Bool = true, _ mode: String = "effect", _ select: String, _ claim: NanoleafOutputClaim?) -> NanoleafOutputState {
            .reported(isOn: on, colorMode: mode, selectedEffect: select, effectsList: list, claim: claim)
        }
        XCTAssertEqual(state(false, "effect", "*Static*", .design), .off)
        XCTAssertEqual(state(true, "hs", "*Solid*", .design), .solid)
        XCTAssertEqual(state(true, "ct", "Evening", nil), .white)
        XCTAssertEqual(state(true, "effect", "*Static*", .design), .design(confirmed: true))
        XCTAssertEqual(state(true, "effect", "*Static*", .preview), .preview)
        XCTAssertEqual(state(true, "effect", "*Static*", nil), .external("A static layout LumenDesk can\u{2019}t account for"))
        XCTAssertEqual(state(true, "effect", "*ExtControl*", .stream(owner: "music")), .stream(owner: "music"))
        XCTAssertEqual(state(true, "effect", "*ExtControl*", nil), .external("A live stream LumenDesk isn\u{2019}t sending"))
        XCTAssertEqual(state(true, "effect", "*Dynamic*", .design), .external("A temporary animated scene from another app"))
        XCTAssertEqual(state(true, "effect", "Evening", .design), .nativeEffect(name: "Evening"),
                       "a scene chosen elsewhere supersedes LumenDesk's claim")
        XCTAssertFalse(NanoleafOutputState.nativeEffect(name: "Evening").panelColorsAreKnown)
        XCTAssertTrue(NanoleafOutputState.design(confirmed: false).panelColorsAreKnown)
    }

    func testOrientationIsConfirmedOnlyByAReadingAfterTheWrite() {
        var state = NanoleafOrientationState()
        XCTAssertEqual(state.status, .unknown)
        state.read(240)
        XCTAssertEqual(state.status, .confirmed(240))
        state.request(-265)
        XCTAssertEqual(state.status, .pending(requested: 95))
        state.read(240) // a reading from before the write landed
        XCTAssertEqual(state.status, .pending(requested: 95))
        state.writeAccepted()
        state.read(95)
        XCTAssertEqual(state.status, .confirmed(95))

        state.request(10)
        state.writeAccepted()
        state.read(15)
        XCTAssertEqual(state.status, .differs(requested: 10, reported: 15))
        state.read(30) // changed later in the Nanoleaf app
        XCTAssertEqual(state.status, .confirmed(30))

        state.request(20)
        XCTAssertEqual(state.summary, "20° requested · waiting for the controller to confirm")
        state.writeFailed("HTTP 422")
        state.read(30)
        XCTAssertEqual(state.status, .failed(requested: 20, reason: "HTTP 422"))
        XCTAssertTrue(state.isFailed)
        XCTAssertEqual(state.summary, "20° not applied · HTTP 422")
        state.clearFailure()
        XCTAssertEqual(state.status, .confirmed(30))
        XCTAssertFalse(state.isFailed)
        XCTAssertEqual(state.summary, "30° · read back from the controller")
    }

    func testEditingHistoryUndoesWholeGesturesAndNeverRecordsNoOps() throws {
        let layout = try arrangement(Self.mixedWall()).layout
        var session = NanoleafEditingSession(draft: .uniform(.white, panelIDs: layout.paintableIDs), origin: .uniform(.white))
        XCTAssertFalse(session.hasUnappliedChanges)
        session.edit { $0.paint(.white, panels: [9]) }
        XCTAssertFalse(session.canUndo, "an edit that changes nothing is not a step")
        let red = NanoleafPanelColor(hue: 0, saturation: 1, intensity: 1)
        session.edit { $0.paint(red, panels: [9]) }
        XCTAssertTrue(session.hasUnappliedChanges)

        session.beginContinuousEdit()
        for step in 1...10 { session.edit { $0.setIntensity(Double(step) / 20, panels: [77]) } }
        session.endContinuousEdit()
        XCTAssertEqual(session.undoStack.count, 2, "a whole slider drag is one step")
        session.undo()
        XCTAssertEqual(session.draft[77], .white)
        XCTAssertEqual(session.draft[9], red)
        session.redo()
        XCTAssertEqual(session.draft[77]?.intensity, 0.5)

        // A drag that ends where it started records nothing at all.
        session.beginContinuousEdit()
        session.edit { $0.setIntensity(0.2, panels: [77]) }
        session.edit { $0.setIntensity(0.5, panels: [77]) }
        session.endContinuousEdit()
        XCTAssertEqual(session.undoStack.count, 2)
        session.undo()
        session.undo()
        XCTAssertEqual(session.draft, .uniform(.white, panelIDs: layout.paintableIDs))
        XCTAssertFalse(session.canUndo)
        session.redo()
        session.markApplied()
        XCTAssertFalse(session.hasUnappliedChanges)

        for step in 0..<150 { session.edit { $0.setIntensity(Double(step % 100) / 100, panels: [5120]) } }
        XCTAssertEqual(session.undoStack.count, NanoleafEditingSession.historyLimit)
    }

    func testSelectionFollowsTheWallAndToolsNeverSilentlyDoNothing() throws {
        let layout = try arrangement(Self.mixedWall()).layout
        var session = NanoleafEditingSession(draft: NanoleafPanelDesign(), origin: .uniform(.black))
        XCTAssertEqual(session.targets(in: layout), layout.paintableIDs)
        session.selection = [9, 4242, 0]
        XCTAssertEqual(session.targets(in: layout), [9])
        XCTAssertEqual(session.reconcileSelection(with: layout), [0, 4242])
        XCTAssertEqual(session.selection, [9])
    }

    func testArrowKeysMoveAcrossTheWallAsOriented() throws {
        let layout = try arrangement(Self.mixedWall()).layout
        XCTAssertEqual(layout.neighbor(of: 5120, toward: .right, rotationDegrees: 0), 1204)
        XCTAssertEqual(layout.neighbor(of: 5120, toward: .down, rotationDegrees: 0), 64001)
        XCTAssertEqual(layout.neighbor(of: 1204, toward: .left, rotationDegrees: 0), 5120)
        XCTAssertEqual(layout.neighbor(of: 5120, toward: .right, rotationDegrees: 180), 9, "a half turn swaps the sides")
        XCTAssertEqual(layout.neighbor(of: 64001, toward: .down, rotationDegrees: 0), nil)
        XCTAssertEqual(layout.neighbor(of: 424242, toward: .down, rotationDegrees: 0), 9, "an unknown start picks the first panel")
    }

    func testDesignsBuiltFromGradientsTonesAndStoredScenes() throws {
        let layout = try arrangement(Self.mixedWall()).layout
        let red = NanoleafPanelColor(hex: "#FF0000")!, blue = NanoleafPanelColor(hex: "#0000FF")!
        let ramp = NanoleafDesignBuilder.gradient(from: red, to: blue, panels: [31000, 5120, 77],
                                                  layout: layout, rotationDegrees: 0, axis: .leftToRight)
        XCTAssertEqual(ramp[31000]?.rgb, red.rgb)
        XCTAssertEqual(ramp[77]?.rgb, blue.rgb)
        XCTAssertEqual(ramp[5120]?.rgb, NanoleafRGB(red: 128, green: 0, blue: 128))
        XCTAssertEqual(ramp.count, 3)

        let tones: [(hue: Double, saturation: Double, level: Double)] = [(0.1, 1, 1), (0.5, 1, 0.5)]
        let themed = NanoleafDesignBuilder.design(tones: tones, layout: layout, rotationDegrees: 0)
        XCTAssertEqual(Set(themed.panelIDs), layout.paintableIDs)
        XCTAssertEqual(themed[31000]?.hue ?? 0, 0.1, accuracy: 1e-9, "the first tone lands on the left of the wall")
        XCTAssertEqual(themed[77]?.intensity, 0.5)

        let stored = NanoleafDesignBuilder.design(staticColors: [5: NanoleafRGB(red: 10, green: 20, blue: 30)])
        XCTAssertEqual(stored[5]?.rgb, NanoleafRGB(red: 10, green: 20, blue: 30))
    }

    // MARK: Event stream

    func testEventStreamEventsAreReadWithOrWithoutBlankSeparators() {
        // Payload shapes from OpenAPI 3.5.2. Separators are omitted between
        // some events, as a line reader that skips blank lines would deliver.
        let lines = [
            "id: 3", #"data: {"events":[{"attr":1,"value":"Flames"}]}"#, "",
            "id: 4\r", #"data: {"events":[{"gesture":0,"panelId":7},{"gesture":3,"panelId":-1},{"gesture":9,"panelId":2}]}"#,
            "id: 2", #"data: {"events":[{"attr":2,"value":90}]}"#,
            ": keep-alive",
            "id: 1", #"data:{"events":[{"attr":2,"value":40}]}"#,
            "", #"data: {"events":[{"attr":1,"value":"Orphan"}]}"#,
            "id: 9", #"data: {"events":[]}"#,
            "id: 3", "data: not json"
        ]
        var parser = NanoleafEventStreamParser()
        let events = lines.flatMap { parser.consume(line: $0) }
        XCTAssertEqual(events, [
            .effectChanged("Flames"),
            .touch(gesture: .singleTap, panelID: 7),
            .touch(gesture: .swipeDown, panelID: nil),
            .layoutChanged,
            .stateChanged,
            .effectChanged(nil)
        ])
    }

    // MARK: Effect library

    /// OpenAPI 3.2.4.4 and 3.2.4.1 examples: a custom effect, a highlight
    /// effect, and a plugin effect with options.
    static let library = """
    {"animations":[
      {"loop":true,"version":"1.0","animName":"Slow","animType":"custom","animData":"2 1 2 0 0 0 0 5 255 0 0 0 5 2 1 0 255 0 0 5"},
      {"loop":true,"version":"1.0","animName":"Flames","animType":"highlight","colorType":"HSB","animData":null,
       "palette":[{"hue":30,"saturation":100,"brightness":100,"probability":58}],
       "brightnessRange":{"minValue":40,"maxValue":100}},
      {"version":"2.0","animType":"plugin","animName":"My Animation","colorType":"HSB",
       "pluginUuid":"027842e4-e1d6-4a4c-a731-be74a1ebd4cf","pluginType":"color",
       "pluginOptions":[{"name":"transTime","value":2},{"name":"direction","value":"left"},{"name":"loop","value":true}],
       "palette":[{"hue":0,"saturation":100,"brightness":100},{"hue":120,"saturation":100,"brightness":100}]},
      {"version":"2.0","animType":"static","animName":"Painted","animData":"1 5 1 10 20 30 0 1"},
      {"animType":"plugin","pluginType":"rhythm","animName":"Meteor Shower","pluginUuid":"23e70ff4-458c-4852-826f-9315d89ee6ed","palette":[]},
      {"animType":"random"}
    ]}
    """

    func testEffectLibraryParsesCategoriesOptionsAndStaticColours() throws {
        let effects = try NanoleafEffectDefinition.parseLibrary(Data(Self.library.utf8))
        XCTAssertEqual(effects.map(\.name), ["Slow", "Flames", "My Animation", "Painted", "Meteor Shower"])
        XCTAssertEqual(effects.map(\.category), [.dynamic, .dynamic, .dynamic, .staticDesign, .rhythm])
        let plugin = effects[2]
        XCTAssertEqual(plugin.options, [
            NanoleafEffectOption(name: "transTime", value: .int(2)),
            NanoleafEffectOption(name: "direction", value: .string("left")),
            NanoleafEffectOption(name: "loop", value: .bool(true))
        ])
        XCTAssertTrue(plugin.hasEditableParameters)
        XCTAssertEqual(effects[3].staticColors, [5: NanoleafRGB(red: 10, green: 20, blue: 30)])
        XCTAssertNil(effects[0].staticColors)
        XCTAssertThrowsError(try NanoleafEffectDefinition.parseLibrary(Data("[]".utf8)))
    }

    func testSavingAnEditedEffectKeepsFieldsLumenDeskDoesNotModel() throws {
        var flames = try XCTUnwrap(try NanoleafEffectDefinition.parseLibrary(Data(Self.library.utf8)).first { $0.name == "Flames" })
        flames.palette = [NanoleafPaletteColor(hue: 10, saturation: 90, brightness: 80)]
        let write = try XCTUnwrap(try object(flames.writeBody(command: "add", name: "Flames (warmer)"))["write"] as? [String: Any])
        XCTAssertEqual(write["command"] as? String, "add")
        XCTAssertEqual(write["animName"] as? String, "Flames (warmer)")
        XCTAssertEqual(write["animType"] as? String, "highlight")
        XCTAssertEqual((write["brightnessRange"] as? [String: Any])?["minValue"] as? Int, 40)
        let palette = try XCTUnwrap(write["palette"] as? [[String: Any]])
        XCTAssertEqual(palette.first?["hue"] as? Int, 10)

        var plugin = try XCTUnwrap(try NanoleafEffectDefinition.parseLibrary(Data(Self.library.utf8)).first { $0.name == "My Animation" })
        plugin.options[0].value = .int(40)
        let preview = try XCTUnwrap(try object(plugin.writeBody(command: "display"))["write"] as? [String: Any])
        XCTAssertNil(preview["animName"], "a preview must not overwrite the stored effect")
        XCTAssertEqual(preview["pluginUuid"] as? String, "027842e4-e1d6-4a4c-a731-be74a1ebd4cf")
        let options = try XCTUnwrap(preview["pluginOptions"] as? [[String: Any]])
        XCTAssertEqual(options.first?["value"] as? Int, 40)
        XCTAssertEqual(options.last?["value"] as? Bool, true)
    }

    func testPluginDescriptionsFromTheDocumentedResponse() throws {
        // OpenAPI 3.2.4.8, trimmed.
        let json = """
        {"plugins":[{"uuid":"027842e4-e1d6-4a4c-a731-be74a1ebd4cf","name":"Flow","description":"Flow","author":"Nanoleaf","type":"color",
          "tags":["zen"],"features":["touch"],"pluginConfig":[
            {"name":"loop","type":"bool","defaultValue":true},
            {"name":"transTime","type":"int","defaultValue":24,"minValue":1,"maxValue":600},
            {"name":"linDirection","type":"string","defaultValue":"right","strings":["left","right","up","down"]}]},
          {"uuid":"23e70ff4-458c-4852-826f-9315d89ee6ed","name":"Meteor Shower","description":"Notes","author":"Nanoleaf","type":"rhythm","tags":[],"features":[]}]}
        """
        let plugins = try NanoleafPluginDescription.parseList(Data(json.utf8))
        XCTAssertEqual(plugins.map(\.name), ["Flow", "Meteor Shower"])
        let transTime = try XCTUnwrap(plugins[0].options.first { $0.name == "transTime" })
        XCTAssertEqual(transTime.defaultValue, .int(24))
        XCTAssertEqual(transTime.maxValue, 600)
        XCTAssertEqual(plugins[0].options.first { $0.name == "linDirection" }?.choices, ["left", "right", "up", "down"])
        XCTAssertEqual(plugins[0].options.first { $0.name == "loop" }?.defaultValue, .bool(true))
        XCTAssertTrue(plugins[1].options.isEmpty)
        XCTAssertEqual(NanoleafOptionValue.label(for: "transTime"), "Transition")
        XCTAssertEqual(NanoleafOptionValue.label(for: "someNewOption"), "Some new option")
    }
}

private enum NanoleafDisplayFixtures {
    static let design = NanoleafPanelDesign.uniform(NanoleafPanelColor(hue: 0.5, saturation: 1, intensity: 1),
                                                    panelIDs: [9, 77, 1204, 5120, 31000, 64001])
}
