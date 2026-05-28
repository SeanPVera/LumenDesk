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
    let id: UUID
    var isEnabled: Bool
    var hour: Int       // 0–23 (absolute time; ignored for sun-relative entries)
    var minute: Int     // 0–59 multiples of 15 (absolute); ignored for sun-relative entries
    var offsetMinutes: Int  // signed offset applied to sunrise/sunset base time
    var action: ScheduleAction

    init(id: UUID = UUID(), isEnabled: Bool = true,
         hour: Int, minute: Int, offsetMinutes: Int = 0, action: ScheduleAction) {
        self.id = id
        self.isEnabled = isEnabled
        self.hour = hour
        self.minute = minute
        self.offsetMinutes = offsetMinutes
        self.action = action
    }

    var timeString: String {
        if action.isRelativeToSun {
            let symbol = action == .atSunrise ? "↑" : "↓"
            if offsetMinutes == 0 { return symbol }
            let sign = offsetMinutes > 0 ? "+" : ""
            return "\(symbol) \(sign)\(offsetMinutes)m"
        }
        return String(format: "%02d:%02d", hour, minute)
    }
}

extension ScheduleEntry: Codable {
    enum CodingKeys: String, CodingKey {
        case id, isEnabled, hour, minute, offsetMinutes, action
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        hour = try c.decode(Int.self, forKey: .hour)
        minute = try c.decode(Int.self, forKey: .minute)
        offsetMinutes = (try? c.decode(Int.self, forKey: .offsetMinutes)) ?? 0
        action = try c.decode(ScheduleAction.self, forKey: .action)
    }
}
