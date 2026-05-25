import Foundation
import SwiftUI
import AppKit

/// Owns the LIFX + Govee clients, holds the discovered devices, and serializes
/// UI updates onto the main actor. Control calls from the UI fan out to the
/// correct vendor client.
@MainActor
final class LightManager: ObservableObject {
    @Published private(set) var devices: [LightDevice] = []
    @Published private(set) var rooms: [Room] = []
    @Published private(set) var favoriteIDs: Set<String> = []
    @Published private(set) var scenes: [LightingScene] = []
    @Published private(set) var isScanning: Bool = false
    @Published var statusMessage: String = ""
    @Published var commandError: String?
    @Published private(set) var canUndo: Bool = false
    @Published private(set) var canRedo: Bool = false
    private var errorClearTask: Task<Void, Never>?

    private var lifx: LIFXClient?
    private var govee: GoveeClient?
    private var refreshTimer: Timer?
    private var scheduleTimer: Timer?

    private let roomsDefaultsKey = "LumenDesk.rooms.v1"
    private let favoritesDefaultsKey = "LumenDesk.favorites.v1"
    private let scenesDefaultsKey = "LumenDesk.scenes.v1"

    // Undo/redo state — coalesces rapid changes (e.g. slider drags) per device.
    private struct DeviceState {
        let deviceID: String
        let isOn: Bool
        let brightness: Double
        let color: Color
    }
    private var undoStack: [[DeviceState]] = []
    private var redoStack: [[DeviceState]] = []
    private var lastChangeTime: [String: Date] = [:]
    private let undoLimit = 20
    private let coalesceWindow: TimeInterval = 1.0

    init() {
        rooms = loadRooms()
        favoriteIDs = loadFavorites()
        scenes = loadScenes()
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
        // Stop spinner after a short window — discovery is fire-and-forget.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.isScanning = false
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
        let nowHour = cal.component(.hour, from: now)
        let nowMinute = cal.component(.minute, from: now)
        for room in rooms {
            for entry in room.schedules where entry.isEnabled {
                guard entry.hour == nowHour, entry.minute == nowMinute else { continue }
                let lights = devices(in: room)
                switch entry.action {
                case .turnOn:
                    for d in lights { d.isOn = true; sendPower(d, on: true) }
                case .turnOff:
                    for d in lights { d.isOn = false; sendPower(d, on: false) }
                default:
                    if let brightness = entry.action.brightnessValue {
                        for d in lights { d.brightness = brightness; sendBrightness(d, value: brightness) }
                    }
                }
            }
        }
    }

    private func refreshAll() {
        let now = Date()
        for d in devices {
            // Two missed 30s cycles (>75s) without a response → mark unreachable.
            if now.timeIntervalSince(d.lastSeen) > 75 {
                d.isStale = true
            }
            switch d.brand {
            case .lifx: lifx?.refresh(macHex: d.backendID)
            case .govee: govee?.refresh(deviceID: d.backendID)
            }
        }
    }

    /// Records a successful contact with a device, clearing any stale flag.
    private func markSeen(_ device: LightDevice) {
        device.lastSeen = Date()
        device.isStale = false
    }

    // MARK: - Control

    func publishError(_ message: String) {
        commandError = message
        errorClearTask?.cancel()
        errorClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { self.commandError = nil }
        }
    }

    func setPower(_ device: LightDevice, on: Bool) {
        if device.isStale {
            publishError(""\(device.name)" may be offline — command sent anyway.")
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
        recordChange([device])
        device.color = color
        sendColor(device, color: color)
    }

    // MARK: - Room & global bulk controls

    func setPower(in room: Room, on: Bool) {
        let lights = devices(in: room)
        let staleCount = lights.filter { $0.isStale }.count
        if staleCount > 0 {
            publishError("\(staleCount) light\(staleCount == 1 ? "" : "s") in "\(room.name)" may be offline.")
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

    // MARK: - Vendor send helpers (no model mutation, no undo recording)

    private func sendPower(_ device: LightDevice, on: Bool) {
        switch device.brand {
        case .lifx: lifx?.setPower(macHex: device.backendID, on: on)
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
                kelvin: 3500
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
                kelvin: 3500
            )
            lifx?.setColor(macHex: device.backendID, color: lifxColor)
        case .govee:
            let rgb = color.rgbComponents
            govee?.setColor(deviceID: device.backendID,
                            r: Int(rgb.r * 255), g: Int(rgb.g * 255), b: Int(rgb.b * 255))
        }
    }

    // MARK: - Undo / redo

    private func snapshot(_ device: LightDevice) -> DeviceState {
        DeviceState(deviceID: device.id, isOn: device.isOn,
                    brightness: device.brightness, color: device.color)
    }

    /// Records the current state of the given devices on the undo stack before
    /// they are mutated. Rapid repeated changes to the same device (or the
    /// same set of devices, for bulk ops) within a 1 s window coalesce into
    /// the first snapshot, so a slider drag produces one undoable step.
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
        canUndo = !undoStack.isEmpty
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
            sendColor(d, color: snap.color)
            sendPower(d, on: snap.isOn)
        }
    }

    // MARK: - Internal helpers

    fileprivate func upsert(_ device: LightDevice) {
        if let idx = devices.firstIndex(where: { $0.id == device.id }) {
            let existing = devices[idx]
            existing.name = device.name
            existing.address = device.address
            markSeen(existing)
        } else {
            devices.append(device)
            devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
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
            if !label.isEmpty { device.name = label }
            device.isOn = isOn
            device.brightness = Double(color.brightness) / 65535.0
            let h = Double(color.hue) / 65535.0
            let s = Double(color.saturation) / 65535.0
            // Display in the UI at full brightness — brightness is shown separately.
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
            device.color = Color(red: Double(r) / 255.0,
                                 green: Double(g) / 255.0,
                                 blue: Double(b) / 255.0)
            self.markSeen(device)
        }
    }
}

// MARK: - Rooms

extension LightManager {
    /// Lights not currently assigned to any room, sorted by name.
    var unassignedDevices: [LightDevice] {
        let assigned = Set(rooms.flatMap { $0.lightIDs })
        return devices
            .filter { !assigned.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Resolves the lights for a room in the order the user has arranged them.
    /// Skips IDs that no longer correspond to a discovered light.
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
        rooms.removeAll { $0.id == roomID }
        persistRooms()
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

    /// Move a light to the given room, or to the unassigned bucket if `roomID` is nil.
    /// The light is removed from any other room first to keep memberships unique.
    func assign(lightID: String, toRoom roomID: UUID?) {
        for i in rooms.indices {
            rooms[i].lightIDs.removeAll { $0 == lightID }
        }
        if let roomID, let idx = rooms.firstIndex(where: { $0.id == roomID }) {
            rooms[idx].lightIDs.append(lightID)
        }
        persistRooms()
    }

    /// Bulk-assigns a set of lights to the same room (or to unassigned). Used
    /// by the multi-select action bar.
    func assign(lightIDs: Set<String>, toRoom roomID: UUID?) {
        for i in rooms.indices {
            rooms[i].lightIDs.removeAll { lightIDs.contains($0) }
        }
        if let roomID, let idx = rooms.firstIndex(where: { $0.id == roomID }) {
            // Preserve the order in which the manager currently knows about the lights.
            let ordered = devices.map { $0.id }.filter { lightIDs.contains($0) }
            rooms[idx].lightIDs.append(contentsOf: ordered)
        }
        persistRooms()
    }

    /// Shift a light up or down within its current room.
    func moveLight(_ lightID: String, in roomID: UUID, by offset: Int) {
        guard let r = rooms.firstIndex(where: { $0.id == roomID }),
              let l = rooms[r].lightIDs.firstIndex(of: lightID) else { return }
        let target = l + offset
        guard rooms[r].lightIDs.indices.contains(target) else { return }
        rooms[r].lightIDs.swapAt(l, target)
        persistRooms()
    }

    /// Returns the room that owns the given light, if any.
    func room(forLightID lightID: String) -> Room? {
        rooms.first { $0.lightIDs.contains(lightID) }
    }

    /// Serializes the current room layout for export to a file.
    func exportRoomsData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(rooms)
    }

    /// Replaces the current room layout with a previously exported file.
    /// Returns true on success; sets `statusMessage` and returns false on a
    /// malformed file so the user gets feedback instead of silent data loss.
    @discardableResult
    func importRoomsData(_ data: Data) -> Bool {
        guard let decoded = try? JSONDecoder().decode([Room].self, from: data) else {
            statusMessage = "Import failed — that file isn't a valid LumenDesk configuration."
            return false
        }
        rooms = decoded
        persistRooms()
        statusMessage = "Imported \(decoded.count) room\(decoded.count == 1 ? "" : "s")."
        return true
    }

    private func persistRooms() {
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
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
                saturation: hsb.s
            )
        }
        scenes.append(LightingScene(name: trimmed, snapshots: snapshots))
        persistScenes()
    }

    func applyScene(_ scene: LightingScene) {
        let affected = devices.filter { scene.snapshots[$0.id] != nil }
        guard !affected.isEmpty else {
            publishError(""\(scene.name)" has no lights in common with what's on the network.")
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
            d.isOn = snap.isOn
            sendColor(d, color: color)
            sendPower(d, on: snap.isOn)
        }
        if staleCount > 0 {
            publishError("Applied "\(scene.name)" — \(staleCount) light\(staleCount == 1 ? "" : "s") may be offline.")
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
        rooms[idx].schedules.sort { $0.hour != $1.hour ? $0.hour < $1.hour : $0.minute < $1.minute }
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
        rooms.contains { room in
            room.schedules.contains { $0.isEnabled }
        }
    }
}

// MARK: - Search

extension LightManager {
    /// Returns true if a device matches the case-insensitive query against its
    /// name, brand display name, or address. Empty queries match everything.
    func device(_ device: LightDevice, matchesQuery query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.isEmpty { return true }
        return device.name.lowercased().contains(trimmed)
            || device.brand.displayName.lowercased().contains(trimmed)
            || device.address.lowercased().contains(trimmed)
    }

    /// Returns true if any light in the room matches the query, OR the room's
    /// own name matches. Used to decide whether to render a room at all.
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
