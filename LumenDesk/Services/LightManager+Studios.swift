import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
                         announce: Bool = true,
                         transitionDuration: TimeInterval = 0.25) {
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
                width: next.width,
                durationMS: UInt32(max(0, min(60_000, Int(transitionDuration * 1_000))))
            )
        }
        if announce {
            logActivity(.command, title: "Luna layout applied",
                        detail: "\(device.label): \(next.zoneCount) color zones")
            lastActionSummary = "Painted \(next.zoneCount) zones on \(device.label)"
        }
    }

    func markLIFXMatrixInactive(_ device: LightDevice) {
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
        let profile = segmentStudioProfile(for: device) ?? .generic
        if let saved = goveeSegmentStates[device.id] {
            return profile.normalizedEditorState(saved)
        }
        return profile.normalizedEditorState(.seed(count: profile.defaultSegmentCount,
                                                   color: device.color,
                                                   gradient: false))
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
        segmentPreviewIDs.insert(device.id)
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
        segmentPreviewIDs.remove(device.id)
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
    /// channel, so each segment's own brightness is folded into its RGB, and
    /// switched-off zones go out as black. Fixtures that can only run some of
    /// their zones at once are clamped here as well, so no path — studio,
    /// scene, effect, or Music Mode — can ask the lamp for a frame it has no
    /// way to show.
    func sendRazerLayout(_ device: LightDevice, state: GoveeSegmentState) {
        guard demoWorkspaceController.allowsLiveNetworking else { return }
        let showable = (segmentStudioProfile(for: device) ?? .generic).enforcingZoneLimit(state)
        let colors = showable.colors.map { segment -> (r: Int, g: Int, b: Int) in
            let rgb = segment.renderedRGB255
            let scale = segment.brightness
            return (r: Int((Double(rgb.r) * scale).rounded()),
                    g: Int((Double(rgb.g) * scale).rounded()),
                    b: Int((Double(rgb.b) * scale).rounded()))
        }
        govee?.sendRazerFrame(deviceID: device.backendID, colors: colors, blend: showable.gradient)
    }

    /// Fits a generated layout to a fixture's zone rules. Effect and Music
    /// Mode frames paint every segment, but a lamp that can only run some of
    /// its zones at once should keep lighting the zones the user picked in the
    /// studio — otherwise the clamp would choose a different pair from frame
    /// to frame and the lamp would flicker between them.
    func zoneConstrained(_ state: GoveeSegmentState, for device: LightDevice) -> GoveeSegmentState {
        guard let profile = segmentStudioProfile(for: device), profile.limitsSimultaneousZones else {
            return state
        }
        var next = state
        if let stored = goveeSegmentStates[device.id],
           stored.segmentCount == next.segmentCount,
           stored.poweredCount > 0 {
            next.setPoweredSegments(stored.poweredSegments)
        }
        return profile.enforcingZoneLimit(next)
    }

    /// Puts a stream-hold device's applied layout on the light and leaves the
    /// overlay up. Re-sending `razer-on` briefly clears the existing frame on
    /// H60B0, so ordinary keepalives send only the atomic color frame. Mode is
    /// enabled once per session, or explicitly after a known reconnect.
    func assertStreamHold(_ device: LightDevice, state: GoveeSegmentState,
                                  forceModeEnable: Bool = false) {
        guard demoWorkspaceController.allowsLiveNetworking else { return }
        let shouldEnableMode = forceModeEnable || !razerActiveIDs.contains(device.id)
        razerActiveIDs.insert(device.id)
        if shouldEnableMode {
            govee?.setRazerMode(deviceID: device.backendID, on: true)
        }
        sendRazerLayout(device, state: state)
    }

    /// Stream-hold layouts live only in the razer overlay. Called from the
    /// 30-second refresh tick, discovery, stale recovery, and power-on so held
    /// layouts stay current while LumenDesk is running. Ordinary refreshes
    /// send only a frame; known reconnects can explicitly re-enable the mode.
    /// Skipped while the light is off — a frame must never light up a light
    /// the user switched off.
    func reassertStreamHoldIfNeeded(_ device: LightDevice, forceModeEnable: Bool = false) {
        guard device.brand == .govee, device.isOn, !segmentPreviewIDs.contains(device.id),
              demoWorkspaceController.allowsLiveNetworking,
              segmentStudioProfile(for: device)?.appliesViaStream == true,
              let held = activeSegmentState(for: device.id) else { return }
        assertStreamHold(device, state: held, forceModeEnable: forceModeEnable)
    }

    /// Saves the studio's draft without commanding the light, so a half
    /// finished paint job survives closing the sheet. The layout only keeps
    /// its "showing on the light" status while it still matches what was
    /// applied — an edited-but-unapplied draft must not masquerade as live
    /// state to scenes and undo.
    func storeSegmentState(_ state: GoveeSegmentState, for device: LightDevice) {
        let profile = segmentStudioProfile(for: device)
        let state = profile?.enforcingZoneLimit(state) ?? state
        let previous = goveeSegmentStates[device.id]
        let changedFromAppliedState = previous?.isActive == true
            && (previous?.colors != state.colors || previous?.gradient != state.gradient)
        if profile?.appliesViaStream == true,
           changedFromAppliedState {
            return
        }
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
        let profile = segmentStudioProfile(for: device)
        var next = profile?.enforcingZoneLimit(state) ?? state
        next.isActive = true
        goveeSegmentStates[device.id] = next
        persistApplicationState()
        device.color = next.blendedColor
        // An all-dark layout is the user asking for nothing to be lit, so it
        // must not switch the light on to show it.
        if turnOn, !device.isOn, !next.isFullyDark {
            device.isOn = true
            sendPower(device, on: true)
        }
        noteSegmentCommand(device, summary: "Applying \(next.segmentCount)-segment layout")
        if demoWorkspaceController.allowsLiveNetworking {
            if profile?.appliesViaStream == true {
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
            if profile?.limitsSimultaneousZones == true {
                let unit = profile?.editorUnitName ?? "zone"
                let summary = "\(next.poweredCount) of \(next.segmentCount) \(unit)s lit"
                logActivity(.command, title: "Lamp zones applied", detail: "\(device.label): \(summary)")
                lastActionSummary = "Set \(summary) on \(device.label)"
            } else {
                logActivity(.command, title: "Segment layout applied",
                            detail: "\(device.label): \(next.segmentCount) segments\(next.gradient ? ", blended" : "")")
                lastActionSummary = "Painted \(next.segmentCount) segments on \(device.label)"
            }
        }
    }

    func addSegmentPreset(name: String, stops: [GoveeSegmentColor], fill: GoveeSegmentPreset.Fill = .smooth) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !stops.isEmpty else { return }
        // A preset carries colors, not which zones a fixture happens to be
        // running, so saved stops are always powered.
        let stops = stops.map { $0.settingPower(true) }
        goveeSegmentPresets.append(GoveeSegmentPreset(name: trimmed, stops: stops, fill: fill))
        persistApplicationState()
        lastActionSummary = "Saved segment preset \u{201C}\(trimmed)\u{201D}"
    }

    func deleteSegmentPreset(_ presetID: UUID) {
        goveeSegmentPresets.removeAll { $0.id == presetID }
        persistApplicationState()
    }

    /// Sends the durable packet batch for a layout.
    func sendSegmentPackets(_ device: LightDevice, state: GoveeSegmentState) {
        let packets = state.durableSegmentPackets(
            supportsGradient: segmentStudioProfile(for: device)?.supportsGradient == true
        )
        govee?.applySegments(deviceID: device.backendID, packets: packets)
    }

    /// Segment layouts aren't echoed back by `devStatus`, so they can't ride
    /// the expectation-matching confirmation pipeline — that would end every
    /// apply with a false "did not confirm" error. Show a lightweight
    /// sending → applied badge instead.
    func noteSegmentCommand(_ device: LightDevice, summary: String) {
        commandCoordinator.recordUnconfirmedSend(deviceID: device.id, summary: summary)
    }

    /// Called whenever a solid color or white command goes to a Govee device,
    /// so scenes and undo stop treating the stored layout as what is on
    /// display. The layout itself is kept for one-tap re-apply.
    func markSegmentsInactive(_ device: LightDevice) {
        // A live razer overlay — studio preview or stream-hold — shadows
        // every static command; bring it down ahead of the solid color,
        // white, or effect frame that triggered this call.
        segmentPreviewIDs.remove(device.id)
        if razerActiveIDs.contains(device.id) {
            razerActiveIDs.remove(device.id)
            govee?.setRazerMode(deviceID: device.backendID, on: false)
        }
        guard goveeSegmentStates[device.id]?.isActive == true else { return }
        goveeSegmentStates[device.id]?.isActive = false
        persistApplicationState()
    }
}

