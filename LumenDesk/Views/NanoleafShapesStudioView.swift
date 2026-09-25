import SwiftUI

/// The Shapes wall editor: the arrangement as the controller reports it,
/// its orientation, panel selection, painting, and saving, in that order.
///
/// Shown inline in the room workspace when one Shapes wall is selected, and
/// as a sheet from the fixture row elsewhere. Everything it changes goes
/// through `NanoleafShapesController` and `LightManager`; the view keeps only
/// selection and field drafts.
struct NanoleafShapesStudio: View {
    enum Presentation { case inline, sheet }

    @EnvironmentObject private var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var device: LightDevice
    @ObservedObject var shapes: NanoleafShapesController
    var presentation: Presentation = .inline
    /// Panels selected when the editor first appears.
    var initialSelection: Set<Int> = []
    /// Canvas beside the inspector, or stacked. Inline, the workspace knows
    /// its width; a sheet measures its own.
    var wide = true

    @State private var selection: Set<Int> = []
    @State private var cursor: Int?
    @State private var orientationDraft: Int?
    @State private var paintColor: Color = Color(red: 1, green: 0.42, blue: 0.17)
    @State private var startColor: Color = .white
    @State private var hexDraft = ""
    @State private var hexProblem: String?
    @State private var gradientStart: Color = Color(red: 1, green: 0.42, blue: 0.17)
    @State private var gradientEnd: Color = Color(red: 0.42, green: 0.24, blue: 1)
    @State private var gradientAxis: NanoleafSpatialAxis = .leftToRight
    @State private var selectsByTouch = false
    @State private var handledTouch: Date?
    @State private var colorEditEnd: Task<Void, Never>?
    @State private var studioMessage: String?
    @State private var namingDesign = false
    @State private var designName = ""
    @State private var namingGroup = false
    @State private var groupName = ""
    @State private var storing = false
    @State private var storeName = ""
    @State private var storeConflict = false
    @State private var storeBusy = false

    private var deviceID: String { device.id }
    private var wall: NanoleafShapesController.Wall { shapes.wall(deviceID) }
    private var session: NanoleafEditingSession? { shapes.session(deviceID) }
    private var runningShow: (scope: LightScope, name: String)? { manager.animatingEffect(for: deviceID) }
    private var rotation: Double { Double(orientationDraft ?? shapes.displayOrientation(deviceID)) }
    private var isPreviewing: Bool { shapes.previewing.contains(deviceID) }

    var body: some View {
        Group {
            if presentation == .sheet {
                GeometryReader { geometry in
                    ScrollView { content(wide: geometry.size.width >= 900).padding(20) }
                }
                .sheetFrame(minWidth: 620, idealWidth: 1040, minHeight: 600, idealHeight: 820)
                .background(Lumen.stage)
            } else {
                content(wide: wide)
            }
        }
        .onChange(of: wall.arrangement?.layout.paintableIDs ?? []) { ids in
            let dropped = selection.subtracting(ids)
            guard !dropped.isEmpty else { return }
            selection.subtract(dropped)
            studioMessage = "\(dropped.count) selected panel\(dropped.count == 1 ? " is" : "s are") no longer on the wall and left the selection."
        }
        .onChange(of: wall.touchedAt) { touchedAt in
            guard selectsByTouch, let touchedAt, touchedAt != handledTouch, let panel = wall.touchedPanel else { return }
            handledTouch = touchedAt
            selection = [panel]
            cursor = panel
        }
        .onAppear {
            if selection.isEmpty { selection = initialSelection }
        }
        .onDisappear {
            // A preview is temporary; leaving the editor puts back what the
            // wall showed before it, where that can be done. The draft stays.
            if let message = shapes.endPreview(deviceID, restore: true) { manager.publishError(message) }
        }
    }

    private func content(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let layout = wall.arrangement?.layout, !layout.paintablePanels.isEmpty {
                if wide {
                    HStack(alignment: .top, spacing: 28) {
                        canvasColumn(layout, height: 400).frame(maxWidth: .infinity)
                        inspector(layout).frame(width: 340)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        canvasColumn(layout, height: 300)
                        inspector(layout)
                    }
                }
            } else {
                unavailable
            }
        }
        .padding(presentation == .inline ? 16 : 0)
        .background(presentation == .inline ? Lumen.deck : Color.clear)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Shapes panels \u{2014} \(device.label)", systemImage: "hexagon")
                    .font(LumenType.display(size: 17, weight: .semibold))
                Text(statusLine).font(.callout).foregroundStyle(Lumen.meter)
                    .fixedSize(horizontal: false, vertical: true)
                if manager.isDemoMode {
                    Label("Demo Mode: a simulated wall. Nothing is sent to a controller.", systemImage: "play.rectangle")
                        .font(.caption).foregroundStyle(Lumen.meter)
                }
                if device.isStale {
                    Label("Not responding. Edits stay in the draft until the controller answers.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Lumen.warn)
                }
            }
            Spacer(minLength: 8)
            if presentation == .sheet {
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private var statusLine: String {
        guard let layout = wall.arrangement?.layout else { return "Layout not read yet" }
        var parts = ["\(layout.paintablePanels.count) panels", layout.shapeSummary, "showing: \(wall.output.summary)"]
        if !device.isOn { parts.append("wall is off") }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(wall.topologyProblem.map { "The controller\u{2019}s layout couldn\u{2019}t be read: \($0.summary)" }
                 ?? "Waiting for the controller to report its layout.")
                .font(.callout).foregroundStyle(Lumen.meter)
                .fixedSize(horizontal: false, vertical: true)
            Text("Panels can be painted once the arrangement is known. Power, brightness, colour and stored scenes still work.")
                .font(.caption).foregroundStyle(Lumen.meter)
                .fixedSize(horizontal: false, vertical: true)
            Button("Read the layout again") { manager.refreshShapes(device) }
                .buttonStyle(LumenSecondaryButtonStyle(compact: true))
                .disabled(manager.isDemoMode)
        }
    }

    // MARK: Canvas column

    private func canvasColumn(_ layout: NanoleafLayout, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            NanoleafWallCanvas(layout: layout, rotation: rotation, display: display(layout),
                               selection: selection, cursor: cursor,
                               onTap: { toggle($0) },
                               onMarquee: { selection.formUnion($0); cursor = $0.sorted().first },
                               onIdentify: { shapes.identifyPanel($0, on: deviceID) })
                .frame(height: height)
                .background(Lumen.stage)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Lumen.ruleSoft, lineWidth: 1))
                .focusableCompat()
                .onMoveCompat { direction in moveCursor(direction, in: layout) }
                .onExitCommandCompat { selection = [] }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Shapes wall, \(layout.paintablePanels.count) panels, drawn as it hangs")
            if let orientationDraft {
                Label("Previewing \(orientationDraft)\u{00B0} here. The wall and its effects change when you apply it.",
                      systemImage: "rotate.right")
                    .font(.caption).foregroundStyle(Lumen.warn)
            }
            legend(for: display(layout).source)
            selectionBar(layout)
            if let message = studioMessage ?? wall.lastChange?.summary {
                Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(Lumen.meter)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = wall.topologyProblem {
                Label("The latest layout reading was damaged (\(problem.summary)); the last good layout is shown.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Lumen.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = wall.lastFailure {
                Label(failure, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Lumen.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func legend(for source: NanoleafPanelDisplay.Source) -> some View {
        let origin: String
        switch source {
        case .draft: origin = isPreviewing ? "Draft, previewing on the wall" : "Draft, not on the wall yet"
        case .sent: origin = "What LumenDesk last sent"
        case .wholeWall: origin = "One colour across the wall"
        case .off: origin = "The wall is off"
        case .unknown: origin = "Colours unknown: the wall is playing something LumenDesk can\u{2019}t read"
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(origin).font(.caption.weight(.semibold)).foregroundStyle(Lumen.chalk)
            Text("Filled number = selected \u{00B7} dashed edge = off \u{00B7} hatched ? = unknown \u{00B7} dashed ring = keyboard cursor. Colours are shown before master brightness (\(Int((device.brightness * 100).rounded()))%).")
                .font(.caption).foregroundStyle(Lumen.meter)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func selectionBar(_ layout: NanoleafLayout) -> some View {
        let total = layout.paintablePanels.count
        let groups = shapes.groups[deviceID] ?? []
        return VStack(alignment: .leading, spacing: 8) {
            Text(selection.isEmpty ? "No panels selected \u{2014} tools affect all \(total)"
                 : "\(selection.count) of \(total) panels selected")
                .font(.callout.weight(.medium))
            HStack(spacing: 8) {
                Button("All") { selection = layout.paintableIDs }
                Button("None") { selection = [] }.disabled(selection.isEmpty)
                Button("Invert") { selection = layout.paintableIDs.subtracting(selection) }
                Menu("Groups") {
                    ForEach(groups) { group in
                        Button("Select \u{201C}\(group.name)\u{201D}") { selection = Set(group.panelIDs).intersection(layout.paintableIDs) }
                    }
                    if !groups.isEmpty { Divider() }
                    Button("Save selection as group\u{2026}") { groupName = ""; namingGroup = true }
                        .disabled(selection.isEmpty)
                    if !groups.isEmpty {
                        Menu("Delete group") {
                            ForEach(groups) { group in
                                Button(group.name, role: .destructive) { shapes.deleteGroup(group.id, for: deviceID) }
                            }
                        }
                    }
                }
                .fixedSize()
                Spacer(minLength: 0)
            }
            .buttonStyle(LumenSecondaryButtonStyle(compact: true))
            HStack(spacing: 12) {
                Button("Identify on the wall") { identifySelection(layout) }
                    .buttonStyle(LumenSecondaryButtonStyle(compact: true))
                    .disabled(manager.isDemoMode)
                    .help("Breathes one selected panel for four seconds so you can find it on the wall")
                Toggle("Select by touching the wall", isOn: $selectsByTouch)
                    .toggleStyle(LumenChipStyle())
                    .disabled(manager.isDemoMode)
            }
        }
        .alert("Save selection as group", isPresented: $namingGroup) {
            TextField("Group name", text: $groupName)
            Button("Save") { shapes.saveGroup(named: groupName, panelIDs: selection, for: deviceID) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A group remembers these \(selection.count) panels on this wall so you can select them again.")
        }
    }

    // MARK: Inspector

    private func inspector(_ layout: NanoleafLayout) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            orientationSection(layout)
            Divider()
            if let runningShow {
                Label("\(runningShow.name) is running on this wall. Stop it before painting panels.", systemImage: "waveform")
                    .font(.callout).foregroundStyle(Lumen.meter)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let session {
                paintSection(layout, session: session)
            } else {
                startSection(layout)
            }
            if selection.count == 1, let id = selection.first, let panel = layout.panel(withID: id) {
                Divider()
                panelDetails(panel, layout: layout)
            }
            Divider()
            designsSection(layout)
            Divider()
            NanoleafSceneLibrary(device: device, shapes: shapes) { colors, name in
                startFromScene(colors, name: name)
            }
            Divider()
            panelList(layout)
            if let message = studioMessage {
                Text(message).font(.caption).foregroundStyle(Lumen.meter)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Orientation

    private func orientationSection(_ layout: NanoleafLayout) -> some View {
        let state = wall.orientation
        let current = shapes.displayOrientation(deviceID)
        let value = orientationDraft ?? current
        return VStack(alignment: .leading, spacing: 10) {
            Text("Orientation").font(.headline)
            Text(state.summary).font(.caption).foregroundStyle(state.isFailed ? Lumen.warn : Lumen.meter)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { orientationDraft = NanoleafOrientation.normalized(value - 90) } label: {
                    Image(systemName: "rotate.left").accessibilityLabel("Turn left 90 degrees")
                }
                Stepper(value: Binding(get: { value }, set: { orientationDraft = NanoleafOrientation.normalized($0) }),
                        in: -360...720, step: 5) {
                    TextField("Degrees", value: Binding(get: { value },
                                                         set: { orientationDraft = NanoleafOrientation.normalized($0) }),
                              format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .accessibilityLabel("Orientation in degrees")
                }
                Text("\u{00B0}").foregroundStyle(Lumen.meter).accessibilityHidden(true)
                Button { orientationDraft = NanoleafOrientation.normalized(value + 90) } label: {
                    Image(systemName: "rotate.right").accessibilityLabel("Turn right 90 degrees")
                }
            }
            .buttonStyle(LumenSecondaryButtonStyle(compact: true))
            HStack(spacing: 8) {
                Button("Apply orientation") {
                    manager.requestShapesOrientation(value, for: device)
                    orientationDraft = nil
                }
                .buttonStyle(LumenPrimaryButtonStyle())
                .disabled(orientationDraft == nil || orientationDraft == current)
                Button("Reset") { orientationDraft = nil }
                    .buttonStyle(LumenSecondaryButtonStyle(compact: true))
                    .disabled(orientationDraft == nil)
                if state.isFailed {
                    Button("Dismiss") { shapes.dismissOrientationFailure(deviceID) }
                        .buttonStyle(LumenSecondaryButtonStyle(compact: true))
                }
            }
            Text("Turn the drawing until it matches the wall: identify a panel, find it, then rotate. Orientation aims LumenDesk\u{2019}s spatial effects and the controller\u{2019}s touch gestures; the panels themselves never move.")
                .font(.caption).foregroundStyle(Lumen.meter)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Starting an edit

    private func startSection(_ layout: NanoleafLayout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paint panels").font(.headline)
            switch wall.output {
            case .design, .preview:
                if shapes.canContinueAppliedDesign(deviceID), let design = shapes.designs[deviceID] {
                    Button("Edit the design on the wall") { shapes.beginSession(deviceID, origin: .appliedDesign, design: design) }
                        .buttonStyle(LumenPrimaryButtonStyle())
                } else {
                    takeover(layout)
                }
            case .solid:
                Button("Start from the wall\u{2019}s colour") { startUniform(wallColor, origin: wallColor) }
                    .buttonStyle(LumenPrimaryButtonStyle())
                takeoverAlternatives(layout)
            case .white:
                Button("Start from the wall\u{2019}s white") { startUniform(whiteColor, origin: whiteColor) }
                    .buttonStyle(LumenPrimaryButtonStyle())
                Text("Panels take colour, not temperature: this starts from an RGB match for \(device.kelvin) K.")
                    .font(.caption).foregroundStyle(Lumen.meter)
                takeoverAlternatives(layout)
            default:
                takeover(layout)
            }
        }
    }

    /// While the wall plays something LumenDesk cannot read panel by panel,
    /// starting an edit is an explicit choice, never a guess.
    @ViewBuilder private func takeover(_ layout: NanoleafLayout) -> some View {
        Text(takeoverReason).font(.callout).foregroundStyle(Lumen.meter)
            .fixedSize(horizontal: false, vertical: true)
        if let design = shapes.designs[deviceID] {
            Button("Start from the last LumenDesk design") { shapes.beginSession(deviceID, origin: .savedDesign("Last applied"), design: design) }
                .buttonStyle(LumenPrimaryButtonStyle())
        }
        takeoverAlternatives(layout)
    }

    @ViewBuilder private func takeoverAlternatives(_ layout: NanoleafLayout) -> some View {
        HStack(spacing: 8) {
            ColorPicker("One colour", selection: $startColor, supportsOpacity: false)
                .fixedSize()
            Button("Start from this colour") {
                let color = panelColor(startColor)
                startUniform(color, origin: color)
            }
            .buttonStyle(LumenSecondaryButtonStyle(compact: true))
        }
        let saved = shapes.savedDesigns(for: deviceID)
        if !saved.isEmpty {
            Menu("Start from a saved design") {
                ForEach(saved) { item in
                    Button(item.name) { shapes.beginSession(deviceID, origin: .savedDesign(item.name), design: item.design) }
                }
            }
            .fixedSize()
        }
        Text("Nothing reaches the wall until you preview or apply.")
            .font(.caption).foregroundStyle(Lumen.meter)
    }

    private var takeoverReason: String {
        switch wall.output {
        case .nativeEffect(let name):
            return "The wall is playing \u{201C}\(name)\u{201D}. Its panel colours can\u{2019}t be read, so choose where to start."
        case .off:
            return "The wall is off. Choose where to start; applying turns it on."
        case .unknown:
            return "The controller hasn\u{2019}t reported what it\u{2019}s showing yet. Choose where to start."
        case .stream:
            return "A live show is streaming to the wall. Choose where to start."
        default:
            return "\(wall.output.summary). Its panel colours can\u{2019}t be read, so choose where to start."
        }
    }

    // MARK: Painting

    private func paintSection(_ layout: NanoleafLayout, session: NanoleafEditingSession) -> some View {
        let targets = targetIDs(layout)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(selection.isEmpty ? "Paint all \(targets.count) panels" : "Paint \(targets.count) selected")
                    .font(.headline)
                Spacer()
                Button { edit { $0.undo() } } label: { Image(systemName: "arrow.uturn.backward").accessibilityLabel("Undo edit") }
                    .disabled(!session.canUndo)
                Button { edit { $0.redo() } } label: { Image(systemName: "arrow.uturn.forward").accessibilityLabel("Redo edit") }
                    .disabled(!session.canRedo)
            }
            .buttonStyle(LumenSecondaryButtonStyle(compact: true))
            Text(sessionLine(session)).font(.caption).foregroundStyle(Lumen.meter)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 6)], spacing: 6) {
                ForEach(LightRowView.colorSwatches, id: \.label) { swatch in
                    Button { recolor(panelColor(swatch.color), layout: layout) } label: {
                        RoundedRectangle(cornerRadius: 2).fill(swatch.color).frame(width: 44, height: 32)
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Lumen.rule, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(swatch.label)
                    .accessibilityLabel("Paint \(swatch.label)")
                }
            }
            ColorPicker("Colour", selection: Binding(get: { paintColor }, set: { value in
                paintColor = value
                recolorContinuously(panelColor(value), layout: layout)
            }), supportsOpacity: false)
            HStack(spacing: 8) {
                TextField("#RRGGBB", text: $hexDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                    .onSubmit { paintHex(layout) }
                    .accessibilityLabel("Exact colour as hex")
                Button("Set exact colour") { paintHex(layout) }
                    .buttonStyle(LumenSecondaryButtonStyle(compact: true))
            }
            if let hexProblem { Text(hexProblem).font(.caption).foregroundStyle(Lumen.warn) }
            LumenFader(label: "Panel intensity", value: Binding(
                get: { averageIntensity(targets, in: session) },
                set: { value in shapes.edit(deviceID) { $0.edit { $0.setIntensity(value, panels: targets) } } }),
                       onEditingChanged: { editing in
                           shapes.edit(deviceID) { editing ? $0.beginContinuousEdit() : $0.endContinuousEdit() }
                       })
            HStack(spacing: 8) {
                Button("Turn off") { shapes.edit(deviceID) { $0.edit { $0.setIntensity(0, panels: targets) } } }
                Button("Full intensity") { shapes.edit(deviceID) { $0.edit { $0.setIntensity(1, panels: targets) } } }
            }
            .buttonStyle(LumenSecondaryButtonStyle(compact: true))
            Text("Intensity belongs to each panel. The wall\u{2019}s master brightness (\(Int((device.brightness * 100).rounded()))%) applies on top, once.")
                .font(.caption).foregroundStyle(Lumen.meter)
                .fixedSize(horizontal: false, vertical: true)
            gradientTools(layout, targets: targets)
            themeMenu(layout, targets: targets)
            Divider()
            Toggle("Preview on the wall as I edit", isOn: Binding(
                get: { isPreviewing },
                set: { shapes.setPreviewing($0, for: deviceID) }))
                .disabled(device.isStale)
            HStack(spacing: 8) {
                Button("Apply to wall") { applyDraft(session) }
                    .buttonStyle(LumenPrimaryButtonStyle())
                    .disabled(!session.hasUnappliedChanges && wall.claim == .design)
                Button("Discard draft") {
                    let message = shapes.endSession(deviceID)
                    studioMessage = message
                }
                .buttonStyle(LumenSecondaryButtonStyle(compact: true))
            }
            Text("Apply makes the draft the wall\u{2019}s design and adds one step to Undo. Discard drops it and, if you were previewing, puts back what the wall showed before.")
                .font(.caption).foregroundStyle(Lumen.meter)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func gradientTools(_ layout: NanoleafLayout, targets: Set<Int>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gradient across \(selection.isEmpty ? "the wall" : "the selection")").font(.caption.weight(.semibold))
            HStack(spacing: 10) {
                ColorPicker("From", selection: $gradientStart, supportsOpacity: false).fixedSize()
                ColorPicker("To", selection: $gradientEnd, supportsOpacity: false).fixedSize()
            }
            Picker("Direction", selection: $gradientAxis) {
                ForEach(NanoleafSpatialAxis.allCases) { Text($0.displayName).tag($0) }
            }
            Button("Blend") {
                let colors = NanoleafDesignBuilder.gradient(from: panelColor(gradientStart), to: panelColor(gradientEnd),
                                                            panels: targets, layout: layout,
                                                            rotationDegrees: rotation, axis: gradientAxis)
                shapes.edit(deviceID) { session in
                    session.edit { draft in for (id, color) in colors { draft.paint(color, panels: [id]) } }
                }
            }
            .buttonStyle(LumenSecondaryButtonStyle(compact: true))
        }
    }

    private func themeMenu(_ layout: NanoleafLayout, targets: Set<Int>) -> some View {
        Menu("Fill with a theme") {
            ForEach(LightingCatalog.themes) { theme in
                Button(theme.name) { fill(theme, layout: layout, targets: targets) }
            }
        }
        .fixedSize()
        .help("Spreads the theme\u{2019}s colours across the panels, left to right as the wall is oriented")
    }

    // MARK: Panel details and list

    private func panelDetails(_ panel: NanoleafPanel, layout: NanoleafLayout) -> some View {
        let number = layout.panelNumbers(rotationDegrees: rotation)[panel.panelID] ?? 0
        let draft = session?.draft[panel.panelID]
        let shown = display(layout).colors[panel.panelID]
        return VStack(alignment: .leading, spacing: 6) {
            Text("Panel \(number)").font(.headline)
            Text("\(panel.kind.displayName) \u{00B7} ID \(panel.panelID) \u{00B7} turned \(Int(panel.orientation.rounded()))\u{00B0} in the layout")
                .font(.caption).foregroundStyle(Lumen.meter)
            Text("Layout position x \(String(format: "%.1f", panel.x)), y \(String(format: "%.1f", panel.y))")
                .font(.caption.monospacedDigit()).foregroundStyle(Lumen.meter)
            if let draft {
                Text("Draft: \(draft.hexString) \u{00B7} \(draft.spokenDescription)").font(.caption).foregroundStyle(Lumen.chalk)
            }
            Text(wall.output.panelColorsAreKnown
                 ? "Last sent: \(wall.lastSent[panel.panelID]?.hexString ?? "nothing yet")"
                 : "On the wall now: unknown (\(wall.output.summary))")
                .font(.caption).foregroundStyle(Lumen.meter)
            if shown == nil, session == nil {
                Text("Hatched panels are unknown, not dark.").font(.caption).foregroundStyle(Lumen.meter)
            }
            Button("Identify on the wall") { shapes.identifyPanel(panel.panelID, on: deviceID) }
                .buttonStyle(LumenSecondaryButtonStyle(compact: true))
                .disabled(manager.isDemoMode)
        }
    }

    private func panelList(_ layout: NanoleafLayout) -> some View {
        let numbers = layout.panelNumbers(rotationDegrees: rotation)
        let shown = display(layout)
        let ordered = layout.paintablePanels.sorted { (numbers[$0.panelID] ?? 0) < (numbers[$1.panelID] ?? 0) }
        return DisclosureGroup("All panels (\(ordered.count))") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(ordered) { panel in
                    let selected = selection.contains(panel.panelID)
                    Button { toggle(panel.panelID) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selected ? "checkmark.square.fill" : "square")
                            Text("Panel \(numbers[panel.panelID] ?? 0)").frame(minWidth: 64, alignment: .leading)
                            Text(panel.kind.displayName).foregroundStyle(Lumen.meter)
                            Spacer(minLength: 4)
                            if let color = shown.colors[panel.panelID] {
                                RoundedRectangle(cornerRadius: 2).fill(color.swiftUIColor).frame(width: 18, height: 14)
                                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Lumen.rule, lineWidth: 1))
                                Text(color.hexString).font(.caption.monospaced()).foregroundStyle(Lumen.meter)
                            } else {
                                Text("Unknown").font(.caption).foregroundStyle(Lumen.meter)
                            }
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Panel \(numbers[panel.panelID] ?? 0), \(panel.kind.displayName)")
                    .accessibilityValue(shown.colors[panel.panelID].map { NanoleafPanelColor(rgb: $0).spokenDescription } ?? "colour unknown")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.top, 6)
        }
    }

    // MARK: Designs

    private func designsSection(_ layout: NanoleafLayout) -> some View {
        let saved = shapes.savedDesigns(for: deviceID)
        let storable = session?.draft ?? shapes.designs[deviceID]
        return VStack(alignment: .leading, spacing: 10) {
            Text("Designs").font(.headline)
            HStack(spacing: 8) {
                Button("Save in LumenDesk\u{2026}") { designName = ""; namingDesign = true }
                    .disabled(storable == nil)
                Button("Store on the controller\u{2026}") { storeName = ""; storing = true }
                    .disabled(storable == nil || manager.isDemoMode || storeBusy)
            }
            .buttonStyle(LumenSecondaryButtonStyle(compact: true))
            Text("Saved designs stay in LumenDesk. Storing writes a static scene to the controller so it works without LumenDesk; an existing scene is never replaced without asking.")
                .font(.caption).foregroundStyle(Lumen.meter)
                .fixedSize(horizontal: false, vertical: true)
            if storeBusy { ProgressView().controlSize(.small) }
            ForEach(saved) { item in
                let reconciliation = item.design.reconciliation(against: layout)
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.callout)
                        Text(reconciliation.summary ?? item.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(reconciliation.isExact ? Lumen.meter : Lumen.warn)
                    }
                    Spacer(minLength: 4)
                    Button("Apply") { manager.applyShapesDesign(item.design, to: device) }
                        .disabled(runningShow != nil)
                    Button("Edit") {
                        if session != nil {
                            shapes.edit(deviceID) { $0.replaceDraft(item.design) }
                        } else {
                            shapes.beginSession(deviceID, origin: .savedDesign(item.name), design: item.design)
                        }
                    }
                    .disabled(runningShow != nil)
                    Menu {
                        Button("Delete \u{201C}\(item.name)\u{201D}", role: .destructive) { shapes.deleteSavedDesign(item.id) }
                    } label: { Image(systemName: "ellipsis").accessibilityLabel("More for \(item.name)") }
                    .fixedSize()
                }
                .buttonStyle(LumenSecondaryButtonStyle(compact: true))
            }
        }
        .alert("Save design in LumenDesk", isPresented: $namingDesign) {
            TextField("Design name", text: $designName)
            Button("Save") {
                if let storable, shapes.saveDesign(storable, named: designName, for: deviceID) != nil {
                    studioMessage = "Saved \u{201C}\(designName.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}."
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Store on the controller", isPresented: $storing) {
            TextField("Scene name", text: $storeName)
            Button("Store") { store(storable, overwrite: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves this design as a static scene on the Shapes controller.")
        }
        .confirmationDialog("A scene called \u{201C}\(storeName)\u{201D} is already on the controller.",
                            isPresented: $storeConflict, titleVisibility: .visible) {
            Button("Replace it", role: .destructive) { store(storable, overwrite: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Replacing overwrites that scene on the controller. Choose another name to keep both.")
        }
    }

    // MARK: Actions

    private func display(_ layout: NanoleafLayout) -> NanoleafPanelDisplay {
        NanoleafPanelDisplay.resolve(layout: layout, output: wall.output, lastSent: wall.lastSent,
                                     draft: session?.draft, wholeWall: wholeWallRGB)
    }

    /// The colour a solid or white wall shows on every panel, before master
    /// brightness, as the canvas draws everything else.
    private var wholeWallRGB: NanoleafRGB? {
        if wall.output == .white { return .approximatingKelvin(device.kelvin) }
        return wallColor.rgb
    }

    private var wallColor: NanoleafPanelColor {
        let hsb = device.color.hsbComponents
        return NanoleafPanelColor(hue: hsb.h, saturation: hsb.s, intensity: 1)
    }

    private var whiteColor: NanoleafPanelColor { NanoleafPanelColor(rgb: .approximatingKelvin(device.kelvin)) }

    private func panelColor(_ color: Color) -> NanoleafPanelColor {
        let rgb = color.rgbComponents
        func byte(_ value: Double) -> UInt8 { UInt8(min(255, max(0, (value * 255).rounded()))) }
        return NanoleafPanelColor(rgb: NanoleafRGB(red: byte(rgb.r), green: byte(rgb.g), blue: byte(rgb.b)))
    }

    private func targetIDs(_ layout: NanoleafLayout) -> Set<Int> {
        let selected = selection.intersection(layout.paintableIDs)
        return selected.isEmpty ? layout.paintableIDs : selected
    }

    private func toggle(_ id: Int) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        cursor = id
    }

    private func moveCursor(_ direction: NanoleafDirection, in layout: NanoleafLayout) {
        let start = cursor ?? layout.spatialPositions(rotationDegrees: rotation, axis: .leftToRight).first?.panelID
        guard let start else { return }
        let next = cursor == nil ? start : (layout.neighbor(of: start, toward: direction, rotationDegrees: rotation) ?? start)
        cursor = next
        selection = [next]
    }

    private func identifySelection(_ layout: NanoleafLayout) {
        let numbers = layout.panelNumbers(rotationDegrees: rotation)
        guard let id = (cursor.flatMap { selection.contains($0) ? $0 : nil })
                ?? selection.min(by: { (numbers[$0] ?? 0) < (numbers[$1] ?? 0) }) else {
            studioMessage = "Select a panel to identify it on the wall."
            return
        }
        shapes.identifyPanel(id, on: deviceID)
    }

    private func edit(_ change: @escaping (inout NanoleafEditingSession) -> Void) {
        shapes.edit(deviceID, change)
    }

    private func sessionLine(_ session: NanoleafEditingSession) -> String {
        let origin: String
        switch session.origin {
        case .appliedDesign: origin = "Editing the design on the wall"
        case .uniform: origin = "Started from one colour"
        case .savedDesign(let name): origin = "Started from \u{201C}\(name)\u{201D}"
        case .controllerScene(let name): origin = "Started from the controller scene \u{201C}\(name)\u{201D}"
        }
        let state = session.hasUnappliedChanges ? "changes not applied" : "matches what was applied"
        return "\(origin) \u{00B7} \(state)\(isPreviewing ? " \u{00B7} previewing on the wall" : "")"
    }

    private func averageIntensity(_ targets: Set<Int>, in session: NanoleafEditingSession) -> Double {
        let values = targets.compactMap { session.draft[$0]?.intensity }
        return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private func startUniform(_ color: NanoleafPanelColor, origin: NanoleafPanelColor) {
        guard let layout = wall.arrangement?.layout else { return }
        shapes.beginSession(deviceID, origin: .uniform(origin), design: .uniform(color, panelIDs: layout.paintableIDs))
    }

    private func startFromScene(_ colors: [Int: NanoleafRGB], name: String) {
        let design = NanoleafDesignBuilder.design(staticColors: colors)
        if session != nil {
            shapes.edit(deviceID) { $0.replaceDraft(design) }
        } else {
            shapes.beginSession(deviceID, origin: .controllerScene(name), design: design)
        }
        if let layout = wall.arrangement?.layout {
            studioMessage = design.reconciliation(against: layout).summary
        }
    }

    private func recolor(_ color: NanoleafPanelColor, layout: NanoleafLayout) {
        let targets = targetIDs(layout)
        shapes.edit(deviceID) { $0.edit { $0.recolor(color, panels: targets) } }
    }

    /// A colour panel sends a change per movement. The whole drag is one
    /// undo step: it ends after the picker has been still for a moment.
    private func recolorContinuously(_ color: NanoleafPanelColor, layout: NanoleafLayout) {
        let targets = targetIDs(layout)
        shapes.edit(deviceID) { session in
            session.beginContinuousEdit()
            session.edit { $0.recolor(color, panels: targets) }
        }
        colorEditEnd?.cancel()
        colorEditEnd = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            shapes.edit(deviceID) { $0.endContinuousEdit() }
        }
    }

    private func paintHex(_ layout: NanoleafLayout) {
        guard let color = NanoleafPanelColor(hex: hexDraft) else {
            hexProblem = "Enter six hex digits, like #FF6A2B."
            return
        }
        hexProblem = nil
        let targets = targetIDs(layout)
        // Exact: the panel is sent these bytes, intensity included.
        shapes.edit(deviceID) { $0.edit { $0.paint(color, panels: targets) } }
    }

    private func fill(_ theme: LightingTheme, layout: NanoleafLayout, targets: Set<Int>) {
        let plan = ThemePlanner.plan(theme, fixtures: [ThemeFixture(id: deviceID, capability: .panels(count: targets.count),
                                                                     kelvin: device.kelvin)])
        guard let tones = plan.fixtures.first?.panels, !tones.isEmpty else { return }
        let colors = NanoleafDesignBuilder.colors(tones: tones.map { (hue: $0.hue, saturation: $0.saturation, level: $0.level) },
                                                  panels: targets, layout: layout, rotationDegrees: rotation)
        shapes.edit(deviceID) { session in
            session.edit { draft in for (id, color) in colors { draft.paint(color, panels: [id]) } }
        }
    }

    private func applyDraft(_ session: NanoleafEditingSession) {
        manager.applyShapesDesign(session.draft, to: device)
        shapes.markApplied(deviceID)
        studioMessage = manager.isDemoMode ? "Applied to the simulated wall." : "Applied. The wall confirms it on its next reading."
    }

    private func store(_ design: NanoleafPanelDesign?, overwrite: Bool) {
        guard let design else { return }
        let name = storeName
        storeBusy = true
        Task { @MainActor in
            defer { storeBusy = false }
            do {
                let verified = try await shapes.saveToController(design, as: name, on: deviceID, allowOverwrite: overwrite)
                studioMessage = verified
                    ? "Stored \u{201C}\(name)\u{201D} on the controller and read it back."
                    : "Stored \u{201C}\(name)\u{201D}, but reading it back did not match. Check it in the Nanoleaf app."
            } catch NanoleafError.nameConflict {
                storeConflict = true
            } catch {
                studioMessage = (error as? NanoleafError ?? .unavailable).localizedDescription
            }
        }
    }
}

extension View {
    /// Arrow-key panel navigation; only macOS routes move commands.
    func onMoveCompat(perform action: @escaping (NanoleafDirection) -> Void) -> some View {
        #if os(macOS)
        return onMoveCommand { direction in
            switch direction {
            case .up: action(.up)
            case .down: action(.down)
            case .left: action(.left)
            case .right: action(.right)
            @unknown default: break
            }
        }
        #else
        return self
        #endif
    }
}
