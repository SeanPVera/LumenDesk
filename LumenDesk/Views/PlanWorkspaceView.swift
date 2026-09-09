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
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                PlanTitleBlock()
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
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

            Text("1:50")
                .font(LumenType.readout(size: 9.5))
                .kerning(0.8)
                .foregroundStyle(Lumen.muted)

            Spacer(minLength: 12)
            arrangeControls
            actionsMenu
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    @ViewBuilder
    private var arrangeControls: some View {
        Toggle("Arrange", isOn: $arranging)
            .toggleStyle(LumenChipStyle())
            .help("Move and resize room blocks")

        if arranging {
            Button("Reset layout") { manager.resetPlanLayout() }
                .buttonStyle(LumenSecondaryButtonStyle(compact: true))
        }
    }

    private var actionsMenu: some View {
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
        .background(trayBackground)
        .padding(.horizontal, 18)
        .padding(.top, 16)
    }

    private var trayBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Lumen.strip)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Lumen.warn.opacity(0.45), lineWidth: 1)
            )
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
        return PlanLayout.rowCount(for: frames)
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
                // Walls last so they sit over every floor, and inert so a
                // partition never swallows a click meant for a fixture.
                PlanWallLayer(frames: placedFrames,
                              cell: cell,
                              inset: boardInset,
                              bounds: proxy.size,
                              selected: selectedFrame)
                    .allowsHitTesting(false)
                refusal(cell: cell)
            }
        }
        .frame(minHeight: CGFloat(rows) * 96)
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
                Text(figure)
                    .font(LumenType.readout(size: 11, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(Lumen.chalk)
                    .padding(.horizontal, 4)
                    .background(Lumen.floor)
                    .offset(y: -9)
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
                .font(LumenType.readout(size: 9))
                .kerning(0.6)
                .foregroundStyle(Lumen.muted)
            if let value {
                Text(value)
                    .font(LumenType.readout(size: 9))
                    .foregroundStyle(isLink ? Lumen.link : Lumen.chalk)
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
        .onTapGesture { if !arranging { onSelect() } }
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
            Text(room.name)
                .font(.system(size: 10, weight: .light))
                .kerning(1.8)
                .textCase(.uppercase)
                .foregroundStyle(Lumen.chalk)
                .shadow(color: Lumen.stage.opacity(0.95), radius: 5)
                .lineLimit(1)
            Spacer(minLength: 6)
            PlanDimensionLine(level: level, figure: figure)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
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

    private var roomPower: Binding<Bool> {
        Binding(get: { lights.contains(where: \.isOn) },
                set: { manager.setPower(in: room, on: $0) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                masterToggle
                fixtureList
                settingsButton
                Spacer(minLength: 12)
                deviceFacts
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

    private var masterToggle: some View {
        Toggle("All in this room", isOn: roomPower)
            .toggleStyle(LumenRockerStyle())
            .disabled(lights.isEmpty)
    }

    @ViewBuilder
    private var fixtureList: some View {
        if lights.isEmpty {
            Text("No fixtures in this room yet. Sort one in from the plan's tray, or move it here from another room.")
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
    }

    private var settingsButton: some View {
        Button("Room settings") { showingRoomDetail = true }
            .buttonStyle(LumenSecondaryButtonStyle(compact: true))
            .frame(maxWidth: .infinity)
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

    /// What the drawing cannot say.
    ///
    /// The plan already states how many fixtures a room has and how many are
    /// lit, so repeating that here fills the column with an echo. These are
    /// the facts only the inspector has: what the selected fixture actually
    /// is, where it lives on the network, and when it last answered. The
    /// network facts take the one authored hue; the catalogue facts do not.
    @ViewBuilder
    private var deviceFacts: some View {
        if let light = selectedLight {
            VStack(spacing: 5) {
                Divider().overlay(Lumen.ruleSoft).padding(.bottom, 6)
                PlanCatalogueFact(key: "MAKE", value: makeLine(for: light))
                PlanCatalogueFact(key: "MODE", value: modeLine(for: light))
                WashLinkFact(key: "LINK", value: light.address, dead: light.isStale)
                WashLinkFact(key: "SEEN",
                             value: light.isStale ? "no reply" : lastSeenLine(for: light),
                             dead: light.isStale)
            }
        }
    }

    private var selectedLight: LightDevice? {
        guard let id = selectedLightID else { return lights.first }
        return lights.first { $0.id == id } ?? lights.first
    }

    private func makeLine(for light: LightDevice) -> String {
        let brand = light.brand == .lifx ? "LIFX" : "Govee"
        guard let sku = light.sku, !sku.isEmpty else { return brand }
        return "\(brand) \(sku)"
    }

    private func modeLine(for light: LightDevice) -> String {
        if light.isLIFXLuna { return "Matrix" }
        if let profile = manager.segmentStudioProfile(for: light) {
            let held = profile.appliesViaStream ? " · held" : ""
            return "\(profile.defaultSegmentCount) segments\(held)"
        }
        return "\(light.kelvin) K"
    }

    private func lastSeenLine(for light: LightDevice) -> String {
        let seconds = Int(Date().timeIntervalSince(light.lastSeen))
        if seconds < 60 { return "\(max(0, seconds)) s ago" }
        if seconds < 3_600 { return "\(seconds / 60) min ago" }
        return "\(seconds / 3_600) h ago"
    }

    /// The two room facts the drawing does not already state. Its count of
    /// lit fixtures is on the room label and its hatched patches mark the
    /// unreachable ones, so FIXTURES and LIT used to sit here saying twice
    /// what you can read once. The unreachable tally stays because the hatch
    /// is deliberately quiet, and the block figure is arranging information
    /// the drawing has no room for.
    private var planFacts: some View {
        VStack(spacing: 5) {
            Divider().overlay(Lumen.ruleSoft).padding(.bottom, 6)
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

/// A catalogue fact: the same ruled row as `WashLinkFact`, in chalk rather
/// than the authored hue, because what a fixture *is* is not network truth.
private struct PlanCatalogueFact: View {
    let key: String
    let value: String

    var body: some View {
        HStack {
            Text(key)
                .font(LumenType.readout(size: 9.5, weight: .regular))
                .foregroundStyle(Lumen.muted)
            Spacer(minLength: 8)
            Text(value)
                .font(LumenType.readout(size: 9.5, weight: .medium))
                .foregroundStyle(Lumen.meter)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One fixture inside the inspector: identity, power, and its own level.
private struct PlanFixtureRow: View {
    @EnvironmentObject private var manager: LightManager
    @ObservedObject var light: LightDevice
    let selected: Bool
    let onSelect: () -> Void

    private var lit: Bool { light.isOn && !light.isStale }
    private var dotColour: Color { lit ? light.color : Lumen.faint }
    private var nameColour: Color { light.isStale ? Lumen.muted : Lumen.chalk }
    private var nameWeight: Font.Weight { selected ? .semibold : .regular }

    private var statusText: String {
        if light.isStale { return "N/R" }
        guard light.isOn else { return "OFF" }
        return "\(Int((light.brightness * 100).rounded()))%"
    }

    private var levelBinding: Binding<Double> {
        Binding(get: { light.brightness },
                set: { manager.setBrightness(light, value: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            identityRow
            levelFader
            identifyButton
        }
        .padding(.vertical, 8)
        .padding(.horizontal, selected ? 8 : 0)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private var identityRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColour)
                .frame(width: 8, height: 8)
                .shadow(color: lit ? light.color.opacity(0.7) : .clear, radius: 4)

            Text(light.label)
                .font(.system(size: 12, weight: nameWeight))
                .foregroundStyle(nameColour)
                .lineLimit(1)

            Spacer(minLength: 6)

            Text(statusText)
                .font(LumenType.readout(size: 10))
                .monospacedDigit()
                .foregroundStyle(Lumen.muted)

            powerButton
        }
    }

    private var powerButton: some View {
        Button {
            manager.setPower(light, on: !light.isOn)
        } label: {
            Image(systemName: "power")
                .font(.system(size: 9, weight: .semibold))
        }
        .buttonStyle(LumenIconButtonStyle(size: 20, prominent: lit))
        .disabled(light.isStale)
        .accessibilityLabel("Power for \(light.label)")
    }

    private var levelFader: some View {
        LumenFader(label: light.label,
                   value: levelBinding,
                   track: .tint(light.color),
                   showsHeader: false)
            .disabled(light.isStale)
    }

    private var identifyButton: some View {
        Button("Identify") { manager.identify(light) }
            .buttonStyle(.plain)
            .font(.system(size: 10.5))
            .foregroundStyle(Lumen.link)
            .accessibilityLabel("Flash \(light.label)")
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(selected ? Lumen.stripRaised : Color.clear)
    }
}
