import SwiftUI

/// A 26-zone editor for the LIFX SuperColor Luna. The lamp reports a 5×6
/// matrix; its four corner cells sit outside the oval diffuser and are shown
/// as empty space so the editor mirrors the physical face.
struct LIFXLunaEditorView: View {
    @EnvironmentObject var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var device: LightDevice

    @State private var draft: LIFXMatrixState?
    @State private var selection: Set<Int> = []
    @State private var paintColor: Color = .purple
    @State private var gradientEndColor: Color = .cyan
    @State private var hasEdits = false

    private var targetIndices: [Int] {
        guard let draft else { return [] }
        return selection.isEmpty ? draft.activeZoneIndices : selection.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            subtitle
            if let draft {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        matrixSection(draft)
                        selectionTools(draft)
                        paintTools
                        gradientTools
                        presetTools
                    }
                    .padding(.vertical, 2)
                }
                footer(draft)
            } else {
                loadingState
            }
        }
        .padding(20)
        .sheetFrame(minWidth: 520, idealWidth: 620, minHeight: 560, idealHeight: 680)
        .background(LumenBackground(glow: false))
        .onAppear {
            if let state = manager.lifxMatrixState(for: device) { draft = state }
            manager.refreshLIFXMatrix(device)
        }
        .onReceive(manager.$lifxMatrixStates) { states in
            guard let state = states[device.id], !hasEdits else { return }
            draft = state
            selection = selection.intersection(Set(state.activeZoneIndices))
        }
    }

    private var header: some View {
        HStack {
            Label("Luna Color Studio — \(device.label)", systemImage: "circle.grid.3x3.fill")
                .font(.title3.weight(.semibold))
            Spacer()
            Button("Done") { dismiss() }
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
                Label("Demo mode: changes are simulated; no LAN packets are sent.", systemImage: "sparkles")
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
                Text(selection.isEmpty ? "All 26 zones" : "\(selection.count) selected")
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
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Lumen.surfaceRaised)
                    .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
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
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color)
                .frame(maxWidth: .infinity, minHeight: 52)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(selected ? Color.white : Lumen.hairlineStrong,
                                lineWidth: selected ? 3 : 0.5)
                )
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                            .padding(5)
                    }
                }
                .shadow(color: color.opacity(0.5), radius: selected ? 8 : 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Luna zone \(state.activeZoneIndices.firstIndex(of: index).map { $0 + 1 } ?? index + 1)")
        .accessibilityValue(selected ? "selected" : "not selected")
    }

    // MARK: - Tools

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
            HStack(spacing: 7) {
                ForEach(LightRowView.colorSwatches, id: \.label) { swatch in
                    Button {
                        paintColor = swatch.color
                        paintTargets(swatch.color)
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(Lumen.hairlineStrong, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help(swatch.label)
                    .accessibilityLabel("Paint \(swatch.label)")
                }
                Spacer(minLength: 4)
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
            HStack(spacing: 10) {
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
            Text("Luna looks").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(LunaLook.allCases) { look in
                    Button(look.title) { apply(look) }
                        .buttonStyle(.bordered)
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
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Editing

    private func paintTargets(_ color: Color) {
        guard var next = draft else { return }
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
