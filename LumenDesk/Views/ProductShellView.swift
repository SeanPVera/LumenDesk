import SwiftUI

// MARK: - Product navigation
//
// Five destinations, named in the vocabulary of the thing the app controls.
// "Home", "Library", "Automation", and "Devices" described the software; Desk,
// Looks, Cues, and Rig describe the lighting, and every one of them is shorter
// than the word it replaced. The case names are unchanged so nothing that
// switches on a destination had to move.

enum LumenDeskDestination: String, CaseIterable, Identifiable {
    case home = "Plan"
    case library = "Looks"
    case automation = "Cues"
    case devices = "Rig"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .home: return "square.grid.3x3.topleft.filled"
        case .library: return "square.grid.2x2"
        case .automation: return "clock"
        case .devices: return "lightbulb.2"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - Shell

/// The window. On macOS a fixed icon rail beside the working area, with the
/// inspector living inside the Desk itself; on iPhone a four-item tab bar.
///
/// The rail replaced a 228 pt sidebar that spent its top on a three-line
/// wordmark and gave each destination a channel number. A list of five things
/// does not need addressing, and the space it cost belonged to the fixtures.
struct LumenDeskShellView: View {
    @EnvironmentObject private var manager: LightManager
    @State private var destination: LumenDeskDestination = .home
    @State private var showingSettings = false

    var body: some View {
        ZStack(alignment: .bottom) {
            #if os(macOS)
            desktopShell
            #else
            mobileShell
            #endif

            statusOverlays
        }
        .tint(Lumen.chalk)
        .background(Lumen.stage)
        .safeAreaInset(edge: .top, spacing: 0) {
            if manager.isDemoMode { DemoModeBanner() }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsWorkspaceView() }
                .environmentObject(manager)
        }
    }

    #if os(macOS)
    private var desktopShell: some View {
        HStack(spacing: 0) {
            WashRail(destination: $destination)
            Divider().overlay(Lumen.ruleSoft)
            NavigationStack { destinationView(destination) }
        }
        .background(Lumen.stage)
        .toolbar {
            ToolbarItemGroup {
                if manager.isScanning {
                    ProgressView()
                        .controlSize(.small)
                        .help(manager.scanPhase)
                }
                Button { manager.scan() } label: {
                    Label("Scan Lights", systemImage: "arrow.clockwise")
                }
                .buttonStyle(LumenIconButtonStyle())
                .disabled(manager.isScanning)
                .keyboardShortcut("r", modifiers: .command)
                .help("Scan this network for lights")
            }
        }
    }
    #endif

    #if !os(macOS)
    private var mobileShell: some View {
        TabView(selection: $destination) {
            mobileTab(.home)
                .tabItem { Label("Plan", systemImage: LumenDeskDestination.home.symbol) }
                .tag(LumenDeskDestination.home)
            mobileTab(.library)
                .tabItem { Label("Looks", systemImage: LumenDeskDestination.library.symbol) }
                .tag(LumenDeskDestination.library)
            mobileTab(.automation)
                .tabItem { Label("Cues", systemImage: LumenDeskDestination.automation.symbol) }
                .tag(LumenDeskDestination.automation)
            mobileTab(.devices)
                .tabItem { Label("Rig", systemImage: LumenDeskDestination.devices.symbol) }
                .tag(LumenDeskDestination.devices)
        }
    }

    private func mobileTab(_ item: LumenDeskDestination) -> some View {
        NavigationStack {
            destinationView(item)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showingSettings = true } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
        }
    }
    #endif

    @ViewBuilder
    private func destinationView(_ item: LumenDeskDestination) -> some View {
        switch item {
        case .home: PlanWorkspaceView()
        case .library: LibraryWorkspaceView()
        case .automation: AutomationWorkspaceView()
        case .devices: DevicesWorkspaceView()
        case .settings: SettingsWorkspaceView()
        }
    }

    @ViewBuilder
    private var statusOverlays: some View {
        VStack(spacing: 8) {
            if let summary = manager.lastActionSummary {
                HStack(spacing: 10) {
                    Label(summary, systemImage: "arrow.uturn.backward")
                    Button("Undo") { manager.undo() }
                        .disabled(!manager.canUndo)
                    Button { manager.dismissLastActionSummary() } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
                .font(.system(size: 12))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Lumen.stripRaised,
                            in: RoundedRectangle(cornerRadius: Lumen.controlRadius, style: .continuous))
            }

            if let error = manager.commandError {
                CommandToastView(
                    message: error,
                    undoAction: manager.commandErrorUndo,
                    dismiss: { manager.commandError = nil }
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}

#if os(macOS)
/// The icon rail. Fifty-eight points of chrome for the whole navigation model.
private struct WashRail: View {
    @EnvironmentObject private var manager: LightManager
    @Binding var destination: LumenDeskDestination

    private var reachableCount: Int {
        manager.devices.filter { !$0.isStale }.count
    }

    var body: some View {
        VStack(spacing: 4) {
            LumenMark(size: 22)
                .padding(.top, 14)
                .padding(.bottom, 16)

            ForEach(LumenDeskDestination.allCases) { item in
                Button { destination = item } label: {
                    Image(systemName: item.symbol)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(destination == item ? Lumen.chalk : Lumen.muted)
                        .frame(width: 38, height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(destination == item ? Lumen.stripRaised : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.rawValue)
                .accessibilityLabel(item.rawValue)
                .accessibilityAddTraits(destination == item ? [.isButton, .isSelected] : .isButton)

                if item == .devices { Spacer(minLength: 12) }
            }

            // The one authored hue, spent on the one thing that is about the
            // network rather than about the lights.
            LumenStatusDot(color: reachableCount > 0 ? Lumen.link : Lumen.faint,
                           size: 7,
                           lit: reachableCount > 0)
                .padding(.bottom, 14)
                .help("\(reachableCount) of \(manager.devices.count) fixtures linked")
        }
        .frame(width: 58)
        .background(Lumen.stage)
    }
}
#endif

// The Wash "Desk" screen lived here: a field of channel strips with the
// fixture as the primary object. The product went with Plan instead, where
// the room is primary, so that screen is `PlanWorkspaceView` now and this one
// is gone rather than left wired to nothing. It is in the history if the
// channel-strip idea is ever wanted back.

// MARK: - Shared list components
//
// Kept because the Rig and Cues workspaces still use them. Restyled onto Wash
// tokens; the composition is unchanged.

private struct SummaryMetric: View {
    let icon: String
    let tint: Color
    let value: String
    let label: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            LumenReadout(value: value, caption: label, size: 17)
            Spacer(minLength: 0)
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lumenCard(radius: 8)
        .accessibilityElement(children: .combine)
    }
}

private struct DeviceCompactRow: View {
    @EnvironmentObject private var manager: LightManager
    @ObservedObject var device: LightDevice
    let selectionMode: Bool
    let selected: Bool
    let onOpen: () -> Void
    let onToggleSelection: () -> Void

    private var command: DeviceCommandState { manager.commandState(for: device.id) }

    var body: some View {
        HStack(spacing: 14) {
            if selectionMode {
                Button(action: onToggleSelection) {
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(selected ? Lumen.lit : Lumen.muted)
                }
                .buttonStyle(.plain)
                .lumenInteractiveTarget()
                .accessibilityLabel(selected ? "Deselect \(device.label)" : "Select \(device.label)")
            }

            LumenLens(color: device.color, isOn: device.isOn, size: 36,
                      isStale: device.isStale, level: device.brightness)

            Button(action: selectionMode ? onToggleSelection : onOpen) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(device.label)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Lumen.chalk)
                            .lineLimit(1)
                        if manager.isFavorite(device.id) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Lumen.warn)
                        }
                    }
                    Text("\(device.brand.displayName) · \(Int(device.brightness * 100))% · \(device.kelvin) K")
                        .font(LumenType.readout(size: 9.5, weight: .regular))
                        .foregroundStyle(Lumen.muted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            DeviceStateBadge(device: device, command: command)

            if !selectionMode {
                if command.phase == .failed {
                    Button("Retry") { manager.retryCommand(for: device) }
                        .buttonStyle(LumenSecondaryButtonStyle(compact: true))
                }
                Toggle("", isOn: Binding(get: { device.isOn },
                                         set: { manager.setPower(device, on: $0) }))
                    .labelsHidden()
                    .toggleStyle(LumenPowerKeyStyle(size: 30, spokenLabel: "Power for \(device.label)"))
            }
        }
        .padding(13)
        .lumenCard(radius: 8, fill: selected ? Lumen.stripLoud : Lumen.strip, highlighted: selected)
        .washed(color: device.color, level: device.brightness,
                isOn: device.isOn && !device.isStale, radius: 8)
        .opacity(device.isStale ? 0.8 : 1)
    }
}

private struct DeviceStateBadge: View {
    let device: LightDevice
    let command: DeviceCommandState

    private var presentation: (title: String, color: Color) {
        switch command.phase {
        case .queued: return ("Queued", Lumen.warn)
        case .sending: return ("Sending", Lumen.link)
        case .applied: return ("Confirmed", Lumen.link)
        case .failed: return ("Failed", Lumen.fail)
        case .idle:
            return device.isStale ? ("Unreachable", Lumen.faint) : ("Linked", Lumen.link)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            LumenStatusDot(color: presentation.color, size: 5)
            Text(presentation.title)
                .font(LumenType.readout(size: 9.5, weight: .medium))
                .foregroundStyle(presentation.color)
        }
        .accessibilityLabel("Status: \(presentation.title)")
    }
}


struct RoomDetailSheet: View {
    @EnvironmentObject private var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    let room: Room
    @State private var showingSchedules = false

    private var currentRoom: Room {
        manager.rooms.first(where: { $0.id == room.id }) ?? room
    }

    private var lights: [LightDevice] { manager.devices(in: currentRoom) }
    private var averageBrightness: Double {
        guard !lights.isEmpty else { return 0 }
        return lights.reduce(0) { $0 + $1.brightness } / Double(lights.count)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeader(eyebrow: "Room", title: currentRoom.name,
                               subtitle: "\(lights.filter(\.isOn).count) of \(lights.count) lights on") {
                        Button { manager.toggleFavoriteRoom(currentRoom.id) } label: {
                            Image(systemName: manager.isFavoriteRoom(currentRoom.id) ? "star.fill" : "star")
                        }
                        .buttonStyle(LumenIconButtonStyle(tint: manager.isFavoriteRoom(currentRoom.id) ? Lumen.gold : Lumen.textSecondary))
                        .accessibilityLabel(manager.isFavoriteRoom(currentRoom.id) ? "Remove favorite" : "Favorite room")
                    }

                    HStack {
                        Button("All On") { manager.setPower(in: currentRoom, on: true) }
                            .buttonStyle(LumenPrimaryButtonStyle())
                        Button("All Off") { manager.setPower(in: currentRoom, on: false) }
                            .buttonStyle(LumenSecondaryButtonStyle())
                        Spacer()
                        Button { showingSchedules = true } label: {
                            Label("Schedules", systemImage: "clock")
                        }
                        .buttonStyle(LumenSecondaryButtonStyle())
                    }
                    .disabled(lights.isEmpty)

                    LumenFader(
                        label: "Brightness in \(currentRoom.name)",
                        value: Binding(get: { averageBrightness },
                                       set: { manager.setBrightness(in: currentRoom, value: $0) }),
                        track: .beam
                    )
                    .padding(16)
                    .lumenCard()
                    .disabled(lights.isEmpty)

                    if lights.isEmpty {
                        EmptyInlineView(icon: "lightbulb.slash", title: "No lights in this room",
                                        message: "Assign a discovered light before using room power or brightness controls.")
                    }

                    SectionHeader(title: "Lights", detail: "\(lights.count) devices")
                    ForEach(lights) { device in
                        LightRowView(device: device)
                    }
                }
                .padding(20)
            }
            .background(LumenBackground(glow: false))
            .navigationTitle(currentRoom.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .sheetFrame(minWidth: 680, idealWidth: 820, minHeight: 600, idealHeight: 760)
        .sheet(isPresented: $showingSchedules) {
            ScheduleEditorView(room: currentRoom)
                .environmentObject(manager)
        }
    }
}

struct NewRoomSheet: View {
    @EnvironmentObject private var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Rooms keep everyday control predictable across brands.")
                    .font(.callout).foregroundStyle(Lumen.textSecondary)
                TextField("Room name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Spacer()
            }
            .padding(20)
            .background(LumenBackground(glow: false))
            .navigationTitle("New Room")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .sheetFrame(minWidth: 420, idealWidth: 480, minHeight: 220, idealHeight: 260)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        manager.createRoom(name: trimmed)
        dismiss()
    }
}

// MARK: - Library

private enum ProductLibrarySection: String, CaseIterable, Identifiable {
    case scenes = "Scenes"
    case themes = "Themes"
    case music = "Music Mode"
    case effects = "Effects"
    var id: String { rawValue }
}

struct LibraryWorkspaceView: View {
    @EnvironmentObject private var manager: LightManager
    @State private var section: ProductLibrarySection = .scenes
    @State private var searchText = ""
    @State private var scope: LightScope = .all
    @State private var newSceneName = ""
    @State private var previewScene: LightingScene?
    @State private var editingScene: LightingScene?
    @State private var pendingAudioEffect: LightingEffect?
    @State private var hasRestoredRunningShow = false

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(eyebrow: "Scenes, colour, motion", title: "Looks",
                           subtitle: "Recall a room, build a mood, or put motion on cue.")

                if !manager.activeEffects.isEmpty { runningEffects }

                LumenSelector(
                    label: "Library section",
                    selection: $section,
                    options: ProductLibrarySection.allCases.map {
                        LumenOption(value: $0, title: $0.rawValue)
                    }
                )

                HStack(spacing: 10) {
                    if section != .scenes && section != .music {
                        LumenEyebrow(text: "Apply to")
                        Picker("Apply to", selection: $scope) {
                            Text("All Lights").tag(LightScope.all)
                            ForEach(manager.rooms) { room in
                                Text(room.name).tag(LightScope.room(room.id))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Spacer()
                }

                switch section {
                case .scenes: scenesSection
                case .themes: themesSection
                case .music: MusicModeView(scope: $scope)
                case .effects: effectsSection
                }
            }
            .frame(maxWidth: 1120)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(LumenBackground(glow: false))
        .navigationTitle("Looks")
        .searchable(text: $searchText, prompt: "Search library")
        .onAppear { restoreRunningShowIfNeeded() }
        .sheet(item: $previewScene) { scene in
            ScenePreviewView(scene: scene).environmentObject(manager)
        }
        .sheet(item: $editingScene) { scene in
            SceneEditorView(scene: scene).environmentObject(manager)
        }
        .alert("Allow Music-Reactive Lighting?", isPresented: Binding(
            get: { pendingAudioEffect != nil },
            set: { if !$0 { pendingAudioEffect = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingAudioEffect = nil }
            Button("Continue") {
                UserDefaults.standard.set(true, forKey: AppPreferenceKey.audioPrivacyAcknowledged)
                if let effect = pendingAudioEffect { manager.startEffect(effect, scope: scope) }
                pendingAudioEffect = nil
            }
        } message: {
            Text("Audio is analyzed locally and is never recorded or retained. The running effect stays visible with a one-click Stop action.")
        }
    }

    private var runningEffects: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Effect running", systemImage: "waveform")
                    .font(LumenType.display(size: 15, weight: .semibold)).foregroundStyle(Lumen.pinkBright)
                Spacer()
                if manager.activeEffects.count > 1 {
                    Button("Stop All") { manager.stopAllEffects() }
                        .buttonStyle(LumenSecondaryButtonStyle())
                }
            }
            ForEach(manager.activeEffects.keys.sorted(by: { manager.scopeDisplayName($0) < manager.scopeDisplayName($1) }), id: \.self) { runScope in
                if let effectID = manager.activeEffects[runScope],
                   let effect = LightingCatalog.effects.first(where: { $0.id == effectID }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(effect.name).font(LumenType.display(size: 15, weight: .semibold))
                            Text(manager.scopeDisplayName(runScope)).font(.caption).foregroundStyle(Lumen.textSecondary)
                        }
                        Spacer()
                        Button("Stop") { manager.stopEffect(scope: runScope) }
                            .buttonStyle(LumenPrimaryButtonStyle(compact: true))
                    }
                }
            }
        }
        .padding(16)
        .lumenCard(fill: Lumen.surfaceRaised, highlighted: true)
    }

    private var scenesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                TextField("Scene name", text: $newSceneName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(captureScene)
                Button { captureScene() } label: {
                    Label("Save Current Lighting", systemImage: "plus")
                }
                .buttonStyle(LumenPrimaryButtonStyle())
                .disabled(newSceneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manager.devices.isEmpty)
            }

            if filteredScenes.isEmpty {
                EmptyInlineView(icon: "sparkles", title: manager.scenes.isEmpty ? "No saved scenes" : "No matching scenes",
                                message: manager.scenes.isEmpty ? "Set your lights, name the moment, and save it here." : "Try a different search.")
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(filteredScenes) { scene in sceneCard(scene) }
                }
            }
        }
    }

    private var themesSection: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(filteredThemes) { theme in
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: theme.icon).font(LumenType.display(size: 21, weight: .semibold)).foregroundStyle(theme.colors.first?.color ?? Lumen.violetBright)
                        Spacer()
                        Text(theme.category.rawValue)
                            .font(.caption2.weight(.semibold)).foregroundStyle(Lumen.textTertiary)
                    }
                    Text(theme.name).font(LumenType.display(size: 15, weight: .semibold))
                    Text(theme.summary).font(.caption).foregroundStyle(Lumen.textSecondary).lineLimit(3)
                    PaletteStrip(colors: theme.colors.map(\.color))
                    HStack {
                        Label("\(Int(theme.brightness * 100))%", systemImage: "sun.max")
                            .font(.caption).foregroundStyle(Lumen.textSecondary)
                        Spacer()
                        Button("Apply") { manager.applyTheme(theme, scope: scope) }
                            .buttonStyle(LumenPrimaryButtonStyle(compact: true))
                            .disabled(manager.devices(in: scope).isEmpty)
                    }
                }
                .padding(16)
                .lumenCard()
            }
        }
    }

    private var effectsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("High-energy effects may not be suitable for people sensitive to flashing light.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(Lumen.textSecondary)
                .padding(12).lumenCard(fill: Lumen.surfaceRaised)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(filteredEffects) { effect in
                    effectCard(effect)
                }
            }
        }
    }

    private func sceneCard(_ scene: LightingScene) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { manager.toggleFavoriteScene(scene.id) } label: {
                    Image(systemName: manager.isFavoriteScene(scene.id) ? "star.fill" : "star")
                        .foregroundStyle(manager.isFavoriteScene(scene.id) ? Lumen.gold : Lumen.textTertiary)
                }
                .buttonStyle(.plain)
                Spacer()
                Menu {
                    Button("Edit Draft") { editingScene = scene }
                    Button("Duplicate Name…") { newSceneName = "\(scene.name) Copy" }
                    Button("Delete", role: .destructive) { manager.deleteScene(scene.id) }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .lumenInteractiveTarget()
            }
            Text(scene.name).font(LumenType.display(size: 15, weight: .semibold))
            Text("\(scene.snapshots.count) lights · saved \(scene.createdAt.formatted(.relative(presentation: .named)))")
                .font(.caption).foregroundStyle(Lumen.textSecondary)
            PaletteStrip(colors: scene.snapshots.values.prefix(8).map {
                Color(hue: $0.hue, saturation: $0.saturation, brightness: max(0.45, $0.brightness))
            })
            Button("Preview & Apply") { previewScene = scene }
                .buttonStyle(LumenPrimaryButtonStyle(compact: true))
                .disabled(manager.availableDeviceIDs(for: scene).isEmpty)
            if manager.availableDeviceIDs(for: scene).isEmpty {
                Label("No scene lights are currently available", systemImage: "wifi.slash")
                    .font(.caption2).foregroundStyle(Lumen.warning)
            }
        }
        .padding(16)
        .lumenCard()
    }

    private func effectCard(_ effect: LightingEffect) -> some View {
        let isActive = manager.activeEffects[scope] == effect.id
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: effect.icon).font(LumenType.display(size: 21, weight: .semibold))
                    .foregroundStyle(isActive ? Lumen.pinkBright : Lumen.violetBright)
                Spacer()
                if effect.isAudioReactive {
                    Label("Audio", systemImage: "waveform").font(.caption2).foregroundStyle(Lumen.pinkBright)
                } else if effect.isHighEnergy {
                    Label("Energy", systemImage: "bolt.fill").font(.caption2).foregroundStyle(Lumen.warning)
                }
            }
            Text(effect.name).font(LumenType.display(size: 15, weight: .semibold))
            Text(effect.summary).font(.caption).foregroundStyle(Lumen.textSecondary).lineLimit(3)
            PaletteStrip(colors: effect.colors.map(\.color))
            HStack {
                Text(manager.scopeDisplayName(scope)).font(.caption).foregroundStyle(Lumen.textTertiary)
                Spacer()
                if isActive {
                    Button("Stop") { manager.stopEffect(scope: scope) }
                        .buttonStyle(LumenSecondaryButtonStyle(compact: true))
                } else {
                    Button("Start") { start(effect) }
                        .buttonStyle(LumenPrimaryButtonStyle(compact: true))
                        .disabled(manager.devices(in: scope).isEmpty)
                }
            }
        }
        .padding(16)
        .lumenCard(fill: isActive ? Lumen.surfaceRaised : Lumen.surface, highlighted: isActive)
    }

    private var filteredScenes: [LightingScene] {
        searchText.isEmpty ? manager.scenes : manager.scenes.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    /// This view (and its `section`/`scope` selection) is torn down and
    /// rebuilt whenever the sidebar/tab moves to a different top-level
    /// destination and back, since it lives behind a `switch` case in
    /// `LumenDeskShellView.destinationView`. Without this, leaving Music
    /// Mode running in a room and returning to Library always lands back on
    /// Scenes / All Lights, hiding the running show's controls behind a
    /// picker the user has to reselect by hand. Restore straight to it once,
    /// on the freshly created instance, without overriding a section the
    /// user then deliberately navigates away from within this instance.
    private func restoreRunningShowIfNeeded() {
        guard !hasRestoredRunningShow else { return }
        hasRestoredRunningShow = true
        if let runningScope = manager.activeEffects.first(where: { $0.value == "music-pulse" })?.key {
            section = .music
            scope = runningScope
        }
    }

    private func start(_ effect: LightingEffect) {
        if effect.isAudioReactive && !UserDefaults.standard.bool(forKey: AppPreferenceKey.audioPrivacyAcknowledged) {
            pendingAudioEffect = effect
        } else {
            manager.startEffect(effect, scope: scope)
        }
    }

    private var filteredThemes: [LightingTheme] {
        searchText.isEmpty ? LightingCatalog.themes : LightingCatalog.themes.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) || $0.summary.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredEffects: [LightingEffect] {
        let effects = LightingCatalog.effects.filter { $0.id != "music-pulse" }
        return searchText.isEmpty ? effects : effects.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) || $0.summary.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func captureScene() {
        let trimmed = newSceneName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        manager.captureScene(name: trimmed)
        if let scene = manager.scenes.last { manager.toggleFavoriteScene(scene.id) }
        newSceneName = ""
    }
}

private struct PaletteStrip: View {
    let colors: [Color]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                Rectangle().fill(color).frame(height: 26)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .stroke(Lumen.hairlineStrong, lineWidth: 1)
        )
        .accessibilityHidden(true)
    }
}

// MARK: - Automation

struct AutomationWorkspaceView: View {
    @EnvironmentObject private var manager: LightManager
    @State private var scheduleRoom: Room?
    @State private var showingSolarSettings = false
    @State private var showingMissed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(eyebrow: "Cues and timing", title: "Cues",
                           subtitle: "Let the house keep time. Pauses and missed cues stay visible until you decide.") {
                    Button { showingSolarSettings = true } label: {
                        Label("Solar Times", systemImage: "sunrise")
                    }
                    .buttonStyle(LumenSecondaryButtonStyle())
                }

                if !manager.missedAutomations.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(LumenType.display(size: 21, weight: .semibold)).foregroundStyle(Lumen.warning)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(manager.missedAutomations.count) missed action\(manager.missedAutomations.count == 1 ? "" : "s")")
                                .font(LumenType.display(size: 15, weight: .semibold))
                            Text("Nothing runs until you review it.")
                                .font(.caption).foregroundStyle(Lumen.textSecondary)
                        }
                        Spacer()
                        Button("Review") { showingMissed = true }
                            .buttonStyle(LumenPrimaryButtonStyle())
                    }
                    .padding(16)
                    .lumenCard(fill: Lumen.surfaceRaised)
                }

                HStack {
                    SummaryMetric(icon: "clock", tint: Lumen.violetBright,
                                  value: "\(enabledScheduleCount)", label: "Enabled schedules")
                    SummaryMetric(icon: "pause.circle", tint: pausedRoomCount > 0 ? Lumen.warning : Lumen.textTertiary,
                                  value: "\(pausedRoomCount)", label: "Temporarily paused")
                }

                SectionHeader(title: "Rooms", detail: "Schedules run while LumenDesk is available")

                if manager.rooms.isEmpty {
                    EmptyInlineView(icon: "clock.badge.questionmark", title: "No rooms to automate",
                                    message: "Create and organize a room on Home before adding a schedule.")
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(manager.rooms) { room in
                            AutomationRoomCard(room: room, onEdit: { scheduleRoom = room })
                        }
                    }
                }
            }
            .frame(maxWidth: 920)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(LumenBackground(glow: false))
        .navigationTitle("Cues")
        .sheet(item: $scheduleRoom) { room in
            ScheduleEditorView(room: room).environmentObject(manager)
        }
        .sheet(isPresented: $showingSolarSettings) {
            SolarSettingsView().environmentObject(manager)
        }
        .sheet(isPresented: $showingMissed) {
            MissedAutomationsView().environmentObject(manager)
        }
    }

    private var enabledScheduleCount: Int {
        manager.rooms.flatMap(\.schedules).filter(\.isEnabled).count
    }

    private var pausedRoomCount: Int {
        manager.rooms.filter { manager.activeAutomationOverride(for: $0.id) != nil }.count
    }
}

private struct AutomationRoomCard: View {
    @EnvironmentObject private var manager: LightManager
    let room: Room
    let onEdit: () -> Void

    private var override: RoomAutomationOverride? { manager.activeAutomationOverride(for: room.id) }
    private var currentRoom: Room { manager.rooms.first(where: { $0.id == room.id }) ?? room }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(currentRoom.name).font(LumenType.display(size: 19, weight: .bold))
                    if let override {
                        Label(override.summary, systemImage: "pause.circle.fill")
                            .font(.caption).foregroundStyle(Lumen.warning)
                    } else {
                        Text("\(currentRoom.schedules.filter(\.isEnabled).count) enabled of \(currentRoom.schedules.count)")
                            .font(.caption).foregroundStyle(Lumen.textSecondary)
                    }
                }
                Spacer()
                if override != nil {
                    Button("Resume") { manager.resumeAutomation(for: currentRoom.id) }
                        .buttonStyle(LumenPrimaryButtonStyle(compact: true))
                } else {
                    Menu {
                        ForEach(AutomationOverrideDuration.allCases) { duration in
                            Button(duration.title) { manager.setAutomationOverride(for: currentRoom.id, duration: duration) }
                        }
                    } label: {
                        Label("Pause", systemImage: "pause")
                    }
                    .controlSize(.small)
                    .lumenInteractiveTarget()
                }
                Button("Edit", action: onEdit)
                    .buttonStyle(LumenSecondaryButtonStyle(compact: true))
            }

            if currentRoom.schedules.isEmpty {
                HStack {
                    Text("No schedules yet").foregroundStyle(Lumen.textSecondary)
                    Spacer()
                    Button("Add Schedule", action: onEdit).buttonStyle(.plain).foregroundStyle(Lumen.cyan)
                }
                .font(.callout)
            } else {
                ForEach(currentRoom.schedules) { entry in
                    HStack(spacing: 12) {
                        Image(systemName: entry.isEnabled ? "clock.fill" : "clock")
                            .foregroundStyle(entry.isEnabled ? Lumen.violetBright : Lumen.textTertiary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.action.displayName).font(LumenType.display(size: 15, weight: .semibold))
                            Text("\(entry.timeString) · \(entry.daySummary) · \(manager.nextRunDescription(for: entry))")
                                .font(.caption).foregroundStyle(Lumen.textSecondary).lineLimit(2)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { entry.isEnabled },
                            set: { manager.setScheduleEnabled(entry.id, in: currentRoom.id, enabled: $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(LumenRockerStyle(showsLabel: false))
                        .accessibilityLabel("Enable \(entry.action.displayName) in \(currentRoom.name)")
                    }
                    .padding(12)
                    .background(LumenToken.Background.subtle, in: RoundedRectangle(cornerRadius: 2, style: .continuous))
                }
            }
        }
        .padding(16)
        .lumenCard(fill: override == nil ? Lumen.surface : Lumen.surfaceRaised)
    }
}

// MARK: - Devices and recovery

struct DevicesWorkspaceView: View {
    @EnvironmentObject private var manager: LightManager
    @State private var selectedDevice: LightDevice?
    @State private var showingDiagnostics = false
    @State private var showingDiscovery = false
    @State private var showingActivity = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(eyebrow: "Local link", title: "Rig",
                           subtitle: "Discovery, command response, and recovery from this network in one place.") {
                    Button { manager.scan() } label: {
                        Label(manager.isScanning ? "Scanning" : "Scan", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(LumenPrimaryButtonStyle())
                    .disabled(manager.isScanning)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                    ForEach(manager.scanDiagnostics) { diagnostic in
                        DiagnosticSummaryCard(diagnostic: diagnostic)
                    }
                }

                HStack(spacing: 10) {
                    Button { showingDiagnostics = true } label: {
                        Label("Discovery Diagnostics", systemImage: "stethoscope")
                    }
                    .buttonStyle(LumenSecondaryButtonStyle())
                    Button { showingDiscovery = true } label: {
                        Label("Review Scan", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .buttonStyle(LumenSecondaryButtonStyle())
                    .disabled(manager.discoveryChanges.isEmpty)
                    Button { showingActivity = true } label: {
                        Label("Activity", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(LumenSecondaryButtonStyle())
                    Spacer()
                }

                if !manager.discoveryChanges.isEmpty {
                    Label("\(manager.discoveryChanges.count) change\(manager.discoveryChanges.count == 1 ? "" : "s") from the latest scan need review.",
                          systemImage: "sparkle.magnifyingglass")
                        .font(.callout)
                        .foregroundStyle(Lumen.cyan)
                        .padding(14)
                        .lumenCard(fill: Lumen.surfaceRaised)
                }

                SectionHeader(title: "All devices", detail: "\(manager.devices.count) discovered")

                if manager.devices.isEmpty {
                    EmptyWorkspaceView(icon: "lightbulb.slash", title: "No devices available",
                                       message: "Run discovery or use Demo Mode to inspect command and recovery states.",
                                       primaryTitle: "Scan Again", primaryAction: manager.scan,
                                       secondaryTitle: "Open Demo Workspace", secondaryAction: manager.enterDemoMode)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(manager.devices) { device in
                            DeviceCompactRow(device: device, selectionMode: false, selected: false,
                                             onOpen: { selectedDevice = device }, onToggleSelection: {})
                        }
                    }
                }
            }
            .frame(maxWidth: 1040)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(LumenBackground(glow: false))
        .navigationTitle("Rig")
        .sheet(item: $selectedDevice) { device in
            DeviceInspectorView(device: device).environmentObject(manager)
        }
        .sheet(isPresented: $showingDiagnostics) {
            DiagnosticsCenterView().environmentObject(manager)
        }
        .sheet(isPresented: $showingDiscovery) {
            DiscoveryInboxView().environmentObject(manager)
        }
        .sheet(isPresented: $showingActivity) {
            ActivityLogView().environmentObject(manager)
        }
    }
}

private struct DiagnosticSummaryCard: View {
    let diagnostic: ScanDiagnostic

    private var color: Color {
        switch diagnostic.status {
        case .good: return Lumen.success
        case .warning: return Lumen.warning
        case .neutral: return Lumen.textTertiary
        }
    }

    private var symbol: String {
        switch diagnostic.status {
        case .good: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .neutral: return "info.circle"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(diagnostic.title).font(.caption).foregroundStyle(Lumen.textSecondary)
                Text(diagnostic.value).font(LumenType.display(size: 15, weight: .semibold)).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lumenCard()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Settings

struct SettingsWorkspaceView: View {
    @EnvironmentObject private var manager: LightManager
    @AppStorage("LumenDesk.workspaceLayout.v1") private var layout = WorkspaceLayout.automatic.rawValue
    @AppStorage("LumenDesk.interfaceDensity.v1") private var density = InterfaceDensity.comfortable.rawValue
    @AppStorage(AppPreferenceKey.quietInterface) private var quietInterface = false
    @AppStorage(AppPreferenceKey.confirmationPolicy) private var confirmationPolicy = ConfirmationPolicy.balanced.rawValue
    @AppStorage(AppPreferenceKey.menuBarScope) private var menuBarScope = MenuBarScope.activeRooms.rawValue
    @AppStorage(AppPreferenceKey.showMenuBarUrgentOnly) private var urgentOnly = false
    @AppStorage(AppPreferenceKey.audioPrivacyAcknowledged) private var audioAcknowledged = false
    @AppStorage("LumenDesk.hasOnboarded.v1") private var hasOnboarded = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(eyebrow: "Preferences", title: "Settings",
                           subtitle: "Set the desk's density, confirmation, privacy, and demo behavior.")

                SettingsSection(title: "Workspace", icon: "rectangle.3.group") {
                    SettingSelectorRow(title: "Layout", selection: $layout,
                                       options: WorkspaceLayout.allCases.map {
                                           LumenOption(value: $0.rawValue, title: $0.title)
                                       })
                    SettingSelectorRow(title: "Density", selection: $density,
                                       options: InterfaceDensity.allCases.map {
                                           LumenOption(value: $0.rawValue, title: $0.title)
                                       })
                    SettingSelectorRow(title: "Confirmation", selection: $confirmationPolicy,
                                       options: ConfirmationPolicy.allCases.map {
                                           LumenOption(value: $0.rawValue, title: $0.title)
                                       })
                    Text("Reversible changes run immediately with Undo. Cautious confirmation keeps broad actions explicit.")
                        .font(.caption).foregroundStyle(Lumen.textSecondary)
                }

                SettingsSection(title: "Appearance & accessibility", icon: "accessibility") {
                    Toggle("Quiet interface", isOn: $quietInterface)
                    Text("System Reduce Motion and Reduce Transparency settings are respected automatically. Status always includes text or a symbol.")
                        .font(.caption).foregroundStyle(Lumen.textSecondary)
                }

                SettingsSection(title: "Menu bar", icon: "menubar.rectangle") {
                    SettingSelectorRow(title: "Content", selection: $menuBarScope,
                                       options: MenuBarScope.allCases.map {
                                           LumenOption(value: $0.rawValue, title: $0.title)
                                       })
                    Toggle("Show only rooms needing attention", isOn: $urgentOnly)
                }

                SettingsSection(title: "Privacy", icon: "hand.raised") {
                    Toggle("I understand local audio analysis", isOn: $audioAcknowledged)
                    Text("Music-reactive effects analyze system audio on Mac and microphone input on iPhone or iPad. Audio is processed locally and never retained.")
                        .font(.caption).foregroundStyle(Lumen.textSecondary)
                    Button("Open Privacy Settings") {
                        PlatformOpener.openSettings(macPane: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                    }
                }

                SettingsSection(title: "Demo workspace", icon: "testtube.2") {
                    if manager.isDemoMode {
                        Label("No physical devices are being controlled", systemImage: "checkmark.shield")
                            .foregroundStyle(Lumen.success)
                        HStack {
                            Button("Reset Demo") { manager.resetDemoMode() }
                            Button("Return to Live Lights") { manager.exitDemoMode() }
                                .buttonStyle(LumenPrimaryButtonStyle())
                        }
                    } else {
                        Button("Enter Safe Demo Workspace") { manager.enterDemoMode() }
                            .buttonStyle(LumenPrimaryButtonStyle())
                        Text("Demo changes are isolated from your live rooms and devices.")
                            .font(.caption).foregroundStyle(Lumen.textSecondary)
                    }
                }

                SettingsSection(title: "Setup", icon: "sparkles") {
                    Button("Run Onboarding Again") { hasOnboarded = false }
                    Text("This reopens guided setup; it does not delete rooms, scenes, or device names.")
                        .font(.caption).foregroundStyle(Lumen.textSecondary)
                }
            }
            .frame(maxWidth: 760)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(LumenBackground(glow: false))
        .navigationTitle("Settings")
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Lumen.beamDim)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Lumen.chalk)
                Rectangle().fill(Lumen.ruleSoft).frame(height: 1)
            }
            content
                .toggleStyle(LumenRockerStyle())
        }
        .padding(18)
        .lumenCard()
    }
}

/// A settings row whose choices are always visible. The desk shows its state
/// rather than hiding it behind a pop-up menu.
private struct SettingSelectorRow: View {
    let title: String
    @Binding var selection: String
    let options: [LumenOption<String>]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LumenEyebrow(text: title)
            LumenSelector(label: title, selection: $selection, options: options)
        }
    }
}

// MARK: - Shared product components

private struct PageHeader<Trailing: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let trailing: Trailing

    init(eyebrow: String, title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            LumenTitleBlock(eyebrow: eyebrow, title: title, subtitle: subtitle, size: 38)
            Spacer(minLength: 12)
            trailing
        }
    }
}

private extension PageHeader where Trailing == EmptyView {
    init(eyebrow: String, title: String, subtitle: String) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle) { EmptyView() }
    }
}

private struct SectionHeader: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Lumen.chalk)
            Rectangle()
                .fill(Lumen.ruleSoft)
                .frame(height: 1)
            LumenEyebrow(text: detail)
        }
        .accessibilityElement(children: .combine)
    }
}

struct EmptyWorkspaceView: View {
    let icon: String
    let title: String
    let message: String
    let primaryTitle: String
    let primaryAction: () -> Void
    let secondaryTitle: String
    let secondaryAction: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            LumenIconTile(systemName: icon, tint: Lumen.textTertiary, size: 52)
            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Lumen.chalk)
            Text(message).font(.callout).foregroundStyle(Lumen.textSecondary).multilineTextAlignment(.center)
            HStack {
                Button(primaryTitle, action: primaryAction).buttonStyle(LumenPrimaryButtonStyle())
                Button(secondaryTitle, action: secondaryAction).buttonStyle(LumenSecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .lumenCard(fill: Lumen.surface)
    }
}

private struct EmptyInlineView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            LumenIconTile(systemName: icon, tint: Lumen.textTertiary, size: 40)
            Text(title)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(Lumen.chalk)
            Text(message).font(.caption).foregroundStyle(Lumen.textSecondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .lumenCard()
    }
}

private struct ConnectionSummary: View {
    @EnvironmentObject private var manager: LightManager

    var body: some View {
        HStack(spacing: 9) {
            LumenStatusDot(color: manager.devices.contains(where: \.isStale) ? Lumen.warning : Lumen.success,
                           size: 7,
                           lit: !manager.devices.isEmpty)
            VStack(alignment: .leading, spacing: 3) {
                Text(manager.devices.isEmpty ? "No fixtures" : "Local link")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Lumen.chalk)
                Text(manager.devices.isEmpty ? "Scan to connect" : "\(manager.devices.filter { !$0.isStale }.count) online")
                    .font(LumenType.readout(size: 10))
                    .foregroundStyle(Lumen.textTertiary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct DemoModeBanner: View {
    @EnvironmentObject private var manager: LightManager

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "testtube.2")
                .font(.system(size: 11, weight: .semibold))
            Text("Demo rig. No physical fixtures are being controlled.")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Button("Return to Live") { manager.exitDemoMode() }
                .buttonStyle(LumenSecondaryButtonStyle(compact: true))
        }
        .foregroundStyle(Lumen.warning)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Lumen.warning.opacity(0.10))
        .overlay(alignment: .bottom) { Rectangle().fill(Lumen.warning.opacity(0.45)).frame(height: 1) }
    }
}
