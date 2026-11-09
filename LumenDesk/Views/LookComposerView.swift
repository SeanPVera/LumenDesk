import SwiftUI
import Foundation

enum LookBrush: String, CaseIterable, Identifiable {
    case original = "Original"
    case spatialWash = "Spatial wash"
    case gradient = "Gradient"
    case exactFixture = "Exact fixture"
    var id: String { rawValue }

    var distribution: ThemeDistribution {
        switch self {
        case .original: return .scattered // unused; applying(to:) returns the source theme
        case .spatialWash: return .wash
        case .gradient: return .gradient
        case .exactFixture: return .alternating
        }
    }

    func applying(to source: LightingTheme) -> LightingTheme {
        switch self {
        case .original:
            return source
        case .spatialWash, .gradient, .exactFixture:
            return LightingTheme(
                id: "\(source.id)-\(id)",
                name: source.name,
                summary: source.summary,
                category: source.category,
                icon: source.icon,
                colors: source.colors,
                brightness: source.brightness,
                distribution: distribution
            )
        }
    }

    var summary: String {
        switch self {
        case .original: return "Keeps the theme\u{2019}s original spread and brightness."
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

struct ComposerPalette: Identifiable {
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
        var seenIDs: Set<String> = ["ember-moss", "direction-a-ember-moss"]
        for theme in LightingCatalog.themes where !seenIDs.contains(theme.id) {
            seenIDs.insert(theme.id)
            values.append(ComposerPalette(id: theme.id, name: theme.name, theme: theme))
        }
        return values
    }()
}

/// Polar Look Composer: a per-fixture table (include, room, fixture, colour,
/// level), a stage preview with an explicit Preview switch, and Save/Revert.
///
/// Preview is OFF by default and the composer never touches a light while
/// it is off: editing the table only changes the draft and the on-screen
/// stage. Turning Preview on shows the draft on the lights through the same
/// path Apply uses; turning it off, Revert-and-off, Cancel or closing the
/// sheet restores the exact opening state.
struct LookComposerView: View {
    @EnvironmentObject private var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    let room: Room
    let initialSelection: Set<String>
    let editing: LightingScene?

    @State private var rows: [LookDraftRow] = []
    @State private var openingRows: [LookDraftRow] = []
    @State private var lookName: String = ""
    @State private var openingName: String = ""
    @State private var allRooms: Bool = false
    @State private var paletteID: String? = nil
    @State private var previewOn: Bool = false
    @State private var previewID: UUID? = nil
    @State private var loaded: Bool = false

    init(room: Room, initialSelection: Set<String>, editing: LightingScene? = nil) {
        self.room = room
        self.initialSelection = initialSelection
        self.editing = editing
    }

    private var currentRoom: Room { manager.rooms.first(where: { $0.id == room.id }) ?? room }

    /// Lights in table order: the open room first, then (with All rooms)
    /// every other room in sidebar order.
    private var tableLights: [LightDevice] {
        var seen = Set<String>()
        var result: [LightDevice] = []
        let rooms = allRooms ? [currentRoom] + manager.rooms.filter { $0.id != currentRoom.id } : [currentRoom]
        for room in rooms {
            for light in manager.devices(in: room) where seen.insert(light.id).inserted {
                result.append(light)
            }
        }
        return result
    }

    private var includedCount: Int { rows.filter(\.included).count }
    private var hasChanges: Bool { rows != openingRows || lookName != openingName }
    private var canSave: Bool {
        includedCount > 0 && !lookName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func roomOf(_ id: String) -> Room? {
        if currentRoom.lightIDs.contains(id) { return currentRoom }
        return manager.rooms.first { $0.lightIDs.contains(id) }
    }

    private func light(_ id: String) -> LightDevice? { manager.devices.first { $0.id == id } }

    private var draftSnapshots: [String: DeviceSnapshot] {
        let kelvins = Dictionary(manager.devices.map { ($0.id, $0.kelvin) }, uniquingKeysWith: { first, _ in first })
        return LookDraftBuilder.snapshots(rows, kelvins: kelvins, original: editing, originalRows: openingRows)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            GeometryReader { geometry in
                if geometry.size.width >= 820 {
                    HStack(spacing: 0) {
                        tablePane
                        Rectangle().fill(Polar.ruleSoft).frame(width: 1)
                        stagePane.frame(width: 300)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            stagePane.frame(height: 520)
                            Rectangle().fill(Polar.ruleSoft).frame(height: 1)
                            tableRows.padding(PolarSpacing.md)
                        }
                    }
                }
            }
        }
        .background(Polar.stage)
        .foregroundStyle(Polar.chalk)
        .font(.polarUI(13))
        .sheetFrame(minWidth: 680, idealWidth: 1040, minHeight: 620, idealHeight: 760)
        .onAppear(perform: load)
        .onDisappear {
            if previewOn { endPreview(restore: true) }
        }
        .onChange(of: allRooms) { _ in mergeRowsForScope() }
        .task(id: rows) {
            // Only a running preview follows edits; with Preview off the
            // draft stays on screen and nothing is sent.
            guard previewOn, let id = previewID else { return }
            do { try await Task.sleep(nanoseconds: 140_000_000) } catch { return }
            guard !Task.isCancelled, previewOn else { return }
            if manager.previewComposedLook(draftSnapshots, updating: id) == nil {
                previewOn = false
                previewID = nil
            }
        }
        .onReceive(manager.$rehearsalSceneID) { current in
            // Another owner (Apply, a show, a workspace switch) ended it.
            if previewOn, current != previewID {
                previewOn = false
                previewID = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumenCommand)) { note in
            switch LumenCommandBus.command(from: note) {
            case .saveLook?: if canSave { save() }
            case .duplicateLook?: saveCopy()
            default: break
            }
        }
    }

    // MARK: Header

    private var headerBar: some View {
        HStack(spacing: PolarSpacing.sm) {
            Button {
                cancel()
            } label: {
                Label("Looks", systemImage: "chevron.left")
            }
            .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
            .keyboardShortcut(.cancelAction)

            TextField("Look name", text: $lookName)
                .textFieldStyle(.plain)
                .font(.polarDisplay(17, weight: .bold))
                .frame(maxWidth: 220)
                .accessibilityLabel("Look name")
            Text(roomsCaption)
                .font(.polarUI(12))
                .foregroundStyle(Polar.meter)
                .lineLimit(1)
            Spacer(minLength: 8)
            if editing != nil {
                Button("Duplicate") { saveCopy() }
                    .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
                    .help("Save this draft as a new Look (\u{2318}D)")
                    .disabled(!canSave)
            }
            Button("Revert") { revert() }
                .buttonStyle(PolarButtonStyle(kind: .quiet))
                .disabled(!hasChanges)
            Button("Save Look") { save() }
                .buttonStyle(PolarButtonStyle(kind: .prominent))
                .disabled(!canSave)
        }
        .padding(.horizontal, PolarSpacing.md)
        .padding(.vertical, 10)
        .background(Polar.desk)
        .overlay(alignment: .bottom) { Rectangle().fill(Polar.ruleSoft).frame(height: 1) }
    }

    private var roomsCaption: String {
        if !allRooms { return currentRoom.name }
        return manager.rooms.map(\.name).joined(separator: " \u{00B7} ")
    }

    // MARK: Table

    private var tablePane: some View {
        ScrollView {
            tableRows.padding(PolarSpacing.md)
        }
    }

    private var tableRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: PolarSpacing.sm) {
                PolarSectionLabel("Per-fixture color & level \u{00B7} \(includedCount) of \(rows.count) included")
                Spacer(minLength: 8)
                Picker("Scope", selection: $allRooms) {
                    Text("This room").tag(false)
                    Text("All rooms").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
            }
            paletteStrip
            columnHeader
            ForEach($rows) { $row in
                if let device = light(row.id) {
                    LookComposerRow(row: $row, device: device, roomName: roomOf(row.id)?.name ?? "No room")
                }
            }
            if rows.isEmpty {
                Text("This room has no fixtures yet. Add lights first, then compose a Look.")
                    .font(.polarUI(13))
                    .foregroundStyle(Polar.meter)
                    .padding(.vertical, PolarSpacing.lg)
            }
        }
    }

    private var paletteStrip: some View {
        HStack(spacing: 8) {
            Text("Start from")
                .font(.polarUI(12))
                .foregroundStyle(Polar.meter)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ComposerPalette.choices.prefix(14)) { palette in
                        Button {
                            paletteID = palette.id
                            rows = LookDraftBuilder.repaint(rows, palette: palette.theme.colors.map { UInt32($0.hex & 0xFFFFFF) })
                        } label: {
                            HStack(spacing: 6) {
                                HStack(spacing: -4) {
                                    ForEach(Array(palette.theme.colors.prefix(4).enumerated()), id: \.offset) { _, color in
                                        Circle().fill(color.color)
                                            .overlay(Circle().stroke(Polar.desk, lineWidth: 1.5))
                                            .frame(width: 12, height: 12)
                                    }
                                }
                                Text(palette.name).lineLimit(1)
                            }
                        }
                        .buttonStyle(PolarButtonStyle(kind: paletteID == palette.id ? .selected : .quiet, compact: true))
                        .help("Recolour the included fixtures with \(palette.name)")
                    }
                }
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 18)
            Text("ROOM").frame(width: 104, alignment: .leading)
            Text("FIXTURE").frame(maxWidth: .infinity, alignment: .leading)
            Text("COLOR").frame(width: 120, alignment: .leading)
            Text("LEVEL").frame(width: 190, alignment: .leading)
        }
        .font(.polarMono(10, weight: .semibold))
        .tracking(0.8)
        .foregroundStyle(Polar.meter)
        .padding(.horizontal, 14)
    }

    // MARK: Stage

    private var stagePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                PolarSectionLabel("Stage preview")
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(previewOn ? "Preview ON \u{2014} showing the Look on your lights"
                                       : "Preview OFF \u{2014} lights untouched")
                            .font(.polarUI(13, weight: .semibold))
                            .foregroundStyle(previewOn ? Polar.mint : Polar.chalk)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Explicit: fixtures stay as they are unless Preview is on. Saving never changes a light.")
                            .font(.polarUI(11))
                            .foregroundStyle(Polar.meter)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Toggle("Preview", isOn: previewBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(Polar.mint)
                        .accessibilityLabel("Preview on lights")
                        .disabled(includedCount == 0 && !previewOn)
                }
            }
            .polarPanel(fill: Polar.desk, padding: 14)

            Text(previewOn ? "PREVIEW ON" : "PREVIEW OFF")
                .font(.polarMono(11, weight: .bold))
                .tracking(1)
                .foregroundStyle(previewOn ? Polar.mint : Polar.meter)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(previewOn ? Polar.mint.opacity(0.12) : Polar.raised.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(previewOn ? Polar.mint.opacity(0.45) : Polar.ruleSoft, lineWidth: 1))

            ComposerStage(rows: rows.filter(\.included), lit: previewOn, anchor: { id in
                guard let room = roomOf(id) else { return PlanAnchor(x: 0.5, y: 0.5) }
                return manager.planAnchor(for: id, in: room)
            }, silhouette: { id in
                light(id).map { LightPageModel.resolve($0).silhouette } ?? .bulb
            })
            .frame(maxHeight: .infinity)

            Text("Orbs show included fixtures at their Look colours. Preview off dims the stage and leaves live lights alone.")
                .font(.polarUI(11))
                .foregroundStyle(Polar.meter)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                save()
            } label: {
                Text("Save Look").frame(maxWidth: .infinity)
            }
            .buttonStyle(PolarButtonStyle(kind: .prominent))
            .disabled(!canSave)
        }
        .padding(PolarSpacing.md)
        .background(Polar.deck)
    }

    private var previewBinding: Binding<Bool> {
        Binding(
            get: { previewOn },
            set: { on in
                if on {
                    previewID = manager.previewComposedLook(draftSnapshots)
                    previewOn = previewID != nil
                } else {
                    endPreview(restore: true)
                }
            }
        )
    }

    // MARK: Actions

    private func load() {
        guard !loaded else { return }
        loaded = true
        let lights = tableLights
        if let editing {
            rows = LookDraftBuilder.rows(editing: editing, lights: lights)
            lookName = editing.name
            // A Look reaching beyond this room opens with every room shown.
            if !Set(editing.snapshots.keys).isSubset(of: Set(currentRoom.lightIDs)) {
                allRooms = true
                rows = LookDraftBuilder.rows(editing: editing, lights: tableLights)
            }
        } else {
            let palette = ComposerPalette.choices.first
            paletteID = palette?.id
            rows = LookDraftBuilder.rows(
                palette: palette?.theme.colors.map { UInt32($0.hex & 0xFFFFFF) } ?? [],
                level: palette?.theme.brightness ?? 0.62,
                lights: lights,
                selection: RoomWorkspaceSelection.targets(selected: initialSelection, available: currentRoom.lightIDs)
                    == Set(currentRoom.lightIDs) ? [] : initialSelection
            )
            lookName = palette?.name ?? "New Look"
        }
        openingRows = rows
        openingName = lookName
    }

    /// Switching the scope keeps every edited row and adds the newcomers,
    /// excluded, at their live colour.
    private func mergeRowsForScope() {
        let existing = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        rows = tableLights.map { light in
            if let row = existing[light.id] { return row }
            let c = light.color.rgbComponents
            return LookDraftRow(id: light.id, included: false,
                                rgb: LookDraftBuilder.rgb(red: c.r, green: c.g, blue: c.b),
                                level: max(LookDraftBuilder.minimumLevel, light.brightness))
        }
    }

    private func revert() {
        let opening = Dictionary(openingRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        rows = rows.compactMap { opening[$0.id] } + openingRows.filter { row in !rows.contains { $0.id == row.id } }
        lookName = openingName
    }

    private func endPreview(restore: Bool) {
        if previewID != nil, manager.rehearsalSceneID == previewID {
            manager.stopSceneRehearsal(restore: restore)
        }
        previewOn = false
        previewID = nil
    }

    private func cancel() {
        endPreview(restore: true)
        dismiss()
    }

    private func save() {
        guard canSave else { return }
        let snapshots = draftSnapshots
        guard manager.saveComposedLook(name: lookName, snapshots: snapshots, replacing: editing?.id) != nil else { return }
        // A running preview already shows the saved Look, so keep it on the
        // lights rather than snapping back; with Preview off nothing moved.
        endPreview(restore: false)
        dismiss()
    }

    /// ⌘D: save the current draft as a new Look and keep composing.
    private func saveCopy() {
        guard canSave else { return }
        let name = LookDraftBuilder.copyName(for: lookName.trimmingCharacters(in: .whitespacesAndNewlines),
                                             existing: manager.scenes.map(\.name))
        _ = manager.saveComposedLook(name: name, snapshots: draftSnapshots, replacing: nil)
    }
}

/// One table row: include checkbox, room chip, fixture, colour, level.
private struct LookComposerRow: View {
    @Binding var row: LookDraftRow
    @ObservedObject var device: LightDevice
    let roomName: String

    private var modelLine: String {
        let line = LightPageModel.resolve(device).modelLine
        if !line.isEmpty { return line }
        return [device.brand.displayName, device.sku].compactMap { $0 }.joined(separator: " ")
    }

    var body: some View {
        HStack(spacing: 12) {
            PolarCheckbox(isOn: $row.included, label: "Include \(device.label)")
            Text(roomName)
                .font(.polarUI(11, weight: .semibold))
                .foregroundStyle(Polar.select)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Polar.accent.opacity(0.16)))
                .frame(width: 104, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.label)
                    .font(.polarUI(13, weight: .semibold))
                    .lineLimit(1)
                Text(modelLine)
                    .font(.polarUI(11))
                    .foregroundStyle(Polar.meter)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                ColorPicker("", selection: colorBinding, supportsOpacity: false)
                    .polarColorWell(row.color, width: 30, height: 22)
                    .accessibilityLabel("\(device.label) color")
                Text(row.hex)
                    .font(.polarMono(11))
                    .foregroundStyle(Polar.meter)
            }
            .frame(width: 120, alignment: .leading)
            HStack(spacing: 8) {
                Slider(value: $row.level, in: LookDraftBuilder.minimumLevel...1)
                    .tint(Polar.accent)
                    .accessibilityLabel("\(device.label) level")
                    .accessibilityValue("\(Int((row.level * 100).rounded())) percent")
                Text("\(Int((row.level * 100).rounded()))%")
                    .font(.polarMono(11, weight: .semibold))
                    .frame(width: 38, alignment: .trailing)
            }
            .frame(width: 190)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Polar.desk))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(row.included ? Polar.rule : Polar.ruleSoft, lineWidth: 1))
        .opacity(row.included ? 1 : 0.55)
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { row.color },
            set: { color in
                let c = color.rgbComponents
                row.rgb = LookDraftBuilder.rgb(red: c.r, green: c.g, blue: c.b)
            }
        )
    }
}

/// A square Polar checkbox that works the same on macOS and iOS.
struct PolarCheckbox: View {
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isOn ? Polar.accent : Polar.raised)
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(isOn ? Polar.accent : Polar.rule, lineWidth: 1))
                .overlay {
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(PolarSwatchButtonStyle())
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "Included" : "Not included")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The composer's stage: included fixtures as glowing orbs at their room
/// positions in the draft's colours. Dimmed while Preview is off.
private struct ComposerStage: View {
    let rows: [LookDraftRow]
    let lit: Bool
    let anchor: (String) -> PlanAnchor
    let silhouette: (String) -> OrbSilhouette

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: Polar.radiusCard, style: .continuous)
                    .fill(Polar.stage)
                PolarStageGrid(spacing: 28)
                    .stroke(Polar.wall.opacity(0.55), lineWidth: 0.5)
                    .clipShape(RoundedRectangle(cornerRadius: Polar.radiusCard, style: .continuous))
                ForEach(rows) { row in
                    let point = anchor(row.id)
                    GlowingOrb(color: row.color, level: row.level, isOn: true,
                               silhouette: silhouette(row.id), size: 22)
                        .position(x: 24 + (geometry.size.width - 48) * point.x,
                                  y: 24 + (geometry.size.height - 48) * point.y)
                }
                .opacity(lit ? 1 : 0.45)
                .saturation(lit ? 1 : 0.7)
            }
            .overlay(RoundedRectangle(cornerRadius: Polar.radiusCard, style: .continuous)
                .stroke(Polar.ruleSoft, lineWidth: 1))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stage preview, \(rows.count) fixtures\(lit ? ", preview on" : "")")
    }
}

/// Square grid lines for stage backdrops.
struct PolarStageGrid: Shape {
    var spacing: CGFloat = 32

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard spacing > 2 else { return path }
        var x = rect.minX + spacing
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += spacing
        }
        var y = rect.minY + spacing
        while y < rect.maxY {
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += spacing
        }
        return path
    }
}

struct ComposerRoomPreview: View {
    @EnvironmentObject private var manager: LightManager
    let room: Room
    let lights: [LightDevice]
    let targetIDs: Set<String>
    let theme: LightingTheme
    let paletteAssignments: [String: Int]?
    let spatialField: SpatialFieldVector

    private var plans: [String: ThemeFixturePlan] {
        let fixtures = lights.filter { targetIDs.contains($0.id) }.map {
            ThemeFixture(
                id: $0.id,
                capability: manager.themeCapability(for: $0),
                kelvin: $0.kelvin,
                anchor: manager.planAnchor(for: $0.id, in: room)
            )
        }
        let plan: ThemePlan
        if let paletteAssignments {
            plan = ThemePlanner.planExact(
                theme,
                fixtures: fixtures,
                paletteIndices: paletteAssignments
            )
        } else {
            plan = ThemePlanner.plan(theme, fixtures: fixtures, spatialField: spatialField)
        }
        return Dictionary(uniqueKeysWithValues: plan.fixtures.map { ($0.fixtureID, $0) })
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(Lumen.floor)
                spatialPreviewWash
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                RoundedRectangle(cornerRadius: 18).stroke(Lumen.graphite, lineWidth: 3)

                if paletteAssignments == nil {
                    VStack {
                        HStack(spacing: 5) {
                            Image(systemName: spatialField.icon)
                                .font(.system(size: 10, weight: .semibold))
                            Text(spatialField.displayName.uppercased())
                                .font(LumenType.instrumentLabel(size: 9))
                                .tracking(0.9)
                            Spacer()
                        }
                        .foregroundStyle(Lumen.graphite.opacity(0.62))
                        Spacer()
                    }
                    .padding(12)
                    .allowsHitTesting(false)
                }

                ForEach(lights) { light in
                    let anchor = manager.planAnchor(for: light.id, in: room)
                    let plan = plans[light.id]
                    VStack(spacing: 4) {
                        ComposerFixtureSwatch(plan: plan)
                            .frame(width: 34, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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

    @ViewBuilder
    private var spatialPreviewWash: some View {
        let colors = theme.colors.map { $0.color.opacity(0.24 * max(0.25, theme.brightness)) }
        if colors.isEmpty {
            EmptyView()
        } else if paletteAssignments != nil {
            LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                .opacity(0.45)
        } else {
            switch spatialField {
            case .themeDefault, .westToEast:
                LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
            case .northToSouth:
                LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
            case .diagonalSweep:
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            case .radialCenter:
                RadialGradient(colors: colors, center: .center, startRadius: 8, endRadius: 150)
            }
        }
    }
}

/// Planned segment, matrix, or panel colours for a fixture, scaled by the
/// look's overall brightness so the onscreen preview matches live output.
struct ComposerFixtureSwatch: View {
    let plan: ThemeFixturePlan?

    var body: some View {
        Group {
            if let plan {
                if let matrix = plan.matrix {
                    VStack(spacing: 1) {
                        ForEach(0..<matrix.height, id: \.self) { row in
                            HStack(spacing: 1) {
                                ForEach(0..<matrix.width, id: \.self) { column in
                                    let index = row * matrix.width + column
                                    let cell = matrix.containsZone(index) ? matrix.colors[index] : nil
                                    Rectangle().fill(
                                        cell.map { color in
                                            Color(
                                                hue: Double(color.hue) / 65_535,
                                                saturation: Double(color.saturation) / 65_535,
                                                brightness: max(0.04, Double(color.brightness) / 65_535 * plan.brightness)
                                            )
                                        } ?? .clear
                                    )
                                }
                            }
                        }
                    }
                } else if let segments = plan.segments {
                    HStack(spacing: 0) {
                        ForEach(sampledIndices(segments.colors.count), id: \.self) { index in
                            let segment = segments.colors[index]
                            let level = segment.isOn ? segment.brightness * plan.brightness : 0
                            Rectangle().fill(Color(red: segment.red * level, green: segment.green * level,
                                                   blue: segment.blue * level))
                        }
                    }
                } else if let panels = plan.panels {
                    HStack(spacing: 1) {
                        ForEach(sampledIndices(panels.count), id: \.self) { index in
                            Rectangle().fill(panels[index].emittedColor(scaledBy: plan.brightness))
                        }
                    }
                } else {
                    let rgb = plan.tone.rgb(atLevel: plan.brightness)
                    Rectangle().fill(Color(red: rgb.red, green: rgb.green, blue: rgb.blue))
                }
            } else {
                Rectangle().fill(Lumen.graphite.opacity(0.12))
            }
        }
        .accessibilityHidden(true)
    }

    private func sampledIndices(_ count: Int) -> [Int] {
        guard count > 1 else { return count == 1 ? [0] : [] }
        let samples = min(count, 24)
        return (0..<samples).map { $0 * (count - 1) / (samples - 1) }
    }
}
