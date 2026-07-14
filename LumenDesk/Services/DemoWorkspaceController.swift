import Foundation
import SwiftUI

/// A device-level snapshot used by undo, effects, rehearsals, and workspace
/// transitions. Keeping it value-based prevents demo devices from sharing
/// mutable state with the saved live workspace.
struct LightRuntimeSnapshot {
    let deviceID: String
    let isOn: Bool
    let brightness: Double
    let color: Color
    let kelvin: Int
    let segments: GoveeSegmentState?
}

struct ExpectedDeviceState {
    var isOn: Bool?
    var brightness: Double?
    var color: (red: Double, green: Double, blue: Double)?
    var kelvin: Int?
}

/// Owns the isolated demo workspace and the live workspace held while Demo
/// Mode is active. UI-facing publication remains with LightManager; this type
/// owns the workspace transitions and isolation decisions.
@MainActor
final class DemoWorkspaceController {
    struct WorkspaceState {
        var devices: [LightDevice]
        var rooms: [Room]
        var favoriteIDs: Set<String>
        var scenes: [LightingScene]
        var isScanning: Bool
        var scanPhase: String
        var lastScanDate: Date?
        var scanResponseCount: Int
        var statusMessage: String
        var commandError: String?
        var commandErrorUndo: (() -> Void)?
        var commandPendingIDs: Set<String>
        var canUndo: Bool
        var canRedo: Bool
        var collapsedRooms: Set<UUID>
        var lastDeletedRoom: (room: Room, index: Int)?
        var lastDeletedScene: (scene: LightingScene, index: Int)?
        var stalenessGeneration: Int
        var newlyDiscoveredIDs: Set<String>
        var whiteModeDeviceIDs: Set<String>
        var napPhase: NapPhase
        var napSnapshotBrightness: [String: Double]
        var activeEffects: [LightScope: String]
        var activityEvents: [ActivityEvent]
        var lastSceneResult: SceneApplicationResult?
        var favoriteOrder: [FavoriteReference]
        var parliamentMembers: [ParliamentMember]
        var parliamentSessions: [ParliamentSession]
        var fireflyCitizens: [FireflyCitizen]
        var sceneCertifications: [SceneCertification]
        var recentColors: [RecentColor]
        var commandStates: [String: DeviceCommandState]
        var confirmedStates: [String: ConfirmedDeviceState]
        var discoveryChanges: [DiscoveryChange]
        var automationOverrides: [UUID: RoomAutomationOverride]
        var missedAutomations: [MissedAutomation]
        var sceneRevisions: [SceneRevision]
        var sceneDrafts: [UUID: LightingScene]
        var lastActionSummary: String?
        var rehearsalSnapshot: [LightRuntimeSnapshot]
        var rehearsalSceneID: UUID?
        var goveeSegmentStates: [String: GoveeSegmentState]
        var goveeSegmentPresets: [GoveeSegmentPreset]
        var customNames: [String: String]
        var favoriteRoomIDs: Set<UUID>
        var favoriteSceneIDs: Set<UUID>
        var customBrightnessPresets: [Double]
        var sunriseHour: Int
        var sunriseMinute: Int
        var sunsetHour: Int
        var sunsetMinute: Int
        var scheduleFiredThisMinute: [UUID: String]
        var lastScheduleCheck: Date?
        var undoStack: [[LightRuntimeSnapshot]]
        var redoStack: [[LightRuntimeSnapshot]]
        var lastChangeTime: [String: Date]
        var expectedStates: [String: ExpectedDeviceState]
        var razerActiveIDs: Set<String>
        var scanStartingIDs: Set<String>
        var scanStartingAddresses: [String: String]
    }

    struct DiscoveryResult {
        let responseCount: Int
        var phase: String { "Demo scan complete: \(responseCount) simulated responses" }
    }

    private let now: () -> Date
    private let discoveryDelayNanoseconds: UInt64
    private var liveWorkspace: WorkspaceState?
    private var discoveryTask: Task<Void, Never>?

    private(set) var isActive = false

    var allowsLivePersistence: Bool { !isActive }
    var allowsLiveNetworking: Bool { !isActive }
    var acceptsLiveNetworkCallbacks: Bool { !isActive }

    init(
        now: @escaping () -> Date = Date.init,
        discoveryDelayNanoseconds: UInt64 = 600_000_000
    ) {
        self.now = now
        self.discoveryDelayNanoseconds = discoveryDelayNanoseconds
    }

    func enter(liveWorkspace: WorkspaceState) -> WorkspaceState? {
        guard !isActive else { return nil }
        self.liveWorkspace = liveWorkspace
        isActive = true
        return makeDemoWorkspace(preserving: liveWorkspace)
    }

    func reset(currentWorkspace: WorkspaceState) -> WorkspaceState? {
        guard isActive else { return nil }
        cancelSimulatedDiscovery()
        return makeDemoWorkspace(preserving: currentWorkspace)
    }

    func exit() -> WorkspaceState? {
        guard isActive, var restored = liveWorkspace else { return nil }
        cancelSimulatedDiscovery()
        liveWorkspace = nil
        isActive = false

        // These operations were intentionally cancelled when Demo Mode was
        // entered in the original behavior; resumable effects, nap state, and
        // pending device commands are restored by LightManager after apply.
        restored.isScanning = false
        restored.rehearsalSnapshot = []
        restored.rehearsalSceneID = nil
        return restored
    }

    func simulateDiscovery(
        devices: [LightDevice],
        completion: @escaping @MainActor (DiscoveryResult) -> Void
    ) {
        guard isActive else { return }
        discoveryTask?.cancel()
        let responseCount = devices.filter { !$0.isStale }.count
        let delay = discoveryDelayNanoseconds
        discoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self, self.isActive else { return }
            completion(DiscoveryResult(responseCount: responseCount))
        }
    }

    func cancelSimulatedDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
    }

    private func makeDemoWorkspace(preserving current: WorkspaceState) -> WorkspaceState {
        var workspace = current
        let timestamp = now()
        let palette: [Color] = [.orange, .cyan, .purple, .mint, .pink, .yellow]
        let names = ["Desk Glow", "Desk COB Strip", "Window Wash", "Shelf String Lights", "Floor Lamp", "Ceiling"]
        let skus: [String?] = [nil, "H619A", nil, "H70C1", nil, nil]

        workspace.devices = (0..<6).map { index in
            let device = LightDevice(
                id: "demo:\(index)",
                brand: index.isMultiple(of: 2) ? .lifx : .govee,
                backendID: "SIM-\(index)",
                name: names[index],
                address: "Simulation",
                sku: skus[index],
                isOn: index != 4,
                brightness: 0.35 + Double(index) * 0.1,
                color: palette[index],
                kelvin: 2700 + index * 500
            )
            device.lastSeen = timestamp
            if index == 4 {
                device.isStale = true
                device.lastSeen = timestamp.addingTimeInterval(-600)
            }
            return device
        }

        let office = Room(
            name: "Demo Office",
            lightIDs: Array(workspace.devices.prefix(3).map(\.id)),
            schedules: [ScheduleEntry(hour: 9, minute: 0, action: .turnOn)]
        )
        let lounge = Room(
            name: "Demo Lounge",
            lightIDs: Array(workspace.devices.suffix(3).map(\.id)),
            schedules: [ScheduleEntry(hour: 22, minute: 30, action: .turnOff)]
        )
        workspace.rooms = [office, lounge]

        let snapshots = Dictionary(uniqueKeysWithValues: workspace.devices.map { device in
            let hsb = device.color.hsbComponents
            return (device.id, DeviceSnapshot(
                isOn: device.isOn,
                brightness: device.brightness,
                hue: hsb.h,
                saturation: hsb.s,
                kelvin: device.kelvin,
                segments: nil
            ))
        })
        workspace.scenes = [LightingScene(name: "Demo Focus", snapshots: snapshots)]
        workspace.favoriteIDs = [workspace.devices[0].id, workspace.devices[3].id]
        workspace.favoriteRoomIDs = [office.id]
        workspace.favoriteSceneIDs = Set(workspace.scenes.map(\.id))
        let favoriteSet = Set(
            workspace.favoriteIDs.map { FavoriteReference(kind: .light, rawID: $0) }
                + workspace.favoriteRoomIDs.map { FavoriteReference(kind: .room, rawID: $0.uuidString) }
                + workspace.favoriteSceneIDs.map { FavoriteReference(kind: .scene, rawID: $0.uuidString) }
        )
        workspace.favoriteOrder = favoriteSet.sorted { $0.id < $1.id }

        workspace.customNames = [:]
        workspace.collapsedRooms = []
        workspace.whiteModeDeviceIDs = []
        workspace.customBrightnessPresets = [0.1, 0.35, 0.7]
        workspace.goveeSegmentStates = [:]
        workspace.goveeSegmentPresets = []
        workspace.activityEvents = [ActivityEvent(
            kind: .system,
            title: "Demo mode entered",
            detail: "Using isolated simulated lights and rooms.",
            date: timestamp
        )]
        workspace.parliamentMembers = []
        workspace.parliamentSessions = []
        workspace.fireflyCitizens = []
        workspace.sceneCertifications = []
        workspace.recentColors = []
        workspace.automationOverrides = [:]
        workspace.missedAutomations = []
        workspace.sceneRevisions = []
        workspace.sceneDrafts = [:]
        workspace.lastDeletedRoom = nil
        workspace.lastDeletedScene = nil
        workspace.lastSceneResult = nil
        workspace.lastActionSummary = nil
        workspace.rehearsalSnapshot = []
        workspace.rehearsalSceneID = nil
        workspace.commandPendingIDs = []
        workspace.commandStates = [:]
        workspace.confirmedStates = [:]
        workspace.expectedStates = [:]
        workspace.discoveryChanges = []
        workspace.newlyDiscoveredIDs = []
        workspace.activeEffects = [:]
        workspace.napPhase = .inactive
        workspace.napSnapshotBrightness = [:]
        workspace.undoStack = []
        workspace.redoStack = []
        workspace.canUndo = false
        workspace.canRedo = false
        workspace.lastChangeTime = [:]
        workspace.scheduleFiredThisMinute = [:]
        workspace.lastScheduleCheck = nil
        workspace.razerActiveIDs = []
        workspace.scanStartingIDs = []
        workspace.scanStartingAddresses = [:]
        workspace.isScanning = false
        workspace.scanPhase = "Demo workspace"
        workspace.lastScanDate = nil
        workspace.scanResponseCount = 0
        workspace.statusMessage = "Demo workspace is active"
        workspace.commandError = "Demo workspace is active. No physical lights will be changed."
        workspace.commandErrorUndo = nil

        for device in workspace.devices where !device.isStale {
            let rgb = device.color.rgbComponents
            let hex = String(
                format: "#%02X%02X%02X",
                Int(rgb.r * 255),
                Int(rgb.g * 255),
                Int(rgb.b * 255)
            )
            workspace.confirmedStates[device.id] = ConfirmedDeviceState(
                isOn: device.isOn,
                brightness: device.brightness,
                colorHex: hex,
                kelvin: device.kelvin,
                confirmedAt: timestamp
            )
            workspace.commandStates[device.id] = DeviceCommandState(
                phase: .idle,
                summary: "Confirmed",
                updatedAt: timestamp
            )
        }

        return workspace
    }
}
