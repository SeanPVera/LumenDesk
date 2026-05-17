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
    @Published private(set) var isScanning: Bool = false
    @Published var statusMessage: String = ""

    private var lifx: LIFXClient?
    private var govee: GoveeClient?
    private var refreshTimer: Timer?

    private let roomsDefaultsKey = "LumenDesk.rooms.v1"

    init() {
        rooms = loadRooms()
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

    func setPower(_ device: LightDevice, on: Bool) {
        device.isOn = on
        switch device.brand {
        case .lifx: lifx?.setPower(macHex: device.backendID, on: on)
        case .govee: govee?.setPower(deviceID: device.backendID, on: on)
        }
    }

    func setBrightness(_ device: LightDevice, value: Double) {
        device.brightness = value
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

    func setColor(_ device: LightDevice, color: Color) {
        device.color = color
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
