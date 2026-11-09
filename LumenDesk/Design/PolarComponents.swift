import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Polar Instrument shared components
//
// The reusable pieces every Polar screen is assembled from: the glowing orb
// that stands for a fixture, instrument controls (slider and dial) with SF
// Mono readouts, a segment strip for zoned fixtures, panel cards and status
// pills. None of these talk to LightManager; callers pass values and
// bindings, so the same control drives live lights, Look drafts and demos.

// MARK: Orb

/// What kind of fixture an orb stands for. Every fixture is drawn as the
/// same round, glowing orb; the kind only picks the small model glyph inside.
enum OrbSilhouette: Equatable {
    case bulb       // single emitter: LIFX colour bulbs
    case matrix     // LIFX Luna
    case strip      // COB and RGBIC tape
    case curtain    // curtain columns
    case bars       // Glide light bars
    case lamp       // multi-zone floor lamp
    case pods       // string pods
    case panels     // Nanoleaf hexagons

    /// SF Symbol drawn faintly inside the orb. Plain bulbs carry none.
    var glyph: String? {
        switch self {
        case .bulb: return nil
        case .matrix: return "circle.grid.3x3.fill"
        case .strip: return "line.3.horizontal"
        case .curtain: return "rectangle.split.3x1"
        case .bars: return "chart.bar.fill"
        case .lamp: return "lamp.floor.fill"
        case .pods: return "ellipsis"
        case .panels: return "hexagon.fill"
        }
    }
}

/// A regular, flat-topped hexagon.
struct PolarHexagon: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + w * 0.25, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.75, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.75, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.25, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

/// A fixture drawn as light: a round, lit core in the fixture's colour and a
/// soft circular glow whose reach and strength follow its level. Off
/// fixtures keep an unlit glass core so the stage still reads as a room.
///
/// The glow is built only from radial gradients inside circles (no
/// `.shadow`), so it never picks up a square edge from layer bounds.
struct GlowingOrb: View {
    var color: Color
    var level: Double
    var isOn: Bool
    var silhouette: OrbSilhouette = .bulb
    /// Diameter of the core, in points.
    var size: CGFloat = 44
    var selected: Bool = false
    var stale: Bool = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var lit: Bool { isOn && !stale }
    private var clampedLevel: Double { min(max(level, 0), 1) }

    var body: some View {
        ZStack {
            if lit {
                // Wide, faint room glow.
                Circle()
                    .fill(RadialGradient(
                        colors: [color.opacity(reduceTransparency ? 0.22 : 0.42 * (0.35 + clampedLevel * 0.65)),
                                 color.opacity(0)],
                        center: .center,
                        startRadius: size * 0.35,
                        endRadius: size * (1.25 + clampedLevel * 0.75)
                    ))
                    .frame(width: size * 4.2, height: size * 4.2)
                    .allowsHitTesting(false)
                // Tight halo hugging the core.
                Circle()
                    .fill(RadialGradient(
                        colors: [color.opacity(0.55 * (0.4 + clampedLevel * 0.6)), color.opacity(0)],
                        center: .center,
                        startRadius: size * 0.42,
                        endRadius: size * 0.9
                    ))
                    .frame(width: size * 1.8, height: size * 1.8)
                    .allowsHitTesting(false)
            }
            Circle()
                .fill(lit
                      ? AnyShapeStyle(RadialGradient(
                            colors: [color.mixed(with: .white, amount: 0.45), color,
                                     color.mixed(with: .black, amount: 0.12)],
                            center: UnitPoint(x: 0.38, y: 0.32),
                            startRadius: 0,
                            endRadius: size * 0.7))
                      : AnyShapeStyle(Polar.raised))
                .overlay(Circle().stroke(Color.white.opacity(lit ? 0.18 : 0.10), lineWidth: 1))
                .frame(width: size, height: size)
                .opacity(lit ? 0.6 + clampedLevel * 0.4 : 1)
            if let glyph = silhouette.glyph, size >= 26 {
                Image(systemName: glyph)
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(lit ? Color.black.opacity(0.30) : Polar.meter.opacity(0.55))
            }
            if selected {
                Circle()
                    .stroke(Polar.select.opacity(0.28), lineWidth: 6)
                    .frame(width: size + 16, height: size + 16)
                Circle()
                    .stroke(Polar.select, lineWidth: 2)
                    .frame(width: size + 10, height: size + 10)
            }
        }
        .frame(width: size + 18, height: size + 18)
        .accessibilityHidden(true)
    }
}

extension Color {
    /// Linear sRGB mix, used for highlights on lit surfaces.
    func mixed(with other: Color, amount: Double) -> Color {
        let a = self.rgbComponents
        let b = other.rgbComponents
        let t = min(max(amount, 0), 1)
        return Color(.sRGB,
                     red: a.r + (b.r - a.r) * t,
                     green: a.g + (b.g - a.g) * t,
                     blue: a.b + (b.b - a.b) * t,
                     opacity: 1)
    }

}

// MARK: Panel cards

/// The Polar card: desk fill, a soft rule and generous radius. `glow` lays a
/// faint coloured halo under hero panels that show a lit fixture.
struct PolarPanelModifier: ViewModifier {
    var fill: Color = Polar.desk
    var radius: CGFloat = Polar.radiusPanel
    var glow: Color? = nil
    var padding: CGFloat? = PolarSpacing.md

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .padding(padding ?? 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(fill))
            .overlay(shape.stroke(Polar.rule.opacity(0.9), lineWidth: 1))
            .shadow(color: (glow ?? .clear).opacity(0.28), radius: 26)
    }
}

extension View {
    func polarPanel(fill: Color = Polar.desk, radius: CGFloat = Polar.radiusPanel,
                    glow: Color? = nil, padding: CGFloat? = PolarSpacing.md) -> some View {
        modifier(PolarPanelModifier(fill: fill, radius: radius, glow: glow, padding: padding))
    }
}

/// Uppercase section caption: "ROOMS", "SELECTION", "CURTAIN · 20 COLUMNS".
struct PolarSectionLabel: View {
    let text: String
    var color: Color = Polar.meter

    init(_ text: String, color: Color = Polar.meter) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.polarCaption)
            .tracking(1.1)
            .foregroundStyle(color)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Status pill: symbol + word + colour, never colour alone.
struct PolarStatusPill: View {
    let title: String
    let symbol: String
    let color: Color

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.polarUI(12, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.55), lineWidth: 1))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Status: \(title)")
    }
}

// MARK: Buttons

/// Polar keys. `.prominent` is the electric-blue primary, `.quiet` a raised
/// well, `.selected` the blue-tinted state used by segmented choices.
struct PolarButtonStyle: ButtonStyle {
    enum Kind { case prominent, quiet, selected, danger }
    var kind: Kind = .quiet
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        PolarButtonFace(configuration: configuration, kind: kind, compact: compact)
    }
}

private struct PolarButtonFace: View {
    let configuration: ButtonStyle.Configuration
    let kind: PolarButtonStyle.Kind
    let compact: Bool
    @Environment(\.isEnabled) private var isEnabled

    private var fill: Color {
        switch kind {
        case .prominent: return Polar.accent
        case .quiet: return Polar.raised
        case .selected: return Polar.accent.opacity(0.22)
        case .danger: return Polar.attention.opacity(0.14)
        }
    }

    private var legend: Color {
        switch kind {
        case .prominent: return Color.white
        case .quiet: return Polar.chalk
        case .selected: return Polar.select
        case .danger: return Polar.attention
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
        configuration.label
            .font(.polarUI(compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(legend)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 5 : 8)
            .frame(minHeight: compact ? 26 : 32)
            .background(shape.fill(fill.opacity(configuration.isPressed ? 0.75 : 1)))
            .overlay(shape.stroke(kind == .selected ? Polar.accent : Color.white.opacity(0.06), lineWidth: 1))
            .shadow(color: kind == .prominent ? Polar.accent.opacity(0.35) : .clear, radius: 10)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(shape)
    }
}

// MARK: Instrument slider

/// A horizontal fader with a lit fill, a glowing cap and an SF Mono readout.
/// Dragging previews continuously; `onCommit` fires once on release so
/// callers can send a single confirmed command. Arrow keys and VoiceOver
/// adjust in `step` increments.
struct InstrumentSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double = 0.01
    var fill: [Color] = [Polar.accent, Polar.mint]
    var readout: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
    var onCommit: ((Double) -> Void)? = nil

    @State private var dragging = false

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PolarSectionLabel(title)
                Spacer()
                Text(readout(value))
                    .font(.polarMono(12, weight: .semibold))
                    .foregroundStyle(Polar.chalk)
            }
            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                ZStack(alignment: .leading) {
                    Capsule().fill(Polar.stage)
                        .overlay(Capsule().stroke(Polar.rule, lineWidth: 1))
                    Capsule()
                        .fill(LinearGradient(colors: fill, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(10, width * fraction))
                        .shadow(color: (fill.last ?? Polar.accent).opacity(0.45), radius: 8)
                    Circle()
                        .fill(Polar.chalk)
                        .frame(width: dragging ? 18 : 16, height: dragging ? 18 : 16)
                        .shadow(color: Color.black.opacity(0.4), radius: 2, y: 1)
                        .offset(x: min(max(0, width * fraction - 8), width - 16))
                }
                .frame(height: 10)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            dragging = true
                            value = quantized(Double(drag.location.x / width))
                        }
                        .onEnded { drag in
                            dragging = false
                            let final = quantized(Double(drag.location.x / width))
                            value = final
                            onCommit?(final)
                        }
                )
            }
            .frame(height: 22)
        }
        .focusableCompat()
        .onHorizontalMoveCompat { nudge($0) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(readout(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(1)
            case .decrement: nudge(-1)
            @unknown default: break
            }
        }
    }

    private func quantized(_ raw: Double) -> Double {
        let clamped = min(max(raw, 0), 1)
        let rawValue = range.lowerBound + clamped * (range.upperBound - range.lowerBound)
        guard step > 0 else { return rawValue }
        let stepped = (rawValue / step).rounded() * step
        return min(max(stepped, range.lowerBound), range.upperBound)
    }

    private func nudge(_ direction: Int) {
        let next = min(max(value + Double(direction) * step * 5, range.lowerBound), range.upperBound)
        value = next
        onCommit?(next)
    }
}

// MARK: Instrument dial

/// A 270° dial, used for white point. The arc is drawn in the quantity's own
/// gradient (warm → cool for Kelvin); drag vertically or use arrow keys.
struct InstrumentDial: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 100
    var arc: [Color] = [Color(hex: 0xFFB765), Color(hex: 0xFFF3E0), Color(hex: 0x9FC2FF)]
    var readout: (Double) -> String = { "\(Int($0)) K" }
    var diameter: CGFloat = 132
    var onCommit: ((Double) -> Void)? = nil

    @State private var dragStart: Double? = nil

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Polar.stage, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle()
                    .trim(from: 0, to: 0.75 * fraction)
                    .stroke(AngularGradient(colors: arc, center: .center,
                                            startAngle: .degrees(0), endAngle: .degrees(270)),
                            style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .shadow(color: (arc.last ?? Polar.accent).opacity(0.35), radius: 8)
                Circle()
                    .fill(RadialGradient(colors: [Polar.raisedHi, Polar.desk],
                                         center: .topLeading, startRadius: 4, endRadius: diameter * 0.5))
                    .padding(22)
                    .overlay(Circle().stroke(Color.white.opacity(0.06), lineWidth: 1).padding(22))
                VStack(spacing: 2) {
                    Text(readout(value))
                        .font(.polarMono(17, weight: .semibold))
                        .foregroundStyle(Polar.chalk)
                    Text(title)
                        .font(.polarUI(11, weight: .medium))
                        .foregroundStyle(Polar.meter)
                }
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let start = dragStart ?? value
                        if dragStart == nil { dragStart = value }
                        let span = range.upperBound - range.lowerBound
                        let delta = Double(-drag.translation.height + drag.translation.width) / 220 * span
                        value = quantized(start + delta)
                    }
                    .onEnded { _ in
                        dragStart = nil
                        onCommit?(value)
                    }
            )
        }
        .focusableCompat()
        .onVerticalMoveCompat { nudge($0) }
        .onHorizontalMoveCompat { nudge($0) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(readout(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(1)
            case .decrement: nudge(-1)
            @unknown default: break
            }
        }
    }

    private func quantized(_ raw: Double) -> Double {
        let stepped = step > 0 ? (raw / step).rounded() * step : raw
        return min(max(stepped, range.lowerBound), range.upperBound)
    }

    private func nudge(_ direction: Int) {
        let next = quantized(value + Double(direction) * step)
        value = next
        onCommit?(next)
    }
}

// MARK: Segment strip

/// A read-out of a zoned fixture: one cell per addressable unit, lit in the
/// unit's colour, numbered every `labelEvery` units (and always on the
/// selected unit) in SF Mono. Long strips wrap into rows of `rowLength` so
/// a 75-segment H612B stays scannable. Selection is optional: pass nil to
/// draw a display-only strip.
struct SegmentStrip: View {
    struct Cell: Equatable {
        var color: Color
        var isOn: Bool
    }

    enum Axis { case horizontal, columns }

    let cells: [Cell]
    var unitName: String = "segment"
    var axis: Axis = .horizontal
    var rowLength: Int? = nil
    var labelEvery: Int = 1
    var cellHeight: CGFloat = 34
    var selection: Binding<Set<Int>>? = nil

    private var rows: [[Int]] {
        let all = Array(cells.indices)
        guard let rowLength, rowLength > 0, all.count > rowLength else { return [all] }
        return stride(from: 0, to: all.count, by: rowLength).map {
            Array(all[$0..<min($0 + rowLength, all.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: axis == .columns ? 0 : 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                VStack(alignment: .leading, spacing: 4) {
                    if rows.count > 1, let first = row.first, let last = row.last {
                        Text("\(unitName.capitalized)s \(first + 1)–\(last + 1)")
                            .font(.polarMono(12))
                            .foregroundStyle(Polar.meter)
                    }
                    HStack(spacing: axis == .columns ? 4 : 3) {
                        ForEach(row, id: \.self) { index in
                            cell(index)
                        }
                    }
                }
                .id(rowIndex)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(cells.count) \(unitName)s")
    }

    private func isSelected(_ index: Int) -> Bool {
        selection?.wrappedValue.contains(index) ?? false
    }

    private func showsLabel(_ index: Int) -> Bool {
        labelEvery <= 1 || (index + 1) % labelEvery == 0 || index == 0 || isSelected(index)
    }

    @ViewBuilder
    private func cell(_ index: Int) -> some View {
        let item = cells[index]
        let selected = isSelected(index)
        let shape = RoundedRectangle(cornerRadius: axis == .columns ? 5 : 4, style: .continuous)
        let face = VStack(spacing: 3) {
            shape
                .fill(item.isOn
                      ? AnyShapeStyle(LinearGradient(colors: [item.color.mixed(with: .white, amount: 0.18),
                                                              item.color.opacity(0.78)],
                                                     startPoint: .top, endPoint: .bottom))
                      : AnyShapeStyle(Polar.raised))
                .overlay(shape.stroke(selected ? Polar.select : Color.white.opacity(0.07),
                                      lineWidth: selected ? 2 : 1))
                .shadow(color: item.isOn ? item.color.opacity(0.4) : .clear, radius: 5)
                .frame(height: cellHeight)
            Text(showsLabel(index) ? "\(index + 1)" : " ")
                .font(.polarMono(12, weight: selected ? .bold : .medium))
                .foregroundStyle(selected ? Polar.select : Polar.meter)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(minWidth: 10, maxWidth: .infinity)
        .help("\(unitName.capitalized) \(index + 1)\(item.isOn ? "" : " · off")")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(unitName.capitalized) \(index + 1)")
        .accessibilityValue(item.isOn ? (selected ? "On, selected" : "On") : "Off")

        if let selection {
            Button {
                if selection.wrappedValue.contains(index) {
                    selection.wrappedValue.remove(index)
                } else {
                    selection.wrappedValue.insert(index)
                }
            } label: { face.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            face
        }
    }
}

// MARK: Swatch button

/// Press feedback for colour chips without the system's disabled dimming,
/// which turns saturated swatches muddy on the dark stage.
struct PolarSwatchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
