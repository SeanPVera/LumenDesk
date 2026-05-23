import Foundation

enum ScheduleAction: String, Codable, CaseIterable {
    case turnOn  = "turnOn"
    case turnOff = "turnOff"
    case dim10   = "dim10"
    case dim25   = "dim25"
    case dim50   = "dim50"
    case dim75   = "dim75"

    var displayName: String {
        switch self {
        case .turnOn:  return "Turn On"
        case .turnOff: return "Turn Off"
        case .dim10:   return "Dim to 10%"
        case .dim25:   return "Dim to 25%"
        case .dim50:   return "Dim to 50%"
        case .dim75:   return "Dim to 75%"
        }
    }

    var brightnessValue: Double? {
        switch self {
        case .dim10: return 0.10
        case .dim25: return 0.25
        case .dim50: return 0.50
        case .dim75: return 0.75
        default: return nil
        }
    }
}

struct ScheduleEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var isEnabled: Bool
    var hour: Int   // 0–23
    var minute: Int // 0–59 (multiples of 15)
    var action: ScheduleAction

    init(id: UUID = UUID(), isEnabled: Bool = true, hour: Int, minute: Int, action: ScheduleAction) {
        self.id = id
        self.isEnabled = isEnabled
        self.hour = hour
        self.minute = minute
        self.action = action
    }

    var timeString: String {
        String(format: "%02d:%02d", hour, minute)
    }
}
