import XCTest
@testable import LumenDesk

final class ScheduleEngineTests: XCTestCase {
    private let solarTimes = ScheduleEngine.SolarTimes(
        sunriseMinutes: 6 * 60 + 30,
        sunsetMinutes: 20 * 60 + 30
    )

    func testFixedTimeAndWeekdayMatching() throws {
        let calendar = utcCalendar()
        let engine = ScheduleEngine(calendar: calendar)
        let previous = try date(2026, 7, 13, 8, 59, calendar: calendar)
        let currentDate = try date(2026, 7, 13, 9, 1, calendar: calendar)
        let mondayAtNine = ScheduleEntry(hour: 9, minute: 0, action: .turnOn, weekdays: [2])
        let tuesdayAtNine = ScheduleEntry(hour: 9, minute: 0, action: .turnOn, weekdays: [3])

        XCTAssertEqual(
            engine.occurrences(
                for: mondayAtNine,
                after: previous,
                through: currentDate,
                solarTimes: solarTimes
            ),
            [try date(2026, 7, 13, 9, 0, calendar: calendar)]
        )
        XCTAssertTrue(engine.occurrences(
            for: tuesdayAtNine,
            after: previous,
            through: currentDate,
            solarTimes: solarTimes
        ).isEmpty)
    }

    func testSunriseAndSunsetOffsetsSupportPositiveAndNegativeValues() throws {
        let calendar = utcCalendar()
        let engine = ScheduleEngine(calendar: calendar)
        let reference = try date(2026, 7, 13, 12, 0, calendar: calendar)
        let sunrise = ScheduleEntry(hour: 0, minute: 0, offsetMinutes: 15, action: .atSunrise)
        let sunset = ScheduleEntry(hour: 0, minute: 0, offsetMinutes: -30, action: .atSunset)

        XCTAssertEqual(
            engine.occurrence(for: sunrise, relativeTo: reference, solarTimes: solarTimes),
            try date(2026, 7, 13, 6, 45, calendar: calendar)
        )
        XCTAssertEqual(
            engine.occurrence(for: sunset, relativeTo: reference, solarTimes: solarTimes),
            try date(2026, 7, 13, 20, 0, calendar: calendar)
        )
    }

    func testDuplicateFireIsRejectedDuringSameMinuteAndAllowedAfterMinuteChanges() throws {
        let calendar = utcCalendar()
        let entry = ScheduleEntry(hour: 9, minute: 0, action: .turnOn)
        let room = Room(name: "Office", schedules: [entry])
        var currentDate = try date(2026, 7, 13, 9, 0, calendar: calendar).addingTimeInterval(10)
        let previous = try date(2026, 7, 13, 8, 59, calendar: calendar)
        let engine = ScheduleEngine(
            now: { currentDate },
            calendar: calendar,
            state: .init(lastCheck: previous)
        )

        XCTAssertEqual(engine.evaluate(rooms: [room], solarTimes: solarTimes).decisions.count, 1)

        var replayState = engine.state
        replayState.lastCheck = previous
        engine.restore(replayState)
        currentDate = try date(2026, 7, 13, 9, 0, calendar: calendar).addingTimeInterval(45)
        XCTAssertTrue(engine.evaluate(rooms: [room], solarTimes: solarTimes).decisions.isEmpty)

        replayState.lastCheck = previous
        engine.restore(replayState)
        currentDate = try date(2026, 7, 13, 9, 1, calendar: calendar)
        XCTAssertEqual(engine.evaluate(rooms: [room], solarTimes: solarTimes).decisions.count, 1)
    }

    func testNextScheduleOverrideSkipsOnceAndThenResumes() throws {
        let calendar = utcCalendar()
        var currentDate = try date(2026, 7, 13, 8, 50, calendar: calendar)
        let entry = ScheduleEntry(hour: 9, minute: 0, action: .turnOn)
        let room = Room(name: "Office", schedules: [entry])
        let engine = ScheduleEngine(now: { currentDate }, calendar: calendar)
        engine.setOverride(for: room.id, duration: .nextSchedule)

        currentDate = try date(2026, 7, 13, 9, 0, calendar: calendar).addingTimeInterval(5)
        let evaluation = engine.evaluate(rooms: [room], solarTimes: solarTimes)

        XCTAssertEqual(evaluation.decisions, [
            .skipped(
                .init(
                    roomID: room.id,
                    roomName: room.name,
                    entry: entry,
                    scheduledAt: try date(2026, 7, 13, 9, 0, calendar: calendar)
                ),
                consumedSkipOverride: true
            )
        ])
        XCTAssertNil(engine.automationOverrides[room.id])
        XCTAssertTrue(evaluation.didChangeOverrides)
    }

    func testUntilResumedOverrideKeepsRoomPaused() throws {
        let calendar = utcCalendar()
        var currentDate = try date(2026, 7, 13, 8, 50, calendar: calendar)
        let entry = ScheduleEntry(hour: 9, minute: 0, action: .turnOn)
        let room = Room(name: "Office", schedules: [entry])
        let engine = ScheduleEngine(now: { currentDate }, calendar: calendar)
        engine.setOverride(for: room.id, duration: .untilResumed)

        currentDate = try date(2026, 7, 13, 9, 0, calendar: calendar).addingTimeInterval(5)
        let evaluation = engine.evaluate(rooms: [room], solarTimes: solarTimes)

        guard case let .skipped(_, consumedSkipOverride)? = evaluation.decisions.first else {
            return XCTFail("Expected the paused room's automation to be skipped")
        }
        XCTAssertFalse(consumedSkipOverride)
        XCTAssertNotNil(engine.automationOverrides[room.id])
        XCTAssertTrue(engine.resumeAutomation(for: room.id))
        XCTAssertNil(engine.automationOverrides[room.id])
    }

    func testExpiredTemporaryOverrideDoesNotSuppressAutomation() throws {
        let calendar = utcCalendar()
        var currentDate = try date(2026, 7, 13, 7, 59, calendar: calendar)
        let entry = ScheduleEntry(hour: 9, minute: 0, action: .turnOn)
        let room = Room(name: "Office", schedules: [entry])
        let engine = ScheduleEngine(
            now: { currentDate },
            calendar: calendar,
            state: .init(lastCheck: try date(2026, 7, 13, 8, 59, calendar: calendar))
        )
        engine.setOverride(for: room.id, duration: .oneHour)

        currentDate = try date(2026, 7, 13, 9, 0, calendar: calendar).addingTimeInterval(5)
        let evaluation = engine.evaluate(rooms: [room], solarTimes: solarTimes)

        XCTAssertEqual(evaluation.decisions.count, 1)
        guard case .run = evaluation.decisions[0] else {
            return XCTFail("Expected an expired override to permit the scheduled action")
        }
        XCTAssertNil(engine.automationOverrides[room.id])
        XCTAssertTrue(evaluation.didChangeOverrides)
    }

    func testLongGapCreatesOneMissedAutomation() throws {
        let calendar = utcCalendar()
        let previous = try date(2026, 7, 13, 8, 0, calendar: calendar)
        let currentDate = try date(2026, 7, 13, 9, 5, calendar: calendar)
        let entry = ScheduleEntry(hour: 9, minute: 0, action: .dim50)
        let room = Room(name: "Office", schedules: [entry])
        let engine = ScheduleEngine(
            now: { currentDate },
            calendar: calendar,
            state: .init(lastCheck: previous)
        )

        let firstEvaluation = engine.evaluate(rooms: [room], solarTimes: solarTimes)
        guard case let .missed(missed)? = firstEvaluation.decisions.first else {
            return XCTFail("Expected a missed automation decision")
        }
        XCTAssertEqual(missed.roomID, room.id)
        XCTAssertEqual(engine.missedAutomations.count, 1)

        var replayState = engine.state
        replayState.lastCheck = previous
        engine.restore(replayState)
        XCTAssertTrue(engine.evaluate(rooms: [room], solarTimes: solarTimes).decisions.isEmpty)
        XCTAssertEqual(engine.missedAutomations.count, 1)
    }

    func testPausedAutomationIsSkippedInsteadOfRecordedAsMissed() throws {
        let calendar = utcCalendar()
        let previous = try date(2026, 7, 13, 8, 0, calendar: calendar)
        var currentDate = try date(2026, 7, 13, 8, 30, calendar: calendar)
        let entry = ScheduleEntry(hour: 9, minute: 0, action: .turnOff)
        let room = Room(name: "Office", schedules: [entry])
        let engine = ScheduleEngine(
            now: { currentDate },
            calendar: calendar,
            state: .init(lastCheck: previous)
        )
        engine.setOverride(for: room.id, duration: .untilResumed)

        currentDate = try date(2026, 7, 13, 9, 5, calendar: calendar)
        let evaluation = engine.evaluate(rooms: [room], solarTimes: solarTimes)

        guard case .skipped? = evaluation.decisions.first else {
            return XCTFail("Expected an active manual pause to win over missed-automation tracking")
        }
        XCTAssertTrue(engine.missedAutomations.isEmpty)
    }

    func testEmptySchedulesAndDisabledEntriesProduceNoDecisions() throws {
        let calendar = utcCalendar()
        let currentDate = try date(2026, 7, 13, 9, 0, calendar: calendar).addingTimeInterval(5)
        let disabled = ScheduleEntry(isEnabled: false, hour: 9, minute: 0, action: .turnOn)
        let rooms = [Room(name: "Empty"), Room(name: "Disabled", schedules: [disabled])]
        let engine = ScheduleEngine(now: { currentDate }, calendar: calendar)

        XCTAssertTrue(engine.evaluate(rooms: rooms, solarTimes: solarTimes).decisions.isEmpty)
        XCTAssertFalse(engine.hasEnabledSchedules(in: rooms))
        XCTAssertTrue(engine.hasEnabledSchedules(in: [
            Room(name: "Enabled", schedules: [ScheduleEntry(hour: 10, minute: 0, action: .turnOn)])
        ]))
    }

    func testNextOccurrenceUsesInjectedClock() throws {
        let calendar = utcCalendar()
        let currentDate = try date(2026, 7, 13, 9, 30, calendar: calendar)
        let entry = ScheduleEntry(hour: 9, minute: 0, action: .turnOn, weekdays: [2])
        let engine = ScheduleEngine(now: { currentDate }, calendar: calendar)

        XCTAssertEqual(
            engine.nextOccurrence(for: entry, solarTimes: solarTimes),
            try date(2026, 7, 20, 9, 0, calendar: calendar)
        )
    }

    func testDaylightSavingSpringForwardPreservesExistingElapsedMinuteBehavior() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let reference = try date(2026, 3, 8, 12, 0, calendar: calendar)
        let entry = ScheduleEntry(hour: 2, minute: 30, action: .turnOn)
        let engine = ScheduleEngine(calendar: calendar)
        let occurrence = try XCTUnwrap(
            engine.occurrence(for: entry, relativeTo: reference, solarTimes: solarTimes)
        )

        XCTAssertEqual(calendar.component(.hour, from: occurrence), 3)
        XCTAssertEqual(calendar.component(.minute, from: occurrence), 30)
    }

    func testDefaultCalendarTracksSystemTimeZoneChanges() throws {
        let originalTimeZone = NSTimeZone.default
        defer { NSTimeZone.default = originalTimeZone }
        let reference = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-13T12:00:00Z"))
        let entry = ScheduleEntry(hour: 10, minute: 0, action: .turnOn)

        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let engine = ScheduleEngine()
        let newYorkOccurrence = try XCTUnwrap(
            engine.occurrence(for: entry, relativeTo: reference, solarTimes: solarTimes)
        )

        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let losAngelesOccurrence = try XCTUnwrap(
            engine.occurrence(for: entry, relativeTo: reference, solarTimes: solarTimes)
        )

        XCTAssertEqual(losAngelesOccurrence.timeIntervalSince(newYorkOccurrence), 3 * 60 * 60)
    }

    func testConflictDetectionUsesResolvedSolarTimes() {
        let engine = ScheduleEngine(calendar: utcCalendar())
        let sunrise = ScheduleEntry(hour: 0, minute: 0, offsetMinutes: 5, action: .atSunrise)
        let fixed = ScheduleEntry(hour: 6, minute: 40, action: .turnOn)
        let distant = ScheduleEntry(hour: 8, minute: 0, action: .turnOff)

        XCTAssertEqual(
            engine.conflicts(in: [sunrise, fixed, distant], solarTimes: solarTimes),
            [.init(first: sunrise, second: fixed)]
        )
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
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
