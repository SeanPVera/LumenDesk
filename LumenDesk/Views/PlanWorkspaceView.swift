import SwiftUI

/// A room is the working context, not a destination hidden behind a drawing.
/// Domain state remains in LightManager; this view owns only navigation and selection.
struct PlanWorkspaceView: View {
    @EnvironmentObject private var manager: LightManager
    @Binding var scope: LightScope
    @State private var selectedIDs: Set<String> = []
    @State private var section: RoomWorkspaceSection = .control
    @State private var showingSetup = false
    @State private var showingNewRoom = false
    @State private var showingPlan = false
    @State private var configurationRoom: Room?
    @State private var searchText = ""
    @AppStorage("LumenDesk.workspaceLayout.v1") private var layout = WorkspaceLayout.automatic.rawValue
    @AppStorage("LumenDesk.interfaceDensity.v1") private var density = InterfaceDensity.comfortable.rawValue

    init(scope: Binding<LightScope> = .constant(.all),
         initialSelection: Set<String> = [], initialSection: RoomWorkspaceSection = .control) {
        _scope = scope
        _selectedIDs = State(initialValue: initialSelection)
        _section = State(initialValue: initialSection)
    }

    private var lights: [LightDevice] { manager.devices(in: scope) }
    private var room: Room? {
        guard case .room(let id) = scope else { return nil }
        return manager.rooms.first { $0.id == id }
    }
    private var visibleLights: [LightDevice] {
        lights.filter { searchText.isEmpty || manager.device($0, matchesQuery: searchText) }
    }
    private var targets: [LightDevice] {
        let ids = RoomWorkspaceSelection.targets(selected: selectedIDs, available: lights.map(\.id))
        return lights.filter { ids.contains($0.id) }
    }
    /// The one selected fixture, when it is a Shapes wall: its panels get
    /// the full editor in the room workspace rather than a sheet.
    private var selectedShapesWall: LightDevice? {
        guard selectedIDs.count == 1, let light = targets.first, light.brand == .nanoleaf else { return nil }
        return light
    }

    private var activeScopes: [LightScope] {
        Array(Set(lights.compactMap { manager.animatingEffect(for: $0.id)?.scope }))
            .sorted { manager.scopeDisplayName($0) < manager.scopeDisplayName($1) }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: LumenToken.Spacing.s6) {
                    scopeHeader
                    runningOutput
                    if lights.isEmpty {
                        emptyState
                    } else {
                        RoomLightField(lights: lights, room: room, selectedIDs: $selectedIDs,
                                       showsSpatialPlacement: geometry.size.width >= max(720, CGFloat(lights.count) * 155))
                        sectionPicker
                        switch section {
                        case .control:
                            if let wall = selectedShapesWall {
                                NanoleafShapesStudio(device: wall, shapes: manager.shapes,
                                                     wide: geometry.size.width >= 1000)
                            }
                            controls(wide: geometry.size.width >= 900)
                        case .compositions:
                            LibraryWorkspaceView(scope: $scope, embedded: true)
                        case .music:
                            MusicModeView(scope: $scope, showsScopePicker: false)
                        }
                    }
                }
                .padding(geometry.size.width < 600 ? 16 : 24)
                .frame(maxWidth: 1440)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .background(Lumen.stage)
        .navigationTitle("Room")
        .onChange(of: scope) { _ in selectedIDs.removeAll(); searchText = "" }
        .onChange(of: lights.map(\.id)) { ids in
            selectedIDs = RoomWorkspaceSelection.reconciled(selected: selectedIDs, available: ids)
        }
        .onChange(of: manager.rooms.map(\.id)) { ids in
            if case .room(let id) = scope, !ids.contains(id) { scope = .all }
        }
        .sheet(isPresented: $showingSetup) { RoomSetupView().environmentObject(manager) }
        .sheet(isPresented: $showingNewRoom) { NewRoomSheet().environmentObject(manager) }
        .sheet(isPresented: $showingPlan) { RoomArrangementSheet().environmentObject(manager) }
        .sheet(item: $configurationRoom) { RoomConfigurationView(room: $0).environmentObject(manager) }
    }

    private var scopeHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) {
                scopeTitle
                Spacer(minLength: 12)
                roomActions
            }
            VStack(alignment: .leading, spacing: 12) { scopeTitle; roomActions }
        }
    }

    private var scopeTitle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Control room", selection: $scope) {
                Text("All lights").tag(LightScope.all)
                ForEach(manager.rooms) { Text($0.name).tag(LightScope.room($0.id)) }
            }
            .font(.title3.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("workspace.scope")
            Text("\(lights.filter { $0.isOn && !$0.isStale }.count) lit · \(lights.count) fixtures · \(lights.filter(\.isStale).count) not responding")
                .font(.callout).foregroundStyle(Lumen.meter)
        }
    }

    private var roomActions: some View {
        HStack(spacing: 12) {
            if manager.isScanning {
                ProgressView().controlSize(.small)
                Text(manager.scanPhase).font(.caption).foregroundStyle(Lumen.meter)
            }
            Menu {
                if let room {
                    Button("Configure this room…") { configurationRoom = room }
                    Button(manager.isFavoriteRoom(room.id) ? "Unpin room" : "Pin room") { manager.toggleFavoriteRoom(room.id) }
                }
                Button("New room…") { showingNewRoom = true }
                Button("Assign fixtures…") { showingSetup = true }
                Button("Arrange rooms…") { showingPlan = true }
                Button("Scan for lights") { manager.scan() }.disabled(manager.isScanning)
            } label: { Label("Room actions", systemImage: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    @ViewBuilder private var runningOutput: some View {
        if !activeScopes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(activeScopes, id: \.self) { runScope in
                    let id = manager.activeEffects[runScope] ?? ""
                    let name = LightingCatalog.effects.first { $0.id == id }?.name ?? "Effect"
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) {
                            Label("\(name) · \(manager.scopeDisplayName(runScope))", systemImage: id == "music-pulse" ? "music.note" : "waveform")
                            Spacer(minLength: 12)
                            stopActions(runScope)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text("\(name) · \(manager.scopeDisplayName(runScope))")
                            stopActions(runScope)
                        }
                    }
                }
                Text("The running show owns these fixtures. Stop it before editing their output.")
                    .font(.caption).foregroundStyle(Lumen.meter)
            }
            .padding(16)
            .background(Lumen.deck)
            .overlay(alignment: .leading) { Rectangle().fill(Lumen.chalk).frame(width: 2) }
        }
    }

    private func stopActions(_ runScope: LightScope) -> some View {
        HStack(spacing: 10) {
            Button("Stop & restore") { manager.stopEffect(scope: runScope, restore: true) }
                .buttonStyle(LumenSecondaryButtonStyle(compact: true))
            Button("Keep current light") { manager.stopEffect(scope: runScope, restore: false) }
                .buttonStyle(LumenSecondaryButtonStyle(compact: true))
        }
    }

    private var sectionPicker: some View {
        HStack(spacing: 20) {
            ForEach(RoomWorkspaceSection.allCases) { item in
                Button { section = item } label: {
                    Text(item.rawValue)
                        .font(.body.weight(section == item ? .semibold : .regular))
                        .foregroundStyle(section == item ? Lumen.lit : Lumen.meter)
                        .padding(.vertical, 12)
                        .overlay(alignment: .bottom) {
                            if section == item { Rectangle().fill(Lumen.lit).frame(height: 2) }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(section == item ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Lumen.ruleSoft).frame(height: 1) }
    }

    @ViewBuilder private func controls(wide: Bool) -> some View {
        if wide {
            HStack(alignment: .top, spacing: 28) {
                fixtureList.frame(maxWidth: .infinity)
                outputControls.frame(width: 330)
            }
        } else {
            VStack(alignment: .leading, spacing: 24) {
                outputControls
                fixtureList
            }
        }
    }

    private var outputControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            if selectedIDs.count == 1, let light = targets.first {
                Text("One selected fixture").font(.headline)
                LightRowView(device: light, showsShapesStudioEntry: false)
            } else {
                RoomOutputControls(lights: targets, title: selectedIDs.isEmpty
                                   ? manager.scopeDisplayName(scope)
                                   : "\(targets.count) selected fixtures")
            }
            if !selectedIDs.isEmpty && targets.isEmpty {
                Text("The selected fixtures are no longer in this room. Clear selection to control the room.")
                    .font(.callout).foregroundStyle(Lumen.warn)
            }
            if !selectedIDs.isEmpty {
                Menu("Move selected fixtures") {
                    ForEach(manager.rooms) { destination in
                        Button(destination.name) { manager.assign(lightIDs: selectedIDs, toRoom: destination.id) }
                    }
                    Button("Remove room assignment") { manager.assign(lightIDs: selectedIDs, toRoom: nil) }
                }
                Button("Clear selection — control the room") { selectedIDs.removeAll() }
                    .buttonStyle(LumenSecondaryButtonStyle(compact: true))
            }
            if selectedIDs.count != 1 {
                Text("Select one fixture for precise color, white temperature, and its spatial editor. Select several to edit them together.")
                    .font(.callout).foregroundStyle(Lumen.meter)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var fixtureList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Fixtures").font(.headline)
                Spacer()
                Text("\(selectedIDs.count) selected").font(.caption).foregroundStyle(Lumen.meter)
                Button(searchText.isEmpty ? "Select all" : "Select visible") { selectedIDs = Set(visibleLights.map(\.id)) }
                    .buttonStyle(LumenSecondaryButtonStyle(compact: true))
            }
            TextField("Find a fixture", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Find a fixture in the current room")
            if !selectedIDs.isSubset(of: Set(visibleLights.map(\.id))) {
                Label("Selection includes fixtures hidden by this search.", systemImage: "eye.slash")
                    .font(.caption).foregroundStyle(Lumen.warn)
            }
            if visibleLights.isEmpty {
                Text("No fixtures match. Clear the search to see this room.")
                    .foregroundStyle(Lumen.meter)
            }
            LazyVGrid(columns: layout == WorkspaceLayout.list.rawValue
                      ? [GridItem(.flexible())]
                      : [GridItem(.adaptive(minimum: 250), spacing: 16)], spacing: 0) {
                ForEach(visibleLights) { light in
                    RoomFixtureLine(light: light, selected: selectedIDs.contains(light.id),
                                    compact: density == InterfaceDensity.compact.rawValue) {
                        if selectedIDs.contains(light.id) { selectedIDs.remove(light.id) }
                        else { selectedIDs.insert(light.id) }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(manager.devices.isEmpty ? "Bring your lights into view" : "No fixtures in this room")
                .font(.title3.weight(.semibold))
            Text(manager.devices.isEmpty
                 ? "Keep LIFX and Govee lights on the same network. Enable LAN Control in Govee Home."
                 : "Assign a discovered fixture to start controlling this space.")
                .font(.body).foregroundStyle(Lumen.meter)
            HStack {
                Button(manager.isScanning ? "Searching…" : "Scan for lights") { manager.scan() }
                    .buttonStyle(LumenPrimaryButtonStyle()).disabled(manager.isScanning)
                if manager.devices.isEmpty {
                    Button("Try Demo Mode") { manager.enterDemoMode() }
                        .buttonStyle(LumenSecondaryButtonStyle())
                } else {
                    Button("Assign fixtures") { showingSetup = true }
                        .buttonStyle(LumenSecondaryButtonStyle())
                }
            }
            if manager.isScanning { Text(manager.scanPhase).font(.callout) }
            if !manager.statusMessage.isEmpty {
                Text(manager.statusMessage).font(.callout).foregroundStyle(Lumen.warn)
            }
        }
        .padding(.vertical, 32)
    }
}

enum RoomWorkspaceSection: String, CaseIterable, Identifiable {
    case control = "Light", compositions = "Compositions", music = "Music"
    var id: String { rawValue }
}

/// Relative fixture placement uses the existing Room anchors. All-lights and
/// dense rooms use an ordered field instead of implying unknown geometry.
struct RoomLightField: View {
    @EnvironmentObject private var manager: LightManager
    let lights: [LightDevice]
    let room: Room?
    @Binding var selectedIDs: Set<String>
    @State private var arranging = false
    var showsSpatialPlacement = true
    private var usesPlacement: Bool { showsSpatialPlacement && room != nil && lights.count <= 8 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(usesPlacement ? "Relative placement" : "Fixture order")
                    .font(.caption).foregroundStyle(Lumen.meter)
                Spacer()
                if usesPlacement {
                    Toggle("Arrange", isOn: $arranging).toggleStyle(LumenChipStyle())
                }
                Text("Select to control").font(.caption).foregroundStyle(Lumen.meter)
            }
            if let room, usesPlacement {
                GeometryReader { geometry in
                    ForEach(lights) { light in
                        let anchor = manager.planAnchor(for: light.id, in: room)
                        RoomEmitter(light: light, selected: selectedIDs.contains(light.id)) { toggle(light.id) }
                            .frame(width: 116, height: 106)
                            .position(x: 58 + (geometry.size.width - 116) * anchor.x,
                                      y: 53 + (geometry.size.height - 106) * anchor.y)
                            .gesture(DragGesture(minimumDistance: 6).onEnded { value in
                                guard arranging else { return }
                                manager.setPlanAnchor(PlanAnchor(
                                    x: anchor.x + Double(value.translation.width / max(1, geometry.size.width - 116)),
                                    y: anchor.y + Double(value.translation.height / max(1, geometry.size.height - 106))),
                                    for: light.id, in: room.id)
                            }, including: arranging ? .all : .none)
                            .contextMenu {
                                Button("Move left") { move(light, in: room, dx: -0.1, dy: 0) }
                                Button("Move right") { move(light, in: room, dx: 0.1, dy: 0) }
                                Button("Move toward top") { move(light, in: room, dx: 0, dy: -0.1) }
                                Button("Move toward bottom") { move(light, in: room, dx: 0, dy: 0.1) }
                            }
                            .accessibilityAction(named: "Move left") { move(light, in: room, dx: -0.1, dy: 0) }
                            .accessibilityAction(named: "Move right") { move(light, in: room, dx: 0.1, dy: 0) }
                            .accessibilityAction(named: "Move toward top") { move(light, in: room, dx: 0, dy: -0.1) }
                            .accessibilityAction(named: "Move toward bottom") { move(light, in: room, dx: 0, dy: 0.1) }
                    }
                }
                .frame(height: 210)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 8)], spacing: 12) {
                    ForEach(lights) { light in
                        RoomEmitter(light: light, selected: selectedIDs.contains(light.id)) { toggle(light.id) }
                    }
                }
            }
        }
        .padding(16)
        .background(Lumen.deck)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Room light field")
    }

    private func toggle(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    private func move(_ light: LightDevice, in room: Room, dx: Double, dy: Double) {
        let anchor = manager.planAnchor(for: light.id, in: room)
        manager.setPlanAnchor(PlanAnchor(x: anchor.x + dx, y: anchor.y + dy), for: light.id, in: room.id)
    }
}

struct RoomEmitter: View {
    @EnvironmentObject private var manager: LightManager
    @ObservedObject var light: LightDevice
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(light.color.opacity(light.isOn && !light.isStale ? 0.12 + light.brightness * 0.3 : 0))
                    if let state = manager.activeSegmentState(for: light.id) {
                        HStack(spacing: 2) {
                            ForEach(Array(state.colors.prefix(16).enumerated()), id: \.offset) { _, color in
                                Rectangle().fill(color.litColor)
                            }
                        }
                        .frame(height: 12).padding(.horizontal, 10)
                        .opacity(light.isOn && !light.isStale ? 1 : 0.2)
                    } else if light.brand == .nanoleaf, manager.shapes.layout(light.id) != nil {
                        NanoleafMiniWall(shapes: manager.shapes, deviceID: light.id, fallback: light.color,
                                         lit: light.isOn && !light.isStale)
                            .padding(.horizontal, 6)
                    } else if let profile = manager.segmentProfile(for: light) {
                        HStack(spacing: 2) {
                            ForEach(0..<min(16, profile.defaultSegmentCount), id: \.self) { _ in
                                Rectangle().fill(light.isOn && !light.isStale ? light.color : Lumen.meter)
                            }
                        }.frame(height: 12).padding(.horizontal, 10)
                    } else {
                        Image(systemName: light.isLIFXLuna ? "circle.grid.3x3" : "lightbulb")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(light.isOn && !light.isStale ? light.color : Lumen.meter)
                    }
                }
                .frame(height: 46)
                .overlay(alignment: .topTrailing) {
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Lumen.lit).padding(3) }
                }
                Text(light.label).font(.callout.weight(selected ? .semibold : .regular)).lineLimit(2)
                Text(light.isStale ? "Not responding" : light.isOn ? "\(Int(light.brightness * 100))% · On" : "Off")
                    .font(.caption).foregroundStyle(Lumen.meter)
            }
            .padding(6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Lumen.lit : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(light.label)
        .accessibilityValue("\(selected ? "Selected. " : "")\(light.isStale ? "Not responding" : light.isOn ? "On, \(Int(light.brightness * 100)) percent" : "Off")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(light.label)
    }
}

struct RoomFixtureLine: View {
    @EnvironmentObject private var manager: LightManager
    @ObservedObject var light: LightDevice
    let selected: Bool
    var compact = false
    let select: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: select) {
                HStack(spacing: 12) {
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(light.label).font(.body.weight(.medium)).lineLimit(2)
                        Text(detail).font(.caption).foregroundStyle(Lumen.meter)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(selected ? "Deselect" : "Select") \(light.label)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            Text(light.isStale ? "Offline" : light.isOn ? "\(Int(light.brightness * 100))%" : "Off")
                .font(.callout.monospacedDigit()).foregroundStyle(Lumen.meter)
        }
        .padding(.vertical, compact ? 8 : 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Lumen.ruleSoft).frame(height: 1) }
    }

    private var detail: String {
        if let run = manager.animatingEffect(for: light.id) { return run.name }
        if light.isLIFXLuna { return "Matrix · 26 zones" }
        if light.brand == .nanoleaf, let layout = manager.shapes.layout(light.id) {
            return "Shapes · \(layout.paintablePanels.count) panels"
        }
        if manager.segmentStudioProfile(for: light) != nil {
            return "\(manager.segmentState(for: light).segmentCount) segments"
        }
        return manager.isWhiteMode(light.id) ? "\(light.kelvin) K white" : "Single color"
    }
}

struct RoomOutputControls: View {
    @EnvironmentObject private var manager: LightManager
    let lights: [LightDevice]
    let title: String

    private var ids: Set<String> { Set(lights.filter { !$0.isStale }.map(\.id)) }
    private var owned: Bool { lights.contains { manager.animatingEffect(for: $0.id) != nil } }
    private var level: Double {
        let online = lights.filter { !$0.isStale }
        return online.isEmpty ? 0 : online.reduce(0) { $0 + $1.brightness } / Double(online.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            Text("\(ids.count) available · \(lights.count - ids.count) not responding")
                .font(.caption).foregroundStyle(Lumen.meter)
            HStack(spacing: 12) {
                Button("On") { manager.setPower(deviceIDs: ids, on: true) }
                    .buttonStyle(LumenPrimaryButtonStyle())
                Button("Off") { manager.setPower(deviceIDs: ids, on: false) }
                    .buttonStyle(LumenSecondaryButtonStyle())
            }
            .disabled(ids.isEmpty || owned)
            LumenFader(label: "Brightness", value: Binding(
                get: { level }, set: { manager.setBrightness(deviceIDs: ids, value: $0) }))
                .disabled(ids.isEmpty || owned)
            ColorPicker("Color", selection: Binding(
                get: { lights.first?.color ?? .white },
                set: { manager.setColor(deviceIDs: ids, color: $0) }), supportsOpacity: false)
                .disabled(ids.isEmpty || owned)
            if Set(lights.map { $0.color.hsbComponents.h }).count > 1 || Set(lights.map { $0.color.hsbComponents.s }).count > 1 {
                Text("Mixed colors. Picking a color replaces the selected output.")
                    .font(.caption).foregroundStyle(Lumen.meter)
            }
            LumenFader(label: "White temperature", value: Binding(
                get: { Double(lights.first?.kelvin ?? 3500) },
                set: { manager.setKelvin(deviceIDs: ids, kelvin: Int($0)) }),
                       range: 2500...9000, step: 100, track: .kelvin,
                       format: { "\(Int($0)) K" })
                .disabled(ids.isEmpty || owned)
            Text("Output depends on each fixture. Segment and matrix layouts are replaced by a single color or white setting.")
                .font(.caption).foregroundStyle(Lumen.meter)
            if owned {
                Label("Controlled by the running show", systemImage: "waveform")
                    .font(.callout).foregroundStyle(Lumen.meter)
            }
        }
    }
}

/// Room membership and naming use the existing canonical manager mutations.
struct RoomConfigurationView: View {
    @EnvironmentObject private var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    let room: Room
    @State private var name = ""
    private var current: Room { manager.rooms.first { $0.id == room.id } ?? room }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        TextField("Room name", text: $name).textFieldStyle(.roundedBorder)
                        Button("Rename") { manager.renameRoom(room.id, to: name) }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text("Fixtures in this room").font(.headline)
                    Text("Assignment changes organization only. Removing a fixture here keeps it available in All lights.")
                        .font(.callout).foregroundStyle(Lumen.meter)
                    ForEach(manager.devices) { light in
                        Toggle(light.label, isOn: Binding(
                            get: { current.lightIDs.contains(light.id) },
                            set: { manager.assign(lightID: light.id, toRoom: $0 ? room.id : nil) }))
                            .toggleStyle(LumenRockerStyle())
                    }
                    Divider()
                    Text("Fixture order").font(.headline)
                    ForEach(manager.devices(in: current)) { light in
                        HStack {
                            Text(light.label).lineLimit(2)
                            Spacer()
                            Button("Earlier") { manager.moveLight(light.id, in: room.id, by: -1) }
                                .accessibilityLabel("Move \(light.label) earlier")
                            Button("Later") { manager.moveLight(light.id, in: room.id, by: 1) }
                                .accessibilityLabel("Move \(light.label) later")
                        }
                    }
                    Button("Delete room", role: .destructive) {
                        manager.deleteRoom(room.id)
                        dismiss()
                    }
                    Text("Deleting removes the room and its schedules. Fixtures remain available. The existing deletion confirmation and Undo policy apply.")
                        .font(.caption).foregroundStyle(Lumen.meter)
                }.padding(20)
            }
            .navigationTitle("Configure \(current.name)")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear { name = current.name }
        .sheetFrame(minWidth: 540, idealWidth: 660, minHeight: 540, idealHeight: 700)
    }
}

/// Existing saved room frames remain editable as advanced organization.
struct RoomArrangementSheet: View {
    @EnvironmentObject private var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    @State private var roomID: UUID?
    @State private var lightID: String?
    @State private var placementError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Arrange rooms").font(.headline)
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                Text("Relative organization, not a measured floor plan. Drag a room or edit its position and size below.")
                    .foregroundStyle(Lumen.meter)
                ScrollView(.horizontal) {
                    PlanBoardView(arranging: true, selectedRoomID: $roomID, selectedLightID: $lightID)
                        .frame(width: 600, height: CGFloat(max(2, manager.rooms.compactMap { $0.planFrame?.maxRow }.max() ?? 2)) * 120)
                }
                if let placementError {
                    Label(placementError, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Lumen.warn)
                }
                ForEach(manager.rooms) { room in
                    DisclosureGroup(room.name) {
                        VStack(alignment: .leading, spacing: 12) {
                            Stepper("Column: \((room.planFrame?.column ?? 0) + 1)",
                                    value: frameBinding(room, \.column), in: 0...5)
                            Stepper("Row: \((room.planFrame?.row ?? 0) + 1)",
                                    value: frameBinding(room, \.row), in: 0...999)
                            Stepper("Width: \(room.planFrame?.width ?? 1) columns",
                                    value: frameBinding(room, \.width), in: 1...6)
                            Stepper("Height: \(room.planFrame?.height ?? 1) rows",
                                    value: frameBinding(room, \.height), in: 1...999)
                            HStack {
                                Text("Room list order")
                                Spacer()
                                Button("Earlier") { manager.moveRoom(room.id, by: -1) }
                                    .accessibilityLabel("Move \(room.name) earlier in room list")
                                Button("Later") { manager.moveRoom(room.id, by: 1) }
                                    .accessibilityLabel("Move \(room.name) later in room list")
                            }
                        }
                        .padding(.vertical, 12)
                    }
                }
                Button("Reset arrangement") { manager.resetPlanLayout(); placementError = nil }
            }
            .padding(20)
        }
        .onAppear { manager.ensurePlanLayout() }
        .sheetFrame(minWidth: 620, idealWidth: 820, minHeight: 560, idealHeight: 700)
    }

    private func frameBinding(_ room: Room, _ key: WritableKeyPath<RoomPlanFrame, Int>) -> Binding<Int> {
        Binding(
            get: { (manager.rooms.first { $0.id == room.id }?.planFrame ?? RoomPlanFrame(column: 0, row: 0))[keyPath: key] },
            set: { value in
                guard var frame = manager.rooms.first(where: { $0.id == room.id })?.planFrame else { return }
                frame[keyPath: key] = value
                if manager.setPlanFrame(frame, for: room.id) {
                    placementError = nil
                } else {
                    placementError = "\(room.name) was not moved. That position overlaps another room or leaves the six-column board. Choose a free position; no layout was changed."
                }
            })
    }
}

/// A move or resize expressed in whole grid cells.
struct PlanCellDelta {
    var columns: Int
    var rows: Int
}

extension RoomPlanFrame {
    /// The frame's pixel rect on a board whose cells are `cell`.
    ///
    /// Rooms tile exactly — no gap, no inset. Two rooms that touch share one
    /// wall, and the walls are drawn once on top as their own layer. Giving
    /// each block its own inset border is what made the first pass read as a
    /// grid of cards rather than as a drawing.
    func rect(cell: CGSize, origin: CGFloat = 0) -> CGRect {
        CGRect(x: origin + cell.width * CGFloat(column),
               y: origin + cell.height * CGFloat(row),
               width: max(0, cell.width * CGFloat(width)),
               height: max(0, cell.height * CGFloat(height)))
    }
}

// MARK: - Board

/// The grid of room blocks. Six columns wide, growing downward.
struct PlanBoardView: View {
    @EnvironmentObject private var manager: LightManager
    let arranging: Bool
    @Binding var selectedRoomID: UUID?
    @Binding var selectedLightID: String?
    var query: String = ""
    /// Fired whenever a room or one of its fixtures is tapped (not dragged).
    /// Only iOS uses it, to open `RoomDetailSheet` in place of the
    /// macOS-only inspector column.
    var onRoomTapped: (() -> Void)? = nil

    /// A move or resize in progress, held here so the ghost and the block can
    /// be drawn from the same source.
    @State private var draft: PlanDraft?

    struct PlanDraft {
        let roomID: UUID
        let frame: RoomPlanFrame
        let valid: Bool
    }

    /// Half the exterior wall's stroke width. The envelope is drawn centred on
    /// the board's edge, so without this half of it would hang outside.
    private let boardInset: CGFloat = 3

    private var rows: Int {
        var frames: [UUID: RoomPlanFrame] = [:]
        for room in manager.rooms {
            if let frame = room.planFrame { frames[room.id] = frame }
        }
        return max(2, frames.values.map(\.maxRow).max() ?? 2)
    }

    private var placedFrames: [RoomPlanFrame] {
        manager.rooms.compactMap { displayFrame(for: $0) }
    }

    var body: some View {
        GeometryReader { proxy in
            let cell = cellSize(in: proxy.size)
            ZStack(alignment: .topLeading) {
                ForEach(manager.rooms) { room in
                    block(for: room, cell: cell)
                }
                refusal(cell: cell)
            }
        }
        .frame(minWidth: CGFloat(PlanLayout.columns) * 74,
               minHeight: CGFloat(rows) * 96)
    }

    private func cellSize(in size: CGSize) -> CGSize {
        CGSize(width: max(1, (size.width - boardInset * 2) / CGFloat(PlanLayout.columns)),
               height: max(1, (size.height - boardInset * 2) / CGFloat(rows)))
    }

    private var selectedFrame: RoomPlanFrame? {
        guard let selectedRoomID else { return nil }
        return manager.rooms.first { $0.id == selectedRoomID }?.planFrame
    }

    // MARK: Pieces
    //
    // Split out of `body` deliberately. SwiftUI type-checks a view body as one
    // expression, and a single ZStack carrying a ForEach, two conditionals and
    // a dozen geometry expressions takes the compiler past its budget.

    @ViewBuilder
    private func block(for room: Room, cell: CGSize) -> some View {
        if let frame = displayFrame(for: room) {
            let rect = frame.rect(cell: cell, origin: boardInset)
            VStack(alignment: .leading, spacing: 8) {
                Text(room.name).font(.headline).lineLimit(2)
                Text("\(manager.devices(in: room).count) fixtures")
                    .font(.caption).foregroundStyle(Lumen.meter)
                Spacer(minLength: 0)
                HStack {
                    Text("\(frame.width) × \(frame.height) cells").font(.caption)
                    Spacer()
                    Image(systemName: "arrow.down.right")
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                        .gesture(DragGesture().onChanged { value in
                            move(room: room, by: PlanCellDelta(
                                columns: Int((value.translation.width / cell.width).rounded()),
                                rows: Int((value.translation.height / cell.height).rounded())),
                                 resize: true, committing: false)
                        }.onEnded { value in
                            move(room: room, by: PlanCellDelta(
                                columns: Int((value.translation.width / cell.width).rounded()),
                                rows: Int((value.translation.height / cell.height).rounded())),
                                 resize: true, committing: true)
                        })
                        .accessibilityHidden(true)
                }
            }
            .padding(12)
            .background(Lumen.deck)
            .overlay(Rectangle().stroke(selectedRoomID == room.id ? Lumen.lit : Lumen.rule, lineWidth: 1))
            .padding(3)
            .contentShape(Rectangle())
            .onTapGesture { selectedRoomID = room.id }
            .gesture(DragGesture().onChanged { value in
                move(room: room, by: PlanCellDelta(
                    columns: Int((value.translation.width / cell.width).rounded()),
                    rows: Int((value.translation.height / cell.height).rounded())),
                     resize: false, committing: false)
            }.onEnded { value in
                move(room: room, by: PlanCellDelta(
                    columns: Int((value.translation.width / cell.width).rounded()),
                    rows: Int((value.translation.height / cell.height).rounded())),
                     resize: false, committing: true)
            })
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .zIndex(draft?.roomID == room.id ? 10 : 0)
        }
    }

    /// A drop that would overlap, shown in red where it would have landed.
    /// The block itself does not move, because a refused drop reverts.
    @ViewBuilder
    private func refusal(cell: CGSize) -> some View {
        if let draft, !draft.valid {
            let rect = draft.frame.rect(cell: cell, origin: boardInset)
            Rectangle()
                .fill(Lumen.fail.opacity(0.10))
                .overlay(
                    Rectangle()
                        .stroke(Lumen.fail, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                )
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
                .zIndex(20)
        }
    }

    // MARK: Placement

    /// The frame to draw: the live draft while a block is being dragged, and
    /// the committed frame otherwise.
    private func displayFrame(for room: Room) -> RoomPlanFrame? {
        if let draft, draft.roomID == room.id, draft.valid { return draft.frame }
        return room.planFrame
    }

    private func matchesQuery(_ room: Room) -> Bool {
        guard !query.isEmpty else { return true }
        if manager.room(room, matchesQuery: query) { return true }
        return manager.devices(in: room).contains { manager.device($0, matchesQuery: query) }
    }

    /// Translate a cell delta into a candidate frame, showing it live and
    /// committing only when the gesture ends on something legal.
    private func move(room: Room, by delta: PlanCellDelta,
                      resize: Bool, committing: Bool) {
        guard let base = room.planFrame else { return }
        let candidate: RoomPlanFrame
        if resize {
            candidate = RoomPlanFrame(column: base.column, row: base.row,
                                      width: base.width + delta.columns,
                                      height: base.height + delta.rows)
        } else {
            candidate = RoomPlanFrame(column: base.column + delta.columns,
                                      row: base.row + delta.rows,
                                      width: base.width, height: base.height)
        }

        var others: [UUID: RoomPlanFrame] = [:]
        for other in manager.rooms where other.id != room.id {
            if let frame = other.planFrame { others[other.id] = frame }
        }
        let valid = PlanLayout.canPlace(candidate, for: room.id, among: others)

        if committing {
            draft = nil
            // A refused drop reverts. Never reflow a board somebody arranged.
            if valid { manager.setPlanFrame(candidate, for: room.id) }
        } else {
            draft = PlanDraft(roomID: room.id, frame: candidate, valid: valid)
        }
    }
}

// MARK: - Walls

/// Every wall on the plan, drawn once.
///
/// Two rooms that touch produce the same edge twice, so edges are collected
/// into a set first and the shared one is stroked a single time. That is the
/// difference between a plan and a grid of bordered tiles.
///
/// Line weight carries the hierarchy the way it does on any drawing: the
/// exterior envelope is heavy, interior partitions are light, and both sit on
/// a wider poché band so a wall reads as having thickness.
struct PlanWallLayer: View {
    let frames: [RoomPlanFrame]
    let cell: CGSize
    let inset: CGFloat
    let bounds: CGSize
    var selected: RoomPlanFrame?

    /// An edge rounded to whole points, so the two rooms either side of a
    /// shared wall collapse to one entry.
    private struct Edge: Hashable {
        let x1: Int, y1: Int, x2: Int, y2: Int
    }

    var body: some View {
        Canvas { context, size in
            let edges = collectEdges()
            // Poché first, then the line on top of it.
            for pass in 0..<2 {
                for edge in edges {
                    let outer = isOuter(edge, in: size)
                    var path = Path()
                    path.move(to: CGPoint(x: CGFloat(edge.x1), y: CGFloat(edge.y1)))
                    path.addLine(to: CGPoint(x: CGFloat(edge.x2), y: CGFloat(edge.y2)))
                    context.stroke(path,
                                   with: .color(pass == 0 ? Lumen.poche
                                                          : (outer ? Lumen.wallOuter : Lumen.wall)),
                                   style: StrokeStyle(lineWidth: strokeWidth(pass: pass, outer: outer),
                                                      lineCap: .square))
                }
            }
            markSelection(in: &context)
        }
        .accessibilityHidden(true)
    }

    private func strokeWidth(pass: Int, outer: Bool) -> CGFloat {
        if pass == 0 { return outer ? 9 : 6 }
        return outer ? 5 : 2
    }

    private func collectEdges() -> Set<Edge> {
        var edges: Set<Edge> = []
        for frame in frames {
            let rect = frame.rect(cell: cell, origin: inset)
            let minX = Int(rect.minX.rounded()), maxX = Int(rect.maxX.rounded())
            let minY = Int(rect.minY.rounded()), maxY = Int(rect.maxY.rounded())
            edges.insert(Edge(x1: minX, y1: minY, x2: maxX, y2: minY))
            edges.insert(Edge(x1: minX, y1: maxY, x2: maxX, y2: maxY))
            edges.insert(Edge(x1: minX, y1: minY, x2: minX, y2: maxY))
            edges.insert(Edge(x1: maxX, y1: minY, x2: maxX, y2: maxY))
        }
        return edges
    }

    /// An edge belongs to the envelope when it lies on the board's inset
    /// bounds rather than between two rooms.
    private func isOuter(_ edge: Edge, in size: CGSize) -> Bool {
        let epsilon: CGFloat = 1.5
        if edge.x1 == edge.x2 {
            let x = CGFloat(edge.x1)
            return abs(x - inset) < epsilon || abs(x - (size.width - inset)) < epsilon
        }
        let y = CGFloat(edge.y1)
        return abs(y - inset) < epsilon || abs(y - (size.height - inset)) < epsilon
    }

    /// The selected room is marked up with a heavier outline, the way a zone
    /// is highlighted on a drawing.
    ///
    /// It lands on the room's own edges rather than inside them. An inset
    /// outline sits a hair off the wall it is marking, and what you read is
    /// two parallel lines where there should be one — a rendering fault, not
    /// a highlight.
    private func markSelection(in context: inout GraphicsContext) {
        guard let selected else { return }
        let rect = selected.rect(cell: cell, origin: inset)
        context.stroke(Path(rect), with: .color(Lumen.mark.opacity(0.85)), lineWidth: 2.5)
    }
}

// MARK: - Fixture symbols

/// A fixture as an electrical-plan symbol.
///
/// A circle with a cross through it is a ceiling fixture, a bar is a strip, a
/// square is a panel. The vocabulary is a century old and free, and it means
/// the drawing states what kind of fixture is there rather than only where.
/// An unreachable one is drawn hollow and dashed, which is the same convention
/// as an item shown for reference.
struct PlanFixtureSymbol: View {
    let symbol: FixtureSymbol
    let colour: Color
    let isLit: Bool
    let isReachable: Bool
    var isSelected: Bool = false
    var size: CGFloat = 21

    private var strokeColour: Color {
        if !isReachable { return Lumen.wallOuter }
        return isLit ? colour : Lumen.faint
    }

    private var strokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: 1.3, dash: isReachable ? [] : [2, 2])
    }

    var body: some View {
        ZStack {
            if isSelected {
                Circle()
                    .stroke(Lumen.mark, lineWidth: 1.4)
                    .frame(width: size * 0.95, height: size * 0.95)
            }
            glyph
            // The fixture is the source, so a lit one carries a bright core
            // and the pool reads as coming from it.
            if isLit && isReachable {
                Circle()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: size * 0.145, height: size * 0.145)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var glyph: some View {
        switch symbol {
        case .bulb:  bulb
        case .strip: strip
        case .panel: panel
        }
    }

    /// The cross runs through the circle, not around it. That is what
    /// separates a fixture symbol from a coloured dot.
    private var bulb: some View {
        ZStack {
            Circle()
                .fill(isLit ? colour.opacity(0.5) : Color.clear)
                .frame(width: size * 0.6, height: size * 0.6)
            Circle()
                .stroke(strokeColour, style: strokeStyle)
                .frame(width: size * 0.6, height: size * 0.6)
            Path { path in
                path.move(to: CGPoint(x: size / 2, y: size * 0.12))
                path.addLine(to: CGPoint(x: size / 2, y: size * 0.88))
                path.move(to: CGPoint(x: size * 0.12, y: size / 2))
                path.addLine(to: CGPoint(x: size * 0.88, y: size / 2))
            }
            .stroke(strokeColour, style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
        }
    }

    private var strip: some View {
        Capsule()
            .fill(isLit ? colour.opacity(0.55) : Color.clear)
            .overlay(Capsule().stroke(strokeColour, style: strokeStyle))
            .frame(width: size * 0.87, height: size * 0.2)
    }

    private var panel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(isLit ? colour.opacity(0.5) : Color.clear)
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .stroke(strokeColour, style: strokeStyle)
            Path { path in
                path.move(to: CGPoint(x: 0, y: size * 0.32))
                path.addLine(to: CGPoint(x: size * 0.64, y: size * 0.32))
                path.move(to: CGPoint(x: size * 0.32, y: 0))
                path.addLine(to: CGPoint(x: size * 0.32, y: size * 0.64))
            }
            .stroke(strokeColour.opacity(0.75), lineWidth: 0.9)
        }
        .frame(width: size * 0.64, height: size * 0.64)
    }
}

// MARK: - Dimension line

/// A room's level, drawn the way a drawing states a measurement: a tick at
/// each end, the fill on the line, and the figure sitting on it.
///
/// This replaces a 24 pt mono figure in the corner of each block, which
/// competed with the drawing and read as a dashboard tile. The pools carry the
/// impression of brightness; the dimension carries the exact number.
struct PlanDimensionLine: View {
    let level: Double
    let figure: String

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Lumen.faint)
                    .frame(height: 1)
                Rectangle()
                    .fill(Lumen.mark)
                    .frame(width: max(0, proxy.size.width * level), height: 2)
                    .shadow(color: Lumen.mark.opacity(0.45), radius: 2.5)
                tick.offset(x: 0)
                tick.offset(x: proxy.size.width - 1)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .overlay(alignment: .topTrailing) {
                // The figure sits above the line rather than on it, so a
                // knocked-out background was never holding a break open — it
                // was a dark rectangle punched through whatever pool happened
                // to be behind it. A halo instead.
                Text(figure)
                    .font(LumenType.readout(size: 12.5))
                    .monospacedDigit()
                    .foregroundStyle(Lumen.lit)
                    .shadow(color: Lumen.stage.opacity(0.92), radius: 1.5)
                    .shadow(color: Lumen.stage.opacity(0.9), radius: 7)
                    .offset(y: -10)
            }
        }
        .frame(height: 14)
    }

    private var tick: some View {
        Rectangle()
            .fill(Lumen.wallOuter)
            .frame(width: 1, height: 13)
    }
}

// MARK: - Title block

/// The drawing's metadata, in the drawing's own language.
///
/// Ruled cells along the foot of the sheet, carrying the facts that used to
/// sit in a header strip: rooms, fixtures, how many are linked, when the
/// network was last scanned. The one authored hue still means network truth;
/// it just lives where a drawing puts its metadata.
struct PlanTitleBlock: View {
    @EnvironmentObject private var manager: LightManager

    private var lit: Int { manager.devices.filter { $0.isOn && !$0.isStale }.count }
    private var linked: Int { manager.devices.filter { !$0.isStale }.count }

    var body: some View {
        HStack(spacing: 0) {
            cell(key: "LUMENDESK", value: nil)
            cell(key: "ROOMS", value: "\(manager.rooms.count)")
            cell(key: "FIXTURES", value: "\(manager.devices.count)")
            cell(key: "LIT", value: "\(lit)")
            cell(key: "LINKED", value: "\(linked)/\(manager.devices.count)", isLink: true)
            Spacer(minLength: 0)
        }
        .overlay(Rectangle().stroke(Lumen.wallOuter, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(manager.rooms.count) rooms, \(manager.devices.count) fixtures, \(linked) linked")
    }

    private func cell(key: String, value: String?, isLink: Bool = false) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(LumenType.readout(size: 10.5, weight: .regular))
                .kerning(0.4)
                .foregroundStyle(Lumen.meter)
            if let value {
                Text(value)
                    .font(LumenType.readout(size: 10.5))
                    .foregroundStyle(isLink ? Lumen.link : Lumen.lit)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Lumen.wall).frame(width: 1)
        }
    }
}

// MARK: - One room

private struct RoomBlockView: View {
    @EnvironmentObject private var manager: LightManager
    let room: Room
    let arranging: Bool
    let dimmed: Bool
    let selected: Bool
    @Binding var selectedLightID: String?
    let onSelect: () -> Void
    let onLevel: (Double) -> Void
    let onMove: (PlanCellDelta, Bool) -> Void
    let onResize: (PlanCellDelta, Bool) -> Void
    let cell: CGSize
    /// Fired only by a genuine tap on the room or one of its fixtures —
    /// never by `commitLevel`, which also calls `onSelect()` on every frame
    /// of a brightness drag. Conflating the two meant dragging across a room
    /// to set its level fired this on each frame too.
    var onTapped: (() -> Void)? = nil

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var lights: [LightDevice] { manager.devices(in: room) }
    private var litLights: [LightDevice] { lights.filter { $0.isOn && !$0.isStale } }

    private var level: Double {
        guard !litLights.isEmpty else { return 0 }
        return litLights.reduce(0) { $0 + $1.brightness } / Double(litLights.count)
    }

    private var percent: Int { Int((level * 100).rounded()) }
    private var figure: String {
        lights.isEmpty ? "—" : "\(percent)  \(litLights.count)/\(lights.count)"
    }
    private var spokenValue: String {
        "\(percent) percent, \(litLights.count) of \(lights.count) lit"
    }

    /// The pool's shape and the drawn symbol read the same fixture, so they
    /// go through one classifier rather than two that can drift apart.
    private func symbol(for light: LightDevice) -> FixtureSymbol {
        FixtureSymbol.classify(isMatrix: light.isLIFXLuna,
                               hasSegments: manager.segmentStudioProfile(for: light) != nil)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(selected ? Lumen.floorRaised : Lumen.floor)

            // The pools. This is the status display: what a room is doing is
            // legible from across the desk without reading anything.
            RoomPoolCanvas(pools: pools, flat: reduceTransparency)
                .allowsHitTesting(false)

            // A plan hatches what is shown for reference rather than built.
            // That is what an unreachable fixture is — but it is the fixture,
            // not the room: one dead strip does not put the bedroom out of
            // contract, and hatching the whole floor said it did.
            hatchPatches

            fixtureSymbols
            labelStack

            if arranging { resizeGrip }
        }
        .clipped()
        .opacity(dimmed ? 0.35 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !arranging else { return }
            onSelect()
            onTapped?()
        }
        .gesture(blockGesture)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(room.name)
        .accessibilityValue(spokenValue)
    }

    private var hatchPatches: some View {
        GeometryReader { proxy in
            ForEach(lights.filter(\.isStale)) { light in
                PlanHatchPatch()
                    .position(x: proxy.size.width * manager.planAnchor(for: light.id, in: room).x,
                              y: proxy.size.height * manager.planAnchor(for: light.id, in: room).y)
            }
        }
        .allowsHitTesting(false)
    }

    private var labelStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            roomLabel
            Spacer(minLength: 6)
            PlanDimensionLine(level: level, figure: figure)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
    }

    private var roomLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(room.name)
                .font(.system(size: 13, weight: .semibold))
                .kerning(0.65)
                .textCase(.uppercase)
                .foregroundStyle(Lumen.lit)
                .lineLimit(1)

            // How many of this room's fixtures are actually lit. The drawing
            // shows you the light; this says whether any of it is missing.
            Text("\(litLights.count)/\(lights.count)")
                .font(LumenType.readout(size: 11, weight: .regular))
                .foregroundStyle(Lumen.meter)

            if !lights.isEmpty {
                Spacer(minLength: 6)
                roomPowerButton
            }
        }
        // A tight shadow for edge definition and a wide one to hold the
        // label together where it crosses a bright pool.
        .shadow(color: Lumen.stage.opacity(0.92), radius: 1.5)
        .shadow(color: Lumen.stage.opacity(0.85), radius: 8)
    }

    /// Every room's own blackout switch, on the drawing itself rather than
    /// behind a selection-then-scroll trip into the inspector. This is the
    /// fastest way to shut a whole room off, on either platform, so it needed
    /// to be visible without opening anything first.
    private var roomAnyOn: Bool { lights.contains(where: \.isOn) }

    private var roomPowerButton: some View {
        Button {
            // Deliberately does not call `onSelect()`: on iOS that opens
            // `RoomDetailSheet`, and the point of this button is a blackout
            // that needs nothing to open first.
            manager.setPower(in: room, on: !roomAnyOn)
        } label: {
            Image(systemName: "power")
        }
        .buttonStyle(LumenIconButtonStyle(size: 22, prominent: roomAnyOn))
        // The drawn key stays compact so it doesn't crowd the room label,
        // but the tappable area grows to the platform's touch target so a
        // near miss on a dense plan doesn't land on the room block behind it.
        .lumenInteractiveTarget()
        .help(roomAnyOn ? "Turn off every light in \(room.name)" : "Turn on every light in \(room.name)")
        .accessibilityLabel(roomAnyOn ? "Turn off all lights in \(room.name)" : "Turn on all lights in \(room.name)")
    }

    private var pools: [RoomPoolCanvas.Pool] {
        lights.compactMap { light in
            guard light.isOn, !light.isStale else { return nil }
            return RoomPoolCanvas.Pool(anchor: manager.planAnchor(for: light.id, in: room),
                                       colour: light.color,
                                       opacity: 0.09 + light.brightness * 0.36,
                                       symbol: symbol(for: light))
        }
    }

    private var fixtureSymbols: some View {
        GeometryReader { proxy in
            ForEach(lights) { light in
                symbolButton(for: light)
                    .position(x: proxy.size.width * manager.planAnchor(for: light.id, in: room).x,
                              y: proxy.size.height * manager.planAnchor(for: light.id, in: room).y)
            }
        }
    }

    private func symbolButton(for light: LightDevice) -> some View {
        let kind = symbol(for: light)
        return Button {
            onSelect()
            selectedLightID = light.id
            onTapped?()
        } label: {
            PlanFixtureSymbol(symbol: kind,
                              colour: light.color,
                              isLit: light.isOn,
                              isReachable: !light.isStale,
                              isSelected: selectedLightID == light.id)
        }
        .buttonStyle(.plain)
        .disabled(arranging)
        .help("\(light.label) · \(kind.spokenName)")
        .accessibilityLabel("Select \(light.label), \(kind.spokenName)")
    }

    private var resizeGrip: some View {
        Path { path in
            path.move(to: CGPoint(x: 15, y: 0))
            path.addLine(to: CGPoint(x: 0, y: 15))
            path.move(to: CGPoint(x: 15, y: 6))
            path.addLine(to: CGPoint(x: 6, y: 15))
        }
        .stroke(Lumen.meter, lineWidth: 1.5)
        .frame(width: 15, height: 15)
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .gesture(resizeGesture)
        .accessibilityHidden(true)
    }

    // MARK: Gestures

    /// One gesture that branches inside, rather than a ternary between two.
    ///
    /// Two computed properties returning `some Gesture` have two *distinct*
    /// opaque types even when the underlying gesture is identical, so
    /// `arranging ? moveGesture : levelGesture` can never type-check. Doing the
    /// branch in the handlers keeps a single concrete type.
    ///
    /// Plain drags set the whole room, because the room is the object here. A
    /// tap only selects: a zero-distance drag meant clicking a block to look at
    /// it slammed its level to wherever the pointer landed.
    private var blockGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in handleDrag(value, committing: false) }
            .onEnded { value in handleDrag(value, committing: true) }
    }

    private func handleDrag(_ value: DragGesture.Value, committing: Bool) {
        if arranging {
            onMove(cellDelta(value.translation), committing)
        } else {
            commitLevel(at: value.location.x)
        }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in onResize(cellDelta(value.translation), false) }
            .onEnded { value in onResize(cellDelta(value.translation), true) }
    }

    private func commitLevel(at x: CGFloat) {
        onSelect()
        let width = max(1, cell.width * CGFloat(room.planFrame?.width ?? 1))
        onLevel(min(1, max(0, Double(x / width))))
    }

    private func cellDelta(_ translation: CGSize) -> PlanCellDelta {
        PlanCellDelta(columns: Int((translation.width / max(1, cell.width)).rounded()),
                      rows: Int((translation.height / max(1, cell.height)).rounded()))
    }
}

// MARK: - Hatch

/// The drafting mark for something shown for reference rather than built.
///
/// Scoped to one fixture's patch of floor: an unreachable strip is not in
/// contract, but the room around it still is. The diagonals fade out at the
/// edge so the patch reads as a zone on the drawing and not as a sticker
/// laid on top of it.
struct PlanHatchPatch: View {
    var size: CGFloat = 62
    var spacing: CGFloat = 5

    var body: some View {
        Canvas { context, canvas in
            let colour = Lumen.wallOuter.opacity(0.34)
            var offset = -canvas.height
            while offset < canvas.width {
                var path = Path()
                path.move(to: CGPoint(x: offset, y: canvas.height))
                path.addLine(to: CGPoint(x: offset + canvas.height, y: 0))
                context.stroke(path, with: .color(colour), lineWidth: 1)
                offset += spacing
            }
        }
        .frame(width: size, height: size)
        .mask {
            RadialGradient(stops: [
                .init(color: .black, location: 0.34),
                .init(color: .clear, location: 0.70)
            ], center: .center, startRadius: 0, endRadius: size / 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Pools

/// Light falling on the drawing.
///
/// Drawn in a `Canvas` with a screen blend so two lamps in one room add up
/// the way light actually does, and blurred so the edge of a pool is a
/// falloff rather than a circle. Reduce Transparency swaps the blur for flat
/// discs, which keeps the information and drops the cost.
///
/// A pool is shaped by what is throwing it: a strip lays down a wide shallow
/// wash, a ceiling fixture a round one, a panel something between. The aspect
/// says which before you read the symbol. Sizes are deliberately well under
/// half the room — pools that fill the room stop reading as pools and turn
/// the floor into one flat wash.
struct RoomPoolCanvas: View {
    struct Pool {
        let anchor: PlanAnchor
        let colour: Color
        let opacity: Double
        let symbol: FixtureSymbol

        /// Half-width as a fraction of the room's short-ish dimension.
        /// `CGFloat` rather than `Double` so the geometry below never leans
        /// on the implicit conversion between the two.
        var extent: CGFloat {
            switch symbol {
            case .strip: return 0.27
            case .bulb:  return 0.22
            case .panel: return 0.20
            }
        }

        /// Width over height. A strip throws wide and shallow.
        var aspect: CGFloat {
            switch symbol {
            case .strip: return 1.75
            case .bulb:  return 1.0
            case .panel: return 1.15
            }
        }
    }

    let pools: [Pool]
    var flat: Bool = false

    var body: some View {
        Canvas { context, size in
            context.blendMode = .screen
            if !flat { context.addFilter(.blur(radius: 9)) }

            for pool in pools {
                // Taking the base off the width alone would spill a pool out
                // of a tall narrow room; off the height alone it would vanish
                // in a wide one. The smaller of the two, with the aspect
                // folded in, behaves in both.
                let base = min(size.width, size.height * pool.aspect)
                let rx = base * pool.extent
                let ry = rx / pool.aspect
                let centre = CGPoint(x: size.width * pool.anchor.x,
                                     y: size.height * pool.anchor.y)
                let rect = CGRect(x: centre.x - rx, y: centre.y - ry,
                                  width: rx * 2, height: ry * 2)
                let shading: GraphicsContext.Shading = flat
                    ? .color(pool.colour.opacity(pool.opacity * 0.6))
                    : .radialGradient(
                        Gradient(stops: [
                            .init(color: pool.colour.opacity(pool.opacity), location: 0),
                            .init(color: pool.colour.opacity(pool.opacity), location: 0.06),
                            .init(color: pool.colour.opacity(0), location: 0.66)
                        ]),
                        center: centre, startRadius: 0, endRadius: max(rx, ry))
                context.fill(Ellipse().path(in: rect), with: shading)
            }
        }
        .accessibilityHidden(true)
    }
}
