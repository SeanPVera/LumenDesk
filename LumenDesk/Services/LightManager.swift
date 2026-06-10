import Foundation
import SwiftUI
import AppKit

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
    @Published private(set) var commandPendingIDs: Set<String> = []
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
    @Published private(set) var activeEffectID: String?

    private var errorClearTask: Task<Void, Never>?
    private var lifx: LIFXClient?
    private var govee: GoveeClient?
    private var refreshTimer: Timer?
    private var scheduleTimer: Timer?
    private var napTimer: Timer?
    private var napSnapshotBrightness: [String: Double] = [:]
    private var scanGeneration: Int = 0     // incremented each scan; clears isScanning safely
    private var hasStarted = false
    private var lastScheduleCheck: Date?

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

    // Tracks which schedule entries already fired in the current clock-minute
    // to prevent double-firing when timer drift straddles two ticks.
    private var scheduleFiredThisMinute: [UUID: String] = [:]  // entryID → "HH:MM"

    private let roomsDefaultsKey        = "LumenDesk.rooms.v1"
    private let favoritesDefaultsKey    = "LumenDesk.favorites.v1"
    private let scenesDefaultsKey       = "LumenDesk.scenes.v1"
    private let customNamesDefaultsKey  = "LumenDesk.customNames.v1"
    private let collapsedRoomsKey       = "LumenDesk.collapsedRooms.v1"
    private let solarKey                = "LumenDesk.solar.v1"
    private let whiteModeKey            = "LumenDesk.whiteMode.v1"
    fileprivate let roomFavoritesDefaultsKey = "LumenDesk.favoriteRooms.v1"
    fileprivate let sceneFavoritesDefaultsKey = "LumenDesk.favoriteScenes.v1"
    fileprivate let brightnessPresetsKey    = "LumenDesk.brightnessPresets.v1"

    // MARK: - Undo / redo state

    private struct DeviceState {
        let deviceID: String
        let isOn: Bool
        let brightness: Double
        let color: Color
        let kelvin: Int
    }
    private var effectTimer: Timer?
    private var effectSnapshot: [DeviceState] = []
    private var effectPhase: Double = 0
    private var audioLevel: Double = 0
    private let audioLevelMonitor = AudioLevelMonitor()
    private var undoStack: [[DeviceState]] = []
    private var redoStack: [[DeviceState]] = []
    private var lastChangeTime: [String: Date] = [:]
    private let undoLimit = 20
    private let coalesceWindow: TimeInterval = 1.0

    // MARK: - Init

    init() {
        rooms = loadRooms()
        favoriteIDs = loadFavorites()
        scenes = loadScenes()
        customNames = loadCustomNames()
        collapsedRooms = loadCollapsedRooms()
        favoriteRoomIDs = loadUUIDSet(forKey: roomFavoritesDefaultsKey)
        favoriteSceneIDs = loadUUIDSet(forKey: sceneFavoritesDefaultsKey)
        customBrightnessPresets = loadBrightnessPresets()
        whiteModeDeviceIDs = loadWhiteMode()
        loadSolarPrefs()
    }

    func start() {
        guard !hasStarted else {
            scan()
            return
        }
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
    }

    func scan() {
        isScanning = true
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
            }
        }
    }

    private func scheduleRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
    }

    private func startScheduleTimer() {
        scheduleTimer?.invalidate()
        let seconds = Calendar.current.component(.second, from: Date())
        let delay = TimeInterval(max(1, 60 - seconds))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.checkSchedules()
                self.scheduleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.checkSchedules() }
                }
            }
        }
    }

    private func checkSchedules() {
        let now = Date()
        let previous = lastScheduleCheck ?? now.addingTimeInterval(-75)
        lastScheduleCheck = now
        let cal = Calendar.current
        let nowHour   = cal.component(.hour, from: now)
        let nowMinute = cal.component(.minute, from: now)
        let nowKey    = String(format: "%02d:%02d", nowHour, nowMinute)

        for room in rooms {
            for entry in room.schedules where entry.isEnabled {
                if scheduleFiredThisMinute[entry.id] == nowKey { continue }
                guard schedule(entry, shouldFireBetween: previous, and: now) else { continue }

                scheduleFiredThisMinute[entry.id] = nowKey
                let lights = devices(in: room)
                switch entry.action {
                case .turnOn, .atSunrise:
                    for d in lights { d.isOn = true; markPending(d.id); sendPower(d, on: true) }
                case .turnOff, .atSunset:
                    for d in lights { d.isOn = false; markPending(d.id); sendPower(d, on: false) }
                default:
                    if let brightness = entry.action.brightnessValue {
                        for d in lights { d.brightness = brightness; markPending(d.id); sendBrightness(d, value: brightness) }
                    }
                }
            }
        }
        scheduleFiredThisMinute = scheduleFiredThisMinute.filter { $0.value == nowKey }
    }

    private func schedule(_ entry: ScheduleEntry, shouldFireBetween previous: Date, and now: Date) -> Bool {
        guard let target = scheduledOccurrenceToday(for: entry, relativeTo: now) else { return false }
        return target > previous && target <= now
    }

    fileprivate func scheduledOccurrenceToday(for entry: ScheduleEntry, relativeTo date: Date) -> Date? {
        let cal = Calendar.current
        let totalMinutes: Int
        switch entry.action {
        case .atSunrise:
            totalMinutes = max(0, min(1439, sunriseHour * 60 + sunriseMinute + entry.offsetMinutes))
        case .atSunset:
            totalMinutes = max(0, min(1439, sunsetHour * 60 + sunsetMinute + entry.offsetMinutes))
        default:
            totalMinutes = max(0, min(1439, entry.hour * 60 + entry.minute))
        }
        return cal.date(byAdding: .minute, value: totalMinutes, to: cal.startOfDay(for: date))
    }

    private func refreshAll() {
        let now = Date()
        for d in devices {
            if now.timeIntervalSince(d.lastSeen) > 75, !d.isStale {
                d.isStale = true
                stalenessGeneration += 1  // triggers manager @Published, re-renders rooms
            }
            switch d.brand {
            case .lifx:  lifx?.refresh(macHex: d.backendID)
            case .govee: govee?.refresh(deviceID: d.backendID)
            }
        }
    }

    private func markSeen(_ device: LightDevice) {
        device.lastSeen = Date()
        device.isStale = false
        commandPendingIDs.remove(device.id)
    }

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
        persistCustomNames()
    }

    fileprivate func persistCustomNames() {
        if let data = try? JSONEncoder().encode(customNames) {
            UserDefaults.standard.set(data, forKey: customNamesDefaultsKey)
        }
    }

    private func loadCustomNames() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: customNamesDefaultsKey),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    // MARK: - Solar preferences

    func setSunriseTime(hour: Int, minute: Int) {
        sunriseHour = hour; sunriseMinute = minute; persistSolarPrefs()
    }
    func setSunsetTime(hour: Int, minute: Int) {
        sunsetHour = hour; sunsetMinute = minute; persistSolarPrefs()
    }

    fileprivate func persistSolarPrefs() {
        let d: [String: Int] = [
            "sunriseHour": sunriseHour, "sunriseMinute": sunriseMinute,
            "sunsetHour": sunsetHour,   "sunsetMinute": sunsetMinute
        ]
        UserDefaults.standard.set(d, forKey: solarKey)
    }

    private func loadSolarPrefs() {
        guard let d = UserDefaults.standard.dictionary(forKey: solarKey) else { return }
        sunriseHour   = d["sunriseHour"]   as? Int ?? 6
        sunriseMinute = d["sunriseMinute"] as? Int ?? 30
        sunsetHour    = d["sunsetHour"]    as? Int ?? 20
        sunsetMinute  = d["sunsetMinute"]  as? Int ?? 30
    }

    // MARK: - Room expansion state

    func toggleRoomExpansion(_ roomID: UUID) {
        if collapsedRooms.contains(roomID) {
            collapsedRooms.remove(roomID)
        } else {
            collapsedRooms.insert(roomID)
        }
        persistCollapsedRooms()
    }

    func isRoomExpanded(_ roomID: UUID) -> Bool { !collapsedRooms.contains(roomID) }

    fileprivate func persistCollapsedRooms() {
        if let data = try? JSONEncoder().encode(Array(collapsedRooms)) {
            UserDefaults.standard.set(data, forKey: collapsedRoomsKey)
        }
    }

    private func loadCollapsedRooms() -> Set<UUID> {
        guard let data = UserDefaults.standard.data(forKey: collapsedRoomsKey),
              let arr = try? JSONDecoder().decode([UUID].self, from: data) else { return [] }
        return Set(arr)
    }

    // MARK: - Error / toast

    func publishError(_ message: String, undo: (() -> Void)? = nil) {
        commandError = message
        commandErrorUndo = undo
        errorClearTask?.cancel()
        errorClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled {
                self.commandError = nil
                self.commandErrorUndo = nil
            }
        }
    }

    // MARK: - Command pending state

    fileprivate func markPending(_ deviceID: String) {
        commandPendingIDs.insert(deviceID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            Task { @MainActor in self?.commandPendingIDs.remove(deviceID) }
        }
    }

    // MARK: - Control

    func setPower(_ device: LightDevice, on: Bool) {
        if device.isStale {
            publishError("\u{201C}\(device.label)\u{201D} may be offline — command sent anyway.")
        }
        recordChange([device])
        device.isOn = on
        markPending(device.id)
        sendPower(device, on: on)
    }

    func setBrightness(_ device: LightDevice, value: Double) {
        recordChange([device])
        device.brightness = value
        markPending(device.id)
        sendBrightness(device, value: value)
    }

    func setColor(_ device: LightDevice, color: Color) {
        if device.isStale {
            publishError("\u{201C}\(device.label)\u{201D} may be offline — command sent anyway.")
        }
        recordChange([device])
        device.color = color
        markPending(device.id)
        sendColor(device, color: color)
    }

    func setKelvin(_ device: LightDevice, kelvin: Int) {
        recordChange([device])
        device.kelvin = kelvin
        markPending(device.id)
        sendColorTemperature(device, kelvin: kelvin)
    }

    // MARK: - Room & global bulk controls

    func setPower(in room: Room, on: Bool) {
        let lights = devices(in: room)
        let staleCount = lights.filter { $0.isStale }.count
        if staleCount > 0 {
            publishError("\(staleCount) light\(staleCount == 1 ? "" : "s") in \u{201C}\(room.name)\u{201D} may be offline.")
        }
        recordChange(lights)
        for d in lights { d.isOn = on; markPending(d.id); sendPower(d, on: on) }
    }

    func setBrightness(in room: Room, value: Double) {
        let lights = devices(in: room)
        recordChange(lights)
        for d in lights { d.brightness = value; markPending(d.id); sendBrightness(d, value: value) }
    }

    func setAllPower(on: Bool) {
        let staleCount = devices.filter { $0.isStale }.count
        if staleCount > 0 {
            publishError("\(staleCount) light\(staleCount == 1 ? "" : "s") may be offline.")
        }
        recordChange(devices)
        for d in devices { d.isOn = on; markPending(d.id); sendPower(d, on: on) }
    }

    func setAllBrightness(_ value: Double) {
        recordChange(devices)
        for d in devices { d.brightness = value; markPending(d.id); sendBrightness(d, value: value) }
    }

    func setPower(deviceIDs: Set<String>, on: Bool) {
        let lights = devices.filter { deviceIDs.contains($0.id) }
        recordChange(lights)
        for d in lights { d.isOn = on; markPending(d.id); sendPower(d, on: on) }
    }

    func setBrightness(deviceIDs: Set<String>, value: Double) {
        let lights = devices.filter { deviceIDs.contains($0.id) }
        recordChange(lights)
        for d in lights { d.brightness = value; markPending(d.id); sendBrightness(d, value: value) }
    }

    // MARK: - Theme & effect catalog

    func applyTheme(_ theme: LightingTheme) {
        guard !devices.isEmpty else {
            publishError("Discover a light before applying a theme.")
            return
        }
        stopEffect(restore: false)
        recordChange(devices)
        for (index, device) in devices.enumerated() {
            let color = theme.colors[index % theme.colors.count].color
            device.isOn = true
            device.brightness = theme.brightness
            device.color = color
            markPending(device.id)
            sendPower(device, on: true)
            sendColor(device, color: color)
            if device.brand == .govee { sendBrightness(device, value: theme.brightness) }
        }
        publishError("Applied “\(theme.name)” to \(devices.count) light\(devices.count == 1 ? "" : "s").")
    }

    func startEffect(_ effect: LightingEffect) {
        guard !devices.isEmpty else {
            publishError("Discover a light before starting an effect.")
            return
        }
        let startingSnapshot = activeEffectID == nil ? devices.map(snapshot) : effectSnapshot
        stopEffect(restore: false)
        effectSnapshot = startingSnapshot
        recordChange(devices)
        activeEffectID = effect.id
        effectPhase = 0
        audioLevel = 0
        for device in devices {
            device.isOn = true
            markPending(device.id)
            sendPower(device, on: true)
        }

        let begin: () -> Void = { [weak self] in
            guard let self, self.activeEffectID == effect.id else { return }
            self.runEffectFrame(effect)
            self.effectTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.runEffectFrame(effect) }
            }
        }

        if effect.isAudioReactive {
            audioLevelMonitor.onLevel = { [weak self] level in self?.audioLevel = level }
            audioLevelMonitor.requestAccessAndStart { [weak self] started in
                guard let self else { return }
                if started {
                    begin()
                } else {
                    self.activeEffectID = nil
                    self.effectSnapshot = []
                    self.publishError("Soundcheck needs microphone access. Enable it in System Settings → Privacy & Security → Microphone.")
                }
            }
        } else {
            begin()
        }
    }

    func stopEffect(restore: Bool = true) {
        effectTimer?.invalidate()
        effectTimer = nil
        audioLevelMonitor.stop()
        audioLevelMonitor.onLevel = nil
        activeEffectID = nil
        guard restore, !effectSnapshot.isEmpty else {
            effectSnapshot = []
            return
        }
        restoreDeviceStates(effectSnapshot)
        effectSnapshot = []
    }

    private func runEffectFrame(_ effect: LightingEffect) {
        guard activeEffectID == effect.id, !effect.colors.isEmpty else { return }
        effectPhase += effect.speed
        let palette = effect.colors

        for (index, device) in devices.enumerated() {
            var color = palette[(index + Int(effectPhase)) % palette.count].color
            var brightness = 0.72

            switch effect.style {
            case .colorFlow:
                let hue = (effectPhase * 0.08 + Double(index) / Double(max(1, devices.count))).truncatingRemainder(dividingBy: 1)
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
            case .twinkle:
                let spark = Double.random(in: 0...1) > 0.78
                color = (spark ? palette[0] : palette[(index % max(1, palette.count - 1)) + 1]).color
                brightness = spark ? Double.random(in: 0.72...1) : Double.random(in: 0.16...0.34)
            case .musicPulse:
                color = palette[(index + Int(effectPhase * 4)) % palette.count].color
                brightness = 0.16 + pow(audioLevel, 0.62) * 0.84
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

            device.isOn = true
            device.color = color
            device.brightness = max(0.05, min(1, brightness))
            sendColor(device, color: color)
            if device.brand == .govee { sendBrightness(device, value: device.brightness) }
        }
    }

    private func restoreDeviceStates(_ states: [DeviceState]) {
        for state in states {
            guard let device = devices.first(where: { $0.id == state.deviceID }) else { continue }
            device.isOn = state.isOn
            device.brightness = state.brightness
            device.color = state.color
            device.kelvin = state.kelvin
            markPending(device.id)
            sendColor(device, color: state.color)
            if device.brand == .govee { sendBrightness(device, value: state.brightness) }
            sendPower(device, on: state.isOn)
        }
    }

    // MARK: - Vendor send helpers

    private func sendPower(_ device: LightDevice, on: Bool) {
        switch device.brand {
        case .lifx:  lifx?.setPower(macHex: device.backendID, on: on)
        case .govee: govee?.setPower(deviceID: device.backendID, on: on)
        }
    }

    private func sendBrightness(_ device: LightDevice, value: Double) {
        switch device.brand {
        case .lifx:
            let hsb = device.color.hsbComponents
            let lifxColor = LIFXHSBK(
                hue: UInt16(hsb.h * 65535),
                saturation: UInt16(hsb.s * 65535),
                brightness: UInt16(max(0, min(1, value)) * 65535),
                kelvin: UInt16(device.kelvin)
            )
            lifx?.setColor(macHex: device.backendID, color: lifxColor)
        case .govee:
            govee?.setBrightness(deviceID: device.backendID, percent: Int(value * 100))
        }
    }

    private func sendColor(_ device: LightDevice, color: Color) {
        switch device.brand {
        case .lifx:
            let hsb = color.hsbComponents
            let lifxColor = LIFXHSBK(
                hue: UInt16(hsb.h * 65535),
                saturation: UInt16(hsb.s * 65535),
                brightness: UInt16(device.brightness * 65535),
                kelvin: UInt16(device.kelvin)
            )
            lifx?.setColor(macHex: device.backendID, color: lifxColor)
        case .govee:
            let rgb = color.rgbComponents
            govee?.setColor(deviceID: device.backendID,
                            r: Int(rgb.r * 255), g: Int(rgb.g * 255), b: Int(rgb.b * 255),
                            kelvin: 0)
        }
    }

    private func sendColorTemperature(_ device: LightDevice, kelvin: Int) {
        switch device.brand {
        case .lifx:
            sendBrightness(device, value: device.brightness)
        case .govee:
            govee?.setColor(deviceID: device.backendID, r: 255, g: 255, b: 255, kelvin: kelvin)
        }
    }

    // MARK: - Undo / redo

    private func snapshot(_ device: LightDevice) -> DeviceState {
        DeviceState(deviceID: device.id, isOn: device.isOn,
                    brightness: device.brightness, color: device.color, kelvin: device.kelvin)
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
        let current = entry.compactMap { snap -> DeviceState? in
            guard let d = devices.first(where: { $0.id == snap.deviceID }) else { return nil }
            return snapshot(d)
        }
        redoStack.append(current)
        apply(entry)
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func redo() {
        guard let entry = redoStack.popLast() else { return }
        let current = entry.compactMap { snap -> DeviceState? in
            guard let d = devices.first(where: { $0.id == snap.deviceID }) else { return nil }
            return snapshot(d)
        }
        undoStack.append(current)
        apply(entry)
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func apply(_ entry: [DeviceState]) {
        for snap in entry {
            guard let d = devices.first(where: { $0.id == snap.deviceID }) else { continue }
            d.isOn = snap.isOn
            d.brightness = snap.brightness
            d.color = snap.color
            d.kelvin = snap.kelvin
            sendColor(d, color: snap.color)
            // Govee needs an explicit brightness call; LIFX brightness is embedded in setColor.
            if d.brand == .govee {
                govee?.setBrightness(deviceID: d.backendID, percent: Int(snap.brightness * 100))
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
            existing.name = device.name
            existing.address = device.address
            existing.customName = customNames[existing.id]
            markSeen(existing)
        } else {
            devices.append(device)
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
        devices.first { $0.id == id }
    }
}

// MARK: - LIFX delegate

extension LightManager: LIFXClientDelegate {
    nonisolated func lifxDiscovered(macHex: String, address: String) {
        Task { @MainActor in
            let id = "lifx:\(macHex)"
            if let existing = self.device(withID: id) {
                self.scanResponseCount += 1
                existing.address = address
                self.markSeen(existing)
            } else {
                let device = LightDevice(id: id, brand: .lifx, backendID: macHex,
                                         name: "LIFX \(macHex.suffix(6))", address: address)
                self.upsert(device)
            }
        }
    }

    nonisolated func lifxDidUpdate(macHex: String, label: String, color: LIFXHSBK, isOn: Bool) {
        Task { @MainActor in
            let id = "lifx:\(macHex)"
            guard let device = self.device(withID: id) else { return }
            if !label.isEmpty && label != device.name {
                device.name = label
                self.sortDevices()
            }
            device.isOn = isOn
            device.brightness = Double(color.brightness) / 65535.0
            device.kelvin = Int(color.kelvin)
            let h = Double(color.hue) / 65535.0
            let s = Double(color.saturation) / 65535.0
            device.color = Color(hue: h, saturation: s, brightness: 1.0)
            self.markSeen(device)
        }
    }

    nonisolated func lifxCommandFailed(_ error: Error) {
        Task { @MainActor in self.publishError("LIFX command failed: \(error)") }
    }
}

// MARK: - Govee delegate

extension LightManager: GoveeClientDelegate {
    nonisolated func goveeDiscovered(deviceID: String, address: String, sku: String?) {
        Task { @MainActor in
            let id = "govee:\(deviceID)"
            if let existing = self.device(withID: id) {
                self.scanResponseCount += 1
                existing.address = address
                self.markSeen(existing)
            } else {
                let suffix = deviceID.split(separator: ":").suffix(2).joined(separator: "")
                let display = sku.map { "\($0) \(suffix)" } ?? "Govee \(suffix)"
                let device = LightDevice(id: id, brand: .govee, backendID: deviceID,
                                         name: display, address: address)
                self.upsert(device)
            }
        }
    }

    nonisolated func goveeDidUpdate(deviceID: String, isOn: Bool, brightness: Int,
                                    r: Int, g: Int, b: Int, kelvin: Int) {
        Task { @MainActor in
            let id = "govee:\(deviceID)"
            guard let device = self.device(withID: id) else { return }
            device.isOn = isOn
            device.brightness = Double(brightness) / 100.0
            device.kelvin = kelvin > 0 ? kelvin : device.kelvin
            device.color = Color(red: Double(r) / 255.0,
                                 green: Double(g) / 255.0,
                                 blue: Double(b) / 255.0)
            self.markSeen(device)
        }
    }

    nonisolated func goveeCommandFailed(_ error: Error) {
        Task { @MainActor in self.publishError("Govee command failed: \(error)") }
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
        let index = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        return room.lightIDs.compactMap { index[$0] }
    }

    func createRoom(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        rooms.append(Room(name: trimmed))
        persistRooms()
    }

    func renameRoom(_ roomID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        rooms[idx].name = trimmed
        persistRooms()
    }

    func deleteRoom(_ roomID: UUID) {
        guard let idx = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        let deleted = rooms[idx]
        lastDeletedRoom = (room: deleted, index: idx)
        rooms.remove(at: idx)
        persistRooms()
        publishError("\u{201C}\(deleted.name)\u{201D} deleted.") {
            self.undoDeleteRoom()
        }
    }

    func undoDeleteRoom() {
        guard let (room, index) = lastDeletedRoom else { return }
        let insertAt = min(index, rooms.count)
        rooms.insert(room, at: insertAt)
        lastDeletedRoom = nil
        persistRooms()
        commandError = nil
        commandErrorUndo = nil
    }

    func moveRooms(from offsets: IndexSet, to destination: Int) {
        rooms.move(fromOffsets: offsets, toOffset: destination)
        persistRooms()
    }

    func moveRoom(_ roomID: UUID, by offset: Int) {
        guard let idx = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        let target = idx + offset
        guard rooms.indices.contains(target) else { return }
        rooms.swapAt(idx, target)
        persistRooms()
    }

    func assign(lightID: String, toRoom roomID: UUID?) {
        for i in rooms.indices { rooms[i].lightIDs.removeAll { $0 == lightID } }
        if let roomID, let idx = rooms.firstIndex(where: { $0.id == roomID }) {
            rooms[idx].lightIDs.append(lightID)
        }
        persistRooms()
    }

    func assign(lightIDs: Set<String>, toRoom roomID: UUID?) {
        for i in rooms.indices { rooms[i].lightIDs.removeAll { lightIDs.contains($0) } }
        if let roomID, let idx = rooms.firstIndex(where: { $0.id == roomID }) {
            let ordered = devices.map { $0.id }.filter { lightIDs.contains($0) }
            rooms[idx].lightIDs.append(contentsOf: ordered)
        }
        persistRooms()
    }

    func moveLight(_ lightID: String, in roomID: UUID, by offset: Int) {
        guard let r = rooms.firstIndex(where: { $0.id == roomID }),
              let l = rooms[r].lightIDs.firstIndex(of: lightID) else { return }
        let target = l + offset
        guard rooms[r].lightIDs.indices.contains(target) else { return }
        rooms[r].lightIDs.swapAt(l, target)
        persistRooms()
    }

    func room(forLightID lightID: String) -> Room? {
        rooms.first { $0.lightIDs.contains(lightID) }
    }

    struct ExportedConfiguration: Codable {
        var rooms: [Room]
        var favoriteIDs: [String]
        var favoriteRoomIDs: [UUID]
        var favoriteSceneIDs: [UUID]
        var scenes: [LightingScene]
        var customNames: [String: String]
        var collapsedRooms: [UUID]
        var sunriseHour: Int
        var sunriseMinute: Int
        var sunsetHour: Int
        var sunsetMinute: Int
        var brightnessPresets: [Double]
    }

    func exportRoomsData() -> Data? { exportConfigurationData() }

    func exportConfigurationData() -> Data? {
        let config = ExportedConfiguration(
            rooms: rooms,
            favoriteIDs: Array(favoriteIDs),
            favoriteRoomIDs: Array(favoriteRoomIDs),
            favoriteSceneIDs: Array(favoriteSceneIDs),
            scenes: scenes,
            customNames: customNames,
            collapsedRooms: Array(collapsedRooms),
            sunriseHour: sunriseHour,
            sunriseMinute: sunriseMinute,
            sunsetHour: sunsetHour,
            sunsetMinute: sunsetMinute,
            brightnessPresets: customBrightnessPresets
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(config)
    }

    @discardableResult
    func importRoomsData(_ data: Data) -> Bool {
        if let config = try? JSONDecoder().decode(ExportedConfiguration.self, from: data) {
            rooms = config.rooms
            favoriteIDs = Set(config.favoriteIDs)
            favoriteRoomIDs = Set(config.favoriteRoomIDs)
            favoriteSceneIDs = Set(config.favoriteSceneIDs)
            scenes = config.scenes
            customNames = config.customNames
            collapsedRooms = Set(config.collapsedRooms)
            sunriseHour = config.sunriseHour
            sunriseMinute = config.sunriseMinute
            sunsetHour = config.sunsetHour
            sunsetMinute = config.sunsetMinute
            customBrightnessPresets = sanitizedPresets(config.brightnessPresets)
            persistAllConfiguration()
            reportImportMatchStatus(roomCount: rooms.count)
            return true
        }
        guard let decoded = try? JSONDecoder().decode([Room].self, from: data) else {
            statusMessage = "Import failed — that file isn’t a valid LumenDesk configuration."
            return false
        }
        rooms = decoded
        persistRooms()
        reportImportMatchStatus(roomCount: decoded.count)
        return true
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

    private func persistAllConfiguration() {
        persistRooms()
        persistFavorites()
        persistScenes()
        persistCustomNames()
        persistCollapsedRooms()
        persistSolarPrefs()
        persistUUIDSet(favoriteRoomIDs, forKey: roomFavoritesDefaultsKey)
        persistUUIDSet(favoriteSceneIDs, forKey: sceneFavoritesDefaultsKey)
        persistBrightnessPresets()
        persistWhiteMode()
    }

    fileprivate func persistRooms() {
        guard let data = try? JSONEncoder().encode(rooms) else { return }
        UserDefaults.standard.set(data, forKey: roomsDefaultsKey)
    }

    private func loadRooms() -> [Room] {
        guard let data = UserDefaults.standard.data(forKey: roomsDefaultsKey),
              let decoded = try? JSONDecoder().decode([Room].self, from: data) else { return [] }
        return decoded
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
        persistFavorites()
    }

    var favoriteDevices: [LightDevice] {
        devices
            .filter { favoriteIDs.contains($0.id) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    fileprivate func persistFavorites() {
        if let data = try? JSONEncoder().encode(Array(favoriteIDs)) {
            UserDefaults.standard.set(data, forKey: favoritesDefaultsKey)
        }
    }

    fileprivate func loadFavorites() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: favoritesDefaultsKey),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(arr)
    }


    func isFavoriteRoom(_ roomID: UUID) -> Bool { favoriteRoomIDs.contains(roomID) }

    func toggleFavoriteRoom(_ roomID: UUID) {
        if favoriteRoomIDs.contains(roomID) { favoriteRoomIDs.remove(roomID) } else { favoriteRoomIDs.insert(roomID) }
        persistUUIDSet(favoriteRoomIDs, forKey: roomFavoritesDefaultsKey)
    }

    func isFavoriteScene(_ sceneID: UUID) -> Bool { favoriteSceneIDs.contains(sceneID) }

    func toggleFavoriteScene(_ sceneID: UUID) {
        if favoriteSceneIDs.contains(sceneID) { favoriteSceneIDs.remove(sceneID) } else { favoriteSceneIDs.insert(sceneID) }
        persistUUIDSet(favoriteSceneIDs, forKey: sceneFavoritesDefaultsKey)
    }

    var favoriteRooms: [Room] { rooms.filter { favoriteRoomIDs.contains($0.id) } }
    var favoriteScenes: [LightingScene] { scenes.filter { favoriteSceneIDs.contains($0.id) } }

    fileprivate func persistUUIDSet(_ values: Set<UUID>, forKey key: String) {
        if let data = try? JSONEncoder().encode(Array(values)) { UserDefaults.standard.set(data, forKey: key) }
    }

    fileprivate func loadUUIDSet(forKey key: String) -> Set<UUID> {
        guard let data = UserDefaults.standard.data(forKey: key),
              let arr = try? JSONDecoder().decode([UUID].self, from: data) else { return [] }
        return Set(arr)
    }

    func addBrightnessPreset(_ value: Double) {
        customBrightnessPresets = sanitizedPresets(customBrightnessPresets + [value])
        persistBrightnessPresets()
    }

    func deleteBrightnessPreset(_ value: Double) {
        customBrightnessPresets.removeAll { abs($0 - value) < 0.005 }
        persistBrightnessPresets()
    }

    fileprivate func sanitizedPresets(_ values: [Double]) -> [Double] {
        var seen: Set<Int> = []
        return values.map { max(0.01, min(1.0, $0)) }
            .sorted()
            .filter { value in
                let key = Int((value * 100).rounded())
                if seen.contains(key) { return false }
                seen.insert(key)
                return true
            }
    }

    fileprivate func persistBrightnessPresets() {
        if let data = try? JSONEncoder().encode(customBrightnessPresets) { UserDefaults.standard.set(data, forKey: brightnessPresetsKey) }
    }

    fileprivate func loadBrightnessPresets() -> [Double] {
        guard let data = UserDefaults.standard.data(forKey: brightnessPresetsKey),
              let decoded = try? JSONDecoder().decode([Double].self, from: data) else { return [] }
        return sanitizedPresets(decoded)
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
                kelvin: d.kelvin
            )
        }
        scenes.append(LightingScene(name: trimmed, snapshots: snapshots))
        persistScenes()
    }

    func applyScene(_ scene: LightingScene) {
        let affected = devices.filter { scene.snapshots[$0.id] != nil }
        guard !affected.isEmpty else {
            publishError("\u{201C}\(scene.name)\u{201D} has no lights in common with what\u{2019}s on the network.")
            return
        }
        recordChange(affected)
        var staleCount = 0
        for d in affected {
            guard let snap = scene.snapshots[d.id] else { continue }
            if d.isStale { staleCount += 1 }
            let color = Color(hue: snap.hue, saturation: snap.saturation, brightness: 1.0)
            d.color = color
            d.brightness = snap.brightness
            d.kelvin = snap.kelvin
            d.isOn = snap.isOn
            markPending(d.id)
            sendColor(d, color: color)
            if d.brand == .govee {
                govee?.setBrightness(deviceID: d.backendID, percent: Int(snap.brightness * 100))
            }
            sendPower(d, on: snap.isOn)
        }
        if staleCount > 0 {
            publishError("Applied \u{201C}\(scene.name)\u{201D} — \(staleCount) light\(staleCount == 1 ? "" : "s") may be offline.") { self.undo() }
        } else {
            publishError("Applied \u{201C}\(scene.name)\u{201D}.") { self.undo() }
        }
    }

    func deleteScene(_ sceneID: UUID) {
        guard let idx = scenes.firstIndex(where: { $0.id == sceneID }) else { return }
        let deleted = scenes[idx]
        lastDeletedScene = (scene: deleted, index: idx)
        scenes.remove(at: idx)
        favoriteSceneIDs.remove(sceneID)
        persistScenes()
        persistUUIDSet(favoriteSceneIDs, forKey: sceneFavoritesDefaultsKey)
        publishError("Scene “\(deleted.name)” deleted.") { self.undoDeleteScene() }
    }

    func undoDeleteScene() {
        guard let (scene, index) = lastDeletedScene else { return }
        scenes.insert(scene, at: min(index, scenes.count))
        lastDeletedScene = nil
        persistScenes()
        commandError = nil
        commandErrorUndo = nil
    }

    func renameScene(_ sceneID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = scenes.firstIndex(where: { $0.id == sceneID }) else { return }
        scenes[idx].name = trimmed
        persistScenes()
    }

    fileprivate func persistScenes() {
        if let data = try? JSONEncoder().encode(scenes) {
            UserDefaults.standard.set(data, forKey: scenesDefaultsKey)
        }
    }

    fileprivate func loadScenes() -> [LightingScene] {
        guard let data = UserDefaults.standard.data(forKey: scenesDefaultsKey),
              let decoded = try? JSONDecoder().decode([LightingScene].self, from: data) else { return [] }
        return decoded
    }
}

// MARK: - Schedules

extension LightManager {
    func schedules(for roomID: UUID) -> [ScheduleEntry] {
        rooms.first(where: { $0.id == roomID })?.schedules ?? []
    }

    func addSchedule(_ entry: ScheduleEntry, to roomID: UUID) {
        guard let idx = rooms.firstIndex(where: { $0.id == roomID }),
              rooms[idx].schedules.count < 4 else { return }
        rooms[idx].schedules.append(entry)
        // Sort by resolved clock-minute so the list is always chronological.
        rooms[idx].schedules.sort { lhs, rhs in
            scheduledMinute(lhs) < scheduledMinute(rhs)
        }
        persistRooms()
    }

    func deleteSchedule(_ entryID: UUID, from roomID: UUID) {
        guard let idx = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        rooms[idx].schedules.removeAll { $0.id == entryID }
        persistRooms()
    }

    func setScheduleEnabled(_ entryID: UUID, in roomID: UUID, enabled: Bool) {
        guard let rIdx = rooms.firstIndex(where: { $0.id == roomID }),
              let eIdx = rooms[rIdx].schedules.firstIndex(where: { $0.id == entryID }) else { return }
        rooms[rIdx].schedules[eIdx].isEnabled = enabled
        persistRooms()
    }

    var hasActiveSchedules: Bool {
        rooms.contains { room in room.schedules.contains { $0.isEnabled } }
    }

    func nextRunDescription(for entry: ScheduleEntry) -> String {
        guard let today = scheduledOccurrenceToday(for: entry, relativeTo: Date()) else { return "No next run" }
        let next = today > Date() ? today : Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
        return "Next runs \(next.formatted(.relative(presentation: .named))) at \(next.formatted(date: .omitted, time: .shortened))"
    }

    func conflictWarnings(for roomID: UUID) -> [String] {
        let entries = schedules(for: roomID).filter { $0.isEnabled }
        var warnings: [String] = []
        guard entries.count > 1 else { return [] }
        for i in 0..<(entries.count - 1) {
            for j in (i + 1)..<entries.count {
                let first = entries[i]
                let second = entries[j]
                if abs(scheduledMinute(first) - scheduledMinute(second)) <= 5 {
                    warnings.append("\(first.action.displayName) and \(second.action.displayName) are within 5 minutes.")
                }
            }
        }
        return warnings
    }

    fileprivate func scheduledMinute(_ entry: ScheduleEntry) -> Int {
        switch entry.action {
        case .atSunrise: return max(0, min(1439, sunriseHour * 60 + sunriseMinute + entry.offsetMinutes))
        case .atSunset: return max(0, min(1439, sunsetHour * 60 + sunsetMinute + entry.offsetMinutes))
        default: return max(0, min(1439, entry.hour * 60 + entry.minute))
        }
    }

    // Estimates are for the Northern Hemisphere. Southern Hemisphere users should set times manually.
    func applyEstimatedSolarTimes() {
        let month = Calendar.current.component(.month, from: Date())
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
        persistWhiteMode()
    }

    fileprivate func persistWhiteMode() {
        if let data = try? JSONEncoder().encode(Array(whiteModeDeviceIDs)) {
            UserDefaults.standard.set(data, forKey: whiteModeKey)
        }
    }

    private func loadWhiteMode() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: whiteModeKey),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(arr)
    }
}

// MARK: - Nap Mode

extension LightManager {
    func startNapMode() {
        guard napPhase == .inactive else { cancelNapMode(); return }
        napSnapshotBrightness = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.brightness) })
        napPhase = .dimming(endsAt: Date().addingTimeInterval(20 * 60))
        napTimer?.invalidate()
        napTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickNapMode() }
        }
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
                    if d.brand == .govee { govee?.setBrightness(deviceID: d.backendID, percent: 50) }
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
    var hsbComponents: (h: Double, s: Double, b: Double) {
        guard let ns = NSColor(self).usingColorSpace(.sRGB) else { return (0, 0, 1) }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (Double(h), Double(s), Double(b))
    }

    var rgbComponents: (r: Double, g: Double, b: Double) {
        guard let ns = NSColor(self).usingColorSpace(.sRGB) else { return (1, 1, 1) }
        var r: CGFloat = 0, g: CGFloat = 0, bb: CGFloat = 0, a: CGFloat = 0
        ns.getRed(&r, green: &g, blue: &bb, alpha: &a)
        return (Double(r), Double(g), Double(bb))
    }
}
