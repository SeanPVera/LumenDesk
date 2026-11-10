import XCTest
@testable import LumenDesk

/// Pins the per-light page each owned fixture model opens, and that every
/// other fixture keeps the editor it had before the Polar redesign.
final class LightPageModelTests: XCTestCase {
    func testOwnedLIFXModelsResolveByProductID() {
        XCTAssertEqual(LightPageModel.resolve(brand: .lifx, sku: nil, productID: 219), .lifxLuna)
        XCTAssertEqual(LightPageModel.resolve(brand: .lifx, sku: nil, productID: 129), .lifxColorBulb(.color800))
        XCTAssertEqual(LightPageModel.resolve(brand: .lifx, sku: nil, productID: 91), .lifxColorBulb(.color800lm))
        XCTAssertEqual(LightPageModel.resolve(brand: .lifx, sku: nil, productID: 93), .lifxColorBulb(.colorA19))
        XCTAssertEqual(LightPageModel.resolve(brand: .lifx, sku: nil, productID: 181), .lifxColorBulb(.mini))
    }

    func testOwnedGoveeModelsResolveByExactSKU() {
        let expected: [String: LightPageModel] = [
            "H70B1": .goveeCurtain,
            "H70BC": .goveeCurtainString,
            "H61E6": .goveeCOBStrip,
            "H6062": .goveeGlideBars,
            "H60B0": .goveeUplighter,
            "H608B": .goveeStringPods,
            "H612B": .goveeStripS
        ]
        for (sku, model) in expected {
            XCTAssertEqual(LightPageModel.resolve(brand: .govee, sku: sku, productID: nil), model, sku)
            XCTAssertEqual(LightPageModel.resolve(brand: .govee, sku: sku.lowercased(), productID: nil), model, sku)
        }
    }

    func testOwnedGoveeModelsHaveTheSegmentProfilesTheirPagesDraw() {
        XCTAssertEqual(GoveeSegmentProfile.detect(sku: "H70B1")?.layout, .curtain)
        XCTAssertEqual(GoveeSegmentProfile.detect(sku: "H70BC")?.defaultSegmentCount, 20)
        XCTAssertEqual(GoveeSegmentProfile.detect(sku: "H61E6")?.layout, .cobStrip)
        XCTAssertEqual(GoveeSegmentProfile.detect(sku: "H6062")?.defaultSegmentCount, 28)
        XCTAssertEqual(GoveeSegmentProfile.detect(sku: "H60B0")?.simultaneousZoneLimit, 2)
        XCTAssertEqual(GoveeSegmentProfile.detect(sku: "H608B")?.defaultSegmentCount, 15)
        XCTAssertEqual(GoveeSegmentProfile.detect(sku: "H612B")?.defaultSegmentCount, 75)
    }

    func testNanoleafHexagonsResolveByModel() {
        XCTAssertEqual(LightPageModel.resolve(brand: .nanoleaf, sku: "NL42", productID: nil), .nanoleafHexagons)
        XCTAssertEqual(LightPageModel.resolve(brand: .nanoleaf, sku: "NL22", productID: nil), .fallback(.nanoleafStudio))
        XCTAssertEqual(LightPageModel.resolve(brand: .nanoleaf, sku: nil, productID: nil), .fallback(.nanoleafStudio))
    }

    func testUnownedFixturesKeepPreRedesignRouting() {
        XCTAssertEqual(LightPageModel.resolve(brand: .lifx, sku: nil, productID: 220), .fallback(.lunaMatrix))
        XCTAssertEqual(LightPageModel.resolve(brand: .lifx, sku: LIFXProductCatalog.lunaSKU, productID: nil),
                       .fallback(.lunaMatrix))
        XCTAssertEqual(LightPageModel.resolve(brand: .lifx, sku: nil, productID: 1), .fallback(.basic))
        XCTAssertEqual(LightPageModel.resolve(brand: .lifx, sku: nil, productID: nil), .fallback(.basic))
        XCTAssertEqual(LightPageModel.resolve(brand: .govee, sku: "H619A", productID: nil), .fallback(.goveeSegments))
        XCTAssertEqual(LightPageModel.resolve(brand: .govee, sku: nil, productID: nil), .fallback(.goveeSegments))
    }

    func testDedicatedPagesCarryModelLines() {
        let owned: [LightPageModel] = [
            .lifxLuna, .lifxColorBulb(.mini), .nanoleafHexagons, .goveeCurtain, .goveeCurtainString,
            .goveeCOBStrip, .goveeGlideBars, .goveeUplighter, .goveeStringPods, .goveeStripS
        ]
        for model in owned {
            XCTAssertTrue(model.isDedicatedPage)
            XCTAssertFalse(model.modelLine.isEmpty)
        }
        XCTAssertFalse(LightPageModel.fallback(.basic).isDedicatedPage)
    }

    func testPodWhitePointOnlyOnStringDownlights() {
        XCTAssertEqual(GoveeSegmentProfile.detect(sku: "H608B")?.segmentWhiteRange, 2_700...6_500)
        XCTAssertNil(GoveeSegmentProfile.detect(sku: "H70B1")?.segmentWhiteRange)
        XCTAssertNil(GoveeSegmentProfile.detect(sku: "H6062")?.segmentWhiteRange)
    }

    func testCommandBusRoundTrips() {
        let note = Notification(name: .lumenCommand, object: nil,
                                userInfo: ["command": LumenCommand.openLightPage.rawValue])
        XCTAssertEqual(LumenCommandBus.command(from: note), .openLightPage)
        XCTAssertNil(LumenCommandBus.command(from: Notification(name: .lumenCommand)))
        let save = Notification(name: .lumenCommand, object: nil,
                                userInfo: ["command": LumenCommand.saveLook.rawValue])
        XCTAssertEqual(LumenCommandBus.command(from: save), .saveLook)
    }
}
