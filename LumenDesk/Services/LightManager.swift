import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum NapPhase: Equatable {
    case inactive
    case dimming(endsAt: Date)
    case holding(endsAt: Date)
    case brightening(endsAt: Date)
}

@MainActor
final class LightManager: ObservableObject {
    @Published private(set) var devices: [LightDevice] = []
    @Published private(set) var rooms: [Room] = []
    @Published private(set) var favoriteIDs: Set<String> = []
    @Published private(set) var scenes: [LightingScene] = []
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var scanPhase: String = "Idle"
    @Published private(set) var lastScanDate: Date?
    @Published private(set) var scanResponseCount: Int = 0
    @Published var statusMessage: String = ""
    @Published var commandError: String?
    @Published var commandErrorUndo: (() -> Void)?  // optional undo action on the error toast
    @Published private(set) var canUndo: Bool = false
    @Published private(set) var canRedo: Bool = false
    @Published private(set) var collapsedRooms: Set<UUID> = []
    // Holds the last deleted room and its position for undo.
    @Published private(set) var lastDeletedRoom: (room: Room, index: Int)? = nil
    @Published private(set) var lastDeletedScene: (scene: LightingScene, index: Int)? = nil
    @Published private(set) var stalenessGeneration: Int = 0
    @Published private(set) var newlyDiscoveredIDs: Set<String> = []
    @Published private(set) var whiteModeDeviceIDs: Set<String> = []
    @Published private(set) var napPhase: NapPhase = .inactive
    @Published private(set) var activeEffects: [LightScope: String] = [:]
    @Published private(set) var activityEvents: [ActivityEvent] = []
    @Published private(set) var lastSceneResult: SceneApplicationResult?
    @Published private(set) var favoriteOrder: [FavoriteReference] = []
    @Published private(set) var parliamentMembers: [ParliamentMember] = []
    @Published private(set) var parliamentSessions: [ParliamentSession] = []
    @Published private(set) var sceneCertifications: [SceneCertification] = []
    @Published private(set) var recentColors: [RecentColor] = []
    @Published private(set) var discoveryChanges: [DiscoveryChange] = []
    @Published private(set) var sceneRevisions: [SceneRevision] = []
    @Published private(set) var sceneDrafts: [UUID: LightingScene] = [:]
    @Published private(set) var lastActionSummary: String?
    @Published private(set) var rehearsalSceneID: UUID?
    // Per-device Govee segment layouts (COB strips, string lights, neon ropes)
    // and reusable multi-color paint jobs, both persisted across sessions.
    @Published private(set) var goveeSegmentStates: [String: GoveeSegmentState] = [:]
    @Published private(set) var goveeSegmentPresets: [GoveeSegmentPreset] = []
    @Published private(set) var lifxMatrixStates: [String: LIFXMatrixState] = [:]
    @Published private(set) var musicModeConfiguration = MusicModeConfiguration.configuration(for: .soundcheck)
    @Published private(set) var fixtureTopologies: [String: FixtureTopology] = [:]

    let musicModeController = AudioReactiveSessionController()

    private var errorClearTask: Task<Void, Never>?
    private var lifx: LIFXClient?
    private var govee: GoveeClient?
    private var refreshTimer: Timer?
    private var scheduleTimer: Timer?
    private var napTimer: Timer?
    private var brightnessTasks: [String: Task<Void, Never>] = [:]
    private var napSnapshotBrightness: [String: Double] = [:]
    private var scanGeneration: Int = 0     // incremented each scan; clears isScanning safely
    private var hasStarted = false
    private var scanStartingIDs: Set<String> = []
    private var scanStartingAddresses: [String: String] = [:]
    private var devicesByID: [String: LightDevice] = [:]
    private let demoWorkspaceController: DemoWorkspaceController
    let confirmationCoordinator: ConfirmationCoordinator
    private let scheduleEngine: ScheduleEngine
    private let persistenceStore: ApplicationPersistence
    private let commandCoordinator: CommandCoordinator
    private var rehearsalSnapshot: [LightRuntimeSnapshot] = []
    // Devices currently streaming a razer-mode segment preview.
    private var razerActiveIDs: Set<String> = []

    // Custom display names keyed by device id, persisted across sessions.
    private var customNames: [String: String] = [:]

    @Published private(set) var favoriteRoomIDs: Set<UUID> = []
    @Published private(set) var favoriteSceneIDs: Set<UUID> = []
    @Published private(set) var customBrightnessPresets: [Double] = []

    // Configurable sunrise/sunset times (hour and minute).
    @Published var sunriseHour: Int   = 6
    @Published var sunriseMinute: Int = 30
    @Published var sunsetHour: Int    = 20
    @Published var sunsetMinute: Int  = 30

    // MARK: - Undo / redo state
    /// One animated effect running against one scope. Several runs can be
    /// active at once as long as their device sets don't overlap (e.g. a
    /// different effect per room).
    private final class EffectRun {
        let id = UUID()
        let effect: LightingEffect
        let scope: LightScope
        var phase: Double = 0
        var snapshot: [LightRuntimeSnapshot]
        var timer: Timer?
        var restorePreviousState: Bool
        var reducedMotion: Bool
        // Network effects may run faster than the UI needs to redraw. Keep the
        // device model at a smooth 4 fps while commands retain their full cadence.
        var modelUpdateElapsed: TimeInterval = .greatestFiniteMagnitude
        init(effect: LightingEffect, scope: LightScope, snapshot: [LightRuntimeSnapshot], restorePreviousState: Bool = true, reducedMotion: Bool = false) {
            self.effect = effect
            self.scope = scope
            self.snapshot = snapshot
            self.restorePreviousState = restorePreviousState
            self.reducedMotion = reducedMotion
        }
    }
    private var effectRuns: [LightScope: EffectRun] = [:]
    private let musicLightingRenderer = MusicLightingRenderer()
    private var musicModelUpdateAt: [String: TimeInterval] = [:]
    private var undoStack: [[LightRuntimeSnapshot]] = []
    private var redoStack: [[LightRuntimeSnapshot]] = []
    private var lastChangeTime: [String: Date] = [:]
    private let undoLimit = 20
    private let coalesceWindow: TimeInterval = 1.0

    // MARK: - Init

    init(
        defaults: UserDefaults = .standard,
        demoWorkspaceController: DemoWorkspaceController? = nil,
        confirmationCoordinator: ConfirmationCoordinator? = nil,
        scheduleEngine: ScheduleEngine? = nil,
        persistenceStore: ApplicationPersistence? = nil,
        commandCoordinator: CommandCoordinator? = nil
    ) {
        self.demoWorkspaceController = demoWorkspaceController ?? DemoWorkspaceController()
        self.confirmationCoordinator = confirmationCoordinator ?? ConfirmationCoordinator(defaults: defaults)
        self.scheduleEngine = scheduleEngine ?? ScheduleEngine()
        self.persistenceStore = persistenceStore ?? PersistenceStore.live(legacyDefaults: defaults)
        self.commandCoordinator = commandCoordinator ?? CommandCoordinator()
        let persistedState = self.persistenceStore.load()
        rooms = persistedState.rooms
        favoriteIDs = persistedState.favoriteIDs
        scenes = persistedState.scenes
        customNames = persistedState.customNames
        collapsedRooms = persistedState.collapsedRooms
        favoriteRoomIDs = persistedState.favoriteRoomIDs
        favoriteSceneIDs = persistedState.favoriteSceneIDs
        customBrightnessPresets = persistedState.customBrightnessPresets
        whiteModeDeviceIDs = persistedState.whiteModeDeviceIDs
        sunriseHour = persistedState.solarPreferences.sunriseHour
        sunriseMinute = persistedState.solarPreferences.sunriseMinute
        sunsetHour = persistedState.solarPreferences.sunsetHour
        sunsetMinute = persistedState.solarPreferences.sunsetMinute
        activityEvents = persistedState.activityEvents
        favoriteOrder = persistedState.favoriteOrder
        parliamentMembers = persistedState.parliamentMembers
        parliamentSessions = persistedState.parliamentSessions
        sceneCertifications = persistedState.sceneCertifications
        recentColors = persistedState.recentColors
        if scheduleEngine == nil {
            self.scheduleEngine.restoreAutomationOverrides(
                persistedState.automationOverrides
            )
        }
        sceneRevisions = persistedState.sceneRevisions
        sceneDrafts = persistedState.sceneDrafts
        goveeSegmentStates = persistedState.goveeSegmentStates
        goveeSegmentPresets = persistedState.goveeSegmentPresets
        musicModeConfiguration = persistedState.musicModeConfiguration
        fixtureTopologies = persistedState.fixtureTopologies
        self.commandCoordinator.onChange = { [weak self] in
            self?.objectWillChange.send()
        }
    }

    var isDemoMode: Bool { demoWorkspaceController.isActive }
    var automationOverrides: [UUID: RoomAutomationOverride] { scheduleEngine.automationOverrides }
    var missedAutomations: [MissedAutomation] { scheduleEngine.missedAutomations }
    var commandPendingIDs: Set<String> { commandCoordinator.pendingDeviceIDs }
    var commandStates: [String: DeviceCommandState] { commandCoordinator.commandStates }
    var confirmedStates: [String: ConfirmedDeviceState] { commandCoordinator.confirmedStates }

    private var scheduleSolarTimes: ScheduleEngine.SolarTimes {
        ScheduleEngine.SolarTimes(
            sunriseMinutes: sunriseHour * 60 + sunriseMinute,
            sunsetMinutes: sunsetHour * 60 + sunsetMinute
        )
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        do {
            let lx = try LIFXClient()
            lx.delegate = self
            self.lifx = lx
        } catch {
            statusMessage = "LIFX init failed: \(error)"
        }
        do {
            let gv = try GoveeClient()
            gv.delegate = self
            self.govee = gv
        } catch {
            statusMessage = "Govee init failed: \(error). Is another app already bound to UDP 4002?"
        }
        scan()
        scheduleRefresh()
        startScheduleTimer()
        logActivity(.system, title: "LumenDesk started", detail: "Local automation and discovery services are active.")
    }

    func scan() {
        if isDemoMode {
            isScanning = true
            scanPhase = "Scanning simulated lights"
            lastScanDate = Date()
            scanResponseCount = 0
            scanGeneration += 1
            let generation = scanGeneration
            demoWorkspaceController.simulateDiscovery(devices: devices) { [weak self] result in
                guard let self, self.scanGeneration == generation else { return }
                self.scanResponseCount = result.responseCount
                self.isScanning = false
                self.scanPhase = result.phase
                self.logActivity(.scan, title: "Demo scan completed", detail: result.phase)
            }
            return
        }
        logActivity(.scan, title: "Discovery scan started", detail: "Broadcasting to LIFX and Govee devices.")
        isScanning = true
        discoveryChanges = []
        scanStartingIDs = Set(devices.map(\.id))
        scanStartingAddresses = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.address) })
        scanPhase = "Sending discovery broadcasts"
        lastScanDate = Date()
        scanResponseCount = 0
        lifx?.discover()
        govee?.discover()
        scanGeneration += 1
        let gen = scanGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            Task { @MainActor in
                guard let self, self.scanGeneration == gen else { return }
                self.scanPhase = "Querying bulb state"
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            Task { @MainActor in
                guard let self, self.scanGeneration == gen else { return }
                self.isScanning = false
                self.scanPhase = self.scanResponseCount == 0 ? "No responses found" : "Scan complete: \(self.scanResponseCount) response\(self.scanResponseCount == 1 ? "" : "s")"
                let seenSinceScan = Set(self.devices.filter { $0.lastSeen >= (self.lastScanDate ?? .distantPast) }.map(\.id))
                for id in self.scanStartingIDs.subtracting(seenSinceScan) {
                    if let device = self.device(withID: id) {
                        self.appendDiscoveryChange(device, kind: .missing, detail: "No response during this scan")
                    }
                }
                self.logActivity(.scan, title: self.scanResponseCount == 0 ? "Scan found no lights" : "Scan completed", detail: self.scanPhase, isFailure: self.scanResponseCount == 0)
            }
        }
    }

    private func scheduleRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
        refreshTimer?.tolerance = 3
    }

    private func startScheduleTimer() {
        scheduleTimer?.invalidate()
        let delay = scheduleEngine.delayUntilNextMinute
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.checkSchedules()
                self.scheduleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.checkSchedules() }
                }
                self.scheduleTimer?.tolerance = 1
            }
        }
    }

    private func checkSchedules() {
        let evaluation = scheduleEngine.evaluate(rooms: rooms, solarTimes: scheduleSolarTimes)
        if evaluation.didChangeOverrides || evaluation.didChangeMissedAutomations {
            objectWillChange.send()
        }
        if evaluation.didChangeOverrides {
            persistApplicationState()
        }

        for decision in evaluation.decisions {
            switch decision {
            case let .skipped(occurrence, consumedSkipOverride):
                if consumedSkipOverride { lastActionSummary = "Automation resumed" }
                logActivity(
                    .schedule,
                    title: "Automation skipped",
                    detail: "\(occurrence.roomName): manual override was active"
                )
            case let .missed(missed):
                logActivity(
                    .schedule,
                    title: "Automation needs review",
                    detail: "\(missed.roomName): \(missed.entry.action.displayName) was missed while LumenDesk was unavailable"
                )
            case let .run(occurrence):
                guard let room = rooms.first(where: { $0.id == occurrence.roomID }) else { continue }
                let entry = occurrence.entry
                logActivity(
                    .schedule,
                    title: "Automation ran",
                    detail: "\(room.name): \(entry.action.displayName) at \(entry.timeString)"
                )
                let lights = devices(in: room)
                switch entry.action {
                case .turnOn, .atSunrise:
                    for device in lights {
                        device.isOn = true
                        sendPower(device, on: true)
                    }
                case .turnOff, .atSunset:
                    for device in lights {
                        device.isOn = false
                        sendPower(device, on: false)
                    }
                default:
                    if let brightness = entry.action.brightnessValue {
                        for device in lights {
                            device.brightness = brightness
                            sendBrightness(device, value: brightness)
                        }
                    }
                }
            }
        }
    }

    func setAutomationOverride(for roomID: UUID, duration: AutomationOverrideDuration) {
        objectWillChange.send()
        let value = scheduleEngine.setOverride(for: roomID, duration: duration)
        persistApplicationState()
        lastActionSummary = "Automation paused — \(value.summary)"
    }

    func activeAutomationOverride(for roomID: UUID) -> RoomAutomationOverride? {
        let lookup = scheduleEngine.activeOverride(for: roomID)
        if lookup.didRemoveExpired {
            objectWillChange.send()
            persistApplicationState()
        }
        return lookup.value
    }

    func resumeAutomation(for roomID: UUID) {
        guard scheduleEngine.resumeAutomation(for: roomID) else { return }
        objectWillChange.send()
        persistApplicationState()
        lastActionSummary = "Automation resumed"
    }

    func runMissedAutomation(_ missed: MissedAutomation) {
        guard let room = rooms.first(where: { $0.id == missed.roomID }) else { return }
        let lights = devices(in: room)
        if let brightness = missed.entry.action.brightnessValue {
            for device in lights { device.brightness = brightness; sendBrightness(device, value: brightness) }
        } else {
            let on = missed.entry.action == .turnOn || missed.entry.action == .atSunrise
            for device in lights { device.isOn = on; sendPower(device, on: on) }
        }
        if scheduleEngine.removeMissedAutomation(id: missed.id) { objectWillChange.send() }
    }

    func skipMissedAutomation(_ missed: MissedAutomation) {
        if scheduleEngine.removeMissedAutomation(id: missed.id) { objectWillChange.send() }
    }

    private func refreshAll() {
        guard demoWorkspaceController.allowsLiveNetworking else { return }
        let now = Date()
        for d in devices {
            if now.timeIntervalSince(d.lastSeen) > 75, !d.isStale {
                d.isStale = true
                stalenessGeneration += 1  // triggers manager @Published, re-renders rooms
            }
            switch d.brand {
            case .lifx:  lifx?.refresh(macHex: d.backendID)
            case .govee:
                govee?.refresh(deviceID: d.backendID)
                // Doubles as the stream-hold keepalive: held layouts are
                // re-pushed every tick so power cycles, reboots, and razer
                // inactivity timeouts heal within one refresh interval.
                reassertStreamHoldIfNeeded(d)
            }
        }
    }

    private func markSeen(_ device: LightDevice, confirmsPendingCommand: Bool = false) {
        let wasStale = device.isStale
        device.lastSeen = Date()
        device.isStale = false
        let rgb = device.color.rgbComponents
        let hex = String(format: "#%02X%02X%02X", Int(rgb.r * 255), Int(rgb.g * 255), Int(rgb.b * 255))
        commandCoordinator.recordObservation(
            deviceID: device.id,
            confirmedState: ConfirmedDeviceState(
                isOn: device.isOn,
                brightness: device.brightness,
                colorHex: hex,
                kelvin: device.kelvin,
                confirmedAt: Date()
            ),
            confirmsPendingCommand: confirmsPendingCommand
        )
        if wasStale {
            appendDiscoveryChange(device, kind: .backOnline, detail: "Responded again")
            // A light that dropped off and came back likely power-cycled,
            // which clears the razer overlay stream-hold layouts live in.
            reassertStreamHoldIfNeeded(device)
        }
    }

    private func reportedStateMatchesExpectation(
        deviceID: String,
        isOn: Bool,
        brightness: Double,
        red: Double,
        green: Double,
        blue: Double,
        kelvin: Int
    ) -> Bool {
        commandCoordinator.reportedStateMatchesExpectation(
            deviceID: deviceID,
            reported: ReportedDeviceState(
                isOn: isOn,
                brightness: brightness,
                red: red,
                green: green,
                blue: blue,
                kelvin: kelvin
            )
        )
    }

    private func expectPower(_ device: LightDevice, on: Bool) {
        guard demoWorkspaceController.allowsLiveNetworking else { return }
        commandCoordinator.expectPower(deviceID: device.id, isOn: on)
    }

    private func expectBrightness(_ device: LightDevice, value: Double) {
        guard demoWorkspaceController.allowsLiveNetworking else { return }
        commandCoordinator.expectBrightness(deviceID: device.id, brightness: value)
    }

    private func expectColor(_ device: LightDevice, color: Color) {
        guard demoWorkspaceController.allowsLiveNetworking else { return }
        let rgb = color.rgbComponents
        commandCoordinator.expectColor(deviceID: device.id, red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    private func expectKelvin(_ device: LightDevice, kelvin: Int) {
        guard demoWorkspaceController.allowsLiveNetworking else { return }
        commandCoordinator.expectKelvin(deviceID: device.id, kelvin: kelvin)
    }

    private func refresh(_ device: LightDevice) {
        guard demoWorkspaceController.allowsLiveNetworking else { return }
        switch device.brand {
        case .lifx: lifx?.refresh(macHex: device.backendID)
        case .govee: govee?.refresh(deviceID: device.backendID)
        }
    }

    private func appendDiscoveryChange(_ device: LightDevice, kind: DiscoveryChange.Kind, detail: String) {
        guard !discoveryChanges.contains(where: { $0.deviceID == device.id && $0.kind == kind }) else { return }
        discoveryChanges.append(DiscoveryChange(deviceID: device.id, name: device.label, kind: kind, detail: detail))
    }

    func clearDiscoveryChanges() { discoveryChanges = [] }

    // MARK: - Custom display names

    func setCustomName(_ deviceID: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            customNames.removeValue(forKey: deviceID)
        } else {
            customNames[deviceID] = trimmed
        }
        if let device = device(withID: deviceID) {
            device.customName = trimmed.isEmpty ? nil : trimmed
        }
        persistApplicationState()
    }

    // MARK: - Solar preferences

    func setSunriseTime(hour: Int, minute: Int) {
        sunriseHour = hour; sunriseMinute = minute; persistApplicationState()
    }
    func setSunsetTime(hour: Int, minute: Int) {
        sunsetHour = hour; sunsetMinute = minute; persistApplicationState()
    }

    // MARK: - Room expansion state

    func toggleRoomExpansion(_ roomID: UUID) {
        if collapsedRooms.contains(roomID) {
            collapsedRooms.remove(roomID)
        } else {
            collapsedRooms.insert(roomID)
        }
        persistApplicationState()
    }

    func isRoomExpanded(_ roomID: UUID) -> Bool { !collapsedRooms.contains(roomID) }

    // MARK: - Error / toast

    func dismissLastActionSummary() { lastActionSummary = nil }

    private func announceAction(_ title: String, lights: [LightDevice]) {
        lastActionSummary = "\(title) · \(lights.count) light\(lights.count == 1 ? "" : "s")"
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if self?.lastActionSummary?.hasPrefix(title) == true { self?.lastActionSummary = nil }
        }
    }

    func publishError(_ message: String, undo: (() -> Void)? = nil) {
        commandError = message
        commandErrorUndo = undo
        scheduleErrorClear()
    }

    private func scheduleErrorClear() {
        errorClearTask?.cancel()
        errorClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled {
                self.commandError = nil
                self.commandErrorUndo = nil
            }
        }
    }

    // MARK: - Command queue and confirmed state

    private func enqueueCommand(for device: LightDevice, coalescingKey: String, summary: String, debounce: TimeInterval = 0.08, operation: @escaping @MainActor () -> Void) {
        let simulated = isDemoMode ? CommandCoordinator.SimulatedCommand(
            isStale: { [weak device] in device?.isStale ?? true },
            didFail: { [weak self, weak device] in
                guard let self, let device else { return }
                self.publishError("Demo failure: \(device.label) intentionally did not respond.")
            }
        ) : nil
        commandCoordinator.enqueue(
            deviceID: device.id,
            coalescingKey: coalescingKey,
            summary: summary,
            debounceNanoseconds: UInt64(max(0, debounce) * 1_000_000_000),
            simulated: simulated,
            send: operation,
            refresh: { [weak self, weak device] in
                guard let self, let device else { return }
                self.refresh(device)
            },
            timedOut: { [weak self, weak device] in
                guard let self, let device else { return }
                self.publishError("\(device.label) did not confirm the change. Keep trying or rescan.")
            }
        )
    }

    func cancelQueuedCommands(deviceIDs: Set<String>? = nil) {
        let ids = commandCoordinator.cancel(deviceIDs: deviceIDs)
        lastActionSummary = "Cancelled \(ids.count) queued command\(ids.count == 1 ? "" : "s")"
    }

    func retryCommand(for device: LightDevice) {
        commandCoordinator.retry(
            deviceID: device.id,
            refresh: { [weak self, weak device] in
                guard let self, let device else { return }
                self.refresh(device)
            },
            timedOut: { [weak self, weak device] in
                guard let self, let device else { return }
                self.publishError("\(device.label) did not confirm the change. Keep trying or rescan.")
            }
        )
    }

    func commandState(for deviceID: String) -> DeviceCommandState {
        commandCoordinator.commandState(for: deviceID)
    }

    // MARK: - Control

    func setPower(_ device: LightDevice, on: Bool) {
        if device.isStale {
            publishError("\u{201C}\(device.label)\u{201D} may be offline — command sent anyway.")
        }
        recordChange([device])
        device.isOn = on
        sendPower(device, on: on)
        // Powering a stream-hold device back on restores its held segment
        // layout immediately instead of waiting for the next refresh tick.
        if on { reassertStreamHoldIfNeeded(device) }
    }

    func setBrightness(_ device: LightDevice, value: Double) {
        recordChange([device])
        device.brightness = value
        sendBrightness(device, value: value)
    }

    func setColor(_ device: LightDevice, color: Color) {
        rememberColor(color, name: "Custom")
        if device.isStale {
            publishError("\u{201C}\(device.label)\u{201D} may be offline — command sent anyway.")
        }
        recordChange([device])
        device.color = color
        sendColor(device, color: color)
    }

    func setKelvin(_ device: LightDevice, kelvin: Int) {
        recordChange([device])
        device.kelvin = kelvin
        sendColorTemperature(device, kelvin: kelvin)
    }

    // MARK: - Room & global bulk controls

    func setPower(in room: Room, on: Bool) {
        let lights = devices(in: room)
        guard !lights.isEmpty else {
            publishError("“\(room.name)” has no lights to control.")
            return
        }
        if lights.count > 1 {
            let verb = on ? "Turn On" : "Turn Off"
            confirmationCoordinator.request(
                .init(
                    title: "\(verb) \(room.name)?",
                    message: "This will change all \(lights.count) lights in the room. You can undo the change afterward.",
                    confirmTitle: verb
                ),
                action: { [weak self] in self?.performSetPower(in: room, on: on) }
            )
            return
        }
        performSetPower(in: room, on: on)
    }

    private func performSetPower(in room: Room, on: Bool) {
        let lights = devices(in: room)
        guard !lights.isEmpty else { return }
        let staleCount = lights.filter { $0.isStale }.count
        if staleCount > 0 {
            publishError("\(staleCount) light\(staleCount == 1 ? "" : "s") in \u{201C}\(room.name)\u{201D} may be offline.")
        }
        recordChange(lights)
        announceAction("\(room.name) turned \(on ? "on" : "off")", lights: lights)
        for d in lights { d.isOn = on; sendPower(d, on: on) }
    }

    func setBrightness(in room: Room, value: Double) {
        let lights = devices(in: room)
        guard !lights.isEmpty else {
            publishError("“\(room.name)” has no lights to control.")
            return
        }
        recordChange(lights)
        let clamped = min(1, max(0, value))
        for d in lights { previewBrightness(d, value: clamped) }
    }

    func setColor(in room: Room, color: Color) {
        let lights = devices(in: room)
        guard !lights.isEmpty else { return }
        rememberColor(color, name: "Custom")
        stopEffects(touching: Set(lights.map(\.id)))
        recordChange(lights)
        announceAction("\(room.name) color changed", lights: lights)
        for d in lights { d.color = color; sendColor(d, color: color) }
    }

    func setKelvin(in room: Room, kelvin: Int) {
        let lights = devices(in: room)
        guard !lights.isEmpty else { return }
        stopEffects(touching: Set(lights.map(\.id)))
        recordChange(lights)
        announceAction("\(room.name) set to \(kelvin) K white", lights: lights)
        for d in lights { d.kelvin = kelvin; sendColorTemperature(d, kelvin: kelvin) }
    }

    func setAllPower(on: Bool) {
        guard !devices.isEmpty else {
            publishError("No lights are available to control.")
            return
        }
        let verb = on ? "Turn On" : "Turn Off"
        confirmationCoordinator.request(
            .init(
                title: "\(verb) All Lights?",
                message: "This will change \(devices.count) light\(devices.count == 1 ? "" : "s"). You can undo the change afterward.",
                confirmTitle: verb
            ),
            action: { [weak self] in self?.performSetAllPower(on: on) }
        )
    }

    private func performSetAllPower(on: Bool) {
        let staleCount = devices.filter { $0.isStale }.count
        if staleCount > 0 {
            publishError("\(staleCount) light\(staleCount == 1 ? "" : "s") may be offline.")
        }
        recordChange(devices)
        announceAction("All lights turned \(on ? "on" : "off")", lights: devices)
        for d in devices { d.isOn = on; sendPower(d, on: on) }
    }

    func setAllBrightness(_ value: Double) {
        guard !devices.isEmpty else {
            publishError("No lights are available to control.")
            return
        }
        recordChange(devices)
        let clamped = min(1, max(0, value))
        for d in devices { previewBrightness(d, value: clamped) }
    }

    func setPower(deviceIDs: Set<String>, on: Bool) {
        let lights = devices.filter { deviceIDs.contains($0.id) }
        recordChange(lights)
        for d in lights { d.isOn = on; sendPower(d, on: on) }
    }

    func setBrightness(deviceIDs: Set<String>, value: Double) {
        let lights = devices.filter { deviceIDs.contains($0.id) }
        recordChange(lights)
        for d in lights { d.brightness = value; sendBrightness(d, value: value) }
    }

    // MARK: - Theme & effect catalog

    func devices(in scope: LightScope) -> [LightDevice] {
        switch scope {
        case .all:
            return devices
        case .room(let roomID):
            guard let room = rooms.first(where: { $0.id == roomID }) else { return [] }
            return devices(in: room)
        }
    }

    func scopeDisplayName(_ scope: LightScope) -> String {
        switch scope {
        case .all: return "All Lights"
        case .room(let roomID): return rooms.first(where: { $0.id == roomID })?.name ?? "Room"
        }
    }

    func applyTheme(_ theme: LightingTheme, scope: LightScope = .all) {
        let targets = devices(in: scope)
        guard !targets.isEmpty else {
            publishError(scope == .all
                         ? "Discover a light before applying a theme."
                         : "No lights in “\(scopeDisplayName(scope))” to theme.")
            return
        }
        stopEffects(touching: Set(targets.map(\.id)))
        recordChange(targets)
        for (index, device) in targets.enumerated() {
            let color = theme.colors[index % theme.colors.count].color
            device.isOn = true
            device.brightness = theme.brightness
            device.color = color
            sendPower(device, on: true)
            sendColor(device, color: color)
            if device.brand == .govee { sendBrightness(device, value: theme.brightness) }
        }
        let suffix = scope == .all ? "" : " in “\(scopeDisplayName(scope))”"
        publishError("Applied “\(theme.name)” to \(targets.count) light\(targets.count == 1 ? "" : "s")\(suffix).")
    }

    func startEffect(_ effect: LightingEffect, scope: LightScope = .all) {
        if effect.id == "music-pulse" || effect.style == .musicPulse {
            startMusicMode(
                configuration: .configuration(for: .soundcheck),
                scope: scope,
                reducedMotion: false
            )
            return
        }
        let targets = devices(in: scope)
        guard !targets.isEmpty else {
            publishError(scope == .all
                         ? "Discover a light before starting an effect."
                         : "No lights in “\(scopeDisplayName(scope))” to animate.")
            return
        }
        // Inherit snapshots from any run these lights are leaving, so stopping
        // the new run later restores the true pre-effect state rather than a
        // mid-effect frame.
        let inherited = stopEffects(touching: Set(targets.map(\.id)))
        let startingSnapshot = targets.map { inherited[$0.id] ?? snapshot($0) }
        recordChange(targets)
        let run = EffectRun(effect: effect, scope: scope, snapshot: startingSnapshot)
        effectRuns[scope] = run
        activeEffects[scope] = effect.id
        for device in targets {
            device.isOn = true
            sendPower(device, on: true)
            // Effect frames fold brightness into the RGB payload for Govee, so
            // open the device's own brightness to full range once up front.
            if device.brand == .govee {
                markSegmentsInactive(device)
                sendBrightness(device, value: 1.0)
            }
        }

        // Effects animate on a fixed timer at the effect's cadence. The timer
        // guarantees the lights keep moving; audio-reactive effects feed the
        // latest analysis into `audioSnapshot` (below) for the timer to sample.
        let runID = run.id
        let startTimer: () -> Void = { [weak self] in
            guard let self, self.effectRuns[scope]?.id == runID else { return }
            self.runEffectFrame(run)
            run.timer = Timer.scheduledTimer(withTimeInterval: effect.frameInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let activeRun = self.effectRuns[scope], activeRun.id == runID else { return }
                    self.runEffectFrame(activeRun)
                }
            }
            run.timer?.tolerance = min(0.02, effect.frameInterval * 0.1)
        }

        startTimer()
    }

    /// Starts the first-class Music Mode while preserving the `music-pulse`
    /// catalog identifier used by earlier saved state. Choreography and
    /// transport pacing live outside LightManager; this method only joins
    /// them to the existing scope, undo, and restoration lifecycle.
    func startMusicMode(
        configuration: MusicModeConfiguration,
        scope: LightScope = .all,
        reducedMotion: Bool = false
    ) {
        guard let effect = LightingCatalog.effects.first(where: { $0.id == "music-pulse" }) else { return }
        let targets = devices(in: scope)
        guard !targets.isEmpty else {
            publishError(scope == .all
                ? "Discover a light before starting Music Mode."
                : "No lights in “\(scopeDisplayName(scope))” for Music Mode.")
            return
        }

        let normalized = configuration.normalized(reducedMotion: reducedMotion)
        let inherited = stopEffects(touching: Set(targets.map(\.id)))
        let startingSnapshot = targets.map { inherited[$0.id] ?? snapshot($0) }
        recordChange(targets)
        let run = EffectRun(
            effect: effect,
            scope: scope,
            snapshot: startingSnapshot,
            restorePreviousState: normalized.restorePreviousState,
            reducedMotion: reducedMotion
        )
        effectRuns[scope] = run
        activeEffects[scope] = effect.id
        let fixtures = musicFixtureDescriptors(in: scope)
        let topology = fixtureTopology(for: scope)

        for device in targets {
            device.isOn = true
            sendPower(device, on: true)
            if device.brand == .govee, segmentProfile(for: device) == nil {
                // Ordinary Govee LAN color packets fold brightness into RGB.
                // Opening device brightness once avoids a second write per frame.
                markSegmentsInactive(device)
                sendBrightness(device, value: 1)
            }
        }

        musicModeController.start(
            scope: scope,
            configuration: normalized,
            topology: topology,
            fixtures: fixtures,
            reducedMotion: reducedMotion,
            useSyntheticPattern: isDemoMode && normalized.usesSyntheticDemoPattern,
            onFrame: { [weak self] frame in
                self?.renderMusicFrame(frame, scope: scope)
            },
            completion: { [weak self, weak run] result in
                guard let self, let run, self.effectRuns[scope] === run else { return }
                switch result {
                case .started:
                    self.logActivity(
                        .command,
                        title: "Music Mode started",
                        detail: "\(normalized.preset.displayName) · \(self.scopeDisplayName(scope))"
                    )
                case .needsScreenRecording, .unavailable:
                    self.stopEffect(scope: scope, restore: true)
                    self.publishError(self.musicModeFailureMessage(for: result))
                }
            }
        )
    }

    func stopEffect(scope: LightScope, restore: Bool = true) {
        guard let run = effectRuns.removeValue(forKey: scope) else { return }
        run.timer?.invalidate()
        if run.effect.id == "music-pulse" {
            musicModeController.stop(scope: scope)
            finishMusicStreaming(for: run.snapshot.map(\.deviceID))
        }
        activeEffects[scope] = nil
        if restore && run.restorePreviousState { restoreDeviceStates(run.snapshot) }
    }

    func stopAllEffects(restore: Bool = true) {
        for scope in Array(effectRuns.keys) { stopEffect(scope: scope, restore: restore) }
    }

    /// Stops every effect run that animates any of `deviceIDs`. Lights covered
    /// by a stopped run but outside `deviceIDs` are restored to that run's
    /// snapshot; snapshot entries for lights inside `deviceIDs` are returned so
    /// the caller can overwrite those lights (themes) or carry the entries
    /// into a replacement run (effects).
    @discardableResult
    private func stopEffects(touching deviceIDs: Set<String>) -> [String: LightRuntimeSnapshot] {
        var inherited: [String: LightRuntimeSnapshot] = [:]
        for (scope, run) in effectRuns {
            let runIDs = Set(run.snapshot.map(\.deviceID)).union(devices(in: scope).map(\.id))
            guard !runIDs.isDisjoint(with: deviceIDs) else { continue }
            run.timer?.invalidate()
            if run.effect.id == "music-pulse" {
                musicModeController.stop(scope: scope)
                finishMusicStreaming(for: runIDs)
            }
            effectRuns[scope] = nil
            activeEffects[scope] = nil
            for snap in run.snapshot where deviceIDs.contains(snap.deviceID) {
                inherited[snap.deviceID] = snap
            }
            restoreDeviceStates(run.snapshot.filter { !deviceIDs.contains($0.deviceID) })
        }
        return inherited
    }

    /// User-facing message when Music Mode can't start its audio source.
    /// macOS uses system audio (Screen Recording); iOS uses the microphone.
    private func musicModeFailureMessage(for result: AudioCaptureService.AudioStartResult) -> String {
        #if os(macOS)
        switch result {
        case .needsScreenRecording:
            return "Music Mode needs Screen Recording permission to analyze system audio. Turn on LumenDesk in System Settings › Privacy & Security › Screen & System Audio Recording (Screen Recording on older macOS), then try again."
        case .unavailable, .started:
            return "Music Mode couldn't start system-audio analysis. Make sure an audio app is playing, then try again."
        }
        #else
        return "Music Mode needs microphone access on iPhone and iPad. Enable it in Settings › Privacy & Security › Microphone."
        #endif
    }

    /// True when the device belongs to a currently animating effect run.
    private func isEffectAnimating(_ deviceID: String) -> Bool {
        effectRuns.contains { scope, run in
            run.snapshot.contains { $0.deviceID == deviceID } ||
            devices(in: scope).contains { $0.id == deviceID }
        }
    }

    private func runEffectFrame(_ run: EffectRun) {
        guard effectRuns[run.scope] === run, !run.effect.colors.isEmpty else { return }
        run.phase += run.effect.speed
        let effect = run.effect
        let effectPhase = run.phase
        let palette = effect.colors
        let targets = devices(in: run.scope)
        run.modelUpdateElapsed += effect.frameInterval
        let shouldUpdateModel = run.modelUpdateElapsed >= 0.25
        if shouldUpdateModel { run.modelUpdateElapsed = 0 }

        for (index, device) in targets.enumerated() {
            var color = palette[(index + Int(effectPhase)) % palette.count].color
            var brightness = 0.72

            switch effect.style {
            case .colorFlow:
                let hue = (effectPhase * 0.08 + Double(index) / Double(max(1, targets.count))).truncatingRemainder(dividingBy: 1)
                color = Color(hue: hue, saturation: 0.86, brightness: 1)
                brightness = 0.78
            case .oceanWave:
                let wave = (sin(effectPhase + Double(index) * 0.85) + 1) / 2
                color = palette[Int(wave * Double(palette.count - 1))].color
                brightness = 0.38 + wave * 0.42
            case .breathe:
                let breath = (sin(effectPhase) + 1) / 2
                color = palette[index % palette.count].color
                brightness = 0.18 + breath * 0.62
            case .candlelight:
                color = palette.randomElement()?.color ?? color
                brightness = Double.random(in: 0.38...0.76)
            case .musicPulse:
                // Routed through `startMusicMode`; this restrained fallback is
                // deliberately flash-free if a future caller bypasses it.
                let wave = (sin(effectPhase + Double(index) * 0.75) + 1) / 2
                color = palette[index % palette.count].color
                brightness = 0.18 + wave * 0.36
            case .prismShuffle:
                color = palette.randomElement()?.color ?? color
                brightness = Double.random(in: 0.62...0.92)
            case .lightning:
                let strike = Double.random(in: 0...1) > 0.91
                color = strike ? palette.last!.color : palette[index % max(1, palette.count - 1)].color
                brightness = strike ? 1 : Double.random(in: 0.18...0.42)
            case .sunrise:
                let progress = min(0.999, effectPhase / 12)
                color = palette[min(palette.count - 1, Int(progress * Double(palette.count)))].color
                brightness = 0.08 + progress * 0.82
            case .sunset:
                let progress = min(0.999, effectPhase / 12)
                color = palette[min(palette.count - 1, Int(progress * Double(palette.count)))].color
                brightness = 0.82 - progress * 0.58
            }

            let clampedBrightness = max(0.05, min(1, brightness))
            if shouldUpdateModel {
                if device.color.rgbDistance(to: color) > 0.005 { device.color = color }
                if abs(device.brightness - clampedBrightness) > 0.005 { device.brightness = clampedBrightness }
            }
            sendEffectFrame(device, color: color, brightness: clampedBrightness,
                            duration: effect.frameInterval)
        }
    }

    /// Effect frames are transient and never receive command acknowledgements.
    /// Sending them through the normal confirmation pipeline used to allocate
    /// three Tasks and publish several whole-app changes per light, per frame.
    private func sendEffectFrame(_ device: LightDevice, color: Color, brightness: Double,
                                 duration: TimeInterval) {
        guard demoWorkspaceController.allowsLiveNetworking else { return }
        switch device.brand {
        case .lifx:
            markLIFXMatrixInactive(device)
            let hsb = color.hsbComponents
            lifx?.setColor(
                macHex: device.backendID,
                color: LIFXHSBK(
                    hue: UInt16(hsb.h * 65535),
                    saturation: UInt16(hsb.s * 65535),
                    brightness: UInt16(brightness * 65535),
                    kelvin: UInt16(device.kelvin)
                ),
                durationMS: UInt32(max(0, min(500, Int(duration * 1_000))))
            )
        case .govee:
            let rgb = color.rgbComponents
            let scale = max(0, min(1, brightness))
            govee?.setColor(deviceID: device.backendID,
                            r: Int(rgb.r * 255 * scale),
                            g: Int(rgb.g * 255 * scale),
                            b: Int(rgb.b * 255 * scale),
                            kelvin: 0)
        }
    }

    private func restoreDeviceStates(_ states: [LightRuntimeSnapshot]) {
        for state in states {
            guard let device = device(withID: state.deviceID) else { continue }
            device.isOn = state.isOn
            device.brightness = state.brightness
            device.color = state.color
            device.kelvin = state.kelvin
            if let matrix = state.matrix, device.isLIFXLuna {
                applyLIFXMatrix(device, state: matrix, recordUndo: false,
                                turnOn: false, announce: false)
            } else if let segments = state.segments, device.brand == .govee {
                applySegments(device, state: segments, recordUndo: false, turnOn: false, announce: false)
                sendBrightness(device, value: state.brightness)
            } else {
                sendColor(device, color: state.color)
                if device.brand == .govee { sendBrightness(device, value: state.brightness) }
            }
            sendPower(device, on: state.isOn)
        }
    }

    // MARK: - Vendor send helpers

    private func sendPower(_ device: LightDevice, on: Bool) {
        expectPower(device, on: on)
        enqueueCommand(for: device, coalescingKey: "power", summary: on ? "Turning on" : "Turning off") { [weak self, weak device] in
            guard let self, let device else { return }
            switch device.brand {
            case .lifx: self.lifx?.setPower(macHex: device.backendID, on: on)
            case .govee: self.govee?.setPower(deviceID: device.backendID, on: on)
            }
        }
    }

    private func sendBrightness(_ device: LightDevice, value: Double) {
        expectBrightness(device, value: value)
        let matrixUpdate: LIFXMatrixState?
        if device.isLIFXLuna,
           let current = activeLIFXMatrixState(for: device.id) {
            let updated = current.settingBrightness(value)
            lifxMatrixStates[device.id] = updated
            matrixUpdate = updated
        } else {
            matrixUpdate = nil
        }
        enqueueCommand(for: device, coalescingKey: "brightness", summary: "Brightness \(Int(value * 100)) percent") { [weak self, weak device] in
            guard let self, let device else { return }
            switch device.brand {
            case .lifx:
                if let matrixUpdate {
                    self.lifx?.setMatrixColors(
                        macHex: device.backendID,
                        colors: matrixUpdate.colors.map(\.hsbk),
                        width: matrixUpdate.width
                    )
                } else {
                    let hsb = device.color.hsbComponents
                    let lifxColor = LIFXHSBK(hue: UInt16(hsb.h * 65535), saturation: UInt16(hsb.s * 65535), brightness: UInt16(max(0, min(1, value)) * 65535), kelvin: UInt16(device.kelvin))
                    self.lifx?.setColor(macHex: device.backendID, color: lifxColor)
                }
            case .govee:
                self.govee?.setBrightness(deviceID: device.backendID, percent: Int(value * 100))
            }
        }
    }

    private func sendColor(_ device: LightDevice, color: Color, debounce: TimeInterval = 0.08) {
        if device.brand == .lifx { markLIFXMatrixInactive(device) }
        expectColor(device, color: color)
        enqueueCommand(for: device, coalescingKey: "color", summary: "Changing color", debounce: debounce) { [weak self, weak device] in
            guard let self, let device else { return }
            switch device.brand {
            case .lifx:
                let hsb = color.hsbComponents
                let lifxColor = LIFXHSBK(hue: UInt16(hsb.h * 65535), saturation: UInt16(hsb.s * 65535), brightness: UInt16(device.brightness * 65535), kelvin: UInt16(device.kelvin))
                self.lifx?.setColor(macHex: device.backendID, color: lifxColor)
            case .govee:
                self.markSegmentsInactive(device)
                let rgb = color.rgbComponents
                self.govee?.setColor(deviceID: device.backendID, r: Int(rgb.r * 255), g: Int(rgb.g * 255), b: Int(rgb.b * 255), kelvin: 0)
            }
        }
    }

    private func sendColorTemperature(_ device: LightDevice, kelvin: Int) {
        if device.brand == .lifx { markLIFXMatrixInactive(device) }
        expectKelvin(device, kelvin: kelvin)
        enqueueCommand(for: device, coalescingKey: "kelvin", summary: "Color temperature \(kelvin) kelvin") { [weak self, weak device] in
            guard let self, let device else { return }
            switch device.brand {
            case .lifx:
                let hsb = device.color.hsbComponents
                self.lifx?.setColor(macHex: device.backendID, color: LIFXHSBK(hue: UInt16(hsb.h * 65535), saturation: 0, brightness: UInt16(device.brightness * 65535), kelvin: UInt16(kelvin)))
            case .govee:
                self.markSegmentsInactive(device)
                self.govee?.setColor(deviceID: device.backendID, r: 255, g: 255, b: 255, kelvin: kelvin)
            }
        }
    }

    // MARK: - Undo / redo

    private func snapshot(_ device: LightDevice) -> LightRuntimeSnapshot {
        LightRuntimeSnapshot(deviceID: device.id, isOn: device.isOn,
                    brightness: device.brightness, color: device.color, kelvin: device.kelvin,
                    segments: activeSegmentState(for: device.id),
                    matrix: activeLIFXMatrixState(for: device.id))
    }

    private func recordChange(_ devices: [LightDevice]) {
        guard !devices.isEmpty else { return }
        let now = Date()
        if let last = undoStack.last,
           last.count == devices.count,
           Set(last.map { $0.deviceID }) == Set(devices.map { $0.id }),
           devices.allSatisfy({ now.timeIntervalSince(lastChangeTime[$0.id] ?? .distantPast) < coalesceWindow }) {
            for d in devices { lastChangeTime[d.id] = now }
            return
        }
        undoStack.append(devices.map { snapshot($0) })
        if undoStack.count > undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        canUndo = true
        canRedo = false
        for d in devices { lastChangeTime[d.id] = now }
    }

    func undo() {
        guard let entry = undoStack.popLast() else { return }
        let current = entry.compactMap { snap -> LightRuntimeSnapshot? in
            guard let d = device(withID: snap.deviceID) else { return nil }
            return snapshot(d)
        }
        redoStack.append(current)
        apply(entry)
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func redo() {
        guard let entry = redoStack.popLast() else { return }
        let current = entry.compactMap { snap -> LightRuntimeSnapshot? in
            guard let d = device(withID: snap.deviceID) else { return nil }
            return snapshot(d)
        }
        undoStack.append(current)
        apply(entry)
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func apply(_ entry: [LightRuntimeSnapshot]) {
        for snap in entry {
            guard let d = device(withID: snap.deviceID) else { continue }
            d.isOn = snap.isOn
            d.brightness = snap.brightness
            d.color = snap.color
            d.kelvin = snap.kelvin
            if let matrix = snap.matrix, d.isLIFXLuna {
                applyLIFXMatrix(d, state: matrix, recordUndo: false,
                                turnOn: false, announce: false)
            } else if let segments = snap.segments, d.brand == .govee {
                applySegments(d, state: segments, recordUndo: false, turnOn: false, announce: false)
                sendBrightness(d, value: snap.brightness)
            } else {
                sendColor(d, color: snap.color)
                // Govee needs an explicit brightness call; LIFX brightness is embedded in setColor.
                if d.brand == .govee { sendBrightness(d, value: snap.brightness) }
            }
            sendPower(d, on: snap.isOn)
        }
    }

    // MARK: - Internal helpers

    fileprivate func upsert(_ device: LightDevice) {
        scanResponseCount += 1
        // Apply any persisted custom name.
        device.customName = customNames[device.id]

        if let idx = devices.firstIndex(where: { $0.id == device.id }) {
            let existing = devices[idx]
            devicesByID[existing.id] = existing
            let oldAddress = existing.address
            existing.name = device.name
            existing.address = device.address
            existing.sku = device.sku ?? existing.sku
            existing.productID = device.productID ?? existing.productID
            if oldAddress != device.address { appendDiscoveryChange(existing, kind: .changed, detail: "Address changed from \(oldAddress) to \(device.address)") }
            existing.customName = customNames[existing.id]
            markSeen(existing)
        } else {
            devices.append(device)
            devicesByID[device.id] = device
            appendDiscoveryChange(device, kind: .new, detail: "Ready to assign to a room")
            sortDevices()
            // UX 9: briefly flag newly discovered devices so the UI can highlight them.
            newlyDiscoveredIDs.insert(device.id)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.newlyDiscoveredIDs.remove(device.id)
            }
        }
    }

    private func sortDevices() {
        devices.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    fileprivate func device(withID id: String) -> LightDevice? {
        devicesByID[id]
    }
}

// MARK: - LIFX delegate

extension LightManager: LIFXClientDelegate {
    nonisolated func lifxDiscovered(macHex: String, address: String) {
        Task { @MainActor in
            guard self.demoWorkspaceController.acceptsLiveNetworkCallbacks else { return }
            let id = "lifx:\(macHex)"
            if let existing = self.device(withID: id) {
                self.scanResponseCount += 1
                let oldAddress = existing.address
                existing.address = address
                if oldAddress != address { self.appendDiscoveryChange(existing, kind: .changed, detail: "Address changed from \(oldAddress) to \(address)") }
                self.markSeen(existing)
            } else {
                let device = LightDevice(id: id, brand: .lifx, backendID: macHex,
                                         name: "LIFX \(macHex.suffix(6))", address: address)
                self.upsert(device)
            }
        }
    }

    nonisolated func lifxDidIdentify(macHex: String, vendorID: UInt32, productID: UInt32) {
        Task { @MainActor in
            guard self.demoWorkspaceController.acceptsLiveNetworkCallbacks,
                  vendorID == 1,
                  let device = self.device(withID: "lifx:\(macHex)") else { return }
            device.productID = productID
            if let sku = LIFXProductCatalog.sku(for: productID) {
                device.sku = sku
            }
        }
    }

    nonisolated func lifxDidUpdate(macHex: String, label: String, color: LIFXHSBK, isOn: Bool) {
        Task { @MainActor in
            guard self.demoWorkspaceController.acceptsLiveNetworkCallbacks else { return }
            let id = "lifx:\(macHex)"
            guard let device = self.device(withID: id) else { return }
            if self.isScanning { self.scanResponseCount += 1 }
            if !label.isEmpty && label != device.name {
                device.name = label
                self.sortDevices()
            }
            let h = Double(color.hue) / 65535.0
            let s = Double(color.saturation) / 65535.0
            let reportedColor = Color(hue: h, saturation: s, brightness: 1.0)
            let rgb = reportedColor.rgbComponents
            let brightness = Double(color.brightness) / 65535.0
            let matches = self.reportedStateMatchesExpectation(
                deviceID: id,
                isOn: isOn,
                brightness: brightness,
                red: rgb.r,
                green: rgb.g,
                blue: rgb.b,
                kelvin: Int(color.kelvin)
            )
            if !self.isEffectAnimating(id) && (!self.commandPendingIDs.contains(id) || matches) {
                if device.isOn != isOn { device.isOn = isOn }
                if abs(device.brightness - brightness) > 0.001 { device.brightness = brightness }
                if device.kelvin != Int(color.kelvin) { device.kelvin = Int(color.kelvin) }
                if device.color.rgbDistance(to: reportedColor) > 0.005 { device.color = reportedColor }
            }
            self.markSeen(device, confirmsPendingCommand: matches)
        }
    }

    nonisolated func lifxDidUpdateMatrix(macHex: String, productID: UInt32,
                                         width: Int, height: Int,
                                         colors: [LIFXHSBK]) {
        Task { @MainActor in
            guard self.demoWorkspaceController.acceptsLiveNetworkCallbacks,
                  let device = self.device(withID: "lifx:\(macHex)") else { return }
            if productID != 0 {
                device.productID = productID
                device.sku = LIFXProductCatalog.sku(for: productID) ?? device.sku
            }
            guard device.isLIFXLuna else { return }
            self.lifxMatrixStates[device.id] = LIFXMatrixState(
                productID: device.productID ?? productID,
                width: width,
                height: height,
                colors: colors.map(LIFXMatrixColor.init),
                isActive: true
            )
            self.markSeen(device)
        }
    }

    nonisolated func lifxCommandFailed(_ error: Error) {
        Task { @MainActor in
            guard self.demoWorkspaceController.acceptsLiveNetworkCallbacks else { return }
            let affected = Set(self.devices.lazy
                .filter { $0.brand == .lifx && self.commandPendingIDs.contains($0.id) }
                .map(\.id))
            self.commandCoordinator.fail(deviceIDs: affected, summary: "LIFX rejected the command")
            self.publishError("LIFX command failed: \(error)")
        }
    }
}

// MARK: - Govee delegate

extension LightManager: GoveeClientDelegate {
    nonisolated func goveeDiscovered(deviceID: String, address: String, sku: String?) {
        Task { @MainActor in
            guard self.demoWorkspaceController.acceptsLiveNetworkCallbacks else { return }
            let id = "govee:\(deviceID)"
            if let existing = self.device(withID: id) {
                self.scanResponseCount += 1
                let oldAddress = existing.address
                existing.address = address
                if let sku, existing.sku != sku { existing.sku = sku }
                if oldAddress != address { self.appendDiscoveryChange(existing, kind: .changed, detail: "Address changed from \(oldAddress) to \(address)") }
                self.markSeen(existing)
                // Fresh discovery is the earliest moment after an app launch
                // or a device reboot to restore a held layout.
                self.reassertStreamHoldIfNeeded(existing)
            } else {
                let suffix = deviceID.split(separator: ":").suffix(2).joined(separator: "")
                let display = sku.map { "\($0) \(suffix)" } ?? "Govee \(suffix)"
                let device = LightDevice(id: id, brand: .govee, backendID: deviceID,
                                         name: display, address: address, sku: sku)
                self.upsert(device)
                // First sighting after an app launch: restore any held layout.
                self.reassertStreamHoldIfNeeded(device)
            }
        }
    }

    nonisolated func goveeDidUpdate(deviceID: String, isOn: Bool, brightness: Int,
                                    r: Int, g: Int, b: Int, kelvin: Int) {
        Task { @MainActor in
            guard self.demoWorkspaceController.acceptsLiveNetworkCallbacks else { return }
            let id = "govee:\(deviceID)"
            guard let device = self.device(withID: id) else { return }
            if self.isScanning { self.scanResponseCount += 1 }
            let normalizedBrightness = Double(brightness) / 100.0
            let red = Double(r) / 255.0
            let green = Double(g) / 255.0
            let blue = Double(b) / 255.0
            let matches = self.reportedStateMatchesExpectation(
                deviceID: id,
                isOn: isOn,
                brightness: normalizedBrightness,
                red: red,
                green: green,
                blue: blue,
                kelvin: kelvin
            )
            if !self.isEffectAnimating(id) && (!self.commandPendingIDs.contains(id) || matches) {
                if device.isOn != isOn { device.isOn = isOn }
                if abs(device.brightness - normalizedBrightness) > 0.001 {
                    device.brightness = normalizedBrightness
                }
                if kelvin > 0, device.kelvin != kelvin { device.kelvin = kelvin }
                let reportedColor = Color(red: red, green: green, blue: blue)
                if device.color.rgbDistance(to: reportedColor) > 0.005 { device.color = reportedColor }
            }
            self.markSeen(device, confirmsPendingCommand: matches)
        }
    }

    nonisolated func goveeCommandFailed(_ error: Error) {
        Task { @MainActor in
            guard self.demoWorkspaceController.acceptsLiveNetworkCallbacks else { return }
            let affected = Set(self.devices.lazy
                .filter { $0.brand == .govee && self.commandPendingIDs.contains($0.id) }
                .map(\.id))
            self.commandCoordinator.fail(deviceIDs: affected, summary: "Govee rejected the command")
            self.publishError("Govee command failed: \(error)")
        }
    }
}

// MARK: - LIFX Luna matrix color studio

extension LightManager {
    func lifxMatrixState(for device: LightDevice) -> LIFXMatrixState? {
        guard device.isLIFXLuna else { return nil }
        return lifxMatrixStates[device.id]
    }

    func activeLIFXMatrixState(for deviceID: String) -> LIFXMatrixState? {
        guard let state = lifxMatrixStates[deviceID], state.isActive else { return nil }
        return state
    }

    func refreshLIFXMatrix(_ device: LightDevice) {
        guard device.isLIFXLuna else { return }
        if isDemoMode {
            if lifxMatrixStates[device.id] == nil {
                lifxMatrixStates[device.id] = .demoLuna(brightness: device.brightness)
            }
            return
        }
        lifx?.refreshMatrix(macHex: device.backendID)
    }

    func applyLIFXMatrix(_ device: LightDevice, state: LIFXMatrixState,
                         recordUndo: Bool = true, turnOn: Bool = true,
                         announce: Bool = true) {
        guard device.isLIFXLuna else { return }
        if recordUndo {
            if device.isStale {
                publishError("\u{201C}\(device.label)\u{201D} may be offline — command sent anyway.")
            }
            recordChange([device])
        }

        var next = state
        next.productID = device.productID ?? state.productID
        next.isActive = true
        lifxMatrixStates[device.id] = next
        if turnOn, !device.isOn {
            device.isOn = true
            sendPower(device, on: true)
        }

        commandCoordinator.recordUnconfirmedSend(
            deviceID: device.id,
            summary: "Applying \(next.zoneCount)-zone Luna layout"
        )
        if demoWorkspaceController.allowsLiveNetworking {
            lifx?.setMatrixColors(
                macHex: device.backendID,
                colors: next.colors.map(\.hsbk),
                width: next.width
            )
        }
        if announce {
            logActivity(.command, title: "Luna layout applied",
                        detail: "\(device.label): \(next.zoneCount) color zones")
            lastActionSummary = "Painted \(next.zoneCount) zones on \(device.label)"
        }
    }

    fileprivate func markLIFXMatrixInactive(_ device: LightDevice) {
        guard lifxMatrixStates[device.id]?.isActive == true else { return }
        lifxMatrixStates[device.id]?.isActive = false
    }
}

// MARK: - Govee Segment Studio (per-segment control for COB strips, string lights, neon ropes)

extension LightManager {
    /// Capability detected from the discovery SKU; nil for non-Govee devices
    /// and Govee models the catalog doesn't recognize.
    func segmentProfile(for device: LightDevice) -> GoveeSegmentProfile? {
        guard device.brand == .govee else { return nil }
        return GoveeSegmentProfile.detect(sku: device.sku)
    }

    /// Profile the Segment Studio runs with. Any Govee light may open the
    /// studio — unrecognized SKUs get the generic profile (the studio labels
    /// them as unrecognized; devices without RGBIC hardware simply ignore
    /// segment packets).
    func segmentStudioProfile(for device: LightDevice) -> GoveeSegmentProfile? {
        guard device.brand == .govee else { return nil }
        return segmentProfile(for: device) ?? .generic
    }

    /// The device's saved layout, or a fresh one seeded from its current color.
    func segmentState(for device: LightDevice) -> GoveeSegmentState {
        if let saved = goveeSegmentStates[device.id] { return saved }
        let profile = segmentStudioProfile(for: device) ?? .generic
        return .seed(count: profile.defaultSegmentCount,
                     color: device.color,
                     gradient: false)
    }

    /// The saved layout only when it is what the light is currently showing.
    func activeSegmentState(for deviceID: String) -> GoveeSegmentState? {
        guard let state = goveeSegmentStates[deviceID], state.isActive else { return nil }
        return state
    }

    /// Streams the draft layout in real time over razer mode while the studio
    /// is editing. The overlay is volatile, so ending the preview without
    /// applying is a true cancel: the light falls back to its last static
    /// state (or, on stream-hold families, snaps back to the applied layout).
    func previewSegments(_ device: LightDevice, state: GoveeSegmentState) {
        guard device.brand == .govee, demoWorkspaceController.allowsLiveNetworking else { return }
        if !razerActiveIDs.contains(device.id) {
            razerActiveIDs.insert(device.id)
            govee?.setRazerMode(deviceID: device.backendID, on: true)
        }
        sendRazerLayout(device, state: state)
    }

    /// Ends a studio editing session's live stream. Static-write devices
    /// drop the overlay so the light falls back to its stored state;
    /// stream-hold devices keep the overlay up and snap it back to the
    /// applied layout, because the overlay IS their persistence.
    func endSegmentPreview(_ device: LightDevice) {
        guard demoWorkspaceController.allowsLiveNetworking else { return }
        guard razerActiveIDs.contains(device.id) else { return }
        if segmentStudioProfile(for: device)?.appliesViaStream == true,
           let held = activeSegmentState(for: device.id) {
            sendRazerLayout(device, state: held)
        } else {
            razerActiveIDs.remove(device.id)
            govee?.setRazerMode(deviceID: device.backendID, on: false)
        }
    }

    /// One razer frame carrying a whole layout. Frames have no brightness
    /// channel, so each segment's own brightness is folded into its RGB.
    private func sendRazerLayout(_ device: LightDevice, state: GoveeSegmentState) {
        guard demoWorkspaceController.allowsLiveNetworking else { return }
        let colors = state.colors.map { segment -> (r: Int, g: Int, b: Int) in
            let rgb = segment.rgb255
            let scale = segment.brightness
            return (r: Int((Double(rgb.r) * scale).rounded()),
                    g: Int((Double(rgb.g) * scale).rounded()),
                    b: Int((Double(rgb.b) * scale).rounded()))
        }
        govee?.sendRazerFrame(deviceID: device.backendID, colors: colors, blend: state.gradient)
    }

    /// Puts a stream-hold device's applied layout on the light and leaves
    /// the overlay up. Razer-on is sent unconditionally so this also repairs
    /// an overlay the firmware dropped (power cycle, timeout, reboot).
    private func assertStreamHold(_ device: LightDevice, state: GoveeSegmentState) {
        guard demoWorkspaceController.allowsLiveNetworking else { return }
        razerActiveIDs.insert(device.id)
        govee?.setRazerMode(deviceID: device.backendID, on: true)
        sendRazerLayout(device, state: state)
    }

    /// Stream-hold layouts live only in the razer overlay, which a power
    /// cycle or firmware timeout clears. Called from the 30-second refresh
    /// tick, discovery, stale-recovery, and power-on so held layouts come
    /// back on their own while LumenDesk is running. Skipped while the light
    /// is off — pushing a frame must never light up a light the user
    /// switched off.
    func reassertStreamHoldIfNeeded(_ device: LightDevice) {
        guard device.brand == .govee, device.isOn, demoWorkspaceController.allowsLiveNetworking,
              segmentStudioProfile(for: device)?.appliesViaStream == true,
              let held = activeSegmentState(for: device.id) else { return }
        assertStreamHold(device, state: held)
    }

    /// Saves the studio's draft without commanding the light, so a half
    /// finished paint job survives closing the sheet. The layout only keeps
    /// its "showing on the light" status while it still matches what was
    /// applied — an edited-but-unapplied draft must not masquerade as live
    /// state to scenes and undo.
    func storeSegmentState(_ state: GoveeSegmentState, for device: LightDevice) {
        let previous = goveeSegmentStates[device.id]
        var stored = state
        stored.isActive = previous?.isActive == true
            && previous?.colors == state.colors
            && previous?.gradient == state.gradient
        goveeSegmentStates[device.id] = stored
        persistApplicationState()
    }

    /// Applies a layout durably. Strip-family firmware stores the layout via
    /// the same Bluetooth-format commands the Govee Home app writes, relayed
    /// over the LAN `ptReal` command. String/curtain-family firmware has no
    /// static segment write at all (Govee's own API exposes none for them),
    /// so their layouts are held on the light through the razer streaming
    /// overlay and re-asserted automatically while LumenDesk runs.
    func applySegments(_ device: LightDevice, state: GoveeSegmentState,
                       recordUndo: Bool = true, turnOn: Bool = true, announce: Bool = true) {
        guard device.brand == .govee else { return }
        if recordUndo {
            if device.isStale {
                publishError("\u{201C}\(device.label)\u{201D} may be offline — command sent anyway.")
            }
            recordChange([device])
        }
        var next = state
        next.isActive = true
        goveeSegmentStates[device.id] = next
        persistApplicationState()
        device.color = next.blendedColor
        if turnOn, !device.isOn {
            device.isOn = true
            sendPower(device, on: true)
        }
        noteSegmentCommand(device, summary: "Applying \(next.segmentCount)-segment layout")
        if demoWorkspaceController.allowsLiveNetworking {
            if segmentStudioProfile(for: device)?.appliesViaStream == true {
                // The overlay is the persistence: push the layout as a frame
                // and deliberately leave razer mode up.
                assertStreamHold(device, state: next)
            } else {
                // The razer overlay must come down BEFORE the static write.
                // Firmware restores its pre-razer state when the overlay is
                // disabled, so a layout written while streaming is active
                // gets wiped the moment the studio closes. The razer-off is
                // bundled into the apply's own packet batch (see
                // GoveeClient.applySegments) so no re-enable can slip in
                // between; here we only drop the bookkeeping so the studio's
                // next edit knows to open a fresh streaming session.
                razerActiveIDs.remove(device.id)
                sendSegmentPackets(device, state: next)
            }
        }
        if announce {
            logActivity(.command, title: "Segment layout applied",
                        detail: "\(device.label): \(next.segmentCount) segments\(next.gradient ? ", blended" : "")")
            lastActionSummary = "Painted \(next.segmentCount) segments on \(device.label)"
        }
    }

    func addSegmentPreset(name: String, stops: [GoveeSegmentColor], fill: GoveeSegmentPreset.Fill = .smooth) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !stops.isEmpty else { return }
        goveeSegmentPresets.append(GoveeSegmentPreset(name: trimmed, stops: stops, fill: fill))
        persistApplicationState()
        lastActionSummary = "Saved segment preset \u{201C}\(trimmed)\u{201D}"
    }

    func deleteSegmentPreset(_ presetID: UUID) {
        goveeSegmentPresets.removeAll { $0.id == presetID }
        persistApplicationState()
    }

    /// Translates a layout into the packet batch the firmware expects: one
    /// gradient toggle, one color packet per distinct color, and per-segment
    /// brightness packets only when the layout actually dims something.
    private func sendSegmentPackets(_ device: LightDevice, state: GoveeSegmentState) {
        var packets: [[UInt8]] = []
        if segmentStudioProfile(for: device)?.supportsGradient == true {
            packets.append(GoveeProtocol.gradientPacket(on: state.gradient))
        }
        for group in state.colorGroups {
            let rgb = group.color.rgb255
            packets.append(GoveeProtocol.segmentColorPacket(r: rgb.r, g: rgb.g, b: rgb.b, segments: group.segments))
        }
        let brightnessGroups = state.brightnessGroups
        if brightnessGroups.contains(where: { $0.percent < 100 }) {
            for group in brightnessGroups {
                packets.append(GoveeProtocol.segmentBrightnessPacket(percent: group.percent, segments: group.segments))
            }
        }
        govee?.applySegments(deviceID: device.backendID, packets: packets)
    }

    /// Segment layouts aren't echoed back by `devStatus`, so they can't ride
    /// the expectation-matching confirmation pipeline — that would end every
    /// apply with a false "did not confirm" error. Show a lightweight
    /// sending → applied badge instead.
    private func noteSegmentCommand(_ device: LightDevice, summary: String) {
        commandCoordinator.recordUnconfirmedSend(deviceID: device.id, summary: summary)
    }

    /// Called whenever a solid color or white command goes to a Govee device,
    /// so scenes and undo stop treating the stored layout as what is on
    /// display. The layout itself is kept for one-tap re-apply.
    fileprivate func markSegmentsInactive(_ device: LightDevice) {
        // A live razer overlay — studio preview or stream-hold — shadows
        // every static command; bring it down ahead of the solid color,
        // white, or effect frame that triggered this call.
        if razerActiveIDs.contains(device.id) {
            razerActiveIDs.remove(device.id)
            govee?.setRazerMode(deviceID: device.backendID, on: false)
        }
        guard goveeSegmentStates[device.id]?.isActive == true else { return }
        goveeSegmentStates[device.id]?.isActive = false
        persistApplicationState()
    }
}

// MARK: - Rooms

extension LightManager {
    var unassignedDevices: [LightDevice] {
        let assigned = Set(rooms.flatMap { $0.lightIDs })
        return devices
            .filter { !assigned.contains($0.id) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    func devices(in room: Room) -> [LightDevice] {
        room.lightIDs.compactMap { devicesByID[$0] }
    }

    func createRoom(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        rooms.append(Room(name: trimmed))
        persistApplicationState()
    }

    func renameRoom(_ roomID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        rooms[idx].name = trimmed
        persistApplicationState()
    }

    func deleteRoom(_ roomID: UUID) {
        guard let idx = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        let room = rooms[idx]
        confirmationCoordinator.request(
            .init(
                title: "Delete “\(room.name)”?",
                message: "The room will be removed, but its lights will remain available and the deletion can be undone.",
                confirmTitle: "Delete Room",
                role: .destructive
            ),
            action: { [weak self] in self?.performDeleteRoom(roomID) }
        )
    }

    private func performDeleteRoom(_ roomID: UUID) {
        guard let idx = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        stopEffect(scope: .room(roomID))
        let deleted = rooms[idx]
        lastDeletedRoom = (room: deleted, index: idx)
        rooms.remove(at: idx)
        persistApplicationState()
        publishError("\u{201C}\(deleted.name)\u{201D} deleted.") {
            self.undoDeleteRoom()
        }
    }

    func undoDeleteRoom() {
        guard let (room, index) = lastDeletedRoom else { return }
        let insertAt = min(index, rooms.count)
        rooms.insert(room, at: insertAt)
        lastDeletedRoom = nil
        persistApplicationState()
        commandError = nil
        commandErrorUndo = nil
    }

    func moveRooms(from offsets: IndexSet, to destination: Int) {
        rooms.move(fromOffsets: offsets, toOffset: destination)
        persistApplicationState()
    }

    func moveRoom(_ roomID: UUID, by offset: Int) {
        guard let idx = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        let target = idx + offset
        guard rooms.indices.contains(target) else { return }
        rooms.swapAt(idx, target)
        persistApplicationState()
    }

    func assign(lightID: String, toRoom roomID: UUID?) {
        for i in rooms.indices { rooms[i].lightIDs.removeAll { $0 == lightID } }
        if let roomID, let idx = rooms.firstIndex(where: { $0.id == roomID }) {
            rooms[idx].lightIDs.append(lightID)
        }
        persistApplicationState()
    }

    func assign(lightIDs: Set<String>, toRoom roomID: UUID?) {
        for i in rooms.indices { rooms[i].lightIDs.removeAll { lightIDs.contains($0) } }
        if let roomID, let idx = rooms.firstIndex(where: { $0.id == roomID }) {
            let ordered = devices.map { $0.id }.filter { lightIDs.contains($0) }
            rooms[idx].lightIDs.append(contentsOf: ordered)
        }
        persistApplicationState()
    }

    func moveLight(_ lightID: String, in roomID: UUID, by offset: Int) {
        guard let r = rooms.firstIndex(where: { $0.id == roomID }),
              let l = rooms[r].lightIDs.firstIndex(of: lightID) else { return }
        let target = l + offset
        guard rooms[r].lightIDs.indices.contains(target) else { return }
        rooms[r].lightIDs.swapAt(l, target)
        persistApplicationState()
    }

    func room(forLightID lightID: String) -> Room? {
        rooms.first { $0.lightIDs.contains(lightID) }
    }

    typealias ExportedConfiguration = PersistenceStore.ConfigurationArchive

    func exportRoomsData() -> Data? { exportConfigurationData() }

    func exportConfigurationData() -> Data? {
        try? persistenceStore.exportConfiguration(from: persistedApplicationState())
    }

    @discardableResult
    func importRoomsData(_ data: Data) -> Bool {
        do {
            let importedState = try persistenceStore.importingConfiguration(
                from: data,
                into: persistedApplicationState()
            )
            if demoWorkspaceController.allowsLivePersistence {
                // Persist the fully validated candidate atomically before
                // replacing any live in-memory configuration.
                try persistenceStore.save(importedState)
            }
            applyPersistedApplicationState(importedState)
            for device in devices {
                device.customName = customNames[device.id]
            }
            sortDevices()
            reportImportMatchStatus(roomCount: rooms.count)
            return true
        } catch {
            statusMessage = "Import failed — that file isn’t a valid LumenDesk configuration."
            return false
        }
    }

    func requestConfigurationImport(_ data: Data, fileName: String) {
        let roomWord = rooms.count == 1 ? "room" : "rooms"
        let sceneWord = scenes.count == 1 ? "scene" : "scenes"
        confirmationCoordinator.request(
            .init(
                title: "Replace Current Configuration?",
                message: "Importing “\(fileName)” will overwrite \(rooms.count) \(roomWord) and \(scenes.count) \(sceneWord), along with favorites, custom names, and saved segment layouts. This cannot be undone.",
                confirmTitle: "Import Configuration",
                role: .destructive,
                requirement: .always
            ),
            action: { [weak self] in _ = self?.importRoomsData(data) }
        )
    }

    private func reportImportMatchStatus(roomCount: Int) {
        let importedIDs = Set(rooms.flatMap { $0.lightIDs })
        let knownIDs = Set(devices.map { $0.id })
        let missing = importedIDs.subtracting(knownIDs).count
        if missing > 0 {
            statusMessage = "Imported \(roomCount) room\(roomCount == 1 ? "" : "s"); \(missing) saved light\(missing == 1 ? "" : "s") not currently discovered."
        } else {
            statusMessage = "Imported \(roomCount) room\(roomCount == 1 ? "" : "s") and matched all saved lights."
        }
    }

}

// MARK: - Favorites

extension LightManager {
    func isFavorite(_ deviceID: String) -> Bool { favoriteIDs.contains(deviceID) }

    func toggleFavorite(_ deviceID: String) {
        if favoriteIDs.contains(deviceID) {
            favoriteIDs.remove(deviceID)
        } else {
            favoriteIDs.insert(deviceID)
        }
        persistApplicationState()
    }

    var favoriteDevices: [LightDevice] {
        devices
            .filter { favoriteIDs.contains($0.id) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    func isFavoriteRoom(_ roomID: UUID) -> Bool { favoriteRoomIDs.contains(roomID) }

    func toggleFavoriteRoom(_ roomID: UUID) {
        if favoriteRoomIDs.contains(roomID) { favoriteRoomIDs.remove(roomID) } else { favoriteRoomIDs.insert(roomID) }
        persistApplicationState()
    }

    func isFavoriteScene(_ sceneID: UUID) -> Bool { favoriteSceneIDs.contains(sceneID) }

    func toggleFavoriteScene(_ sceneID: UUID) {
        if favoriteSceneIDs.contains(sceneID) { favoriteSceneIDs.remove(sceneID) } else { favoriteSceneIDs.insert(sceneID) }
        persistApplicationState()
    }

    var favoriteRooms: [Room] { rooms.filter { favoriteRoomIDs.contains($0.id) } }
    var favoriteScenes: [LightingScene] { scenes.filter { favoriteSceneIDs.contains($0.id) } }

    func addBrightnessPreset(_ value: Double) {
        customBrightnessPresets = PersistenceStore.sanitizedBrightnessPresets(
            customBrightnessPresets + [value]
        )
        persistApplicationState()
    }

    func deleteBrightnessPreset(_ value: Double) {
        customBrightnessPresets.removeAll { abs($0 - value) < 0.005 }
        persistApplicationState()
    }

}

// MARK: - Scenes

extension LightManager {
    func captureScene(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var snapshots: [String: DeviceSnapshot] = [:]
        for d in devices {
            let hsb = d.color.hsbComponents
            snapshots[d.id] = DeviceSnapshot(
                isOn: d.isOn,
                brightness: d.brightness,
                hue: hsb.h,
                saturation: hsb.s,
                kelvin: d.kelvin,
                segments: activeSegmentState(for: d.id),
                matrix: activeLIFXMatrixState(for: d.id)
            )
        }
        scenes.append(LightingScene(name: trimmed, snapshots: snapshots))
        persistApplicationState()
        logActivity(.scene, title: "Scene captured", detail: "\(trimmed): \(snapshots.count) lights")
    }

    func applyScene(_ scene: LightingScene) {
        applyScene(scene, allowTurningOff: true, reviewed: false)
    }

    func deleteScene(_ sceneID: UUID) {
        guard let idx = scenes.firstIndex(where: { $0.id == sceneID }) else { return }
        let scene = scenes[idx]
        confirmationCoordinator.request(
            .init(
                title: "Delete “\(scene.name)”?",
                message: "The scene will be removed from the library and favorites. You can undo the deletion afterward.",
                confirmTitle: "Delete Scene",
                role: .destructive
            ),
            action: { [weak self] in self?.performDeleteScene(sceneID) }
        )
    }

    private func performDeleteScene(_ sceneID: UUID) {
        guard let idx = scenes.firstIndex(where: { $0.id == sceneID }) else { return }
        let deleted = scenes[idx]
        lastDeletedScene = (scene: deleted, index: idx)
        scenes.remove(at: idx)
        favoriteSceneIDs.remove(sceneID)
        persistApplicationState()
        publishError("Scene “\(deleted.name)” deleted.") { self.undoDeleteScene() }
    }

    func undoDeleteScene() {
        guard let (scene, index) = lastDeletedScene else { return }
        scenes.insert(scene, at: min(index, scenes.count))
        lastDeletedScene = nil
        persistApplicationState()
        commandError = nil
        commandErrorUndo = nil
    }

    func renameScene(_ sceneID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = scenes.firstIndex(where: { $0.id == sceneID }) else { return }
        scenes[idx].name = trimmed
        persistApplicationState()
    }

    func updateScene(_ draft: LightingScene, revisionLabel: String = "Before edit") {
        guard let index = scenes.firstIndex(where: { $0.id == draft.id }) else { return }
        sceneRevisions.insert(SceneRevision(scene: scenes[index], label: revisionLabel), at: 0)
        sceneRevisions = Array(sceneRevisions.prefix(60))
        scenes[index] = draft
        sceneDrafts.removeValue(forKey: draft.id)
        persistApplicationState()
        lastActionSummary = "Saved \(draft.name) — Undo restores the previous version"
    }

    func revisions(for sceneID: UUID) -> [SceneRevision] { sceneRevisions.filter { $0.sceneID == sceneID } }

    func recoveredDraft(for sceneID: UUID) -> LightingScene? { sceneDrafts[sceneID] }
    func autosaveSceneDraft(_ draft: LightingScene) {
        sceneDrafts[draft.id] = draft
        persistApplicationState()
    }
    func discardSceneDraft(for sceneID: UUID) {
        sceneDrafts.removeValue(forKey: sceneID)
        persistApplicationState()
    }

    func restoreSceneRevision(_ revision: SceneRevision) {
        guard let index = scenes.firstIndex(where: { $0.id == revision.sceneID }) else { return }
        sceneRevisions.insert(SceneRevision(scene: scenes[index], label: "Before restore"), at: 0)
        scenes[index].name = revision.name
        scenes[index].snapshots = revision.snapshots
        persistApplicationState()
        lastActionSummary = "Restored \(revision.label)"
    }

    func startSceneRehearsal(_ scene: LightingScene, deviceIDs: Set<String>) {
        stopSceneRehearsal(restore: true)
        let targets = devices.filter { deviceIDs.contains($0.id) && scene.snapshots[$0.id] != nil && !$0.isStale }
        guard !targets.isEmpty else {
            publishError("“\(scene.name)” has no currently available lights to preview.")
            return
        }
        rehearsalSnapshot = targets.map(snapshot)
        rehearsalSceneID = scene.id
        for device in targets {
            guard let value = scene.snapshots[device.id] else { continue }
            device.isOn = value.isOn; device.brightness = value.brightness; device.kelvin = value.kelvin
            if let matrix = value.matrix, device.isLIFXLuna {
                applyLIFXMatrix(device, state: matrix, recordUndo: false,
                                turnOn: false, announce: false)
            } else {
                device.color = Color(hue: value.hue, saturation: value.saturation, brightness: 1)
                sendColor(device, color: device.color)
            }
            sendPower(device, on: value.isOn)
        }
        lastActionSummary = "Rehearsing \(scene.name) on \(targets.count) light\(targets.count == 1 ? "" : "s")"
    }

    func stopSceneRehearsal(restore: Bool = true) {
        guard rehearsalSceneID != nil else { return }
        if restore { restoreDeviceStates(rehearsalSnapshot) }
        rehearsalSnapshot = []
        rehearsalSceneID = nil
        lastActionSummary = restore ? "Rehearsal ended — prior state restored" : "Rehearsal kept"
    }

    func duplicateNameMessage(_ candidate: String, excludingDeviceID: String? = nil) -> String? {
        let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        let matches = devices.filter { $0.id != excludingDeviceID && $0.label.lowercased() == normalized }
        guard !matches.isEmpty else { return nil }
        let roomNames = rooms.filter { room in matches.contains(where: { room.lightIDs.contains($0.id) }) }.map(\.name)
        return roomNames.isEmpty ? "Another light already uses this name." : "Already used in \(roomNames.joined(separator: ", ")). Consider adding the room name."
    }

    func duplicateSceneNameMessage(_ candidate: String, excludingSceneID: UUID? = nil) -> String? {
        scenes.contains { $0.id != excludingSceneID && $0.name.caseInsensitiveCompare(candidate.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame } ? "Another scene already uses this name." : nil
    }

}

// MARK: - Schedules

extension LightManager {
    func schedules(for roomID: UUID) -> [ScheduleEntry] {
        rooms.first(where: { $0.id == roomID })?.schedules ?? []
    }

    func addSchedule(_ entry: ScheduleEntry, to roomID: UUID) {
        guard let idx = rooms.firstIndex(where: { $0.id == roomID }),
              rooms[idx].schedules.count < 12 else { return }
        rooms[idx].schedules.append(entry)
        // Sort by resolved clock-minute so the list is always chronological.
        rooms[idx].schedules.sort { lhs, rhs in
            scheduleEngine.scheduledMinute(for: lhs, solarTimes: scheduleSolarTimes)
                < scheduleEngine.scheduledMinute(for: rhs, solarTimes: scheduleSolarTimes)
        }
        persistApplicationState()
    }

    func deleteSchedule(_ entryID: UUID, from roomID: UUID) {
        guard let idx = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        rooms[idx].schedules.removeAll { $0.id == entryID }
        persistApplicationState()
    }

    func setScheduleEnabled(_ entryID: UUID, in roomID: UUID, enabled: Bool) {
        guard let rIdx = rooms.firstIndex(where: { $0.id == roomID }),
              let eIdx = rooms[rIdx].schedules.firstIndex(where: { $0.id == entryID }) else { return }
        rooms[rIdx].schedules[eIdx].isEnabled = enabled
        persistApplicationState()
    }

    var hasActiveSchedules: Bool {
        scheduleEngine.hasEnabledSchedules(in: rooms)
    }

    func nextRunDescription(for entry: ScheduleEntry) -> String {
        let next = scheduleEngine.nextOccurrence(for: entry, solarTimes: scheduleSolarTimes)
        guard let next else { return "No next run" }
        return "Next runs \(next.formatted(.relative(presentation: .named))) at \(next.formatted(date: .omitted, time: .shortened))"
    }

    func conflictWarnings(for roomID: UUID) -> [String] {
        scheduleEngine.conflicts(in: schedules(for: roomID), solarTimes: scheduleSolarTimes).map { conflict in
            "\(conflict.first.action.displayName) and \(conflict.second.action.displayName) are within 5 minutes."
        }
    }

    // Estimates are for the Northern Hemisphere. Southern Hemisphere users should set times manually.
    func applyEstimatedSolarTimes() {
        let month = Calendar.current.component(.month, from: scheduleEngine.currentDate)
        switch month {
        case 4...8:
            setSunriseTime(hour: 5, minute: 45)
            setSunsetTime(hour: 20, minute: 30)
        case 11, 12, 1, 2:
            setSunriseTime(hour: 7, minute: 15)
            setSunsetTime(hour: 17, minute: 0)
        default:
            setSunriseTime(hour: 6, minute: 30)
            setSunsetTime(hour: 19, minute: 0)
        }
    }
}

// MARK: - Search

extension LightManager {
    func device(_ device: LightDevice, matchesQuery query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.isEmpty { return true }
        return device.label.lowercased().contains(trimmed)
            || device.name.lowercased().contains(trimmed)
            || device.brand.displayName.lowercased().contains(trimmed)
            || device.address.lowercased().contains(trimmed)
    }

    func room(_ room: Room, matchesQuery query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.isEmpty { return true }
        if room.name.lowercased().contains(trimmed) { return true }
        return devices(in: room).contains { device($0, matchesQuery: query) }
    }
}

// MARK: - White mode persistence (UX: color mode survives re-renders)

extension LightManager {
    func isWhiteMode(_ deviceID: String) -> Bool { whiteModeDeviceIDs.contains(deviceID) }

    func setWhiteMode(_ deviceID: String, white: Bool) {
        if white { whiteModeDeviceIDs.insert(deviceID) } else { whiteModeDeviceIDs.remove(deviceID) }
        persistApplicationState()
    }
}

// MARK: - Nap Mode

extension LightManager {
    func startNapMode() {
        guard napPhase == .inactive else { cancelNapMode(); return }
        napSnapshotBrightness = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.brightness) })
        napPhase = .dimming(endsAt: Date().addingTimeInterval(20 * 60))
        scheduleNapTimer()
    }

    private func scheduleNapTimer() {
        napTimer?.invalidate()
        napTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickNapMode() }
        }
        napTimer?.tolerance = 1
    }

    func cancelNapMode() {
        napTimer?.invalidate()
        napTimer = nil
        for (id, brightness) in napSnapshotBrightness {
            if let d = device(withID: id) { d.brightness = brightness; sendBrightness(d, value: brightness) }
        }
        napSnapshotBrightness = [:]
        napPhase = .inactive
    }

    private func tickNapMode() {
        let now = Date()
        switch napPhase {
        case .inactive:
            break
        case .dimming(let endsAt):
            let total: TimeInterval = 20 * 60
            let remaining = endsAt.timeIntervalSince(now)
            if remaining <= 0 {
                for d in devices { d.brightness = 0.01; sendBrightness(d, value: 0.01) }
                napPhase = .holding(endsAt: now.addingTimeInterval(70 * 60))
            } else {
                let factor = pow((remaining / total), 1.5)
                for (id, startBrightness) in napSnapshotBrightness {
                    if let d = device(withID: id), d.isOn {
                        let target = max(0.01, startBrightness * factor)
                        d.brightness = target
                        sendBrightness(d, value: target)
                    }
                }
            }
        case .holding(let endsAt):
            if endsAt.timeIntervalSince(now) <= 0 {
                napPhase = .brightening(endsAt: now.addingTimeInterval(10 * 60))
            }
        case .brightening(let endsAt):
            let total: TimeInterval = 10 * 60
            let remaining = endsAt.timeIntervalSince(now)
            if remaining <= 0 {
                let warmWhite = Color(red: 1.0, green: 0.87, blue: 0.67)
                for d in devices {
                    if !d.isOn { d.isOn = true; sendPower(d, on: true) }
                    d.color = warmWhite; d.brightness = 0.5
                    sendColor(d, color: warmWhite)
                    if d.brand == .govee { sendBrightness(d, value: 0.5) }
                }
                napTimer?.invalidate(); napTimer = nil
                napSnapshotBrightness = [:]; napPhase = .inactive
            } else {
                let progress = (total - remaining) / total
                for d in devices where d.isOn {
                    let target = max(0.01, progress * 0.5)
                    d.brightness = target; sendBrightness(d, value: target)
                }
            }
        }
    }

    var napCountdownString: String {
        let now = Date()
        switch napPhase {
        case .inactive: return ""
        case .dimming(let endsAt):
            return "Dimming · \(Int(max(0, endsAt.timeIntervalSince(now)) / 60))m"
        case .holding(let endsAt):
            return "Napping · \(Int(max(0, endsAt.timeIntervalSince(now)) / 60))m left"
        case .brightening(let endsAt):
            return "Waking · \(Int(max(0, endsAt.timeIntervalSince(now)) / 60))m"
        }
    }
}

// MARK: - Color helpers

extension Color {
    func rgbDistance(to other: Color) -> Double {
        let lhs = rgbComponents
        let rhs = other.rgbComponents
        return max(abs(lhs.r - rhs.r), max(abs(lhs.g - rhs.g), abs(lhs.b - rhs.b)))
    }

    var hsbComponents: (h: Double, s: Double, b: Double) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if os(macOS)
        guard let ns = NSColor(self).usingColorSpace(.sRGB) else { return (0, 0, 1) }
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        #else
        guard UIColor(self).getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return (0, 0, 1) }
        #endif
        return (Double(h), Double(s), Double(b))
    }

    var rgbComponents: (r: Double, g: Double, b: Double) {
        var r: CGFloat = 0, g: CGFloat = 0, bb: CGFloat = 0, a: CGFloat = 0
        #if os(macOS)
        guard let ns = NSColor(self).usingColorSpace(.sRGB) else { return (1, 1, 1) }
        ns.getRed(&r, green: &g, blue: &bb, alpha: &a)
        #else
        guard UIColor(self).getRed(&r, green: &g, blue: &bb, alpha: &a) else { return (1, 1, 1) }
        #endif
        return (Double(r), Double(g), Double(bb))
    }
}

// MARK: - Music Mode

extension LightManager {
    func setMusicModeConfiguration(_ configuration: MusicModeConfiguration) {
        musicModeConfiguration = configuration.normalized()
        persistApplicationState()
        for scope in musicModeController.activeScopeIDs {
            musicModeController.update(
                scope: scope,
                configuration: musicModeConfiguration,
                topology: fixtureTopology(for: scope),
                fixtures: musicFixtureDescriptors(in: scope),
                reducedMotion: effectRuns[scope]?.reducedMotion ?? false
            )
        }
    }

    func applyMusicModePreset(_ preset: MusicModePreset) {
        guard preset != .custom else {
            var custom = musicModeConfiguration
            custom.preset = .custom
            setMusicModeConfiguration(custom)
            return
        }
        setMusicModeConfiguration(.configuration(for: preset))
    }

    func fixtureTopology(for scope: LightScope) -> FixtureTopology {
        fixtureTopologies[topologyKey(for: scope)] ?? FixtureTopology()
    }

    func setFixtureTopology(_ topology: FixtureTopology, for scope: LightScope) {
        let available = Set(musicFixtureDescriptors(in: scope).map(\.id))
        var normalized = topology
        normalized.fixtureOrder = topology.fixtureOrder.filter(available.contains)
        fixtureTopologies[topologyKey(for: scope)] = normalized
        persistApplicationState()
        if musicModeController.activeScopeIDs.contains(scope) {
            musicModeController.update(
                scope: scope,
                configuration: musicModeConfiguration,
                topology: normalized,
                fixtures: musicFixtureDescriptors(in: scope),
                reducedMotion: effectRuns[scope]?.reducedMotion ?? false
            )
        }
    }

    func musicFixtureDescriptors(in scope: LightScope) -> [MusicFixtureDescriptor] {
        devices(in: scope).map { device in
            if device.brand == .govee, segmentProfile(for: device) != nil {
                return MusicFixtureDescriptor(
                    id: device.id,
                    label: device.label,
                    transport: .goveeRealtimeSegments,
                    segmentCount: segmentState(for: device).segmentCount
                )
            }
            return MusicFixtureDescriptor(
                id: device.id,
                label: device.label,
                transport: device.brand == .lifx ? .lifxLAN : .goveeLAN
            )
        }
    }

    private func topologyKey(for scope: LightScope) -> String {
        switch scope {
        case .all: return "all"
        case .room(let roomID): return "room:\(roomID.uuidString.lowercased())"
        }
    }

    private func renderMusicFrame(_ frame: MusicLightingFrame, scope: LightScope) {
        guard effectRuns[scope]?.effect.id == "music-pulse" else { return }
        let fixtures = musicFixtureDescriptors(in: scope)
        let commands = musicLightingRenderer.enqueue(frame, fixtures: fixtures, at: frame.timestamp)
        for command in commands {
            guard let device = device(withID: command.fixtureID), let first = command.states.first else { continue }
            let color = Color(hue: first.hue, saturation: first.saturation, brightness: 1)
            if frame.timestamp - (musicModelUpdateAt[device.id] ?? -Double.greatestFiniteMagnitude) >= 0.2 {
                device.color = color
                device.brightness = first.brightness
                musicModelUpdateAt[device.id] = frame.timestamp
            }

            switch command.transport {
            case .lifxLAN, .goveeLAN:
                sendEffectFrame(
                    device,
                    color: color,
                    brightness: first.brightness,
                    duration: first.transitionDuration
                )
            case .goveeRealtimeSegments:
                let segments = command.states.map { state in
                    GoveeSegmentColor(
                        color: Color(hue: state.hue, saturation: state.saturation, brightness: 1),
                        brightness: state.brightness
                    )
                }
                guard !segments.isEmpty else { continue }
                previewSegments(
                    device,
                    state: GoveeSegmentState(colors: segments, gradient: false, isActive: false)
                )
            }
        }
    }

    private func finishMusicStreaming<S: Sequence>(for deviceIDs: S) where S.Element == String {
        let ids = Set(deviceIDs)
        musicLightingRenderer.reset(fixtureIDs: ids)
        for id in ids {
            musicModelUpdateAt.removeValue(forKey: id)
            guard let device = device(withID: id),
                  device.brand == .govee,
                  segmentProfile(for: device) != nil else { continue }
            endSegmentPreview(device)
        }
    }
}

// MARK: - Second-pass UX services

extension LightManager {
    private func persistApplicationState() {
        guard demoWorkspaceController.allowsLivePersistence else { return }
        try? persistenceStore.save(persistedApplicationState())
    }

    private func persistedApplicationState() -> PersistedApplicationState {
        var state = PersistedApplicationState()
        state.rooms = rooms
        state.favoriteIDs = favoriteIDs
        state.scenes = scenes
        state.customNames = customNames
        state.collapsedRooms = collapsedRooms
        state.solarPreferences = .init(
            sunriseHour: sunriseHour,
            sunriseMinute: sunriseMinute,
            sunsetHour: sunsetHour,
            sunsetMinute: sunsetMinute
        )
        state.whiteModeDeviceIDs = whiteModeDeviceIDs
        state.favoriteRoomIDs = favoriteRoomIDs
        state.favoriteSceneIDs = favoriteSceneIDs
        state.customBrightnessPresets = customBrightnessPresets
        state.activityEvents = activityEvents
        state.favoriteOrder = favoriteOrder
        state.parliamentMembers = parliamentMembers
        state.parliamentSessions = parliamentSessions
        state.sceneCertifications = sceneCertifications
        state.recentColors = recentColors
        state.automationOverrides = automationOverrides
        state.sceneRevisions = sceneRevisions
        state.sceneDrafts = sceneDrafts
        state.goveeSegmentStates = goveeSegmentStates
        state.goveeSegmentPresets = goveeSegmentPresets
        state.musicModeConfiguration = musicModeConfiguration
        state.fixtureTopologies = fixtureTopologies
        return state
    }

    private func applyPersistedApplicationState(_ state: PersistedApplicationState) {
        rooms = state.rooms
        favoriteIDs = state.favoriteIDs
        scenes = state.scenes
        customNames = state.customNames
        collapsedRooms = state.collapsedRooms
        sunriseHour = state.solarPreferences.sunriseHour
        sunriseMinute = state.solarPreferences.sunriseMinute
        sunsetHour = state.solarPreferences.sunsetHour
        sunsetMinute = state.solarPreferences.sunsetMinute
        whiteModeDeviceIDs = state.whiteModeDeviceIDs
        favoriteRoomIDs = state.favoriteRoomIDs
        favoriteSceneIDs = state.favoriteSceneIDs
        customBrightnessPresets = state.customBrightnessPresets
        activityEvents = state.activityEvents
        favoriteOrder = state.favoriteOrder
        parliamentMembers = state.parliamentMembers
        parliamentSessions = state.parliamentSessions
        sceneCertifications = state.sceneCertifications
        recentColors = state.recentColors
        scheduleEngine.restoreAutomationOverrides(state.automationOverrides)
        sceneRevisions = state.sceneRevisions
        sceneDrafts = state.sceneDrafts
        goveeSegmentStates = state.goveeSegmentStates
        goveeSegmentPresets = state.goveeSegmentPresets
        musicModeConfiguration = state.musicModeConfiguration
        fixtureTopologies = state.fixtureTopologies
    }

    func logActivity(_ kind: ActivityEvent.Kind, title: String, detail: String = "", isFailure: Bool = false) {
        activityEvents.insert(ActivityEvent(kind: kind, title: title, detail: detail, isFailure: isFailure), at: 0)
        if activityEvents.count > 250 { activityEvents.removeLast(activityEvents.count - 250) }
        persistApplicationState()
    }

    func clearActivity() {
        activityEvents.removeAll()
        persistApplicationState()
    }

    func activityExportText() -> String {
        activityEvents.reversed().map {
            "[\($0.date.formatted(date: .numeric, time: .standard))] \($0.kind.rawValue.uppercased()) — \($0.title)\($0.detail.isEmpty ? "" : ": \($0.detail)")"
        }.joined(separator: "\n")
    }

    func recentActivitySummary(for device: LightDevice) -> String? {
        activityEvents.first { $0.detail.localizedCaseInsensitiveContains(device.label) || $0.detail.localizedCaseInsensitiveContains(device.id) }
            .map { "\($0.title) · \($0.date.formatted(.relative(presentation: .named)))" }
    }

    func recentActivitySummary(for room: Room) -> String? {
        activityEvents.first { $0.detail.localizedCaseInsensitiveContains(room.name) || $0.title.localizedCaseInsensitiveContains(room.name) }
            .map { "\($0.title) · \($0.date.formatted(.relative(presentation: .named)))" }
    }

    func aggregatePowerState(for lights: [LightDevice]) -> AggregatePowerState {
        let on = lights.filter(\.isOn).count
        if on == 0 { return .off }
        if on == lights.count { return .on }
        return .mixed(on: on, total: lights.count)
    }

    func toggleAggregatePower(_ lights: [LightDevice]) {
        let target = lights.filter(\.isOn).count < lights.count
        setPower(deviceIDs: Set(lights.map(\.id)), on: target)
        logActivity(.command, title: target ? "Lights turned on" : "Lights turned off", detail: "\(lights.count) selected lights")
    }

    /// Optimistically updates the UI while coalescing LAN traffic to one send per 120 ms.
    func previewBrightness(_ device: LightDevice, value: Double) {
        device.brightness = value
        brightnessTasks[device.id]?.cancel()
        brightnessTasks[device.id] = Task { @MainActor [weak self, weak device] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self, let device else { return }
            self.sendBrightness(device, value: value)
            self.brightnessTasks[device.id] = nil
        }
    }

    func commitBrightness(_ device: LightDevice, value: Double) {
        brightnessTasks[device.id]?.cancel()
        brightnessTasks[device.id] = nil
        device.brightness = value
        sendBrightness(device, value: value)
        logActivity(.command, title: "Brightness changed", detail: "\(device.label): \(Int(value * 100))%")
    }

    func identify(_ device: LightDevice) {
        let originalPower = device.isOn
        let originalColor = device.color
        let originalBrightness = device.brightness
        let originalSegments = activeSegmentState(for: device.id)
        let originalMatrix = activeLIFXMatrixState(for: device.id)
        device.isOn = true
        device.color = .cyan
        device.brightness = 1
        sendPower(device, on: true); sendColor(device, color: .cyan); sendBrightness(device, value: 1)
        logActivity(.recovery, title: "Identifying light", detail: device.label)
        Task { @MainActor [weak self, weak device] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, let device else { return }
            device.color = originalColor; device.brightness = originalBrightness; device.isOn = originalPower
            if let originalMatrix {
                self.applyLIFXMatrix(device, state: originalMatrix, recordUndo: false,
                                     turnOn: false, announce: false)
            } else if let originalSegments {
                self.applySegments(device, state: originalSegments, recordUndo: false, turnOn: false, announce: false)
            } else {
                self.sendColor(device, color: originalColor)
            }
            self.sendBrightness(device, value: originalBrightness); self.sendPower(device, on: originalPower)
        }
    }

    func retry(_ device: LightDevice) {
        commandCoordinator.recover(deviceID: device.id) { [weak self, weak device] in
            guard let self, let device else { return }
            self.refresh(device)
        }
        logActivity(.recovery, title: "Retried unreachable light", detail: device.label)
    }

    func diagnostics(for device: LightDevice) -> [ScanDiagnostic] {
        [
            ScanDiagnostic(title: "Vendor", value: device.brand.displayName, status: .neutral),
            ScanDiagnostic(title: "Model", value: device.sku ?? "Not reported", status: .neutral),
            ScanDiagnostic(title: "Segment control",
                           value: segmentProfile(for: device).map { "\($0.layout.displayName) · \(segmentState(for: device).segmentCount) segments" } ?? "Not detected",
                           status: .neutral),
            ScanDiagnostic(title: "Address", value: device.address, status: .neutral),
            ScanDiagnostic(title: "Last seen", value: device.lastSeen.formatted(date: .abbreviated, time: .standard), status: device.isStale ? .warning : .good),
            ScanDiagnostic(title: "Reachability", value: device.isStale ? "Not seen recently" : "Responding", status: device.isStale ? .warning : .good),
            ScanDiagnostic(title: "Color temperature", value: "2,500–9,000 K", status: .neutral),
            ScanDiagnostic(title: "LAN identifier", value: device.backendID, status: .neutral)
        ]
    }

    var likelyLocalNetworkPermissionIssue: Bool {
        lastScanDate != nil && scanResponseCount == 0 && devices.isEmpty
    }

    var scanDiagnostics: [ScanDiagnostic] {
        [
            ScanDiagnostic(title: "LIFX protocol", value: lifx == nil ? "Unavailable" : "Ready on UDP 56700", status: lifx == nil ? .warning : .good),
            ScanDiagnostic(title: "Govee protocol", value: govee == nil ? "Unavailable" : "Ready on UDP 4001–4003", status: govee == nil ? .warning : .good),
            ScanDiagnostic(title: "Last scan", value: lastScanDate?.formatted(date: .abbreviated, time: .standard) ?? "Not yet scanned", status: .neutral),
            ScanDiagnostic(title: "Responses", value: "\(scanResponseCount)", status: scanResponseCount == 0 ? .warning : .good),
            ScanDiagnostic(title: "Discovered lights", value: "\(devices.count)", status: devices.isEmpty ? .warning : .good)
        ]
    }

    func updateSchedule(_ entry: ScheduleEntry, in roomID: UUID) {
        guard let roomIndex = rooms.firstIndex(where: { $0.id == roomID }),
              let entryIndex = rooms[roomIndex].schedules.firstIndex(where: { $0.id == entry.id }) else { return }
        rooms[roomIndex].schedules[entryIndex] = entry
        persistApplicationState()
        logActivity(.schedule, title: "Schedule updated", detail: "\(rooms[roomIndex].name): \(entry.daySummary) at \(entry.timeString)")
    }

    func duplicateSchedule(_ entry: ScheduleEntry, in roomID: UUID) {
        guard let roomIndex = rooms.firstIndex(where: { $0.id == roomID }), rooms[roomIndex].schedules.count < 12 else { return }
        let copy = ScheduleEntry(hour: entry.hour, minute: entry.minute, offsetMinutes: entry.offsetMinutes, action: entry.action, weekdays: entry.weekdays)
        rooms[roomIndex].schedules.append(copy); persistApplicationState()
        logActivity(.schedule, title: "Schedule duplicated", detail: rooms[roomIndex].name)
    }

    func testSchedule(_ entry: ScheduleEntry, in room: Room) {
        let lights = devices(in: room)
        switch entry.action {
        case .turnOn, .atSunrise: setPower(deviceIDs: Set(lights.map(\.id)), on: true)
        case .turnOff, .atSunset: setPower(deviceIDs: Set(lights.map(\.id)), on: false)
        default: if let value = entry.action.brightnessValue { setBrightness(deviceIDs: Set(lights.map(\.id)), value: value) }
        }
        logActivity(.schedule, title: "Schedule tested", detail: "\(room.name): \(entry.action.displayName)")
    }

    func scenePreview(_ scene: LightingScene) -> SceneApplicationPreview {
        let affected = devices.filter { scene.snapshots[$0.id] != nil }
        let unreachable = affected.filter(\.isStale)
        let missing = scene.snapshots.keys.filter { id in !devices.contains(where: { $0.id == id }) }
        let unchanged = affected.filter { d in
            guard let snap = scene.snapshots[d.id] else { return false }
            let hsb = d.color.hsbComponents
            return d.isOn == snap.isOn && abs(d.brightness - snap.brightness) < 0.01 && abs(hsb.h - snap.hue) < 0.01
        }
        return SceneApplicationPreview(scene: scene, affected: affected, unreachable: unreachable, missingIDs: missing, unchanged: unchanged)
    }

    func availableDeviceIDs(for scene: LightingScene) -> Set<String> {
        Set(devices.lazy.filter { scene.snapshots[$0.id] != nil && !$0.isStale }.map(\.id))
    }

    func applyScene(_ scene: LightingScene, allowTurningOff: Bool, reviewed: Bool = false) {
        let preview = scenePreview(scene)
        guard !preview.affected.isEmpty else { publishError("“\(scene.name)” has no discovered lights to change."); return }
        let availableCount = preview.affected.count - preview.unreachable.count
        guard availableCount > 0 else {
            publishError("“\(scene.name)” has no currently available lights to change.")
            return
        }
        if !reviewed {
            confirmationCoordinator.request(
                .init(
                    title: "Apply “\(scene.name)”?",
                    message: "This scene will change \(availableCount) available light\(availableCount == 1 ? "" : "s")\(preview.unreachable.isEmpty ? "." : "; \(preview.unreachable.count) offline light\(preview.unreachable.count == 1 ? "" : "s") may need retry.") You can undo the change afterward.",
                    confirmTitle: "Apply Scene"
                ),
                action: { [weak self] in self?.applyScene(scene, allowTurningOff: allowTurningOff, reviewed: true) }
            )
            return
        }
        stopEffects(touching: Set(preview.affected.map(\.id)))
        recordChange(preview.affected)
        var succeeded: [String] = [], failed: [String] = [], skipped: [String] = []
        for device in preview.affected {
            guard let snap = scene.snapshots[device.id] else { continue }
            if !allowTurningOff && !snap.isOn { skipped.append(device.id); continue }
            if device.isStale { failed.append(device.id) } else { succeeded.append(device.id) }
            device.brightness = snap.brightness; device.kelvin = snap.kelvin; device.isOn = snap.isOn
            if let matrix = snap.matrix, device.isLIFXLuna {
                applyLIFXMatrix(device, state: matrix, recordUndo: false,
                                turnOn: false, announce: false)
            } else if let segments = snap.segments, device.brand == .govee {
                applySegments(device, state: segments, recordUndo: false, turnOn: false, announce: false)
                sendBrightness(device, value: snap.brightness)
            } else {
                let color = Color(hue: snap.hue, saturation: snap.saturation, brightness: 1)
                device.color = color
                sendColor(device, color: color)
                if device.brand == .govee { sendBrightness(device, value: snap.brightness) }
            }
            sendPower(device, on: snap.isOn)
        }
        lastSceneResult = SceneApplicationResult(sceneName: scene.name, succeededIDs: succeeded, failedIDs: failed, skippedOffIDs: skipped)
        logActivity(.scene, title: "Scene applied", detail: "\(scene.name): \(succeeded.count) succeeded, \(failed.count) need retry", isFailure: !failed.isEmpty)
    }

    func retryLastSceneFailures() {
        guard let result = lastSceneResult, let scene = scenes.first(where: { $0.name == result.sceneName }) else { return }
        let failed = devices.filter { result.failedIDs.contains($0.id) }
        for device in failed { retry(device) }
        applyScene(scene, allowTurningOff: true, reviewed: true)
    }

    func reconcileFavoriteOrder() {
        let active = Set(favoriteIDs.map { FavoriteReference(kind: .light, rawID: $0) }
            + favoriteRoomIDs.map { FavoriteReference(kind: .room, rawID: $0.uuidString) }
            + favoriteSceneIDs.map { FavoriteReference(kind: .scene, rawID: $0.uuidString) })
        favoriteOrder = favoriteOrder.filter(active.contains)
        favoriteOrder.append(contentsOf: active.filter { !favoriteOrder.contains($0) }.sorted { $0.id < $1.id })
        persistApplicationState()
    }

    func moveFavorite(from source: IndexSet, to destination: Int) {
        reconcileFavoriteOrder(); favoriteOrder.move(fromOffsets: source, toOffset: destination)
        persistApplicationState()
    }

    func rememberColor(_ color: Color, name: String) {
        let candidate = RecentColor(color: color, name: name)
        recentColors.removeAll { $0.hex == candidate.hex }
        recentColors.insert(candidate, at: 0)
        if recentColors.count > 8 { recentColors.removeLast(recentColors.count - 8) }
        persistApplicationState()
    }

    func ensureParliament() {
        let existing = Set(parliamentMembers.map(\.id))
        for (index, device) in devices.enumerated() where !existing.contains(device.id) {
            let titles = ["The Rt. Hon. Glow", "Baron von Bulb", "Dame Incandescence", "Minister Lux", "Sir Filament"]
            let parties = ParliamentMember.Party.allCases
            parliamentMembers.append(ParliamentMember(id: device.id, parliamentaryName: "\(titles[index % titles.count]) of \(device.label)", party: parties[index % parties.count], approval: 50, lastVote: "Newly seated"))
        }
        parliamentMembers.removeAll { member in !devices.contains(where: { $0.id == member.id }) }
        persistApplicationState()
    }

    @discardableResult
    func conveneParliament(motion: String) -> ParliamentSession {
        ensureParliament()
        var ayes = 0, noes = 0, abstentions = 0
        for index in parliamentMembers.indices {
            guard let device = device(withID: parliamentMembers[index].id), !device.isStale else {
                abstentions += 1; parliamentMembers[index].lastVote = "Abstained (unreachable)"; continue
            }
            let bias = parliamentMembers[index].party == .efficiencyBloc && motion.lowercased().contains("off") ? 25 : 0
            let vote = Int.random(in: 0..<100) < 55 + bias
            if vote { ayes += 1; parliamentMembers[index].lastVote = "Aye" } else { noes += 1; parliamentMembers[index].lastVote = "No" }
            parliamentMembers[index].approval = max(0, min(100, parliamentMembers[index].approval + (vote ? 1 : -1)))
        }
        let passed = ayes > noes
        let session = ParliamentSession(id: UUID(), date: Date(), motion: motion, ayes: ayes, noes: noes, abstentions: abstentions, verdict: passed ? "Motion carried" : "Motion defeated")
        parliamentSessions.insert(session, at: 0)
        if parliamentSessions.count > 50 { parliamentSessions.removeLast() }
        persistApplicationState()
        logActivity(.parliament, title: session.verdict, detail: "\(ayes) ayes, \(noes) noes, \(abstentions) abstentions — \(motion)")
        if passed { executiveIlluminationOrder(motion: motion) }
        return session
    }

    func executiveIlluminationOrder(motion: String) {
        if motion.lowercased().contains("off") { setAllPower(on: false) }
        else if motion.lowercased().contains("on") { setAllPower(on: true) }
        else { setAllBrightness(0.5) }
        logActivity(.parliament, title: "Executive Illumination Order", detail: motion)
    }

    func certify(_ scene: LightingScene) -> SceneCertification {
        let onCount = scene.snapshots.values.filter(\.isOn).count
        let hues = scene.snapshots.values.map(\.hue)
        let variety = Set(hues.map { Int($0 * 12) }).count
        let score = min(100, 45 + onCount * 4 + variety * 7 + min(12, scene.name.count))
        let seal: SceneCertification.Seal = score >= 85 ? .gold : (score >= 65 ? .silver : .bronze)
        let findings = [
            "Chromatic diversity: \(variety) recognized hue families.",
            "Estimated moth attraction: \(max(1, onCount * 3)) ceremonial moths per hour.",
            scene.name.count >= 4 ? "Scene nomenclature satisfies Article IV." : "Scene name is suspiciously terse.",
            "Wall-paint diplomacy risk: \(score > 75 ? "Acceptable" : "Requires bilateral consultation")."
        ]
        let certification = SceneCertification(id: UUID(), sceneID: scene.id, issuedAt: Date(), score: score, seal: seal, findings: findings, treatyCode: "IBL-\(Int.random(in: 10000...99999))-LUX")
        sceneCertifications.removeAll { $0.sceneID == scene.id }
        sceneCertifications.append(certification); persistApplicationState()
        logActivity(.compliance, title: "Scene certified \(seal.rawValue.capitalized)", detail: "\(scene.name) scored \(score)/100")
        return certification
    }

    func certification(for sceneID: UUID) -> SceneCertification? { sceneCertifications.first { $0.sceneID == sceneID } }
}

// MARK: - Demo workspace

extension LightManager {
    func enterDemoMode() {
        guard !isDemoMode else { return }
        if rehearsalSceneID != nil { stopSceneRehearsal(restore: true) }
        let liveEffects = activeEffects
        stopAllEffects(restore: true)
        let liveWorkspace = captureWorkspaceState(activeEffects: liveEffects)
        guard let demoWorkspace = demoWorkspaceController.enter(liveWorkspace: liveWorkspace) else { return }
        cancelWorkspaceTasks()
        napTimer?.invalidate()
        napTimer = nil
        confirmationCoordinator.cancelPendingRequest()
        objectWillChange.send()
        applyWorkspaceState(demoWorkspace)
        effectRuns = [:]
        scheduleErrorClear()
    }

    func exitDemoMode() {
        guard isDemoMode else { return }
        confirmationCoordinator.cancelPendingRequest()
        if rehearsalSceneID != nil { stopSceneRehearsal(restore: false) }
        stopAllEffects(restore: false)
        napTimer?.invalidate()
        napTimer = nil
        cancelWorkspaceTasks()
        errorClearTask?.cancel()
        errorClearTask = nil
        guard let restoredWorkspace = demoWorkspaceController.exit() else { return }
        objectWillChange.send()
        applyWorkspaceState(restoredWorkspace)
        effectRuns = [:]

        if napPhase != .inactive { scheduleNapTimer() }
        for (scope, effectID) in restoredWorkspace.activeEffects {
            if let effect = LightingCatalog.effects.first(where: { $0.id == effectID }) {
                if effect.id == "music-pulse" {
                    startMusicMode(configuration: musicModeConfiguration, scope: scope)
                } else {
                    startEffect(effect, scope: scope)
                }
            }
        }
        // Restarting a previously active effect must not manufacture a new
        // user-visible undo step merely because Demo Mode was exited.
        undoStack = restoredWorkspace.undoStack
        redoStack = restoredWorkspace.redoStack
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        lastChangeTime = restoredWorkspace.lastChangeTime
        lastActionSummary = restoredWorkspace.lastActionSummary
        for id in commandPendingIDs {
            if let device = device(withID: id) {
                commandCoordinator.resumePendingCommand(
                    deviceID: id,
                    refresh: { [weak self, weak device] in
                        guard let self, let device else { return }
                        self.refresh(device)
                    },
                    timedOut: { [weak self, weak device] in
                        guard let self, let device else { return }
                        self.publishError("\(device.label) did not confirm the change. Keep trying or rescan.")
                    }
                )
            }
        }
    }

    func resetDemoMode() {
        guard isDemoMode else { return }
        confirmationCoordinator.cancelPendingRequest()
        if rehearsalSceneID != nil { stopSceneRehearsal(restore: false) }
        stopAllEffects(restore: false)
        napTimer?.invalidate()
        napTimer = nil
        cancelWorkspaceTasks()
        guard let demoWorkspace = demoWorkspaceController.reset(
            currentWorkspace: captureWorkspaceState(activeEffects: [:])
        ) else { return }
        applyWorkspaceState(demoWorkspace)
        effectRuns = [:]
        scheduleErrorClear()
    }

    private func cancelWorkspaceTasks() {
        scanGeneration += 1
        brightnessTasks.values.forEach { $0.cancel() }
        brightnessTasks = [:]
        commandCoordinator.cancelAllTasks(clearPendingAndExpectations: true)
    }

    private func captureWorkspaceState(
        activeEffects capturedActiveEffects: [LightScope: String]? = nil
    ) -> DemoWorkspaceController.WorkspaceState {
        DemoWorkspaceController.WorkspaceState(
            devices: devices,
            rooms: rooms,
            favoriteIDs: favoriteIDs,
            scenes: scenes,
            isScanning: isScanning,
            scanPhase: scanPhase,
            lastScanDate: lastScanDate,
            scanResponseCount: scanResponseCount,
            statusMessage: statusMessage,
            commandError: commandError,
            commandErrorUndo: commandErrorUndo,
            commandState: commandCoordinator.state,
            canUndo: canUndo,
            canRedo: canRedo,
            collapsedRooms: collapsedRooms,
            lastDeletedRoom: lastDeletedRoom,
            lastDeletedScene: lastDeletedScene,
            stalenessGeneration: stalenessGeneration,
            newlyDiscoveredIDs: newlyDiscoveredIDs,
            whiteModeDeviceIDs: whiteModeDeviceIDs,
            napPhase: napPhase,
            napSnapshotBrightness: napSnapshotBrightness,
            activeEffects: capturedActiveEffects ?? activeEffects,
            activityEvents: activityEvents,
            lastSceneResult: lastSceneResult,
            favoriteOrder: favoriteOrder,
            parliamentMembers: parliamentMembers,
            parliamentSessions: parliamentSessions,
            sceneCertifications: sceneCertifications,
            recentColors: recentColors,
            discoveryChanges: discoveryChanges,
            scheduleState: scheduleEngine.state,
            sceneRevisions: sceneRevisions,
            sceneDrafts: sceneDrafts,
            lastActionSummary: lastActionSummary,
            rehearsalSnapshot: rehearsalSnapshot,
            rehearsalSceneID: rehearsalSceneID,
            goveeSegmentStates: goveeSegmentStates,
            goveeSegmentPresets: goveeSegmentPresets,
            lifxMatrixStates: lifxMatrixStates,
            musicModeConfiguration: musicModeConfiguration,
            fixtureTopologies: fixtureTopologies,
            customNames: customNames,
            favoriteRoomIDs: favoriteRoomIDs,
            favoriteSceneIDs: favoriteSceneIDs,
            customBrightnessPresets: customBrightnessPresets,
            sunriseHour: sunriseHour,
            sunriseMinute: sunriseMinute,
            sunsetHour: sunsetHour,
            sunsetMinute: sunsetMinute,
            undoStack: undoStack,
            redoStack: redoStack,
            lastChangeTime: lastChangeTime,
            razerActiveIDs: razerActiveIDs,
            scanStartingIDs: scanStartingIDs,
            scanStartingAddresses: scanStartingAddresses
        )
    }

    private func applyWorkspaceState(_ workspace: DemoWorkspaceController.WorkspaceState) {
        devices = workspace.devices
        devicesByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        rooms = workspace.rooms
        favoriteIDs = workspace.favoriteIDs
        scenes = workspace.scenes
        isScanning = workspace.isScanning
        scanPhase = workspace.scanPhase
        lastScanDate = workspace.lastScanDate
        scanResponseCount = workspace.scanResponseCount
        statusMessage = workspace.statusMessage
        commandError = workspace.commandError
        commandErrorUndo = workspace.commandErrorUndo
        commandCoordinator.restore(workspace.commandState)
        canUndo = workspace.canUndo
        canRedo = workspace.canRedo
        collapsedRooms = workspace.collapsedRooms
        lastDeletedRoom = workspace.lastDeletedRoom
        lastDeletedScene = workspace.lastDeletedScene
        stalenessGeneration = workspace.stalenessGeneration
        newlyDiscoveredIDs = workspace.newlyDiscoveredIDs
        whiteModeDeviceIDs = workspace.whiteModeDeviceIDs
        napPhase = workspace.napPhase
        napSnapshotBrightness = workspace.napSnapshotBrightness
        activeEffects = workspace.activeEffects
        activityEvents = workspace.activityEvents
        lastSceneResult = workspace.lastSceneResult
        favoriteOrder = workspace.favoriteOrder
        parliamentMembers = workspace.parliamentMembers
        parliamentSessions = workspace.parliamentSessions
        sceneCertifications = workspace.sceneCertifications
        recentColors = workspace.recentColors
        discoveryChanges = workspace.discoveryChanges
        scheduleEngine.restore(workspace.scheduleState)
        sceneRevisions = workspace.sceneRevisions
        sceneDrafts = workspace.sceneDrafts
        lastActionSummary = workspace.lastActionSummary
        rehearsalSnapshot = workspace.rehearsalSnapshot
        rehearsalSceneID = workspace.rehearsalSceneID
        goveeSegmentStates = workspace.goveeSegmentStates
        goveeSegmentPresets = workspace.goveeSegmentPresets
        lifxMatrixStates = workspace.lifxMatrixStates
        musicModeConfiguration = workspace.musicModeConfiguration
        fixtureTopologies = workspace.fixtureTopologies
        customNames = workspace.customNames
        favoriteRoomIDs = workspace.favoriteRoomIDs
        favoriteSceneIDs = workspace.favoriteSceneIDs
        customBrightnessPresets = workspace.customBrightnessPresets
        sunriseHour = workspace.sunriseHour
        sunriseMinute = workspace.sunriseMinute
        sunsetHour = workspace.sunsetHour
        sunsetMinute = workspace.sunsetMinute
        undoStack = workspace.undoStack
        redoStack = workspace.redoStack
        lastChangeTime = workspace.lastChangeTime
        razerActiveIDs = workspace.razerActiveIDs
        scanStartingIDs = workspace.scanStartingIDs
        scanStartingAddresses = workspace.scanStartingAddresses
    }
}
