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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("LIVE")
                            .font(LumenType.instrumentLabel(size: 10))
                            .tracking(1.4)
                            .foregroundStyle(Lumen.ember)
                        Text(room.name)
                            .font(LumenType.display(size: 31, weight: .bold))
                        Text("Choose an audio or clock input and a room response. Stop always restores the room to its opening state.")
                            .font(LumenType.body(size: 13))
                            .foregroundStyle(Lumen.meter)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Input").font(LumenType.display(size: 19, weight: .bold))
                        Picker("Input", selection: $input) {
                            ForEach(RoomLiveInput.allCases) { item in
                                Text(inputTitle(item)).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(isRunning)
                        if input == .file {
                            HStack {
                                Text(audioFile?.lastPathComponent ?? "No audio file selected")
                                    .font(LumenType.body(size: 12))
                                    .foregroundStyle(Lumen.meter)
                                    .lineLimit(1)
                                Spacer()
                                Button("Choose file") { choosingFile = true }
                                    .buttonStyle(.bordered)
                                    .disabled(isRunning)
                            }
                        } else if input == .midiClock {
                            Text("Locks room choreography to incoming CoreMIDI beat clock (24 PPQN) from DAWs or hardware sequencers.")
                                .font(LumenType.body(size: 12))
                                .foregroundStyle(Lumen.meter)
                        } else {
                            Text(platformInputDetail)
                                .font(LumenType.body(size: 12))
                                .foregroundStyle(Lumen.meter)
                            if manager.isDemoMode {
                                HStack {
                                    Text("Demo groove")
                                        .font(LumenType.body(size: 12, weight: .semibold))
                                    Spacer()
                                    Picker("Demo groove", selection: Binding(
                                        get: { manager.musicModeController.selectedGrooveID },
                                        set: { manager.musicModeController.setGroove($0) }
                                    )) {
                                        ForEach(MusicGroove.all) { groove in
                                            Text("\(groove.name) · \(Int(groove.bpm)) BPM (\(groove.metre)/4)")
                                                .tag(groove.id)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(maxWidth: 260)
                                }
                            }
                        }
                    }
                    .padding(16)
                    .background(Lumen.floor, in: RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Response").font(LumenType.display(size: 19, weight: .bold))
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(RoomLiveResponse.allCases) { item in
                                Button {
                                    response = item
                                    studioPreset = item.preset
                                    if isRunning {
                                        manager.applyMusicModePreset(item.preset)
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Image(systemName: item.symbol)
                                            .font(.system(size: 20, weight: .semibold))
                                        Text(item.rawValue)
                                            .font(LumenType.display(size: 18, weight: .bold))
                                        Text(item.summary)
                                            .font(LumenType.body(size: 11))
                                            .foregroundStyle(Lumen.meter)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
                                    .padding(14)
                                    .background(Lumen.floor, in: RoundedRectangle(cornerRadius: 11))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 11)
                                            .stroke(studioPreset == item.preset ? Lumen.ember : Lumen.rule,
                                                    lineWidth: studioPreset == item.preset ? 2 : 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
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
                        Label(isRunning ? "Stop and restore" : "Start live response",
                              systemImage: isRunning ? "stop.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isRunning ? Lumen.graphite : Lumen.ember)
                    .controlSize(.large)
                    .disabled(input == .file && audioFile == nil && !isRunning)

                    Text("Live is immediate and foreground-only. Stop always restores the room's previous lighting state.")
                        .font(LumenType.body(size: 11))
                        .foregroundStyle(Lumen.meter)
                }
                .padding(22)
            }
            .background(Lumen.canvas)
            .navigationTitle("Live")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                studioPreset = manager.musicModeConfiguration.preset == .custom
                    ? response.preset
                    : manager.musicModeConfiguration.preset
                if let matched = RoomLiveResponse.allCases.first(where: { $0.preset == studioPreset }) {
                    response = matched
                }
            }
        }
        .font(LumenType.body())
        .foregroundStyle(Lumen.graphite)
        .sheetFrame(minWidth: 620, idealWidth: 780, minHeight: 580, idealHeight: 740)
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
                    Text("Studio Sync & Choreography")
                        .font(LumenType.display(size: 16, weight: .bold))
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
        .padding(16)
        .background(Lumen.floor, in: RoundedRectangle(cornerRadius: 12))
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
