import Foundation
import SwiftUI

enum WorkspaceLayout: String, Codable, CaseIterable, Identifiable {
    case automatic, list, grid
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum SearchScope: String, CaseIterable, Identifiable {
    case all, lights, rooms, scenes
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum InterfaceDensity: String, Codable, CaseIterable, Identifiable {
    case comfortable, compact
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum AggregatePowerState: Equatable {
    case off, mixed(on: Int, total: Int), on

    var title: String {
        switch self {
        case .off: return "All Off"
        case .on: return "All On"
        case .mixed(let on, let total): return "\(on) of \(total) On"
        }
    }

    var symbol: String {
        switch self {
        case .off: return "power"
        case .on: return "power.circle.fill"
        case .mixed: return "circle.lefthalf.filled"
        }
    }
}

struct ActivityEvent: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case scan, command, schedule, scene, recovery, system, parliament, compliance }
    let id: UUID
    let date: Date
    let kind: Kind
    let title: String
    let detail: String
    let isFailure: Bool

    init(kind: Kind, title: String, detail: String = "", isFailure: Bool = false, date: Date = Date()) {
        id = UUID(); self.date = date; self.kind = kind; self.title = title; self.detail = detail; self.isFailure = isFailure
    }
}

struct ScanDiagnostic: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let status: Status
    enum Status { case good, warning, neutral }
}

struct SceneApplicationPreview {
    let scene: LightingScene
    let affected: [LightDevice]
    let unreachable: [LightDevice]
    let missingIDs: [String]
    let unchanged: [LightDevice]
}

struct SceneApplicationResult: Identifiable, Equatable {
    let id = UUID()
    let sceneName: String
    let succeededIDs: [String]
    let failedIDs: [String]
    let skippedOffIDs: [String]
}

struct FavoriteReference: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case light, room, scene }
    let kind: Kind
    let rawID: String
    var id: String { "\(kind.rawValue):\(rawID)" }
}

struct ParliamentMember: Identifiable, Codable, Equatable {
    enum Party: String, Codable, CaseIterable {
        case warmCoalition = "Warm Coalition"
        case chromaticLeft = "Chromatic Left"
        case efficiencyBloc = "Efficiency Bloc"
        case nocturnalCaucus = "Nocturnal Caucus"
    }
    let id: String
    let parliamentaryName: String
    let party: Party
    var approval: Int
    var lastVote: String
}

struct ParliamentSession: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let motion: String
    let ayes: Int
    let noes: Int
    let abstentions: Int
    let verdict: String
}

struct SceneCertification: Identifiable, Codable, Equatable {
    enum Seal: String, Codable { case bronze, silver, gold }
    let id: UUID
    let sceneID: UUID
    let issuedAt: Date
    let score: Int
    let seal: Seal
    let findings: [String]
    let treatyCode: String
}

struct RecentColor: Identifiable, Codable, Equatable {
    let id: UUID
    let red: Double
    let green: Double
    let blue: Double
    let name: String

    init(color: Color, name: String) {
        id = UUID()
        let rgb = color.rgbComponents
        red = rgb.r; green = rgb.g; blue = rgb.b; self.name = name
    }

    var color: Color { Color(red: red, green: green, blue: blue) }
    var hex: String { String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255)) }
}

struct DiscoveryChange: Identifiable, Equatable {
    enum Kind: String { case new = "New", backOnline = "Back online", changed = "Changed", missing = "Still missing" }
    let id: UUID
    let deviceID: String
    let name: String
    let kind: Kind
    let detail: String
    let date: Date

    init(deviceID: String, name: String, kind: Kind, detail: String, date: Date = Date()) {
        id = UUID(); self.deviceID = deviceID; self.name = name; self.kind = kind; self.detail = detail; self.date = date
    }
}

enum AutomationOverrideDuration: String, CaseIterable, Identifiable {
    case nextSchedule, oneHour, untilResumed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .nextSchedule: return "Until next schedule"
        case .oneHour: return "For 1 hour"
        case .untilResumed: return "Until I resume"
        }
    }
}

struct RoomAutomationOverride: Codable, Equatable {
    var createdAt: Date
    var expiresAt: Date?
    var skipNextSchedule: Bool

    var summary: String {
        if skipNextSchedule { return "Paused until next schedule" }
        if let expiresAt { return "Paused until \(expiresAt.formatted(date: .omitted, time: .shortened))" }
        return "Paused until resumed"
    }

    func isActive(at date: Date = Date()) -> Bool { expiresAt.map { $0 > date } ?? true }
}

struct MissedAutomation: Identifiable, Equatable {
    let id = UUID()
    let roomID: UUID
    let roomName: String
    let entry: ScheduleEntry
    let scheduledAt: Date
}

struct SceneRevision: Identifiable, Codable, Equatable {
    let id: UUID
    let sceneID: UUID
    let savedAt: Date
    let label: String
    let name: String
    let snapshots: [String: DeviceSnapshot]

    init(scene: LightingScene, label: String) {
        id = UUID(); sceneID = scene.id; savedAt = Date(); self.label = label; name = scene.name; snapshots = scene.snapshots
    }
}

enum ConfirmationPolicy: String, CaseIterable, Identifiable {
    case balanced, cautious
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum MenuBarScope: String, CaseIterable, Identifiable {
    case favorites, activeRooms, allRooms
    var id: String { rawValue }
    var title: String {
        switch self { case .favorites: return "Favorites"; case .activeRooms: return "Active rooms"; case .allRooms: return "All rooms" }
    }
}

enum AppPreferenceKey {
    static let quietInterface = "LumenDesk.quietInterface.v1"
    static let confirmationPolicy = "LumenDesk.confirmationPolicy.v1"
    static let menuBarScope = "LumenDesk.menuBarScope.v1"
    static let showMenuBarUrgentOnly = "LumenDesk.menuBarUrgentOnly.v1"
    static let audioPrivacyAcknowledged = "LumenDesk.audioPrivacyAcknowledged.v1"
}
