import SwiftUI
import XCTest
@testable import LumenDesk

final class DomainTests: XCTestCase {
    func testSceneSerialization() throws {
        let segmentState = GoveeSegmentState(
            colors: [
                GoveeSegmentColor(red: 1, green: 0.2, blue: 0.1, brightness: 0.7),
                GoveeSegmentColor(red: 0.1, green: 0.4, blue: 1, brightness: 0.5)
            ],
            gradient: true,
            isActive: true
        )
        let scene = LightingScene(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Evening",
            snapshots: [
                "govee:desk": DeviceSnapshot(
                    isOn: true,
                    brightness: 0.65,
                    hue: 0.8,
                    saturation: 0.75,
                    kelvin: 3_200,
                    segments: segmentState
                )
            ],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let decoded = try JSONDecoder().decode(LightingScene.self, from: JSONEncoder().encode(scene))
        XCTAssertEqual(decoded, scene)
    }

    func testRoomSerialization() throws {
        let schedule = ScheduleEntry(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            hour: 21,
            minute: 30,
            action: .dim25,
            weekdays: [2, 3, 4, 5, 6]
        )
        let room = Room(
            id: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            name: "Office",
            lightIDs: ["lifx:a", "govee:b"],
            schedules: [schedule]
        )

        let decoded = try JSONDecoder().decode(Room.self, from: JSONEncoder().encode(room))
        XCTAssertEqual(decoded, room)
    }

    @MainActor
    func testImportExportRoundTrip() throws {
        let source = LightManager(defaults: isolatedDefaults())
        source.enterDemoMode()
        defer { source.exitDemoMode() }

        let data = try XCTUnwrap(source.exportConfigurationData())
        let destination = LightManager(defaults: isolatedDefaults())
        XCTAssertTrue(destination.importRoomsData(data))
        XCTAssertEqual(destination.rooms, source.rooms)
        XCTAssertEqual(destination.scenes, source.scenes)
        XCTAssertEqual(destination.favoriteIDs, source.favoriteIDs)
        XCTAssertEqual(destination.favoriteRoomIDs, source.favoriteRoomIDs)
        XCTAssertEqual(destination.favoriteSceneIDs, source.favoriteSceneIDs)
        XCTAssertEqual(destination.customBrightnessPresets, source.customBrightnessPresets)
    }

    func testScheduleMatching() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let previous = try date(2026, 7, 13, 8, 59, calendar: calendar)
        let now = try date(2026, 7, 13, 9, 1, calendar: calendar)
        let mondayAtNine = ScheduleEntry(hour: 9, minute: 0, action: .turnOn, weekdays: [2])

        let matches = ScheduleEvaluator.occurrences(
            for: mondayAtNine,
            after: previous,
            through: now,
            sunriseMinutes: 390,
            sunsetMinutes: 1_230,
            calendar: calendar
        )
        XCTAssertEqual(matches, [try date(2026, 7, 13, 9, 0, calendar: calendar)])

        let tuesdayOnly = ScheduleEntry(hour: 9, minute: 0, action: .turnOn, weekdays: [3])
        XCTAssertTrue(ScheduleEvaluator.occurrences(
            for: tuesdayOnly,
            after: previous,
            through: now,
            sunriseMinutes: 390,
            sunsetMinutes: 1_230,
            calendar: calendar
        ).isEmpty)

        let sunrise = ScheduleEntry(hour: 0, minute: 0, offsetMinutes: 15, action: .atSunrise)
        let sunriseDate = ScheduleEvaluator.occurrence(
            for: sunrise,
            relativeTo: previous,
            sunriseMinutes: 390,
            sunsetMinutes: 1_230,
            calendar: calendar
        )
        XCTAssertEqual(sunriseDate, try date(2026, 7, 13, 6, 45, calendar: calendar))
    }

    func testDuplicateScheduleFirePrevention() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let entryID = UUID()
        var fired: [UUID: String] = [:]
        let first = try date(2026, 7, 13, 9, 0, calendar: calendar)
        let sameMinute = try date(2026, 7, 13, 9, 0, calendar: calendar).addingTimeInterval(45)
        let nextMinute = try date(2026, 7, 13, 9, 1, calendar: calendar)

        XCTAssertTrue(ScheduleEvaluator.claim(entryID, at: first, fired: &fired, calendar: calendar))
        XCTAssertFalse(ScheduleEvaluator.claim(entryID, at: sameMinute, fired: &fired, calendar: calendar))
        XCTAssertTrue(ScheduleEvaluator.claim(entryID, at: nextMinute, fired: &fired, calendar: calendar))
    }

    func testSegmentLayoutResizingPreservesEndpoints() {
        let red = GoveeSegmentColor(red: 1, green: 0, blue: 0)
        let blue = GoveeSegmentColor(red: 0, green: 0, blue: 1)
        var state = GoveeSegmentState(colors: [red, blue], gradient: true, isActive: true)

        state.resize(to: 3)

        XCTAssertEqual(state.segmentCount, 3)
        XCTAssertEqual(state.colors.first, red)
        XCTAssertEqual(state.colors.last, blue)
        XCTAssertEqual(state.colors[1].red, 0.5, accuracy: 0.0001)
        XCTAssertEqual(state.colors[1].blue, 0.5, accuracy: 0.0001)
    }

    @MainActor
    func testUndoRedoSnapshotRestoration() throws {
        let manager = LightManager(defaults: isolatedDefaults())
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let device = try XCTUnwrap(manager.devices.first)
        let originalPower = device.isOn
        let originalBrightness = device.brightness

        manager.setBrightness(device, value: 0.82)
        manager.setPower(device, on: !originalPower)
        XCTAssertTrue(manager.canUndo)

        manager.undo()
        XCTAssertEqual(device.brightness, originalBrightness, accuracy: 0.0001)
        XCTAssertEqual(device.isOn, originalPower)
        XCTAssertTrue(manager.canRedo)

        manager.redo()
        XCTAssertEqual(device.brightness, 0.82, accuracy: 0.0001)
        XCTAssertEqual(device.isOn, !originalPower)
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "LumenDeskTests.\(UUID().uuidString)")!
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        calendar: Calendar
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )))
    }
}
