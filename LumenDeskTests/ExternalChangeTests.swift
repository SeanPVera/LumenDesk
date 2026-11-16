import XCTest
import SwiftUI
@testable import LumenDesk

/// Changes a light reports that LumenDesk did not make: what is recorded
/// about them, what is said about their cause, and putting them back.
final class ExternalChangeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let mac = "001122334455"
    private let goveeID = "AA:BB:CC:DD:EE:FF:00:11"

    // Three LIFX readings that differ from each other in level, colour and
    // white point. Brightness is 20000, 45000 and 60000 of 65535.
    private let readingA = LIFXHSBK(hue: 0, saturation: 0, brightness: 20_000, kelvin: 3_500)
    private let readingB = LIFXHSBK(hue: 30_000, saturation: 50_000, brightness: 45_000, kelvin: 4_200)
    private let readingC = LIFXHSBK(hue: 10_000, saturation: 60_000, brightness: 60_000, kelvin: 2_700)

    private func reading(on: Bool = true, brightness: Double = 0.4, hex: String = "#FF8800",
                         kelvin: Int = 3_500, appearance: NanoleafAppearance? = nil,
                         after seconds: TimeInterval = 0) -> ConfirmedDeviceState {
        ConfirmedDeviceState(isOn: on, brightness: brightness, colorHex: hex, kelvin: kelvin,
                             nanoleafAppearance: appearance,
                             confirmedAt: start.addingTimeInterval(seconds))
    }

    private func change(before: ConfirmedDeviceState, after: ConfirmedDeviceState,
                        vendor: String = "LIFX",
                        evidence: ExternalChange.Evidence = .unreported) -> ExternalChange {
        ExternalChange(deviceID: "lifx:1", vendor: vendor, before: before, after: after,
                       noticedAt: after.confirmedAt, evidence: evidence)
    }

    // MARK: - What changed

    func testDifferencesNameEveryChannelThatMoved() {
        let moved = change(before: reading(),
                           after: reading(on: false, brightness: 0.8, hex: "#3366FF", kelvin: 2_700, after: 30))
        XCTAssertEqual(moved.differences.map(\.field), [.power, .brightness, .colour, .whitePoint])
        XCTAssertEqual(moved.differenceSummary,
                       "Power On \u{2192} Off, Brightness 40% \u{2192} 80%, Colour #FF8800 \u{2192} #3366FF, White point 3500 K \u{2192} 2700 K")
    }

    func testEveryReadingThatCountsAsAChangeHasSomethingToShow() {
        let before = reading()
        let candidates = [
            reading(on: false), reading(brightness: 0.44), reading(hex: "#FF8801"),
            reading(kelvin: 3_650), reading(appearance: .init(colorMode: "ct"))
        ]
        for after in candidates {
            XCTAssertTrue(ExternalChange.materiallyDiffers(before, after))
            XCTAssertFalse(change(before: before, after: after).differences.isEmpty)
        }
        // Inside the tolerances a reading is the same state, and lists nothing.
        let drift = reading(brightness: 0.42, kelvin: 3_560)
        XCTAssertFalse(ExternalChange.materiallyDiffers(before, drift))
        XCTAssertTrue(change(before: before, after: drift).differences.isEmpty)
    }

    func testANanoleafModeChangeIsNamedInWords() {
        let moved = change(before: reading(appearance: .init(colorMode: "effect")),
                           after: reading(appearance: .init(colorMode: "effect", effect: "Forest"), after: 5),
                           vendor: "Nanoleaf", evidence: .controllerScene(name: "Forest"))
        XCTAssertEqual(moved.differenceSummary,
                       "Mode Panel layout or stream \u{2192} Scene \u{201C}Forest\u{201D}")
        XCTAssertEqual(ExternalChange.modeName(.init(colorMode: "hs")), "One colour")
        XCTAssertEqual(ExternalChange.modeName(.init(colorMode: "ct")), "White")
    }

    func testColourValuesParseForSwatches() {
        XCTAssertEqual(ExternalChange.rgbValue(hex: "#FF8800"), 0xFF8800)
        XCTAssertEqual(ExternalChange.rgbValue(hex: "3366ff"), 0x3366FF)
        XCTAssertNil(ExternalChange.rgbValue(hex: "#FFF"))
        XCTAssertNil(ExternalChange.rgbValue(hex: "On"))
    }

    // MARK: - When

    func testTimingIsOnlyCalledPreciseInsideOneRefreshInterval() {
        let stamp: (Date) -> String = { "t+\(Int($0.timeIntervalSince(self.start)))" }
        let quick = change(before: reading(), after: reading(brightness: 0.8, after: 30))
        XCTAssertTrue(quick.isPinpointed)
        XCTAssertEqual(quick.timingStatement(format: stamp), "Changed at about t+30.")

        // An hour with no reading: the change could be anywhere in it.
        let slow = change(before: reading(), after: reading(brightness: 0.8, after: 3_600))
        XCTAssertFalse(slow.isPinpointed)
        XCTAssertEqual(slow.window, start...start.addingTimeInterval(3_600))
        XCTAssertEqual(slow.timingStatement(format: stamp),
                       "Changed between t+0 and t+3600. LumenDesk had no reading from this light in between.")
    }

    // MARK: - Where from

    func testNoStatementNamesASenderTheLightDidNotReport() {
        let unreported = change(before: reading(), after: reading(brightness: 0.8, after: 30), vendor: "Govee")
        XCTAssertEqual(unreported.originTitle, "Sender not reported")
        XCTAssertFalse(unreported.originIsInference)
        XCTAssertTrue(unreported.originStatement.hasPrefix("Govee lights report their state and nothing about who set it."))

        let scene = change(before: reading(), after: reading(after: 5), vendor: "Nanoleaf",
                           evidence: .controllerScene(name: "Forest"))
        XCTAssertTrue(scene.originStatement.contains("the controller does not say which"))
        XCTAssertFalse(scene.originIsInference)

        // Circumstance, not a report, and labelled as likely.
        for evidence in [ExternalChange.Evidence.returnedAfterSilence, .panelTouched] {
            let guessed = change(before: reading(), after: reading(on: false, after: 30), evidence: evidence)
            XCTAssertTrue(guessed.originIsInference)
            XCTAssertTrue(guessed.originTitle.hasPrefix("Probably"))
            XCTAssertTrue(guessed.originStatement.contains("likely"))
        }
    }

    func testLaterReadingsMoveAfterAndKeepTheFirstCause() {
        var moved = change(before: reading(), after: reading(brightness: 0.8, after: 30))
        moved.update(after: reading(brightness: 0.9, after: 60), evidence: .returnedAfterSilence)
        XCTAssertEqual(moved.after.brightness, 0.9)
        XCTAssertEqual(moved.before.brightness, 0.4)
        XCTAssertEqual(moved.evidence, .returnedAfterSilence, "The first cause on offer replaces none")

        moved.update(after: reading(brightness: 0.6, after: 90), evidence: .unreported)
        XCTAssertEqual(moved.evidence, .returnedAfterSilence, "A later reading with no cause does not erase one")
        XCTAssertEqual(moved.noticedAt, start.addingTimeInterval(30), "Noticed when the first difference was read")
    }

    // MARK: - Through the manager

    @MainActor
    private func makeManager() -> LightManager {
        LightManager(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                     persistenceStore: temporaryPersistenceStore())
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    @MainActor
    private func lifxLight(_ manager: LightManager, first reading: LIFXHSBK) async throws -> LightDevice {
        manager.lifxDiscovered(macHex: mac, address: "192.0.2.10")
        try await settle()
        manager.lifxDidUpdate(macHex: mac, label: "Desk", color: reading, isOn: true)
        try await settle()
        return try XCTUnwrap(manager.devices.first)
    }

    @MainActor
    private func report(_ reading: LIFXHSBK, to manager: LightManager, isOn: Bool = true) async throws {
        manager.lifxDidUpdate(macHex: mac, label: "Desk", color: reading, isOn: isOn)
        try await settle()
    }

    @MainActor
    func testAnOutsideChangeRecordsWhatTheLightReportedBeforeAndAfter() async throws {
        let manager = makeManager()
        let device = try await lifxLight(manager, first: readingA)
        XCTAssertNil(manager.externalChanges[device.id], "A first reading has nothing to differ from")

        try await report(readingB, to: manager)
        let noticed = try XCTUnwrap(manager.externalChanges[device.id])
        XCTAssertEqual(noticed.vendor, "LIFX")
        XCTAssertEqual(noticed.differences.map(\.field), [.brightness, .colour, .whitePoint])
        XCTAssertEqual(noticed.differences.first?.summary, "Brightness 31% \u{2192} 69%")
        XCTAssertEqual(noticed.before.kelvin, 3_500)
        XCTAssertEqual(noticed.after.kelvin, 4_200)
        XCTAssertEqual(noticed.evidence, .unreported, "LIFX replies carry no sender")
        XCTAssertTrue(noticed.isPinpointed)
        XCTAssertEqual(manager.externalChanges(in: [device.id]), [noticed])
        XCTAssertTrue(manager.externalChanges(in: ["lifx:someone-else"]).isEmpty)
        XCTAssertEqual(RoomCanvasStatus.resolve([device], manager: manager), .changedElsewhere)
    }

    @MainActor
    func testPuttingItBackRestoresTheLightAndUndoReturnsToTheChange() async throws {
        let manager = makeManager()
        let device = try await lifxLight(manager, first: readingA)
        try await report(readingB, to: manager)
        XCTAssertEqual(device.kelvin, 4_200, "The model shows what the light reported")

        manager.overrideExternalChange(deviceIDs: [device.id])
        XCTAssertNil(manager.externalChanges[device.id])
        XCTAssertNil(manager.externalChangeRestorePoints[device.id])
        XCTAssertEqual(device.brightness, 20_000.0 / 65_535.0, accuracy: 0.001)
        XCTAssertEqual(device.kelvin, 3_500)
        XCTAssertTrue(device.isOn)
        XCTAssertTrue(manager.commandPendingIDs.contains(device.id), "Putting it back is a real command")
        XCTAssertTrue(manager.canUndo)

        // The light reports what it was sent: confirmed, not a new change.
        try await report(readingA, to: manager)
        XCTAssertNil(manager.externalChanges[device.id])
        XCTAssertFalse(manager.commandPendingIDs.contains(device.id))

        manager.undo()
        XCTAssertEqual(device.brightness, 45_000.0 / 65_535.0, accuracy: 0.001)
        XCTAssertEqual(device.kelvin, 4_200)
    }

    @MainActor
    func testKeepingItClearsTheChangeAndSendsNothing() async throws {
        let manager = makeManager()
        let device = try await lifxLight(manager, first: readingA)
        try await report(readingB, to: manager)

        manager.acknowledgeExternalChange(deviceIDs: [device.id])
        XCTAssertNil(manager.externalChanges[device.id])
        XCTAssertNil(manager.externalChangeRestorePoints[device.id])
        XCTAssertFalse(manager.commandPendingIDs.contains(device.id))
        XCTAssertEqual(device.kelvin, 4_200)
        XCTAssertEqual(RoomCanvasStatus.resolve([device], manager: manager), .confirmed)

        // What was kept is the new baseline: the same reading is not a change.
        try await report(readingB, to: manager)
        XCTAssertNil(manager.externalChanges[device.id])
    }

    @MainActor
    func testASecondOutsideChangeStillPutsBackTheFirstBefore() async throws {
        let manager = makeManager()
        let device = try await lifxLight(manager, first: readingA)
        try await report(readingB, to: manager)
        try await report(readingC, to: manager)

        let noticed = try XCTUnwrap(manager.externalChanges[device.id])
        XCTAssertEqual(noticed.before.kelvin, 3_500, "Before stays what LumenDesk last held")
        XCTAssertEqual(noticed.after.kelvin, 2_700, "After follows the light")

        manager.overrideExternalChange(deviceIDs: [device.id])
        XCTAssertEqual(device.kelvin, 3_500)
        XCTAssertEqual(device.brightness, 20_000.0 / 65_535.0, accuracy: 0.001)
    }

    @MainActor
    func testALightThatGoesBackByItselfStopsBeingFlagged() async throws {
        let manager = makeManager()
        let device = try await lifxLight(manager, first: readingA)
        try await report(readingB, to: manager)
        XCTAssertNotNil(manager.externalChanges[device.id])

        try await report(readingA, to: manager)
        XCTAssertNil(manager.externalChanges[device.id], "Nothing is left to keep or put back")
        XCTAssertNil(manager.externalChangeRestorePoints[device.id])
    }

    @MainActor
    func testALightTurnedOffElsewhereIsTurnedBackOn() async throws {
        let manager = makeManager()
        let device = try await lifxLight(manager, first: readingA)
        try await report(readingA, to: manager, isOn: false)

        let noticed = try XCTUnwrap(manager.externalChanges[device.id])
        XCTAssertEqual(noticed.differences.map(\.field), [.power])
        XCTAssertFalse(device.isOn)

        manager.overrideExternalChange(deviceIDs: [device.id])
        XCTAssertTrue(device.isOn)
    }

    @MainActor
    func testALightThatHadGoneQuietIsPutDownToLosingPower() async throws {
        let manager = makeManager()
        let device = try await lifxLight(manager, first: readingA)
        device.isStale = true

        try await report(readingB, to: manager)
        let noticed = try XCTUnwrap(manager.externalChanges[device.id])
        XCTAssertEqual(noticed.evidence, .returnedAfterSilence)
        XCTAssertTrue(noticed.originIsInference)
    }

    @MainActor
    func testLumenDesksOwnUnconfirmedSendIsNotAChangeMadeElsewhere() async throws {
        let manager = makeManager()
        manager.goveeDiscovered(deviceID: goveeID, address: "192.0.2.20", sku: nil)
        try await settle()
        let device = try XCTUnwrap(manager.devices.first)
        func report(r: Int, g: Int, b: Int) async throws {
            manager.goveeDidUpdate(deviceID: goveeID, isOn: true, brightness: 50, r: r, g: g, b: b, kelvin: 0)
            try await settle()
        }
        try await report(r: 255, g: 0, b: 0)

        // A segment layout is never echoed by a status reply. The reading
        // that follows it is that layout landing.
        manager.noteSegmentCommand(device, summary: "Applying 15-segment layout")
        manager.unconfirmedSends[device.id] = Date().addingTimeInterval(-10)
        try await report(r: 0, g: 0, b: 255)
        XCTAssertNil(manager.externalChanges[device.id])
        XCTAssertEqual(manager.confirmedStates[device.id]?.colorHex,
                       LightManager.hexString(Color(red: 0, green: 0, blue: 1)),
                       "The reading still becomes the confirmed state")
        XCTAssertNil(manager.unconfirmedSends[device.id], "One send explains one reading")

        // The next difference has no LumenDesk send behind it.
        try await report(r: 0, g: 255, b: 0)
        let noticed = try XCTUnwrap(manager.externalChanges[device.id])
        XCTAssertEqual(noticed.vendor, "Govee")
        XCTAssertEqual(noticed.differences.map(\.field), [.colour])
    }

    @MainActor
    func testAnOldUnconfirmedSendDoesNotExcuseALaterChange() async throws {
        let manager = makeManager()
        let device = try await lifxLight(manager, first: readingA)
        manager.unconfirmedSends[device.id] = Date().addingTimeInterval(-(ExternalChange.ownSendWindow + 5))

        try await report(readingB, to: manager)
        XCTAssertNotNil(manager.externalChanges[device.id])
    }

    @MainActor
    func testALunaIsPutBackToTheZonesItHadEvenWhenTheZoneReplyArrivesFirst() async throws {
        let manager = makeManager()
        let device = try await lifxLight(manager, first: readingA)
        let held = (0..<64).map { LIFXHSBK(hue: UInt16($0 * 1_000), saturation: 65_535, brightness: 20_000, kelvin: 3_500) }
        let outside = Array(repeating: readingB, count: 64)
        func zones(_ colors: [LIFXHSBK]) async throws {
            manager.lifxDidUpdateMatrix(macHex: mac, productID: 219, width: 8, height: 8, colors: colors)
            try await settle()
        }
        try await zones(held)
        XCTAssertTrue(device.isLIFXLuna)

        // Another app repaints the Luna. Its zones are read before its colour.
        try await zones(outside)
        XCTAssertNil(manager.externalChanges[device.id], "Zones alone do not raise the flag")
        try await report(readingB, to: manager)

        let point = try XCTUnwrap(manager.externalChangeRestorePoints[device.id])
        XCTAssertEqual(point.matrix?.colors, held.map(LIFXMatrixColor.init))

        manager.overrideExternalChange(deviceIDs: [device.id])
        XCTAssertEqual(manager.lifxMatrixStates[device.id]?.colors, held.map(LIFXMatrixColor.init))
        XCTAssertNil(manager.matrixBeforeReading[device.id])
    }
}
