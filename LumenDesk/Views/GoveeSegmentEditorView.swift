import SwiftUI

/// Hardware-aware color studio for Govee RGBIC devices. Strip-like fixtures
/// expose paintable segments; fixed fixtures such as H60B0 expose their named
/// physical lighting zones.
///
/// Editing streams live to the light over the razer LAN command (volatile, so
/// closing without applying is a true cancel). Apply either writes a static
/// device layout or holds the frame through streaming, depending on the model.
struct GoveeSegmentEditorView: View {
    @EnvironmentObject var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var device: LightDevice

    @State private var draft = GoveeSegmentState(colors: [])
    @State private var openingState: GoveeSegmentState?
    @State private var selection: Set<Int> = []
    @State private var paintColor: Color = .white
    @State private var blendEndColor: Color = Color(hue: 0.62, saturation: 1, brightness: 1)
    @State private var livePreview = true
    @State private var savingPreset = false
    @State private var presetName = ""
    @State private var loaded = false
    @State private var dragTargetSelected: Bool?

    private var profile: GoveeSegmentProfile { manager.segmentStudioProfile(for: device) ?? .generic }
    private var layout: GoveeSegmentLayout { profile.layout }
    private var isUplighter: Bool { layout == .lamp && profile.hasFixedSegmentCount }
    private var isStringLights: Bool { layout == .stringLights }
    private var isCurtain: Bool { layout == .curtain }
    private var studioName: String {
        switch layout {
        case .lamp where isUplighter: return "Uplighter Color Studio"
        case .stringLights: return "String Light Studio"
        case .curtain: return "Curtain Column Studio"
        default: return "Segment Studio"
        }
    }
    private var unitName: String { profile.editorUnitName }

    /// Paint operations target the selection, or the whole strip when nothing
    /// is selected.
    private var targetIndexes: [Int] {
        selection.isEmpty ? Array(0..<draft.segmentCount) : selection.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            subtitle
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    stripSection
                    selectionToolbar
                    paintSection
                    brightnessSection
                    if profile.supportsGradient { gradientSection }
                    presetSection
                    setupSection
                }
                .padding(.vertical, 2)
            }
            footer
        }
        .padding(20)
        .sheetFrame(minWidth: 600, idealWidth: 700, minHeight: 560, idealHeight: 660)
        .background(LumenBackground(glow: false))
        .onAppear(perform: load)
        .onDisappear {
            manager.endSegmentPreview(device)
            manager.storeSegmentState(draft, for: device)
        }
    }

    // MARK: - Header & captions

    private var header: some View {
        HStack {
            Label("\(studioName) — \(device.label)", systemImage: layout.icon)
                .font(.title3.weight(.semibold))
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(layout.displayName) · \(device.sku ?? "Model not reported") · \(draft.segmentCount) \(unitName)\(draft.segmentCount == 1 ? "" : "s")")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !profile.recognized {
                Label("This model isn't in the segment catalog. Set the segment count below to match what the Govee Home app shows; non-RGBIC devices ignore segment commands.",
                      systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(Lumen.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if manager.isDemoMode {
                Label("Demo mode: the layout is saved and simulated, no packets are sent.", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Strip

    private var stripSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            stripView
            Text(selectionCaption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var selectionCaption: String {
        if selection.isEmpty {
            switch layout {
            case .lamp where isUplighter:
                return "Choose one or more lighting zones. With nothing selected, painting updates all three lamps."
            case .stringLights:
                return "Choose individual \(unitName)s along the strand. With nothing selected, painting updates the whole string."
            case .curtain:
                return "Choose one or more vertical columns. With nothing selected, painting updates the whole curtain."
            default:
                return "Tap or drag across segments to select them. With nothing selected, painting fills the whole strip."
            }
        }
        return "\(selection.count) \(unitName)\(selection.count == 1 ? "" : "s") selected — colors and brightness apply to the selection."
    }

    @ViewBuilder
    private var stripView: some View {
        if isUplighter {
            uplighterZoneView
        } else if isStringLights {
            stringLightView
        } else if isCurtain {
            curtainColumnView
        } else {
            GeometryReader { geo in
                let count = max(1, draft.segmentCount)
                let spacing: CGFloat = 2
                let cellWidth = max(4, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
                ZStack {
                    HStack(spacing: spacing) {
                        ForEach(0..<count, id: \.self) { index in
                            segmentCell(index: index, width: cellWidth)
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(dragSelectGesture(width: geo.size.width, count: count))
            }
            .frame(height: 56)
            .accessibilityLabel("Segment strip, \(draft.segmentCount) segments")
        }
    }

    private var stringLightRows: [[Int]] {
        let rowCapacity = profile.stringLightStyle?.unitsPerEditorRow ?? 15
        return stride(from: 0, to: draft.segmentCount, by: rowCapacity).enumerated().map { row, start in
            let indexes = Array(start..<min(start + rowCapacity, draft.segmentCount))
            return row.isMultiple(of: 2) ? indexes : Array(indexes.reversed())
        }
    }

    private var stringLightView: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(stringLightRows.enumerated()), id: \.offset) { _, indexes in
                let range = indexes.sorted()
                HStack(spacing: 8) {
                    Text("\((range.first ?? 0) + 1)–\((range.last ?? 0) + 1)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 44, alignment: .trailing)
                    ZStack {
                        Capsule()
                            .fill(Lumen.hairlineStrong)
                            .frame(height: 2)
                        HStack(spacing: profile.stringLightStyle == .bead ? 4 : 7) {
                            ForEach(indexes, id: \.self) { index in
                                stringLightUnit(index)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity,
                           minHeight: profile.stringLightStyle == .bead ? 22 : 32)
                }
            }
        }
        .padding(10)
        .background(Lumen.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Lumen.hairline, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("String light with \(draft.segmentCount) \(unitName)s")
    }

    private func stringLightUnit(_ index: Int) -> some View {
        let isSelected = selection.contains(index)
        return Button {
            toggleSelection(index)
        } label: {
            Group {
                if profile.stringLightStyle == .bead {
                    Circle()
                        .fill(color(at: index))
                        .frame(width: isSelected ? 15 : 11, height: isSelected ? 15 : 11)
                        .shadow(color: color(at: index).opacity(0.7), radius: 3)
                } else {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: isSelected ? 25 : 21, weight: .medium))
                        .foregroundStyle(color(at: index))
                        .shadow(color: color(at: index).opacity(0.55), radius: 3)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 28)
            .overlay(Circle().stroke(isSelected ? Color.accentColor : Color.clear,
                                     lineWidth: isSelected ? 2 : 0))
            .animation(.spring(duration: 0.15), value: isSelected)
        }
        .buttonStyle(.plain)
        .help("\(unitName.capitalized) \(index + 1)")
        .accessibilityLabel("\(unitName.capitalized) \(index + 1)")
        .accessibilityValue(isSelected ? "selected" : "not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var curtainColumnView: some View {
        HStack(alignment: .top, spacing: 5) {
            ForEach(0..<draft.segmentCount, id: \.self) { index in
                let isSelected = selection.contains(index)
                Button {
                    toggleSelection(index)
                } label: {
                    VStack(spacing: 3) {
                        ForEach(0..<10, id: \.self) { _ in
                            Circle()
                                .fill(color(at: index))
                                .frame(width: 8, height: 8)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(color(at: index).opacity(0.07), in: Capsule())
                    .overlay(Capsule().stroke(isSelected ? Color.accentColor : Lumen.hairline,
                                              lineWidth: isSelected ? 2 : 0.5))
                }
                .buttonStyle(.plain)
                .help("Curtain column \(index + 1)")
                .accessibilityLabel("Curtain column \(index + 1)")
                .accessibilityValue(isSelected ? "selected" : "not selected")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(10)
        .background(Lumen.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Lumen.hairline, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Curtain with \(draft.segmentCount) editable columns")
    }

    private var uplighterZoneView: some View {
        VStack(spacing: 8) {
            ForEach(0..<min(profile.zoneNames.count, draft.segmentCount), id: \.self) { index in
                Button {
                    toggleSelection(index)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: uplighterZoneIcon(index))
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(color(at: index))
                            .frame(width: 32, height: 32)
                            .background(color(at: index).opacity(0.16), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.zoneNames[index])
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(uplighterZoneDetail(index))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        RoundedRectangle(cornerRadius: 5)
                            .fill(cellFill(index))
                            .frame(width: 72, height: 30)
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(selection.contains(index) ? Color.accentColor : Lumen.hairlineStrong,
                                            lineWidth: selection.contains(index) ? 2 : 0.5)
                            }
                        Image(systemName: selection.contains(index) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selection.contains(index) ? Color.accentColor : Color.secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                    .background(color(at: index).opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(selection.contains(index) ? Color.accentColor : Lumen.hairline,
                                    lineWidth: selection.contains(index) ? 2 : 0.5)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(profile.zoneNames[index]), \(selection.contains(index) ? "selected" : "not selected")")
                .accessibilityAddTraits(selection.contains(index) ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Uplighter lighting zones")
    }

    private func uplighterZoneDetail(_ index: Int) -> String {
        switch index {
        case 0: return "Ripple wall-washing light"
        case 1: return "Room ambience"
        default: return "Focused daily illumination"
        }
    }

    private func uplighterZoneIcon(_ index: Int) -> String {
        switch index {
        case 0: return "water.waves"
        case 1: return "circle.dotted.circle.fill"
        default: return "lightbulb.fill"
        }
    }

    @ViewBuilder
    private func segmentCell(index: Int, width: CGFloat) -> some View {
        let isSelected = selection.contains(index)
        RoundedRectangle(cornerRadius: 3)
            .fill(cellFill(index))
            .frame(height: 44)
            .overlay(RoundedRectangle(cornerRadius: 3)
                .stroke(isSelected ? Color.accentColor : Lumen.hairline,
                        lineWidth: isSelected ? 2.5 : 0.5))
        .scaleEffect(isSelected ? 1.05 : 1)
        .animation(.spring(duration: 0.15), value: isSelected)
        .accessibilityElement()
        .accessibilityLabel("\(unitName.capitalized) \(index + 1)")
        .accessibilityValue(isSelected ? "selected" : "not selected")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggleSelection(index) }
    }

    private func color(at index: Int) -> Color {
        guard draft.colors.indices.contains(index) else { return .white }
        return draft.colors[index].litColor
    }

    /// COB cells preview gradient blending by easing each cell's edges toward
    /// its neighbors, approximating what the diffuser does.
    private func cellFill(_ index: Int) -> LinearGradient {
        let current = draft.colors.indices.contains(index) ? draft.colors[index] : GoveeSegmentColor(hex: 0xFFFFFF)
        guard draft.gradient, draft.segmentCount > 1 else {
            return LinearGradient(colors: [current.litColor, current.litColor], startPoint: .leading, endPoint: .trailing)
        }
        let previous = draft.colors.indices.contains(index - 1) ? draft.colors[index - 1] : current
        let next = draft.colors.indices.contains(index + 1) ? draft.colors[index + 1] : current
        return LinearGradient(colors: [GoveeSegmentColor.interpolate(previous, current, fraction: 0.5).litColor,
                                       current.litColor,
                                       GoveeSegmentColor.interpolate(current, next, fraction: 0.5).litColor],
                              startPoint: .leading, endPoint: .trailing)
    }

    /// One gesture covers both tap-to-toggle and sweep-to-select: the first
    /// touched segment decides whether the sweep selects or deselects.
    private func dragSelectGesture(width: CGFloat, count: Int) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let stride = width / CGFloat(count)
                guard stride > 0 else { return }
                let index = min(count - 1, max(0, Int(value.location.x / stride)))
                if dragTargetSelected == nil {
                    dragTargetSelected = !selection.contains(index)
                }
                if dragTargetSelected == true { selection.insert(index) } else { selection.remove(index) }
            }
            .onEnded { _ in dragTargetSelected = nil }
    }

    private func toggleSelection(_ index: Int) {
        if selection.contains(index) { selection.remove(index) } else { selection.insert(index) }
    }

    // MARK: - Selection tools

    private var selectionToolbar: some View {
        HStack(spacing: 8) {
            Button("All") { selection = Set(0..<draft.segmentCount) }
            Button("None") { selection = [] }
            Button("Invert") { selection = Set((0..<draft.segmentCount).filter { !selection.contains($0) }) }
            if !isUplighter {
                Button("Every Other") { selection = Set(stride(from: 0, to: draft.segmentCount, by: 2)) }
            }
            Spacer()
            if !isUplighter {
                Button {
                    rotate(by: 1)
                } label: {
                    Image(systemName: "arrow.left")
                }
                .help("Shift all colors one segment left")
                .accessibilityLabel("Shift colors left")
                Button {
                    rotate(by: -1)
                } label: {
                    Image(systemName: "arrow.right")
                }
                .help("Shift all colors one segment right")
                .accessibilityLabel("Shift colors right")
            }
        }
        .controlSize(.small)
    }

    // MARK: - Paint tools

    private var paintSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paint").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(LightRowView.colorSwatches, id: \.label) { swatch in
                    Button {
                        paintColor = swatch.color
                        paintTargets(with: swatch.color)
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .frame(width: 20, height: 20)
                            .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help(swatch.label)
                    .accessibilityLabel("Paint \(swatch.label)")
                }
                ForEach(manager.recentColors) { recent in
                    Button {
                        paintColor = recent.color
                        paintTargets(with: recent.color)
                    } label: {
                        Circle()
                            .fill(recent.color)
                            .frame(width: 20, height: 20)
                            .overlay(Circle().stroke(Lumen.hairlineStrong, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help("\(recent.name) · \(recent.hex)")
                    .accessibilityLabel("Paint recent color \(recent.name)")
                }
                Spacer(minLength: 0)
                ColorPicker("", selection: $paintColor, supportsOpacity: false)
                    .labelsHidden()
                    .onChange(of: paintColor) { newValue in paintTargets(with: newValue) }
                    .accessibilityLabel("Paint color")
            }
            HStack(spacing: 8) {
                Button("Blend Across Selection", action: blendAcrossSelection)
                    .controlSize(.small)
                    .disabled(targetIndexes.count < 2)
                    .help("Fades from the paint color to the end color across the selected \(unitName)s")
                ColorPicker("", selection: $blendEndColor, supportsOpacity: false)
                    .labelsHidden()
                    .accessibilityLabel("Blend end color")
                Text("→ end color").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
            }
        }
    }

    private var brightnessSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.min").foregroundStyle(.secondary).accessibilityHidden(true)
            Slider(value: selectionBrightness, in: 0.05...1, onEditingChanged: { editing in
                if !editing { manager.storeSegmentState(draft, for: device) }
            })
            .accessibilityLabel("Brightness for \(selection.isEmpty ? "all \(unitName)s" : "selected \(unitName)s")")
            .accessibilityValue("\(Int(selectionBrightness.wrappedValue * 100)) percent")
            Image(systemName: "sun.max").foregroundStyle(.secondary).accessibilityHidden(true)
            Text("\(Int(selectionBrightness.wrappedValue * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }

    private var gradientSection: some View {
        Toggle(isOn: gradientBinding) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Blend colors between segments")
                Text("Melts neighboring segment colors into each other, like the Govee app's gradient switch.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .toggleStyle(.switch)
        .tint(Lumen.pink)
    }

    // MARK: - Presets

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Presets").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(savingPreset ? "Cancel" : "Save Current…") {
                    savingPreset.toggle()
                    presetName = ""
                }
                .controlSize(.small)
            }
            if savingPreset {
                HStack {
                    TextField("Preset name", text: $presetName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(savePreset)
                    Button("Save", action: savePreset)
                        .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(manager.goveeSegmentPresets) { preset in
                        presetChip(preset, custom: true)
                    }
                    ForEach(GoveeSegmentPreset.builtIns) { preset in
                        presetChip(preset, custom: false)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func presetChip(_ preset: GoveeSegmentPreset, custom: Bool) -> some View {
        Button {
            applyPreset(preset)
        } label: {
            VStack(spacing: 4) {
                SegmentMiniStripView(colors: preset.colors(for: 12).map(\.color))
                    .frame(width: 76, height: 14)
                HStack(spacing: 3) {
                    if custom {
                        Image(systemName: "person.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    Text(preset.name).font(.caption2).lineLimit(1)
                }
            }
            .padding(7)
            .background(Lumen.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Lumen.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(custom ? "\(preset.name) (saved preset)" : preset.name)
        .accessibilityLabel("Apply preset \(preset.name)")
        .contextMenu {
            if custom {
                Button("Delete Preset", role: .destructive) { manager.deleteSegmentPreset(preset.id) }
            }
        }
    }

    // MARK: - Setup (segment count, live preview)

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if profile.hasFixedSegmentCount {
                Label(fixedTopologyTitle, systemImage: layout.icon)
                    .font(.callout.weight(.medium))
                Text(fixedTopologyDetail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                HStack {
                    Stepper("\(unitName.capitalized)s: \(draft.segmentCount)",
                            value: segmentCountBinding,
                            in: 2...profile.maximumEditorSegmentCount)
                        .frame(maxWidth: 220)
                    if let detected = manager.segmentProfile(for: device),
                       draft.segmentCount != detected.defaultSegmentCount {
                        Button("Reset to \(detected.defaultSegmentCount)") {
                            segmentCountBinding.wrappedValue = detected.defaultSegmentCount
                        }
                        .controlSize(.small)
                    }
                    Spacer()
                }
                Text("Match the \(unitName) count the Govee Home app shows for this light.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Toggle("Live preview on the light while editing", isOn: $livePreview)
                .toggleStyle(.switch)
                .tint(Lumen.pink)
                .disabled(manager.isDemoMode)
                .onChange(of: livePreview) { enabled in
                    if enabled {
                        manager.previewSegments(device, state: draft)
                    } else {
                        manager.endSegmentPreview(device)
                    }
                }
        }
    }

    private var fixedTopologyTitle: String {
        switch layout {
        case .lamp: return "Three fixed hardware lighting zones"
        case .stringLights: return "\(profile.defaultSegmentCount) individually addressable \(unitName)s"
        case .curtain: return "\(profile.defaultSegmentCount) LAN-addressable curtain columns"
        default: return "Fixed \(profile.defaultSegmentCount)-\(unitName) hardware topology"
        }
    }

    private var fixedTopologyDetail: String {
        switch layout {
        case .lamp:
            return "Upper Ripple, Middle Ambient, and Lower Daily Illumination match the physical H60B0 lamps."
        case .stringLights:
            return "Each numbered \(unitName) maps to its physical position along the strand, starting at the controller."
        case .curtain:
            return "Each control maps to one vertical strand group. Per-bead curtain artwork remains in Govee Home."
        default:
            return "The editor count follows this fixture's physical hardware and cannot be resized."
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text(profile.appliesViaStream
                     ? "This light family can't store the edited layout in its own firmware, so Apply holds it from LumenDesk and restores it automatically while LumenDesk is running."
                     : "Live preview is temporary. Apply pauses the preview and writes the layout to the light so it survives power cycles; editing again resumes the preview.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Revert") { revert() }
                    .disabled(openingState == nil || openingState == draft)
                Button("Apply to Light") { applyToLight() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Bindings

    private var selectionBrightness: Binding<Double> {
        Binding(
            get: {
                let targets = targetIndexes.filter { draft.colors.indices.contains($0) }
                guard !targets.isEmpty else { return 1 }
                return targets.map { draft.colors[$0].brightness }.reduce(0, +) / Double(targets.count)
            },
            set: { newValue in
                updateDraft(persist: false) { state in
                    for index in targetIndexes where state.colors.indices.contains(index) {
                        state.colors[index].brightness = newValue
                    }
                }
            }
        )
    }

    private var gradientBinding: Binding<Bool> {
        Binding(get: { draft.gradient },
                set: { newValue in updateDraft { $0.gradient = newValue } })
    }

    private var segmentCountBinding: Binding<Int> {
        Binding(get: { draft.segmentCount },
                set: { newValue in
                    updateDraft { $0.resize(to: max(2, min(profile.maximumEditorSegmentCount, newValue))) }
                    selection = Set(selection.filter { $0 < draft.segmentCount })
                })
    }

    // MARK: - Actions

    private func load() {
        guard !loaded else { return }
        loaded = true
        var state = manager.segmentState(for: device)
        if profile.hasFixedSegmentCount {
            state.resize(to: profile.defaultSegmentCount)
        } else if state.segmentCount < 2 {
            state.resize(to: profile.defaultSegmentCount)
        }
        draft = state
        openingState = state
        paintColor = device.color
    }

    /// Central mutation point: every edit optionally persists the draft and
    /// streams a live frame to the light.
    private func updateDraft(persist: Bool = true, _ mutate: (inout GoveeSegmentState) -> Void) {
        mutate(&draft)
        if livePreview { manager.previewSegments(device, state: draft) }
        if persist { manager.storeSegmentState(draft, for: device) }
    }

    private func paintTargets(with color: Color) {
        updateDraft { state in
            for index in targetIndexes where state.colors.indices.contains(index) {
                let brightness = state.colors[index].brightness
                state.colors[index] = GoveeSegmentColor(color: color, brightness: brightness)
            }
        }
    }

    private func blendAcrossSelection() {
        let targets = targetIndexes
        guard targets.count >= 2 else { return }
        let start = GoveeSegmentColor(color: paintColor)
        let end = GoveeSegmentColor(color: blendEndColor)
        updateDraft { state in
            for (offset, index) in targets.enumerated() where state.colors.indices.contains(index) {
                let fraction = Double(offset) / Double(targets.count - 1)
                let blended = GoveeSegmentColor.interpolate(start, end, fraction: fraction)
                state.colors[index] = GoveeSegmentColor(red: blended.red, green: blended.green, blue: blended.blue,
                                                        brightness: state.colors[index].brightness)
            }
        }
    }

    private func rotate(by offset: Int) {
        updateDraft { state in
            let n = state.colors.count
            guard n > 1 else { return }
            let shift = ((offset % n) + n) % n
            state.colors = Array(state.colors[shift...] + state.colors[..<shift])
        }
    }

    private func applyPreset(_ preset: GoveeSegmentPreset) {
        updateDraft { state in
            state.colors = preset.colors(for: state.segmentCount)
        }
    }

    private func savePreset() {
        let trimmed = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        manager.addSegmentPreset(name: trimmed, stops: draft.colors)
        savingPreset = false
        presetName = ""
    }

    private func revert() {
        guard let openingState else { return }
        updateDraft { $0 = openingState }
        selection = []
    }

    private func applyToLight() {
        manager.applySegments(device, state: draft)
        openingState = draft
    }
}

// MARK: - Mini strip preview

/// Compact horizontal swatch bar used on light rows and preset chips.
struct SegmentMiniStripView: View {
    let colors: [Color]

    private var sampled: [Color] {
        guard colors.count > 16 else { return colors }
        return (0..<16).map { colors[$0 * colors.count / 16] }
    }

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(sampled.enumerated()), id: \.offset) { _, color in
                Rectangle().fill(color)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Lumen.hairlineStrong, lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}
