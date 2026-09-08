import SwiftUI

// MARK: - The Plan
//
// The room is the primary object. The screen is a drawing of the home, and
// every lit fixture pools its own colour onto it, so a dark room is visible
// from across the desk without reading a word.
//
// The plan is deliberately not a floor plan. It is a seating chart: it does
// not have to be architecturally correct, it has to be consistent. A kitchen
// that stays top-right is learned in about a day and never unlearned, which
// is why `setPlanFrame` refuses an overlapping drop rather than tidying the
// board, and why every default position in `PlanLayout` is deterministic.

struct PlanWorkspaceView: View {
    @EnvironmentObject private var manager: LightManager

    @State private var selectedRoomID: UUID?
    @State private var selectedLightID: String?
    @State private var arranging = false
    @State private var showingSetup = false
    @State private var showingNewRoom = false
    @State private var searchText = ""

    private var selectedRoom: Room? {
        guard let selectedRoomID else { return manager.rooms.first }
        return manager.rooms.first { $0.id == selectedRoomID } ?? manager.rooms.first
    }

    var body: some View {
        HStack(spacing: 0) {
            drawingSheet

            #if os(macOS)
            if let room = selectedRoom {
                Divider().overlay(Lumen.ruleSoft)
                PlanInspector(room: room,
                              selectedLightID: $selectedLightID,
                              arranging: arranging)
                    .frame(width: 268)
            }
            #endif
        }
        .background(Lumen.stage)
        .navigationTitle("Plan")
        .searchable(text: $searchText, prompt: "Search rooms and fixtures")
        .onAppear {
            manager.ensurePlanLayout()
            if selectedRoomID == nil { selectedRoomID = manager.rooms.first?.id }
        }
        .onChange(of: manager.rooms.count) { _ in
            manager.ensurePlanLayout()
            if selectedRoomID == nil { selectedRoomID = manager.rooms.first?.id }
        }
        .sheet(isPresented: $showingSetup) {
            RoomSetupView().environmentObject(manager)
        }
        .sheet(isPresented: $showingNewRoom) {
            NewRoomSheet().environmentObject(manager)
        }
    }

    // MARK: Sheet

    private var drawingSheet: some View {
        VStack(spacing: 0) {
            titleBar
            Divider().overlay(Lumen.ruleSoft)

            if manager.devices.isEmpty {
                emptyRig
            } else if manager.rooms.isEmpty {
                unsortedRig
            } else {
                if !manager.unplacedDevices.isEmpty { unsortedTray }
                PlanBoardView(arranging: arranging,
                              selectedRoomID: $selectedRoomID,
                              selectedLightID: $selectedLightID,
                              query: searchText)
                    .padding(18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var titleBar: some View {
        HStack(spacing: 12) {
            // Drafting convention: thin, tracked, uppercase. This is the one
            // surface in the product where that is correct, because it is a
            // drawing and drawings label that way.
            Text("Ground floor")
                .font(.system(size: 14, weight: .light))
                .kerning(1.4)
                .textCase(.uppercase)
                .foregroundStyle(Lumen.chalk)

            Text(linkSummary)
                .font(LumenType.readout(size: 9.5))
                .kerning(0.8)
                .foregroundStyle(Lumen.muted)

            Spacer(minLength: 12)

            Toggle("Arrange", isOn: $arranging)
                .toggleStyle(LumenChipStyle())
                .help("Move and resize room blocks")

            if arranging {
                Button("Reset layout") { manager.resetPlanLayout() }
                    .buttonStyle(LumenSecondaryButtonStyle(compact: true))
            }

            Menu {
                Button { showingSetup = true } label: {
                    Label("Sort Fixtures Into Rooms", systemImage: "square.grid.3x3.topleft.filled")
                }
                Button { showingNewRoom = true } label: {
                    Label("New Room", systemImage: "rectangle.stack.badge.plus")
                }
                Divider()
                Button { manager.resetPlanLayout() } label: {
                    Label("Reset Plan Layout", systemImage: "arrow.counterclockwise")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Plan actions")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var linkSummary: String {
        let reachable = manager.devices.filter { !$0.isStale }.count
        return "\(reachable) of \(manager.devices.count) linked"
    }

    // MARK: Trays and empty states

    /// Unsorted fixtures surface on the plan itself, forever. Every setup
    /// wizard works once; people buy lamps for years, so the sorting flow
    /// cannot live only in onboarding.
    private var unsortedTray: some View {
        HStack(spacing: 12) {
            Image(systemName: "lightbulb.max")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Lumen.warn)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Lumen.warn.opacity(0.14)))

            VStack(alignment: .leading, spacing: 2) {
                Text(unsortedTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Lumen.chalk)
                Text(manager.unplacedDevices.map(\.label).joined(separator: ", "))
                    .font(LumenType.readout(size: 10))
                    .foregroundStyle(Lumen.meter)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button("Flash and sort") { showingSetup = true }
                .buttonStyle(LumenPrimaryButtonStyle(compact: true))
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Lumen.strip)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Lumen.warn.opacity(0.45), lineWidth: 1)
                )
        )
        .padding(.horizontal, 18)
        .padding(.top, 16)
    }

    private var unsortedTitle: String {
        let count = manager.unplacedDevices.count
        return count == 1 ? "1 fixture is not on the plan" : "\(count) fixtures are not on the plan"
    }

    private var emptyRig: some View {
        ScrollView {
            EmptyWorkspaceView(
                icon: "lightbulb.slash",
                title: "No fixtures found",
                message: "Scan this network for LIFX and Govee, or take the plan for a run on an isolated demo rig.",
                primaryTitle: "Scan This Network",
                primaryAction: manager.scan,
                secondaryTitle: "Try the Demo Rig",
                secondaryAction: manager.enterDemoMode
            )
            .padding(24)
        }
    }

    private var unsortedRig: some View {
        ScrollView {
            VStack(spacing: 14) {
                LumenIconTile(systemName: "square.grid.3x3.topleft.filled",
                              tint: Lumen.muted, size: 52)
                Text("Nothing is on the plan yet")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Lumen.chalk)
                Text("\(manager.devices.count) fixtures are on the network. Sorting them takes about a minute: most land in a room from their own name, and the rest get flashed one at a time so you can point at them.")
                    .font(.system(size: 13))
                    .foregroundStyle(Lumen.meter)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Sort My Fixtures") { showingSetup = true }
                    .buttonStyle(LumenPrimaryButtonStyle())
            }
            .frame(maxWidth: .infinity)
            .padding(44)
        }
    }
}

/// A move or resize expressed in whole grid cells.
struct PlanCellDelta {
    var columns: Int
    var rows: Int
}

// MARK: - Board

/// The grid of room blocks. Six columns wide, growing downward.
struct PlanBoardView: View {
    @EnvironmentObject private var manager: LightManager
    let arranging: Bool
    @Binding var selectedRoomID: UUID?
    @Binding var selectedLightID: String?
    var query: String = ""

    /// A move or resize in progress, held here so the ghost and the block can
    /// be drawn from the same source.
    @State private var draft: (roomID: UUID, frame: RoomPlanFrame, valid: Bool)?

    private var rows: Int {
        var frames: [UUID: RoomPlanFrame] = [:]
        for room in manager.rooms { if let f = room.planFrame { frames[room.id] = f } }
        return PlanLayout.rowCount(for: frames)
    }

    var body: some View {
        GeometryReader { proxy in
            let cell = CGSize(width: proxy.size.width / CGFloat(PlanLayout.columns),
                              height: proxy.size.height / CGFloat(rows))
            ZStack(alignment: .topLeading) {
                if arranging { grid(cell: cell) }

                ForEach(manager.rooms) { room in
                    if let frame = displayFrame(for: room) {
                        RoomBlockView(
                            room: room,
                            arranging: arranging,
                            dimmed: !matchesQuery(room),
                            selected: selectedRoomID == room.id,
                            selectedLightID: $selectedLightID,
                            onSelect: { selectedRoomID = room.id },
                            onLevel: { manager.setBrightness(in: room, value: $0) },
                            onMove: { delta, committing in
                                move(room: room, by: delta, resize: false, committing: committing)
                            },
                            onResize: { delta, committing in
                                move(room: room, by: delta, resize: true, committing: committing)
                            },
                            cell: cell
                        )
                        .frame(width: cell.width * CGFloat(frame.width) - 5,
                               height: cell.height * CGFloat(frame.height) - 5)
                        .offset(x: cell.width * CGFloat(frame.column) + 2.5,
                                y: cell.height * CGFloat(frame.row) + 2.5)
                        .zIndex(draft?.roomID == room.id ? 10 : 0)
                    }
                }

                if let draft, !draft.valid {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(Lumen.fail, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Lumen.fail.opacity(0.09))
                        )
                        .frame(width: cell.width * CGFloat(draft.frame.width) - 5,
                               height: cell.height * CGFloat(draft.frame.height) - 5)
                        .offset(x: cell.width * CGFloat(draft.frame.column) + 2.5,
                                y: cell.height * CGFloat(draft.frame.row) + 2.5)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(minHeight: CGFloat(rows) * 96)
    }

    private func grid(cell: CGSize) -> some View {
        Canvas { context, size in
            let line = Color(hex: 0xFFFFFF, alpha: 0.045)
            for column in 1..<PlanLayout.columns {
                var path = Path()
                let x = cell.width * CGFloat(column)
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(line), lineWidth: 1)
            }
            for row in 1..<max(2, rows) {
                var path = Path()
                let y = cell.height * CGFloat(row)
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(line), lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
    }

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
        let candidate = resize
            ? RoomPlanFrame(column: base.column, row: base.row,
                            width: base.width + delta.columns, height: base.height + delta.rows)
            : RoomPlanFrame(column: base.column + delta.columns, row: base.row + delta.rows,
                            width: base.width, height: base.height)

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
            draft = (room.id, candidate, valid)
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

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var lights: [LightDevice] { manager.devices(in: room) }
    private var litLights: [LightDevice] { lights.filter { $0.isOn && !$0.isStale } }

    private var level: Double {
        guard !litLights.isEmpty else { return 0 }
        return litLights.reduce(0) { $0 + $1.brightness } / Double(litLights.count)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(selected ? Lumen.stripRaised : Lumen.strip)

            // The pools. This is the status display: what a room is doing is
            // legible from across the desk without reading anything.
            RoomPoolCanvas(pools: pools, flat: reduceTransparency)
                .allowsHitTesting(false)

            fixtureDots

            VStack(alignment: .leading, spacing: 0) {
                Text(room.name)
                    .font(.system(size: 10.5, weight: .regular))
                    .kerning(1.5)
                    .textCase(.uppercase)
                    .foregroundStyle(Lumen.chalk)
                    .lineLimit(1)

                Spacer(minLength: 6)

                levelRule

                HStack(alignment: .lastTextBaseline) {
                    Text(lights.isEmpty ? "—" : "\(Int((level * 100).rounded()))")
                        .font(LumenType.readout(size: 24, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Lumen.chalk)
                        .shadow(color: Lumen.stage.opacity(0.9), radius: 6)
                    Spacer(minLength: 6)
                    Text("\(litLights.count)/\(lights.count)")
                        .font(LumenType.readout(size: 9))
                        .foregroundStyle(Lumen.muted)
                }
            }
            .padding(10)

            if arranging { resizeGrip }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(borderColour, lineWidth: 1)
        )
        .opacity(dimmed ? 0.35 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if !arranging { onSelect() } }
        .gesture(arranging ? moveGesture : levelGesture)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(room.name)
        .accessibilityValue("\(Int((level * 100).rounded())) percent, \(litLights.count) of \(lights.count) lit")
    }

    private var borderColour: Color {
        if selected { return Lumen.link.opacity(0.7) }
        return arranging ? Lumen.rule : Lumen.ruleSoft
    }

    /// Room level as a dimension line under the plan rather than a slider,
    /// because a drawing measures with a rule.
    private var levelRule: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Lumen.rule).frame(height: 2)
                Capsule()
                    .fill(Lumen.link)
                    .frame(width: max(0, proxy.size.width * level), height: 2)
                    .shadow(color: Lumen.link.opacity(0.6), radius: 4)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 6)
        .padding(.bottom, 5)
    }

    private var pools: [RoomPoolCanvas.Pool] {
        lights.compactMap { light in
            guard light.isOn, !light.isStale else { return nil }
            let anchor = manager.planAnchor(for: light.id, in: room)
            return RoomPoolCanvas.Pool(anchor: anchor,
                                       colour: light.color,
                                       opacity: 0.14 + light.brightness * 0.5)
        }
    }

    /// The fixture itself, where it stands. Click one and you never have to
    /// remember which lamp is called "Bed Left", because you are pointing at
    /// it instead of naming it.
    private var fixtureDots: some View {
        GeometryReader { proxy in
            ForEach(lights) { light in
                let anchor = manager.planAnchor(for: light.id, in: room)
                Button {
                    onSelect()
                    selectedLightID = light.id
                } label: {
                    Circle()
                        .fill(light.isOn && !light.isStale ? light.color : Lumen.faint)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Color.white.opacity(0.19), lineWidth: 1))
                        .shadow(color: light.isOn ? light.color.opacity(0.8) : .clear, radius: 5)
                        .overlay {
                            if selectedLightID == light.id {
                                Circle().stroke(Lumen.link, lineWidth: 2).padding(-3)
                            }
                        }
                }
                .buttonStyle(.plain)
                .disabled(arranging)
                .position(x: proxy.size.width * anchor.x, y: proxy.size.height * anchor.y)
                .help(light.label)
                .accessibilityLabel("Select \(light.label)")
            }
        }
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

    /// Drag anywhere inside a room to set the whole room. The room is the
    /// object here, so the room is what a plain drag controls.
    private var levelGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in commitLevel(at: value.location.x) }
            .onEnded { value in commitLevel(at: value.location.x) }
    }

    private func commitLevel(at x: CGFloat) {
        onSelect()
        let width = max(1, cell.width * CGFloat(room.planFrame?.width ?? 1) - 5)
        onLevel(min(1, max(0, Double(x / width))))
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in onMove(cellDelta(value.translation), false) }
            .onEnded { value in onMove(cellDelta(value.translation), true) }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in onResize(cellDelta(value.translation), false) }
            .onEnded { value in onResize(cellDelta(value.translation), true) }
    }

    private func cellDelta(_ translation: CGSize) -> PlanCellDelta {
        PlanCellDelta(columns: Int((translation.width / max(1, cell.width)).rounded()),
                      rows: Int((translation.height / max(1, cell.height)).rounded()))
    }
}

// MARK: - Pools

/// Light falling on the drawing.
///
/// Drawn in a `Canvas` with a screen blend so two lamps in one room add up
/// the way light actually does, and blurred so the edge of a pool is a
/// falloff rather than a circle. Reduce Transparency swaps the blur for flat
/// discs, which keeps the information and drops the cost.
struct RoomPoolCanvas: View {
    struct Pool {
        let anchor: PlanAnchor
        let colour: Color
        let opacity: Double
    }

    let pools: [Pool]
    var flat: Bool = false

    var body: some View {
        Canvas { context, size in
            context.blendMode = .screen
            if !flat { context.addFilter(.blur(radius: 13)) }

            let radius = min(size.width, size.height) * 0.58
            for pool in pools {
                let centre = CGPoint(x: size.width * pool.anchor.x,
                                     y: size.height * pool.anchor.y)
                let rect = CGRect(x: centre.x - radius, y: centre.y - radius,
                                  width: radius * 2, height: radius * 2)
                let shading: GraphicsContext.Shading = flat
                    ? .color(pool.colour.opacity(pool.opacity * 0.6))
                    : .radialGradient(
                        Gradient(stops: [
                            .init(color: pool.colour.opacity(pool.opacity), location: 0),
                            .init(color: pool.colour.opacity(pool.opacity), location: 0.18),
                            .init(color: pool.colour.opacity(0), location: 0.66)
                        ]),
                        center: centre, startRadius: 0, endRadius: radius)
                context.fill(Ellipse().path(in: rect), with: shading)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Inspector

/// The selected room, and every fixture in it with its own control.
///
/// Per-fixture work is the cost of putting the room first: it is one click on
/// a dot plus one drag here, where a channel strip would be a single drag.
/// The trade is deliberate, and this column is what keeps the cost at two.
private struct PlanInspector: View {
    @EnvironmentObject private var manager: LightManager
    let room: Room
    @Binding var selectedLightID: String?
    let arranging: Bool

    @State private var renaming = false
    @State private var draftName = ""
    @State private var showingRoomDetail = false

    private var lights: [LightDevice] { manager.devices(in: room) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                Toggle("All in this room",
                       isOn: Binding(get: { lights.contains(where: \.isOn) },
                                     set: { manager.setPower(in: room, on: $0) }))
                    .toggleStyle(LumenRockerStyle())
                    .disabled(lights.isEmpty)

                if lights.isEmpty {
                    Text("No fixtures in this room yet. Sort one in from the plan's tray, or drag it here from another room.")
                        .font(.system(size: 12))
                        .foregroundStyle(Lumen.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(lights) { light in
                        PlanFixtureRow(light: light,
                                       selected: selectedLightID == light.id,
                                       onSelect: { selectedLightID = light.id })
                    }
                }

                Button("Room settings") { showingRoomDetail = true }
                    .buttonStyle(LumenSecondaryButtonStyle(compact: true))
                    .frame(maxWidth: .infinity)

                Spacer(minLength: 12)
                planFacts
            }
            .padding(16)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(Lumen.deck)
        // Schedules, effects and automation overrides for the room. The plan
        // is the control surface; this is where the room's settings live.
        .sheet(isPresented: $showingRoomDetail) {
            RoomDetailSheet(room: room).environmentObject(manager)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if renaming {
                TextField("Room name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(Lumen.chalk)
                    .onSubmit(commitRename)
                Button("Save", action: commitRename)
                    .buttonStyle(LumenSecondaryButtonStyle(compact: true))
            } else {
                Text(room.name)
                    .font(.system(size: 15, weight: .light))
                    .kerning(1.3)
                    .textCase(.uppercase)
                    .foregroundStyle(Lumen.chalk)
                Spacer(minLength: 6)
                Button {
                    draftName = room.name
                    renaming = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(LumenIconButtonStyle(size: 24))
                .accessibilityLabel("Rename \(room.name)")
            }
        }
    }

    private func commitRename() {
        manager.renameRoom(room.id, to: draftName)
        renaming = false
    }

    private var planFacts: some View {
        VStack(spacing: 5) {
            Divider().overlay(Lumen.ruleSoft).padding(.bottom, 6)
            WashLinkFact(key: "FIXTURES", value: "\(lights.count)")
            WashLinkFact(key: "LIT",
                         value: "\(lights.filter { $0.isOn && !$0.isStale }.count)")
            WashLinkFact(key: "UNREACHABLE",
                         value: "\(lights.filter(\.isStale).count)",
                         dead: lights.contains(where: \.isStale))
            if let frame = room.planFrame {
                WashLinkFact(key: "BLOCK",
                             value: "\(frame.width)×\(frame.height) @ \(frame.column),\(frame.row)")
            }
        }
    }
}

/// One fixture inside the inspector: identity, power, and its own level.
private struct PlanFixtureRow: View {
    @EnvironmentObject private var manager: LightManager
    @ObservedObject var light: LightDevice
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle()
                    .fill(light.isOn && !light.isStale ? light.color : Lumen.faint)
                    .frame(width: 8, height: 8)
                    .shadow(color: light.isOn ? light.color.opacity(0.7) : .clear, radius: 4)

                Text(light.label)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(light.isStale ? Lumen.muted : Lumen.chalk)
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text(light.isStale ? "N/R" : light.isOn ? "\(Int((light.brightness * 100).rounded()))%" : "OFF")
                    .font(LumenType.readout(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Lumen.muted)

                Button {
                    manager.setPower(light, on: !light.isOn)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(LumenIconButtonStyle(size: 20, prominent: light.isOn && !light.isStale))
                .disabled(light.isStale)
                .accessibilityLabel("Power for \(light.label)")
            }

            LumenFader(
                label: light.label,
                value: Binding(get: { light.brightness },
                               set: { manager.setBrightness(light, value: $0) }),
                track: .tint(light.color),
                showsHeader: false
            )
            .disabled(light.isStale)

            Button("Identify") { manager.identify(light) }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(Lumen.link)
                .accessibilityLabel("Flash \(light.label)")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, selected ? 8 : 0)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Lumen.stripRaised : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}
