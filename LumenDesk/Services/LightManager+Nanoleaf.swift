import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Nanoleaf Shapes

extension LightManager {
    func configureNanoleaf() {
        nanoleaf.onCandidates = { [weak self] candidates in
            guard let self, self.demoWorkspaceController.acceptsLiveNetworkCallbacks else { return }
            self.nanoleafCandidates = candidates
        }
        nanoleaf.onDiscoveryError = { [weak self] message in
            guard let self, self.demoWorkspaceController.acceptsLiveNetworkCallbacks else { return }
            self.nanoleafDiscoveryError = message
        }
        nanoleaf.onUpdate = { [weak self] pairing, info in
            self?.nanoleafDidUpdate(pairing: pairing, info: info)
        }
        nanoleaf.onFailure = { [weak self] serial, error in
            guard let self, self.demoWorkspaceController.acceptsLiveNetworkCallbacks else { return }
            let id = "nanoleaf:\(serial)"
            if let device = self.device(withID: id), error == .pairingRequired {
                device.needsNanoleafPairing = true
                device.isStale = true
            }
            if self.commandPendingIDs.contains(id) {
                self.commandCoordinator.fail(deviceIDs: [id], summary: error.localizedDescription)
                self.publishError(error.localizedDescription)
            }
        }
        // Shapes: every live callback is dropped while Demo Mode holds the
        // workspace, so a real wall can never write into the simulated one.
        shapes.isLive = { [weak self] in self?.demoWorkspaceController.allowsLiveNetworking ?? false }
        shapes.persist = { [weak self] in self?.persistApplicationState() }
        shapes.restoreWholeWall = { [weak self] id in self?.restoreWholeWallAfterPreview(id) }
        nanoleaf.onOperationFailure = { [weak self] serial, operation, error in
            guard let self, self.demoWorkspaceController.acceptsLiveNetworkCallbacks else { return }
            self.shapes.didFail(deviceID: "nanoleaf:\(serial)", operation: operation, error: error)
        }
        nanoleaf.onWriteAccepted = { [weak self] serial, operation in
            guard let self, self.demoWorkspaceController.acceptsLiveNetworkCallbacks else { return }
            self.shapes.didAccept(deviceID: "nanoleaf:\(serial)", operation: operation)
        }
        nanoleaf.onEvent = { [weak self] serial, event in
            guard let self, self.demoWorkspaceController.acceptsLiveNetworkCallbacks else { return }
            self.shapes.handle(deviceID: "nanoleaf:\(serial)", event: event)
        }
        nanoleaf.onStreamStatus = { [weak self] serial, status in
            guard let self, self.demoWorkspaceController.acceptsLiveNetworkCallbacks else { return }
            self.shapes.didChangeStream(deviceID: "nanoleaf:\(serial)", status: status)
        }
    }

    func pairNanoleaf(host: String, port: Int = 16021, serviceID: String? = nil) async throws {
        guard demoWorkspaceController.allowsLiveNetworking else { throw NanoleafError.unavailable }
        try await nanoleaf.pair(endpoint: NanoleafEndpoint(host: host, port: port), serviceID: serviceID)
        logActivity(.system, title: "Nanoleaf controller paired", detail: "Local control is ready.")
    }

    func nanoleafDidUpdate(pairing: NanoleafPairing, info: NanoleafInfo) {
        guard demoWorkspaceController.acceptsLiveNetworkCallbacks, info.family != nil else { return }
        let id = "nanoleaf:\(pairing.serial)"
        if device(withID: id) == nil {
            upsert(LightDevice(id: id, brand: .nanoleaf, backendID: pairing.serial,
                               name: info.name, address: pairing.endpoint.host, sku: info.model))
        }
        guard let device = device(withID: id) else { return }
        device.address = pairing.endpoint.host
        device.name = info.name
        device.needsNanoleafPairing = false
        device.nanoleafEffects = info.effects.effectsList
        if let owner = shapes.didRead(deviceID: id, info: info) {
            releaseShapesStream(deviceID: id, owner: owner)
        }
        let color = Color(hue: Double(min(360, max(0, info.state.hue.value))) / 360,
                          saturation: Double(min(100, max(0, info.state.sat.value))) / 100, brightness: 1)
        let rgb = color.rgbComponents
        let brightness = Double(min(100, max(0, info.state.brightness.value))) / 100
        let kelvin = NanoleafProtocol.kelvin(info.state.ct.value)
        let matches = commandCoordinator.reportedStateMatchesExpectation(
            deviceID: id,
            reported: ReportedDeviceState(isOn: info.state.on.value, brightness: brightness,
                                           red: rgb.r, green: rgb.g, blue: rgb.b,
                                           kelvin: kelvin, nanoleafAppearance: info.appearance)
        )
        if !isEffectAnimating(id) && (!commandPendingIDs.contains(id) || matches) {
            device.isOn = info.state.on.value
            device.brightness = brightness
            device.kelvin = kelvin
            // A wall showing LumenDesk's design reports the hue of its last
            // solid colour, which is not what it shows; its swatch is the
            // design's own.
            device.color = shapes.showingDesign(for: id)?.representativeChroma?.swiftUIColor ?? color
            device.nanoleafAppearance = info.appearance
            if info.state.colorMode == "ct" { whiteModeDeviceIDs.insert(id) }
            else { whiteModeDeviceIDs.remove(id) }
        }
        if isScanning { scanResponseCount += 1 }
        markSeen(device, confirmsPendingCommand: matches)
    }

    func expectNanoleafAppearance(_ device: LightDevice, appearance: NanoleafAppearance) {
        guard device.brand == .nanoleaf else { return }
        device.nanoleafAppearance = appearance
        if appearance.colorMode == "ct" { whiteModeDeviceIDs.insert(device.id) }
        else { whiteModeDeviceIDs.remove(device.id) }
        guard demoWorkspaceController.allowsLiveNetworking else { return }
        commandCoordinator.expectNanoleafAppearance(deviceID: device.id, appearance: appearance)
    }

    func selectNanoleafEffect(_ device: LightDevice, name: String) {
        guard device.brand == .nanoleaf, device.nanoleafEffects.contains(name),
              !isEffectAnimating(device.id) else { return }
        recordChange([device])
        device.isOn = true
        sendPower(device, on: true)
        sendNanoleafEffect(device, name: name)
    }

    func sendNanoleafEffect(_ device: LightDevice, name: String) {
        expectNanoleafAppearance(device, appearance: .init(colorMode: "effect", effect: name))
        simulateShapesOutput(device, .nativeEffect(name: name))
        // Share the color coalescing key so a queued color cannot overwrite an
        // effect the user selected afterwards (or vice versa).
        enqueueCommand(for: device, coalescingKey: "color", summary: "Selecting Nanoleaf effect") { [weak self, weak device] in
            guard let self, let device else { return }
            self.shapes.outputReplaced(device.id, by: .nativeEffect(name: name))
            self.nanoleaf.selectEffect(device.backendID, name: name)
        }
    }

    func restoreNanoleafAppearance(_ appearance: NanoleafAppearance?, to device: LightDevice) -> Bool {
        guard device.brand == .nanoleaf, let appearance else { return false }
        if appearance.colorMode == "effect", let effect = appearance.effect {
            sendNanoleafEffect(device, name: effect)
            sendBrightness(device, value: device.brightness)
            return true
        }
        if appearance.colorMode == "ct" {
            sendColorTemperature(device, kelvin: device.kelvin)
            return true
        }
        return false
    }

    // MARK: Shapes panels

    /// Asks a Shapes controller for a fresh reading: layout, orientation and
    /// what it is showing. Nothing is sent in Demo Mode.
    func refreshShapes(_ device: LightDevice) {
        guard device.brand == .nanoleaf else { return }
        refresh(device)
    }

    static func shapesSnapshot(from state: PersistedApplicationState) -> NanoleafShapesController.Snapshot {
        NanoleafShapesController.Snapshot(designs: state.nanoleafDesigns,
                                          savedDesigns: state.nanoleafSavedDesigns,
                                          groups: state.nanoleafPanelGroups,
                                          arrangements: state.nanoleafArrangements)
    }

    /// Shows a per-panel design on a Shapes wall as LumenDesk's own static
    /// layout. Each panel's intensity is part of the design; master
    /// brightness stays on the controller's brightness channel, untouched.
    func applyShapesDesign(_ design: NanoleafPanelDesign, to device: LightDevice,
                           recordUndo: Bool = true, turnOn: Bool = true, announce: Bool = true) {
        guard device.brand == .nanoleaf, let layout = shapes.layout(device.id) else { return }
        if recordUndo {
            if device.isStale {
                publishError("\u{201C}\(device.label)\u{201D} may be offline — command sent anyway.")
            }
            stopEffects(touching: [device.id])
            recordChange([device])
        }
        // An all-dark design is a request for nothing to be lit, so it must
        // not switch the wall on to show it.
        if turnOn, !device.isOn, design.lightsAnyPanel(of: layout) {
            device.isOn = true
            sendPower(device, on: true)
        }
        showShapesDesign(design, on: device)
        if announce {
            let count = design.reconciliation(against: layout).covered.count
            logActivity(.command, title: "Panel design applied", detail: "\(device.label): \(count) panels")
            lastActionSummary = "Painted \(count) panel\(count == 1 ? "" : "s") on \(device.label)"
        }
    }

    /// The one path a design takes to a wall. It shares the colour command's
    /// coalescing key, so a colour queued a moment earlier can never land on
    /// top of the design, or the other way round.
    func showShapesDesign(_ design: NanoleafPanelDesign, on device: LightDevice, transition: Int = 3) {
        if let chroma = design.representativeChroma { device.color = chroma.swiftUIColor }
        // The controller reports a static layout as an effect with a
        // reserved name, which reads back as effect mode and no scene.
        expectNanoleafAppearance(device, appearance: .init(colorMode: "effect"))
        if isDemoMode {
            // Demo commands are simulated and never sent; the simulated
            // wall takes the design as it is queued.
            shapes.show(design, on: device.id, transition: transition)
        }
        enqueueCommand(for: device, coalescingKey: "color", summary: "Painting \(design.panelIDs.count) Nanoleaf panels") { [weak self, weak device] in
            guard let self, let device else { return }
            self.shapes.show(design, on: device.id, transition: transition)
        }
    }

    /// In Demo Mode the solid colour, white or scene that replaces a design
    /// reaches the simulated wall as the command is queued; live, it does so
    /// when the command is actually sent.
    func simulateShapesOutput(_ device: LightDevice, _ output: NanoleafOutputState) {
        guard device.brand == .nanoleaf, isDemoMode else { return }
        shapes.outputReplaced(device.id, by: output)
    }

    /// Puts a Shapes wall's captured output back: LumenDesk's design when it
    /// owned the wall, otherwise a stored scene or white. False when neither
    /// applies, so the caller falls through to the plain colour path.
    func restoreNanoleafOutput(design: NanoleafPanelDesign?, appearance: NanoleafAppearance?,
                                       to device: LightDevice) -> Bool {
        guard device.brand == .nanoleaf else { return false }
        if let design, shapes.layout(device.id) != nil {
            showShapesDesign(design, on: device)
            sendBrightness(device, value: device.brightness)
            return true
        }
        return restoreNanoleafAppearance(appearance, to: device)
    }

    /// Ending an editor preview that had replaced a solid colour or white
    /// puts that colour back.
    func restoreWholeWallAfterPreview(_ deviceID: String) {
        guard let device = device(withID: deviceID) else { return }
        if whiteModeDeviceIDs.contains(deviceID) {
            sendColorTemperature(device, kelvin: device.kelvin)
        } else {
            sendColor(device, color: device.color)
        }
    }

    /// Writes a wall's global orientation and re-aims any running Music Mode
    /// show at the rotated wall. Effects re-read it on every frame.
    func requestShapesOrientation(_ degrees: Int, for device: LightDevice) {
        guard device.brand == .nanoleaf else { return }
        shapes.requestOrientation(degrees, for: device.id)
        musicFixtureCache.removeAll()
        for scope in musicModeController.activeScopeIDs
            where effectRuns[scope]?.ownedDeviceIDs.contains(device.id) == true {
            musicModeController.update(scope: scope, configuration: musicModeConfiguration,
                                       topology: fixtureTopology(for: scope),
                                       fixtures: musicFixtureDescriptors(in: scope),
                                       reducedMotion: effectRuns[scope]?.reducedMotion ?? false)
        }
    }

    /// The wall direction a room's music sweep travels.
    func shapesAxis(for layout: FixtureTopologyLayout) -> NanoleafSpatialAxis {
        switch layout {
        case .leftToRight, .custom: return .leftToRight
        case .frontToBack: return .topToBottom
        case .circular: return .clockwise
        }
    }

    /// Claims a Shapes wall for a show. With a known layout the show streams
    /// panel by panel, and master brightness opens to full: each panel's
    /// level rides in its own colour, and Nanoleaf's master brightness
    /// multiplies every mode, so leaving it down would dim twice. Without a
    /// layout the wall takes the show's whole-wall colour, as it always has.
    func beginShapesShow(_ device: LightDevice, owner: String, perPanel: Bool) {
        guard device.brand == .nanoleaf else { return }
        guard perPanel, shapes.canStream(device.id), let layout = shapes.layout(device.id) else {
            shapes.outputReplaced(device.id, by: .solid)
            return
        }
        shapesStreams[device.id] = ShapesStream(owner: owner, panelIDs: layout.paintablePanels.map(\.panelID))
        shapes.beginStream(device.id, owner: owner)
        sendBrightness(device, value: 1)
    }

    /// Ends a show's streams. With `keepingLastFrame`, the frame on the wall
    /// becomes a static LumenDesk design, so a show that ends without
    /// restoring leaves its final look under a name LumenDesk can account
    /// for, not an external-control session nothing feeds.
    func endShapesStreams(ownedBy owner: String, keepingLastFrame: Bool) {
        for (deviceID, stream) in shapesStreams where stream.owner == owner {
            shapesStreams.removeValue(forKey: deviceID)
            if keepingLastFrame, let device = device(withID: deviceID),
               let design = shapes.lastStreamedDesign(deviceID, owner: owner) {
                if let chroma = design.representativeChroma { device.color = chroma.swiftUIColor }
                shapes.show(design, on: deviceID, transition: 1)
            } else {
                shapes.endStream(deviceID, owner: owner)
            }
        }
    }

    /// Another app took a wall a show was streaming to. The show keeps
    /// running on its other lights but lets this one go: no more frames, its
    /// controls come back, and stopping the show will not "restore" it over
    /// the other app's choice.
    func releaseShapesStream(deviceID: String, owner: String) {
        guard shapesStreams[deviceID]?.owner == owner else { return }
        shapesStreams.removeValue(forKey: deviceID)
        for run in effectRuns.values where run.streamOwner == owner {
            run.releasedDeviceIDs.insert(deviceID)
            run.snapshot.removeAll { $0.deviceID == deviceID }
        }
        let label = device(withID: deviceID)?.label ?? "Nanoleaf panels"
        logActivity(.command, title: "Live output released",
                    detail: "\(label) switched to a scene chosen elsewhere; LumenDesk stopped streaming to it.")
    }

    /// Diagnostics rows for a Shapes or Aurora wall: what was read, what is claimed,
    /// and what the live stream did. None of it is evidence the panels lit.
    func shapesDiagnostics(for device: LightDevice) -> [ScanDiagnostic] {
        guard device.brand == .nanoleaf else { return [] }
        let wall = shapes.wall(device.id)
        var rows: [ScanDiagnostic] = []
        if let layout = wall.arrangement?.layout {
            rows.append(ScanDiagnostic(title: "Panel layout",
                                       value: "\(layout.paintablePanels.count) panels · \(layout.shapeSummary)",
                                       status: wall.topologyProblem == nil ? .good : .warning))
        } else {
            rows.append(ScanDiagnostic(title: "Panel layout", value: "Not read yet", status: .neutral))
        }
        if let problem = wall.topologyProblem {
            rows.append(ScanDiagnostic(title: "Latest layout reading", value: problem.summary, status: .warning))
        }
        rows.append(ScanDiagnostic(title: "Orientation", value: wall.orientation.summary,
                                   status: wall.orientation.isFailed ? .warning : .neutral))
        rows.append(ScanDiagnostic(title: "Showing", value: wall.output.summary, status: .neutral))
        if let family = device.nanoleafFamily {
            rows.append(ScanDiagnostic(title: "Product",
                                       value: "\(family.displayName) · live output over external control \(family.streamProtocol.rawValue)",
                                       status: .neutral))
        }
        if let firmware = wall.firmware {
            rows.append(ScanDiagnostic(title: "Firmware", value: firmware, status: .neutral))
        }
        if let metrics = shapes.streamMetrics(device.id) {
            rows.append(ScanDiagnostic(title: "Live stream",
                                       value: "\(metrics.datagramsSent) datagrams sent · \(metrics.framesCoalesced) frames merged · \(metrics.sendFailures) refused (UDP has no receipt)",
                                       status: metrics.sendFailures > 0 ? .warning : .neutral))
        }
        if let failure = wall.lastFailure {
            rows.append(ScanDiagnostic(title: "Last panel failure", value: failure, status: .warning))
        }
        return rows
    }
}
