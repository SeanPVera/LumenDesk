import SwiftUI
import Combine
import Foundation
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
    @Published var showingLooks = false
    /// The Look open in the composer for editing; nil composes a new one.
    @Published var editingLookID: UUID?
    /// The light whose page is open in the detail column, replacing the
    /// Room Stage until the person goes back.
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
        case .changedElsewhere: return Polar.changed
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
    @State private var handledInitialSetup: Bool = false

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
                    .navigationSplitViewColumnWidth(min: 184, ideal: 218, max: 280)
                    #endif
            } detail: {
                NavigationStack {
                    if let editorDevice {
                        LightPageView(
                            device: editorDevice,
                            navigate: { session.editorDeviceID = $0 },
                            close: { session.editorDeviceID = nil }
                        )
                        .id(editorDevice.id)
                    } else if let selectedRoom {
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
        .onReceive(NotificationCenter.default.publisher(for: .lumenCommand)) { notification in
            guard let command = LumenCommandBus.command(from: notification) else { return }
            handle(command)
        }
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
            session.editingLookID = nil
        }) {
            if let selectedRoom {
                LookComposerView(
                    room: selectedRoom,
                    initialSelection: session.selectedFixtureIDs,
                    editing: session.editingLookID.flatMap { id in manager.scenes.first { $0.id == id } }
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
            RoomCanvasSettingsView(showsDone: true)
                .sheetFrame(minWidth: 560, idealWidth: 640, minHeight: 460, idealHeight: 540)
                .environmentObject(manager)
        }
        .sheet(isPresented: $session.showingLooks) {
            if let selectedRoom {
                LooksLibraryView(
                    room: selectedRoom,
                    compose: {
                        session.editingLookID = nil
                        session.showingLooks = false
                        session.showingComposer = true
                    },
                    edit: { look in
                        session.editingLookID = look.id
                        session.showingLooks = false
                        session.showingComposer = true
                    }
                )
                .environmentObject(manager)
            }
        }
    }

    /// Menu-bar commands that act on what this window is showing.
    private func handle(_ command: LumenCommand) {
        switch command {
        case .newLook:
            guard selectedRoom != nil else { return }
            session.showingComposer = true
        case .addLights:
            session.showingAddOrRepair = true
        case .openLooks:
            guard selectedRoom != nil else { return }
            session.showingLooks = true
        case .openLive:
            guard selectedRoom != nil else { return }
            session.showingLive = true
        case .identifySelected:
            if let editorDevice {
                manager.identify(editorDevice)
            } else {
                for device in manager.devices where session.selectedFixtureIDs.contains(device.id) {
                    manager.identify(device)
                }
            }
        case .openLightPage:
            guard let room = selectedRoom else { return }
            let ordered = room.lightIDs.filter { session.selectedFixtureIDs.contains($0) }
            if let first = ordered.first { session.editorDeviceID = first }
        case .saveLook:
            // The composer saves its own draft; otherwise the room's Looks
            // bar opens its "Save current as a Look" prompt.
            guard !session.showingComposer, selectedRoom != nil else { return }
            NotificationCenter.default.post(name: .lumenSaveCurrentLook, object: nil)
        case .duplicateLook:
            // The composer duplicates its draft itself.
            guard !session.showingComposer else { return }
            if let lastID = manager.lastSceneResult?.scene.id,
               manager.scenes.contains(where: { $0.id == lastID }) {
                manager.duplicateLook(lastID)
            } else {
                manager.publishError("Apply a Look first, then press \u{2318}D to duplicate it. You can also right-click any Look.")
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
            if let summary = manager.lastActionSummary,
               !(manager.isDemoMode && summary.localizedCaseInsensitiveContains("Sample Room")) {
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
        .padding(.horizontal, 16)
        .padding(.bottom, 76)
    }
}

private struct RoomCanvasSidebar: View {
    @EnvironmentObject private var manager: LightManager
    @ObservedObject var session: RoomCanvasSessionStore
    @State private var renamingRoomID: UUID? = nil
    @State private var renamedRoomName: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                LumenHexMark(size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text("LumenDesk")
                        .font(.polarDisplay(17, weight: .bold))
                    Text("Lighting instrument")
                        .font(.polarUI(12))
                        .foregroundStyle(Polar.meter)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        PolarSectionLabel("Rooms")
                        Spacer()
                        Text("\(manager.rooms.count)")
                            .font(.polarMono(12))
                            .foregroundStyle(Polar.meter)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                    ForEach(Array(manager.rooms.enumerated()), id: \.element.id) { index, room in
                        roomButton(room, index: index)
                    }

                    if !manager.scenes.isEmpty {
                        PolarSectionLabel("Looks")
                            .padding(.horizontal, 8)
                            .padding(.top, 18)
                            .padding(.bottom, 4)
                        ForEach(manager.scenes.prefix(8)) { look in
                            Button {
                                session.showingLooks = true
                            } label: {
                                HStack(spacing: 8) {
                                    LookSwatchDots(look: look)
                                    Text(look.name)
                                        .font(.polarUI(13))
                                        .foregroundStyle(Polar.chalk.opacity(0.86))
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Open Looks (⌘L)")
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            VStack(spacing: 8) {
                Button {
                    session.showingAddOrRepair = true
                } label: {
                    Label("Add lights", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PolarButtonStyle(kind: .prominent))
                .help("Add or repair lights (⌘N)")

                Button {
                    session.showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .font(.polarUI(13))
                .foregroundStyle(Polar.meter)
                .padding(.horizontal, 4)

                Text("Select a light to open its page. ⌘, Settings")
                    .font(.polarUI(12))
                    .foregroundStyle(Polar.meter.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(14)
            .overlay(alignment: .top) { Rectangle().fill(Polar.ruleSoft).frame(height: 1) }
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

    private func roomButton(_ room: Room, index: Int) -> some View {
        let lights = manager.devices(in: room)
        let selected = room.id == session.selectedRoomID
        let status = RoomCanvasStatus.resolve(lights, manager: manager)
        let litCount = lights.filter { $0.isOn && !$0.isStale }.count
        return HStack(spacing: 4) {
            Button {
                session.select(room, devices: lights)
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(Polar.roomTint(index))
                        .frame(width: 8, height: 8)
                        .shadow(color: Polar.roomTint(index).opacity(litCount > 0 ? 0.9 : 0), radius: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(room.name)
                            .font(.polarUI(13, weight: selected ? .semibold : .regular))
                            .foregroundStyle(Polar.chalk)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Text("\(litCount)/\(lights.count) on")
                                .font(.polarMono(12))
                            if status != .confirmed {
                                Image(systemName: status.symbol)
                                    .accessibilityLabel(status.title)
                            }
                        }
                        .foregroundStyle(status == .confirmed ? Polar.meter : status.color)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 0)
                    if index < 9 {
                        Text("⌘\(index + 1)")
                            .font(.polarMono(12))
                            .foregroundStyle(Polar.meter.opacity(0.7))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
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
                    .frame(width: 22, height: 30)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Actions for \(room.name)")
            .help("Rename or delete \(room.name)")
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Polar.raisedHi : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(selected ? Polar.accent.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func beginRenaming(_ room: Room) {
        renamedRoomName = room.name
        renamingRoomID = room.id
    }
}

struct RoomCanvasEmptyState: View {
    let openSetup: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: Polar.radiusPanel, style: .continuous)
                    .strokeBorder(Polar.wall, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .frame(width: 132, height: 112)
                LumenHexMark(size: 56)
                    .opacity(0.85)
            }
            Text("Make the room the interface")
                .font(.polarDisplay(30))
                .foregroundStyle(Polar.chalk)
            Text("Find a fixture, identify it in the room, then place it where you expect to find it.")
                .font(.polarUI(15))
                .foregroundStyle(Polar.meter)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button(action: openSetup) {
                Label("Add lights", systemImage: "plus")
            }
            .buttonStyle(PolarButtonStyle(kind: .prominent))
            Text("\u{2318}N")
                .font(.polarMono(11))
                .foregroundStyle(Polar.meter)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Polar.stage)
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
                    .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            canvasColumn
                                .frame(minHeight: 240, idealHeight: 280)
                            selectionInspector
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                LookShelf(
                    room: currentRoom,
                    compose: { session.showingComposer = true }
                )
                .layoutPriority(1)
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
        .background(Polar.desk)
        .overlay(alignment: .bottom) { Rectangle().fill(Polar.ruleSoft).frame(height: 1) }
    }

    private func roomHeading(showsInstruction: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(currentRoom.name)
                .font(.polarDisplay(28, weight: .bold))
                .lineLimit(1)
            if showsInstruction {
                Text("Click a light to select it, double-click to open its page. Drag to arrange.")
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
                session.showingLooks = true
            } label: {
                Label("Looks", systemImage: "swatchpalette")
            }
            .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
            .help("Looks (⌘L)")
            Button {
                session.showingLive = true
            } label: {
                Label("Live", systemImage: "waveform")
            }
            .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
            .help("Live (⇧⌘L)")
            Button {
                manager.scan()
            } label: {
                if manager.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Find", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
            .disabled(manager.isScanning)
            .help(manager.isScanning ? manager.scanPhase : "Find fixtures on the local network (⌘R)")
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
                if isOffline {
                    OfflineBanner(roomName: currentRoom.name)
                        .padding([.horizontal, .top], 18)
                } else {
                    NeedsAttentionStrip(lights: lights, openSetup: { session.showingAddOrRepair = true })
                        .padding([.horizontal, .top], 18)
                }
                DirectionARoomField(
                    room: currentRoom,
                    lights: lights,
                    selection: selection,
                    openLight: { session.editorDeviceID = $0 }
                )
                .padding(18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Lumen.canvas)
    }

    /// Every light in the room has stopped answering, which on a LAN-only
    /// app means the network is gone rather than one fixture.
    private var isOffline: Bool {
        !manager.isDemoMode && lights.count > 1 && lights.allSatisfy(\.isStale)
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

struct DirectionARoomField: View {
    @EnvironmentObject private var manager: LightManager
    let room: Room
    let lights: [LightDevice]
    @Binding var selection: Set<String>
    /// Opens a light's page (double-click on its orb). Nil where the field
    /// is only a picker, as in Add lights.
    var openLight: ((String) -> Void)? = nil
    @State private var dragOffsets: [String: CGSize] = [:]

    var body: some View {
        GeometryReader { geometry in
            let compactWidth = geometry.size.width < 520
            let condensed = compactWidth || geometry.size.height < 420
            let horizontalInset: CGFloat = compactWidth ? 34 : 54
            let verticalInset: CGFloat = condensed ? 42 : 46
            ZStack {
                RoundedRectangle(cornerRadius: Polar.radiusStage, style: .continuous)
                    .fill(Polar.stage)
                roomGrid
                    .clipShape(RoundedRectangle(cornerRadius: Polar.radiusStage, style: .continuous))
                spatialFieldWash(in: geometry.size, horizontalInset: horizontalInset, verticalInset: verticalInset)
                    .clipShape(RoundedRectangle(cornerRadius: Polar.radiusStage, style: .continuous))
                RoundedRectangle(cornerRadius: Polar.radiusStage, style: .continuous)
                    .stroke(Polar.wall, lineWidth: 1)
                roomDetails

                ForEach(lights.indices, id: \.self) { index in
                    let light = lights[index]
                    let anchor = canvasAnchor(for: light, index: index)
                    let offset = dragOffsets[light.id] ?? .zero
                    FixtureCanvasNode(
                        light: light,
                        segmentProfile: manager.segmentProfile(for: light),
                        activeSegmentState: manager.activeSegmentState(for: light.id),
                        selected: selection.contains(light.id),
                        status: RoomCanvasStatus.resolve([light], manager: manager),
                        compact: compactWidth,
                        condensed: condensed,
                        silhouette: LightPageModel.resolve(light).silhouette,
                        select: { toggle(light.id) },
                        open: openLight.map { handler -> () -> Void in { handler(light.id) } }
                    )
                    .frame(width: nodeWidth(for: light, compact: compactWidth),
                           height: condensed ? 92 : 118)
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
        .frame(minHeight: 220)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(room.name) fixture canvas")
    }

    private func spatialFieldWash(in size: CGSize, horizontalInset: CGFloat, verticalInset: CGFloat) -> some View {
        let radius = max(110, min(size.width, size.height) * 0.56)
        return ZStack {
            ForEach(lights.indices, id: \.self) { index in
                let light = lights[index]
                if light.isOn && !light.isStale {
                    let anchor = canvasAnchor(for: light, index: index)
                    let offset = dragOffsets[light.id] ?? .zero
                    let center = CGPoint(
                        x: horizontalInset + (size.width - horizontalInset * 2) * anchor.x + offset.width,
                        y: verticalInset + (size.height - verticalInset * 2) * anchor.y + offset.height
                    )
                    let activeSeg = manager.activeSegmentState(for: light.id)
                    let poweredColors: [Color] = {
                        guard let seg = activeSeg else { return [] }
                        let lit = seg.poweredSegments.compactMap { seg.colors.indices.contains($0) ? seg.colors[$0].litColor : nil }
                        return lit
                    }()
                    let primaryColor = poweredColors.first ?? light.color
                    let secondaryColor = poweredColors.count > 1 ? poweredColors[poweredColors.count / 2] : primaryColor
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    primaryColor.opacity(0.30 * max(0.25, light.brightness)),
                                    secondaryColor.opacity(0.12 * max(0.25, light.brightness)),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 6,
                                endRadius: radius
                            )
                        )
                        .frame(width: radius * 2, height: radius * 2)
                        .position(center)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
            .stroke(Polar.wall.opacity(0.55), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }

    private var roomDetails: some View {
        let isLiveMusic = manager.activeEffects[.room(room.id)] == "music-pulse"
        let snapshot = manager.musicModeController.latestSnapshot
        return VStack {
            HStack {
                Text(room.name.uppercased())
                    .font(.polarCaption)
                    .tracking(1.2)
                    .foregroundStyle(Polar.meter.opacity(0.7))
                Spacer()
                if isLiveMusic {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Lumen.ember)
                            .frame(width: 6, height: 6)
                            .scaleEffect(1.0 + 0.35 * min(1, max(0, snapshot.pulse)))
                        Text(snapshot.tempo > 0
                             ? "LIVE · \(Int(snapshot.tempo.rounded())) BPM · \(snapshot.metre)/4"
                             : "LIVE AUDIO")
                            .font(LumenType.readout(size: 9, weight: .semibold))
                            .foregroundStyle(Lumen.graphite)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Lumen.canvas.opacity(0.9), in: Capsule())
                    .overlay(Capsule().stroke(Lumen.ember.opacity(0.45), lineWidth: 1))
                }
            }
            Spacer()
        }
        .padding(18)
        .accessibilityHidden(true)
    }

    private func nodeWidth(for light: LightDevice, compact: Bool) -> CGFloat {
        if compact {
            switch manager.themeCapability(for: light) {
            case .segments, .matrix, .panels: return 84
            case .solid: return 72
            }
        }
        switch manager.themeCapability(for: light) {
        case .segments: return 132
        case .matrix, .panels: return 112
        case .solid: return 104
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
    let segmentProfile: GoveeSegmentProfile?
    let activeSegmentState: GoveeSegmentState?
    let selected: Bool
    let status: RoomCanvasStatus
    let compact: Bool
    let condensed: Bool
    var silhouette: OrbSilhouette = .bulb
    let select: () -> Void
    var open: (() -> Void)? = nil

    private var orbSize: CGFloat { compact ? 30 : (condensed ? 34 : 42) }

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                GlowingOrb(color: primaryGlowColor, level: light.brightness, isOn: light.isOn,
                           silhouette: silhouette, size: orbSize, selected: selected,
                           stale: light.isStale)
                if status != .confirmed {
                    Image(systemName: status.symbol)
                        .font(.system(size: condensed ? 9 : 11, weight: .bold))
                        .foregroundStyle(status.color)
                        .padding(3)
                        .background(Polar.desk, in: Circle())
                        .offset(x: 4, y: -4)
                }
            }
            .frame(height: orbSize + 18)
            segmentBadge
            Text(light.label)
                .font(.polarUI(compact ? 12 : 13, weight: .semibold))
                .foregroundStyle(Polar.chalk)
                .lineLimit(compact ? 2 : 1)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.82)
                .shadow(color: Polar.stage, radius: 3)
            Text(light.isOn ? status.title : "Off · \(status.title)")
                .font(.polarMono(12, weight: .medium))
                .foregroundStyle(light.isOn ? status.color : Polar.meter)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open?() }
        .onTapGesture(count: 1, perform: select)
        .help(open == nil ? light.label : "\(light.label) — double-click to open its page")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(light.label)
        .accessibilityValue("\(selected ? "Selected, " : "")\(status.title), \(light.isOn ? "on" : "off"), \(Int(light.brightness * 100)) percent")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(.default, select)
        .accessibilityAction(named: "Open light page") { open?() }
    }

    private var primaryGlowColor: Color {
        if let state = activeSegmentState,
           let firstOn = state.poweredSegments.first,
           state.colors.indices.contains(firstOn) {
            return state.colors[firstOn].litColor
        }
        return light.color
    }

    @ViewBuilder
    private var segmentBadge: some View {
        if light.isOn, let state = activeSegmentState, !state.colors.isEmpty {
            if let profile = segmentProfile, profile.limitsSimultaneousZones {
                HStack(spacing: 3) {
                    ForEach(0..<min(3, state.colors.count), id: \.self) { index in
                        let seg = state.colors[index]
                        Capsule()
                            .fill(seg.isOn ? seg.litColor : Lumen.graphite.opacity(0.22))
                            .frame(width: compact ? 10 : 14, height: 4)
                    }
                }
                .accessibilityHidden(true)
            } else {
                SegmentMiniStripView(colors: state.colors.map { $0.isOn ? $0.litColor : Polar.raised })
                    .frame(width: compact ? 44 : 64, height: 4)
            }
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
    @State private var renamingFixtureID: String? = nil
    @State private var renamedFixtureName: String = ""

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

                    if targets.count == 1, let device = targets.first {
                        Button { edit(device.id) } label: {
                            Label(hasSpatialEditor(device) ? "Open light page · \(capabilityObject(device))" : "Open light page",
                                  systemImage: "arrow.up.right.square")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PolarButtonStyle(kind: .prominent))
                        .help("Open this light's own page (⌘↩)")
                    }

                    uplighterZoneControls

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
    private var uplighterZoneControls: some View {
        if targets.count == 1,
           let device = targets.first,
           let profile = manager.segmentProfile(for: device),
           profile.layout == .lamp,
           profile.limitsSimultaneousZones {
            let state = profile.enforcingZoneLimit(manager.segmentState(for: device))
            let zoneLimit = profile.simultaneousZoneLimit ?? 2
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Lamp zones")
                        .font(LumenType.instrumentLabel(size: 10))
                        .tracking(1)
                        .foregroundStyle(Lumen.meter)
                    Spacer()
                    Text("\(state.poweredCount) of \(state.segmentCount) lit (max \(zoneLimit))")
                        .font(LumenType.readout(size: 11))
                        .foregroundStyle(Lumen.meter)
                }

                if !profile.zoneCombinations.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(profile.zoneCombinations.enumerated()), id: \.offset) { _, zones in
                                let isCurrent = state.poweredSegments == zones
                                let title = zones.map { profile.zoneShortName($0) }.joined(separator: " + ")
                                Button(title) {
                                    var next = state
                                    next.setPoweredSegments(zones)
                                    manager.applySegments(device, state: next)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(isCurrent ? Lumen.ember : nil)
                            }
                            ForEach(0..<min(profile.zoneNames.count, state.segmentCount), id: \.self) { zone in
                                let isCurrent = state.poweredSegments == [zone]
                                Button("\(profile.zoneShortName(zone)) only") {
                                    var next = state
                                    next.setPoweredSegments([zone])
                                    manager.applySegments(device, state: next)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(isCurrent ? Lumen.ember : nil)
                            }
                        }
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(GoveeSegmentPreset.uplighterBuiltIns) { preset in
                            Button(preset.name) {
                                var next = state
                                let powered = preset.poweredZones ?? state.poweredSegments
                                next.colors = preset.colors(for: state.segmentCount)
                                next.setPoweredSegments(powered)
                                manager.applySegments(device, state: next)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }

                ForEach(0..<min(profile.zoneNames.count, state.segmentCount), id: \.self) { index in
                    let segment = state.colors[index]
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(segment.isOn ? segment.litColor : segment.color.opacity(0.25))
                                .frame(width: 12, height: 12)
                            Text(profile.zoneName(index))
                                .font(LumenType.body(size: 12, weight: .semibold))
                                .foregroundStyle(segment.isOn ? Lumen.graphite : Lumen.meter)
                            Spacer()
                            ColorPicker("", selection: Binding(
                                get: { segment.color },
                                set: { newColor in
                                    var next = state
                                    next.colors[index] = GoveeSegmentColor(
                                        color: newColor,
                                        brightness: segment.brightness,
                                        isOn: segment.isOn
                                    )
                                    manager.applySegments(device, state: next)
                                }
                            ), supportsOpacity: false)
                            .labelsHidden()
                            .accessibilityLabel("\(profile.zoneName(index)) colour")

                            Toggle("", isOn: Binding(
                                get: { segment.isOn },
                                set: { isOn in
                                    var next = state
                                    let keeping = isOn
                                        ? ([index] + state.poweredSegments.filter { $0 != index })
                                        : state.poweredSegments.filter { $0 != index }
                                    next.setPower(isOn, at: index)
                                    next = profile.enforcingZoneLimit(next, keeping: keeping)
                                    manager.applySegments(device, state: next)
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                            .accessibilityLabel("\(profile.zoneName(index)) power")
                        }

                        HStack(spacing: 8) {
                            Slider(
                                value: Binding(
                                    get: { segment.brightness },
                                    set: { newBrightness in
                                        var next = state
                                        next.colors[index].brightness = newBrightness
                                        manager.applySegments(device, state: next)
                                    }
                                ),
                                in: 0.05...1.0
                            )
                            .controlSize(.small)
                            .accessibilityLabel("\(profile.zoneName(index)) brightness")
                            Text("\(Int((segment.brightness * 100).rounded()))%")
                                .font(LumenType.readout(size: 11))
                                .foregroundStyle(Lumen.meter)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                    .padding(8)
                    .background(Lumen.floor.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(12)
            .background(Lumen.canvas.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
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

                }
            }
            .padding(12)
            .background(Lumen.canvas.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func capabilityName(_ device: LightDevice) -> String {
        if let profile = manager.segmentProfile(for: device), profile.layout == .lamp {
            if let limit = profile.simultaneousZoneLimit {
                return "\(profile.defaultSegmentCount) lamp zones · up to \(limit) lit"
            }
            return "\(profile.defaultSegmentCount) lamp zones"
        }
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
        if let profile = manager.segmentProfile(for: device) {
            return "\(profile.editorUnitName)s"
        }
        return "segments"
    }
}

// MARK: - Looks

struct RoomLookTemplate: Identifiable {
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
    @State private var namingCurrent: Bool = false
    @State private var currentName: String = ""
    @State private var renamingLookID: UUID? = nil
    @State private var renamedLookName: String = ""

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
                    Menu {
                        LightingThemeCategoryMenuContent { theme in
                            _ = manager.startLookPreview(
                                theme, deviceIDs: ids, in: .room(room.id), transitionDuration: 1.2
                            )
                        }
                    } label: {
                        Label("Color themes", systemImage: "swatchpalette")
                    }
                    .buttonStyle(RoomLookButtonStyle())
                    .help("Preview a theme on the room without saving a Look")
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
                            Button("Rename Look") {
                                renamedLookName = look.name
                                renamingLookID = look.id
                            }
                            Button("Duplicate Look") { manager.duplicateLook(look.id) }
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
        .onReceive(NotificationCenter.default.publisher(for: .lumenSaveCurrentLook)) { _ in
            currentName = suggestedName
            namingCurrent = true
        }
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
        .alert("Rename Look", isPresented: Binding(
            get: { renamingLookID != nil },
            set: { if !$0 { renamingLookID = nil } }
        )) {
            TextField("Look name", text: $renamedLookName)
            Button("Cancel", role: .cancel) { renamingLookID = nil }
            Button("Rename") {
                guard let renamingLookID else { return }
                manager.renameScene(renamingLookID, to: renamedLookName)
                self.renamingLookID = nil
            }
            .disabled(renamedLookName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The new name appears on every room shelf where this Look is available.")
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
