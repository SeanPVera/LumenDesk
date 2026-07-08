import SwiftUI

/// Segment Studio — per-segment control for Govee RGBIC devices (COB strips,
/// string lights, neon ropes) with the same specificity as the Govee Home
/// app: paint individual segments, dim them independently, blend neighboring
/// colors on COB hardware, and save reusable multi-color presets.
///
/// Editing streams live to the light over the razer LAN command (volatile, so
/// closing without applying is a true cancel); **Apply** writes the layout
/// with the app-native Bluetooth-format commands so it survives power cycles.
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
            Label("Segment Studio — \(device.label)", systemImage: layout.icon)
                .font(.title3.weight(.semibold))
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(layout.displayName) · \(device.sku ?? "Model not reported") · \(draft.segmentCount) segments")
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
            Text(selection.isEmpty
                 ? "Tap or drag across segments to select them. With nothing selected, painting fills the whole strip."
                 : "\(selection.count) segment\(selection.count == 1 ? "" : "s") selected — colors and brightness apply to the selection.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var stripView: some View {
        GeometryReader { geo in
            let count = max(1, draft.segmentCount)
            let spacing: CGFloat = layout == .stringLights ? 6 : 2
            let cellWidth = max(4, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            ZStack {
                if layout == .stringLights {
                    Rectangle()
                        .fill(Lumen.hairlineStrong)
                        .frame(height: 2)
                }
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

    @ViewBuilder
    private func segmentCell(index: Int, width: CGFloat) -> some View {
        let isSelected = selection.contains(index)
        Group {
            if layout == .stringLights {
                Circle()
                    .fill(color(at: index))
                    .frame(width: min(width, 30), height: min(width, 30))
                    .overlay(Circle().stroke(isSelected ? Color.accentColor : Lumen.hairlineStrong,
                                             lineWidth: isSelected ? 2.5 : 0.5))
                    .frame(maxWidth: .infinity)
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(cellFill(index))
                    .frame(height: 44)
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .stroke(isSelected ? Color.accentColor : Lumen.hairline,
                                lineWidth: isSelected ? 2.5 : 0.5))
            }
        }
        .scaleEffect(isSelected ? 1.05 : 1)
        .animation(.spring(duration: 0.15), value: isSelected)
        .accessibilityElement()
        .accessibilityLabel("Segment \(index + 1)")
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
            Button("Every Other") { selection = Set(stride(from: 0, to: draft.segmentCount, by: 2)) }
            Spacer()
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
                    .help("Fades from the paint color to the end color across the selected segments")
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
            .accessibilityLabel("Brightness for \(selection.isEmpty ? "all segments" : "selected segments")")
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
            HStack {
                Stepper("Segments: \(draft.segmentCount)", value: segmentCountBinding, in: 2...GoveeProtocol.maxSegments)
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
            Text("Match the segment count the Govee Home app shows for this light.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
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

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("Live preview is temporary. Apply writes the layout to the light so it survives power cycles.")
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
                    updateDraft { $0.resize(to: max(2, min(GoveeProtocol.maxSegments, newValue))) }
                    selection = Set(selection.filter { $0 < draft.segmentCount })
                })
    }

    // MARK: - Actions

    private func load() {
        guard !loaded else { return }
        loaded = true
        var state = manager.segmentState(for: device)
        if state.segmentCount < 2 { state.resize(to: profile.defaultSegmentCount) }
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
