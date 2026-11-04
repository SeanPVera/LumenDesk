import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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

    func performDeleteRoom(_ roomID: UUID) {
        guard let idx = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        stopEffect(scope: .room(roomID))
        let deleted = rooms[idx]
        lastDeletedRoom = (room: deleted, index: idx)
        rooms.remove(at: idx)
        reconcileFavoriteOrder()
        recomputeCanUndo()
        publishError("\u{201C}\(deleted.name)\u{201D} deleted.") {
            self.undoDeleteRoom()
        }
    }

    func undoDeleteRoom() {
        guard let (room, index) = lastDeletedRoom else { return }
        let insertAt = min(index, rooms.count)
        rooms.insert(room, at: insertAt)
        lastDeletedRoom = nil
        reconcileFavoriteOrder()
        recomputeCanUndo()
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

    // MARK: - Plan layout

    /// Give every room a block on the board, leaving existing blocks alone.
    ///
    /// Layout is lazy rather than migrated: an archive written before the plan
    /// existed simply has no frames, and the first draw fills them in. Rooms
    /// that already carry a frame are never moved, so adding a room in March
    /// does not rearrange the home you learned in January.
    func ensurePlanLayout() {
        guard rooms.contains(where: { $0.planFrame == nil }) else { return }

        var occupied: [RoomPlanFrame] = rooms.compactMap(\.planFrame)
        for index in rooms.indices where rooms[index].planFrame == nil {
            let span = PlanLayout.defaultSpan(fixtureCount: rooms[index].lightIDs.count)
            let frame = PlanLayout.firstFreeFrame(width: span.width, height: span.height,
                                                  among: occupied)
                ?? RoomPlanFrame(column: 0, row: occupied.map(\.maxRow).max() ?? 0)
            rooms[index].planFrame = frame
            occupied.append(frame)
        }
        persistApplicationState()
    }

    /// Move or resize a room's block.
    ///
    /// Returns false and changes nothing when the frame would overlap another
    /// room or leave the board. A refused drop is the point: silently
    /// reflowing a board somebody arranged by hand destroys the spatial
    /// memory the plan is built on.
    @discardableResult
    func setPlanFrame(_ frame: RoomPlanFrame, for roomID: UUID) -> Bool {
        var others: [UUID: RoomPlanFrame] = [:]
        for room in rooms where room.id != roomID {
            if let existing = room.planFrame { others[room.id] = existing }
        }
        guard PlanLayout.canPlace(frame, for: roomID, among: others),
              let index = rooms.firstIndex(where: { $0.id == roomID }) else { return false }
        rooms[index].planFrame = frame
        persistApplicationState()
        return true
    }

    /// Throw the board away and lay every room out from scratch.
    func resetPlanLayout() {
        let frames = PlanLayout.autoArrange(rooms.map { (id: $0.id, fixtureCount: $0.lightIDs.count) })
        for index in rooms.indices { rooms[index].planFrame = frames[rooms[index].id] }
        persistApplicationState()
    }

    /// Where a fixture stands inside its room, falling back to the
    /// deterministic default so a room draws correctly before anyone has
    /// dragged a single dot.
    func planAnchor(for lightID: String, in room: Room) -> PlanAnchor {
        if let stored = room.fixtureAnchors[lightID] { return stored }
        guard let index = room.lightIDs.firstIndex(of: lightID) else {
            return PlanAnchor(x: 0.5, y: 0.5)
        }
        let defaults = PlanLayout.defaultAnchors(count: room.lightIDs.count)
        return defaults.indices.contains(index) ? defaults[index] : PlanAnchor(x: 0.5, y: 0.5)
    }

    func setPlanAnchor(
        _ anchor: PlanAnchor,
        for lightID: String,
        in roomID: UUID,
        persistImmediately: Bool = true
    ) {
        guard let index = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        rooms[index].fixtureAnchors[lightID] = anchor
        if persistImmediately {
            persistApplicationState()
        } else {
            scheduleDeferredPersistence()
        }
    }

    /// Create a room and hand back its identifier, so a setup flow can assign
    /// a fixture into it in the same gesture that names it. `createRoom(name:)`
    /// keeps its existing signature for the call sites that do not need this.
    @discardableResult
    func addRoom(named name: String) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let room = Room(name: trimmed)
        rooms.append(room)
        persistApplicationState()
        return room.id
    }

    /// Fixtures discovered but never sorted onto the plan. They surface in a
    /// tray on the plan itself rather than being dumped into a junk room, so
    /// the sorting flow keeps working long after onboarding is over.
    var unplacedDevices: [LightDevice] {
        let assigned = Set(rooms.flatMap(\.lightIDs))
        return devices.filter { !assigned.contains($0.id) }
    }

    typealias ExportedConfiguration = PersistenceStore.ConfigurationArchive

    func exportRoomsData() -> Data? { exportConfigurationData() }

    func exportConfigurationData() -> Data? {
        try? persistenceStore.exportConfiguration(from: persistedApplicationState())
    }

    /// Writes the exported configuration to `url` and reports what happened.
    ///
    /// Both halves of this used to be silent: encoding returned nil on failure
    /// and the write went out through `try?`. A user whose export never landed
    /// — a read-only volume, a folder they could not write — saw nothing at all
    /// and was left believing their configuration was backed up.
    @discardableResult
    func exportConfiguration(to url: URL) -> Bool {
        do {
            let data = try persistenceStore.exportConfiguration(from: persistedApplicationState())
            try data.write(to: url, options: .atomic)
            lastActionSummary = "Configuration exported to \u{201C}\(url.lastPathComponent)\u{201D}"
            logActivity(.system, title: "Configuration exported", detail: url.lastPathComponent)
            return true
        } catch {
            publishError("Export failed \u{2014} could not write \u{201C}\(url.lastPathComponent)\u{201D}: \(error.localizedDescription)")
            logActivity(.system, title: "Configuration export failed",
                        detail: error.localizedDescription, isFailure: true)
            return false
        }
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

    func reportImportMatchStatus(roomCount: Int) {
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
        reconcileFavoriteOrder()
    }

    var favoriteDevices: [LightDevice] {
        devices
            .filter { favoriteIDs.contains($0.id) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    func isFavoriteRoom(_ roomID: UUID) -> Bool { favoriteRoomIDs.contains(roomID) }

    func toggleFavoriteRoom(_ roomID: UUID) {
        if favoriteRoomIDs.contains(roomID) { favoriteRoomIDs.remove(roomID) } else { favoriteRoomIDs.insert(roomID) }
        reconcileFavoriteOrder()
    }

    func isFavoriteScene(_ sceneID: UUID) -> Bool { favoriteSceneIDs.contains(sceneID) }

    func toggleFavoriteScene(_ sceneID: UUID) {
        if favoriteSceneIDs.contains(sceneID) { favoriteSceneIDs.remove(sceneID) } else { favoriteSceneIDs.insert(sceneID) }
        reconcileFavoriteOrder()
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
    func captureScene(name: String, scope: LightScope = .all) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var snapshots: [String: DeviceSnapshot] = [:]
        for d in devices(in: scope) {
            let hsb = d.color.hsbComponents
            snapshots[d.id] = DeviceSnapshot(
                isOn: d.isOn,
                brightness: d.brightness,
                hue: hsb.h,
                saturation: hsb.s,
                kelvin: d.kelvin,
                segments: activeSegmentState(for: d.id),
                matrix: activeLIFXMatrixState(for: d.id),
                nanoleafAppearance: d.nanoleafAppearance,
                nanoleafDesign: d.brand == .nanoleaf ? shapes.showingDesign(for: d.id) : nil
            )
        }
        scenes.append(LightingScene(name: trimmed, snapshots: snapshots))
        persistApplicationState()
        logActivity(.scene, title: "Scene captured", detail: "\(trimmed): \(snapshots.count) lights")
    }

    /// Direction A's durable room composition. `LightingScene` remains the
    /// archive type so every existing scene migrates losslessly; the product
    /// now presents the object consistently as a Look.
    @discardableResult
    func captureLook(name: String, deviceIDs: Set<String>) -> LightingScene? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let targets = devices.filter { deviceIDs.contains($0.id) }
        guard !trimmed.isEmpty, !targets.isEmpty else { return nil }

        var snapshots: [String: DeviceSnapshot] = [:]
        for device in targets {
            let hsb = device.color.hsbComponents
            snapshots[device.id] = DeviceSnapshot(
                isOn: device.isOn,
                brightness: device.brightness,
                hue: hsb.h,
                saturation: hsb.s,
                kelvin: device.kelvin,
                segments: activeSegmentState(for: device.id),
                matrix: activeLIFXMatrixState(for: device.id),
                nanoleafAppearance: device.nanoleafAppearance,
                nanoleafDesign: device.brand == .nanoleaf
                    ? shapes.showingDesign(for: device.id) : nil
            )
        }
        let look = LightingScene(name: trimmed, snapshots: snapshots)
        scenes.append(look)
        persistApplicationState()
        lastActionSummary = "Saved Look “\(trimmed)”"
        logActivity(.scene, title: "Look saved", detail: "\(trimmed): \(snapshots.count) fixtures")
        return look
    }

    /// Applies only the part of a migrated or saved Look that belongs to the
    /// open room. A Look can therefore survive fixture moves without reaching
    /// into a different room.
    func applyLook(_ look: LightingScene, deviceIDs: Set<String>) {
        let snapshots = look.snapshots.filter { deviceIDs.contains($0.key) }
        guard !snapshots.isEmpty else {
            publishError("“\(look.name)” has no fixtures in this room.")
            return
        }
        applyScene(
            LightingScene(id: look.id, name: look.name,
                          snapshots: snapshots, createdAt: look.createdAt),
            allowTurningOff: true,
            reviewed: true,
            allowUnavailableTargets: true
        )
    }

    /// A live, reversible preview using the same pure renderer and transport
    /// branches as Apply. Leaving the composer restores the exact opening
    /// power, brightness, colour, segment, matrix, and panel state.
    func startLookPreview(
        _ theme: LightingTheme,
        deviceIDs: Set<String>,
        in scope: LightScope = .all,
        paletteAssignments: [String: Int]? = nil,
        spatialField: SpatialFieldVector = .themeDefault,
        transitionDuration: TimeInterval = 1.8
    ) {
        stopSceneRehearsal(restore: true)
        // `devices(in:)` preserves the room's explicit fixture order. Filtering
        // the global discovery array here would make a composed gradient land
        // on different fixtures than the room-ordered visual preview.
        let targets = devices(in: scope).filter { deviceIDs.contains($0.id) }
        guard !targets.isEmpty else {
            publishError("Select at least one fixture to preview this Look.")
            return
        }
        cancelIdentifications(deviceIDs: deviceIDs, restore: true)
        stopEffects(touching: deviceIDs)
        cancelPendingBrightness(deviceIDs: deviceIDs)
        rehearsalSnapshot = targets.map(snapshot)
        rehearsalSceneID = UUID()

        let plan = plannedLook(
            theme,
            targets: targets,
            in: scope,
            paletteAssignments: paletteAssignments,
            spatialField: spatialField
        )
        let plans = Dictionary(plan.fixtures.map { ($0.fixtureID, $0) },
                               uniquingKeysWith: { first, _ in first })
        for device in targets {
            guard let fixturePlan = plans[device.id] else { continue }
            applyThemePlan(fixturePlan, to: device, transitionDuration: transitionDuration)
        }
        var summary = "Previewing “\(theme.name)”"
        if let adaptation = lookAdaptationSummary(
            theme,
            deviceIDs: deviceIDs,
            in: scope,
            paletteAssignments: paletteAssignments,
            spatialField: spatialField
        ) {
            summary += " — \(adaptation)"
        }
        lastActionSummary = summary
    }

    /// Saves a composed Look directly from its planned fixture states without
    /// mutating live fixtures or broadcasting hardware packets when the user
    /// has not started a live room preview.
    @discardableResult
    func saveLookFromPlan(
        name: String,
        theme: LightingTheme,
        deviceIDs: Set<String>,
        in scope: LightScope = .all,
        paletteAssignments: [String: Int]? = nil,
        spatialField: SpatialFieldVector = .themeDefault
    ) -> LightingScene? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let targets = devices(in: scope).filter { deviceIDs.contains($0.id) }
        guard !targets.isEmpty else {
            publishError("Select at least one fixture to save this Look.")
            return nil
        }

        let plan = plannedLook(
            theme,
            targets: targets,
            in: scope,
            paletteAssignments: paletteAssignments,
            spatialField: spatialField
        )
        let plans = Dictionary(plan.fixtures.map { ($0.fixtureID, $0) },
                               uniquingKeysWith: { first, _ in first })

        var snapshots: [String: DeviceSnapshot] = [:]
        for device in targets {
            guard let fixturePlan = plans[device.id] else { continue }
            let hsb = fixturePlan.tone.displayColor.hsbComponents
            let segmentSnap: GoveeSegmentState?
            if let segments = fixturePlan.segments, device.brand == .govee {
                var constrained = zoneConstrained(segments, for: device)
                constrained.isActive = true
                segmentSnap = constrained
            } else {
                segmentSnap = nil
            }
            let matrixSnap: LIFXMatrixState?
            if var matrix = fixturePlan.matrix, device.isLIFXLuna {
                matrix.productID = device.productID ?? matrix.productID
                matrix.isActive = true
                matrixSnap = matrix
            } else {
                matrixSnap = nil
            }
            let nanoleafDesignSnap: NanoleafPanelDesign?
            if let tones = fixturePlan.panels, device.brand == .nanoleaf, let layout = shapes.layout(device.id) {
                nanoleafDesignSnap = NanoleafDesignBuilder.design(
                    tones: tones.map { (hue: $0.hue, saturation: $0.saturation, level: $0.level) },
                    layout: layout,
                    rotationDegrees: Double(shapes.displayOrientation(device.id))
                )
            } else {
                nanoleafDesignSnap = nil
            }

            snapshots[device.id] = DeviceSnapshot(
                isOn: true,
                brightness: fixturePlan.brightness,
                hue: hsb.h,
                saturation: hsb.s,
                kelvin: fixturePlan.kelvin,
                segments: segmentSnap,
                matrix: matrixSnap,
                nanoleafAppearance: device.nanoleafAppearance,
                nanoleafDesign: nanoleafDesignSnap
            )
        }

        let look = LightingScene(name: trimmed, snapshots: snapshots)
        scenes.append(look)
        persistApplicationState()
        lastActionSummary = "Saved Look “\(trimmed)”"
        logActivity(.scene, title: "Look saved", detail: "\(trimmed): \(snapshots.count) fixtures")
        return look
    }

    /// Plain-language, capability-aware disclosure for the composer.
    func lookAdaptationSummary(
        _ theme: LightingTheme,
        deviceIDs: Set<String>,
        in scope: LightScope = .all,
        paletteAssignments: [String: Int]? = nil,
        spatialField: SpatialFieldVector = .themeDefault
    ) -> String? {
        let targets = devices(in: scope).filter { deviceIDs.contains($0.id) }
        guard !targets.isEmpty else { return nil }
        let plan = plannedLook(
            theme,
            targets: targets,
            in: scope,
            paletteAssignments: paletteAssignments,
            spatialField: spatialField
        )
        var parts: [String] = []
        if plan.solidCount > 0, theme.colors.count > 1 {
            parts.append("\(plan.solidCount) single-colour fixture\(plan.solidCount == 1 ? "" : "s") hold one palette colour each")
        }
        if plan.spatialCount > 0 {
            parts.append("\(plan.spatialCount) spatial fixture\(plan.spatialCount == 1 ? " carries" : "s carry") the palette across its surface")
        }
        if plan.zoneLimitedCount > 0 {
            parts.append("\(plan.zoneLimitedCount) fixture\(plan.zoneLimitedCount == 1 ? " is" : "s are") limited to its active zones")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ") + "."
    }

    func plannedLook(
        _ theme: LightingTheme,
        targets: [LightDevice],
        in scope: LightScope = .all,
        paletteAssignments: [String: Int]?,
        spatialField: SpatialFieldVector = .themeDefault
    ) -> ThemePlan {
        let fixtures = targets.map { themeFixture($0, in: scope) }
        if let paletteAssignments {
            return ThemePlanner.planExact(
                theme,
                fixtures: fixtures,
                paletteIndices: paletteAssignments
            )
        }
        return ThemePlanner.plan(theme, fixtures: fixtures, spatialField: spatialField)
    }

    func applyScene(_ scene: LightingScene) {
        applyScene(scene, allowTurningOff: true, reviewed: false)
    }

    func deleteScene(_ sceneID: UUID) {
        guard let idx = scenes.firstIndex(where: { $0.id == sceneID }) else { return }
        let scene = scenes[idx]
        confirmationCoordinator.request(
            .init(
                title: "Delete “\(scene.name)” everywhere?",
                message: "The Look will be removed from every room shelf where it appears. You can undo the deletion afterward.",
                confirmTitle: "Delete Everywhere",
                role: .destructive,
                requirement: .always
            ),
            action: { [weak self] in self?.performDeleteScene(sceneID) }
        )
    }

    func performDeleteScene(_ sceneID: UUID) {
        guard let idx = scenes.firstIndex(where: { $0.id == sceneID }) else { return }
        let deleted = scenes[idx]
        lastDeletedScene = (scene: deleted, index: idx)
        scenes.remove(at: idx)
        favoriteSceneIDs.remove(sceneID)
        reconcileFavoriteOrder()
        recomputeCanUndo()
        publishError("Look “\(deleted.name)” deleted.") { self.undoDeleteScene() }
    }

    func undoDeleteScene() {
        guard let (scene, index) = lastDeletedScene else { return }
        scenes.insert(scene, at: min(index, scenes.count))
        lastDeletedScene = nil
        recomputeCanUndo()
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
        if rehearsalSceneID == draft.id { stopSceneRehearsal(restore: true) }
        sceneRevisions.insert(SceneRevision(scene: scenes[index], label: revisionLabel), at: 0)
        sceneRevisions = Array(sceneRevisions.prefix(60))
        scenes[index] = draft
        sceneDrafts.removeValue(forKey: draft.id)
        persistApplicationState()
        lastActionSummary = "Saved \(draft.name) — restore previous versions from scene History"
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

    /// Puts one captured scene snapshot onto a light.
    ///
    /// Shared by Apply and Rehearse so a preview cannot drift from what
    /// applying actually does. Rehearsal used to carry its own copy of this
    /// logic, which had lost the Govee segment branch and never sent a Govee
    /// brightness at all — so rehearsing a scene that captured a segment
    /// layout previewed a solid wash, at the light's old brightness, while
    /// Apply painted the real segments.
    func applySceneSnapshot(_ snap: DeviceSnapshot, to device: LightDevice) {
        let snap = snap.normalized()
        device.isOn = snap.isOn
        device.brightness = snap.brightness
        device.kelvin = snap.kelvin
        if restoreNanoleafOutput(design: snap.nanoleafDesign, appearance: snap.nanoleafAppearance, to: device) {
            // Restored the captured design or controller mode.
        } else if let matrix = snap.matrix, device.isLIFXLuna {
            applyLIFXMatrix(device, state: matrix, recordUndo: false,
                            turnOn: false, announce: false)
        } else if let segments = snap.segments, device.brand == .govee {
            applySegments(device, state: segments, recordUndo: false, turnOn: false, announce: false)
            sendBrightness(device, value: snap.brightness)
        } else {
            let color = Color(hue: snap.hue, saturation: snap.saturation, brightness: 1)
            device.color = color
            sendColor(device, color: color)
            // Govee needs an explicit brightness message; LIFX carries
            // brightness inside the same SetColor packet.
            if device.brand == .govee { sendBrightness(device, value: snap.brightness) }
        }
        sendPower(device, on: snap.isOn)
    }

    func startSceneRehearsal(_ scene: LightingScene, deviceIDs: Set<String>) {
        stopSceneRehearsal(restore: true)
        let targets = devices.filter { deviceIDs.contains($0.id) && scene.snapshots[$0.id] != nil && !$0.isStale }
        guard !targets.isEmpty else {
            publishError("“\(scene.name)” has no currently available lights to preview.")
            return
        }
        cancelIdentifications(deviceIDs: Set(targets.map(\.id)), restore: true)
        stopEffects(touching: Set(targets.map(\.id)))
        cancelPendingBrightness(deviceIDs: Set(targets.map(\.id)))
        rehearsalSnapshot = targets.map(snapshot)
        rehearsalSceneID = scene.id
        for device in targets {
            guard let value = scene.snapshots[device.id] else { continue }
            applySceneSnapshot(value, to: device)
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

    @discardableResult
    func addSchedule(_ entry: ScheduleEntry, to roomID: UUID) -> Bool {
        guard let idx = rooms.firstIndex(where: { $0.id == roomID }),
              rooms[idx].schedules.count < Self.maximumSchedulesPerRoom else { return false }
        rooms[idx].schedules.append(entry)
        // Sort by resolved clock-minute so the list is always chronological.
        rooms[idx].schedules.sort { lhs, rhs in
            scheduleEngine.scheduledMinute(for: lhs, solarTimes: scheduleSolarTimes)
                < scheduleEngine.scheduledMinute(for: rhs, solarTimes: scheduleSolarTimes)
        }
        persistApplicationState()
        return true
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

    func scheduleNapTimer() {
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

    func tickNapMode() {
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

    /// The color a LIFX bulb reports back after being sent this one.
    ///
    /// LIFX HSBK keeps brightness in its own channel, so `LightManager.sendColor`
    /// sends only this color's hue and saturation and supplies the device's
    /// brightness separately. `StateLight` therefore always describes a
    /// full-value color, whatever value the user picked.
    var lifxReportedEquivalent: Color {
        let hsb = hsbComponents
        return Color(hue: hsb.h, saturation: hsb.s, brightness: 1)
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
