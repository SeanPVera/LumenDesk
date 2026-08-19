import SwiftUI

// MARK: - Stable product navigation

enum LumenDeskDestination: String, CaseIterable, Identifiable {
    case home = "Home"
    case library = "Library"
    case automation = "Automation"
    case devices = "Devices"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .library: return "square.grid.2x2"
        case .automation: return "clock.arrow.2.circlepath"
        case .devices: return "lightbulb.2"
        case .settings: return "gearshape"
        }
    }

    /// Channel number. A lighting desk addresses its destinations by number,
    /// and the numbers make the sidebar scannable without reading the words.
    var channel: String {
        switch self {
        case .home: return "01"
        case .library: return "02"
        case .automation: return "03"
        case .devices: return "04"
        case .settings: return "05"
        }
    }
}

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
        .tint(Lumen.signal)
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
        NavigationSplitView {
            ZStack {
                LumenToken.Background.subtle
                    .ignoresSafeArea()
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        LumenWordmark(size: 17)
                        Text("LOCAL LIGHTING DESK")
                            .font(LumenType.instrumentLabel(size: 8))
                            .tracking(1.6)
                            .foregroundStyle(Lumen.textTertiary)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 20)

                    Rectangle()
                        .fill(Lumen.hairline)
                        .frame(height: 1)
                        .padding(.bottom, 14)

                    VStack(spacing: 2) {
                        ForEach(LumenDeskDestination.allCases) { item in
                            Button {
                                destination = item
                            } label: {
                                SidebarDestinationRow(item: item, selected: destination == item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)

                    Spacer(minLength: 12)

                    ConnectionSummary()
                        .padding(12)
                        .lumenCard(radius: 3)
                        .padding(12)
                }
            }
            .navigationTitle("LumenDesk")
            .navigationSplitViewColumnWidth(min: 200, ideal: 228, max: 260)
        } detail: {
            NavigationStack { destinationView(destination) }
        }
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
                .tabItem { Label("Home", systemImage: LumenDeskDestination.home.symbol) }
                .tag(LumenDeskDestination.home)
            mobileTab(.library)
                .tabItem { Label("Library", systemImage: LumenDeskDestination.library.symbol) }
                .tag(LumenDeskDestination.library)
            mobileTab(.automation)
                .tabItem { Label("Automation", systemImage: LumenDeskDestination.automation.symbol) }
                .tag(LumenDeskDestination.automation)
            mobileTab(.devices)
                .tabItem { Label("Devices", systemImage: LumenDeskDestination.devices.symbol) }
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
        case .home: HomeWorkspaceView()
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
                    Label(summary, systemImage: "arrow.uturn.backward.circle")
                    Button("Undo") { manager.undo() }
                        .disabled(!manager.canUndo)
                    Button { manager.dismissLastActionSummary() } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
                .font(.caption)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Lumen.surfaceRaised, in: LumenPanelShape(radius: 3, chamfer: 12))
                .overlay(
                    LumenPanelShape(radius: 3, chamfer: 12)
                        .stroke(Lumen.hairlineStrong, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.45), radius: 14, y: 4)
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

private struct SidebarDestinationRow: View {
    let item: LumenDeskDestination
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(item.channel)
                .font(LumenType.readout(size: 10, weight: .semibold))
                .foregroundStyle(selected ? Lumen.beamBright : Lumen.textTertiary)
            Image(systemName: item.symbol)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Lumen.beamBright : Lumen.textSecondary)
                .frame(width: 20)
            Text(item.rawValue)
                .font(LumenType.display(size: 14, weight: selected ? .bold : .medium))
                .tracking(0.3)
                .foregroundStyle(selected ? Lumen.textPrimary : Lumen.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .background(
            LumenPanelShape(radius: 2, chamfer: selected ? 10 : 0)
                .fill(selected ? Lumen.surfaceRaised : Color.clear)
        )
        .overlay(alignment: .leading) {
            if selected {
                Rectangle()
                    .fill(Lumen.spectrum)
                    .frame(width: 2, height: 22)
            }
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Home

struct HomeWorkspaceView: View {
    @EnvironmentObject private var manager: LightManager
    @State private var searchText = ""
    @State private var showOnlyOn = false
    @State private var showOfflineOnly = false
    @State private var selectionMode = false
    @State private var selectedIDs: Set<String> = []
    @State private var selectedDevice: LightDevice?
    @State private var selectedRoom: Room?
    @State private var showingNewRoom = false

    private var visibleDevices: [LightDevice] {
        manager.devices.filter { device in
            (searchText.isEmpty || manager.device(device, matchesQuery: searchText)) &&
            (!showOnlyOn || device.isOn) &&
            (!showOfflineOnly || device.isStale)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LumenToken.Spacing.s6) {
                PageHeader(
                    eyebrow: "Live desk · \(greeting)",
                    title: "Home",
                    subtitle: "Power, level, and device response at a glance."
                ) {
                    Menu {
                        Button { showingNewRoom = true } label: {
                            Label("New Room", systemImage: "rectangle.stack.badge.plus")
                        }
                        Button {
                            selectionMode.toggle()
                            if !selectionMode { selectedIDs.removeAll() }
                        } label: {
                            Label(selectionMode ? "Finish Selection" : "Select Lights",
                                  systemImage: "checkmark.circle")
                        }
                        Divider()
                        Button {
                            if manager.napPhase == .inactive { manager.startNapMode() }
                            else { manager.cancelNapMode() }
                        } label: {
                            Label(manager.napPhase == .inactive ? "Start Nap Mode" : "Cancel Nap Mode",
                                  systemImage: "moon")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .lumenInteractiveTarget()
                    .accessibilityLabel("Home actions")
                }

                if manager.devices.isEmpty {
                    EmptyWorkspaceView(
                        icon: "lightbulb.slash",
                        title: "No lights discovered",
                        message: "Scan this network for LIFX and Govee, or try the controls on an isolated demo rig.",
                        primaryTitle: "Scan This Network",
                        primaryAction: manager.scan,
                        secondaryTitle: "Try the Demo Rig",
                        secondaryAction: manager.enterDemoMode
                    )
                } else {
                    ActiveLightingSummary()
                    GlobalLightingControl()

                    if hasFavorites {
                        SectionHeader(title: "Favorites", detail: "Pinned controls")
                        FavoritesQuickStrip(onOpenDevice: { selectedDevice = $0 },
                                            onOpenRoom: { selectedRoom = $0 })
                    }

                    if !manager.rooms.isEmpty {
                        SectionHeader(title: "Rooms", detail: "\(manager.rooms.count) spaces")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                            ForEach(filteredRooms) { room in
                                RoomSummaryCard(room: room, onOpen: { selectedRoom = room })
                            }
                        }
                    }

                    HStack(alignment: .firstTextBaseline) {
                        SectionHeader(title: "Lights", detail: "\(visibleDevices.count) shown")
                        Spacer()
                        if selectionMode {
                            Button("Select Visible") { selectedIDs = Set(visibleDevices.map(\.id)) }
                                .buttonStyle(LumenSecondaryButtonStyle(compact: true))
                        }
                    }

                    WorkspaceFilters(showOnlyOn: $showOnlyOn, showOfflineOnly: $showOfflineOnly)

                    LazyVStack(spacing: 10) {
                        ForEach(visibleDevices) { device in
                            DeviceCompactRow(
                                device: device,
                                selectionMode: selectionMode,
                                selected: selectedIDs.contains(device.id),
                                onOpen: { selectedDevice = device },
                                onToggleSelection: { toggleSelection(device.id) }
                            )
                        }
                    }

                    if visibleDevices.isEmpty {
                        EmptyInlineView(icon: "magnifyingglass", title: "No matching lights",
                                        message: "Clear search or filters to show the rest of your devices.")
                    }
                }
            }
            .frame(maxWidth: 1120)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(LumenBackground(glow: false))
        .navigationTitle("Home")
        .searchable(text: $searchText, prompt: "Search lights and rooms")
        .safeAreaInset(edge: .bottom) {
            if selectionMode && !selectedIDs.isEmpty {
                BulkActionBar(selectedIDs: $selectedIDs, selectionMode: $selectionMode)
                    .padding(12)
                    .background(LumenToken.Background.subtle.opacity(0.96))
            }
        }
        .sheet(item: $selectedDevice) { device in
            LightDetailSheet(device: device)
                .environmentObject(manager)
        }
        .sheet(item: $selectedRoom) { room in
            RoomDetailSheet(room: room)
                .environmentObject(manager)
        }
        .sheet(isPresented: $showingNewRoom) {
            NewRoomSheet()
                .environmentObject(manager)
        }
        .onChange(of: manager.devices.map(\.id)) { ids in
            selectedIDs.formIntersection(Set(ids))
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var hasFavorites: Bool {
        !manager.favoriteDevices.isEmpty || !manager.favoriteRooms.isEmpty || !manager.favoriteScenes.isEmpty
    }

    private var filteredRooms: [Room] {
        guard !searchText.isEmpty else { return manager.rooms }
        return manager.rooms.filter { manager.room($0, matchesQuery: searchText) }
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) }
        else { selectedIDs.insert(id) }
    }
}

private struct ActiveLightingSummary: View {
    @EnvironmentObject private var manager: LightManager

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
            SummaryMetric(icon: manager.isScanning ? "dot.radiowaves.left.and.right" : "wifi",
                          tint: manager.devices.contains(where: \.isStale) ? Lumen.warning : Lumen.success,
                          value: manager.isScanning ? "Scanning" : connectionValue,
                          label: manager.isScanning ? manager.scanPhase : "Local link")
            SummaryMetric(icon: "waveform",
                          tint: manager.activeEffects.isEmpty ? Lumen.textTertiary : Lumen.pinkBright,
                          value: manager.activeEffects.isEmpty ? "None" : "\(manager.activeEffects.count) running",
                          label: "Live motion")
            SummaryMetric(icon: "clock.badge.exclamationmark",
                          tint: manager.missedAutomations.isEmpty ? Lumen.textTertiary : Lumen.warning,
                          value: manager.missedAutomations.isEmpty ? "On track" : "\(manager.missedAutomations.count) missed",
                          label: "Cue status")
        }
    }

    private var connectionValue: String {
        let reachable = manager.devices.filter { !$0.isStale }.count
        return "\(reachable) of \(manager.devices.count) online"
    }
}

private struct SummaryMetric: View {
    let icon: String
    let tint: Color
    let value: String
    let label: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    LumenStatusDot(color: tint, size: 6)
                    Text(label.uppercased())
                        .font(LumenType.instrumentLabel(size: 9))
                        .tracking(1.1)
                        .foregroundStyle(Lumen.textTertiary)
                        .lineLimit(1)
                }
                Text(value)
                    .font(LumenType.readout(size: 17, weight: .semibold))
                    .foregroundStyle(Lumen.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lumenCard(radius: 4)
        .accessibilityElement(children: .combine)
    }
}

private struct GlobalLightingControl: View {
    @EnvironmentObject private var manager: LightManager

    private var onCount: Int { manager.devices.filter(\.isOn).count }
    private var averageBrightness: Double {
        let active = manager.devices.filter(\.isOn)
        guard !active.isEmpty else { return 0 }
        return active.reduce(0) { $0 + $1.brightness } / Double(active.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    LumenEyebrow(text: "Master", tint: Lumen.beamBright, size: 10)
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text("\(Int(averageBrightness * 100))")
                            .font(LumenType.readout(size: 50, weight: .semibold))
                            .foregroundStyle(Lumen.textPrimary)
                            .monospacedDigit()
                        Text("%")
                            .font(LumenType.readout(size: 16, weight: .medium))
                            .foregroundStyle(Lumen.textTertiary)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 12) {
                    HStack(spacing: 7) {
                        LumenStatusDot(color: onCount > 0 ? Lumen.beamBright : Lumen.offline,
                                       size: 6, lit: onCount > 0)
                        Text("\(onCount) ON · \(manager.devices.count - onCount) OFF")
                            .font(LumenType.instrumentLabel(size: 10))
                            .tracking(0.9)
                            .foregroundStyle(Lumen.textSecondary)
                    }
                    Button {
                        manager.setAllPower(on: onCount == 0)
                    } label: {
                        Text(onCount == 0 ? "All On" : "All Off")
                    }
                    .buttonStyle(LumenPrimaryButtonStyle())
                    .disabled(manager.devices.isEmpty)
                    .accessibilityLabel(onCount == 0 ? "Turn all lights on" : "Turn all lights off")
                }
            }

            LumenFader(
                label: "All lights",
                value: Binding(get: { averageBrightness }, set: manager.setAllBrightness),
                track: .beam
            )
            .disabled(manager.devices.isEmpty)
        }
        .padding(20)
        .lumenCard(fill: Lumen.surfaceRaised, highlighted: true)
    }
}

private struct WorkspaceFilters: View {
    @Binding var showOnlyOn: Bool
    @Binding var showOfflineOnly: Bool

    var body: some View {
        HStack(spacing: 8) {
            LumenEyebrow(text: "Filter")
            Toggle("On", isOn: $showOnlyOn)
                .toggleStyle(LumenChipStyle())
            Toggle("Needs attention", isOn: $showOfflineOnly)
                .toggleStyle(LumenChipStyle())
            if showOnlyOn || showOfflineOnly {
                Button("Clear") {
                    showOnlyOn = false
                    showOfflineOnly = false
                }
                .buttonStyle(.plain)
                .font(LumenType.instrumentLabel(size: 10))
                .foregroundStyle(Lumen.cyan)
            }
            Spacer()
        }
        .controlSize(.small)
    }
}

private struct FavoritesQuickStrip: View {
    @EnvironmentObject private var manager: LightManager
    let onOpenDevice: (LightDevice) -> Void
    let onOpenRoom: (Room) -> Void
    @State private var previewScene: LightingScene?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(manager.favoriteDevices) { device in
                    FavoriteDeviceTile(device: device, onOpen: { onOpenDevice(device) })
                }
                ForEach(manager.favoriteRooms) { room in
                    FavoriteRoomTile(room: room, onOpen: { onOpenRoom(room) })
                }
                ForEach(manager.favoriteScenes) { scene in
                    FavoriteSceneTile(scene: scene, onPreview: { previewScene = scene })
                }
            }
            .padding(.vertical, 2)
        }
        .sheet(item: $previewScene) { scene in
            ScenePreviewView(scene: scene).environmentObject(manager)
        }
    }
}

private struct FavoriteDeviceTile: View {
    @EnvironmentObject private var manager: LightManager
    @ObservedObject var device: LightDevice
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                LumenLens(color: device.color, isOn: device.isOn, size: 30, isStale: device.isStale)
                Spacer()
                Toggle("", isOn: Binding(get: { device.isOn }, set: { manager.setPower(device, on: $0) }))
                    .labelsHidden()
                    .toggleStyle(LumenPowerKeyStyle(size: 28, spokenLabel: "Power for \(device.label)"))
            }
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.label).font(LumenType.display(size: 15, weight: .semibold)).lineLimit(1)
                    Text("\(Int(device.brightness * 100))% · \(device.isStale ? "OFFLINE" : "ONLINE")")
                        .font(LumenType.instrumentLabel(size: 9))
                        .tracking(0.7)
                        .foregroundStyle(Lumen.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .lumenInteractiveTarget()
        }
        .padding(14)
        .frame(width: 180)
        .lumenCard(highlighted: true)
    }
}

private struct FavoriteRoomTile: View {
    @EnvironmentObject private var manager: LightManager
    let room: Room
    let onOpen: () -> Void

    private var lights: [LightDevice] { manager.devices(in: room) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                LumenIconTile(systemName: "rectangle.stack.fill", tint: Lumen.beamDim, size: 30)
                Spacer()
                Button { manager.setPower(in: room, on: lights.filter(\.isOn).count < lights.count) } label: {
                    Image(systemName: manager.aggregatePowerState(for: lights).symbol)
                }
                .buttonStyle(LumenIconButtonStyle(size: 28))
                .disabled(lights.isEmpty)
                .accessibilityLabel("Toggle all lights in \(room.name)")
            }
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(room.name).font(LumenType.display(size: 15, weight: .semibold)).lineLimit(1)
                    Text(lights.isEmpty ? "NO LIGHTS" : "\(lights.filter(\.isOn).count) OF \(lights.count) ON")
                        .font(LumenType.instrumentLabel(size: 9))
                        .tracking(0.7)
                        .foregroundStyle(Lumen.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .lumenInteractiveTarget()
        }
        .padding(14)
        .frame(width: 180)
        .lumenCard(highlighted: true)
    }
}

private struct FavoriteSceneTile: View {
    @EnvironmentObject private var manager: LightManager
    let scene: LightingScene
    let onPreview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LumenIconTile(systemName: "wand.and.stars", tint: Lumen.beamDim, size: 30)
            Text(scene.name).font(LumenType.display(size: 15, weight: .semibold)).lineLimit(1)
            Text("\(scene.snapshots.count) LIGHTS")
                .font(LumenType.instrumentLabel(size: 9))
                .tracking(0.7)
                .foregroundStyle(Lumen.textTertiary)
            Button("Preview", action: onPreview)
                .buttonStyle(LumenSecondaryButtonStyle())
                .disabled(manager.availableDeviceIDs(for: scene).isEmpty)
            if manager.availableDeviceIDs(for: scene).isEmpty {
                Text("No available lights")
                    .font(.caption2).foregroundStyle(Lumen.warning)
            }
        }
        .padding(14)
        .frame(width: 180, alignment: .leading)
        .lumenCard(highlighted: true)
    }
}

private struct RoomSummaryCard: View {
    @EnvironmentObject private var manager: LightManager
    let room: Room
    let onOpen: () -> Void

    private var lights: [LightDevice] { manager.devices(in: room) }
    private var onCount: Int { lights.filter(\.isOn).count }
    private var staleCount: Int { lights.filter(\.isStale).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Button(action: onOpen) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(room.name).font(LumenType.display(size: 19, weight: .bold)).lineLimit(1)
                        Text(lights.isEmpty ? "NO LIGHTS" : "\(onCount) OF \(lights.count) ON")
                            .font(LumenType.instrumentLabel(size: 10))
                            .tracking(0.9)
                            .foregroundStyle(Lumen.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .lumenInteractiveTarget()
                Spacer()
                Button { manager.setPower(in: room, on: lights.filter(\.isOn).count < lights.count) } label: {
                    Image(systemName: manager.aggregatePowerState(for: lights).symbol)
                }
                .buttonStyle(LumenIconButtonStyle(size: 30, prominent: onCount > 0))
                .disabled(lights.isEmpty)
                .accessibilityLabel("Toggle all lights in \(room.name)")
            }

            if !lights.isEmpty {
                HStack(spacing: 4) {
                    ForEach(lights.prefix(8)) { light in
                        LumenLens(color: light.color, isOn: light.isOn, size: 16)
                    }
                    Spacer()
                    if staleCount > 0 {
                        Label("\(staleCount) offline", systemImage: "wifi.slash")
                            .font(.caption).foregroundStyle(Lumen.warning)
                    } else {
                        Label("Online", systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(Lumen.success)
                    }
                }
            } else {
                Label("No lights are assigned to this room.", systemImage: "lightbulb.slash")
                    .font(.caption).foregroundStyle(Lumen.textSecondary)
            }

            HStack {
                Label("\(room.schedules.filter(\.isEnabled).count) schedules", systemImage: "clock")
                    .font(.caption).foregroundStyle(Lumen.textSecondary)
                Spacer()
                Button("Open", action: onOpen)
                    .buttonStyle(.plain)
                    .foregroundStyle(Lumen.cyan)
                    .lumenInteractiveTarget()
            }
        }
        .padding(16)
        .lumenCard(fill: onCount > 0 ? Lumen.surfaceRaised : Lumen.surface, highlighted: onCount > 0)
        .accessibilityElement(children: .contain)
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
                        .foregroundStyle(selected ? Lumen.beamBright : Lumen.textTertiary)
                }
                .buttonStyle(.plain)
                .lumenInteractiveTarget()
                .accessibilityLabel(selected ? "Deselect \(device.label)" : "Select \(device.label)")
            }

            LumenLens(color: device.color, isOn: device.isOn, size: 40, isStale: device.isStale)

            Button(action: selectionMode ? onToggleSelection : onOpen) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(device.label).font(LumenType.display(size: 15, weight: .semibold)).lineLimit(1)
                        if manager.isFavorite(device.id) {
                            Image(systemName: "star.fill").font(.caption2).foregroundStyle(Lumen.gold)
                        }
                    }
                    Text("\(device.brand.displayName.uppercased()) · \(Int(device.brightness * 100))% · \(device.kelvin)K")
                        .font(LumenType.instrumentLabel(size: 9))
                        .tracking(0.7)
                        .foregroundStyle(Lumen.textTertiary)
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
                        .buttonStyle(LumenSecondaryButtonStyle())
                }
                Toggle("", isOn: Binding(get: { device.isOn }, set: { manager.setPower(device, on: $0) }))
                    .labelsHidden()
                    .toggleStyle(LumenPowerKeyStyle(size: 32, spokenLabel: "Power for \(device.label)"))
            }
        }
        .padding(14)
        .lumenCard(fill: selected ? Lumen.surfaceLoud : Lumen.surface, highlighted: selected)
        .opacity(device.isStale ? 0.82 : 1)
    }
}

private struct DeviceStateBadge: View {
    let device: LightDevice
    let command: DeviceCommandState

    private var presentation: (title: String, icon: String, color: Color) {
        switch command.phase {
        case .queued: return ("Queued", "clock", Lumen.warning)
        case .sending: return ("Sending", "arrow.up.circle", Lumen.cyan)
        case .applied: return ("Confirmed", "checkmark.circle.fill", Lumen.success)
        case .failed: return ("Failed", "exclamationmark.triangle.fill", Lumen.danger)
        case .idle:
            return device.isStale
                ? ("Offline", "wifi.slash", Lumen.offline)
                : ("Online", "checkmark.circle", Lumen.success)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            LumenStatusDot(color: presentation.color, size: 6)
            Text(presentation.title.uppercased())
                .font(LumenType.instrumentLabel(size: 9))
                .tracking(0.9)
                .foregroundStyle(presentation.color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(presentation.color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .stroke(presentation.color.opacity(0.3), lineWidth: 1)
        )
        .accessibilityLabel("Status: \(presentation.title)")
    }
}

private struct LightDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var device: LightDevice

    var body: some View {
        NavigationStack {
            ScrollView {
                LightRowView(device: device)
                    .padding(20)
            }
            .background(LumenBackground(glow: false))
            .navigationTitle(device.label)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .sheetFrame(minWidth: 600, idealWidth: 720, minHeight: 560, idealHeight: 700)
    }
}

private struct RoomDetailSheet: View {
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

private struct NewRoomSheet: View {
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

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(eyebrow: "Scenes · Color · Motion", title: "Library",
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
        .navigationTitle("Library")
        .searchable(text: $searchText, prompt: "Search library")
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
                        Text(theme.category.rawValue.uppercased())
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
                PageHeader(eyebrow: "Cues and timing", title: "Automation",
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
        .navigationTitle("Automation")
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
                PageHeader(eyebrow: "Local link", title: "Devices",
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
        .navigationTitle("Devices")
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
                Text(title.uppercased())
                    .font(LumenType.display(size: 15, weight: .bold))
                    .tracking(1.1)
                Rectangle().fill(Lumen.hairline).frame(height: 1)
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
            VStack(alignment: .leading, spacing: 7) {
                LumenEyebrow(text: eyebrow, tint: Lumen.beamDim)
                Text(title.uppercased())
                    .font(LumenType.display(size: 38, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(Lumen.textPrimary)
                SpectrumRule(height: 2, tapered: true)
                    .frame(width: 190)
                    .padding(.bottom, 2)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(Lumen.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            Text(title.uppercased())
                .font(LumenType.display(size: 17, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(Lumen.textPrimary)
            Rectangle()
                .fill(Lumen.hairline)
                .frame(height: 1)
            LumenEyebrow(text: detail)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct EmptyWorkspaceView: View {
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
            Text(title.uppercased())
                .font(LumenType.display(size: 20, weight: .bold))
                .tracking(1.1)
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
            Text(title.uppercased())
                .font(LumenType.display(size: 15, weight: .bold))
                .tracking(0.9)
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
                Text(manager.devices.isEmpty ? "NO LIGHTS" : "LOCAL LINK")
                    .font(LumenType.instrumentLabel(size: 9))
                    .tracking(1.2)
                    .foregroundStyle(Lumen.textPrimary)
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
            Text("DEMO MODE — NO PHYSICAL LIGHTS ARE BEING CONTROLLED")
                .font(LumenType.instrumentLabel(size: 9))
                .tracking(1.1)
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
