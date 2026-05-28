import Foundation
import SwiftUI
import AppKit

@MainActor
final class LightManager: ObservableObject {
    @Published private(set) var devices: [LightDevice] = []
    @Published private(set) var rooms: [Room] = []
    @Published private(set) var favoriteIDs: Set<String> = []
    @Published private(set) var scenes: [LightingScene] = []
    @Published private(set) var isScanning: Bool = false
    @Published var statusMessage: String = ""
    @Published var commandError: String?
    @Published var commandErrorUndo: (() -> Void)?  // optional undo action on the error toast
    @Published private(set) var canUndo: Bool = false
    @Published private(set) var canRedo: Bool = false
    @Published private(set) var collapsedRooms: Set<UUID> = []
    // Holds the last deleted room and its position for undo.
    @Published private(set) var lastDeletedRoom: (room: Room, index: Int)? = nil

    private var errorClearTask: Task<Void, Never>?
    private var lifx: LIFXClient?
    private var govee: GoveeClient?
    private var refreshTimer: Timer?
    private var scheduleTimer: Timer?
    private var scanGeneration: Int = 0     // incremented each scan; clears isScanning safely

    // Custom display names keyed by device id, persisted across sessions.
    private var customNames: [String: String] = [:]

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

    // MARK: - Undo / redo state

    private struct DeviceState {
        let deviceID: String
        let isOn: Bool
        let brightness: Double
        let color: Color
        let kelvin: Int
    }
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
        loadSolarPrefs()
    }

    func start() {
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
        lifx?.discover()
        govee?.discover()
        scanGeneration += 1
        let gen = scanGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.scanGeneration == gen else { return }
            self.isScanning = false
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
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSchedules() }
        }
    }

    private func checkSchedules() {
        let cal = Calendar.current
        let now = Date()
        let nowHour   = cal.component(.hour, from: now)
        let nowMinute = cal.component(.minute, from: now)
        let nowKey    = String(format: "%02d:%02d", nowHour, nowMinute)

        for room in rooms {
            for entry in room.schedules where entry.isEnabled {
                // Prevent double-fire when timer drift causes two ticks in the same minute.
                if scheduleFiredThisMinute[entry.id] == nowKey { continue }

                let (targetH, targetM): (Int, Int) = {
                    switch entry.action {
                    case .atSunrise:
                        let base = sunriseHour * 60 + sunriseMinute + entry.offsetMinutes
                        let clamped = max(0, min(1439, base))
                        return (clamped / 60, clamped % 60)
                    case .atSunset:
                        let base = sunsetHour * 60 + sunsetMinute + entry.offsetMinutes
                        let clamped = max(0, min(1439, base))
                        return (clamped / 60, clamped % 60)
                    default:
                        return (entry.hour, entry.minute)
                    }
                }()

                guard targetH == nowHour, targetM == nowMinute else { continue }

                scheduleFiredThisMinute[entry.id] = nowKey
                let lights = devices(in: room)
                switch entry.action {
                case .turnOn, .atSunrise:
                    for d in lights { d.isOn = true; sendPower(d, on: true) }
                case .turnOff, .atSunset:
                    for d in lights { d.isOn = false; sendPower(d, on: false) }
                default:
                    if let brightness = entry.action.brightnessValue {
                        for d in lights { d.brightness = brightness; sendBrightness(d, value: brightness) }
                    }
                }
            }
        }
        // Purge stale entries from a previous minute.
        scheduleFiredThisMinute = scheduleFiredThisMinute.filter { $0.value == nowKey }
    }

    private func refreshAll() {
        let now = Date()
        for d in devices {
            if now.timeIntervalSince(d.lastSeen) > 75 { d.isStale = true }
            switch d.brand {
            case .lifx:  lifx?.refresh(macHex: d.backendID)
            case .govee: govee?.refresh(deviceID: d.backendID)
            }
        }
    }

    private func markSeen(_ device: LightDevice) {
        device.lastSeen = Date()
        device.isStale = false
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

    private func persistCustomNames() {
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

    private func persistSolarPrefs() {
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

    private func persistCollapsedRooms() {
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
        device.brightness = value
        sendBrightness(device, value: value)
    }

    func setColor(_ device: LightDevice, color: Color) {
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
        sendBrightness(device, value: device.brightness)  // re-sends with new kelvin
    }

    // MARK: - Room & global bulk controls

    func setPower(in room: Room, on: Bool) {
        let lights = devices(in: room)
        let staleCount = lights.filter { $0.isStale }.count
        if staleCount > 0 {
            publishError("\(staleCount) light\(staleCount == 1 ? "" : "s") in \u{201C}\(room.name)\u{201D} may be offline.")
        }
        recordChange(lights)
        for d in lights { d.isOn = on; sendPower(d, on: on) }
    }

    func setBrightness(in room: Room, value: Double) {
        let lights = devices(in: room)
        recordChange(lights)
        for d in lights { d.brightness = value; sendBrightness(d, value: value) }
    }

    func setAllPower(on: Bool) {
        let staleCount = devices.filter { $0.isStale }.count
        if staleCount > 0 {
            publishError("\(staleCount) light\(staleCount == 1 ? "" : "s") may be offline.")
        }
        recordChange(devices)
        for d in devices { d.isOn = on; sendPower(d, on: on) }
    }

    func setAllBrightness(_ value: Double) {
        recordChange(devices)
        for d in devices { d.brightness = value; sendBrightness(d, value: value) }
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
                            kelvin: device.kelvin)
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
}

// MARK: - Govee delegate

extension LightManager: GoveeClientDelegate {
    nonisolated func goveeDiscovered(deviceID: String, address: String, sku: String?) {
        Task { @MainActor in
            let id = "govee:\(deviceID)"
            if let existing = self.device(withID: id) {
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

    func exportRoomsData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(rooms)
    }

    @discardableResult
    func importRoomsData(_ data: Data) -> Bool {
        guard let decoded = try? JSONDecoder().decode([Room].self, from: data) else {
            statusMessage = "Import failed — that file isn\u{2019}t a valid LumenDesk configuration."
            return false
        }
        rooms = decoded
        persistRooms()
        statusMessage = "Imported \(decoded.count) room\(decoded.count == 1 ? "" : "s")."
        return true
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
            sendColor(d, color: color)
            if d.brand == .govee {
                govee?.setBrightness(deviceID: d.backendID, percent: Int(snap.brightness * 100))
            }
            sendPower(d, on: snap.isOn)
        }
        if staleCount > 0 {
            publishError("Applied \u{201C}\(scene.name)\u{201D} — \(staleCount) light\(staleCount == 1 ? "" : "s") may be offline.")
        }
    }

    func deleteScene(_ sceneID: UUID) {
        scenes.removeAll { $0.id == sceneID }
        persistScenes()
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
        rooms[idx].schedules.sort { lhs, rhs in
            // Sun-relative entries sort by offset; absolute entries by time.
            if lhs.action.isRelativeToSun && rhs.action.isRelativeToSun {
                return lhs.offsetMinutes < rhs.offsetMinutes
            }
            if lhs.action.isRelativeToSun { return false }
            if rhs.action.isRelativeToSun { return true }
            return lhs.hour != rhs.hour ? lhs.hour < rhs.hour : lhs.minute < rhs.minute
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
