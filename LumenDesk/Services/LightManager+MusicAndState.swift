import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Music Mode

extension LightManager {
    var musicLIFXDispatch: MusicDispatchMetrics.Snapshot { lifx?.musicMetrics.snapshot() ?? .init() }
    var musicGoveeDispatch: MusicDispatchMetrics.Snapshot { govee?.musicMetrics.snapshot() ?? .init() }
    var musicRenderDiagnostics: MusicLightingRenderer.Diagnostics { musicLightingRenderer.diagnostics }

    /// The platform's Reduce Motion switch.
    static var systemReducesMotion: Bool {
        #if os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        UIAccessibility.isReduceMotionEnabled
        #endif
    }

    /// Follows the system setting for the life of the manager, so a change
    /// reaches running shows whether or not the Music screen is open.
    func observeSystemReduceMotion() {
        #if os(macOS)
        let center = NSWorkspace.shared.notificationCenter
        let name = NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        #else
        let center = NotificationCenter.default
        let name = UIAccessibility.reduceMotionStatusDidChangeNotification
        #endif
        reduceMotionObserver = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let enabled = LightManager.systemReducesMotion
                if enabled != self.reducesMotion { self.setMusicReducedMotion(enabled) }
            }
        }
    }

    /// Applies Reduce Motion to every running show. The system observer calls
    /// this; tests call it directly.
    func setMusicReducedMotion(_ enabled: Bool) {
        reducesMotion = enabled
        for scope in musicModeController.activeScopeIDs { effectRuns[scope]?.reducedMotion = enabled }
        refreshMusicSessions()
    }

    func setMusicModeConfiguration(_ configuration: MusicModeConfiguration) {
        previewMusicModeConfiguration(configuration)
        persistApplicationState()
    }

    /// Applies a configuration to running shows without writing it to disk.
    /// A fader drag reports dozens of values a second, and saving each one
    /// rewrote the whole state file on the main thread that also runs the
    /// lighting timer. The release commits with `setMusicModeConfiguration`.
    func previewMusicModeConfiguration(_ configuration: MusicModeConfiguration) {
        musicModeConfiguration = configuration.normalized()
        refreshMusicSessions()
    }

    func refreshMusicSessions() {
        for scope in musicModeController.activeScopeIDs {
            effectRuns[scope]?.restorePreviousState = musicModeConfiguration.restorePreviousState
            musicModeController.update(
                scope: scope,
                configuration: musicModeConfiguration,
                topology: fixtureTopology(for: scope),
                fixtures: musicFixtureDescriptors(in: scope),
                reducedMotion: effectRuns[scope]?.reducedMotion ?? reducesMotion
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
        // A preset describes the show, not the setup: keep the app-wide light
        // timing and the Spotify and Music choice.
        setMusicModeConfiguration(MusicModeConfiguration.configuration(for: preset)
            .preservingRoomCalibration(from: musicModeConfiguration))
    }

    func fixtureTopology(for scope: LightScope) -> FixtureTopology {
        fixtureTopologies[topologyKey(for: scope)] ?? FixtureTopology()
    }

    func setFixtureTopology(_ topology: FixtureTopology, for scope: LightScope) {
        let available = Set(musicFixtureDescriptors(in: scope).map(\.id))
        var normalized = topology
        normalized.fixtureOrder = topology.fixtureOrder.filter(available.contains)
        normalized.excludedFixtureIDs = topology.excludedFixtureIDs.intersection(available)
        if effectRuns[scope]?.effect.id == "music-pulse" {
            // A running show has already powered, snapshotted, and taken
            // ownership of exactly its non-excluded fixtures at start
            // (`EffectRun.animatedDeviceIDs`). Changing exclusion mid-show
            // would target a newly-included fixture with color frames
            // without ever powering it on, and without a snapshot to
            // restore it from on stop. The UI disables this while running;
            // keep the currently-active exclusion set here too as a
            // backstop. Order and layout remain safe to change live.
            // `fixtureTopology(for:)` (not a raw dictionary lookup) so a
            // scope with nothing persisted yet correctly freezes to no
            // exclusions rather than falling through to the new value.
            let activeTopology = fixtureTopology(for: scope)
            normalized.excludedFixtureIDs = activeTopology.excludedFixtureIDs
            for id in available where (activeTopology.role(for: id) == .off) != (normalized.role(for: id) == .off) {
                normalized.roles[id] = activeTopology.roles[id]
            }
        }
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
        let topology = fixtureTopology(for: scope)
        return devices(in: scope).map { device in
            let role = topology.role(for: device.id)
            if device.isLIFXLuna, let matrix = lifxMatrixState(for: device) {
                return MusicFixtureDescriptor(
                    id: device.id, label: device.label, transport: .lifxLAN,
                    segmentCount: matrix.zoneCount, role: role,
                    segmentPositions: matrix.activeZoneIndices.map { zone in
                        topology.layout == .frontToBack
                            ? Double(zone / matrix.width) / Double(max(1, matrix.height - 1))
                            : Double(zone % matrix.width) / Double(max(1, matrix.width - 1))
                    }
                )
            }
            if device.brand == .govee, segmentProfile(for: device) != nil {
                return MusicFixtureDescriptor(
                    id: device.id,
                    label: device.label,
                    transport: .goveeRealtimeSegments,
                    segmentCount: segmentState(for: device).segmentCount,
                    role: role
                )
            }
            if device.brand == .nanoleaf, shapes.canStream(device.id), let layout = shapes.layout(device.id) {
                // Segment i is the i-th light panel by ID, a numbering that
                // never moves; where it sits on the wall, as oriented, comes
                // from the layout along the room's own sweep direction.
                let orientation = Double(shapes.displayOrientation(device.id))
                var positions = layout.spatialPositions(rotationDegrees: orientation,
                                                       axis: shapesAxis(for: topology.layout))
                if positions.count > 1,
                   let first = positions.first, let last = positions.last,
                   last.position - first.position < 0.001 {
                    // A vertical wall has no horizontal span (and vice versa).
                    // Use its other physical axis rather than a uniform color.
                    positions = layout.spatialPositions(rotationDegrees: orientation,
                        axis: topology.layout == .frontToBack ? .leftToRight : .topToBottom)
                }
                let placed = Dictionary(
                    positions.map { ($0.panelID, $0.position) },
                    uniquingKeysWith: { first, _ in first })
                let panels = layout.paintablePanels
                return MusicFixtureDescriptor(
                    id: device.id,
                    label: device.label,
                    transport: .nanoleafStream,
                    segmentCount: panels.count,
                    role: role,
                    segmentPositions: panels.map { placed[$0.panelID] ?? 0.5 }
                )
            }
            return MusicFixtureDescriptor(
                id: device.id,
                label: device.label,
                transport: device.brand == .nanoleaf ? .nanoleafLAN : (device.brand == .lifx ? .lifxLAN : .goveeLAN),
                role: role
            )
        }
    }

    func topologyKey(for scope: LightScope) -> String {
        switch scope {
        case .all: return "all"
        case .room(let roomID): return "room:\(roomID.uuidString.lowercased())"
        }
    }

    func cachedMusicFixtures(in scope: LightScope, runID: UUID, at timestamp: TimeInterval) -> [MusicFixtureDescriptor] {
        if let cached = musicFixtureCache[scope], cached.runID == runID,
           timestamp >= cached.builtAt, timestamp - cached.builtAt < 1 {
            return cached.fixtures
        }
        let fixtures = musicFixtureDescriptors(in: scope)
        musicFixtureCache[scope] = MusicFixtureCache(runID: runID, builtAt: timestamp, fixtures: fixtures)
        return fixtures
    }

    func renderMusicFrame(_ frame: MusicLightingFrame, scope: LightScope) {
        guard let run = effectRuns[scope], run.effect.id == "music-pulse" else { return }
        let fixtures = cachedMusicFixtures(in: scope, runID: run.id, at: frame.timestamp)
        let ownedIDs = run.ownedDeviceIDs
        // Ownership and reachability stay per frame: they are cheap, and a
        // light that drops out must stop receiving frames at once.
        let activeFixtures = fixtures.filter { ownedIDs.contains($0.id) && device(withID: $0.id)?.isStale == false }
        let commands = musicLightingRenderer.enqueue(frame, fixtures: activeFixtures, at: ProcessInfo.processInfo.systemUptime)
        for command in commands {
            guard let device = device(withID: command.fixtureID), let first = command.states.first else { continue }
            let color = Color(hue: first.hue, saturation: first.saturation, brightness: 1)
            if frame.timestamp - (musicModelUpdateAt[device.id] ?? -Double.greatestFiniteMagnitude) >= 0.2 {
                device.color = color
                device.brightness = first.brightness
                musicModelUpdateAt[device.id] = frame.timestamp
            }

            switch command.transport {
            case .goveeLAN:
                guard demoWorkspaceController.allowsLiveNetworking else { continue }
                let rgb = color.rgbComponents
                govee?.sendMusicColor(deviceID: device.backendID,
                    r: Int(rgb.r * 255 * first.brightness), g: Int(rgb.g * 255 * first.brightness),
                    b: Int(rgb.b * 255 * first.brightness))
            case .lifxLAN:
                if first.segmentID != nil, var matrix = lifxMatrixState(for: device) {
                    let zones = matrix.activeZoneIndices
                    for state in command.states {
                        guard let segment = state.segmentID, zones.indices.contains(segment) else { continue }
                        matrix.colors[zones[segment]] = LIFXMatrixColor(
                            hue: UInt16((state.hue * 65_535).rounded()),
                            saturation: UInt16((state.saturation * 65_535).rounded()),
                            brightness: UInt16((state.brightness * 65_535).rounded()), kelvin: 3_500)
                    }
                    guard demoWorkspaceController.allowsLiveNetworking else { continue }
                    lifx?.setMatrixColors(macHex: device.backendID, colors: matrix.colors.map(\.hsbk),
                        width: matrix.width, durationMS: UInt32((first.transitionDuration * 1000).rounded()),
                        musicTimestamp: frame.timestamp)
                } else {
                    sendEffectFrame(device, color: color, brightness: first.brightness,
                                    duration: first.transitionDuration, musicTimestamp: frame.timestamp)
                }
            case .nanoleafLAN:
                sendEffectFrame(
                    device,
                    color: color,
                    brightness: first.brightness,
                    duration: first.transitionDuration, musicTimestamp: frame.timestamp
                )
            case .nanoleafStream:
                guard let stream = shapesStreams[device.id], !shapes.streamFailed(device.id, owner: stream.owner) else {
                    // The wall's stream never opened: it still follows the
                    // show, as one colour, rather than going dark.
                    sendEffectFrame(device, color: color, brightness: first.brightness,
                                    duration: first.transitionDuration, musicTimestamp: frame.timestamp)
                    continue
                }
                let transition = max(0, min(10, Int((first.transitionDuration * 10).rounded())))
                let frames = command.states.compactMap { state -> NanoleafPanelFrame? in
                    guard let segment = state.segmentID, stream.panelIDs.indices.contains(segment) else { return nil }
                    let rgb = NanoleafPanelColor(hue: state.hue, saturation: state.saturation,
                                                 intensity: state.brightness).rgb
                    return NanoleafPanelFrame(panelID: stream.panelIDs[segment], rgb: rgb, transition: transition)
                }
                shapes.submit(frames, to: device.id, owner: stream.owner)
            case .goveeRealtimeSegments:
                let states = musicCapabilityStates(command.states, fixtureID: command.fixtureID)
                let segments = states.map { GoveeSegmentColor(color: Color(hue: $0.hue, saturation: $0.saturation, brightness: 1), brightness: $0.brightness, isOn: $0.brightness > 0) }
                guard !segments.isEmpty else { continue }
                previewSegments(device, state: GoveeSegmentState(colors: segments, gradient: false, isActive: false))
            }
        }
    }

    /// Shared by transport and preview: firmware masks are visible before send.
    func musicCapabilityStates(_ states: [MusicLightingState], fixtureID: String) -> [MusicLightingState] {
        guard let device = device(withID: fixtureID), device.brand == .govee,
              states.first?.segmentID != nil else { return states }
        let colors = states.map { GoveeSegmentColor(color: Color(hue: $0.hue, saturation: $0.saturation, brightness: 1), brightness: $0.brightness) }
        let constrained = zoneConstrained(GoveeSegmentState(colors: colors, gradient: false, isActive: false), for: device)
        return zip(states, constrained.colors).map { state, segment in
            MusicLightingState(fixtureID: state.fixtureID, segmentID: state.segmentID, hue: state.hue,
                saturation: state.saturation, brightness: segment.isOn ? segment.brightness : 0,
                transitionDuration: state.transitionDuration, priority: state.priority)
        }
    }

    func finishMusicStreaming<S: Sequence>(for deviceIDs: S) where S.Element == String {
        let ids = Set(deviceIDs)
        musicLightingRenderer.reset(fixtureIDs: ids)
        for id in ids {
            musicModelUpdateAt.removeValue(forKey: id)
            if let device = device(withID: id), device.brand == .govee {
                govee?.cancelMusicFrames(deviceID: device.backendID)
            }
            guard let device = device(withID: id),
                  device.brand == .govee,
                  segmentProfile(for: device) != nil else { continue }
            endSegmentPreview(device)
        }
    }
}

// MARK: - Second-pass UX services

extension LightManager {
    func persistApplicationState() {
        deferredPersistenceTask?.cancel()
        deferredPersistenceTask = nil
        guard demoWorkspaceController.allowsLivePersistence else { return }
        try? persistenceStore.save(persistedApplicationState())
    }

    func scheduleDeferredPersistence(delayNanoseconds: UInt64 = 250_000_000) {
        guard demoWorkspaceController.allowsLivePersistence else { return }
        deferredPersistenceTask?.cancel()
        deferredPersistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.deferredPersistenceTask = nil
            self.persistApplicationState()
        }
    }

    func persistedApplicationState() -> PersistedApplicationState {
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
        state.recentColors = recentColors
        state.automationOverrides = automationOverrides
        state.sceneRevisions = sceneRevisions
        state.sceneDrafts = sceneDrafts
        state.goveeSegmentStates = goveeSegmentStates
        state.goveeSegmentPresets = goveeSegmentPresets
        state.musicModeConfiguration = musicModeConfiguration
        state.fixtureTopologies = fixtureTopologies
        let shapesState = shapes.snapshot()
        state.nanoleafDesigns = shapesState.designs
        state.nanoleafSavedDesigns = shapesState.savedDesigns
        state.nanoleafPanelGroups = shapesState.groups
        state.nanoleafArrangements = shapesState.arrangements
        return state
    }

    func applyPersistedApplicationState(_ state: PersistedApplicationState) {
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
        recentColors = state.recentColors
        scheduleEngine.restoreAutomationOverrides(state.automationOverrides)
        sceneRevisions = state.sceneRevisions
        sceneDrafts = state.sceneDrafts
        goveeSegmentStates = state.goveeSegmentStates
        goveeSegmentPresets = state.goveeSegmentPresets
        musicModeConfiguration = state.musicModeConfiguration
        fixtureTopologies = state.fixtureTopologies
        shapes.importSnapshot(Self.shapesSnapshot(from: state))
    }

    func logActivity(_ kind: ActivityEvent.Kind, title: String, detail: String = "", isFailure: Bool = false) {
        activityEvents.insert(ActivityEvent(kind: kind, title: title, detail: detail, isFailure: isFailure), at: 0)
        if activityEvents.count > 250 { activityEvents.removeLast(activityEvents.count - 250) }
    }

    func clearActivity() {
        activityEvents.removeAll()
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
        cancelIdentifications(deviceIDs: [device.id], restore: true)
        let value = boundedBrightness(value)
        device.brightness = value
        brightnessTasks[device.id]?.cancel()
        brightnessTasks[device.id] = Task { @MainActor [weak self, weak device] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self, let device else { return }
            self.sendBrightness(device, value: value)
            self.brightnessTasks[device.id] = nil
        }
    }

    /// Cancels debounced brightness sends so a later undo, scene, or schedule
    /// write is not overwritten by a stale slider flush.
    func cancelPendingBrightness(deviceIDs: Set<String>? = nil) {
        if let deviceIDs {
            for id in deviceIDs {
                brightnessTasks[id]?.cancel()
                brightnessTasks[id] = nil
            }
        } else {
            brightnessTasks.values.forEach { $0.cancel() }
            brightnessTasks = [:]
        }
    }

    var pendingBrightnessDeviceIDsForTesting: Set<String> { Set(brightnessTasks.keys) }

    func commitBrightness(_ device: LightDevice, value: Double) {
        cancelIdentifications(deviceIDs: [device.id], restore: true)
        let value = boundedBrightness(value)
        cancelPendingBrightness(deviceIDs: [device.id])
        device.brightness = value
        sendBrightness(device, value: value)
        logActivity(.command, title: "Brightness changed", detail: "\(device.label): \(Int(value * 100))%")
    }

    func identify(_ device: LightDevice) {
        if device.brand == .nanoleaf, !isDemoMode {
            cancelIdentifications(deviceIDs: [device.id], restore: true)
            // The controller's own identify flashes every panel and then puts
            // back whatever was showing by itself, per-panel design included.
            shapes.identifyWall(device.id)
            logActivity(.recovery, title: "Identifying light", detail: device.label)
            return
        }
        let saved = identifications[device.id]?.snapshot
        cancelIdentifications(deviceIDs: [device.id], restore: true)
        let inherited = stopEffects(touching: [device.id])
        cancelPendingBrightness(deviceIDs: [device.id])
        let original = saved ?? inherited[device.id] ?? snapshot(device)
        let token = UUID()
        identifications[device.id] = Identification(token: token, snapshot: original)
        device.isOn = true
        device.color = .cyan
        device.brightness = 1
        sendPower(device, on: true); sendColor(device, color: .cyan); sendBrightness(device, value: 1)
        logActivity(.recovery, title: "Identifying light", detail: device.label)
        let delay = identifyDurationNanoseconds
        let sleep = identifySleep
        identifications[device.id]?.task = Task { @MainActor [weak self, weak device] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self, let device,
                  self.identifications[device.id]?.token == token else { return }
            self.cancelIdentifications(deviceIDs: [device.id], restore: true)
        }
    }

    // MARK: - Sustained identify

    /// Breathe a fixture until told to stop.
    ///
    /// `identify(_:)` flashes for two seconds, which is right for "which one
    /// is this?" asked about a row on screen. Sorting a rig asks the opposite
    /// question: the user is looking at the room, not at the app, and the
    /// bulb has to stay findable for as long as the question is up.
    ///
    /// It breathes between full and a third rather than strobing, at roughly
    /// 0.7 Hz. That is well under any flash threshold and it reads as "this
    /// one" from the other side of a room without being unpleasant to sit in.
    func beginSustainedIdentify(_ device: LightDevice) {
        endSustainedIdentify()
        cancelIdentifications(deviceIDs: [device.id], restore: true)
        let inherited = stopEffects(touching: [device.id])
        cancelPendingBrightness(deviceIDs: [device.id])
        var hold = IdentifyHold(snapshot: inherited[device.id] ?? snapshot(device), task: nil)
        logActivity(.recovery, title: "Identifying light", detail: device.label)
        hold.task = Task { @MainActor [weak self, weak device] in
            var full = true
            while !Task.isCancelled {
                guard let self, let device else { return }
                let level = full ? 1.0 : 0.35
                device.isOn = true
                device.color = .cyan
                device.brightness = level
                self.sendPower(device, on: true)
                self.sendColor(device, color: .cyan)
                self.sendBrightness(device, value: level)
                full.toggle()
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
        identifyHold = hold
    }

    /// Stop the breathing and restore the fixture, including any held segment
    /// or matrix layout it was carrying before the question was asked.
    func endSustainedIdentify() {
        guard let hold = identifyHold else { return }
        cancelIdentifications(deviceIDs: [hold.snapshot.deviceID], restore: true)
    }

    /// Stops both kinds of identification before another command owns a light.
    /// Removing ownership first makes a cancelled delayed task harmless even
    /// when its injected sleep finishes after a workspace transition.
    func cancelIdentifications(deviceIDs: Set<String>? = nil, restore: Bool) {
        var originals: [LightRuntimeSnapshot] = []
        let ids = deviceIDs ?? Set(identifications.keys)
        for id in ids {
            guard let identification = identifications.removeValue(forKey: id) else { continue }
            identification.task?.cancel()
            originals.append(identification.snapshot)
        }
        if let hold = identifyHold, deviceIDs == nil || ids.contains(hold.snapshot.deviceID) {
            identifyHold = nil
            hold.task?.cancel()
            originals.append(hold.snapshot)
        }
        guard !originals.isEmpty else { return }
        let cancelledIDs = Set(originals.map(\.deviceID))
        commandCoordinator.cancel(deviceIDs: cancelledIDs)
        cancelPendingBrightness(deviceIDs: cancelledIDs)
        if restore { restoreDeviceStates(originals) }
    }

    var identifyingDeviceIDsForTesting: Set<String> { Set(identifications.keys) }

    func retry(_ device: LightDevice) {
        commandCoordinator.recover(deviceID: device.id, timedOut: { [weak self, weak device] in
            guard let self, let device else { return }
            self.publishError("\(device.label) is still not answering. Rescan or check its power and network.")
        }) { [weak self, weak device] in
            guard let self, let device else { return }
            self.refresh(device)
        }
        logActivity(.recovery, title: "Retried unreachable light", detail: device.label)
    }

    func diagnostics(for device: LightDevice) -> [ScanDiagnostic] {
        deviceDiagnostics(for: device) + shapesDiagnostics(for: device)
    }

    func deviceDiagnostics(for device: LightDevice) -> [ScanDiagnostic] {
        [
            ScanDiagnostic(title: "Vendor", value: device.brand.displayName, status: .neutral),
            ScanDiagnostic(title: "Model", value: device.sku ?? "Not reported", status: .neutral),
            ScanDiagnostic(title: "Segment control",
                           value: segmentProfile(for: device).map { "\($0.layout.displayName) · \(segmentState(for: device).segmentCount) segments" } ?? "Not detected",
                           status: .neutral),
            ScanDiagnostic(title: "Address", value: device.address, status: .neutral),
            ScanDiagnostic(title: "Last seen", value: device.lastSeen.formatted(date: .abbreviated, time: .standard), status: device.isStale ? .warning : .good),
            ScanDiagnostic(title: "Reachability", value: device.isStale ? "Not seen recently" : "Responding", status: device.isStale ? .warning : .good),
            ScanDiagnostic(title: "Color temperature", value: device.brand == .nanoleaf ? "1,200–6,500 K" : "2,500–9,000 K", status: .neutral),
            ScanDiagnostic(title: "LAN identifier", value: device.backendID, status: .neutral)
        ]
    }

    var likelyLocalNetworkPermissionIssue: Bool {
        lastScanDate != nil && scanResponseCount == 0 && devices.isEmpty
    }

    /// Why the last scan came back empty, in the user's terms.
    ///
    /// "No devices found" has at least four unrelated causes and the app used
    /// to name only one of them. The probe reports separate "we never got on
    /// the network" from "we probed every host and nothing answered", which are
    /// different problems with different fixes.
    var discoveryFailureHint: String? {
        guard !isDemoMode, !isScanning, lastScanDate != nil, devices.isEmpty else { return nil }

        if !nanoleafCandidates.isEmpty {
            return "Nanoleaf controller found. Open Pair Nanoleaf in Devices to connect it."
        }
        if govee == nil && lifx == nil {
            return "Neither protocol could open a socket. Another app may hold UDP 4002, or the app was denied network access."
        }
        if govee == nil {
            return "Govee could not bind UDP 4002. Quit another local lighting app or a second copy of LumenDesk, then scan again."
        }
        if scanInterfaces.isEmpty {
            return "No active IPv4 network interface. Join a Wi-Fi network or plug in Ethernet, then scan again."
        }

        let reports = [lifxProbe, goveeProbe].compactMap { $0 }
        if reports.isEmpty { return nil }

        // An empty address is not a fault. Sweeping a /24 that holds nine
        // devices means ~245 of them answer "nothing here", which is the
        // sweep working. Only a refusal — no permission, no route to the
        // network, no buffers — says something is wrong with this machine.
        let refusals = reports.reduce(0) { $0 + $1.datagramsFailed }
        let reason = reports.compactMap(\.lastError).first

        if reports.allSatisfy({ !$0.reachedNetwork }) {
            if refusals > 0 {
                return "No probe left this machine (\(reason ?? "every send was refused")). A VPN holding the default route, or a firewall filtering local traffic, is the usual cause."
            }
            return "Every address on \(scanInterfaces.joined(separator: ", ")) came back unreachable. Nothing is responding on this subnet — check that this machine is on the same network as the lights."
        }
        if refusals > 0 {
            return "Probes went out on \(scanInterfaces.joined(separator: ", ")), but \(refusals) send\(refusals == 1 ? " was" : "s were") refused (\(reason ?? "unknown")). A VPN or firewall may be filtering local traffic."
        }
        return "Probes went out on \(scanInterfaces.joined(separator: ", ")) and nothing answered. Check that Local Network access is allowed, that the lights are powered on and on the same network and band (2.4 GHz for Govee), and that LAN control is enabled in the Govee Home app."
    }

    var scanDiagnostics: [ScanDiagnostic] {
        var rows = [
            ScanDiagnostic(title: "LIFX protocol", value: lifx == nil ? "Unavailable" : "Ready on UDP 56700", status: lifx == nil ? .warning : .good),
            ScanDiagnostic(title: "Govee protocol", value: govee == nil ? "Unavailable" : "Ready on UDP 4001–4003", status: govee == nil ? .warning : .good)
        ]
        rows.append(ScanDiagnostic(title: "Nanoleaf Shapes and Aurora", value: nanoleafDiscoveryError ?? "Bonjour discovery · local pairing", status: nanoleafDiscoveryError == nil ? .good : .warning))
        // The probe rows are the difference between "your network has no
        // lights" and "nothing we sent ever left the machine". Without them a
        // wrong interface, a refused route, and a denied Local Network grant
        // all read as an empty room.
        rows.append(networkInterfaceDiagnostic)
        if let lifxProbe { rows.append(probeDiagnostic(title: "LIFX probes", report: lifxProbe)) }
        if let goveeProbe { rows.append(probeDiagnostic(title: "Govee probes", report: goveeProbe)) }
        rows.append(contentsOf: [
            ScanDiagnostic(title: "Last scan", value: lastScanDate?.formatted(date: .abbreviated, time: .standard) ?? "Not yet scanned", status: .neutral),
            ScanDiagnostic(title: "Responses", value: "\(scanResponseCount)", status: scanResponseCount == 0 ? .warning : .good),
            ScanDiagnostic(title: "Discovered lights", value: "\(devices.count)", status: devices.isEmpty ? .warning : .good)
        ])
        return rows
    }

    var networkInterfaceDiagnostic: ScanDiagnostic {
        guard !scanInterfaces.isEmpty else {
            return ScanDiagnostic(title: "Network interface",
                                  value: lastScanDate == nil ? "Not yet scanned" : "No active IPv4 network",
                                  status: lastScanDate == nil ? .neutral : .warning)
        }
        return ScanDiagnostic(title: "Network interface",
                              value: scanInterfaces.joined(separator: ", "),
                              status: .good)
    }

    func probeDiagnostic(title: String, report: DiscoveryProbeReport) -> ScanDiagnostic {
        // Unoccupied addresses are the expected bulk of a sweep, so they do
        // not colour the row; only a refusal, or a pass that never got out at
        // all, does.
        let healthy = report.reachedNetwork && report.datagramsFailed == 0
        return ScanDiagnostic(title: title, value: report.summary,
                              status: healthy ? .good : .warning)
    }

    func updateSchedule(_ entry: ScheduleEntry, in roomID: UUID) {
        guard let roomIndex = rooms.firstIndex(where: { $0.id == roomID }),
              let entryIndex = rooms[roomIndex].schedules.firstIndex(where: { $0.id == entry.id }) else { return }
        rooms[roomIndex].schedules[entryIndex] = entry
        persistApplicationState()
        logActivity(.schedule, title: "Schedule updated", detail: "\(rooms[roomIndex].name): \(entry.daySummary) at \(entry.timeString)")
    }

    func duplicateSchedule(_ entry: ScheduleEntry, in roomID: UUID) {
        guard let roomIndex = rooms.firstIndex(where: { $0.id == roomID }),
              rooms[roomIndex].schedules.count < Self.maximumSchedulesPerRoom else { return }
        let copy = ScheduleEntry(hour: entry.hour, minute: entry.minute, offsetMinutes: entry.offsetMinutes, action: entry.action, weekdays: entry.weekdays)
        rooms[roomIndex].schedules.append(copy); persistApplicationState()
        logActivity(.schedule, title: "Schedule duplicated", detail: rooms[roomIndex].name)
    }

    func testSchedule(_ entry: ScheduleEntry, in room: Room) {
        // A test is a user action standing in for the room controls, so it
        // stays undoable the way those controls are.
        applyScheduleAction(entry.action, to: devices(in: room), recordUndo: true)
        logActivity(.schedule, title: "Schedule tested", detail: "\(room.name): \(entry.action.displayName)")
    }

    /// Shared show-takeover path for real scheduled runs, tests, and missed
    /// catch-up. Stops effects that would repaint over the change and sends
    /// brightness immediately (not the slider debounce). A schedule acts on
    /// the room as it stood before any show: lights taken from a show return
    /// to their saved state first, so the action never freezes a random show
    /// frame into the room or discards the look the show would have restored.
    func applyScheduleAction(_ action: ScheduleAction, to lights: [LightDevice], recordUndo: Bool = false) {
        guard !lights.isEmpty else { return }
        let ids = Set(lights.map(\.id))
        cancelIdentifications(deviceIDs: ids, restore: true)
        let inherited = stopEffects(touching: ids)
        cancelPendingBrightness(deviceIDs: ids)
        restoreDeviceStates(lights.compactMap { inherited[$0.id] })
        if recordUndo { recordChange(lights) }
        switch action {
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
            if let brightness = action.brightnessValue {
                for device in lights {
                    device.brightness = brightness
                    sendBrightness(device, value: brightness)
                }
            }
        }
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

    /// Scenes recall fixture IDs, even when the selected room changes. Use
    /// current room membership to make those targets visible before Apply.
    func sceneScopeSummary(_ scene: LightingScene, selectedScope: LightScope = .all) -> SceneScopeSummary {
        let savedIDs = Set(scene.snapshots.keys)
        var remaining = savedIDs
        var groups: [String] = []
        for room in rooms.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            let ids = remaining.intersection(room.lightIDs)
            guard !ids.isEmpty else { continue }
            groups.append("\(room.name) (\(ids.count))")
            remaining.subtract(ids)
        }
        let knownIDs = Set(devices.map(\.id))
        let unassigned = remaining.intersection(knownIDs).count
        if unassigned > 0 { groups.append("Unassigned (\(unassigned))") }
        let undiscovered = remaining.subtracting(knownIDs).count
        if undiscovered > 0 { groups.append("Undiscovered (\(undiscovered))") }
        let selectedRoom: Room?
        if case .room(let id) = selectedScope { selectedRoom = rooms.first { $0.id == id } }
        else { selectedRoom = nil }
        return SceneScopeSummary(
            description: groups.isEmpty ? "No saved lights" : "Saved fixtures: " + groups.joined(separator: ", "),
            outsideSelectedRoomCount: selectedRoom.map { savedIDs.subtracting($0.lightIDs).count } ?? 0,
            selectedRoomName: selectedRoom?.name
        )
    }

    func availableDeviceIDs(for scene: LightingScene) -> Set<String> {
        Set(devices.lazy.filter { scene.snapshots[$0.id] != nil && !$0.isStale }.map(\.id))
    }

    func applyScene(_ scene: LightingScene, allowTurningOff: Bool, reviewed: Bool = false,
                    allowUnavailableTargets: Bool = false) {
        let preview = scenePreview(scene)
        guard !preview.affected.isEmpty else { publishError("“\(scene.name)” has no discovered lights to change."); return }
        let availableCount = preview.affected.count - preview.unreachable.count
        guard availableCount > 0 || allowUnavailableTargets else {
            publishError("“\(scene.name)” has no currently available lights to change.")
            return
        }
        if !reviewed {
            confirmationCoordinator.request(
                .init(
                    title: "Apply “\(scene.name)”?",
                    message: "\(sceneScopeSummary(scene).description). This scene will change \(availableCount) available light\(availableCount == 1 ? "" : "s")\(preview.unreachable.isEmpty ? "." : "; \(preview.unreachable.count) offline light\(preview.unreachable.count == 1 ? "" : "s") may need retry.") You can undo the change afterward.",
                    confirmTitle: "Apply Scene"
                ),
                action: { [weak self] in self?.applyScene(scene, allowTurningOff: allowTurningOff, reviewed: true) }
            )
            return
        }
        let result = applySceneSnapshots(scene, to: preview.affected, allowTurningOff: allowTurningOff)
        lastSceneResult = SceneApplicationResult(scene: scene, allowTurningOff: allowTurningOff,
                                                succeededIDs: result.succeeded, failedIDs: result.failed,
                                                skippedOffIDs: result.skipped)
        if result.failed.isEmpty {
            lastActionSummary = "Applied Look “\(scene.name)” to \(result.succeeded.count) fixture\(result.succeeded.count == 1 ? "" : "s")"
        } else {
            publishError("Applied “\(scene.name)” to \(result.succeeded.count) fixture\(result.succeeded.count == 1 ? "" : "s"); \(result.failed.count) need\(result.failed.count == 1 ? "s" : "") attention.")
        }
        logActivity(.scene, title: "Scene applied", detail: "\(scene.name): \(result.succeeded.count) succeeded, \(result.failed.count) need retry", isFailure: !result.failed.isEmpty)
    }

    func applySceneSnapshots(_ scene: LightingScene, to lights: [LightDevice], allowTurningOff: Bool)
        -> (succeeded: [String], failed: [String], skipped: [String]) {
        let targets = lights.filter { device in
            guard let snap = scene.snapshots[device.id] else { return false }
            return allowTurningOff || snap.isOn
        }
        let affectedIDs = Set(targets.map(\.id))
        stopEffects(touching: affectedIDs)
        cancelPendingBrightness(deviceIDs: affectedIDs)
        recordChange(targets)
        var succeeded: [String] = [], failed: [String] = [], skipped: [String] = []
        for device in lights {
            guard let snap = scene.snapshots[device.id] else { continue }
            if !allowTurningOff && !snap.isOn { skipped.append(device.id); continue }
            if device.isStale { failed.append(device.id) } else { succeeded.append(device.id) }
            applySceneSnapshot(snap, to: device)
        }
        return (succeeded, failed, skipped)
    }

    func retryLastSceneFailures() {
        guard let result = lastSceneResult, !result.failedIDs.isEmpty else { return }
        let failedIDs = Set(result.failedIDs)
        let failed = devices.filter { failedIDs.contains($0.id) }
        guard !failed.isEmpty else {
            publishError("The failed lights for “\(result.sceneName)” have not been rediscovered yet.")
            return
        }
        for device in failed { refresh(device) }
        let retried = applySceneSnapshots(result.scene, to: failed, allowTurningOff: result.allowTurningOff)
        let succeeded = Set(result.succeededIDs).union(retried.succeeded).sorted()
        let remainingFailures = Set(result.failedIDs).subtracting(retried.succeeded).subtracting(retried.skipped).sorted()
        let skipped = Set(result.skippedOffIDs).union(retried.skipped).sorted()
        // A rename may update the displayed title, but retry always applies
        // the saved version of the scene that produced these failures.
        let sceneName = scenes.first { $0.id == result.sceneID }?.name ?? result.sceneName
        lastSceneResult = SceneApplicationResult(scene: result.scene, allowTurningOff: result.allowTurningOff,
                                                succeededIDs: succeeded, failedIDs: remainingFailures,
                                                skippedOffIDs: skipped, sceneName: sceneName)
        logActivity(.scene, title: "Scene failures retried", detail: "\(sceneName): \(failed.count) retried, \(remainingFailures.count) need retry", isFailure: !remainingFailures.isEmpty)
    }

    func reconcileFavoriteOrder() {
        let active = Set(favoriteIDs.map { FavoriteReference(kind: .light, rawID: $0) }
            + favoriteRooms.map { FavoriteReference(kind: .room, rawID: $0.id.uuidString) }
            + favoriteScenes.map { FavoriteReference(kind: .scene, rawID: $0.id.uuidString) })
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
}

// MARK: - Demo workspace

extension LightManager {
    func enterDemoMode() {
        nanoleaf.pause()
        guard !isDemoMode else { return }
        cancelIdentifications(restore: true)
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
        cancelIdentifications(restore: false)
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
        nanoleaf.discover()
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
        cancelIdentifications(restore: false)
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

    func cancelWorkspaceTasks() {
        scanGeneration += 1
        cancelPendingBrightness()
        commandCoordinator.cancelAllTasks(clearPendingAndExpectations: true)
    }

    func captureWorkspaceState(
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
            segmentPreviewIDs: segmentPreviewIDs,
            scanStartingIDs: scanStartingIDs,
            scanStartingAddresses: scanStartingAddresses,
            nanoleafShapes: shapes.workspaceSnapshot()
        )
    }

    func applyWorkspaceState(_ workspace: DemoWorkspaceController.WorkspaceState) {
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
        segmentPreviewIDs = workspace.segmentPreviewIDs
        scanStartingIDs = workspace.scanStartingIDs
        scanStartingAddresses = workspace.scanStartingAddresses
        // Shows were stopped before the swap, so no stream belongs to the
        // workspace arriving.
        shapesStreams = [:]
        shapes.restoreWorkspace(workspace.nanoleafShapes)
    }
}
