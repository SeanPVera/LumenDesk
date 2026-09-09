import SwiftUI
import UniformTypeIdentifiers

struct MusicModeView: View {
    @EnvironmentObject private var manager: LightManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var scope: LightScope
    @State private var configuration = MusicModeConfiguration.configuration(for: .soundcheck)
    @State private var topology = FixtureTopology()
    @State private var advancedExpanded = false
    @State private var showUnsafeWarning = false
    @State private var showFileImporter = false
    /// Lightweight view preferences, stored the way the rest of the app stores
    /// them. Both start on so a first-time user gets the walkthrough and the
    /// plain-English captions without going looking for them.
    @AppStorage("LumenDesk.musicMode.quickStart.v1") private var showsQuickStart = true
    @AppStorage("LumenDesk.musicMode.plainHelp.v1") private var showsPlainHelp = true

    private var fixtures: [MusicFixtureDescriptor] { manager.musicFixtureDescriptors(in: scope) }
    private var includedFixtures: [MusicFixtureDescriptor] { topology.includedFixtures(fixtures) }
    private var isRunning: Bool { manager.activeEffects[scope] == "music-pulse" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            intro
            quickStart
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
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            commitConfiguration()
            manager.startMusicMode(
                configuration: configuration,
                scope: scope,
                reducedMotion: reduceMotion,
                capture: .file(url)
            )
        }
    }

    private var intro: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                LumenPanelShape(radius: 3, chamfer: 16).fill(Lumen.surfaceLoud)
                LumenPanelShape(radius: 3, chamfer: 16).stroke(Lumen.hairlineStrong, lineWidth: 1)
                Image(systemName: "music.note.list")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Lumen.beamBright)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 6) {
                Text("Music Mode")
                    .font(LumenType.display(size: 22, weight: .bold))
                    .foregroundStyle(Lumen.textPrimary)
                SpectrumRule(height: 2, tapered: true).frame(width: 120)
                #if os(macOS)
                Text("Your lights follow whatever this Mac is playing. Any app counts, not just a music app. The sound is analyzed on this Mac and never recorded, saved, or sent anywhere.")
                #else
                Text("Your lights follow music playing in the room, heard through the microphone. The sound is analyzed on this device and never recorded, saved, or sent anywhere.")
                #endif
                Toggle("Explain the controls", isOn: $showsPlainHelp)
                    .toggleStyle(LumenRockerStyle())
                    .font(.caption)
                    .help("Shows a plain-English line under each control. Turn it off once you know your way around.")
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
                        .buttonStyle(LumenSecondaryButtonStyle())
                } else {
                    VStack(alignment: .trailing, spacing: 8) {
                        Button("Start Music Mode") {
                            commitConfiguration()
                            manager.startMusicMode(
                                configuration: configuration,
                                scope: scope,
                                reducedMotion: reduceMotion
                            )
                        }
                        .buttonStyle(LumenPrimaryButtonStyle())
                        .disabled(includedFixtures.isEmpty)
                        .help(MusicModeHelp.systemAudioSource)
                        Button("Open Audio File…") { showFileImporter = true }
                            .buttonStyle(LumenSecondaryButtonStyle())
                            .disabled(includedFixtures.isEmpty)
                            .help(MusicModeHelp.fileSource)
                        Button("MIDI Clock") {
                            commitConfiguration()
                            manager.startMusicMode(
                                configuration: configuration,
                                scope: scope,
                                reducedMotion: reduceMotion,
                                capture: .midiClock
                            )
                        }
                        .buttonStyle(LumenSecondaryButtonStyle())
                        .disabled(includedFixtures.isEmpty)
                        .help(MusicModeHelp.midiSource)
                    }
                    if includedFixtures.isEmpty {
                        Text("No lights in this show yet. Pick a room with lights in it, or switch a light back on in the list below.")
                            .font(.caption)
                            .foregroundStyle(Lumen.warning)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 220)
                    }
                }
            }
        }
        .padding(18)
        .lumenCard(highlighted: isRunning, glowColor: isRunning ? Lumen.pink : nil)
    }

    /// A first-run walkthrough, collapsible and remembered, so the desk does
    /// not open cold for someone who has never used it.
    private var quickStart: some View {
        DisclosureGroup(isExpanded: $showsQuickStart) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(MusicModeHelp.quickStart) { step in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(step.id)")
                            .font(LumenType.display(size: 15, weight: .bold).monospacedDigit())
                            .foregroundStyle(Lumen.beamBright)
                            .frame(width: 22, alignment: .center)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.title)
                                .font(LumenType.display(size: 14, weight: .semibold))
                                .foregroundStyle(Lumen.textPrimary)
                            Text(step.detail)
                                .font(.caption)
                                .foregroundStyle(Lumen.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Step \(step.id). \(step.title). \(step.detail)")
                }
                Text(MusicModeHelp.sharedSource)
                    .font(.caption)
                    .foregroundStyle(Lumen.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 12)
        } label: {
            Text("How to get a show running")
                .font(LumenType.display(size: 15, weight: .semibold))
        }
        .padding(16)
        .lumenCard()
    }

    private var sourceAndInput: some View {
        MusicModeInputStatusView(controller: manager.musicModeController,
                                 isRunning: isRunning,
                                 showsPlainHelp: showsPlainHelp)
    }

    private var presetPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                LumenEyebrow(text: "Preset", tint: Lumen.beamDim, size: 10)
                Spacer()
                Text(configuration.preset.bestFor)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Lumen.textSecondary)
            }
            LumenSelector(label: "Preset", selection: Binding(
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
            ), options: MusicModePreset.allCases.map {
                LumenOption(value: $0, title: $0.displayName)
            })
            if showsPlainHelp {
                Text(configuration.preset.plainSummary)
                    .font(.caption)
                    .foregroundStyle(Lumen.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(configuration.preset.summary)
                .font(.caption)
                .foregroundStyle(Lumen.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .lumenCard()
    }

    private var primaryControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            LumenEyebrow(text: "Show balance", tint: Lumen.beamDim, size: 10)
            if showsPlainHelp {
                Text("A preset sets all of these for you. Move one and the preset becomes Custom. Picking a named preset afterwards writes over what you changed.")
                    .font(.caption)
                    .foregroundStyle(Lumen.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            musicSlider("Master brightness", value: binding(\.masterBrightness), icon: "sun.max.fill",
                        help: MusicModeHelp.masterBrightness)
            musicSlider("Effect intensity", value: binding(\.effectIntensity), icon: "waveform",
                        help: MusicModeHelp.effectIntensity)
            musicSlider("Beat sensitivity", value: binding(\.beatSensitivity), icon: "metronome.fill",
                        help: MusicModeHelp.beatSensitivity)
            musicSlider("Bass sensitivity", value: binding(\.bassSensitivity), icon: "speaker.wave.3.fill",
                        help: MusicModeHelp.bassSensitivity)
            musicSlider("Percussion sensitivity", value: binding(\.percussionSensitivity), icon: "hands.clap.fill",
                        help: MusicModeHelp.percussionSensitivity)
        }
        .padding(16)
        .lumenCard()
    }

    private var topologyEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Which light does what")
                        .font(LumenType.display(size: 15, weight: .semibold))
                    Text("Give each light a job and put the list in the order the lights sit in the room. LumenDesk never guesses the order from how the lights were found.\(isRunning ? " Stop the show to change which lights are included." : "")")
                        .font(.caption).foregroundStyle(Lumen.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Picker("Layout", selection: Binding(
                        get: { topology.layout },
                        set: { topology.layout = $0; commitTopology() }
                    )) {
                        ForEach(FixtureTopologyLayout.allCases) { Text($0.displayName).tag($0) }
                    }
                    .fixedSize()
                    .help(topology.layout.plainSummary)
                    if showsPlainHelp {
                        Text(topology.layout.plainSummary)
                            .font(.caption)
                            .foregroundStyle(Lumen.textTertiary)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 260)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if showsPlainHelp {
                VStack(alignment: .leading, spacing: 6) {
                    Text(MusicModeHelp.roles)
                        .font(.caption)
                        .foregroundStyle(Lumen.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(FixtureRole.allCases) { role in
                        HStack(alignment: .top, spacing: 8) {
                            Text(role.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Lumen.textPrimary)
                                .frame(width: 58, alignment: .leading)
                            Text(role.plainSummary)
                                .font(.caption)
                                .foregroundStyle(Lumen.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Text(MusicModeHelp.order)
                        .font(.caption)
                        .foregroundStyle(Lumen.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(
                    LumenPanelShape(radius: 3, chamfer: 10)
                        .fill(Lumen.surfaceRaised)
                )
            }

            let ordered = topology.orderedFixtures(fixtures)
            let includedOrdered = topology.includedFixtures(fixtures)
            ForEach(Array(ordered.enumerated()), id: \.element.id) { index, fixture in
                let isExcluded = topology.excludedFixtureIDs.contains(fixture.id)
                HStack(spacing: 10) {
                    if let position = includedOrdered.firstIndex(where: { $0.id == fixture.id }) {
                        Text("\(position + 1)").font(.caption.monospacedDigit()).foregroundStyle(Lumen.textTertiary)
                            .frame(width: 20)
                    } else {
                        Text("–").font(.caption.monospacedDigit()).foregroundStyle(Lumen.textTertiary)
                            .frame(width: 20)
                    }
                    Image(systemName: fixture.segmentCount > 0 ? "rectangle.split.3x1.fill" : "lightbulb.fill")
                        .foregroundStyle(isExcluded ? Lumen.textTertiary : (fixture.segmentCount > 0 ? Lumen.coral : Lumen.violetBright))
                    Text(fixture.label)
                        .strikethrough(isExcluded)
                        .foregroundStyle(isExcluded ? Lumen.textTertiary : Lumen.textPrimary)
                    if fixture.segmentCount > 0 {
                        Text("+ \(fixture.segmentCount) segments").font(.caption).foregroundStyle(Lumen.textTertiary)
                    }
                    Picker("Role", selection: roleBinding(fixture.id)) {
                        ForEach(FixtureRole.allCases.filter { !isRunning || $0 != .off || fixture.role == .off }) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(isExcluded || (isRunning && fixture.role == .off))
                    .help(fixture.resolvedRole.plainSummary)
                    .accessibilityHint(fixture.resolvedRole.plainSummary)
                    Spacer()
                    Button { toggleExclusion(fixture.id) } label: {
                        Image(systemName: isExcluded ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(isExcluded ? Lumen.textTertiary : Lumen.success)
                    .disabled(isRunning)
                    .help(isRunning ? "Stop the show to change which lights are included." : "")
                    .accessibilityLabel(isExcluded
                        ? "Excluded from show. Tap to include \(fixture.label)."
                        : "Included in show. Tap to exclude \(fixture.label).")
                    .accessibilityHint(isRunning ? "Stop the show first to change inclusion." : "")
                    Button { moveFixture(from: index, offset: -1, ordered: ordered) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless).disabled(index == 0 || isExcluded)
                    Button { moveFixture(from: index, offset: 1, ordered: ordered) } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless).disabled(index == ordered.count - 1 || isExcluded)
                }
                .padding(.vertical, 4)
                .opacity(isExcluded ? 0.55 : 1)
            }
        }
        .padding(16)
        .lumenCard()
    }

    private var advancedControls: some View {
        DisclosureGroup(isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                musicSlider("Color-change intensity", value: binding(\.colorChangeIntensity), icon: "paintpalette.fill",
                            help: MusicModeHelp.colorChangeIntensity)
                musicSlider("Movement amount", value: binding(\.movementAmount), icon: "arrow.left.and.right",
                            help: MusicModeHelp.movementAmount)
                musicSlider("Movement speed", value: binding(\.movementSpeed), icon: "speedometer",
                            help: MusicModeHelp.movementSpeed)
                Picker("Movement direction", selection: binding(\.movementDirection)) {
                    ForEach(MusicMovementDirection.allCases) { Text($0.displayName).tag($0) }
                }
                .help(configuration.movementDirection.plainSummary)
                helpCaption(configuration.movementDirection.plainSummary)
                musicSlider("Minimum brightness", value: binding(\.minimumBrightness), icon: "sun.min",
                            help: MusicModeHelp.minimumBrightness)
                musicSlider("Maximum brightness", value: binding(\.maximumBrightness), icon: "sun.max",
                            help: MusicModeHelp.maximumBrightness)

                Divider().overlay(Lumen.hairline)
                Toggle("Allow controlled flashes", isOn: binding(\.allowsFlashes))
                    .toggleStyle(LumenRockerStyle())
                    .help(MusicModeHelp.allowsFlashes)
                helpCaption(MusicModeHelp.allowsFlashes)
                musicSlider("Flash intensity", value: binding(\.flashIntensity), icon: "bolt.fill",
                            help: MusicModeHelp.flashIntensity)
                    .disabled(configuration.photosensitivitySafeMode || !configuration.allowsFlashes)
                LumenFader(label: "Maximum flash frequency",
                           value: frequencyBinding,
                           range: 0...FlashSafetyLimiter.hardMaximumFrequency,
                           step: 0.25,
                           track: .tint(Lumen.warning),
                           format: { String(format: "%.2f/s", $0) })
                .disabled(configuration.photosensitivitySafeMode || !configuration.allowsFlashes)
                .help(MusicModeHelp.maximumFlashFrequency)
                .accessibilityHint(MusicModeHelp.maximumFlashFrequency)
                helpCaption(MusicModeHelp.maximumFlashFrequency)

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
                .help(MusicModeHelp.photosensitivitySafeMode)
                helpCaption(MusicModeHelp.photosensitivitySafeMode)
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
                    Text("Club").tag("club")
                }
                .help(MusicModeHelp.palette)
                helpCaption(MusicModeHelp.palette)
                Picker("Silence behavior", selection: binding(\.silenceBehavior)) {
                    ForEach(MusicSilenceBehavior.allCases) { Text($0.displayName).tag($0) }
                }
                .help(configuration.silenceBehavior.plainSummary)
                helpCaption(configuration.silenceBehavior.plainSummary)

                Divider().overlay(Lumen.hairline)
                Picker("Metre", selection: metreBinding) {
                    Text("Auto").tag("auto")
                    ForEach(MusicMetre.allCases) { Text($0.displayName).tag(String($0.rawValue)) }
                }
                .help(metreHelp)
                helpCaption(metreHelp)
                Picker("Time feel", selection: binding(\.timeFeel)) {
                    ForEach(TimeFeel.allCases) { Text($0.displayName).tag($0) }
                }
                .help(configuration.timeFeel.plainSummary)
                helpCaption(configuration.timeFeel.plainSummary)
                musicSlider("Stereo image", value: binding(\.stereoImage), icon: "headphones",
                            help: MusicModeHelp.stereoImage)
                Toggle("Phrase-aware lifts", isOn: binding(\.phraseAware))
                    .toggleStyle(LumenRockerStyle())
                    .help(MusicModeHelp.phraseAware)
                helpCaption(MusicModeHelp.phraseAware)
                Text("Auto metre listens for 3/4, 5/4, 6/8 and 7/8. Half-time feels every other beat. Roles and metre stay inside the 3 flashes/second ceiling.")
                    .font(.caption).foregroundStyle(Lumen.textSecondary)

                Toggle("Restore previous state when stopped", isOn: binding(\.restorePreviousState))
                    .help(MusicModeHelp.restorePreviousState)
                helpCaption(MusicModeHelp.restorePreviousState)
                if manager.isDemoMode {
                    Toggle("Use deterministic demo rhythm", isOn: binding(\.usesSyntheticDemoPattern))
                    Picker("Demo groove", selection: Binding(
                        get: { manager.musicModeController.selectedGrooveID },
                        set: { manager.musicModeController.setGroove($0) }
                    )) {
                        ForEach(MusicGroove.all) { groove in
                            Text(groove.name).tag(groove.id)
                        }
                    }
                    Text("Turn this off to demonstrate with live audio input. Grooves cover waltz, odd metre, and half-time with no copyrighted audio.")
                        .font(.caption).foregroundStyle(Lumen.textSecondary)
                }
            }
            .padding(.top, 14)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Advanced controls").font(LumenType.display(size: 15, weight: .semibold))
                Text("Nothing in here is needed to run a show. Open it to shape one preset into exactly what you want.")
                    .font(.caption)
                    .foregroundStyle(Lumen.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .lumenCard()
    }

    /// One fader plus the sentence that says what moving it does. The caption
    /// follows the "Explain the controls" preference; the tooltip and the
    /// accessibility hint carry the same words either way, so the explanation
    /// is never only available to a sighted user with a mouse.
    private func musicSlider(_ title: String, value: Binding<Double>, icon: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Lumen.beamDim)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                LumenFader(label: title, value: value, track: .spectrum, showsScale: false)
                    .accessibilityHint(help)
            }
            if showsPlainHelp {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(Lumen.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 30)
                    .accessibilityHidden(true)
            }
        }
        .help(help)
    }

    /// A plain-English line under a control, shown while "Explain the
    /// controls" is on. Pickers and toggles carry the same words in `.help`,
    /// so nothing here is the only copy of an explanation.
    @ViewBuilder
    private func helpCaption(_ text: String) -> some View {
        if showsPlainHelp {
            Text(text)
                .font(.caption)
                .foregroundStyle(Lumen.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
        }
    }

    private var metreHelp: String {
        guard let metre = configuration.metreOverride else {
            return "Auto works out how many beats are in a bar by listening. Set it by hand only if the room is counting the music wrong."
        }
        return metre.plainSummary
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
                if configuration.palette == MusicModeConfiguration.clubPalette { return "club" }
                return "soundcheck"
            },
            set: { name in
                switch name {
                case "aurora": configuration.palette = MusicModeConfiguration.auroraPalette
                case "sunset": configuration.palette = MusicModeConfiguration.sunsetPalette
                case "ocean": configuration.palette = MusicModeConfiguration.oceanPalette
                case "club": configuration.palette = MusicModeConfiguration.clubPalette
                default: configuration.palette = MusicModeConfiguration.soundcheckPalette
                }
                configuration.preset = .custom
                commitConfiguration()
            }
        )
    }

    private var metreBinding: Binding<String> {
        Binding(
            get: {
                if let metre = configuration.metreOverride { return String(metre.rawValue) }
                return "auto"
            },
            set: { value in
                configuration.metreOverride = MusicMetre(rawValue: Int(value) ?? -1)
                configuration.preset = .custom
                commitConfiguration()
            }
        )
    }

    private func roleBinding(_ fixtureID: String) -> Binding<FixtureRole> {
        Binding(
            get: { topology.role(for: fixtureID) },
            set: { role in
                if role == .auto {
                    topology.roles.removeValue(forKey: fixtureID)
                } else {
                    topology.roles[fixtureID] = role
                }
                commitTopology()
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

    private func toggleExclusion(_ fixtureID: String) {
        if topology.excludedFixtureIDs.contains(fixtureID) {
            topology.excludedFixtureIDs.remove(fixtureID)
        } else {
            topology.excludedFixtureIDs.insert(fixtureID)
        }
        commitTopology()
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
    let showsPlainHelp: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(controller.sourceStatus.displayName, systemImage: sourceIcon)
                    .font(LumenType.display(size: 15, weight: .semibold))
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
            meter("Input", value: controller.latestSnapshot.level, color: Lumen.beamBright, segments: 32)
            HStack(alignment: .bottom, spacing: 12) {
                meter("Bass", value: controller.latestSnapshot.bass, color: Lumen.chalk, segments: 12)
                meter("Mids", value: controller.latestSnapshot.mids, color: Lumen.meter, segments: 12)
                meter("Highs", value: controller.latestSnapshot.highs, color: Lumen.muted, segments: 12)
                VStack(spacing: 5) {
                    LumenStatusDot(color: Lumen.beamBright,
                                   size: 18,
                                   lit: controller.latestSnapshot.beat > 0.25)
                    LumenEyebrow(
                        text: tempoLabel,
                        tint: controller.latestSnapshot.isTempoLocked ? Lumen.textSecondary : Lumen.textTertiary
                    )
                }
                .frame(width: 58)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(controller.latestSnapshot.isTempoLocked
                    ? "Tempo locked at \(tempoLabel)"
                    : "Beat indicator, no tempo detected")
            }
            if controller.sourceStatus == .permissionDenied {
                Text(permissionMessage)
                    .font(.caption).foregroundStyle(Lumen.warning)
            } else if controller.sourceStatus == .unavailable {
                Text("The audio source is unavailable. Check permission and try starting Music Mode again.")
                    .font(.caption).foregroundStyle(Lumen.warning)
            }
            if showsPlainHelp {
                Text(MusicModeHelp.readout)
                    .font(.caption)
                    .foregroundStyle(Lumen.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .lumenCard(fill: Lumen.surfaceRaised)
    }

    private func meter(_ label: String, value: Double, color: Color, segments: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            LumenMeter(value: value, tint: color, segments: segments, height: 9)
            LumenEyebrow(text: label)
        }
        .frame(maxWidth: .infinity)
    }

    /// Reads out the detected tempo once the beat tracker locks, so it is
    /// visible whether the show is choreographing to a grid or reacting to
    /// onsets alone.
    private var tempoLabel: String {
        let snapshot = controller.latestSnapshot
        guard snapshot.isTempoLocked, snapshot.tempo > 0 else { return "Beat" }
        let bpm = Int((snapshot.feltTempo > 0 ? snapshot.feltTempo : snapshot.tempo).rounded())
        let metre = snapshot.metre > 0 ? snapshot.metre : 4
        return "\(bpm) · \(metre)/\(metre == 6 ? 8 : 4)"
    }

    private var sourceIcon: String {
        switch controller.sourceStatus {
        case .systemAudio: return "macbook.and.iphone"
        case .microphone: return "mic.fill"
        case .syntheticDemo: return "waveform.badge.plus"
        case .filePlayback: return "waveform.badge.magnifyingglass"
        case .midiClock: return "pianokeys"
        case .permissionDenied: return "lock.trianglebadge.exclamationmark"
        case .unavailable: return "exclamationmark.triangle.fill"
        case .idle, .requestingPermission: return "waveform"
        }
    }

    private var permissionMessage: String {
        #if os(macOS)
        return "Screen Recording permission is required to analyze system audio. Enable LumenDesk in System Settings › Privacy & Security › Screen & System Audio Recording, return here, and press Start again. A relaunch is normally unnecessary."
        #else
        return "Microphone permission is required on iPhone and iPad. Enable LumenDesk in Settings › Privacy & Security › Microphone."
        #endif
    }

    private var statusColor: Color {
        switch controller.sourceStatus {
        case .permissionDenied, .unavailable: return Lumen.warning
        case .systemAudio, .microphone, .syntheticDemo, .filePlayback, .midiClock: return Lumen.success
        case .idle, .requestingPermission: return Lumen.textSecondary
        }
    }
}
