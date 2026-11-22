import SwiftUI
import Foundation
import UniformTypeIdentifiers

private enum RoomLiveResponse: String, CaseIterable, Identifiable {
    case calm = "Calm"
    case pulse = "Pulse"
    case spatial = "Spatial"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .calm: return "water.waves"
        case .pulse: return "waveform.path.ecg"
        case .spatial: return "arrow.left.and.right"
        }
    }

    var summary: String {
        switch self {
        case .calm: return "Restrained level and slow palette movement."
        case .pulse: return "Brightness follows the beat without flashes."
        case .spatial: return "Colour travels through room order and addressable surfaces."
        }
    }

    var preset: MusicModePreset {
        switch self {
        case .calm: return .ambient
        case .pulse: return .balanced
        case .spatial: return .cinematic
        }
    }
}

private enum RoomLiveInput: String, CaseIterable, Identifiable {
    case platform = "Playing audio"
    case file = "Audio file"
    case midiClock = "MIDI clock"
    var id: String { rawValue }
}

struct RoomLiveView: View {
    @EnvironmentObject private var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let room: Room
    @State private var response: RoomLiveResponse = .calm
    @State private var studioPreset: MusicModePreset = .ambient
    @State private var input: RoomLiveInput = .platform
    @State private var audioFile: URL? = nil
    @State private var choosingFile: Bool = false
    @State private var confirmingLocalAudio: Bool = false
    @State private var showingStudioControls: Bool = false
    @AppStorage(AppPreferenceKey.audioPrivacyAcknowledged) private var audioAcknowledged = false

    private var scope: LightScope { .room(room.id) }
    private var isRunning: Bool { manager.activeEffects[scope] == "music-pulse" }
    private var roomLights: [LightDevice] { manager.devices(in: room) }
    private var topology: FixtureTopology { manager.fixtureTopology(for: scope) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            GeometryReader { geometry in
                if geometry.size.width >= 760 {
                    HStack(spacing: 0) {
                        stage.padding(12)
                        Rectangle().fill(Polar.ruleSoft).frame(width: 1)
                        ScrollView { responseColumn }
                            .frame(width: 290)
                            .background(Polar.deck)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            stage.frame(height: 320).padding(12)
                            responseColumn
                        }
                    }
                }
            }
        }
        .background(Polar.stage)
        .font(.polarUI(13))
        .foregroundStyle(Polar.chalk)
        .sheetFrame(minWidth: 620, idealWidth: 960, minHeight: 560, idealHeight: 640)
        .onAppear {
            studioPreset = manager.musicModeConfiguration.preset == .custom
                ? response.preset
                : manager.musicModeConfiguration.preset
            if let matched = RoomLiveResponse.allCases.first(where: { $0.preset == studioPreset }) {
                response = matched
            }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result { audioFile = url }
        }
        .alert("Local audio analysis", isPresented: $confirmingLocalAudio) {
            Button("Cancel", role: .cancel) {}
            Button("Continue") {
                audioAcknowledged = true
                start()
            }
        } message: {
            Text("LumenDesk analyzes audio on this device to drive the selected room. It does not retain recordings.")
        }
    }

    // MARK: Polar layout

    private var topBar: some View {
        HStack(spacing: 8) {
            Text("Input")
                .font(.polarUI(12))
                .foregroundStyle(Polar.meter)
            ForEach(RoomLiveInput.allCases) { item in
                Button(inputTitle(item)) { input = item }
                    .buttonStyle(PolarButtonStyle(kind: input == item ? .prominent : .quiet, compact: true))
                    .disabled(isRunning && input != item)
                    .accessibilityAddTraits(input == item ? .isSelected : [])
            }
            if input == .file {
                Text(audioFile?.lastPathComponent ?? "No file chosen")
                    .font(.polarUI(11))
                    .foregroundStyle(Polar.meter)
                    .lineLimit(1)
                Button("Choose\u{2026}") { choosingFile = true }
                    .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
                    .disabled(isRunning)
            }
            Spacer()
            if isRunning {
                Button {
                    stop()
                } label: {
                    HStack(spacing: 6) {
                        Text("\u{2318}.")
                            .font(.polarMono(10, weight: .semibold))
                            .padding(.horizontal, 4)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Polar.raised))
                        Text("Stop")
                    }
                }
                .buttonStyle(PolarButtonStyle(kind: .danger, compact: true))
                .keyboardShortcut(".", modifiers: .command)
            }
            Button("Done") { dismiss() }
                .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, PolarSpacing.md)
        .padding(.vertical, 10)
        .background(Polar.desk)
        .overlay(alignment: .bottom) { Rectangle().fill(Polar.ruleSoft).frame(height: 1) }
    }

    /// The room as light: each fixture's glow at its place on the plan,
    /// with the session state in the middle.
    private var stage: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: Polar.radiusStage, style: .continuous)
                    .fill(Polar.stage)
                PolarStageGrid(spacing: 40)
                    .stroke(Polar.wall.opacity(0.55), lineWidth: 0.5)
                ForEach(roomLights) { light in
                    let anchor = manager.planAnchor(for: light.id, in: room)
                    LiveStageGlow(light: light, size: min(geometry.size.width, geometry.size.height) * 0.55)
                        .position(x: geometry.size.width * (0.1 + 0.8 * anchor.x),
                                  y: geometry.size.height * (0.1 + 0.8 * anchor.y))
                }
                VStack(spacing: 6) {
                    Text("\(isRunning ? "Listening" : "Ready") \u{00B7} \(response.rawValue)")
                        .font(.polarDisplay(22, weight: .bold))
                    Text(roomLights.isEmpty ? "No lights in \(room.name) yet"
                                            : roomLights.prefix(6).map(\.label).joined(separator: " \u{00B7} "))
                        .font(.polarUI(12))
                        .foregroundStyle(Polar.meter)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: geometry.size.width * 0.7)
                    Text(input == .midiClock
                         ? "Follows CoreMIDI beat clock (24 PPQN) from a DAW or sequencer."
                         : platformInputDetail)
                        .font(.polarUI(11))
                        .foregroundStyle(Polar.meter.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: geometry.size.width * 0.6)
                        .opacity(isRunning ? 0 : 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Polar.radiusStage, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Polar.radiusStage, style: .continuous)
                .stroke(Polar.ruleSoft, lineWidth: 1))
        }
        .accessibilityElement(children: .combine)
    }

    private var responseColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            PolarSectionLabel("Response")
            ForEach(RoomLiveResponse.allCases) { item in
                let chosen = studioPreset == item.preset
                Button {
                    response = item
                    studioPreset = item.preset
                    if isRunning { manager.applyMusicModePreset(item.preset) }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(chosen ? Polar.select : Polar.meter)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.rawValue).font(.polarUI(14, weight: .semibold))
                            Text(item.summary)
                                .font(.polarUI(11))
                                .foregroundStyle(Polar.meter)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(chosen ? Polar.accent.opacity(0.14) : Polar.raised.opacity(0.7)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(chosen ? Polar.accent : Polar.ruleSoft, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }

            if manager.isDemoMode && input == .platform {
                HStack {
                    Text("Demo groove").font(.polarUI(12)).lineLimit(1).fixedSize()
                    Spacer()
                    Picker("Demo groove", selection: Binding(
                        get: { manager.musicModeController.selectedGrooveID },
                        set: { manager.musicModeController.setGroove($0) }
                    )) {
                        ForEach(MusicGroove.all) { groove in
                            Text("\(groove.name) \u{00B7} \(Int(groove.bpm)) BPM").tag(groove.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            LiveInputStatus(controller: manager.musicModeController)

            studioChoreographyDrawer

            Button {
                if isRunning {
                    stop()
                } else if manager.isDemoMode || input == .midiClock || audioAcknowledged {
                    start()
                } else {
                    confirmingLocalAudio = true
                }
            } label: {
                Text(isRunning ? "Stop and restore" : "Start Live").frame(maxWidth: .infinity)
            }
            .buttonStyle(PolarButtonStyle(kind: isRunning ? .danger : .prominent))
            .disabled(input == .file && audioFile == nil && !isRunning)
            .padding(.top, 6)

            Text(input == .platform && !manager.isDemoMode
                 ? "Screen & System Audio Recording may be required. Nothing is recorded. Stop always restores the room."
                 : "Live is foreground-only. Stop always restores the room\u{2019}s previous lighting.")
                .font(.polarUI(11))
                .foregroundStyle(Polar.meter)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PolarSpacing.md)
    }

    private var studioChoreographyDrawer: some View {
        DisclosureGroup(isExpanded: $showingStudioControls) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("STUDIO CHOREOGRAPHY PRESET")
                        .font(LumenType.instrumentLabel(size: 10))
                        .tracking(1.1)
                        .foregroundStyle(Lumen.meter)
                    Picker("Preset", selection: Binding(
                        get: { studioPreset },
                        set: { newPreset in
                            studioPreset = newPreset
                            if let matched = RoomLiveResponse.allCases.first(where: { $0.preset == newPreset }) {
                                response = matched
                            }
                            if isRunning {
                                manager.applyMusicModePreset(newPreset)
                            }
                        }
                    )) {
                        ForEach(MusicModePreset.allCases.filter { $0 != .custom }) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(studioPreset.summary)
                        .font(LumenType.body(size: 11))
                        .foregroundStyle(Lumen.meter)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Follow Apple Music & Spotify beat maps", isOn: Binding(
                        get: { manager.musicModeConfiguration.followsPlaybackApps },
                        set: { enabled in
                            var updated = manager.musicModeConfiguration
                            updated.followsPlaybackApps = enabled
                            manager.setMusicModeConfiguration(updated)
                        }
                    ))
                    .font(LumenType.body(size: 13, weight: .semibold))
                    Text(manager.musicModeController.beatMapStatus.summary)
                        .font(LumenType.body(size: 11))
                        .foregroundStyle(Lumen.meter)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Light timing offset")
                            .font(LumenType.body(size: 13, weight: .semibold))
                        Spacer()
                        let offsetMS = Int((manager.musicModeConfiguration.outputLatencyOffset * 1000).rounded())
                        Text("\(offsetMS >= 0 ? "+" : "")\(offsetMS) ms")
                            .font(LumenType.readout(size: 11, weight: .semibold))
                            .foregroundStyle(Lumen.meter)
                    }
                    Slider(
                        value: Binding(
                            get: { manager.musicModeConfiguration.outputLatencyOffset },
                            set: { newValue in
                                var updated = manager.musicModeConfiguration
                                updated.outputLatencyOffset = newValue
                                manager.previewMusicModeConfiguration(updated)
                            }
                        ),
                        in: -MusicModeConfiguration.latencyOffsetLimit ... MusicModeConfiguration.latencyOffsetLimit,
                        onEditingChanged: { editing in
                            if !editing {
                                manager.setMusicModeConfiguration(manager.musicModeConfiguration)
                            }
                        }
                    )
                    .tint(Lumen.ember)

                    HStack(spacing: 10) {
                        Button("Tap Light Pulse") {
                            manager.musicModeController.recordCalibrationTap(scope: scope)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!manager.musicModeController.hasCalibrationGrid(for: scope))

                        if let suggested = manager.musicModeController.calibratedLatencyOffset(
                            from: manager.musicModeConfiguration.outputLatencyOffset,
                            scope: scope
                        ) {
                            let suggestedMS = Int((suggested * 1000).rounded())
                            Button("Apply \(suggestedMS >= 0 ? "+" : "")\(suggestedMS) ms") {
                                var updated = manager.musicModeConfiguration
                                updated.outputLatencyOffset = suggested
                                manager.setMusicModeConfiguration(updated)
                                manager.musicModeController.resetCalibrationTaps()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Lumen.verdigris)
                            .controlSize(.small)
                        } else {
                            let taps = manager.musicModeController.calibrationTapCount(for: scope)
                            Text(taps > 0 ? "\(taps) tap\(taps == 1 ? "" : "s") recorded" : "Tap with the visible light pulse while running to calibrate network latency.")
                                .font(LumenType.body(size: 11))
                                .foregroundStyle(Lumen.meter)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Photosensitivity safe mode (clamp rapid flashes)", isOn: Binding(
                        get: { manager.musicModeConfiguration.photosensitivitySafeMode },
                        set: { safe in
                            var updated = manager.musicModeConfiguration
                            updated.photosensitivitySafeMode = safe
                            manager.setMusicModeConfiguration(updated)
                        }
                    ))
                    .font(LumenType.body(size: 13, weight: .semibold))

                    Toggle("Allow downbeat flash accents", isOn: Binding(
                        get: { manager.musicModeConfiguration.allowsFlashes },
                        set: { flashes in
                            var updated = manager.musicModeConfiguration
                            updated.allowsFlashes = flashes
                            if flashes && updated.flashIntensity == 0 {
                                updated.flashIntensity = 0.42
                                updated.maximumFlashFrequency = 1.5
                            }
                            manager.setMusicModeConfiguration(updated)
                        }
                    ))
                    .font(LumenType.body(size: 13))
                    .disabled(manager.musicModeConfiguration.photosensitivitySafeMode)
                }

                if !roomLights.isEmpty {
                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("ROOM SWEEP & FIXTURE ROLES")
                                .font(LumenType.instrumentLabel(size: 10))
                                .tracking(1.1)
                                .foregroundStyle(Lumen.meter)
                            Spacer()
                            Picker("Sweep", selection: Binding(
                                get: { topology.layout },
                                set: { newLayout in
                                    var updated = topology
                                    updated.layout = newLayout
                                    manager.setFixtureTopology(updated, for: scope)
                                }
                            )) {
                                ForEach(FixtureTopologyLayout.allCases) { layout in
                                    Text(layout.displayName).tag(layout)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                        }

                        ForEach(roomLights) { light in
                            HStack {
                                Circle()
                                    .fill(light.isOn ? light.color : Lumen.rule)
                                    .frame(width: 10, height: 10)
                                Text(light.label)
                                    .font(LumenType.body(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                Spacer()
                                Picker(light.label, selection: Binding(
                                    get: { topology.role(for: light.id) },
                                    set: { newRole in
                                        var updated = topology
                                        if newRole == .auto {
                                            updated.roles.removeValue(forKey: light.id)
                                        } else {
                                            updated.roles[light.id] = newRole
                                        }
                                        manager.setFixtureTopology(updated, for: scope)
                                    }
                                )) {
                                    ForEach(FixtureRole.allCases) { role in
                                        Text(role.displayName).tag(role)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 118)
                                .disabled(isRunning && (topology.role(for: light.id) == .off))
                            }
                        }
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Studio sync & choreography")
                        .font(.polarUI(13, weight: .semibold))
                    Text("Beat-map sync, latency calibration, fixture roles & sweep direction")
                        .font(LumenType.body(size: 11))
                        .foregroundStyle(Lumen.meter)
                }
                Spacer()
                Text(studioPreset.displayName)
                    .font(LumenType.readout(size: 11, weight: .semibold))
                    .foregroundStyle(Lumen.ember)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Polar.desk))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Polar.ruleSoft, lineWidth: 1))
    }

    private func inputTitle(_ input: RoomLiveInput) -> String {
        switch input {
        case .platform:
            #if os(macOS)
            return "System audio"
            #else
            return "Microphone"
            #endif
        case .file: return "Audio file"
        case .midiClock: return "MIDI clock"
        }
    }

    private var platformInputDetail: String {
        if manager.isDemoMode { return "Sample Room uses a synthetic rhythm and never opens an audio source." }
        #if os(macOS)
        return "Audio is analyzed locally from the Mac system-audio capture. Screen & System Audio Recording permission may be required."
        #else
        return "Audio is analyzed locally from this device’s microphone. Microphone permission may be required."
        #endif
    }

    private func start() {
        let current = manager.musicModeConfiguration
        var configuration = MusicModeConfiguration.configuration(for: studioPreset)
            .preservingRoomCalibration(from: current)
        configuration.restorePreviousState = true
        configuration.photosensitivitySafeMode = current.photosensitivitySafeMode
        if current.photosensitivitySafeMode {
            configuration.allowsFlashes = false
            configuration.flashIntensity = 0
            configuration.maximumFlashFrequency = 0
        } else {
            configuration.allowsFlashes = current.allowsFlashes
        }
        configuration.usesSyntheticDemoPattern = manager.isDemoMode && input == .platform
        let capture: MusicCapturePreference
        switch input {
        case .file:
            capture = audioFile.map { .file($0) } ?? .platformDefault
        case .midiClock:
            capture = .midiClock
        case .platform:
            capture = .platformDefault
        }
        manager.startMusicMode(configuration: configuration, scope: scope,
                               reducedMotion: reduceMotion, capture: capture)
    }

    private func stop() {
        manager.stopEffect(scope: scope, restore: true)
    }
}

private struct LiveInputStatus: View {
    @ObservedObject var controller: AudioReactiveSessionController

    var body: some View {
        let snapshot = controller.latestSnapshot
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.sourceStatus.displayName)
                        .font(LumenType.body(size: 13, weight: .semibold))
                    Text(controller.beatMapStatus.isPlayingMap
                         ? controller.beatMapStatus.summary
                         : controller.inputHealth.displayName)
                        .font(LumenType.body(size: 11))
                        .foregroundStyle(Lumen.meter)
                }
                Spacer()
                if controller.sourceStatus.isActiveCapture {
                    if snapshot.tempo > 0 {
                        Text("\(Int(snapshot.tempo.rounded())) BPM · \(max(1, snapshot.metre))/4")
                            .font(LumenType.readout(size: 10, weight: .semibold))
                            .foregroundStyle(Lumen.graphite)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Lumen.canvas, in: Capsule())
                    }
                    Text("LIVE")
                        .font(LumenType.instrumentLabel(size: 10))
                        .foregroundStyle(Lumen.ember)
                }
            }

            if controller.sourceStatus.isActiveCapture {
                HStack(spacing: 14) {
                    HStack(spacing: 5) {
                        let metre = max(2, min(8, snapshot.metre))
                        ForEach(0..<metre, id: \.self) { beat in
                            let isActiveBeat = (snapshot.beatInBar % metre) == beat && snapshot.tempo > 0
                            Circle()
                                .fill(isActiveBeat ? (beat == 0 ? Lumen.ember : Lumen.verdigris) : Lumen.graphite.opacity(0.18))
                                .frame(width: beat == 0 ? 8 : 6, height: beat == 0 ? 8 : 6)
                        }
                    }

                    Spacer()

                    HStack(spacing: 10) {
                        telemetryBar(label: "LOW", value: snapshot.bass, tint: Lumen.ember)
                        telemetryBar(label: "MID", value: snapshot.mids, tint: Lumen.ochre)
                        telemetryBar(label: "HIGH", value: snapshot.highs, tint: Lumen.verdigris)
                    }
                }
            }
        }
        .padding(14)
        .background(statusColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(statusColor.opacity(0.35), lineWidth: 1))
    }

    private func telemetryBar(label: String, value: Double, tint: Color) -> some View {
        let clamped = max(0, min(1, value))
        return HStack(spacing: 4) {
            Text(label)
                .font(LumenType.instrumentLabel(size: 8))
                .foregroundStyle(Lumen.meter)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Lumen.graphite.opacity(0.14))
                    .frame(width: 34, height: 5)
                Capsule()
                    .fill(tint)
                    .frame(width: max(3, 34 * clamped), height: 5)
            }
        }
    }

    private var statusSymbol: String {
        switch controller.sourceStatus {
        case .permissionDenied, .unavailable: return "exclamationmark.triangle.fill"
        case .idle: return "waveform"
        case .midiClock: return "metronome.fill"
        default: return "waveform.circle.fill"
        }
    }

    private var statusColor: Color {
        switch controller.sourceStatus {
        case .permissionDenied, .unavailable: return Lumen.fail
        case .idle: return Lumen.graphite
        default: return Lumen.verdigris
        }
    }
}

/// One fixture's glow on the Live stage. Observes the light so the glow
/// follows what a running session is doing to it.
private struct LiveStageGlow: View {
    @ObservedObject var light: LightDevice
    let size: CGFloat

    var body: some View {
        let lit = light.isOn && !light.isStale
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [light.color.opacity(lit ? 0.30 * (0.4 + light.brightness * 0.6) : 0), .clear],
                                     center: .center, startRadius: 4, endRadius: size / 2))
                .frame(width: size, height: size)
            GlowingOrb(color: light.color, level: light.brightness, isOn: light.isOn,
                       silhouette: LightPageModel.resolve(light).silhouette, size: 14, stale: light.isStale)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
