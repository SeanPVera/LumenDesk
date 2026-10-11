import Foundation

enum ScheduleAction: String, Codable, CaseIterable {
    case turnOn    = "turnOn"
    case turnOff   = "turnOff"
    case dim10     = "dim10"
    case dim25     = "dim25"
    case dim50     = "dim50"
    case dim75     = "dim75"
    case atSunrise = "atSunrise"
    case atSunset  = "atSunset"

    var displayName: String {
        switch self {
        case .turnOn:    return "Turn On"
        case .turnOff:   return "Turn Off"
        case .dim10:     return "Dim to 10%"
        case .dim25:     return "Dim to 25%"
        case .dim50:     return "Dim to 50%"
        case .dim75:     return "Dim to 75%"
        case .atSunrise: return "At Sunrise"
        case .atSunset:  return "At Sunset"
        }
    }

    var brightnessValue: Double? {
        switch self {
        case .dim10: return 0.10
        case .dim25: return 0.25
        case .dim50: return 0.50
        case .dim75: return 0.75
        default:     return nil
        }
    }

    /// True for the two solar-relative action types.
    var isRelativeToSun: Bool {
        self == .atSunrise || self == .atSunset
    }
}

struct ScheduleEntry: Identifiable, Equatable {
    /// Keep legacy offsets beyond the editor's two-hour choices while bounding
    /// the adjacent solar days the scheduler must consider.
    static let supportedOffsetMinutes = -1440...1440

    let id: UUID
    var isEnabled: Bool
    var hour: Int       // 0–23 (absolute time; ignored for sun-relative entries)
    var minute: Int     // 0–59 (absolute); ignored for sun-relative entries
    var offsetMinutes: Int  // signed offset applied to sunrise/sunset base time
    var action: ScheduleAction
    /// Calendar weekday numbers (1 = Sunday ... 7 = Saturday). Empty means every day.
    var weekdays: Set<Int>

    init(id: UUID = UUID(), isEnabled: Bool = true,
         hour: Int, minute: Int, offsetMinutes: Int = 0, action: ScheduleAction,
         weekdays: Set<Int> = Set(1...7)) {
        self.id = id
        self.isEnabled = isEnabled
        self.hour = hour
        self.minute = minute
        self.offsetMinutes = offsetMinutes
        self.action = action
        self.weekdays = weekdays
        self = normalized()
    }

    /// Imported or subsequently mutated values must be safe to format and
    /// evaluate. Disable malformed rules instead of silently running them at
    /// a corrected time or on additional days. Empty weekdays still means daily.
    func normalized() -> ScheduleEntry {
        var value = self
        let validDays = weekdays.filter { (1...7).contains($0) }
        let invalidTime = action.isRelativeToSun
            ? !Self.supportedOffsetMinutes.contains(offsetMinutes)
            : !(0...23).contains(hour) || !(0...59).contains(minute)
        if invalidTime || validDays != weekdays {
            value.isEnabled = false
        }
        let (hourMinutes, hourOverflow) = hour.multipliedReportingOverflow(by: 60)
        let (totalMinutes, minuteOverflow) = hourMinutes.addingReportingOverflow(minute)
        let safeMinute = hourOverflow || minuteOverflow
            ? (hour < 0 ? 0 : 1439)
            : max(0, min(1439, totalMinutes))
        value.hour = safeMinute / 60
        value.minute = safeMinute % 60
        value.offsetMinutes = max(Self.supportedOffsetMinutes.lowerBound,
                                  min(Self.supportedOffsetMinutes.upperBound, offsetMinutes))
        value.weekdays = validDays
        return value
    }

    var daySummary: String {
        let days = weekdays.isEmpty ? Set(1...7) : weekdays.filter { (1...7).contains($0) }
        guard !days.isEmpty else { return "No valid days" }
        if days == Set(1...7) { return "Every day" }
        if days == Set(2...6) { return "Weekdays" }
        if days == Set([1, 7]) { return "Weekends" }
        let symbols = Calendar.current.veryShortWeekdaySymbols
        return days.sorted().map { symbols[$0 - 1] }.joined(separator: ", ")
    }

    var timeString: String {
        if action.isRelativeToSun {
            let symbol = action == .atSunrise ? "↑" : "↓"
            if offsetMinutes == 0 { return symbol }
            let sign = offsetMinutes > 0 ? "+" : ""
            return "\(symbol) \(sign)\(offsetMinutes)m"
        }
        var components = DateComponents()
        let value = normalized()
        components.hour = value.hour; components.minute = value.minute
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

extension ScheduleEntry: Codable {
    enum CodingKeys: String, CodingKey {
        case id, isEnabled, hour, minute, offsetMinutes, action, weekdays
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        hour = try c.decode(Int.self, forKey: .hour)
        minute = try c.decode(Int.self, forKey: .minute)
        offsetMinutes = (try? c.decode(Int.self, forKey: .offsetMinutes)) ?? 0
        action = try c.decode(ScheduleAction.self, forKey: .action)
        weekdays = (try? c.decode(Set<Int>.self, forKey: .weekdays)) ?? Set(1...7)
        self = normalized()
    }
}
