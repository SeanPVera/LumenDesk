import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ContentView: View {
    @EnvironmentObject var manager: LightManager

    @State private var showingNewRoom: Bool = false
    @State private var newRoomName: String = ""
    @State private var setupChecks: Set<Int> = []
    @State private var showingScenes: Bool = false
    @State private var showingShortcuts: Bool = false
    @AppStorage("LumenDesk.auroraFireflies.v1") private var auroraFireflies: Bool = true
    @State private var showingDiagnostics = false
    @State private var showingActivity = false
    @State private var showingParliament = false
    @State private var showingEcosystem = false
    @State private var showingCompliance = false
    @State private var showingDiscoveryInbox = false
    @State private var showingMissedAutomations = false
    @State private var showingIdentifyMode = false
    @State private var showingExperienceCenter = false
    @AppStorage(AppPreferenceKey.quietInterface) private var quietInterface = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("LumenDesk.workspaceLayout.v1") private var layoutRaw = WorkspaceLayout.automatic.rawValue
    @AppStorage("LumenDesk.interfaceDensity.v1") private var densityRaw = InterfaceDensity.comfortable.rawValue

    @AppStorage("LumenDesk.searchText.v1") private var searchText: String = ""
    @FocusState private var searchFocused: Bool
    @AppStorage("LumenDesk.showOnlyOn.v1") private var showOnlyOn: Bool = false
    @State private var showOfflineOnly = false
    @State private var vendorFilter: LightDevice.Brand?
    @AppStorage("LumenDesk.searchScope.v1") private var searchScopeRaw = SearchScope.all.rawValue

    @State private var selectionMode: Bool = false
    @State private var selectedIDs: Set<String> = []

    private let gridThreshold: CGFloat = 780

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                if manager.isDemoMode {
                    HStack { Label("SAFE DEMO — no physical lights are being controlled", systemImage: "testtube.2").font(.caption.bold()); Spacer(); Button("Return to Live") { manager.exitDemoMode() }.controlSize(.small) }
                        .padding(.horizontal, 16).padding(.vertical, 6).background(Color.orange.opacity(0.16))
                }

                if manager.devices.isEmpty {
                    emptyState
                } else if searchScope == .scenes {
                    sceneSearchResults
                } else {
                    TodayLightingTimelineView(showingMissedAutomations: $showingMissedAutomations, showingExperienceCenter: $showingExperienceCenter)
                        .padding(.horizontal, 16)
                        .padding(.top, density == .compact ? 6 : 10)

                    LightingIntentDockView()
                        .padding(.horizontal, 16)
                        .padding(.top, density == .compact ? 6 : 10)

                    FavoritesStripView()
                        .padding(.horizontal, 16)
                        .padding(.top, density == .compact ? 6 : 12)

                    GeometryReader { proxy in
                        if effectiveLayout(for: proxy.size.width) == .grid { gridLayout } else { listLayout }
                    }
                }
            }
            .background(LumenBackground())
            .background(findShortcutButton)
            .sheet(isPresented: $showingNewRoom) { newRoomSheet }
            .sheet(isPresented: $showingScenes) {
                ScenesView().environmentObject(manager)
            }
            .sheet(isPresented: $showingShortcuts) { KeyboardShortcutsView() }
            .sheet(isPresented: $showingDiagnostics) { DiagnosticsCenterView().environmentObject(manager) }
            .sheet(isPresented: $showingActivity) { ActivityLogView().environmentObject(manager) }
            .sheet(isPresented: $showingParliament) { LightingParliamentView().environmentObject(manager) }
            .sheet(isPresented: $showingEcosystem) { FireflyEcosystemView().environmentObject(manager) }
            .sheet(isPresented: $showingCompliance) { ComplianceSuiteView().environmentObject(manager) }
            .sheet(isPresented: $showingDiscoveryInbox) { DiscoveryInboxView().environmentObject(manager) }
            .sheet(isPresented: $showingMissedAutomations) { MissedAutomationsView().environmentObject(manager) }
            .sheet(isPresented: $showingIdentifyMode) { IdentifyLightsView().environmentObject(manager) }
            .sheet(isPresented: $showingExperienceCenter) { ExperienceCenterView().environmentObject(manager) }

            if selectionMode && !selectedIDs.isEmpty {
                VStack(spacing: 6) {
                    if !selectedIDs.subtracting(visibleDeviceIDs).isEmpty {
                        Text("\(selectedIDs.count) selected · \(selectedIDs.subtracting(visibleDeviceIDs).count) hidden by filters")
                            .font(.caption).padding(.horizontal, 10).padding(.vertical, 5).background(Lumen.warning.opacity(0.18), in: Capsule())
                    }
                    BulkActionBar(selectedIDs: $selectedIDs, selectionMode: $selectionMode)
                    .padding(.bottom, manager.commandError == nil ? 16 : 72)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            if auroraFireflies && !quietInterface && !reduceMotion && !manager.devices.isEmpty {
                AuroraFireflyOverlay(colors: manager.fireflyCitizens.map { Color(hue: $0.hue, saturation: 0.82, brightness: max(0.45, $0.energy)) })
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if let summary = manager.lastActionSummary {
                HStack(spacing: 10) {
                    Label(summary, systemImage: "arrow.uturn.backward.circle")
                    Button("Undo") { manager.undo() }.disabled(!manager.canUndo)
                    Button { manager.dismissLastActionSummary() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .font(.caption).padding(.horizontal, 12).padding(.vertical, 8)
                .background(reduceTransparency ? Color.black : Color.black.opacity(0.8), in: Capsule())
                .padding(.bottom, manager.commandError == nil ? 16 : 70)
                .accessibilityElement(children: .combine)
            }

            if let error = manager.commandError {
                CommandToastView(
                    message: error,
                    undoAction: manager.commandErrorUndo,
                    dismiss: { manager.commandError = nil }
                )
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.25), value: manager.commandError)
        .animation(.spring(duration: 0.25), value: selectionMode)
        .onChange(of: manager.devices.map(\.id)) { ids in selectedIDs.formIntersection(Set(ids)) }
    }

    private var findShortcutButton: some View {
        Button { searchFocused = true } label: { EmptyView() }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .disabled(manager.devices.isEmpty)
    }

    // MARK: - Mood-ring

    /// Aggregate colour of all currently-on lights: hue/saturation averaged,
    /// brightness proportional to how many lights are on. Falls back to warm
    /// yellow when nothing is on (classic "off" bulb look).
    private var moodColor: Color {
        let on = manager.devices.filter { $0.isOn }
        guard !on.isEmpty else { return .yellow }
        let hsbs = on.map { $0.color.hsbComponents }
        let avgH = hsbs.reduce(0.0) { $0 + $1.h } / Double(on.count)
        let avgS = hsbs.reduce(0.0) { $0 + $1.s } / Double(on.count)
        let avgB = on.reduce(0.0) { $0 + $1.brightness } / Double(on.count)
        return Color(hue: avgH, saturation: avgS, brightness: max(0.5, avgB))
    }

    private var moodGlowRadius: CGFloat {
        let fraction = Double(manager.devices.filter { $0.isOn }.count) /
                       max(1, Double(manager.devices.count))
        return CGFloat(fraction * 12)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Lumen.brandGradient)
                        .frame(width: 58, height: 58)
                        .shadow(color: moodColor.opacity(0.75), radius: 22)
                    Image(systemName: "lightbulb.max.fill")
                        .font(.system(size: 31, weight: .black))
                        .foregroundStyle(.black.opacity(0.82))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.28), lineWidth: 1)
                )
                .animation(.easeInOut(duration: 0.6), value: moodColor)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("LumenDesk")
                        .font(.system(size: 36, weight: .black, design: .rounded))
                        .kerning(-1.2)
                        .foregroundStyle(Lumen.brandGradient)
                    Text(headerSubtitle.uppercased())
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .kerning(1.5)
                        .foregroundStyle(Lumen.acid)
                }
                Spacer()
                if manager.isScanning {
                    ProgressView().controlSize(.small)
                        .help(manager.scanPhase)
                }
                Button {
                    if manager.napPhase != .inactive { manager.cancelNapMode() } else { manager.startNapMode() }
                } label: {
                    Label(
                        manager.napPhase == .inactive ? "Nap" : manager.napCountdownString,
                        systemImage: manager.napPhase == .inactive ? "moon.fill" : "xmark.circle.fill"
                    )
                }
                .help(manager.napPhase == .inactive
                      ? "Nap Mode — dims all lights over 20 minutes, holds, then brightens gently to wake you"
                      : "Cancel Nap Mode")
                .tint(manager.napPhase == .inactive ? .indigo : .orange)
                if !manager.devices.isEmpty {
                    Button {
                        selectionMode.toggle()
                        if !selectionMode { selectedIDs.removeAll() }
                    } label: {
                        Label(selectionMode ? "Done" : "Select",
                              systemImage: selectionMode ? "checkmark.circle.fill" : "checkmark.circle")
                    }
                    .help(selectionMode ? "Exit selection mode" : "Select multiple lights for bulk actions")
                    if selectionMode {
                        Button("Select Visible") { selectedIDs = visibleDeviceIDs }
                            .disabled(visibleDeviceIDs.isEmpty)
                        Button("Clear") { selectedIDs.removeAll() }
                            .disabled(selectedIDs.isEmpty)
                    }
                }
                Button { showingExperienceCenter = true } label: {
                    Label("Experience", systemImage: "sparkles.rectangle.stack")
                }
                .help("Open the differentiated UX cockpit: timeline, map, safety, scene confidence, diary, and creative tools")
                Button { showingScenes = true } label: {
                    Label("Library", systemImage: "wand.and.stars")
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .help("Browse themes, effects, and saved scenes (⇧⌘S)")
                Button {
                    newRoomName = ""
                    showingNewRoom = true
                } label: {
                    Label("New Room", systemImage: "rectangle.stack.badge.plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                Button { manager.scan() } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                Menu {
                    Button { newRoomName = ""; showingNewRoom = true } label: { Label("New Room", systemImage: "rectangle.stack.badge.plus") }
                    Button { selectionMode.toggle(); if !selectionMode { selectedIDs.removeAll() } } label: { Label(selectionMode ? "Finish Selection" : "Select Lights", systemImage: "checkmark.circle") }
                    Button { showingExperienceCenter = true } label: { Label("Experience Center", systemImage: "sparkles.rectangle.stack") }
                    Button { showingIdentifyMode = true } label: { Label("Identify Lights", systemImage: "lightbulb.2") }
                        .disabled(manager.devices.isEmpty)
                    Button { showingShortcuts = true } label: { Label("Keyboard Shortcuts", systemImage: "keyboard") }
                    Divider()
                    Picker("Layout", selection: $layoutRaw) { ForEach(WorkspaceLayout.allCases) { Text($0.title).tag($0.rawValue) } }
                    Picker("Density", selection: $densityRaw) { ForEach(InterfaceDensity.allCases) { Text($0.title).tag($0.rawValue) } }
                    Divider()
                    Toggle("Aurora Fireflies", isOn: $auroraFireflies)
                    Button { if manager.napPhase != .inactive { manager.cancelNapMode() } else { manager.startNapMode() } } label: { Label(manager.napPhase == .inactive ? "Start Nap Mode" : "Cancel Nap Mode", systemImage: "moon.fill") }
                    Divider()
                    Button { showingDiagnostics = true } label: { Label("Discovery Diagnostics", systemImage: "stethoscope") }
                    Button { showingDiscoveryInbox = true } label: { Label("Review Discovery Changes", systemImage: "tray.full") }
                    if !manager.missedAutomations.isEmpty { Button { showingMissedAutomations = true } label: { Label("Missed Automations (\(manager.missedAutomations.count))", systemImage: "clock.badge.exclamationmark") } }
                    if !manager.commandPendingIDs.isEmpty { Button("Cancel Queued Commands") { manager.cancelQueuedCommands() } }
                    Button { showingActivity = true } label: { Label("Activity Log", systemImage: "clock.arrow.circlepath") }
                    Divider()
                    Menu("Labs") {
                        Toggle("Aurora Fireflies", isOn: $auroraFireflies)
                        Button { showingParliament = true } label: { Label("Lighting Parliament", systemImage: "building.columns") }
                        Button { showingEcosystem = true } label: { Label("Firefly Conservatory", systemImage: "ladybug") }
                        Button { showingCompliance = true } label: { Label("Lumens Compliance", systemImage: "checkmark.seal") }
                    }
                } label: { Label("More", systemImage: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)

            if !manager.devices.isEmpty {
                Divider()
                HStack(spacing: 10) {
                    Button { manager.toggleAggregatePower(manager.devices) } label: {
                        let state = manager.aggregatePowerState(for: manager.devices)
                        Label(state.title, systemImage: state.symbol).font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .tint(manager.devices.contains(where: \.isOn) ? Lumen.pink : .secondary)
                    .help("Aggregate power state — mixed rooms are shown explicitly")
                    .accessibilityLabel("All lights: \(manager.aggregatePowerState(for: manager.devices).title)")
                    Image(systemName: "sun.min").foregroundStyle(.secondary).font(.caption)
                        .accessibilityHidden(true)
                    Slider(value: globalBrightnessBinding, in: 0...1)
                        .disabled(manager.devices.allSatisfy { !$0.isOn })
                        .accessibilityLabel("Global brightness")
                        .accessibilityValue("\(Int(globalBrightnessBinding.wrappedValue * 100)) percent")
                    Image(systemName: "sun.max").foregroundStyle(.secondary).font(.caption)
                        .accessibilityHidden(true)
                    Text("All Lights")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider()
                searchBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                searchSummary
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .background(
            ZStack {
                Lumen.ink.opacity(0.92)
                LinearGradient(colors: [Lumen.surfaceLoud.opacity(0.95), Lumen.ink.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Lumen.brandGradient)
                .frame(height: 3)
                .shadow(color: Lumen.cyan.opacity(0.55), radius: 8)
        }
    }

    private var headerSubtitle: String {
        if !manager.statusMessage.isEmpty { return manager.statusMessage }
        if manager.isScanning { return manager.scanPhase }
        if selectionMode {
            return selectedIDs.isEmpty
                ? "Select lights to act on them in bulk"
                : "\(selectedIDs.count) of \(manager.devices.count) selected"
        }
        if showOnlyOn {
            let onCount = manager.devices.filter { $0.isOn }.count
            return "\(onCount) light\(onCount == 1 ? "" : "s") on"
        }
        return "\(manager.devices.count) light\(manager.devices.count == 1 ? "" : "s") on this network"
    }

    // MARK: - Search bar (with on-only filter toggle)

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("Search lights, rooms, or scenes", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Lumen.surfaceLoud)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(searchFocused ? Color.accentColor : Lumen.hairline,
                            lineWidth: searchFocused ? 1.5 : 1)
            )

            Picker("Scope", selection: $searchScopeRaw) { ForEach(SearchScope.allCases) { Text($0.title).tag($0.rawValue) } }
                .pickerStyle(.menu).frame(width: 90)

            // "On only" filter chip
            Toggle(isOn: $showOnlyOn) {
                Label("On only", systemImage: "lightbulb.fill")
                    .font(.caption.weight(.medium))
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .tint(Lumen.gold)
            .help("Show only lights that are currently on")
            .accessibilityLabel("Filter to on lights only")

            Toggle(isOn: $showOfflineOnly) { Label("Offline", systemImage: "wifi.slash").font(.caption.weight(.medium)) }
                .toggleStyle(.button).controlSize(.small).tint(Lumen.warning)
            Menu {
                Button("All Vendors") { vendorFilter = nil }
                Button("LIFX") { vendorFilter = .lifx }
                Button("Govee") { vendorFilter = .govee }
            } label: { Label(vendorFilter?.displayName ?? "Vendor", systemImage: "line.3.horizontal.decrease.circle").font(.caption) }
            .menuStyle(.borderlessButton)
            if showOnlyOn || showOfflineOnly || vendorFilter != nil {
                Button("Clear Filters") { showOnlyOn = false; showOfflineOnly = false; vendorFilter = nil }
                    .controlSize(.small)
            }
        }
    }

    private var searchSummary: some View {
        let hidden = max(0, manager.devices.count - visibleDeviceIDs.count)
        let hiddenSelected = selectedIDs.subtracting(visibleDeviceIDs).count
        return HStack(spacing: 8) {
            Label("Showing \(visibleDeviceIDs.count) of \(manager.devices.count) lights", systemImage: "line.3.horizontal.decrease.circle")
            if !visibleRooms.isEmpty { Text("· \(visibleRooms.count) room\(visibleRooms.count == 1 ? "" : "s")") }
            if hidden > 0 { Text("· \(hidden) hidden") }
            if hiddenSelected > 0 { Text("· \(hiddenSelected) selected hidden").foregroundStyle(Lumen.warning) }
            Spacer()
            if !searchText.isEmpty || showOnlyOn || showOfflineOnly || vendorFilter != nil {
                Button("Reset view") { searchText = ""; showOnlyOn = false; showOfflineOnly = false; vendorFilter = nil }
                    .controlSize(.small)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Layout

    private var visibleRooms: [Room] {
        guard searchScope != .lights else { return [] }
        return manager.rooms.filter { room in
            let matchesSearch = manager.room(room, matchesQuery: searchText)
            guard matchesSearch else { return false }
            let lights = manager.devices(in: room)
            if showOnlyOn && !lights.contains(where: \.isOn) { return false }
            if showOfflineOnly && !lights.contains(where: \.isStale) { return false }
            if let vendorFilter, !lights.contains(where: { $0.brand == vendorFilter }) { return false }
            return true
        }
    }

    private var visibleUnassigned: [LightDevice] {
        guard searchScope != .rooms else { return [] }
        return manager.unassignedDevices.filter { device in
            let matchesSearch = manager.device(device, matchesQuery: searchText)
            guard matchesSearch else { return false }
            if showOnlyOn && !device.isOn { return false }
            if showOfflineOnly && !device.isStale { return false }
            if let vendorFilter, device.brand != vendorFilter { return false }
            return true
        }
    }

    private var visibleDeviceIDs: Set<String> {
        var ids = Set(visibleUnassigned.map { $0.id })
        for room in visibleRooms {
            ids.formUnion(manager.devices(in: room).filter { device in
                manager.device(device, matchesQuery: searchText) && (!showOnlyOn || device.isOn) && (!showOfflineOnly || device.isStale) && (vendorFilter == nil || device.brand == vendorFilter)
            }.map { $0.id })
        }
        return ids
    }

    private var listLayout: some View {
        List {
            ForEach(visibleRooms) { room in
                RoomSectionView(
                    room: room,
                    searchQuery: searchText,
                    showOnlyOn: showOnlyOn,
                    showOfflineOnly: showOfflineOnly,
                    vendorFilter: vendorFilter,
                    selectionMode: selectionMode,
                    selectedIDs: selectedIDs,
                    onToggleSelection: toggleSelection
                )
                .listRowInsets(EdgeInsets(top: density == .compact ? 4 : 9, leading: 16, bottom: density == .compact ? 4 : 9, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .onMove { offsets, destination in
                guard searchText.isEmpty else { return }
                manager.moveRooms(from: offsets, to: destination)
            }

            unassignedSection
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var gridLayout: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ],
                alignment: .leading,
                spacing: density == .compact ? 10 : 18
            ) {
                ForEach(visibleRooms) { room in
                    RoomSectionView(
                        room: room,
                        searchQuery: searchText,
                        showOnlyOn: showOnlyOn,
                        showOfflineOnly: showOfflineOnly,
                        vendorFilter: vendorFilter,
                        selectionMode: selectionMode,
                        selectedIDs: selectedIDs,
                        onToggleSelection: toggleSelection
                    )
                }
                if !visibleUnassigned.isEmpty {
                    unassignedGridSection
                }
            }
            .padding(16)
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    private var searchScope: SearchScope { SearchScope(rawValue: searchScopeRaw) ?? .all }

    private var sceneSearchResults: some View {
        let matches = manager.scenes.filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Scene Results").font(.headline); Text("\(matches.count)").foregroundStyle(.secondary); Spacer(); Button("Open Scene Library") { showingScenes = true } }
            if matches.isEmpty { Spacer(); Text("No scenes match your search.").foregroundStyle(.secondary).frame(maxWidth: .infinity); Spacer() }
            else { List(matches) { scene in HStack { Label(scene.name, systemImage: "wand.and.stars"); Spacer(); Text("\(scene.snapshots.count) lights").foregroundStyle(.secondary); Button("Apply") { manager.applyScene(scene) } } }.listStyle(.inset) }
        }.padding(16)
    }

    private var layoutPreference: WorkspaceLayout { WorkspaceLayout(rawValue: layoutRaw) ?? .automatic }
    private var density: InterfaceDensity { InterfaceDensity(rawValue: densityRaw) ?? .comfortable }
    private func effectiveLayout(for width: CGFloat) -> WorkspaceLayout {
        layoutPreference == .automatic ? (width >= gridThreshold ? .grid : .list) : layoutPreference
    }

    // MARK: - Unassigned section

    @ViewBuilder
    private var unassignedSection: some View {
        if !visibleUnassigned.isEmpty {
            unassignedContent
                .listRowInsets(EdgeInsets(top: density == .compact ? 4 : 9, leading: 16, bottom: density == .compact ? 4 : 9, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var unassignedGridSection: some View {
        if !visibleUnassigned.isEmpty { unassignedContent }
    }

    private var unassignedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(manager.rooms.isEmpty ? "All Lights" : "Unassigned")
                    .font(.title2.weight(.black))
                Text("\(visibleUnassigned.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Lumen.cyan.opacity(0.20)))
                Spacer()
            }
            VStack(spacing: 10) {
                ForEach(visibleUnassigned) { device in
                    LightRowView(
                        device: device,
                        selectionMode: selectionMode,
                        selected: selectedIDs.contains(device.id),
                        onToggleSelection: { toggleSelection(device.id) }
                    )
                    .draggable(device.id)
                }
            }
        }
        .dropDestination(for: String.self) { ids, _ in
            for id in ids { manager.assign(lightID: id, toRoom: nil) }
            return true
        }
    }

    // MARK: - Header bindings

    private var globalPowerBinding: Binding<Bool> {
        Binding(
            get: { !manager.devices.isEmpty && manager.devices.allSatisfy { $0.isOn } },
            set: { manager.setAllPower(on: $0) }
        )
    }

    private var globalBrightnessBinding: Binding<Double> {
        Binding(
            get: {
                let on = manager.devices.filter { $0.isOn }
                guard !on.isEmpty else { return 1.0 }
                return on.reduce(0) { $0 + $1.brightness } / Double(on.count)
            },
            set: { manager.setAllBrightness($0) }
        )
    }

    // MARK: - New room sheet

    private var newRoomSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Room").font(.title3.weight(.semibold))
            Text("Group lights from any brand into a single custom room.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Room name (e.g. \u{201C}Living Room\u{201D})", text: $newRoomName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(createRoom)
            HStack {
                Spacer()
                Button("Cancel") { showingNewRoom = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: createRoom)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newRoomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(LumenBackground(glow: false))
    }

    private func createRoom() {
        let trimmed = newRoomName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        manager.createRoom(name: trimmed)
        showingNewRoom = false
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "lightbulb.slash")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No lights found yet").font(.headline)
            Text("Run through this checklist, then scan again.")
                .font(.callout)
                .foregroundStyle(.secondary)

            DiscoveryDiagnosticsCard()
                .environmentObject(manager)

            HStack(spacing: 12) {
                setupBrandCard("LIFX", icon: "dot.radiowaves.left.and.right", tint: Lumen.violetBright,
                               detail: "Uses UDP broadcast on 56700. Keep the Mac and bulbs on the same subnet.")
                setupBrandCard("Govee", icon: "network", tint: Lumen.coral,
                               detail: "Requires LAN Control in the Govee Home app and UDP ports 4001–4003.")
            }
            .frame(maxWidth: 520)

            VStack(alignment: .leading, spacing: 12) {
                setupStep(0,
                          "Mac and bulbs on the same Wi-Fi",
                          "Both must be on the same network and subnet \u{2014} check your router if unsure.")
                setupStep(1,
                          "Govee: \u{201C}LAN Control\u{201D} enabled",
                          "Govee Home app \u{2192} Devices \u{2192} [bulb] \u{2192} Settings \u{2192} LAN Control.")
                setupStep(2,
                          "LIFX: bulbs powered and paired",
                          "Confirm each bulb is on and set up in the LIFX app.")
            }
            .frame(maxWidth: 440)
            .padding(16)
            .lumenCard()

            Button("Scan Now") { manager.scan() }
                .buttonStyle(LumenPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func setupBrandCard(_ title: String, icon: String, tint: Color, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lumenCard(radius: Lumen.tileRadius)
    }

    private func setupStep(_ index: Int, _ title: String, _ detail: String) -> some View {
        let checked = setupChecks.contains(index)
        return Button {
            if checked { setupChecks.remove(index) } else { setupChecks.insert(index) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct NowAutomationDashboard: View {
    @EnvironmentObject var manager: LightManager
    @Binding var showingMissedAutomations: Bool

    private var enabledSchedules: [(Room, ScheduleEntry)] {
        manager.rooms.flatMap { room in manager.schedules(for: room.id).filter(\.isEnabled).map { (room, $0) } }
    }

    private var nextSummary: String {
        if let missed = manager.missedAutomations.first { return "Missed: \(missed.roomName) at \(missed.scheduledAt.formatted(date: .omitted, time: .shortened))" }
        guard let next = enabledSchedules.sorted(by: { lhs, rhs in
            lhs.1.hour == rhs.1.hour ? lhs.1.minute < rhs.1.minute : lhs.1.hour < rhs.1.hour
        }).first else { return "No automations scheduled today" }
        return "Next: \(next.0.name) · \(next.1.timeString) \(next.1.action.displayName)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Label(nextSummary, systemImage: manager.missedAutomations.isEmpty ? "clock" : "clock.badge.exclamationmark")
                .font(.caption.weight(.medium))
                .foregroundStyle(manager.missedAutomations.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Lumen.warning))
                .lineLimit(1)
            Spacer()
            Text("\(enabledSchedules.count) active")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            if !manager.missedAutomations.isEmpty {
                Button("Review") { showingMissedAutomations = true }
                    .controlSize(.small)
            }
            Button("Pause all") {
                for room in manager.rooms { manager.setAutomationOverride(for: room.id, duration: .untilResumed) }
            }
            .controlSize(.small)
            .disabled(enabledSchedules.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Lumen.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Lumen.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Automation dashboard. \(nextSummary). \(enabledSchedules.count) active schedules.")
    }
}

struct IdentifyLightsView: View {
    @EnvironmentObject var manager: LightManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Identify Lights", systemImage: "lightbulb.2").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Flash each bulb, then rename or assign it while the physical light is obvious.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(Array(manager.devices.enumerated()), id: \.element.id) { index, device in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("\(index + 1)").font(.title2.bold()).foregroundStyle(Lumen.gold)
                                VStack(alignment: .leading) {
                                    Text(device.label).font(.headline).lineLimit(1)
                                    Text("\(device.brand.displayName) · \(device.address)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                            HStack {
                                Button("Flash") { manager.identify(device) }.buttonStyle(.borderedProminent)
                                Button("Retry") { manager.retry(device) }
                                Menu("Move") {
                                    Button("Unassigned") { manager.assign(lightID: device.id, toRoom: nil) }
                                    ForEach(manager.rooms) { room in Button(room.name) { manager.assign(lightID: device.id, toRoom: room.id) } }
                                }
                            }
                            if device.isStale {
                                Label("Not responding recently", systemImage: "wifi.slash")
                                    .font(.caption)
                                    .foregroundStyle(Lumen.warning)
                            }
                        }
                        .padding(12)
                        .lumenCard(radius: 10)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(20)
        .sheetFrame(minWidth: 560, idealWidth: 760, minHeight: 440, idealHeight: 620)
        .background(LumenBackground(glow: false))
    }
}

// MARK: - Toast

struct CommandToastView: View {
    let message: String
    var undoAction: (() -> Void)? = nil
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Lumen.warning)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 0)
            if let undo = undoAction {
                Button("Undo") { undo() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Undo last action")
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Lumen.surfaceRaised))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Lumen.warning.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
        .frame(maxWidth: 420)
    }
}

// MARK: - Bulk action bar

struct BulkActionBar: View {
    @EnvironmentObject var manager: LightManager
    @Binding var selectedIDs: Set<String>
    @Binding var selectionMode: Bool
    @State private var pendingAction: PendingBulkAction?

    private enum PendingBulkAction: Identifiable {
        case power(Bool), brightness(Double), move(UUID?)
        var id: String {
            switch self {
            case .power(let on): return "power-\(on)"
            case .brightness(let value): return "brightness-\(value)"
            case .move(let id): return "move-\(id?.uuidString ?? "none")"
            }
        }
        var title: String {
            switch self {
            case .power(let on): return on ? "Turn selected lights on?" : "Turn selected lights off?"
            case .brightness(let value): return "Set selected brightness to \(Int(value * 100))%?"
            case .move: return "Move selected lights?"
            }
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(selectedIDs.count) selected")
                .font(.callout.weight(.medium))
                .accessibilityLabel("\(selectedIDs.count) light\(selectedIDs.count == 1 ? "" : "s") selected")

            Divider().frame(height: 16).accessibilityHidden(true)

            Button("Turn On") { pendingAction = .power(true) }
                .accessibilityHint("Turns on \(selectedIDs.count) selected light\(selectedIDs.count == 1 ? "" : "s")")
            Button("Turn Off") { pendingAction = .power(false) }
                .accessibilityHint("Turns off \(selectedIDs.count) selected light\(selectedIDs.count == 1 ? "" : "s")")

            Menu("Move to\u{2026}") {
                Button("Unassigned") {
                    pendingAction = .move(nil)
                }
                if !manager.rooms.isEmpty {
                    Divider()
                    ForEach(manager.rooms) { room in
                        Button(room.name) {
                            pendingAction = .move(room.id)
                        }
                    }
                }
            }
            .fixedSize()

            Menu("Brightness") {
                Button("100%") { pendingAction = .brightness(1.0) }
                Button("75%")  { pendingAction = .brightness(0.75) }
                Button("50%")  { pendingAction = .brightness(0.5) }
                Button("25%")  { pendingAction = .brightness(0.25) }
                Button("10%")  { pendingAction = .brightness(0.1) }
                if !manager.customBrightnessPresets.isEmpty {
                    Divider()
                    ForEach(manager.customBrightnessPresets, id: \.self) { value in
                        Button("Preset \(Int(value * 100))%") { pendingAction = .brightness(value) }
                    }
                }
                Divider()
                Button("Save Current Average as Preset") { manager.addBrightnessPreset(currentAverageBrightness) }
            }
            .fixedSize()

            Spacer(minLength: 8)

            Button("Done") { exitSelection() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Lumen.surfaceRaised))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Lumen.hairlineStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
        .frame(maxWidth: 640)
        .confirmationDialog(
            pendingAction?.title ?? "Apply bulk action?",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            presenting: pendingAction
        ) { action in
            Button("Apply to \(selectedIDs.count) selected lights") { apply(action, onlyVisible: false) }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(bulkPreviewMessage(for: action))
        }
    }

    private var currentAverageBrightness: Double {
        let selected = manager.devices.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { return 0.5 }
        return selected.reduce(0) { $0 + $1.brightness } / Double(selected.count)
    }

    private func exitSelection() {
        selectedIDs.removeAll()
        selectionMode = false
    }

    private func bulkPreviewMessage(for action: PendingBulkAction) -> String {
        let selected = manager.devices.filter { selectedIDs.contains($0.id) }
        let stale = selected.filter(\.isStale).count
        let rooms = Dictionary(grouping: selected) { device in manager.rooms.first(where: { $0.lightIDs.contains(device.id) })?.name ?? "Unassigned" }
            .map { "\($0.key): \($0.value.count)" }
            .sorted()
            .joined(separator: " · ")
        return "\(rooms). \(stale) may be offline. This action is undoable for light state changes."
    }

    private func apply(_ action: PendingBulkAction, onlyVisible: Bool) {
        switch action {
        case .power(let on): manager.setPower(deviceIDs: selectedIDs, on: on)
        case .brightness(let value): manager.setBrightness(deviceIDs: selectedIDs, value: value)
        case .move(let roomID): manager.assign(lightIDs: selectedIDs, toRoom: roomID); exitSelection()
        }
    }
}

struct DiscoveryDiagnosticsCard: View {
    @EnvironmentObject var manager: LightManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Discovery diagnostics", systemImage: "wave.3.right.circle")
                .font(.callout.weight(.semibold))
            HStack {
                Text(manager.scanPhase)
                Spacer()
                Text("Responses: \(manager.scanResponseCount)")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let date = manager.lastScanDate {
                Text("Last scan: \(date.formatted(.relative(presentation: .named)))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if manager.likelyLocalNetworkPermissionIssue {
                Label("No UDP replies were received. Local Network access may be denied; verify it in System Settings.", systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.caption).foregroundStyle(Lumen.warning)
            }
            HStack {
                Button("Open Local Network Privacy") {
                    PlatformOpener.openSettings(macPane: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
                }.font(.caption)
                Spacer()
                Button("Scan Again") { manager.scan() }.font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: 440, alignment: .leading)
        .lumenCard(radius: Lumen.tileRadius)
    }
}

struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss
    private let shortcuts = [
        ("Scan for Lights", "⌘R"),
        ("New Room", "⌘N"),
        ("Find", "⌘F"),
        ("Library", "⇧⌘S"),
        ("Toggle All Lights", "⇧⌘P"),
        ("Undo / Redo", "⌘Z / ⇧⌘Z")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keyboard Shortcuts").font(.title3.weight(.semibold))
            ForEach(shortcuts, id: \.0) { item in
                HStack {
                    Text(item.0)
                    Spacer()
                    Text(item.1)
                        .font(.callout.monospaced())
                        .foregroundStyle(Lumen.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Lumen.surfaceRaised))
                        .overlay(Capsule().stroke(Lumen.hairline, lineWidth: 1))
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 360)
        .background(LumenBackground(glow: false))
    }
}

struct AuroraFireflyOverlay: View {
    let colors: [Color]
    @State private var drift = false
    private let points: [(CGFloat, CGFloat)] = [(0.12,0.25),(0.28,0.72),(0.46,0.18),(0.63,0.64),(0.81,0.32),(0.92,0.78)]

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let palette = colors.isEmpty ? [Lumen.violet, Lumen.pink, Lumen.gold] : colors
                for (idx, point) in points.enumerated() {
                    let color = palette[idx % palette.count]
                    let x = size.width * point.0 + (drift ? 18 : -18) * sin(Double(idx + 1))
                    let y = size.height * point.1 + (drift ? -14 : 14) * cos(Double(idx + 2))
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 7, height: 7)), with: .color(color.opacity(0.55)))
                    context.addFilter(.blur(radius: 8))
                    context.fill(Path(ellipseIn: CGRect(x: x - 10, y: y - 10, width: 27, height: 27)), with: .color(color.opacity(0.16)))
                    context.drawLayer { layer in
                        if idx > 0 {
                            let previous = points[idx - 1]
                            var path = Path()
                            path.move(to: CGPoint(x: size.width * previous.0, y: size.height * previous.1))
                            path.addLine(to: CGPoint(x: x + 3, y: y + 3))
                            layer.stroke(path, with: .color(color.opacity(0.08)), lineWidth: 1)
                        }
                    }
                }
            }
            .ignoresSafeArea()
            .onAppear {
                withAnimation(.easeInOut(duration: 5).repeatForever(autoreverses: true)) { drift.toggle() }
            }
        }
    }
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        LumenDeskShellView()
            .environmentObject(LightManager())
            .frame(width: 980, height: 720)
    }
}
#endif
