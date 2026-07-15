import SwiftUI

struct MusicModeView: View {
    @EnvironmentObject private var manager: LightManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var scope: LightScope
    @State private var configuration = MusicModeConfiguration.configuration(for: .soundcheck)
    @State private var topology = FixtureTopology()
    @State private var advancedExpanded = false
    @State private var showUnsafeWarning = false

    private var fixtures: [MusicFixtureDescriptor] { manager.musicFixtureDescriptors(in: scope) }
    private var isRunning: Bool { manager.activeEffects[scope] == "music-pulse" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            intro
            sourceAndInput
            presetPicker
            MusicModeVisualizerView(
                controller: manager.musicModeController,
                scope: scope,
                fixtures: fixtures
            )
            primaryControls
            topologyEditor
            advancedControls
        }
        .onAppear { reloadForScope() }
        .onChange(of: scope) { _ in reloadForScope() }
        .alert("Disable photosensitivity-safe mode?", isPresented: $showUnsafeWarning) {
            Button("Keep Safe Mode", role: .cancel) {}
            Button("Disable Safe Limits", role: .destructive) {
                configuration.photosensitivitySafeMode = false
                configuration.preset = .custom
                commitConfiguration()
            }
        } message: {
            Text("Music Mode will still enforce its absolute 3 flashes-per-second ceiling and your selected frequency, but flashing can affect people with photosensitivity. Safe Mode is recommended.")
        }
    }

    private var intro: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 15).fill(Lumen.brandGradient)
                Image(systemName: "music.note.list").font(.title).foregroundStyle(.white)
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 5) {
                Text("Music Mode").font(.title2.bold())
                #if os(macOS)
                Text("LumenDesk analyzes system audio locally and choreographs your lights without recording or retaining audio.")
                #else
                Text("LumenDesk analyzes microphone input locally and choreographs your lights without recording or retaining audio.")
                #endif
                Text("Soundcheck remains available as a built-in preset, and saved music-pulse effects remain compatible.")
                    .font(.caption)
                    .foregroundStyle(Lumen.textTertiary)
            }
            .foregroundStyle(Lumen.textSecondary)
            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                Picker("Target scope", selection: $scope) {
                    Text("All Lights").tag(LightScope.all)
                    ForEach(manager.rooms) { room in
                        Text(room.name).tag(LightScope.room(room.id))
                    }
                }
                .fixedSize()
                if isRunning {
                    Button("Stop", role: .destructive) { manager.stopEffect(scope: scope) }
                        .buttonStyle(.bordered)
                } else {
                    Button("Start Music Mode") {
                        commitConfiguration()
                        manager.startMusicMode(
                            configuration: configuration,
                            scope: scope,
                            reducedMotion: reduceMotion
                        )
                    }
                    .buttonStyle(LumenPrimaryButtonStyle())
                    .disabled(fixtures.isEmpty)
                }
            }
        }
        .padding(18)
        .lumenCard(radius: 18, highlighted: isRunning, glowColor: isRunning ? Lumen.pink : nil)
    }

    private var sourceAndInput: some View {
        MusicModeInputStatusView(controller: manager.musicModeController, isRunning: isRunning)
    }

    private var presetPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Preset").font(.headline)
                Spacer()
                Text(configuration.preset.summary)
                    .font(.caption)
                    .foregroundStyle(Lumen.textSecondary)
                    .lineLimit(2)
            }
            Picker("Preset", selection: Binding(
                get: { configuration.preset },
                set: { preset in
                    if preset == .custom {
                        configuration.preset = .custom
                    } else {
                        configuration = .configuration(for: preset)
                        if manager.isDemoMode {
                            configuration.usesSyntheticDemoPattern = manager.musicModeConfiguration.usesSyntheticDemoPattern
                        }
                    }
                    commitConfiguration()
                }
            )) {
                ForEach(MusicModePreset.allCases) { preset in Text(preset.displayName).tag(preset) }
            }
            .pickerStyle(.segmented)
        }
        .padding(16)
        .lumenCard(radius: 16)
    }

    private var primaryControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Show balance").font(.headline)
            musicSlider("Master brightness", value: binding(\.masterBrightness), icon: "sun.max.fill")
            musicSlider("Effect intensity", value: binding(\.effectIntensity), icon: "waveform")
            musicSlider("Beat sensitivity", value: binding(\.beatSensitivity), icon: "metronome.fill")
            musicSlider("Bass sensitivity", value: binding(\.bassSensitivity), icon: "speaker.wave.3.fill")
            musicSlider("Percussion sensitivity", value: binding(\.percussionSensitivity), icon: "hands.clap.fill")
        }
        .padding(16)
        .lumenCard(radius: 16)
    }

    private var topologyEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Spatial topology").font(.headline)
                    Text("Position is explicit and never inferred from discovery order. RGBIC segments continue the path inside their fixture.")
                        .font(.caption).foregroundStyle(Lumen.textSecondary)
                }
                Spacer()
                Picker("Layout", selection: Binding(
                    get: { topology.layout },
                    set: { topology.layout = $0; commitTopology() }
                )) {
                    ForEach(FixtureTopologyLayout.allCases) { Text($0.displayName).tag($0) }
                }
                .fixedSize()
            }

            let ordered = topology.orderedFixtures(fixtures)
            ForEach(Array(ordered.enumerated()), id: \.element.id) { index, fixture in
                HStack(spacing: 10) {
                    Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(Lumen.textTertiary)
                        .frame(width: 20)
                    Image(systemName: fixture.segmentCount > 0 ? "rectangle.split.3x1.fill" : "lightbulb.fill")
                        .foregroundStyle(fixture.segmentCount > 0 ? Lumen.coral : Lumen.violetBright)
                    Text(fixture.label)
                    if fixture.segmentCount > 0 {
                        Text("+ \(fixture.segmentCount) segments").font(.caption).foregroundStyle(Lumen.textTertiary)
                    }
                    Spacer()
                    Button { moveFixture(from: index, offset: -1, ordered: ordered) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless).disabled(index == 0)
                    Button { moveFixture(from: index, offset: 1, ordered: ordered) } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless).disabled(index == ordered.count - 1)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .lumenCard(radius: 16)
    }

    private var advancedControls: some View {
        DisclosureGroup(isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                musicSlider("Color-change intensity", value: binding(\.colorChangeIntensity), icon: "paintpalette.fill")
                musicSlider("Movement amount", value: binding(\.movementAmount), icon: "arrow.left.and.right")
                musicSlider("Movement speed", value: binding(\.movementSpeed), icon: "speedometer")
                Picker("Movement direction", selection: binding(\.movementDirection)) {
                    ForEach(MusicMovementDirection.allCases) { Text($0.displayName).tag($0) }
                }
                musicSlider("Minimum brightness", value: binding(\.minimumBrightness), icon: "sun.min")
                musicSlider("Maximum brightness", value: binding(\.maximumBrightness), icon: "sun.max")

                Divider().overlay(Lumen.hairline)
                Toggle("Allow controlled flashes", isOn: binding(\.allowsFlashes))
                musicSlider("Flash intensity", value: binding(\.flashIntensity), icon: "bolt.fill")
                    .disabled(configuration.photosensitivitySafeMode || !configuration.allowsFlashes)
                HStack {
                    Label("Maximum flash frequency", systemImage: "gauge.with.dots.needle.50percent")
                    Slider(value: frequencyBinding, in: 0...FlashSafetyLimiter.hardMaximumFrequency, step: 0.25)
                    Text(String(format: "%.2f/s", configuration.maximumFlashFrequency))
                        .font(.caption.monospacedDigit()).frame(width: 48, alignment: .trailing)
                }
                .disabled(configuration.photosensitivitySafeMode || !configuration.allowsFlashes)

                Toggle("Photosensitivity-safe mode", isOn: Binding(
                    get: { configuration.photosensitivitySafeMode },
                    set: { enabled in
                        if enabled {
                            configuration.photosensitivitySafeMode = true
                            configuration.preset = .custom
                            commitConfiguration()
                        } else {
                            showUnsafeWarning = true
                        }
                    }
                ))
                Text(configuration.photosensitivitySafeMode
                     ? "Enabled by default: flashes are disabled. Reduced Motion also limits movement and flashes."
                     : "Absolute enforcement remains active: no request can exceed 3 flashes per second or your lower selected limit.")
                    .font(.caption).foregroundStyle(configuration.photosensitivitySafeMode ? Lumen.success : Lumen.warning)

                Divider().overlay(Lumen.hairline)
                Picker("Color palette", selection: paletteBinding) {
                    Text("Soundcheck").tag("soundcheck")
                    Text("Aurora").tag("aurora")
                    Text("Sunset").tag("sunset")
                    Text("Ocean").tag("ocean")
                }
                Picker("Silence behavior", selection: binding(\.silenceBehavior)) {
                    ForEach(MusicSilenceBehavior.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Restore previous state when stopped", isOn: binding(\.restorePreviousState))
                if manager.isDemoMode {
                    Toggle("Use deterministic demo rhythm", isOn: binding(\.usesSyntheticDemoPattern))
                    Text("Turn this off to demonstrate with live audio input. The synthetic pattern contains no copyrighted audio.")
                        .font(.caption).foregroundStyle(Lumen.textSecondary)
                }
            }
            .padding(.top, 14)
        } label: {
            Text("Advanced controls").font(.headline)
        }
        .padding(16)
        .lumenCard(radius: 16)
    }

    private func musicSlider(_ title: String, value: Binding<Double>, icon: String) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: icon).frame(width: 190, alignment: .leading)
            Slider(value: value, in: 0...1)
            Text("\(Int(value.wrappedValue * 100))%")
                .font(.caption.monospacedDigit()).frame(width: 38, alignment: .trailing)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<MusicModeConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { configuration[keyPath: keyPath] },
            set: { value in
                configuration[keyPath: keyPath] = value
                configuration.preset = .custom
                commitConfiguration()
            }
        )
    }

    private var frequencyBinding: Binding<Double> {
        Binding(
            get: { configuration.maximumFlashFrequency },
            set: { configuration.maximumFlashFrequency = $0; configuration.preset = .custom; commitConfiguration() }
        )
    }

    private var paletteBinding: Binding<String> {
        Binding(
            get: {
                if configuration.palette == MusicModeConfiguration.auroraPalette { return "aurora" }
                if configuration.palette == MusicModeConfiguration.sunsetPalette { return "sunset" }
                if configuration.palette == MusicModeConfiguration.oceanPalette { return "ocean" }
                return "soundcheck"
            },
            set: { name in
                switch name {
                case "aurora": configuration.palette = MusicModeConfiguration.auroraPalette
                case "sunset": configuration.palette = MusicModeConfiguration.sunsetPalette
                case "ocean": configuration.palette = MusicModeConfiguration.oceanPalette
                default: configuration.palette = MusicModeConfiguration.soundcheckPalette
                }
                configuration.preset = .custom
                commitConfiguration()
            }
        )
    }

    private func reloadForScope() {
        configuration = manager.musicModeConfiguration
        topology = manager.fixtureTopology(for: scope)
    }

    private func commitConfiguration() {
        manager.setMusicModeConfiguration(configuration)
        configuration = manager.musicModeConfiguration
    }

    private func commitTopology() {
        manager.setFixtureTopology(topology, for: scope)
        topology = manager.fixtureTopology(for: scope)
    }

    private func moveFixture(from index: Int, offset: Int, ordered: [MusicFixtureDescriptor]) {
        let destination = index + offset
        guard ordered.indices.contains(index), ordered.indices.contains(destination) else { return }
        var ids = ordered.map(\.id)
        ids.swapAt(index, destination)
        topology.fixtureOrder = ids
        topology.layout = .custom
        commitTopology()
    }
}

private struct MusicModeInputStatusView: View {
    @ObservedObject var controller: AudioReactiveSessionController
    let isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(controller.sourceStatus.displayName, systemImage: sourceIcon)
                    .font(.headline)
                    .foregroundStyle(statusColor)
                Spacer()
                if isRunning && !controller.isAudioPlaying {
                    Label("No audio playing", systemImage: "speaker.slash.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(Lumen.warning)
                } else if isRunning {
                    Label("Input active", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(Lumen.success)
                }
            }
            meter("Input", value: controller.latestSnapshot.level, color: Lumen.pinkBright)
            HStack(spacing: 12) {
                meter("Bass", value: controller.latestSnapshot.bass, color: Lumen.coral)
                meter("Mids", value: controller.latestSnapshot.mids, color: Lumen.violetBright)
                meter("Highs", value: controller.latestSnapshot.highs, color: Lumen.cyan)
                VStack(spacing: 4) {
                    Circle()
                        .fill(controller.latestSnapshot.beat > 0.25 ? Lumen.goldBright : Lumen.hairlineStrong)
                        .frame(width: 22, height: 22)
                        .shadow(color: Lumen.gold.opacity(controller.latestSnapshot.beat), radius: 8)
                    Text("Beat").font(.caption2).foregroundStyle(Lumen.textTertiary)
                }
                .frame(width: 50)
            }
            if controller.sourceStatus == .permissionDenied {
                Text(permissionMessage)
                    .font(.caption).foregroundStyle(Lumen.warning)
            } else if controller.sourceStatus == .unavailable {
                Text("The audio source is unavailable. Check permission and try starting Music Mode again.")
                    .font(.caption).foregroundStyle(Lumen.warning)
            }
        }
        .padding(16)
        .lumenCard(radius: 16, fill: Lumen.surfaceRaised)
    }

    private func meter(_ label: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Lumen.hairline)
                    Capsule().fill(color.gradient).frame(width: proxy.size.width * max(0, min(1, value)))
                }
            }
            .frame(height: 8)
            Text(label).font(.caption2).foregroundStyle(Lumen.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var sourceIcon: String {
        switch controller.sourceStatus {
        case .systemAudio: return "macbook.and.iphone"
        case .microphone: return "mic.fill"
        case .syntheticDemo: return "waveform.badge.plus"
        case .permissionDenied: return "lock.trianglebadge.exclamationmark"
        case .unavailable: return "exclamationmark.triangle.fill"
        case .idle, .requestingPermission: return "waveform"
        }
    }

    private var permissionMessage: String {
        #if os(macOS)
        return "Screen Recording permission is required to analyze system audio. Enable LumenDesk in System Settings › Privacy & Security › Screen & System Audio Recording."
        #else
        return "Microphone permission is required on iPhone and iPad. Enable LumenDesk in Settings › Privacy & Security › Microphone."
        #endif
    }

    private var statusColor: Color {
        switch controller.sourceStatus {
        case .permissionDenied, .unavailable: return Lumen.warning
        case .systemAudio, .microphone, .syntheticDemo: return Lumen.success
        case .idle, .requestingPermission: return Lumen.textSecondary
        }
    }
}
