import SwiftUI

/// Exact region values bind to the same draft as the spatial canvas. Color
/// commits are validated before invoking the editor's existing mutation path.
struct SpectrumValueRow: View {
    @Environment(\.isEnabled) private var isEnabled
    let name: String
    let color: Color
    @Binding var intensity: Double
    var intensityRange: ClosedRange<Double> = 0...1
    let state: String
    let commitColor: (Color) -> Void
    @State private var hex: String = ""
    @State private var invalidHex: Bool = false
    @FocusState private var editingHex: Bool

    private var rgb: NanoleafRGB {
        let values = color.rgbComponents
        func byte(_ value: Double) -> UInt8 { UInt8(min(255, max(0, (value * 255).rounded()))) }
        return NanoleafRGB(red: byte(values.r), green: byte(values.g), blue: byte(values.b))
    }

    private var percent: Binding<Double> {
        Binding(get: { intensity * 100 }, set: { value in
            guard isEnabled, value.isFinite else { return }
            intensity = min(intensityRange.upperBound, max(intensityRange.lowerBound, value / 100))
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                fields(showsRGB: true)
                fields(showsRGB: false)
            }
            if invalidHex {
                Text("Enter six hex digits, such as #FFB36B.").font(.caption).foregroundStyle(Lumen.warn)
            }
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Lumen.ruleSoft).frame(height: 1).allowsHitTesting(false)
        }
        .onAppear { hex = rgb.hexString }
        .onChange(of: rgb) { value in hex = value.hexString; invalidHex = false }
        .onChange(of: editingHex) { focused in if !focused { submitHex() } }
    }

    private func fields(showsRGB: Bool) -> some View {
        HStack(spacing: 12) {
            Text(name).font(.caption.monospacedDigit()).frame(width: 62, alignment: .leading)
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 18, height: 18)
                .accessibilityHidden(true)
            TextField("HEX", text: $hex).textFieldStyle(.roundedBorder)
                .font(.caption.monospaced()).frame(width: 92)
                .focused($editingHex).onSubmit(submitHex)
                .accessibilityLabel("\(name) hex color")
            if showsRGB {
                Text("\(rgb.red) · \(rgb.green) · \(rgb.blue)")
                    .font(.caption.monospacedDigit()).foregroundStyle(Lumen.meter)
                    .frame(minWidth: 100, alignment: .leading)
                    .accessibilityLabel("Red \(rgb.red), green \(rgb.green), blue \(rgb.blue)")
            }
            Spacer(minLength: 0)
            TextField("Intensity", value: percent, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                .font(.caption.monospacedDigit()).frame(width: 48)
                .accessibilityLabel("\(name) intensity percent")
            Text("%").font(.caption).foregroundStyle(Lumen.meter)
            Text(state).font(.caption).foregroundStyle(Lumen.meter).frame(minWidth: 44, alignment: .trailing)
        }
    }

    private func submitHex() {
        guard isEnabled else { return }
        guard let parsed = NanoleafRGB(hex: hex) else { invalidHex = true; return }
        invalidHex = false
        guard parsed != rgb else { hex = parsed.hexString; return }
        commitColor(parsed.swiftUIColor)
        // The editor may normalize chroma (Luna); display its actual value.
        // A changed color updates this again through onChange above.
        hex = rgb.hexString
    }
}

// MARK: - Shared light controls
// Presentation only: bindings retain existing command/commit behavior.
// Neutral chrome, visible focus, tabular values and keyboard/VoiceOver actions.

// MARK: - Fader

/// How a fader's filled travel is coloured. A fader shows either illumination,
/// a fixture's own colour, or a CCT ramp.
struct LumenFaderTrack {
    let gradient: LinearGradient

    static let beam = LumenFaderTrack(
        gradient: LinearGradient(colors: [Lumen.studioAccent.opacity(0.65), Lumen.studioAccent],
                                 startPoint: .leading, endPoint: .trailing)
    )

    /// The dispersion ramp is gone; call sites that asked for it want a lit
    /// travel.
    static let spectrum = beam

    static let kelvin = LumenFaderTrack(gradient: Lumen.kelvinRamp)

    static func tint(_ color: Color) -> LumenFaderTrack {
        LumenFaderTrack(
            gradient: LinearGradient(colors: [color.opacity(0.45), color],
                                     startPoint: .leading, endPoint: .trailing)
        )
    }
}

/// A horizontal fader: a recessed travel, a lit fill, and a chalk cap.
///
/// Drag anywhere on the track to jump to that value; arrow keys nudge on
/// macOS; VoiceOver gets an adjustable action. `onEditingChanged` keeps the
/// commit-on-release semantics the light and segment editors depend on.
struct LumenFader: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double? = nil
    var track: LumenFaderTrack = .beam
    /// Formats the value for the readout and for VoiceOver. Defaults to a
    /// percentage of the range.
    var format: (Double) -> String = { LumenFader.percent($0) }
    var showsHeader: Bool = true
    /// Retained so existing call sites compile. The etched scale is gone.
    var showsScale: Bool = true
    var onEditingChanged: (Bool) -> Void = { _ in }

    @Environment(\.isEnabled) private var isEnabled
    @State private var editing: Bool = false
    @FocusState private var hasKeyboardFocus: Bool

    private var span: Double { max(0.000001, range.upperBound - range.lowerBound) }
    private var fraction: Double { min(1, max(0, (value - range.lowerBound) / span)) }
    private var readout: String { format(value) }

    static func percent(_ value: Double) -> String {
        let normalized = value.isFinite ? min(1, max(0, value)) : 0
        return "\(Int((normalized * 100).rounded()))%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Lumen.meter)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(readout)
                        .font(LumenType.readout(size: 11.5, weight: .medium))
                        .foregroundStyle(editing ? Lumen.lit : Lumen.chalk)
                        .monospacedDigit()
                }
            }
            trackBody
        }
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(readout)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(1)
            case .decrement: nudge(-1)
            default: break
            }
        }
        .focusableCompat()
        .focused($hasKeyboardFocus)
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(hasKeyboardFocus ? Lumen.focus : .clear, lineWidth: 2)
                .padding(-3)
                .allowsHitTesting(false)
        }
        .onHorizontalMoveCompat { nudge($0) }
    }

    private var trackBody: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Lumen.rule)
                    .frame(height: 5)
                Capsule()
                    .fill(track.gradient)
                    .frame(width: max(0, width * fraction), height: 5)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Lumen.lit)
                    .frame(width: 5, height: 18)

                    .offset(x: min(max(0, width * fraction - 2.5), width - 5))
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard isEnabled else { return }
                        if !editing {
                            editing = true
                            onEditingChanged(true)
                        }
                        commit(x: drag.location.x, width: width)
                    }
                    .onEnded { drag in
                        guard editing else { return }
                        commit(x: drag.location.x, width: width)
                        editing = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 44)
    }

    private func commit(x: CGFloat, width: CGFloat) {
        guard isEnabled else { return }
        let ratio = min(1, max(0, Double(x / width)))
        value = quantized(range.lowerBound + ratio * span)
    }

    private func nudge(_ direction: Int) {
        guard isEnabled else { return }
        let increment = step ?? (span / 20)
        value = min(range.upperBound,
                    max(range.lowerBound,
                        quantized(value + Double(direction) * increment)))
        onEditingChanged(false)
    }

    private func quantized(_ raw: Double) -> Double {
        guard let step, step > 0 else { return min(range.upperBound, max(range.lowerBound, raw)) }
        let steps = ((raw - range.lowerBound) / step).rounded()
        return min(range.upperBound, max(range.lowerBound, range.lowerBound + steps * step))
    }
}

// MARK: - Rocker

/// The settings toggle. Everything that is not a fixture's power uses this.
struct LumenRockerStyle: ToggleStyle {
    var tint: Color = Lumen.lit
    /// Off for bare `Toggle("", isOn:)` call sites, where the row around the
    /// control already carries the wording and an expanding label would push
    /// the rocker out of alignment.
    var showsLabel: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        LumenRockerFace(configuration: configuration, tint: tint, showsLabel: showsLabel)
    }
}

private struct LumenRockerFace: View {
    let configuration: ToggleStyleConfiguration
    let tint: Color
    let showsLabel: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppPreferenceKey.quietInterface) private var quietInterface = false

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                if showsLabel {
                    configuration.label
                        .font(.system(size: 13))
                        .foregroundStyle(Lumen.chalk)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                rocker
            }
            .lumenInteractiveTarget()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(configuration.isOn ? [.isButton, .isSelected] : .isButton)
    }

    private var rocker: some View {
        ZStack(alignment: configuration.isOn ? .trailing : .leading) {
            Capsule()
                .fill(configuration.isOn ? tint : Lumen.stage)
            Circle()
                .fill(configuration.isOn ? Lumen.stage : Lumen.faint)
                .frame(width: 15, height: 15)
                .padding(3)
        }
        .frame(width: 40, height: 21)
        .animation(reduceMotion || quietInterface ? nil : .easeOut(duration: 0.16), value: configuration.isOn)
    }
}

// MARK: - Chip

/// A filter chip. Sentence case, because a filter is a word rather than a
/// legend engraved on a panel.
struct LumenChipStyle: ToggleStyle {
    var tint: Color = Lumen.lit

    func makeBody(configuration: Configuration) -> some View {
        LumenChipFace(configuration: configuration, tint: tint)
    }
}

private struct LumenChipFace: View {
    let configuration: ToggleStyleConfiguration
    let tint: Color

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(configuration.isOn ? Lumen.stage : Lumen.meter)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .lumenInteractiveTarget()
                .background(
                    RoundedRectangle(cornerRadius: Lumen.controlRadius, style: .continuous)
                        .fill(configuration.isOn ? tint : Lumen.stripRaised)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityAddTraits(configuration.isOn ? [.isButton, .isSelected] : .isButton)
    }
}
