import Foundation

/// Evaluates room schedules and owns the transient bookkeeping needed to keep
/// automation deterministic. It returns decisions for LightManager to apply;
/// it never mutates devices or sends lighting commands itself.
final class ScheduleEngine {
    struct SolarTimes: Equatable {
        var sunriseMinutes: Int
        var sunsetMinutes: Int
    }

    struct State: Equatable {
        var automationOverrides: [UUID: RoomAutomationOverride] = [:]
        var missedAutomations: [MissedAutomation] = []
        var lastCheck: Date?
        var firedThisMinute: [UUID: String] = [:]
    }

    struct Occurrence: Equatable {
        let roomID: UUID
        let roomName: String
        let entry: ScheduleEntry
        let scheduledAt: Date
    }

    enum Decision: Equatable {
        case run(Occurrence)
        case skipped(Occurrence, consumedSkipOverride: Bool)
        case missed(MissedAutomation)
    }

    struct Evaluation: Equatable {
        let decisions: [Decision]
        let didChangeOverrides: Bool
        let didChangeMissedAutomations: Bool
    }

    struct OverrideLookup: Equatable {
        let value: RoomAutomationOverride?
        let didRemoveExpired: Bool
    }

    struct Conflict: Equatable {
        let first: ScheduleEntry
        let second: ScheduleEntry
    }

    private let now: () -> Date
    private let calendar: Calendar
    private(set) var state: State

    init(
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current,
        state: State = State()
    ) {
        self.now = now
        self.calendar = calendar
        self.state = state
    }

    var currentDate: Date { now() }
    var automationOverrides: [UUID: RoomAutomationOverride] { state.automationOverrides }
    var missedAutomations: [MissedAutomation] { state.missedAutomations }

    var delayUntilNextMinute: TimeInterval {
        TimeInterval(max(1, 60 - calendar.component(.second, from: now())))
    }

    func restore(_ state: State) {
        self.state = state
    }

    func restoreAutomationOverrides(_ overrides: [UUID: RoomAutomationOverride]) {
        state.automationOverrides = overrides
    }

    func evaluate(rooms: [Room], solarTimes: SolarTimes) -> Evaluation {
        let oldOverrides = state.automationOverrides
        let oldMissedAutomations = state.missedAutomations
        let currentDate = now()
        let previous = state.lastCheck ?? currentDate.addingTimeInterval(-75)
        state.lastCheck = currentDate
        let shouldRecordMissed = currentDate.timeIntervalSince(previous) > 120
        var decisions: [Decision] = []

        for room in rooms {
            for entry in room.schedules where entry.isEnabled {
                for scheduledAt in occurrences(
                    for: entry,
                    after: previous,
                    through: currentDate,
                    solarTimes: solarTimes
                ) {
                    let occurrence = Occurrence(
                        roomID: room.id,
                        roomName: room.name,
                        entry: entry,
                        scheduledAt: scheduledAt
                    )

                    if let automationOverride = activeOverride(for: room.id, at: currentDate).value {
                        let consumesOverride = automationOverride.skipNextSchedule
                        if consumesOverride {
                            state.automationOverrides.removeValue(forKey: room.id)
                        }
                        decisions.append(.skipped(occurrence, consumedSkipOverride: consumesOverride))
                        continue
                    }

                    if shouldRecordMissed {
                        let isDuplicate = state.missedAutomations.contains {
                            $0.entry.id == entry.id && abs($0.scheduledAt.timeIntervalSince(scheduledAt)) < 1
                        }
                        if !isDuplicate {
                            let missed = MissedAutomation(
                                roomID: room.id,
                                roomName: room.name,
                                entry: entry,
                                scheduledAt: scheduledAt
                            )
                            state.missedAutomations.append(missed)
                            decisions.append(.missed(missed))
                        }
                        continue
                    }

                    if claim(entry.id, at: currentDate) {
                        decisions.append(.run(occurrence))
                    }
                }
            }
        }

        let currentMinute = minuteKey(for: currentDate)
        state.firedThisMinute = state.firedThisMinute.filter { $0.value == currentMinute }
        return Evaluation(
            decisions: decisions,
            didChangeOverrides: state.automationOverrides != oldOverrides,
            didChangeMissedAutomations: state.missedAutomations != oldMissedAutomations
        )
    }

    @discardableResult
    func setOverride(for roomID: UUID, duration: AutomationOverrideDuration) -> RoomAutomationOverride {
        let createdAt = now()
        let value: RoomAutomationOverride
        switch duration {
        case .nextSchedule:
            value = RoomAutomationOverride(createdAt: createdAt, expiresAt: nil, skipNextSchedule: true)
        case .oneHour:
            value = RoomAutomationOverride(
                createdAt: createdAt,
                expiresAt: createdAt.addingTimeInterval(3_600),
                skipNextSchedule: false
            )
        case .untilResumed:
            value = RoomAutomationOverride(createdAt: createdAt, expiresAt: nil, skipNextSchedule: false)
        }
        state.automationOverrides[roomID] = value
        return value
    }

    func activeOverride(for roomID: UUID) -> OverrideLookup {
        activeOverride(for: roomID, at: now())
    }

    @discardableResult
    func resumeAutomation(for roomID: UUID) -> Bool {
        state.automationOverrides.removeValue(forKey: roomID) != nil
    }

    @discardableResult
    func removeMissedAutomation(id: UUID) -> Bool {
        let previousCount = state.missedAutomations.count
        state.missedAutomations.removeAll { $0.id == id }
        return state.missedAutomations.count != previousCount
    }

    func occurrences(
        for entry: ScheduleEntry,
        after previous: Date,
        through currentDate: Date,
        solarTimes: SolarTimes
    ) -> [Date] {
        guard previous < currentDate else { return [] }
        var day = calendar.startOfDay(for: previous)
        let finalDay = calendar.startOfDay(for: currentDate)
        var matches: [Date] = []

        while day <= finalDay {
            let weekday = calendar.component(.weekday, from: day)
            if (entry.weekdays.isEmpty || entry.weekdays.contains(weekday)),
               let occurrence = occurrence(for: entry, relativeTo: day, solarTimes: solarTimes),
               occurrence > previous,
               occurrence <= currentDate {
                matches.append(occurrence)
            }
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = nextDay
        }
        return matches
    }

    func occurrence(for entry: ScheduleEntry, relativeTo date: Date, solarTimes: SolarTimes) -> Date? {
        let totalMinutes: Int
        switch entry.action {
        case .atSunrise:
            totalMinutes = solarTimes.sunriseMinutes + entry.offsetMinutes
        case .atSunset:
            totalMinutes = solarTimes.sunsetMinutes + entry.offsetMinutes
        default:
            totalMinutes = max(0, min(1_439, entry.hour * 60 + entry.minute))
        }
        return calendar.date(
            byAdding: .minute,
            value: totalMinutes,
            to: calendar.startOfDay(for: date)
        )
    }

    func nextOccurrence(for entry: ScheduleEntry, solarTimes: SolarTimes) -> Date? {
        let currentDate = now()
        var day = calendar.startOfDay(for: currentDate)
        for _ in 0..<8 {
            let weekday = calendar.component(.weekday, from: day)
            if (entry.weekdays.isEmpty || entry.weekdays.contains(weekday)),
               let occurrence = occurrence(for: entry, relativeTo: day, solarTimes: solarTimes),
               occurrence > currentDate {
                return occurrence
            }
            guard let followingDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = followingDay
        }
        return nil
    }

    func hasEnabledSchedules(in rooms: [Room]) -> Bool {
        rooms.contains { room in room.schedules.contains(where: \.isEnabled) }
    }

    func scheduledMinute(for entry: ScheduleEntry, solarTimes: SolarTimes) -> Int {
        switch entry.action {
        case .atSunrise:
            return max(0, min(1_439, solarTimes.sunriseMinutes + entry.offsetMinutes))
        case .atSunset:
            return max(0, min(1_439, solarTimes.sunsetMinutes + entry.offsetMinutes))
        default:
            return max(0, min(1_439, entry.hour * 60 + entry.minute))
        }
    }

    func conflicts(in entries: [ScheduleEntry], solarTimes: SolarTimes) -> [Conflict] {
        let enabledEntries = entries.filter(\.isEnabled)
        guard enabledEntries.count > 1 else { return [] }
        var conflicts: [Conflict] = []
        for firstIndex in 0..<(enabledEntries.count - 1) {
            for secondIndex in (firstIndex + 1)..<enabledEntries.count {
                let first = enabledEntries[firstIndex]
                let second = enabledEntries[secondIndex]
                if abs(
                    scheduledMinute(for: first, solarTimes: solarTimes)
                        - scheduledMinute(for: second, solarTimes: solarTimes)
                ) <= 5 {
                    conflicts.append(Conflict(first: first, second: second))
                }
            }
        }
        return conflicts
    }

    private func activeOverride(for roomID: UUID, at date: Date) -> OverrideLookup {
        guard let value = state.automationOverrides[roomID] else {
            return OverrideLookup(value: nil, didRemoveExpired: false)
        }
        guard value.isActive(at: date) else {
            state.automationOverrides.removeValue(forKey: roomID)
            return OverrideLookup(value: nil, didRemoveExpired: true)
        }
        return OverrideLookup(value: value, didRemoveExpired: false)
    }

    private func minuteKey(for date: Date) -> String {
        String(
            format: "%02d:%02d",
            calendar.component(.hour, from: date),
            calendar.component(.minute, from: date)
        )
    }

    private func claim(_ entryID: UUID, at date: Date) -> Bool {
        let key = minuteKey(for: date)
        guard state.firedThisMinute[entryID] != key else { return false }
        state.firedThisMinute[entryID] = key
        return true
    }
}
