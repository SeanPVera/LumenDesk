import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - Direction A session state

/// View state for the foreground room session. Desired and observed fixture
/// state remain in `LightManager`; this store only remembers where the person
/// is looking and which direct-manipulation tool is open.
@MainActor
final class RoomCanvasSessionStore: ObservableObject {
    @Published var selectedRoomID: UUID?
    @Published var selectedFixtureIDs: Set<String> = []
    @Published var showingComposer = false
    @Published var showingAddOrRepair = false
    @Published var showingLive = false
    @Published var showingSettings = false
    @Published var editorDeviceID: String?
    private var selectionRoomID: UUID?

    func select(_ room: Room, devices: [LightDevice]) {
        selectedRoomID = room.id
        selectedFixtureIDs = Set(devices.map(\.id))
        selectionRoomID = room.id
        editorDeviceID = nil
    }

    @discardableResult
    func select(roomID: UUID, rooms: [Room], devices: [LightDevice]) -> Bool {
        guard let room = rooms.first(where: { $0.id == roomID }) else { return false }
        select(room, devices: devices.filter { room.lightIDs.contains($0.id) })
        return true
    }

    func reconcile(rooms: [Room], devices: [LightDevice]) {
        if selectedRoomID == nil || !rooms.contains(where: { $0.id == selectedRoomID }) {
            selectedRoomID = rooms.first?.id
        }
        guard let room = rooms.first(where: { $0.id == selectedRoomID }) else {
            selectedFixtureIDs = []
            selectionRoomID = nil
            return
        }
        let knownIDs = Set(devices.map(\.id))
        let available = room.lightIDs.filter(knownIDs.contains)
        if selectionRoomID != room.id {
            selectedFixtureIDs = Set(available)
            selectionRoomID = room.id
        } else {
            selectedFixtureIDs = RoomWorkspaceSelection.reconciled(
                selected: selectedFixtureIDs,
                available: available
            )
        }
        if let editorDeviceID, !available.contains(editorDeviceID) {
            self.editorDeviceID = nil
        }
    }
}

enum RoomCanvasStatus: Int, CaseIterable, Equatable {
    case confirmed
    case pending
    case changedElsewhere
    case needsAttention

    var title: String {
        switch self {
        case .confirmed: return "Confirmed"
        case .pending: return "Pending"
        case .changedElsewhere: return "Changed elsewhere"
        case .needsAttention: return "Needs attention"
        }
    }

    var symbol: String {
        switch self {
        case .confirmed: return "checkmark.circle.fill"
        case .pending: return "clock.fill"
        case .changedElsewhere: return "arrow.triangle.2.circlepath.circle.fill"
        case .needsAttention: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .confirmed: return Lumen.verdigris
        case .pending: return Lumen.warn
        case .changedElsewhere: return Lumen.graphite
        case .needsAttention: return Lumen.fail
        }
    }

    @MainActor
    static func resolve(_ lights: [LightDevice], manager: LightManager) -> RoomCanvasStatus {
        if lights.contains(where: { $0.isStale || manager.commandState(for: $0.id).phase == .failed }) {
            return .needsAttention
        }
        if lights.contains(where: {
            let phase = manager.commandState(for: $0.id).phase
            return phase == .queued || phase == .sending || phase == .applied
        }) {
            return .pending
        }
        if lights.contains(where: { manager.externallyChangedDeviceIDs.contains($0.id) }) {
            return .changedElsewhere
        }
        return .confirmed
    }
}

struct RoomCanvasStatusBadge: View {
    let status: RoomCanvasStatus
    var compact = false

    var body: some View {
        Label(status.title, systemImage: status.symbol)
            .font(LumenType.body(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(status.color)
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 5 : 7)
            .background(
                Capsule(style: .continuous)
                    .fill(status.color.opacity(status == .changedElsewhere ? 0.08 : 0.11))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(status.color.opacity(0.42), lineWidth: 1)
            )
            .accessibilityLabel("Status: \(status.title)")
    }
}

// MARK: - Room-first shell

struct RoomCanvasShellView: View {
    @EnvironmentObject private var manager: LightManager
    @StateObject private var session = RoomCanvasSessionStore()
    @AppStorage(AppPreferenceKey.roomCanvasOpenRequest) private var openRoomRequest = ""
    let startInSetup: Bool
    let onPrepared: () -> Void
    @State private var handledInitialSetup = false

    init(startInSetup: Bool = false, onPrepared: @escaping () -> Void = {}) {
        self.startInSetup = startInSetup
        self.onPrepared = onPrepared
    }

    private var selectedRoom: Room? {
        manager.rooms.first { $0.id == session.selectedRoomID }
    }

    private var editorDevice: LightDevice? {
        guard let id = session.editorDeviceID else { return nil }
        return manager.devices.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            if manager.isDemoMode { roomCanvasDemoBanner }
            NavigationSplitView {
                RoomCanvasSidebar(session: session)
                    #if os(macOS)
                    .navigationSplitViewColumnWidth(min: 190, ideal: 228, max: 280)
                    #endif
            } detail: {
                NavigationStack {
                    if let selectedRoom {
                        RoomCanvasWorkspace(room: selectedRoom, session: session)
                    } else {
                        RoomCanvasEmptyState(openSetup: { session.showingAddOrRepair = true })
                    }
                }
            }
            .navigationSplitViewStyle(.balanced)
        }
        .font(LumenType.body())
        .foregroundStyle(Lumen.graphite)
        .tint(Lumen.ember)
        .background(Lumen.canvas)
        .overlay(alignment: .bottom) { statusOverlays }
        .onAppear {
            session.reconcile(rooms: manager.rooms, devices: manager.devices)
            consumeOpenRoomRequest(openRoomRequest)
            if startInSetup, !handledInitialSetup {
                handledInitialSetup = true
                session.showingAddOrRepair = true
            }
        }
        .onReceive(manager.$rooms) { rooms in
            session.reconcile(rooms: rooms, devices: manager.devices)
            consumeOpenRoomRequest(openRoomRequest)
        }
        .onReceive(manager.$devices) { devices in
            session.reconcile(rooms: manager.rooms, devices: devices)
        }
        .onChange(of: openRoomRequest) { request in
            consumeOpenRoomRequest(request)
        }
        .sheet(isPresented: $session.showingComposer, onDismiss: {
            manager.stopSceneRehearsal(restore: true)
        }) {
            if let selectedRoom {
                LookComposerView(
                    room: selectedRoom,
                    initialSelection: session.selectedFixtureIDs
                )
                .environmentObject(manager)
            }
        }
        .sheet(isPresented: $session.showingAddOrRepair) {
            AddOrRepairRoomView(
                selectedRoomID: $session.selectedRoomID,
                onFinish: onPrepared
            )
                .environmentObject(manager)
        }
        .sheet(isPresented: $session.showingLive) {
            if let selectedRoom {
                RoomLiveView(room: selectedRoom)
                    .environmentObject(manager)
            }
        }
        .sheet(isPresented: $session.showingSettings) {
            NavigationStack { RoomCanvasSettingsView() }
                .environmentObject(manager)
        }
        .sheet(isPresented: Binding(
            get: { session.editorDeviceID != nil },
            set: { if !$0 { session.editorDeviceID = nil } }
        )) {
            if let editorDevice {
                ContextualFixtureEditor(device: editorDevice)
                    .environmentObject(manager)
            }
        }
    }

    private func consumeOpenRoomRequest(_ request: String) {
        guard !request.isEmpty else { return }
        guard let roomID = UUID(uuidString: request) else {
            openRoomRequest = ""
            return
        }
        guard session.select(roomID: roomID, rooms: manager.rooms, devices: manager.devices) else {
            // A restore can publish rooms after the scene receives the request.
            // Keep it until the room collection arrives instead of opening the
            // wrong room and silently discarding the user's menu-bar choice.
            return
        }
        openRoomRequest = ""
    }

    private var roomCanvasDemoBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "testtube.2")
            Text("Sample Room · no physical fixtures are being controlled")
                .font(LumenType.body(size: 12, weight: .semibold))
            Spacer()
            Button("Return to live") { manager.exitDemoMode() }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .foregroundStyle(Lumen.graphite)
        .background(Lumen.verdigris.opacity(0.14))
        .overlay(alignment: .bottom) { Rectangle().fill(Lumen.verdigris).frame(height: 2) }
    }

    @ViewBuilder
    private var statusOverlays: some View {
        VStack(spacing: 8) {
            if let summary = manager.lastActionSummary {
                HStack(spacing: 10) {
                    Label(summary, systemImage: "arrow.uturn.backward.circle")
                    if manager.canUndo {
                        Button("Undo") { manager.undo() }
                    }
                    Button {
                        manager.dismissLastActionSummary()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
                .font(LumenType.body(size: 12, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Lumen.floor, in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).stroke(Lumen.rule, lineWidth: 1))
            }
            if let error = manager.commandError {
                RoomCanvasCommandToast(
                    message: error,
                    undoAction: manager.commandErrorUndo,
                    dismiss: { manager.commandError = nil }
                )
            }
        }
        .padding(16)
    }
}

private struct RoomCanvasSidebar: View {
    @EnvironmentObject private var manager: LightManager
    @ObservedObject var session: RoomCanvasSessionStore
    @State private var renamingRoomID: UUID?
    @State private var renamedRoomName = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("LUMENDESK")
                    .font(LumenType.instrumentLabel(size: 11))
                    .tracking(1.6)
                    .foregroundStyle(Lumen.ember)
                Text("Room Canvas")
                    .font(LumenType.display(size: 25, weight: .bold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 14)

            HStack {
                Text("Rooms")
                    .font(LumenType.body(size: 12, weight: .semibold))
                    .foregroundStyle(Lumen.meter)
                Spacer()
                Text("\(manager.rooms.count)")
                    .font(LumenType.readout(size: 12))
                    .foregroundStyle(Lumen.meter)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(manager.rooms) { room in
                        roomButton(room)
                    }
                }
                .padding(.horizontal, 10)
            }

            VStack(spacing: 8) {
                Button {
                    session.showingAddOrRepair = true
                } label: {
                    Label("Add or repair room", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .tint(Lumen.ember)

                Button {
                    session.showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)

                Label("Foreground local control", systemImage: "network")
                    .font(LumenType.body(size: 11))
                    .foregroundStyle(Lumen.meter)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(Lumen.floor.opacity(0.7))
        }
        .background(Lumen.deck)
        .navigationTitle("LumenDesk")
        .alert("Rename room", isPresented: Binding(
            get: { renamingRoomID != nil },
            set: { if !$0 { renamingRoomID = nil } }
        )) {
            TextField("Room name", text: $renamedRoomName)
            Button("Cancel", role: .cancel) { renamingRoomID = nil }
            Button("Save") {
                if let renamingRoomID {
                    manager.renameRoom(renamingRoomID, to: renamedRoomName)
                }
                renamingRoomID = nil
            }
            .disabled(renamedRoomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The new name appears anywhere this room can be opened or controlled.")
        }
    }

    private func roomButton(_ room: Room) -> some View {
        let lights = manager.devices(in: room)
        let selected = room.id == session.selectedRoomID
        let status = RoomCanvasStatus.resolve(lights, manager: manager)
        return HStack(spacing: 4) {
            Button {
                session.select(room, devices: lights)
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(selected ? Lumen.ember : Lumen.graphite.opacity(0.08))
                            .frame(width: 34, height: 34)
                        Image(systemName: "square.split.2x2")
                            .foregroundStyle(selected ? Lumen.canvas : Lumen.graphite)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(room.name)
                            .font(LumenType.display(size: 16, weight: .semibold))
                            .lineLimit(1)
                        Text("\(lights.count) fixture\(lights.count == 1 ? "" : "s")")
                            .font(LumenType.body(size: 11))
                            .foregroundStyle(Lumen.meter)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: status.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(status.color)
                        .accessibilityLabel(status.title)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .accessibilityAddTraits(selected ? .isSelected : [])

            Menu {
                Button("Rename Room") { beginRenaming(room) }
                Button("Delete Room", role: .destructive) { manager.deleteRoom(room.id) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 34)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Actions for \(room.name)")
            .help("Rename or delete \(room.name)")
            .fixedSize()
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Lumen.floor : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(selected ? Lumen.ember.opacity(0.38) : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func beginRenaming(_ room: Room) {
        renamedRoomName = room.name
        renamingRoomID = room.id
    }
}

private struct RoomCanvasEmptyState: View {
    let openSetup: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Lumen.floor)
                    .frame(width: 112, height: 96)
                Image(systemName: "square.dashed")
                    .font(.system(size: 40, weight: .light))
            }
            Text("Make the room the interface")
                .font(LumenType.display(size: 30, weight: .bold))
            Text("Find a fixture, identify it in the room, then place it where you expect to find it.")
                .font(LumenType.body(size: 15))
                .foregroundStyle(Lumen.meter)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Add or repair room", action: openSetup)
                .buttonStyle(.borderedProminent)
                .tint(Lumen.ember)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Lumen.canvas)
    }
}

// MARK: - Live Canvas

private struct RoomCanvasWorkspace: View {
    @EnvironmentObject private var manager: LightManager
    let room: Room
    @ObservedObject var session: RoomCanvasSessionStore

    private var currentRoom: Room {
        manager.rooms.first(where: { $0.id == room.id }) ?? room
    }

    private var lights: [LightDevice] { manager.devices(in: currentRoom) }

    private var selection: Binding<Set<String>> {
        Binding(
            get: { session.selectedFixtureIDs },
            set: { session.selectedFixtureIDs = $0 }
        )
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                if geometry.size.width >= 880 {
                    HStack(spacing: 0) {
                        canvasColumn
                        Divider().overlay(Lumen.rule)
                        selectionInspector
                            .frame(width: min(330, max(280, geometry.size.width * 0.27)))
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            canvasColumn
                            selectionInspector
                        }
                    }
                }
                LookShelf(
                    room: currentRoom,
                    compose: { session.showingComposer = true }
                )
            }
        }
        .background(Lumen.canvas)
        .navigationTitle(currentRoom.name)
        .onAppear { reconcileSelection() }
        .onChange(of: room.id) { _ in reconcileSelection(forceAll: true) }
        .onChange(of: currentRoom.lightIDs) { _ in reconcileSelection() }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                roomHeading(showsInstruction: true)
                Spacer()
                roomStatus
                headerActions
            }
            VStack(alignment: .leading, spacing: 10) {
                roomHeading(showsInstruction: false)
                HStack(spacing: 10) {
                    roomStatus
                    Spacer(minLength: 4)
                    headerActions
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Lumen.floor.opacity(0.76))
        .overlay(alignment: .bottom) { Rectangle().fill(Lumen.ruleSoft).frame(height: 1) }
    }

    private func roomHeading(showsInstruction: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(currentRoom.name)
                .font(LumenType.display(size: 28, weight: .bold))
                .lineLimit(1)
            if showsInstruction {
                Text("Touch a fixture to select it. Drag it to keep the canvas familiar.")
                    .font(LumenType.body(size: 12))
                    .foregroundStyle(Lumen.meter)
                    .lineLimit(1)
            }
        }
    }

    private var roomStatus: some View {
        RoomCanvasStatusBadge(
            status: RoomCanvasStatus.resolve(lights, manager: manager),
            compact: true
        )
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            Button {
                session.showingLive = true
            } label: {
                Label("Live", systemImage: "waveform")
            }
            .buttonStyle(.bordered)
            Button {
                manager.scan()
            } label: {
                if manager.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Find", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .disabled(manager.isScanning)
            .help(manager.isScanning ? manager.scanPhase : "Find fixtures on the local network")
        }
    }

    private var canvasColumn: some View {
        VStack(spacing: 0) {
            if lights.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "lightbulb.slash")
                        .font(.system(size: 34, weight: .light))
                    Text("No fixtures placed")
                        .font(LumenType.display(size: 22, weight: .bold))
                    Text("Use Add or repair room to find and place fixtures.")
                        .foregroundStyle(Lumen.meter)
                    Button("Add or repair") { session.showingAddOrRepair = true }
                        .buttonStyle(.borderedProminent)
                        .tint(Lumen.ember)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(30)
            } else {
                DirectionARoomField(
                    room: currentRoom,
                    lights: lights,
                    selection: selection
                )
                .padding(18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Lumen.canvas)
    }

    private var selectionInspector: some View {
        let targets = lights.filter { session.selectedFixtureIDs.contains($0.id) }
        return RoomSelectionInspector(
            room: currentRoom,
            targets: targets,
            compose: { session.showingComposer = true },
            edit: { session.editorDeviceID = $0 }
        )
        .id(targets.map(\.id).sorted().joined(separator: "|"))
    }

    private func reconcileSelection(forceAll: Bool = false) {
        let available = lights.map(\.id)
        if forceAll {
            session.selectedFixtureIDs = Set(available)
        } else {
            session.selectedFixtureIDs = RoomWorkspaceSelection.reconciled(
                selected: session.selectedFixtureIDs,
                available: available
            )
        }
    }
}

private struct DirectionARoomField: View {
    @EnvironmentObject private var manager: LightManager
    let room: Room
    let lights: [LightDevice]
    @Binding var selection: Set<String>
    @State private var dragOffsets: [String: CGSize] = [:]

    var body: some View {
        GeometryReader { geometry in
            let compactWidth = geometry.size.width < 520
            let condensed = compactWidth || geometry.size.height < 420
            let horizontalInset: CGFloat = compactWidth ? 34 : 54
            let verticalInset: CGFloat = condensed ? 42 : 46
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Lumen.floor)
                roomGrid
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Lumen.graphite, lineWidth: 3)
                roomDetails

                ForEach(lights.indices, id: \.self) { index in
                    let light = lights[index]
                    let anchor = canvasAnchor(for: light, index: index)
                    let offset = dragOffsets[light.id] ?? .zero
                    FixtureCanvasNode(
                        light: light,
                        selected: selection.contains(light.id),
                        status: RoomCanvasStatus.resolve([light], manager: manager),
                        compact: compactWidth,
                        condensed: condensed,
                        select: { toggle(light.id) }
                    )
                    .frame(width: nodeWidth(for: light, compact: compactWidth),
                           height: condensed ? 64 : 82)
                    .position(
                        x: horizontalInset
                            + (geometry.size.width - horizontalInset * 2) * anchor.x
                            + offset.width,
                        y: verticalInset
                            + (geometry.size.height - verticalInset * 2) * anchor.y
                            + offset.height
                    )
                    .gesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { value in dragOffsets[light.id] = value.translation }
                            .onEnded { value in
                                let x = anchor.x + Double(
                                    value.translation.width
                                        / max(1, geometry.size.width - horizontalInset * 2)
                                )
                                let y = anchor.y + Double(
                                    value.translation.height
                                        / max(1, geometry.size.height - verticalInset * 2)
                                )
                                manager.setPlanAnchor(PlanAnchor(x: x, y: y), for: light.id, in: room.id)
                                dragOffsets[light.id] = nil
                            }
                    )
                    .accessibilityAction(named: "Move left") { move(light, index: index, dx: -0.08, dy: 0) }
                    .accessibilityAction(named: "Move right") { move(light, index: index, dx: 0.08, dy: 0) }
                    .accessibilityAction(named: "Move up") { move(light, index: index, dx: 0, dy: -0.08) }
                    .accessibilityAction(named: "Move down") { move(light, index: index, dx: 0, dy: 0.08) }
                }
            }
        }
        .frame(minHeight: 360)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(room.name) fixture canvas")
    }

    private var roomGrid: some View {
        GeometryReader { geometry in
            Path { path in
                var x: CGFloat = 32
                while x < geometry.size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                    x += 32
                }
                var y: CGFloat = 32
                while y < geometry.size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                    y += 32
                }
            }
            .stroke(Lumen.graphite.opacity(0.055), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private var roomDetails: some View {
        VStack {
            HStack {
                Text(room.name.uppercased())
                    .font(LumenType.instrumentLabel(size: 10))
                    .tracking(1.2)
                    .foregroundStyle(Lumen.graphite.opacity(0.48))
                Spacer()
            }
            Spacer()
            HStack {
                Capsule().fill(Lumen.graphite.opacity(0.22)).frame(width: 68, height: 8)
                Spacer()
                RoundedRectangle(cornerRadius: 2).fill(Lumen.graphite.opacity(0.16)).frame(width: 42, height: 28)
            }
        }
        .padding(18)
        .accessibilityHidden(true)
    }

    private func nodeWidth(for light: LightDevice, compact: Bool) -> CGFloat {
        if compact {
            switch manager.themeCapability(for: light) {
            case .segments, .matrix, .panels: return 68
            case .solid: return 64
            }
        }
        switch manager.themeCapability(for: light) {
        case .segments: return 126
        case .matrix, .panels: return 104
        case .solid: return 94
        }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) }
        else { selection.insert(id) }
    }

    private func canvasAnchor(for light: LightDevice, index: Int) -> PlanAnchor {
        if let stored = room.fixtureAnchors[light.id] { return stored }
        let defaults = PlanLayout.defaultAnchors(count: lights.count)
        return defaults.indices.contains(index) ? defaults[index] : PlanAnchor(x: 0.5, y: 0.5)
    }

    private func move(_ light: LightDevice, index: Int, dx: Double, dy: Double) {
        let anchor = canvasAnchor(for: light, index: index)
        manager.setPlanAnchor(PlanAnchor(x: anchor.x + dx, y: anchor.y + dy),
                              for: light.id, in: room.id)
    }
}

private struct FixtureCanvasNode: View {
    @ObservedObject var light: LightDevice
    let selected: Bool
    let status: RoomCanvasStatus
    let compact: Bool
    let condensed: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 5) {
                ZStack {
                    if light.isOn && !light.isStale {
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [light.color.opacity(0.55 * light.brightness), light.color.opacity(0)],
                                    center: .center,
                                    startRadius: 2,
                                    endRadius: 34
                                )
                            )
                            .frame(width: compact ? 54 : 74, height: condensed ? 44 : 64)
                    }
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Lumen.graphite)
                        .frame(width: compact ? 32 : 38, height: condensed ? 26 : 30)
                    Image(systemName: fixtureSymbol)
                        .font(.system(size: compact ? 12 : (condensed ? 13 : 14), weight: .semibold))
                        .foregroundStyle(light.isOn ? light.color : Lumen.canvas.opacity(0.66))
                    Image(systemName: status.symbol)
                        .font(.system(size: condensed ? 8 : 10, weight: .bold))
                        .foregroundStyle(status.color)
                        .padding(condensed ? 2 : 3)
                        .background(Lumen.floor, in: Circle())
                        .offset(x: compact ? 17 : 20, y: condensed ? -14 : -17)
                }
                Text(light.label)
                    .font(LumenType.body(size: compact ? 9 : 11, weight: .semibold))
                    .foregroundStyle(Lumen.graphite)
                    .lineLimit(compact ? 2 : 1)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.82)
            }
            .padding(.horizontal, compact ? 4 : 7)
            .padding(.vertical, condensed ? 2 : 5)
            .background(Lumen.floor.opacity(selected ? 0.98 : 0.78), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Lumen.ember : Lumen.graphite.opacity(0.18), lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .help(light.label)
        .accessibilityLabel(light.label)
        .accessibilityValue("\(selected ? "Selected, " : "")\(status.title), \(light.isOn ? "on" : "off"), \(Int(light.brightness * 100)) percent")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var fixtureSymbol: String {
        if light.isLIFXLuna { return "circle.grid.3x3.fill" }
        switch light.brand {
        case .nanoleaf: return "hexagon.fill"
        case .govee: return "lightswitch.on"
        case .lifx: return "lightbulb.fill"
        }
    }
}

private struct RoomSelectionInspector: View {
    @EnvironmentObject private var manager: LightManager
    let room: Room
    let targets: [LightDevice]
    let compose: () -> Void
    let edit: (String) -> Void
    @StateObject private var output: RoomOutputState
    @State private var renamingFixtureID: String?
    @State private var renamedFixtureName = ""

    init(room: Room, targets: [LightDevice], compose: @escaping () -> Void,
         edit: @escaping (String) -> Void) {
        self.room = room
        self.targets = targets
        self.compose = compose
        self.edit = edit
        _output = StateObject(wrappedValue: RoomOutputState(lights: targets))
    }

    private var ids: Set<String> { Set(targets.map(\.id)) }
    private var averageBrightness: Double { RoomOutputState.level(of: targets) }
    private var averageKelvin: Double { RoomOutputState.kelvin(of: targets) }
    private var brightnessValueLabel: String {
        let value = "\(Int(averageBrightness * 100))%"
        return RoomOutputState.hasMixedBrightness(targets) ? "Mixed · \(value) average" : value
    }
    private var kelvinValueLabel: String {
        let value = "\(Int(averageKelvin)) K"
        return RoomOutputState.hasMixedKelvin(targets) ? "Mixed · \(value) average" : value
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Selection")
                        .font(LumenType.instrumentLabel(size: 10))
                        .tracking(1.2)
                        .foregroundStyle(Lumen.meter)
                    Text(selectionTitle)
                        .font(LumenType.display(size: 23, weight: .bold))
                    RoomCanvasStatusBadge(
                        status: RoomCanvasStatus.resolve(targets, manager: manager),
                        compact: true
                    )
                }

                if targets.isEmpty {
                    Text("Select one or more fixtures on the canvas to control them.")
                        .font(LumenType.body(size: 13))
                        .foregroundStyle(Lumen.meter)
                } else {
                    HStack(spacing: 9) {
                        Button("On") { manager.setPower(deviceIDs: ids, on: true) }
                            .buttonStyle(.borderedProminent)
                            .tint(Lumen.ember)
                        Button("Off") { manager.setPower(deviceIDs: ids, on: false) }
                            .buttonStyle(.bordered)
                    }

                    inspectorSlider(
                        title: "Brightness",
                        value: Binding(
                            get: { averageBrightness },
                            set: { manager.setBrightness(deviceIDs: ids, value: $0) }
                        ),
                        range: 0.01...1,
                        valueLabel: brightnessValueLabel
                    )

                    inspectorSlider(
                        title: "White point",
                        value: Binding(
                            get: { averageKelvin },
                            set: { manager.setKelvin(deviceIDs: ids, kelvin: Int($0)) }
                        ),
                        range: 2500...9000,
                        step: 100,
                        valueLabel: kelvinValueLabel
                    )

                    ColorPicker("Output colour", selection: Binding(
                        get: { targets.first?.color ?? .white },
                        set: { manager.setColor(deviceIDs: ids, color: $0) }
                    ), supportsOpacity: false)
                    .font(LumenType.body(size: 13, weight: .semibold))

                    if manager.externallyChangedDeviceIDs.isDisjoint(with: ids) == false {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("A fixture changed outside LumenDesk. The canvas now shows what the room reported.",
                                  systemImage: RoomCanvasStatus.changedElsewhere.symbol)
                                .font(LumenType.body(size: 12, weight: .semibold))
                            Button("Use this as current") {
                                manager.acknowledgeExternalChange(deviceIDs: ids)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(12)
                        .background(Lumen.graphite.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    }

                    capabilityDetail

                    Button(action: compose) {
                        Label("Compose a Look", systemImage: "paintpalette.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Lumen.ember)
                }
            }
            .padding(18)
        }
        .background(Lumen.floor.opacity(0.66))
        .alert("Rename fixture", isPresented: Binding(
            get: { renamingFixtureID != nil },
            set: { if !$0 { renamingFixtureID = nil } }
        )) {
            TextField("Fixture name", text: $renamedFixtureName)
            Button("Cancel", role: .cancel) { renamingFixtureID = nil }
            Button("Save") {
                if let renamingFixtureID {
                    manager.setCustomName(renamingFixtureID, name: renamedFixtureName)
                }
                renamingFixtureID = nil
            }
        } message: {
            Text("Leave the field empty to return to the name reported by the fixture.")
        }
    }

    private var selectionTitle: String {
        switch targets.count {
        case 0: return "Nothing selected"
        case 1: return targets[0].label
        default: return "\(targets.count) fixtures"
        }
    }

    private func inspectorSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double? = nil,
        valueLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(LumenType.body(size: 13, weight: .semibold))
                Spacer()
                Text(valueLabel).font(LumenType.readout(size: 12))
            }
            if let step {
                Slider(value: value, in: range, step: step)
            } else {
                Slider(value: value, in: range)
            }
        }
    }

    @ViewBuilder
    private var capabilityDetail: some View {
        if targets.count == 1, let device = targets.first {
            VStack(alignment: .leading, spacing: 8) {
                Text("Fixture capability")
                    .font(LumenType.instrumentLabel(size: 10))
                    .tracking(1)
                    .foregroundStyle(Lumen.meter)
                Text(capabilityName(device))
                    .font(LumenType.body(size: 13, weight: .semibold))
                Text(capabilitySummary(device))
                    .font(LumenType.body(size: 12))
                    .foregroundStyle(Lumen.meter)
                HStack(spacing: 8) {
                    Button("Rename fixture") {
                        renamedFixtureName = device.label
                        renamingFixtureID = device.id
                    }
                    .buttonStyle(.bordered)
                    if hasSpatialEditor(device) {
                        Button("Edit \(capabilityObject(device))") { edit(device.id) }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding(12)
            .background(Lumen.canvas.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func capabilityName(_ device: LightDevice) -> String {
        switch manager.themeCapability(for: device) {
        case .solid: return "Single colour · \(device.brand.displayName)"
        case .segments(let count, let gradient, _):
            return "\(count) segments · \(gradient ? "gradient" : "discrete")"
        case .matrix(_, let width, let height): return "\(width) × \(height) matrix"
        case .panels(let count): return "\(count) panels"
        }
    }

    private func capabilitySummary(_ device: LightDevice) -> String {
        switch manager.themeCapability(for: device) {
        case .solid: return "Holds one point from a room palette."
        case .segments(_, _, let limit):
            if let limit { return "Carries spatial colour with up to \(limit) active zones." }
            return "Carries the room palette along its length."
        case .matrix: return "Carries the room palette across addressable zones."
        case .panels: return "Carries the room palette across the wall layout."
        }
    }

    private func hasSpatialEditor(_ device: LightDevice) -> Bool {
        if device.brand == .nanoleaf || device.isLIFXLuna { return true }
        return manager.segmentStudioProfile(for: device) != nil
    }

    private func capabilityObject(_ device: LightDevice) -> String {
        if device.brand == .nanoleaf { return "panels" }
        if device.isLIFXLuna { return "matrix" }
        return "segments"
    }
}

// MARK: - Looks

private struct RoomLookTemplate: Identifiable {
    let id: String
    let name: String
    let themeID: String
    let symbol: String

    static let everyday: [RoomLookTemplate] = [
        .init(id: "evening", name: "Evening", themeID: "wind-down", symbol: "sunset.fill"),
        .init(id: "reading", name: "Reading", themeID: "reading-nook", symbol: "book.closed.fill"),
        .init(id: "movie", name: "Movie", themeID: "moon-garden", symbol: "film.fill"),
        .init(id: "bright", name: "Bright", themeID: "kitchen-noon", symbol: "sun.max.fill")
    ]
}

private struct LookShelf: View {
    @EnvironmentObject private var manager: LightManager
    let room: Room
    let compose: () -> Void
    @State private var namingCurrent = false
    @State private var currentName = ""

    private var ids: Set<String> { Set(room.lightIDs) }
    private var roomLooks: [LightingScene] {
        manager.scenes.filter { !Set($0.snapshots.keys).isDisjoint(with: ids) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Looks")
                    .font(LumenType.display(size: 18, weight: .bold))
                Text("Immediate room compositions")
                    .font(LumenType.body(size: 11))
                    .foregroundStyle(Lumen.meter)
                Spacer()
                Button(action: compose) {
                    Label("Compose", systemImage: "paintpalette")
                }
                .buttonStyle(.bordered)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(RoomLookTemplate.everyday) { template in
                        Button {
                            guard let theme = LightingCatalog.theme(withID: template.themeID) else { return }
                            manager.applyTheme(theme, deviceIDs: ids, in: .room(room.id))
                        } label: {
                            Label(template.name, systemImage: template.symbol)
                        }
                        .buttonStyle(RoomLookButtonStyle())
                    }

                    ForEach(roomLooks) { look in
                        Button {
                            manager.applyLook(look, deviceIDs: ids)
                        } label: {
                            HStack(spacing: 8) {
                                LookMiniPalette(look: look)
                                Text(look.name).lineLimit(1)
                            }
                        }
                        .buttonStyle(RoomLookButtonStyle())
                        .contextMenu {
                            Button("Delete Look", role: .destructive) {
                                manager.deleteScene(look.id)
                            }
                        }
                    }

                    Button {
                        currentName = suggestedName
                        namingCurrent = true
                    } label: {
                        Label("Save current", systemImage: "plus")
                    }
                    .buttonStyle(RoomLookButtonStyle(emphasized: true))
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Lumen.deck)
        .overlay(alignment: .top) { Rectangle().fill(Lumen.rule).frame(height: 1) }
        .alert("Save current as a Look", isPresented: $namingCurrent) {
            TextField("Look name", text: $currentName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                _ = manager.captureLook(name: currentName, deviceIDs: ids)
            }
            .disabled(currentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Captures the power, colour, brightness, and supported spatial output in \(room.name).")
        }
    }

    private var suggestedName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE h:mm a"
        return formatter.string(from: Date())
    }
}

private struct RoomLookButtonStyle: ButtonStyle {
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LumenType.body(size: 12, weight: .semibold))
            .foregroundStyle(emphasized ? Lumen.canvas : Lumen.graphite)
            .padding(.horizontal, 13)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(emphasized
                          ? Lumen.ember.opacity(configuration.isPressed ? 0.76 : 1)
                          : Lumen.floor.opacity(configuration.isPressed ? 0.7 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(emphasized ? Color.clear : Lumen.rule, lineWidth: 1)
            )
    }
}

private struct LookMiniPalette: View {
    let look: LightingScene

    private var snapshots: [DeviceSnapshot] {
        Array(look.snapshots.values).prefix(4).map { $0 }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(snapshots.indices, id: \.self) { index in
                let snapshot = snapshots[index]
                Circle()
                    .fill(snapshot.isOn
                          ? Color(hue: snapshot.hue, saturation: snapshot.saturation,
                                  brightness: max(0.08, snapshot.brightness))
                          : Lumen.graphite.opacity(0.18))
                    .frame(width: 10, height: 10)
            }
        }
        .accessibilityHidden(true)
    }
}

private enum LookBrush: String, CaseIterable, Identifiable {
    case spatialWash = "Spatial wash"
    case gradient = "Gradient"
    case exactFixture = "Exact fixture"
    var id: String { rawValue }

    var distribution: ThemeDistribution {
        switch self {
        case .spatialWash: return .wash
        case .gradient: return .gradient
        case .exactFixture: return .alternating
        }
    }

    var summary: String {
        switch self {
        case .spatialWash: return "One key colour fills the room; spatial fixtures hold a quiet secondary tone."
        case .gradient: return "The palette travels through fixture order and across supported surfaces."
        case .exactFixture: return "Choose the exact palette colour each selected fixture should hold."
        }
    }
}

private enum LookComposerScope: String, CaseIterable, Identifiable {
    case room = "Whole room"
    case selection = "Selected fixtures"
    var id: String { rawValue }
}

private struct ComposerPalette: Identifiable {
    let id: String
    let name: String
    let theme: LightingTheme

    static let choices: [ComposerPalette] = {
        var values: [ComposerPalette] = []
        values.append(ComposerPalette(
            id: "ember-moss",
            name: "Ember & Moss",
            theme: LightingTheme(
                id: "direction-a-ember-moss",
                name: "Ember & Moss",
                summary: "Warm ember settles into moss and verdigris across the room.",
                category: .nature,
                icon: "leaf.fill",
                colors: [0xEF5F4F, 0xF2A65A, 0x66704A, 0x35A982].map(CatalogColor.init),
                brightness: 0.62,
                distribution: .gradient
            )
        ))
        for id in ["reading-nook", "aurora", "linen-dusk", "tokyo-rain", "kitchen-noon"] {
            if let theme = LightingCatalog.theme(withID: id) {
                values.append(ComposerPalette(id: id, name: theme.name, theme: theme))
            }
        }
        return values
    }()
}

private struct LookComposerView: View {
    @EnvironmentObject private var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    let room: Room
    let initialSelection: Set<String>
    @State private var paletteID = ComposerPalette.choices.first?.id ?? "ember-moss"
    @State private var brush: LookBrush = .gradient
    @State private var scope: LookComposerScope
    @State private var lookName = "Ember & Moss"
    @State private var transitionSeconds = 1.8
    @State private var exactAssignments: [String: Int] = [:]

    init(room: Room, initialSelection: Set<String>) {
        self.room = room
        self.initialSelection = initialSelection
        _scope = State(initialValue: initialSelection.isEmpty ? .room : .selection)
    }

    private var currentRoom: Room { manager.rooms.first(where: { $0.id == room.id }) ?? room }
    private var roomIDs: Set<String> { Set(currentRoom.lightIDs) }
    private var targetIDs: Set<String> {
        if scope == .selection {
            return RoomWorkspaceSelection.targets(
                selected: initialSelection,
                available: currentRoom.lightIDs
            )
        }
        return roomIDs
    }
    private var selectedPalette: ComposerPalette {
        ComposerPalette.choices.first(where: { $0.id == paletteID }) ?? ComposerPalette.choices[0]
    }
    private var orderedTargetLights: [LightDevice] {
        manager.devices(in: currentRoom).filter { targetIDs.contains($0.id) }
    }
    private var paletteAssignments: [String: Int]? {
        guard brush == .exactFixture else { return nil }
        return Dictionary(uniqueKeysWithValues: orderedTargetLights.map { light in
            (light.id, exactAssignment(for: light))
        })
    }
    private var authoredTheme: LightingTheme {
        let source = selectedPalette.theme
        return LightingTheme(
            id: "\(source.id)-\(brush.id)",
            name: source.name,
            summary: source.summary,
            category: source.category,
            icon: source.icon,
            colors: source.colors,
            brightness: source.brightness,
            distribution: brush.distribution
        )
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    if geometry.size.width >= 850 {
                        HStack(alignment: .top, spacing: 24) {
                            previewColumn.frame(maxWidth: .infinity)
                            inspector.frame(width: 330)
                        }
                        .padding(24)
                    } else {
                        VStack(alignment: .leading, spacing: 22) {
                            previewColumn
                            inspector
                        }
                        .padding(20)
                    }
                }
            }
            .background(Lumen.canvas)
            .navigationTitle("Look Composer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        manager.stopSceneRehearsal(restore: true)
                        dismiss()
                    }
                }
            }
        }
        .font(LumenType.body())
        .foregroundStyle(Lumen.graphite)
        .sheetFrame(minWidth: 680, idealWidth: 1040, minHeight: 620, idealHeight: 780)
        .onAppear { synchronizeExactAssignments() }
        .onChange(of: paletteID) { _ in
            lookName = selectedPalette.name
            synchronizeExactAssignments()
        }
        .onChange(of: scope) { _ in synchronizeExactAssignments() }
        .onChange(of: brush) { _ in synchronizeExactAssignments() }
    }

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("PALETTE")
                    .font(LumenType.instrumentLabel(size: 10))
                    .tracking(1.2)
                    .foregroundStyle(Lumen.meter)
                Text(selectedPalette.name)
                    .font(LumenType.display(size: 30, weight: .bold))
                Text(selectedPalette.theme.summary)
                    .font(LumenType.body(size: 13))
                    .foregroundStyle(Lumen.meter)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(ComposerPalette.choices) { palette in
                        Button {
                            paletteID = palette.id
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 0) {
                                    ForEach(palette.theme.colors.indices, id: \.self) { index in
                                        Rectangle().fill(palette.theme.colors[index].color)
                                    }
                                }
                                .frame(width: 124, height: 34)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                Text(palette.name)
                                    .font(LumenType.body(size: 11, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .padding(9)
                            .background(Lumen.floor, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(paletteID == palette.id ? Lumen.ember : Lumen.rule,
                                            lineWidth: paletteID == palette.id ? 2 : 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("Brush")
                    .font(LumenType.body(size: 13, weight: .semibold))
                Picker("Brush", selection: $brush) {
                    ForEach(LookBrush.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(brush.summary)
                    .font(LumenType.body(size: 12))
                    .foregroundStyle(Lumen.meter)
            }

            exactAssignmentEditor

            ComposerRoomPreview(
                room: currentRoom,
                lights: manager.devices(in: currentRoom),
                targetIDs: targetIDs,
                theme: authoredTheme,
                paletteAssignments: paletteAssignments
            )
            .frame(minHeight: 300)
        }
    }

    @ViewBuilder
    private var exactAssignmentEditor: some View {
        if brush == .exactFixture {
            VStack(alignment: .leading, spacing: 10) {
                Text("Fixture assignments")
                    .font(LumenType.body(size: 13, weight: .semibold))
                Text("Each fixture keeps the chosen swatch. Addressable strips, matrices, and panels repeat it across their surface.")
                    .font(LumenType.body(size: 11))
                    .foregroundStyle(Lumen.meter)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(orderedTargetLights) { light in
                    HStack(spacing: 10) {
                        Text(light.label)
                            .font(LumenType.body(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 7) {
                            ForEach(selectedPalette.theme.colors.indices, id: \.self) { index in
                                Button {
                                    exactAssignments[light.id] = index
                                } label: {
                                    Circle()
                                        .fill(selectedPalette.theme.colors[index].color)
                                        .frame(width: 22, height: 22)
                                        .padding(3)
                                        .overlay(
                                            Circle()
                                                .stroke(
                                                    exactAssignment(for: light) == index
                                                        ? Lumen.graphite : Color.clear,
                                                    lineWidth: 2
                                                )
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Assign palette colour \(index + 1) to \(light.label)")
                                .accessibilityAddTraits(
                                    exactAssignment(for: light) == index ? .isSelected : []
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Lumen.floor, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Lumen.rule, lineWidth: 1))
                }
            }
            .padding(14)
            .background(Lumen.deck.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Look details")
                .font(LumenType.display(size: 22, weight: .bold))
            VStack(alignment: .leading, spacing: 7) {
                Text("Look name").font(LumenType.instrumentLabel(size: 10)).foregroundStyle(Lumen.meter)
                TextField("Look name", text: $lookName).textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Scope").font(LumenType.instrumentLabel(size: 10)).foregroundStyle(Lumen.meter)
                Picker("Scope", selection: $scope) {
                    ForEach(LookComposerScope.allCases) { entry in
                        Text(entry.rawValue).tag(entry)
                    }
                }
                .pickerStyle(.segmented)
                Text("\(targetIDs.count) of \(roomIDs.count) fixtures")
                    .font(LumenType.readout(size: 11))
                    .foregroundStyle(Lumen.meter)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Room level").font(LumenType.body(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(Int(authoredTheme.brightness * 100))%")
                        .font(LumenType.readout(size: 12))
                }
                ProgressView(value: authoredTheme.brightness)
                    .tint(Lumen.ember)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Adaptation")
                    .font(LumenType.instrumentLabel(size: 10))
                    .foregroundStyle(Lumen.meter)
                Text(manager.lookAdaptationSummary(
                    authoredTheme,
                    deviceIDs: targetIDs,
                    in: .room(currentRoom.id),
                    paletteAssignments: paletteAssignments
                )
                     ?? "Every selected fixture can carry this composition directly.")
                    .font(LumenType.body(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Lumen.verdigris.opacity(0.11), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Transition").font(LumenType.body(size: 13, weight: .semibold))
                    Spacer()
                    Text(String(format: "%.1f seconds", transitionSeconds))
                        .font(LumenType.readout(size: 12))
                }
                Slider(value: $transitionSeconds, in: 0.2...5, step: 0.1)
                Text("Ease · device-native where supported")
                    .font(LumenType.body(size: 11))
                    .foregroundStyle(Lumen.meter)
            }

            HStack(spacing: 9) {
                Button("Restore before preview") {
                    manager.stopSceneRehearsal(restore: true)
                }
                .buttonStyle(.bordered)
                .disabled(manager.rehearsalSceneID == nil)
                Button("Preview") {
                    manager.startLookPreview(
                        authoredTheme,
                        deviceIDs: targetIDs,
                        in: .room(currentRoom.id),
                        paletteAssignments: paletteAssignments,
                        transitionDuration: transitionSeconds
                    )
                }
                .buttonStyle(.bordered)
            }

            Button(action: save) {
                Label("Save Look", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Lumen.ember)
            .disabled(lookName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || targetIDs.isEmpty)

            RoomCanvasStatusBadge(status: manager.rehearsalSceneID == nil ? .confirmed : .pending)
        }
        .padding(18)
        .background(Lumen.floor, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Lumen.rule, lineWidth: 1))
    }

    private func save() {
        // Re-plan even when a preview is already active: the palette, brush,
        // scope, or an Exact assignment may have changed since that preview.
        manager.startLookPreview(
            authoredTheme,
            deviceIDs: targetIDs,
            in: .room(currentRoom.id),
            paletteAssignments: paletteAssignments,
            transitionDuration: transitionSeconds
        )
        manager.stopSceneRehearsal(restore: false)
        _ = manager.captureLook(name: lookName, deviceIDs: targetIDs)
        dismiss()
    }

    private func exactAssignment(for light: LightDevice) -> Int {
        let count = selectedPalette.theme.colors.count
        guard count > 0 else { return 0 }
        let fallback = orderedTargetLights.firstIndex(where: { $0.id == light.id }) ?? 0
        return min(count - 1, max(0, exactAssignments[light.id] ?? fallback % count))
    }

    private func synchronizeExactAssignments() {
        let count = selectedPalette.theme.colors.count
        guard count > 0 else {
            exactAssignments = [:]
            return
        }
        var updated: [String: Int] = [:]
        for (index, light) in orderedTargetLights.enumerated() {
            let existing = exactAssignments[light.id] ?? index % count
            updated[light.id] = min(count - 1, max(0, existing))
        }
        exactAssignments = updated
    }
}

private struct ComposerRoomPreview: View {
    @EnvironmentObject private var manager: LightManager
    let room: Room
    let lights: [LightDevice]
    let targetIDs: Set<String>
    let theme: LightingTheme
    let paletteAssignments: [String: Int]?

    private var plans: [String: ThemeFixturePlan] {
        let fixtures = lights.filter { targetIDs.contains($0.id) }.map {
            ThemeFixture(id: $0.id, capability: manager.themeCapability(for: $0), kelvin: $0.kelvin)
        }
        let plan: ThemePlan
        if let paletteAssignments {
            plan = ThemePlanner.planExact(
                theme,
                fixtures: fixtures,
                paletteIndices: paletteAssignments
            )
        } else {
            plan = ThemePlanner.plan(theme, fixtures: fixtures)
        }
        return Dictionary(uniqueKeysWithValues: plan.fixtures.map { ($0.fixtureID, $0) })
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(Lumen.floor)
                RoundedRectangle(cornerRadius: 18).stroke(Lumen.graphite, lineWidth: 3)
                ForEach(lights) { light in
                    let anchor = manager.planAnchor(for: light.id, in: room)
                    let plan = plans[light.id]
                    VStack(spacing: 4) {
                        Circle()
                            .fill(plan?.tone.emittedColor(scaledBy: plan?.brightness ?? 0) ?? Lumen.graphite.opacity(0.12))
                            .frame(width: 34, height: 34)
                            .shadow(color: plan?.tone.displayColor.opacity(0.45) ?? .clear, radius: 14)
                        Text(light.label)
                            .font(LumenType.body(size: 10, weight: .semibold))
                            .lineLimit(1)
                    }
                    .opacity(targetIDs.contains(light.id) ? 1 : 0.32)
                    .position(
                        x: 45 + (geometry.size.width - 90) * anchor.x,
                        y: 35 + (geometry.size.height - 70) * anchor.y
                    )
                }
            }
        }
        .accessibilityLabel("Preview of \(theme.name) in \(room.name)")
    }
}

// MARK: - Add or repair

private enum AddRepairStep: Int, CaseIterable, Identifiable {
    case prepare
    case find
    case place
    case verify
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .prepare: return "Prepare"
        case .find: return "Find"
        case .place: return "Place"
        case .verify: return "Verify"
        }
    }
}

private struct AddOrRepairRoomView: View {
    @EnvironmentObject private var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedRoomID: UUID?
    let onFinish: () -> Void
    @State private var step: AddRepairStep = .prepare
    @State private var selectedIDs: Set<String> = []
    @State private var targetRoomID: UUID?
    @State private var newRoomName = ""
    @State private var showingManualPairing = false
    @State private var fixtureNameDrafts: [String: String] = [:]

    private var targetRoom: Room? {
        manager.rooms.first { $0.id == targetRoomID }
    }

    private var placementLights: [LightDevice] {
        guard let targetRoom else { return [] }
        let placed = manager.devices(in: targetRoom)
        let placedIDs = Set(placed.map(\.id))
        return placed + manager.devices.filter {
            selectedIDs.contains($0.id) && !placedIDs.contains($0.id)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                stepRail
                Divider().overlay(Lumen.rule)
                ScrollView {
                    Group {
                        switch step {
                        case .prepare: prepareStep
                        case .find: findStep
                        case .place: placeStep
                        case .verify: verifyStep
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                Divider().overlay(Lumen.rule)
                footer
            }
            .background(Lumen.canvas)
            .navigationTitle("Add or repair room")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .font(LumenType.body())
        .foregroundStyle(Lumen.graphite)
        .sheetFrame(minWidth: 680, idealWidth: 920, minHeight: 590, idealHeight: 720)
        .sheet(isPresented: $showingManualPairing) {
            NanoleafPairingView().environmentObject(manager)
        }
        .onDisappear { manager.endSustainedIdentify() }
    }

    private var stepRail: some View {
        HStack(spacing: 0) {
            ForEach(AddRepairStep.allCases) { item in
                HStack(spacing: 7) {
                    ZStack {
                        Circle()
                            .fill(item.rawValue <= step.rawValue ? Lumen.ember : Lumen.graphite.opacity(0.11))
                            .frame(width: 24, height: 24)
                        if item.rawValue < step.rawValue {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Lumen.canvas)
                        } else {
                            Text("\(item.rawValue + 1)")
                                .font(LumenType.readout(size: 10, weight: .semibold))
                                .foregroundStyle(item == step ? Lumen.canvas : Lumen.graphite)
                        }
                    }
                    Text(item.title)
                        .font(LumenType.body(size: 12, weight: item == step ? .semibold : .regular))
                    if item != .verify {
                        Rectangle().fill(Lumen.rule).frame(height: 1)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Lumen.floor)
    }

    private var prepareStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeading(
                "Make the fixtures visible",
                "Turn the lights on at the wall and keep this device on the same local network. LumenDesk talks directly to each fixture; there is no bridge service to configure."
            )
            HStack(alignment: .top, spacing: 14) {
                instructionCard(number: "1", title: "Power", text: "Switch on every fixture you want to place.")
                instructionCard(number: "2", title: "Network", text: "Join the Wi‑Fi network the fixtures use.")
                instructionCard(number: "3", title: "Permission", text: "Allow Local Network access when iOS asks.")
            }
            VStack(alignment: .leading, spacing: 8) {
                Label("iPhone and iPad discovery limit", systemImage: "iphone.and.arrow.forward")
                    .font(LumenType.body(size: 13, weight: .semibold))
                Text("iOS can withhold multicast discovery until Local Network permission is granted, and some managed networks block broadcast replies entirely. A missing result does not prove the fixture is offline. Rescan, pair a Nanoleaf by address, or use the vendor app to repair Wi‑Fi before trying again.")
                    .font(LumenType.body(size: 12))
                    .foregroundStyle(Lumen.meter)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(Lumen.warn.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
        }
    }

    private var findStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeading(
                "Find and identify",
                "Select the fixtures that belong together. Identify flashes one fixture and restores its exact opening state."
            )
            HStack {
                Button {
                    manager.scan()
                } label: {
                    Label(manager.isScanning ? manager.scanPhase : "Scan again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(Lumen.ember)
                .disabled(manager.isScanning)
                Button("Pair Nanoleaf by address") { showingManualPairing = true }
                    .buttonStyle(.bordered)
                Spacer()
                Text("\(selectedIDs.count) selected")
                    .font(LumenType.readout(size: 12))
                    .foregroundStyle(Lumen.meter)
            }

            if manager.devices.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 30, weight: .light))
                    Text("No fixtures have answered yet")
                        .font(LumenType.display(size: 20, weight: .bold))
                    Text("Keep the scan open for five seconds. If the network blocks discovery, repair the fixture in its vendor app and rescan here.")
                        .font(LumenType.body(size: 12))
                        .foregroundStyle(Lumen.meter)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(32)
                .background(Lumen.floor, in: RoundedRectangle(cornerRadius: 12))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(manager.devices) { device in
                        discoveryCard(device)
                    }
                }
            }
        }
    }

    private func discoveryCard(_ device: LightDevice) -> some View {
        let selected = selectedIDs.contains(device.id)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                if selected { selectedIDs.remove(device.id) }
                else { selectedIDs.insert(device.id) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(selected ? Lumen.ember : Lumen.graphite)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.label)
                            .font(LumenType.body(size: 13, weight: .semibold))
                        Text("\(device.brand.displayName) · \(device.address)")
                            .font(LumenType.body(size: 10))
                            .foregroundStyle(Lumen.meter)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: device.isStale ? "wifi.slash" : "wifi")
                        .foregroundStyle(device.isStale ? Lumen.fail : Lumen.verdigris)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button("Identify") { manager.identify(device) }
                .buttonStyle(.bordered)
                .disabled(device.isStale)

            HStack(spacing: 8) {
                TextField("Fixture name", text: fixtureNameBinding(device))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveFixtureName(device) }
                Button("Save name") { saveFixtureName(device) }
                    .buttonStyle(.bordered)
                    .disabled(!fixtureNameHasChanges(device))
            }
            if let warning = manager.duplicateNameMessage(
                fixtureNameDrafts[device.id] ?? device.label,
                excludingDeviceID: device.id
            ) {
                Text(warning)
                    .font(LumenType.body(size: 10))
                    .foregroundStyle(Lumen.warn)
            }
        }
        .padding(13)
        .background(Lumen.floor, in: RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(selected ? Lumen.ember : Lumen.rule, lineWidth: selected ? 2 : 1)
        )
    }

    private var placeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeading(
                "Place on the canvas",
                "Choose a room, then drag the selected fixtures toward where they sit. Placement is a memory aid, not a calibrated floor plan."
            )

            HStack(spacing: 10) {
                Picker("Room", selection: $targetRoomID) {
                    Text("Choose a room").tag(Optional<UUID>.none)
                    ForEach(manager.rooms) { room in
                        Text(room.name).tag(Optional(room.id))
                    }
                }
                .frame(maxWidth: 260)
                TextField("New room name", text: $newRoomName)
                    .textFieldStyle(.roundedBorder)
                Button("Create") { createRoom() }
                    .buttonStyle(.bordered)
                    .disabled(newRoomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let targetRoom {
                DirectionARoomField(
                    room: targetRoom,
                    lights: placementLights,
                    selection: $selectedIDs
                )
                .frame(height: 360)
            } else {
                Text("Choose or create the room that contains these fixtures.")
                    .font(LumenType.body(size: 13))
                    .foregroundStyle(Lumen.meter)
                    .frame(maxWidth: .infinity, minHeight: 260)
                    .background(Lumen.floor, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var verifyStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeading(
                "Verify the room",
                "The room is ready when every fixture answers and appears where you expect it. Failures stay beside the fixture so repair remains local."
            )
            if let targetRoom {
                ForEach(manager.devices(in: targetRoom)) { device in
                    HStack(spacing: 12) {
                        Image(systemName: RoomCanvasStatus.resolve([device], manager: manager).symbol)
                            .foregroundStyle(RoomCanvasStatus.resolve([device], manager: manager).color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.label).font(LumenType.body(size: 13, weight: .semibold))
                            Text(device.isStale ? "No reply · check power and Wi‑Fi" : "Responded at \(device.address)")
                                .font(LumenType.body(size: 11))
                                .foregroundStyle(Lumen.meter)
                        }
                        Spacer()
                        if device.isStale {
                            Button("Retry") { manager.scan() }.buttonStyle(.bordered)
                        } else {
                            Button("Identify") { manager.identify(device) }.buttonStyle(.bordered)
                        }
                    }
                    .padding(13)
                    .background(Lumen.floor, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if step != .prepare {
                Button("Back") {
                    manager.endSustainedIdentify()
                    step = AddRepairStep(rawValue: step.rawValue - 1) ?? .prepare
                }
                .buttonStyle(.bordered)
            }
            Spacer()
            Text(footerNote)
                .font(LumenType.body(size: 11))
                .foregroundStyle(Lumen.meter)
            Button(step == .verify ? "Open room" : "Continue") { advance() }
                .buttonStyle(.borderedProminent)
                .tint(Lumen.ember)
                .disabled(!canAdvance)
        }
        .padding(16)
        .background(Lumen.floor)
    }

    private var canAdvance: Bool {
        switch step {
        case .prepare: return true
        case .find: return !selectedIDs.isEmpty
        case .place: return targetRoomID != nil
        case .verify: return true
        }
    }

    private var footerNote: String {
        switch step {
        case .prepare: return "Discovery begins in the foreground"
        case .find: return "\(selectedIDs.count) fixture\(selectedIDs.count == 1 ? "" : "s") to place"
        case .place: return targetRoom?.name ?? "Choose a room"
        case .verify: return "Best-effort confirmation from physical fixtures"
        }
    }

    private func advance() {
        switch step {
        case .prepare:
            manager.scan()
            step = .find
        case .find:
            manager.endSustainedIdentify()
            if targetRoomID == nil { targetRoomID = selectedRoomID ?? manager.rooms.first?.id }
            step = .place
        case .place:
            guard let targetRoomID else { return }
            if let targetRoom {
                let defaults = PlanLayout.defaultAnchors(count: placementLights.count)
                for (index, device) in placementLights.enumerated() {
                    guard targetRoom.fixtureAnchors[device.id] == nil,
                          defaults.indices.contains(index) else { continue }
                    manager.setPlanAnchor(defaults[index], for: device.id, in: targetRoomID)
                }
            }
            manager.assign(lightIDs: selectedIDs, toRoom: targetRoomID)
            manager.ensurePlanLayout()
            selectedRoomID = targetRoomID
            step = .verify
        case .verify:
            onFinish()
            dismiss()
        }
    }

    private func createRoom() {
        guard let id = manager.addRoom(named: newRoomName) else { return }
        targetRoomID = id
        newRoomName = ""
    }

    private func fixtureNameBinding(_ device: LightDevice) -> Binding<String> {
        Binding(
            get: { fixtureNameDrafts[device.id] ?? device.label },
            set: { fixtureNameDrafts[device.id] = $0 }
        )
    }

    private func fixtureNameHasChanges(_ device: LightDevice) -> Bool {
        guard let draft = fixtureNameDrafts[device.id] else { return false }
        return draft.trimmingCharacters(in: .whitespacesAndNewlines) != device.label
    }

    private func saveFixtureName(_ device: LightDevice) {
        let draft = fixtureNameDrafts[device.id] ?? device.label
        manager.setCustomName(device.id, name: draft)
        fixtureNameDrafts[device.id] = device.label
    }

    private func stepHeading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(LumenType.display(size: 28, weight: .bold))
            Text(subtitle)
                .font(LumenType.body(size: 13))
                .foregroundStyle(Lumen.meter)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 680, alignment: .leading)
        }
    }

    private func instructionCard(number: String, title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(number)
                .font(LumenType.readout(size: 11, weight: .semibold))
                .foregroundStyle(Lumen.canvas)
                .frame(width: 25, height: 25)
                .background(Lumen.graphite, in: Circle())
            Text(title).font(LumenType.display(size: 18, weight: .bold))
            Text(text)
                .font(LumenType.body(size: 12))
                .foregroundStyle(Lumen.meter)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Lumen.floor, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Lumen.rule, lineWidth: 1))
    }
}

// MARK: - Live music response

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
    var id: String { rawValue }
}

private struct RoomLiveView: View {
    @EnvironmentObject private var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let room: Room
    @State private var response: RoomLiveResponse = .calm
    @State private var input: RoomLiveInput = .platform
    @State private var audioFile: URL?
    @State private var choosingFile = false
    @State private var confirmingLocalAudio = false
    @AppStorage(AppPreferenceKey.audioPrivacyAcknowledged) private var audioAcknowledged = false

    private var scope: LightScope { .room(room.id) }
    private var isRunning: Bool { manager.activeEffects[scope] == "music-pulse" }

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
                        Text("Choose one input and one room response. Stop always restores the room to its opening state.")
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
                        } else {
                            Text(platformInputDetail)
                                .font(LumenType.body(size: 12))
                                .foregroundStyle(Lumen.meter)
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
                                            .stroke(response == item ? Lumen.ember : Lumen.rule,
                                                    lineWidth: response == item ? 2 : 1)
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(isRunning)
                            }
                        }
                        if isRunning {
                            Text("Stop and restore before changing the input or response.")
                                .font(LumenType.body(size: 11, weight: .semibold))
                                .foregroundStyle(Lumen.meter)
                        }
                    }

                    LiveInputStatus(controller: manager.musicModeController)

                    Button {
                        if isRunning {
                            stop()
                        } else if manager.isDemoMode || audioAcknowledged {
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

                    Text("Live is immediate and foreground-only. It does not create a cue stack, timeline, MIDI map, schedule, or unattended listener.")
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
        }
        .font(LumenType.body())
        .foregroundStyle(Lumen.graphite)
        .sheetFrame(minWidth: 600, idealWidth: 760, minHeight: 560, idealHeight: 700)
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

    private func inputTitle(_ input: RoomLiveInput) -> String {
        switch input {
        case .platform:
            #if os(macOS)
            return "System audio"
            #else
            return "Microphone"
            #endif
        case .file: return "Audio file"
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
        var configuration = MusicModeConfiguration.configuration(for: response.preset)
            .preservingRoomCalibration(from: manager.musicModeConfiguration)
        configuration.restorePreviousState = true
        configuration.photosensitivitySafeMode = true
        configuration.allowsFlashes = false
        configuration.flashIntensity = 0
        configuration.maximumFlashFrequency = 0
        configuration.followsPlaybackApps = false
        configuration.usesSyntheticDemoPattern = manager.isDemoMode
        manager.setMusicModeConfiguration(configuration)
        let capture: MusicCapturePreference
        if input == .file, let audioFile { capture = .file(audioFile) }
        else { capture = .platformDefault }
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
        HStack(spacing: 12) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.sourceStatus.displayName)
                    .font(LumenType.body(size: 13, weight: .semibold))
                Text(controller.inputHealth.displayName)
                    .font(LumenType.body(size: 11))
                    .foregroundStyle(Lumen.meter)
            }
            Spacer()
            if controller.sourceStatus.isActiveCapture {
                Text("LIVE")
                    .font(LumenType.instrumentLabel(size: 10))
                    .foregroundStyle(Lumen.ember)
            }
        }
        .padding(14)
        .background(statusColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(statusColor.opacity(0.35), lineWidth: 1))
    }

    private var statusSymbol: String {
        switch controller.sourceStatus {
        case .permissionDenied, .unavailable: return "exclamationmark.triangle.fill"
        case .idle: return "waveform"
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

// MARK: - Contextual capability editor

private struct ContextualFixtureEditor: View {
    @EnvironmentObject private var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var device: LightDevice

    var body: some View {
        NavigationStack {
            Group {
                if device.brand == .nanoleaf {
                    NanoleafShapesStudio(device: device, shapes: manager.shapes, presentation: .sheet)
                } else if device.isLIFXLuna {
                    LIFXLunaEditorView(device: device)
                } else if manager.segmentStudioProfile(for: device) != nil {
                    GoveeSegmentEditorView(device: device)
                } else {
                    BasicFixtureEditor(device: device)
                }
            }
            .navigationTitle(device.label)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .font(LumenType.body())
        .foregroundStyle(Lumen.graphite)
    }
}

private struct BasicFixtureEditor: View {
    @EnvironmentObject private var manager: LightManager
    @ObservedObject var device: LightDevice

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(device.isOn ? device.color : Lumen.rule)
                        .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.brand.displayName)
                            .font(LumenType.body(size: 13, weight: .semibold))
                        RoomCanvasStatusBadge(
                            status: RoomCanvasStatus.resolve([device], manager: manager),
                            compact: true
                        )
                    }
                    Spacer()
                    Toggle("Power", isOn: Binding(
                        get: { device.isOn },
                        set: { manager.setPower(device, on: $0) }
                    ))
                    .toggleStyle(.switch)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Brightness")
                        Spacer()
                        Text("\(Int(device.brightness * 100))%")
                            .font(LumenType.readout(size: 12))
                    }
                    Slider(value: Binding(
                        get: { device.brightness },
                        set: { manager.setBrightness(deviceIDs: [device.id], value: $0) }
                    ), in: 0.01...1)
                }

                ColorPicker("Output colour", selection: Binding(
                    get: { device.color },
                    set: { manager.setColor(device, color: $0) }
                ), supportsOpacity: false)

                HStack {
                    Button("Identify") { manager.identify(device) }
                    if device.isStale || manager.commandState(for: device.id).phase == .failed {
                        Button("Retry") { manager.retry(device) }
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(22)
        }
        .background(Lumen.canvas)
    }
}

// MARK: - Shared Room Canvas support

/// A room aggregate observes its fixtures directly because discovery and
/// command reconciliation publish through `LightDevice`, not through the
/// room collection on `LightManager`.
final class RoomOutputState: ObservableObject {
    private var observation: AnyCancellable?

    init(lights: [LightDevice]) {
        observation = Publishers.MergeMany(lights.map(\.objectWillChange)).sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    static func level(of lights: [LightDevice]) -> Double {
        lights.isEmpty ? 0 : lights.reduce(0) { $0 + $1.brightness } / Double(lights.count)
    }

    static func kelvin(of lights: [LightDevice]) -> Double {
        guard !lights.isEmpty else { return 3_500 }
        return Double(lights.reduce(0) { $0 + $1.kelvin }) / Double(lights.count)
    }

    static func hasMixedBrightness(_ lights: [LightDevice], tolerance: Double = 0.005) -> Bool {
        guard let first = lights.first?.brightness else { return false }
        return lights.dropFirst().contains { abs($0.brightness - first) > tolerance }
    }

    static func hasMixedKelvin(_ lights: [LightDevice], tolerance: Int = 50) -> Bool {
        guard let first = lights.first?.kelvin else { return false }
        return lights.dropFirst().contains { abs($0.kelvin - first) > tolerance }
    }
}

private struct RoomCanvasCommandToast: View {
    let message: String
    var undoAction: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Lumen.fail)
            Text(message)
                .font(LumenType.body(size: 12, weight: .semibold))
                .lineLimit(3)
            Spacer(minLength: 0)
            if let undoAction {
                Button("Undo", action: undoAction)
                    .buttonStyle(.bordered)
            }
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 440)
        .background(Lumen.floor, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Lumen.fail.opacity(0.45), lineWidth: 1))
        .shadow(color: Lumen.graphite.opacity(0.14), radius: 14, y: 6)
    }
}

struct RoomCanvasSettingsView: View {
    @EnvironmentObject private var manager: LightManager
    @AppStorage(AppPreferenceKey.quietInterface) private var quietInterface = false
    @AppStorage(AppPreferenceKey.confirmationPolicy) private var confirmationPolicy = ConfirmationPolicy.balanced.rawValue
    @AppStorage(AppPreferenceKey.audioPrivacyAcknowledged) private var audioAcknowledged = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("SETTINGS")
                        .font(LumenType.instrumentLabel(size: 10))
                        .tracking(1.4)
                        .foregroundStyle(Lumen.ember)
                    Text("Room Canvas")
                        .font(LumenType.display(size: 30, weight: .bold))
                    Text("A small set of preferences for immediate, local room control.")
                        .font(LumenType.body(size: 13))
                        .foregroundStyle(Lumen.meter)
                }

                settingsSection("Interaction", symbol: "hand.tap") {
                    Picker("Confirmation", selection: $confirmationPolicy) {
                        ForEach(ConfirmationPolicy.allCases) { policy in
                            Text(policy.title).tag(policy.rawValue)
                        }
                    }
                    Toggle("Quiet interface", isOn: $quietInterface)
                    Text("Quiet interface reduces decorative motion. System accessibility settings remain authoritative.")
                        .font(LumenType.body(size: 11))
                        .foregroundStyle(Lumen.meter)
                }

                settingsSection("Live privacy", symbol: "hand.raised") {
                    Toggle("I understand local audio analysis", isOn: $audioAcknowledged)
                    Text("Live analyzes audio on this device and does not retain recordings. macOS may request Screen & System Audio Recording access; iPhone and iPad may request microphone access.")
                        .font(LumenType.body(size: 11))
                        .foregroundStyle(Lumen.meter)
                    Button("Open Privacy Settings") {
                        PlatformOpener.openSettings(macPane: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                    }
                }

                settingsSection("Sample Room", symbol: "testtube.2") {
                    if manager.isDemoMode {
                        Label("No physical fixtures are being controlled", systemImage: "checkmark.shield")
                            .foregroundStyle(Lumen.verdigris)
                        HStack {
                            Button("Reset Sample Room") { manager.resetDemoMode() }
                            Button("Return to live rooms") { manager.exitDemoMode() }
                                .buttonStyle(.borderedProminent)
                                .tint(Lumen.ember)
                        }
                    } else {
                        Button("Open Sample Room") { manager.enterDemoMode() }
                            .buttonStyle(.borderedProminent)
                            .tint(Lumen.ember)
                        Text("The sample workspace is isolated from discovered fixtures and saved rooms.")
                            .font(LumenType.body(size: 11))
                            .foregroundStyle(Lumen.meter)
                    }
                }

            }
            .frame(maxWidth: 720)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Lumen.canvas)
        .foregroundStyle(Lumen.graphite)
        .font(LumenType.body())
        .navigationTitle("Settings")
    }

    private func settingsSection<Content: View>(_ title: String, symbol: String,
                                                @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(Lumen.ember)
                Text(title).font(LumenType.display(size: 19, weight: .bold))
                Rectangle().fill(Lumen.rule).frame(height: 1)
            }
            content()
        }
        .padding(17)
        .background(Lumen.floor, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Lumen.rule, lineWidth: 1))
    }
}
