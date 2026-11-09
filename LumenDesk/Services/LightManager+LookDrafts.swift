import SwiftUI
import Foundation

// MARK: - Look Composer support
//
// Preview, save and duplicate for the Polar Look Composer. Preview reuses
// the rehearsal session (`rehearsalSceneID` / `rehearsalSnapshot`) and the
// same `applySceneSnapshot` path as Apply, so a preview can't drift from
// what the saved Look does, and stopping it restores the exact opening
// state. Nothing here runs unless the composer's Preview switch is on.

extension LightManager {
    /// Shows `snapshots` on their lights as a reversible preview. Pass the
    /// id returned last time to update the running preview in place; a stale
    /// id (the preview was ended elsewhere) returns nil and touches nothing.
    @discardableResult
    func previewComposedLook(_ snapshots: [String: DeviceSnapshot], updating previewID: UUID? = nil) -> UUID? {
        if let previewID {
            guard rehearsalSceneID == previewID else { return nil }
        } else {
            stopSceneRehearsal(restore: true)
        }
        let targets = devices.filter { snapshots[$0.id] != nil && !$0.isStale }
        let targetIDs = Set(targets.map(\.id))
        let originals = Dictionary(rehearsalSnapshot.map { ($0.deviceID, $0) },
                                   uniquingKeysWith: { first, _ in first })
        // Lights that left the draft go back to how they were.
        restoreDeviceStates(rehearsalSnapshot.filter { !targetIDs.contains($0.deviceID) })
        guard !targets.isEmpty else {
            rehearsalSnapshot = []
            if previewID == nil { rehearsalSceneID = UUID() }
            return rehearsalSceneID
        }
        cancelIdentifications(deviceIDs: targetIDs, restore: true)
        let inherited = stopEffects(touching: targetIDs)
        cancelPendingBrightness(deviceIDs: targetIDs)
        commandCoordinator.cancel(deviceIDs: targetIDs)
        rehearsalSnapshot = targets.map { originals[$0.id] ?? inherited[$0.id] ?? snapshot($0) }
        if previewID == nil { rehearsalSceneID = UUID() }
        for device in targets {
            guard let snap = snapshots[device.id] else { continue }
            applySceneSnapshot(snap, to: device)
        }
        lastActionSummary = "Previewing Look on \(targets.count) light\(targets.count == 1 ? "" : "s")"
        return rehearsalSceneID
    }

    /// Saves the composer's draft. With `replacing`, the existing Look is
    /// updated (its previous version goes to History); otherwise a new Look
    /// is added. Never sends anything to a light.
    @discardableResult
    func saveComposedLook(name: String, snapshots: [String: DeviceSnapshot],
                          replacing lookID: UUID? = nil) -> LightingScene? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !snapshots.isEmpty else {
            publishError("Include at least one fixture to save this Look.")
            return nil
        }
        if let lookID, let existing = scenes.first(where: { $0.id == lookID }) {
            let updated = LightingScene(id: existing.id, name: trimmed, snapshots: snapshots,
                                        createdAt: existing.createdAt)
            updateScene(updated, revisionLabel: "Before composer edit")
            return updated
        }
        let look = LightingScene(name: trimmed, snapshots: snapshots)
        scenes.append(look)
        persistApplicationState()
        lastActionSummary = "Saved Look “\(trimmed)”"
        logActivity(.scene, title: "Look saved", detail: "\(trimmed): \(snapshots.count) fixtures")
        return look
    }

    /// Adds a copy of a Look named "<name> copy". Sends nothing.
    @discardableResult
    func duplicateLook(_ lookID: UUID) -> LightingScene? {
        guard let source = scenes.first(where: { $0.id == lookID }) else { return nil }
        let name = LookDraftBuilder.copyName(for: source.name, existing: scenes.map(\.name))
        let copy = LightingScene(name: name, snapshots: source.snapshots)
        if let index = scenes.firstIndex(where: { $0.id == lookID }) {
            scenes.insert(copy, at: index + 1)
        } else {
            scenes.append(copy)
        }
        persistApplicationState()
        lastActionSummary = "Duplicated “\(source.name)” as “\(name)”"
        logActivity(.scene, title: "Look duplicated", detail: name)
        return copy
    }
}
