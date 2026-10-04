import SwiftUI

/// A 26-zone editor for the LIFX SuperColor Luna. The lamp reports a 5×6
/// matrix; its four corner cells sit outside the oval diffuser and are shown
/// as empty space so the editor mirrors the physical face.
struct LIFXLunaEditorView: View {
    @EnvironmentObject var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var device: LightDevice
    var embedded = false
    var initialSelection: Set<Int> = []
    var initialDraft: LIFXMatrixState? = nil
    var onDraftChange: ((LIFXMatrixState?) -> Void)? = nil

    @State private var draft: LIFXMatrixState?
    @State private var selection: Set<Int> = []
    @State private var paintColor: Color = .purple
    @State private var gradientEndColor: Color = .cyan
    @State private var hasEdits = false

    private var targetIndices: [Int] {
        guard let draft else { return [] }
        return SpectrumRegionSelection.targets(selected: selection, available: Set(draft.activeZoneIndices)).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            subtitle
            if let draft {
                GeometryReader { geometry in
                    ScrollView {
                        if geometry.size.width >= 800 {
                            HStack(alignment: .top, spacing: 28) {
                                VStack(spacing: 18) { matrixSection(draft); selectionTools(draft); exactZoneValues(draft) }
                                    .frame(maxWidth: .infinity)
                                editingTools.frame(width: 320)
                            }.padding(.vertical, 2)
                        } else {
                            VStack(alignment: .leading, spacing: 20) {
                                matrixSection(draft)
                                selectionTools(draft)
                                exactZoneValues(draft)
                                editingTools
                            }.padding(.vertical, 2)
                        }
                    }
                }
                footer(draft)
            } else {
                loadingState
            }
        }
        .padding(20)
        .sheetFrame(minWidth: embedded ? nil : 520, idealWidth: embedded ? nil : 960,
                    minHeight: embedded ? nil : 560, idealHeight: embedded ? nil : 740)
        .background(LumenBackground(glow: false))
        .onAppear {
            if let state = initialDraft ?? manager.lifxMatrixState(for: device) { draft = state }
            hasEdits = initialDraft != nil
            selection = SpectrumRegionSelection.targets(selected: initialSelection, available: Set(draft?.activeZoneIndices ?? []))
            manager.refreshLIFXMatrix(device)
        }
        .onDisappear { onDraftChange?(hasEdits ? draft : nil) }
        .onReceive(manager.$lifxMatrixStates) { states in
            guard let state = states[device.id], !hasEdits else { return }
            draft = state
            selection = selection.intersection(Set(state.activeZoneIndices))
        }
    }

    private var editingTools: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(selection.isEmpty ? "Select zones to paint" : "Paint \(selection.count) selected zones").font(.headline)
            paintTools.disabled(targetIndices.isEmpty)
            gradientTools.disabled(targetIndices.isEmpty)
            DisclosureGroup("Luna looks") { presetTools.padding(.top, 12) }
            Text("These are draft colors. Apply writes them to Luna; closing leaves the lamp unchanged.")
                .font(.caption).foregroundStyle(Lumen.meter)
        }
    }

    private var header: some View {
        HStack {
            Label("Luna Color Studio — \(device.label)", systemImage: "circle.grid.3x3.fill")
                .font(LumenType.display(size: 19, weight: .bold))
            Spacer()
            if !embedded { Button("Close draft") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
    }

    private var subtitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(device.sku ?? LIFXProductCatalog.lunaSKU) · 26 individually controlled color zones")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Select zones, then paint them. With no selection, color tools affect the entire lamp.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            if manager.isDemoMode {
                Label("Demo mode: changes are simulated; no LAN packets are sent.", systemImage: "play.rectangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Reading Luna’s color zones…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Try Again") { manager.refreshLIFXMatrix(device) }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Matrix

    private func matrixSection(_ state: LIFXMatrixState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Lamp face").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(selection.count) selected")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                ForEach(0..<state.height, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(0..<state.width, id: \.self) { column in
                            let index = row * state.width + column
                            if state.containsZone(index) {
                                zoneButton(index, state: state)
                            } else {
                                Color.clear
                                    .frame(maxWidth: .infinity, minHeight: 52)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Lumen.surfaceRaised)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Lumen.hairline, lineWidth: 0.5))
            )
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        }
    }

    private func zoneButton(_ index: Int, state: LIFXMatrixState) -> some View {
        let selected = selection.contains(index)
        let color = state.colors.indices.contains(index) ? state.colors[index].color : Color.black
        return Button {
            if selected { selection.remove(index) } else { selection.insert(index) }
        } label: {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color)
                .frame(maxWidth: .infinity, minHeight: 52)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(selected ? Color.white : Lumen.hairlineStrong,
                                lineWidth: selected ? 3 : 0.5)
                )
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Lumen.stage)
                            .background(Lumen.lit, in: Circle())
                            .padding(5)
                    }
                }

        }
        .buttonStyle(.plain)
        .accessibilityLabel("Luna zone \(state.activeZoneIndices.firstIndex(of: index).map { $0 + 1 } ?? index + 1)")
        .accessibilityValue(selected ? "selected" : "not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Tools

    private func exactZoneValues(_ state: LIFXMatrixState) -> some View {
        let indices = selection.sorted().filter { state.containsZone($0) }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Selected zones · \(indices.count)").font(.headline)
            if indices.isEmpty {
                Text("Select zones to inspect their exact values.").font(.caption).foregroundStyle(Lumen.meter)
            } else {
                Text("RGB describes chroma. Each zone retains its own intensity.")
                    .font(.caption).foregroundStyle(Lumen.meter)
                ScrollView([.horizontal, .vertical]) {
                    VStack(spacing: 0) {
                        ForEach(indices, id: \.self) { index in
                            let value = state.colors[index]
                            let color = Color(hue: Double(value.hue) / 65535, saturation: Double(value.saturation) / 65535, brightness: 1)
                            SpectrumValueRow(name: "Zone \((state.activeZoneIndices.firstIndex(of: index) ?? index) + 1)", color: color,
                                             intensity: Binding(get: { Double(draft?.colors[index].brightness ?? 0) / 65535 }, set: { level in
                                guard var next = draft else { return }
                                next.colors[index] = next.colors[index].settingBrightness(level)
                                draft = next
                                hasEdits = true
                            }), state: hasEdits ? "Draft" : "Loaded") { color in
                                guard var next = draft else { return }
                                next.colors[index] = next.colors[index].painted(color, fallbackBrightness: device.brightness, kelvin: device.kelvin)
                                draft = next
                                hasEdits = true
                            }
                        }
                    }.frame(minWidth: 460)
                }.frame(height: min(250, CGFloat(indices.count) * 54))
            }
        }
    }

    private func selectionTools(_ state: LIFXMatrixState) -> some View {
        HStack(spacing: 8) {
            Button("All") { selection = Set(state.activeZoneIndices) }
            Button("None") { selection = [] }
            Button("Invert") {
                selection = Set(state.activeZoneIndices.filter { !selection.contains($0) })
            }
            Button("Every Other") {
                selection = Set(state.activeZoneIndices.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil })
            }
            Spacer()
        }
        .controlSize(.small)
    }

    private var paintTools: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paint").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 7)], spacing: 7) {
                ForEach(LightRowView.colorSwatches, id: \.label) { swatch in
                    Button {
                        paintColor = swatch.color
                        paintTargets(swatch.color)
                    } label: {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(swatch.color)
                            .frame(width: 44, height: 44)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .stroke(Lumen.hairlineStrong, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(swatch.label)
                    .accessibilityLabel("Paint \(swatch.label)")
                }
                ColorPicker("Custom", selection: Binding(
                    get: { paintColor },
                    set: { value in paintColor = value; paintTargets(value) }
                ), supportsOpacity: false)
                .labelsHidden()
                .accessibilityLabel("Custom paint color")
            }
        }
    }

    private var gradientTools: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gradient").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                ColorPicker("Start", selection: $paintColor, supportsOpacity: false)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                ColorPicker("End", selection: $gradientEndColor, supportsOpacity: false)
                Spacer()
                Button("Blend Across Zones") { blendTargets() }
            }
            .controlSize(.small)
        }
    }

    private var presetTools: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Whole-lamp looks").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104))], spacing: 8) {
                ForEach(LunaLook.allCases) { look in
                    Button(look.title) { apply(look) }
                        .buttonStyle(LumenSecondaryButtonStyle())
                        .tint(look.tint)
                }
            }
            .controlSize(.small)
        }
    }

    private func footer(_ state: LIFXMatrixState) -> some View {
        HStack {
            Button("Reload from Lamp") {
                hasEdits = false
                selection = []
                manager.refreshLIFXMatrix(device)
            }
            .disabled(manager.isDemoMode)
            Spacer()
            Button("Apply to Luna") {
                manager.applyLIFXMatrix(device, state: state)
                hasEdits = false
            }
            .buttonStyle(LumenPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Editing

    private func paintTargets(_ color: Color) {
        guard var next = draft, !targetIndices.isEmpty else { return }
        for index in targetIndices where next.colors.indices.contains(index) {
            next.colors[index] = next.colors[index].painted(
                color,
                fallbackBrightness: device.brightness,
                kelvin: device.kelvin
            )
        }
        draft = next
        hasEdits = true
    }

    private func blendTargets() {
        guard var next = draft else { return }
        let targets = targetIndices
        guard !targets.isEmpty else { return }
        for (offset, index) in targets.enumerated() {
            let fraction = targets.count == 1 ? 0 : Double(offset) / Double(targets.count - 1)
            let color = interpolate(paintColor, gradientEndColor, fraction: fraction)
            next.colors[index] = next.colors[index].painted(
                color,
                fallbackBrightness: device.brightness,
                kelvin: device.kelvin
            )
        }
        draft = next
        hasEdits = true
    }

    private func apply(_ look: LunaLook) {
        guard var next = draft else { return }
        let targets = next.activeZoneIndices
        for (offset, index) in targets.enumerated() {
            let fraction = targets.count == 1 ? 0 : Double(offset) / Double(targets.count - 1)
            let scaled = fraction * Double(look.colors.count - 1)
            let lower = min(look.colors.count - 1, Int(scaled))
            let upper = min(look.colors.count - 1, lower + 1)
            let color = interpolate(look.colors[lower], look.colors[upper], fraction: scaled - Double(lower))
            next.colors[index] = next.colors[index].painted(
                color,
                fallbackBrightness: device.brightness,
                kelvin: device.kelvin
            )
        }
        draft = next
        selection = []
        hasEdits = true
    }

    private func interpolate(_ start: Color, _ end: Color, fraction: Double) -> Color {
        let a = start.rgbComponents
        let b = end.rgbComponents
        let t = max(0, min(1, fraction))
        return Color(red: a.r + (b.r - a.r) * t,
                     green: a.g + (b.g - a.g) * t,
                     blue: a.b + (b.b - a.b) * t)
    }
}

private enum LunaLook: String, CaseIterable, Identifiable {
    case aurora, sunset, ocean, rainbow, candle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aurora: return "Aurora"
        case .sunset: return "Sunset"
        case .ocean: return "Ocean"
        case .rainbow: return "Rainbow"
        case .candle: return "Warm Glow"
        }
    }

    var colors: [Color] {
        switch self {
        case .aurora: return [.purple, .blue, .cyan, .mint]
        case .sunset: return [.purple, .pink, .orange, .yellow]
        case .ocean: return [Color(hue: 0.62, saturation: 0.9, brightness: 1), .cyan, .mint]
        case .rainbow: return [.red, .orange, .yellow, .green, .blue, .purple]
        case .candle: return [Color(red: 1, green: 0.3, blue: 0.04), Color(red: 1, green: 0.72, blue: 0.22)]
        }
    }

    var tint: Color { colors[colors.count / 2] }
}

struct LunaMiniGridView: View {
    let state: LIFXMatrixState?
    let fallback: Color

    private var layout: LIFXMatrixState {
        state ?? .demoLuna(brightness: 0.8)
    }

    var body: some View {
        VStack(spacing: 1.5) {
            ForEach(0..<layout.height, id: \.self) { row in
                HStack(spacing: 1.5) {
                    ForEach(0..<layout.width, id: \.self) { column in
                        let index = row * layout.width + column
                        if layout.containsZone(index) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(state?.colors[index].color ?? fallback)
                        } else {
                            Color.clear
                        }
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}
