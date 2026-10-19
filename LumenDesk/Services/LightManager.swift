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
    static let maximumSchedulesPerRoom = 12

    @Published var devices: [LightDevice] = []
    @Published var rooms: [Room] = [] {
        // Room membership decides which lights a show's frames may reach.
        didSet { musicFixtureCache.removeAll() }
    }
    @Published var favoriteIDs: Set<String> = []
    @Published var scenes: [LightingScene] = []
    @Published var isScanning: Bool = false
    @Published var scanPhase: String = "Idle"
    @Published var lastScanDate: Date?
    @Published var scanResponseCount: Int = 0
    /// What the last LIFX and Govee discovery passes actually put on the wire.
    /// A scan that failed at the socket layer used to be indistinguishable from
    /// a scan that reached a healthy network with nothing on it.
    @Published var lifxProbe: DiscoveryProbeReport?
    @Published var goveeProbe: DiscoveryProbeReport?
    /// Interfaces the last scan went out on, sampled once when the scan starts.
    /// The diagnostics card renders on every state change, so reading
    /// `getifaddrs` from its body would mean a syscall per frame.
    @Published var scanInterfaces: [String] = []
    @Published var statusMessage: String = ""
    @Published var commandError: String?
    @Published var commandErrorUndo: (() -> Void)?  // optional undo action on the error toast
    @Published var canUndo: Bool = false
    @Published var canRedo: Bool = false
    var collapsedRooms: Set<UUID> = []
    // Holds the last deleted room and its position for undo.
    var lastDeletedRoom: (room: Room, index: Int)? = nil
    var lastDeletedScene: (scene: LightingScene, index: Int)? = nil
    var stalenessGeneration: Int = 0
    var newlyDiscoveredIDs: Set<String> = []
    var whiteModeDeviceIDs: Set<String> = []
    var napPhase: NapPhase = .inactive
    @Published var activeEffects: [LightScope: String] = [:]
    var activityEvents: [ActivityEvent] = []
    var lastSceneResult: SceneApplicationResult?
    /// Fixtures whose observed state changed without a LumenDesk command in
    /// flight. Direction A keeps this fact in the room instead of quietly
    /// replacing the user's intent or hiding another controller's action.
    @Published var externallyChangedDeviceIDs: Set<String> = []
    var favoriteOrder: [FavoriteReference] = []
    @Published var recentColors: [RecentColor] = []
    var discoveryChanges: [DiscoveryChange] = []
    var sceneRevisions: [SceneRevision] = []
    var sceneDrafts: [UUID: LightingScene] = [:]
    @Published var lastActionSummary: String?
    @Published var rehearsalSceneID: UUID?
    // Per-device Govee segment layouts (COB strips, string lights, neon ropes)
    // and reusable multi-color paint jobs, both persisted across sessions.
    @Published var goveeSegmentStates: [String: GoveeSegmentState] = [:]
    @Published var goveeSegmentPresets: [GoveeSegmentPreset] = []
    @Published var lifxMatrixStates: [String: LIFXMatrixState] = [:]
    @Published var musicModeConfiguration = MusicModeConfiguration.configuration(for: .soundcheck)
    @Published var fixtureTopologies: [String: FixtureTopology] = [:] {
        didSet { musicFixtureCache.removeAll() }
    }

    let musicModeController: AudioReactiveSessionController

    var errorClearTask: Task<Void, Never>?
    var lifx: LIFXClient?
    var govee: GoveeClient?
    let nanoleaf: NanoleafClient
    /// Shapes arrangements, orientation, per-panel designs and live output.
    /// Views that draw a wall observe it directly, so a streamed frame never
    /// republishes the whole manager.
    let shapes: NanoleafShapesController
    /// Shapes walls a running show feeds panel by panel, keyed by device ID.
    var shapesStreams: [String: ShapesStream] = [:]
    @Published var nanoleafCandidates: [NanoleafCandidate] = []
    @Published var nanoleafDiscoveryError: String?
    var refreshTimer: Timer?
    var scheduleTimer: Timer?
    var napTimer: Timer?
    var brightnessTasks: [String: Task<Void, Never>] = [:]
    var deferredPersistenceTask: Task<Void, Never>?
    var napSnapshotBrightness: [String: Double] = [:]
    var scanGeneration: Int = 0     // incremented each scan; clears isScanning safely
    var hasStarted = false
    var hasStartedBackgroundServices = false
    var scanStartingIDs: Set<String> = []
    var scanStartingAddresses: [String: String] = [:]
    var devicesByID: [String: LightDevice] = [:]
    let demoWorkspaceController: DemoWorkspaceController
    let confirmationCoordinator: ConfirmationCoordinator
    let scheduleEngine: ScheduleEngine
    let persistenceStore: ApplicationPersistence
    let commandCoordinator: CommandCoordinator
    let changeClock: () -> Date
    let identifyDurationNanoseconds: UInt64
    let identifySleep: CommandCoordinator.Sleep
    var rehearsalSnapshot: [LightRuntimeSnapshot] = []

    struct Identification {
        let token: UUID
        let snapshot: LightRuntimeSnapshot
        var task: Task<Void, Never>?
    }
    var identifications: [String: Identification] = [:]

    /// State saved before a held identify, so the fixture can be put back
    /// exactly as it was however the question ends. Lives here rather than
    /// beside `beginSustainedIdentify` because that sits in an extension, and
    /// an extension may not hold stored properties.
    struct IdentifyHold {
        let snapshot: LightRuntimeSnapshot
        var task: Task<Void, Never>?
    }

    var identifyHold: IdentifyHold?

    /// One show's per-panel stream to a Shapes wall. Segment `i` of the show's
    /// fixture is `panelIDs[i]`, fixed when the show starts. Where each panel
    /// sits comes separately, from the wall's layout and orientation, so
    /// re-orienting the wall re-aims the show without renumbering its panels.
    struct ShapesStream {
        let owner: String
        let panelIDs: [Int]
    }

    var isHoldingIdentify: Bool { identifyHold != nil }
    // Devices with a live razer overlay, including both editor previews and
    // applied layouts that must be held through the stream.
    var razerActiveIDs: Set<String> = []
    // The subset currently owned by an open Segment Studio preview. Refresh
    // keepalives must not overwrite these frames with the last applied layout.
    var segmentPreviewIDs: Set<String> = []

    // Custom display names keyed by device id, persisted across sessions.
    var customNames: [String: String] = [:]

    @Published var favoriteRoomIDs: Set<UUID> = []
    @Published var favoriteSceneIDs: Set<UUID> = []
    @Published var customBrightnessPresets: [Double] = []

    // Configurable sunrise/sunset times (hour and minute).
    @Published var sunriseHour: Int   = 6
    @Published var sunriseMinute: Int = 30
    @Published var sunsetHour: Int    = 20
    @Published var sunsetMinute: Int  = 30

    // MARK: - Undo / redo state
    /// One animated effect running against one scope. Several runs can be
    /// active at once as long as their device sets don't overlap (e.g. a
    /// different effect per room).
    final class EffectRun {
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
        // The actual devices this run powers, animates, and will restore on
        // stop. Ordinarily every device in `scope`, but Music Mode can leave
        // user-excluded fixtures out, so ownership can no longer be derived
        // by re-querying `devices(in: scope)` — it has to be this stored set.
        let animatedDeviceIDs: Set<String>
        let orderedDeviceIDs: [String]
        // Lights another app took over mid-run: a Shapes wall switched to a
        // scene chosen in the Nanoleaf app. The run stops driving them, gives
        // their controls back, and never "restores" them over that choice.
        var releasedDeviceIDs: Set<String> = []
        var ownedDeviceIDs: Set<String> { animatedDeviceIDs.subtracting(releasedDeviceIDs) }
        /// Names this run's claim on a Shapes wall: its kind, scope and run,
        /// so a finished run can never end or feed a newer run's stream.
        var streamOwner: String {
            let kind = effect.id == "music-pulse" ? "music" : "effect"
            let place: String
            switch scope {
            case .all: place = "all"
            case .room(let roomID): place = "room:\(roomID.uuidString.lowercased())"
            }
            return "\(kind):\(place):\(id.uuidString.prefix(8))"
        }
        init(effect: LightingEffect, scope: LightScope, snapshot: [LightRuntimeSnapshot], restorePreviousState: Bool = true, reducedMotion: Bool = false) {
            self.effect = effect
            self.scope = scope
            self.snapshot = snapshot
            self.restorePreviousState = restorePreviousState
            self.reducedMotion = reducedMotion
            let deviceIDs = snapshot.map(\.deviceID)
            self.orderedDeviceIDs = deviceIDs
            self.animatedDeviceIDs = Set(deviceIDs)
        }
    }
    var effectRuns: [LightScope: EffectRun] = [:]
    let musicLightingRenderer = MusicLightingRenderer()
    var musicModelUpdateAt: [String: TimeInterval] = [:]
    /// Descriptors a running show renders through. Building them walks segment
    /// profiles and Shapes geometry, which is too much to repeat for every
    /// 20 Hz frame. Room and topology edits clear it outright; a one-second
    /// lifetime bounds how long anything rarer (a wall reporting a new layout)
    /// takes to reach output.
    struct MusicFixtureCache {
        let runID: UUID
        let builtAt: TimeInterval
        let fixtures: [MusicFixtureDescriptor]
    }
    var musicFixtureCache: [LightScope: MusicFixtureCache] = [:]
    /// Reduce Motion as the system reports it. Read and observed here rather
    /// than passed in by whichever view started a show, so a show started from
    /// a favorite, a scene card or Demo Mode honors it, and a change reaches
    /// running shows whatever screen is open.
    var reducesMotion = false
    var reduceMotionObserver: NSObjectProtocol?
    var undoStack: [[LightRuntimeSnapshot]] = []
    var redoStack: [[LightRuntimeSnapshot]] = []
    var lastChangeTime: [String: Date] = [:]
    let undoLimit = 20
    let coalesceWindow: TimeInterval = 1.0

    // MARK: - Init

    init(
        defaults: UserDefaults = .standard,
        demoWorkspaceController: DemoWorkspaceController? = nil,
        confirmationCoordinator: ConfirmationCoordinator? = nil,
        scheduleEngine: ScheduleEngine? = nil,
        persistenceStore: ApplicationPersistence? = nil,
        commandCoordinator: CommandCoordinator? = nil,
        musicModeController: AudioReactiveSessionController? = nil,
        nanoleafClient: NanoleafClient? = nil,
        changeClock: @escaping () -> Date = Date.init,
        identifyDurationNanoseconds: UInt64 = 2_000_000_000,
        identifySleep: @escaping CommandCoordinator.Sleep = { try await Task.sleep(nanoseconds: $0) }
    ) {
        let nanoleaf = nanoleafClient ?? NanoleafClient()
        self.nanoleaf = nanoleaf
        self.shapes = NanoleafShapesController(client: nanoleaf)
        self.demoWorkspaceController = demoWorkspaceController ?? DemoWorkspaceController()
        self.confirmationCoordinator = confirmationCoordinator ?? ConfirmationCoordinator(defaults: defaults)
        self.scheduleEngine = scheduleEngine ?? ScheduleEngine()
        self.persistenceStore = persistenceStore ?? PersistenceStore.live(legacyDefaults: defaults)
        self.commandCoordinator = commandCoordinator ?? CommandCoordinator()
        self.changeClock = changeClock
        self.identifyDurationNanoseconds = identifyDurationNanoseconds
        self.identifySleep = identifySleep
        self.musicModeController = musicModeController ?? AudioReactiveSessionController()
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
        shapes.restore(Self.shapesSnapshot(from: persistedState))
        configureNanoleaf()
        self.commandCoordinator.onChange = { [weak self] in
            self?.objectWillChange.send()
        }
        reducesMotion = LightManager.systemReducesMotion
        observeSystemReduceMotion()
    }

    var isDemoMode: Bool { demoWorkspaceController.isActive }
    var automationOverrides: [UUID: RoomAutomationOverride] { scheduleEngine.automationOverrides }
    var missedAutomations: [MissedAutomation] { scheduleEngine.missedAutomations }
    var commandPendingIDs: Set<String> { commandCoordinator.pendingDeviceIDs }
    var commandStates: [String: DeviceCommandState] { commandCoordinator.commandStates }
    var confirmedStates: [String: ConfirmedDeviceState] { commandCoordinator.confirmedStates }

    var scheduleSolarTimes: ScheduleEngine.SolarTimes {
        ScheduleEngine.SolarTimes(
            sunriseMinutes: min(23, max(0, sunriseHour)) * 60 + min(59, max(0, sunriseMinute)),
            sunsetMinutes: min(23, max(0, sunsetHour)) * 60 + min(59, max(0, sunsetMinute))
        )
    }

    func start(discover: Bool = true) {
        // A first-run demo still evaluates schedules and refreshes simulated
        // fixtures, but must not initialize live discovery sockets.
        if isDemoMode {
            startBackgroundServices()
            return
        }
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
        if discover { scan() }
        startBackgroundServices()
        logActivity(.system, title: "LumenDesk started", detail: "Foreground discovery and room reconciliation are active.")
    }

    func startBackgroundServices() {
        guard !hasStartedBackgroundServices else { return }
        hasStartedBackgroundServices = true
        scheduleRefresh()
        // Direction A is deliberately foreground-only. Existing schedule data
        // remains in backups for lossless migration, but no in-app scheduler
        // is started and no command can run while the app is absent.
    }

    func scan() {
        if isDemoMode {
            isScanning = true
            scanPhase = "Scanning simulated lights"
            lastScanDate = Date()
            scanResponseCount = 0
            lifxProbe = nil
            goveeProbe = nil
            scanInterfaces = []
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
        logActivity(.scan, title: "Discovery scan started", detail: "Broadcasting and probing every host on the local subnet for LIFX, Govee, and Nanoleaf Shapes or Aurora devices.")
        isScanning = true
        discoveryChanges = []
        scanStartingIDs = Set(devices.map(\.id))
        scanStartingAddresses = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.address) })
        scanPhase = "Probing the local network"
        lastScanDate = Date()
        scanResponseCount = 0
        lifxProbe = nil
        goveeProbe = nil
        scanInterfaces = LocalSubnet.interfaces().map(\.description)
        lifx?.discover()
        govee?.discover()
        nanoleafDiscoveryError = nil
        nanoleaf.discover()
        scanGeneration += 1
        let gen = scanGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            Task { @MainActor in
                guard let self, self.scanGeneration == gen else { return }
                self.scanPhase = "Querying bulb state"
            }
        }
        // Discovery sends several spaced broadcast rounds and then two paced
        // unicast sweeps with an ARP-warming gap between them, so the last
        // probe does not leave the machine until roughly a second and a half
        // in. Closing the window at three seconds declared "no responses"
        // while the scan was still going out.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scanWindow) { [weak self] in
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

    /// How long a scan stays open before it reports what it found. Covers the
    /// paced sweeps, the ARP warm-up gap, and a bulb's reply latency.
    static let scanWindow: TimeInterval = 5

    func scheduleRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
        refreshTimer?.tolerance = 3
    }

    func startScheduleTimer() {
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

    func checkSchedules() {
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
                applyScheduleAction(entry.action, to: devices(in: room))
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
        applyScheduleAction(missed.entry.action, to: devices(in: room))
        if scheduleEngine.removeMissedAutomation(id: missed.id) { objectWillChange.send() }
    }

    func skipMissedAutomation(_ missed: MissedAutomation) {
        if scheduleEngine.removeMissedAutomation(id: missed.id) { objectWillChange.send() }
    }

    func refreshAll() {
        guard demoWorkspaceController.allowsLiveNetworking else { return }
        let now = Date()
        for d in devices {
            if now.timeIntervalSince(d.lastSeen) > 75, !d.isStale {
                d.isStale = true
                stalenessGeneration += 1  // triggers manager @Published, re-renders rooms
            }
            switch d.brand {
            case .nanoleaf: nanoleaf.refresh(d.backendID)
            case .lifx:  lifx?.refresh(macHex: d.backendID)
            case .govee:
                govee?.refresh(deviceID: d.backendID)
                // Doubles as a flicker-free stream keepalive: re-push the
                // current frame without resetting razer mode. Known power-on,
                // address changes, and stale recovery re-enable the mode.
                reassertStreamHoldIfNeeded(d)
            }
        }
    }

    func markSeen(_ device: LightDevice, confirmsPendingCommand: Bool = false) {
        let wasStale = device.isStale
        device.lastSeen = Date()
        device.isStale = false
        let rgb = device.color.rgbComponents
        let hex = String(format: "#%02X%02X%02X", Int(rgb.r * 255), Int(rgb.g * 255), Int(rgb.b * 255))
        let observed = ConfirmedDeviceState(
            isOn: device.isOn,
            brightness: device.brightness,
            colorHex: hex,
            kelvin: device.kelvin,
            nanoleafAppearance: device.nanoleafAppearance,
            confirmedAt: Date()
        )
        if !confirmsPendingCommand,
           !commandPendingIDs.contains(device.id),
           !isEffectAnimating(device.id),
           let previous = confirmedStates[device.id],
           Self.materiallyDiffers(previous, observed) {
            externallyChangedDeviceIDs.insert(device.id)
        }
        commandCoordinator.recordObservation(
            deviceID: device.id,
            confirmedState: observed,
            confirmsPendingCommand: confirmsPendingCommand
        )
        if wasStale {
            appendDiscoveryChange(device, kind: .backOnline, detail: "Responded again")
            // A light that dropped off and came back likely power-cycled,
            // which clears the razer overlay stream-hold layouts live in.
            reassertStreamHoldIfNeeded(device, forceModeEnable: true)
        }
    }

    static func materiallyDiffers(
        _ lhs: ConfirmedDeviceState,
        _ rhs: ConfirmedDeviceState
    ) -> Bool {
        lhs.isOn != rhs.isOn
            || abs(lhs.brightness - rhs.brightness) > 0.03
            || lhs.colorHex != rhs.colorHex
            || abs(lhs.kelvin - rhs.kelvin) > 100
            || lhs.nanoleafAppearance != rhs.nanoleafAppearance
    }

    func acknowledgeExternalChange(deviceIDs: Set<String>) {
        externallyChangedDeviceIDs.subtract(deviceIDs)
    }

    func reportedStateMatchesExpectation(
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

    func expectPower(_ device: LightDevice, on: Bool) {
        guard demoWorkspaceController.allowsLiveNetworking else { return }
        commandCoordinator.expectPower(deviceID: device.id, isOn: on)
    }

    func expectBrightness(_ device: LightDevice, value: Double) {
        guard demoWorkspaceController.allowsLiveNetworking else { return }
        commandCoordinator.expectBrightness(deviceID: device.id, brightness: value)
    }

    func expectColor(_ device: LightDevice, color: Color) {
        guard demoWorkspaceController.allowsLiveNetworking else { return }
        // Record what the light will actually report, not what the user picked.
        // A LIFX bulb carries brightness in its own HSBK field, so `sendColor`
        // deliberately drops the picked color's brightness component and
        // `lifxDidUpdate` rebuilds the reported color at full brightness.
        // Comparing the raw picked color against that reconstruction missed by
        // more than the tolerance for anything below full value, so the command
        // never confirmed and timed out with a false "did not confirm" error.
        let rgb = (device.brand != .govee ? color.lifxReportedEquivalent : color).rgbComponents
        commandCoordinator.expectColor(deviceID: device.id, red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    func expectKelvin(_ device: LightDevice, kelvin: Int) {
        guard demoWorkspaceController.allowsLiveNetworking else { return }
        commandCoordinator.expectKelvin(deviceID: device.id, kelvin: kelvin)
    }

    func refresh(_ device: LightDevice) {
        guard demoWorkspaceController.allowsLiveNetworking else { return }
        switch device.brand {
        case .nanoleaf: nanoleaf.refresh(device.backendID)
        case .lifx: lifx?.refresh(macHex: device.backendID)
        case .govee: govee?.refresh(deviceID: device.backendID)
        }
    }

    func appendDiscoveryChange(_ device: LightDevice, kind: DiscoveryChange.Kind, detail: String) {
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
        sunriseHour = min(23, max(0, hour)); sunriseMinute = min(59, max(0, minute)); persistApplicationState()
    }
    func setSunsetTime(hour: Int, minute: Int) {
        sunsetHour = min(23, max(0, hour)); sunsetMinute = min(59, max(0, minute)); persistApplicationState()
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

    func announceAction(_ title: String, lights: [LightDevice]) {
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

    func scheduleErrorClear() {
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

    func enqueueCommand(for device: LightDevice, coalescingKey: String, summary: String, debounce: TimeInterval = 0.08, operation: @escaping @MainActor () -> Void) {
        externallyChangedDeviceIDs.remove(device.id)
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
    }

    func setBrightness(_ device: LightDevice, value: Double) {
        recordChange([device])
        let value = boundedBrightness(value)
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

    func performSetPower(in room: Room, on: Bool) {
        let lights = devices(in: room)
        guard !lights.isEmpty else { return }
        let staleCount = lights.filter { $0.isStale }.count
        if staleCount > 0 {
            publishError("\(staleCount) light\(staleCount == 1 ? "" : "s") in \u{201C}\(room.name)\u{201D} may be offline.")
        }
        stopEffects(touching: Set(lights.map(\.id)))
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
        stopEffects(touching: Set(lights.map(\.id)))
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

    func performSetAllPower(on: Bool) {
        let staleCount = devices.filter { $0.isStale }.count
        if staleCount > 0 {
            publishError("\(staleCount) light\(staleCount == 1 ? "" : "s") may be offline.")
        }
        stopEffects(touching: Set(devices.map(\.id)))
        recordChange(devices)
        announceAction("All lights turned \(on ? "on" : "off")", lights: devices)
        for d in devices { d.isOn = on; sendPower(d, on: on) }
    }

    func setAllBrightness(_ value: Double) {
        guard !devices.isEmpty else {
            publishError("No lights are available to control.")
            return
        }
        stopEffects(touching: Set(devices.map(\.id)))
        recordChange(devices)
        let clamped = min(1, max(0, value))
        for d in devices { previewBrightness(d, value: clamped) }
    }

    func setPower(deviceIDs: Set<String>, on: Bool) {
        let lights = devices.filter { deviceIDs.contains($0.id) }
        guard !lights.isEmpty else { return }
        stopEffects(touching: deviceIDs)
        recordChange(lights)
        announceAction("Turned \(on ? "on" : "off")", lights: lights)
        for d in lights { d.isOn = on; sendPower(d, on: on) }
    }

    func setBrightness(deviceIDs: Set<String>, value: Double) {
        let lights = devices.filter { deviceIDs.contains($0.id) }
        guard !lights.isEmpty else { return }
        stopEffects(touching: deviceIDs)
        recordChange(lights)
        let clamped = min(1, max(0, value))
        for d in lights { previewBrightness(d, value: clamped) }
    }

    /// One undo entry for a deliberate multi-fixture color edit.
    func setColor(deviceIDs: Set<String>, color: Color) {
        let lights = devices.filter { deviceIDs.contains($0.id) }
        guard !lights.isEmpty else { return }
        stopEffects(touching: deviceIDs)
        recordChange(lights)
        rememberColor(color, name: "Custom")
        for light in lights {
            setWhiteMode(light.id, white: false)
            light.color = color
            sendColor(light, color: color)
        }
    }

    func setKelvin(deviceIDs: Set<String>, kelvin: Int) {
        let lights = devices.filter { deviceIDs.contains($0.id) }
        guard !lights.isEmpty else { return }
        stopEffects(touching: deviceIDs)
        recordChange(lights)
        for light in lights {
            setWhiteMode(light.id, white: true)
            light.kelvin = min(9000, max(2500, kelvin))
            sendColorTemperature(light, kelvin: light.kelvin)
        }
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

    func applyTheme(
        _ theme: LightingTheme,
        scope: LightScope = .all,
        spatialField: SpatialFieldVector = .themeDefault
    ) {
        let targets = devices(in: scope)
        guard !targets.isEmpty else {
            publishError(scope == .all
                         ? "Discover a light before applying a theme."
                         : "No lights in “\(scopeDisplayName(scope))” to theme.")
            return
        }
        applyTheme(
            theme,
            to: targets,
            in: scope,
            spatialField: spatialField,
            suffix: scope == .all ? "" : " in “\(scopeDisplayName(scope))”"
        )
    }

    /// Palette distribution follows room order and respects an explicit selection.
    func applyTheme(
        _ theme: LightingTheme,
        deviceIDs: Set<String>,
        in scope: LightScope,
        spatialField: SpatialFieldVector = .themeDefault
    ) {
        let targets = devices(in: scope).filter { deviceIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        applyTheme(theme, to: targets, in: scope, spatialField: spatialField, suffix: "")
    }

    func applyTheme(
        _ theme: LightingTheme,
        to targets: [LightDevice],
        in scope: LightScope = .all,
        spatialField: SpatialFieldVector = .themeDefault,
        suffix: String
    ) {
        stopEffects(touching: Set(targets.map(\.id)))
        // The plan sets each light's brightness; a slider send still in flight
        // would land after it and override the theme.
        cancelPendingBrightness(deviceIDs: Set(targets.map(\.id)))
        recordChange(targets)

        let fixtures = targets.map { themeFixture($0, in: scope) }
        let plan = ThemePlanner.plan(theme, fixtures: fixtures, spatialField: spatialField)
        let plansByID = Dictionary(plan.fixtures.map { ($0.fixtureID, $0) },
                                   uniquingKeysWith: { first, _ in first })
        for device in targets {
            guard let fixturePlan = plansByID[device.id] else { continue }
            applyThemePlan(fixturePlan, to: device)
        }

        var message = "Applied “\(theme.name)” to \(targets.count) light\(targets.count == 1 ? "" : "s")\(suffix)."
        if let adaptation = plan.adaptationSummary { message += " \(adaptation)" }
        lastActionSummary = message
        logActivity(.command, title: "Theme applied",
                    detail: "\(theme.name): \(targets.count) lights, \(theme.distribution.displayName.lowercased())")
    }

    /// What the planner needs to know about a light: what it can address, the
    /// white point to fall back on, and — for a fixture that can only run some
    /// of its zones — which zones the user already has lit.
    func themeFixture(_ device: LightDevice, in scope: LightScope = .all) -> ThemeFixture {
        let resolvedRoom: Room? = {
            if case .room(let roomID) = scope {
                return rooms.first(where: { $0.id == roomID }) ?? room(forLightID: device.id)
            }
            return room(forLightID: device.id)
        }()
        return ThemeFixture(
            id: device.id,
            capability: themeCapability(for: device),
            kelvin: device.kelvin,
            preferredZones: activeSegmentState(for: device.id)?.poweredSegments ?? [],
            anchor: resolvedRoom.map { planAnchor(for: device.id, in: $0) }
        )
    }

    /// Capability comes from what discovery reported, never from a guess. A
    /// Govee model the segment catalog doesn't recognize is planned as a plain
    /// emitter rather than being sent segment packets its firmware would drop.
    func themeCapability(for device: LightDevice) -> ThemeFixtureCapability {
        if device.isLIFXLuna, let matrix = lifxMatrixStates[device.id] {
            return .matrix(productID: matrix.productID, width: matrix.width, height: matrix.height)
        }
        if device.brand == .govee, let profile = segmentProfile(for: device), profile.recognized {
            // `segmentState(for:)` is the one place that knows how many
            // segments a fixture really has: it repairs a saved count that a
            // fixed-topology profile contradicts, which happens when the layout
            // was stored before the SKU was recognized or came in from another
            // setup's archive. Reading the raw stored count here would plan a
            // 15-entry layout for a three-zone lamp and misreport its zones.
            return .segments(count: segmentState(for: device).segmentCount,
                             gradient: profile.supportsGradient,
                             simultaneousZoneLimit: profile.simultaneousZoneLimit)
        }
        // A Shapes wall is planned panel by panel only once its controller
        // has reported a layout; before that it takes one colour, like a bulb.
        if device.brand == .nanoleaf, let layout = shapes.layout(device.id), !layout.paintablePanels.isEmpty {
            return .panels(count: layout.paintablePanels.count)
        }
        return .solid
    }

    /// Sends one fixture's share of a theme down whichever path its hardware
    /// understands. Undo was recorded once for the whole batch and the toast is
    /// published once at the end, so every call here stays quiet.
    func applyThemePlan(
        _ plan: ThemeFixturePlan,
        to device: LightDevice,
        transitionDuration: TimeInterval = 1.8
    ) {
        device.isOn = true
        device.kelvin = plan.kelvin
        sendPower(device, on: true)

        if let matrix = plan.matrix, device.isLIFXLuna {
            // Matrix zones carry their own brightness, so the fixture-level
            // value is bookkeeping for the UI rather than a second command.
            device.brightness = plan.brightness
            device.color = plan.tone.displayColor
            applyLIFXMatrix(device, state: matrix, recordUndo: false, turnOn: false,
                            announce: false, transitionDuration: transitionDuration)
            return
        }

        if let segments = plan.segments, device.brand == .govee {
            applySegments(device, state: segments, recordUndo: false, turnOn: false, announce: false)
            device.brightness = plan.brightness
            sendBrightness(device, value: plan.brightness)
            return
        }

        if let tones = plan.panels, device.brand == .nanoleaf, let layout = shapes.layout(device.id) {
            // Tones land left to right along the wall as the user oriented
            // it. Each tone's level is its panel's intensity; the theme's
            // brightness is the controller's master brightness, once.
            let design = NanoleafDesignBuilder.design(
                tones: tones.map { (hue: $0.hue, saturation: $0.saturation, level: $0.level) },
                layout: layout, rotationDegrees: Double(shapes.displayOrientation(device.id)))
            device.brightness = plan.brightness
            showShapesDesign(design, on: device,
                             transition: max(1, Int((transitionDuration * 10).rounded())))
            sendBrightness(device, value: plan.brightness)
            return
        }

        // Chroma at full value plus an explicit brightness, the same shape
        // scene restore uses. Sending the authored hex instead lands
        // differently on each brand: LIFX ignores how dark it was, and Govee
        // dims by it once in the RGB and again in the brightness command.
        let color = plan.tone.displayColor
        device.brightness = plan.brightness
        device.color = color
        sendColor(device, color: color, transitionDuration: transitionDuration)
        if device.brand == .govee { sendBrightness(device, value: plan.brightness) }
    }

    func startEffect(_ effect: LightingEffect, scope: LightScope = .all) {
        if effect.id == "music-pulse" || effect.style == .musicPulse {
            // A favorite or scene card starts the same show as the Music
            // screen: the saved configuration, under the system Reduce Motion.
            startMusicMode(configuration: musicModeConfiguration, scope: scope)
            return
        }
        let targets = devices(in: scope)
        guard !targets.isEmpty else {
            publishError(scope == .all
                         ? "Discover a light before starting an effect."
                         : "No lights in “\(scopeDisplayName(scope))” to animate.")
            return
        }
        cancelIdentifications(deviceIDs: Set(targets.map(\.id)), restore: true)
        // Inherit snapshots from any run these lights are leaving, so stopping
        // the new run later restores the true pre-effect state rather than a
        // mid-effect frame.
        let inherited = stopEffects(touching: Set(targets.map(\.id)))
        // Frames carry brightness from here on; a slider send still in flight
        // would land under the first frames and, on Govee, dim them twice.
        cancelPendingBrightness(deviceIDs: Set(targets.map(\.id)))
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
            beginShapesShow(device, owner: run.streamOwner, perPanel: true)
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
        reducedMotion: Bool = false,
        capture: MusicCapturePreference = .platformDefault
    ) {
        guard let effect = LightingCatalog.effects.first(where: { $0.id == "music-pulse" }) else { return }
        let topology = fixtureTopology(for: scope)
        let fixtures = musicFixtureDescriptors(in: scope)
        let skipped = topology.excludedFixtureIDs.union(
            Set(fixtures.filter { $0.resolvedRole == .off }.map(\.id))
        )
        let targets = devices(in: scope).filter { !skipped.contains($0.id) }
        guard !targets.isEmpty else {
            publishError(scope == .all
                ? "Discover a light before starting Music Mode."
                : "No included lights in “\(scopeDisplayName(scope))” for Music Mode.")
            return
        }

        // The system setting applies whoever starts the show; a caller can
        // only add restraint, never lift it.
        let motionReduced = reducedMotion || reducesMotion
        let normalized = configuration.normalized(reducedMotion: motionReduced)
        guard (isDemoMode && normalized.usesSyntheticDemoPattern)
                || musicModeController.canStartCapture(capture, replacing: scope) else {
            publishError("Music Mode shares one audio source across rooms. Stop the other shows before selecting a different source.")
            return
        }
        cancelIdentifications(deviceIDs: Set(targets.map(\.id)), restore: true)
        let inherited = stopEffects(touching: Set(targets.map(\.id)))
        // Frames carry brightness from here on; a slider send still in flight
        // would land under the show and, on Govee, dim every frame twice.
        cancelPendingBrightness(deviceIDs: Set(targets.map(\.id)))
        let startingSnapshot = targets.map { inherited[$0.id] ?? snapshot($0) }
        recordChange(targets)
        let run = EffectRun(
            effect: effect,
            scope: scope,
            snapshot: startingSnapshot,
            restorePreviousState: normalized.restorePreviousState,
            reducedMotion: motionReduced
        )
        effectRuns[scope] = run
        activeEffects[scope] = effect.id

        let streamedWalls = Set(fixtures.filter { $0.transport == .nanoleafStream }.map(\.id))
        for device in targets {
            device.isOn = true
            sendPower(device, on: true)
            if device.brand == .govee, segmentProfile(for: device) == nil {
                // Ordinary Govee LAN color packets fold brightness into RGB.
                // Opening device brightness once avoids a second write per frame.
                markSegmentsInactive(device)
                sendBrightness(device, value: 1)
            }
            beginShapesShow(device, owner: run.streamOwner, perPanel: streamedWalls.contains(device.id))
        }

        musicModeController.start(
            scope: scope,
            configuration: normalized,
            topology: topology,
            fixtures: fixtures,
            reducedMotion: motionReduced,
            useSyntheticPattern: isDemoMode && normalized.usesSyntheticDemoPattern,
            capture: capture,
            onFrame: { [weak self, weak run] frame in
                guard let self, let run, self.effectRuns[scope] === run else { return }
                self.renderMusicFrame(frame, scope: scope)
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
                    // Failed startup is a rollback even when the user asked
                    // to keep the final look after a successful show.
                    self.stopEffect(scope: scope, restore: false)
                    self.restoreDeviceStates(run.snapshot)
                    self.publishError(self.musicModeFailureMessage(for: result, capture: capture))
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
        let restores = restore && run.restorePreviousState
        endShapesStreams(ownedBy: run.streamOwner, keepingLastFrame: !restores)
        if restores { restoreDeviceStates(run.snapshot) }
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
    func stopEffects(touching deviceIDs: Set<String>) -> [String: LightRuntimeSnapshot] {
        var inherited: [String: LightRuntimeSnapshot] = [:]
        for (scope, run) in effectRuns {
            let runIDs = run.ownedDeviceIDs
            guard !runIDs.isDisjoint(with: deviceIDs) else { continue }
            run.timer?.invalidate()
            if run.effect.id == "music-pulse" {
                musicModeController.stop(scope: scope)
                finishMusicStreaming(for: runIDs)
            }
            effectRuns[scope] = nil
            activeEffects[scope] = nil
            endShapesStreams(ownedBy: run.streamOwner, keepingLastFrame: false)
            for snap in run.snapshot where deviceIDs.contains(snap.deviceID) {
                inherited[snap.deviceID] = snap
            }
            restoreDeviceStates(run.snapshot.filter { !deviceIDs.contains($0.deviceID) })
        }
        return inherited
    }

    /// User-facing message when Music Mode can't start its audio source.
    /// macOS uses system audio (Screen Recording); iOS uses the microphone.
    func musicModeFailureMessage(for result: AudioCaptureService.AudioStartResult, capture: MusicCapturePreference) -> String {
        switch capture {
        case .file:
            return "Music Mode couldn't open or play that audio file. Choose an accessible, supported audio file and try again."
        case .midiClock:
            return "Music Mode couldn't connect to a MIDI source. Connect your MIDI device or enable a MIDI clock output, then try again."
        case .platformDefault:
            break
        }
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
    func isEffectAnimating(_ deviceID: String) -> Bool {
        effectRuns.values.contains { $0.ownedDeviceIDs.contains(deviceID) }
    }

    /// The running effect that owns this light, if one does.
    ///
    /// While a run owns a fixture it repaints colour and brightness on every
    /// frame, so a value set on that light's own instruments is overwritten
    /// within one frame interval. The row uses this to disable those controls
    /// and point at the running show, rather than accept a change and quietly
    /// lose it.
    func animatingEffect(for deviceID: String) -> (scope: LightScope, name: String)? {
        guard let match = effectRuns.first(where: { $0.value.ownedDeviceIDs.contains(deviceID) })
        else { return nil }
        return (match.key, match.value.effect.name)
    }

    func runEffectFrame(_ run: EffectRun) {
        guard effectRuns[run.scope] === run, !run.effect.colors.isEmpty else { return }
        run.phase += run.effect.speed
        let effect = run.effect
        let effectPhase = run.phase
        // A show's ownership is fixed at startup. Room edits must not add
        // fixtures with no baseline or steal them from another running show.
        let targets = run.orderedDeviceIDs.compactMap { device(withID: $0) }
        run.modelUpdateElapsed += effect.frameInterval
        let shouldUpdateModel = run.modelUpdateElapsed >= 0.25
        if shouldUpdateModel { run.modelUpdateElapsed = 0 }

        for (index, device) in targets.enumerated() {
            // A light another app took over mid-run keeps its slot, so the
            // rest of the room animates exactly as before, but gets nothing.
            guard run.ownedDeviceIDs.contains(device.id) else { continue }
            let (color, clampedBrightness) = effectSample(effect, phase: effectPhase, slot: Double(index),
                                                          paletteIndex: index, count: targets.count)
            if shouldUpdateModel {
                if device.color.rgbDistance(to: color) > 0.005 { device.color = color }
                if abs(device.brightness - clampedBrightness) > 0.005 { device.brightness = clampedBrightness }
            }
            if let stream = shapesStreams[device.id], !shapes.streamFailed(device.id, owner: stream.owner) {
                streamEffectFrame(effect, phase: effectPhase, index: index, count: targets.count,
                                  to: device, stream: stream)
            } else {
                sendEffectFrame(device, color: color, brightness: clampedBrightness,
                                duration: effect.frameInterval)
            }
        }
    }

    func renderEffectNowForTesting(scope: LightScope) {
        guard let run = effectRuns[scope] else { return }
        runEffectFrame(run)
    }

    /// One light's colour and level in an effect frame. `slot` is the light's
    /// place in the scope; a Shapes panel adds where it sits along the wall,
    /// 0 to 1, so an effect moves across the panels instead of flashing the
    /// wall as one bulb. Whole lights pass their index for both arguments,
    /// which is exactly the sampling every light had before panels existed.
    func effectSample(_ effect: LightingEffect, phase effectPhase: Double, slot: Double,
                              paletteIndex index: Int, count: Int) -> (Color, Double) {
        let palette = effect.colors
        var color = palette[(index + Int(effectPhase)) % palette.count].color
        var brightness = 0.72

        switch effect.style {
        case .colorFlow:
            let hue = (effectPhase * 0.08 + slot / Double(max(1, count))).truncatingRemainder(dividingBy: 1)
            color = Color(hue: hue, saturation: 0.86, brightness: 1)
            brightness = 0.78
        case .oceanWave:
            let wave = (sin(effectPhase + slot * 0.85) + 1) / 2
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
            let wave = (sin(effectPhase + slot * 0.75) + 1) / 2
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
        return (color, max(0.05, min(1, brightness)))
    }

    /// An effect frame for a Shapes wall, panel by panel, placed left to
    /// right as the user oriented the wall. Each panel's level is folded
    /// into its colour; master brightness was opened to full when the show
    /// began, so the level is applied once.
    func streamEffectFrame(_ effect: LightingEffect, phase: Double, index: Int, count: Int,
                                   to device: LightDevice, stream: ShapesStream) {
        guard let layout = shapes.layout(device.id) else { return }
        let placed = layout.spatialPositions(rotationDegrees: Double(shapes.displayOrientation(device.id)),
                                             axis: .leftToRight)
        let transition = max(1, min(10, Int((effect.frameInterval * 10).rounded())))
        let frames = placed.enumerated().map { ordinal, entry -> NanoleafPanelFrame in
            let (color, level) = effectSample(effect, phase: phase, slot: Double(index) + entry.position,
                                              paletteIndex: index + ordinal, count: count)
            let hsb = color.hsbComponents
            return NanoleafPanelFrame(panelID: entry.panelID,
                                      rgb: NanoleafPanelColor(hue: hsb.h, saturation: hsb.s, intensity: level).rgb,
                                      transition: transition)
        }
        shapes.submit(frames, to: device.id, owner: stream.owner)
    }

    /// Effect frames are transient and never receive command acknowledgements.
    /// Sending them through the normal confirmation pipeline used to allocate
    /// three Tasks and publish several whole-app changes per light, per frame.
    func sendEffectFrame(_ device: LightDevice, color: Color, brightness: Double,
                                 duration: TimeInterval, musicTimestamp: TimeInterval? = nil) {
        guard demoWorkspaceController.allowsLiveNetworking else { return }
        switch device.brand {
        case .nanoleaf:
            let hsb = color.hsbComponents
            device.nanoleafAppearance = .init(colorMode: "hs")
            nanoleaf.setState(device.backendID,
                              NanoleafProtocol.color(hue: hsb.h, saturation: hsb.s, brightness: brightness),
                              transient: true)
        case .lifx:
            markLIFXMatrixInactive(device)
            let hsb = color.hsbComponents
            lifx?.setColor(
                macHex: device.backendID,
                color: LIFXHSBK(
                    hue: UInt16(hsb.h * 65535),
                    saturation: UInt16(hsb.s * 65535),
                    brightness: UInt16(boundedBrightness(brightness) * 65535),
                    kelvin: UInt16(min(9000, max(1200, device.kelvin)))
                ),
                durationMS: UInt32(max(0, min(500, Int(duration * 1_000)))),
                musicTimestamp: musicTimestamp
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

    func restoreDeviceStates(_ states: [LightRuntimeSnapshot]) {
        cancelIdentifications(deviceIDs: Set(states.map(\.deviceID)), restore: false)
        for state in states {
            guard let device = device(withID: state.deviceID) else { continue }
            device.isOn = state.isOn
            device.brightness = state.brightness
            device.color = state.color
            device.kelvin = state.kelvin
            if restoreNanoleafOutput(design: state.nanoleafDesign, appearance: state.nanoleafAppearance, to: device) {
                // Designs, native saved effects and white mode survive a stopped show.
            } else if let matrix = state.matrix, device.isLIFXLuna {
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

    func sendPower(_ device: LightDevice, on: Bool) {
        if device.brand == .govee, !on {
            // Govee drops the volatile stream overlay when power turns off.
            // Forget the local mode flag so the next power-on enables it once.
            razerActiveIDs.remove(device.id)
        }
        expectPower(device, on: on)
        enqueueCommand(for: device, coalescingKey: "power", summary: on ? "Turning on" : "Turning off") { [weak self, weak device] in
            guard let self, let device else { return }
            switch device.brand {
            case .nanoleaf: self.nanoleaf.setState(device.backendID, ["on": ["value": on]])
            case .lifx: self.lifx?.setPower(macHex: device.backendID, on: on)
            case .govee:
                self.govee?.setPower(deviceID: device.backendID, on: on)
                if on {
                    // Queue the overlay after the power command. The Govee
                    // client preserves per-device order and spacing.
                    self.reassertStreamHoldIfNeeded(device)
                }
            }
        }
    }

    func sendBrightness(_ device: LightDevice, value: Double) {
        let value = boundedBrightness(value)
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
                    let lifxColor = LIFXHSBK(hue: UInt16(hsb.h * 65535), saturation: UInt16(hsb.s * 65535), brightness: UInt16(value * 65535), kelvin: UInt16(min(9000, max(1200, device.kelvin))))
                    self.lifx?.setColor(macHex: device.backendID, color: lifxColor)
                }
            case .nanoleaf:
                self.nanoleaf.setState(device.backendID, ["brightness": ["value": NanoleafProtocol.percent(value)]])
            case .govee:
                self.govee?.setBrightness(deviceID: device.backendID, percent: Int(value * 100))
                self.reassertStreamHoldIfNeeded(device)
            }
        }
    }

    func sendColor(
        _ device: LightDevice,
        color: Color,
        debounce: TimeInterval = 0.08,
        transitionDuration: TimeInterval = 0.2
    ) {
        if device.brand == .govee,
           let profile = segmentProfile(for: device),
           profile.limitsSimultaneousZones,
           var active = activeSegmentState(for: device.id) {
            let targets = active.poweredSegments.isEmpty ? Array(active.colors.indices) : active.poweredSegments
            for index in targets where active.colors.indices.contains(index) {
                let existing = active.colors[index]
                active.colors[index] = GoveeSegmentColor(
                    color: color,
                    brightness: existing.brightness,
                    isOn: existing.isOn
                )
            }
            active = profile.enforcingZoneLimit(active)
            active.isActive = true
            goveeSegmentStates[device.id] = active
            persistApplicationState()
            device.color = active.blendedColor
            noteSegmentCommand(device, summary: "Changing lamp zone color")
            if demoWorkspaceController.allowsLiveNetworking {
                assertStreamHold(device, state: active)
            }
            return
        }
        if device.brand == .lifx { markLIFXMatrixInactive(device) }
        expectColor(device, color: color)
        expectNanoleafAppearance(device, appearance: .init(colorMode: "hs"))
        simulateShapesOutput(device, .solid)
        enqueueCommand(for: device, coalescingKey: "color", summary: "Changing color", debounce: debounce) { [weak self, weak device] in
            guard let self, let device else { return }
            switch device.brand {
            case .lifx:
                let hsb = color.hsbComponents
                let lifxColor = LIFXHSBK(hue: UInt16(hsb.h * 65535), saturation: UInt16(hsb.s * 65535), brightness: UInt16(self.boundedBrightness(device.brightness) * 65535), kelvin: UInt16(min(9000, max(1200, device.kelvin))))
                self.lifx?.setColor(
                    macHex: device.backendID,
                    color: lifxColor,
                    durationMS: UInt32(max(0, min(60_000, Int(transitionDuration * 1_000))))
                )
            case .nanoleaf:
                let hsb = color.hsbComponents
                self.shapes.outputReplaced(device.id, by: .solid)
                self.nanoleaf.setState(device.backendID, NanoleafProtocol.color(hue: hsb.h, saturation: hsb.s, brightness: device.brightness))
            case .govee:
                self.markSegmentsInactive(device)
                let rgb = color.rgbComponents
                self.govee?.setColor(deviceID: device.backendID, r: Int(rgb.r * 255), g: Int(rgb.g * 255), b: Int(rgb.b * 255), kelvin: 0)
            }
        }
    }

    func sendColorTemperature(_ device: LightDevice, kelvin: Int) {
        let kelvin = device.brand == .nanoleaf ? NanoleafProtocol.kelvin(kelvin) : min(9000, max(1200, kelvin))
        device.kelvin = kelvin
        expectNanoleafAppearance(device, appearance: .init(colorMode: "ct"))
        simulateShapesOutput(device, .white)
        if device.brand == .lifx { markLIFXMatrixInactive(device) }
        expectKelvin(device, kelvin: kelvin)
        enqueueCommand(for: device, coalescingKey: device.brand == .nanoleaf ? "color" : "kelvin", summary: "Color temperature \(kelvin) kelvin") { [weak self, weak device] in
            guard let self, let device else { return }
            switch device.brand {
            case .lifx:
                let hsb = device.color.hsbComponents
                self.lifx?.setColor(macHex: device.backendID, color: LIFXHSBK(hue: UInt16(hsb.h * 65535), saturation: 0, brightness: UInt16(self.boundedBrightness(device.brightness) * 65535), kelvin: UInt16(kelvin)))
            case .nanoleaf:
                self.shapes.outputReplaced(device.id, by: .white)
                self.nanoleaf.setState(device.backendID, ["ct": ["value": kelvin], "brightness": ["value": NanoleafProtocol.percent(device.brightness)]])
            case .govee:
                self.markSegmentsInactive(device)
                self.govee?.setColor(deviceID: device.backendID, r: 255, g: 255, b: 255, kelvin: kelvin)
            }
        }
    }

    // MARK: - Undo / redo

    func snapshot(_ device: LightDevice) -> LightRuntimeSnapshot {
        LightRuntimeSnapshot(deviceID: device.id, isOn: device.isOn,
                    brightness: device.brightness, color: device.color, kelvin: device.kelvin,
                    segments: activeSegmentState(for: device.id),
                    matrix: activeLIFXMatrixState(for: device.id),
                    nanoleafAppearance: device.nanoleafAppearance,
                    nanoleafDesign: device.brand == .nanoleaf ? shapes.showingDesign(for: device.id) : nil)
    }

    func recomputeCanUndo() {
        canUndo = !undoStack.isEmpty || lastDeletedScene != nil || lastDeletedRoom != nil
    }

    func recordChange(_ devices: [LightDevice]) {
        guard !devices.isEmpty else { return }
        cancelIdentifications(deviceIDs: Set(devices.map(\.id)), restore: true)
        let now = changeClock()
        redoStack.removeAll()
        canRedo = false
        if let last = undoStack.last,
           last.count == devices.count,
           Set(last.map { $0.deviceID }) == Set(devices.map { $0.id }),
           devices.allSatisfy({ now.timeIntervalSince(lastChangeTime[$0.id] ?? .distantPast) < coalesceWindow }) {
            for d in devices { lastChangeTime[d.id] = now }
            return
        }
        undoStack.append(devices.map { snapshot($0) })
        if undoStack.count > undoLimit { undoStack.removeFirst() }
        recomputeCanUndo()
        for d in devices { lastChangeTime[d.id] = now }
    }

    func undo() {
        if commandErrorUndo != nil {
            if lastDeletedScene != nil {
                undoDeleteScene()
                return
            }
            if lastDeletedRoom != nil {
                undoDeleteRoom()
                return
            }
        }
        if let entry = undoStack.popLast() {
            let current = entry.compactMap { snap -> LightRuntimeSnapshot? in
                guard let d = device(withID: snap.deviceID) else { return nil }
                return snapshot(d)
            }
            redoStack.append(current)
            apply(entry)
            lastChangeTime = [:]
            recomputeCanUndo()
            canRedo = !redoStack.isEmpty
            return
        }
        if lastDeletedScene != nil {
            undoDeleteScene()
            return
        }
        if lastDeletedRoom != nil {
            undoDeleteRoom()
            return
        }
    }

    func redo() {
        guard let entry = redoStack.popLast() else { return }
        let current = entry.compactMap { snap -> LightRuntimeSnapshot? in
            guard let d = device(withID: snap.deviceID) else { return nil }
            return snapshot(d)
        }
        undoStack.append(current)
        apply(entry)
        lastChangeTime = [:]
        recomputeCanUndo()
        canRedo = !redoStack.isEmpty
    }

    func apply(_ entry: [LightRuntimeSnapshot]) {
        let ids = Set(entry.map(\.deviceID))
        cancelIdentifications(deviceIDs: ids, restore: false)
        stopEffects(touching: ids)
        cancelPendingBrightness(deviceIDs: ids)
        for snap in entry {
            guard let d = device(withID: snap.deviceID) else { continue }
            d.isOn = snap.isOn
            d.brightness = snap.brightness
            d.color = snap.color
            d.kelvin = snap.kelvin
            if restoreNanoleafOutput(design: snap.nanoleafDesign, appearance: snap.nanoleafAppearance, to: d) {
                // Restored the wall's design or controller mode.
            } else if let matrix = snap.matrix, d.isLIFXLuna {
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

    func boundedBrightness(_ value: Double) -> Double {
        value.isFinite ? max(0, min(1, value)) : 0
    }

    func upsert(_ device: LightDevice) {
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

    func sortDevices() {
        devices.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    func device(withID id: String) -> LightDevice? {
        devicesByID[id]
    }
}
