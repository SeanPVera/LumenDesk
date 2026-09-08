import SwiftUI

// MARK: - Wash instrument controls
//
// The controls a lighting board needs do not exist in the standard library, so
// LumenDesk draws its own. They are built on the tokens in `Theme.swift` and
// follow the same rule: every fixture owns a strip, and the strip is lit by
// the fixture.
//
// What changed from Spectral Bench, and why:
//
// - Uppercase and letter-spacing left every label. Uppercase has no
//   descenders and a flat x-height, so a screen carrying forty tracked-out
//   legends gives the eye no shape to lock onto and every line ends up
//   weighing the same. Hierarchy is size and weight now.
// - Borders left almost everything. A 1 px hairline around each control on a
//   near-black ground was drawing sixty boxes to say what value already said.
// - Etched fader graduations left the fader. They read as instrumentation up
//   close and as noise at a glance, and the number beside the fader was
//   already exact.
//
// Nothing in this file talks to a device: these are presentation only, driven
// by bindings the views already own.

// MARK: - Fader

/// How a fader's filled travel is coloured. A fader shows either illumination,
/// a fixture's own colour, or a CCT ramp.
struct LumenFaderTrack {
    let gradient: LinearGradient

    static let beam = LumenFaderTrack(
        gradient: LinearGradient(colors: [Lumen.chalk.opacity(0.55), Lumen.lit],
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
    @State private var editing = false

    private var span: Double { max(0.000001, range.upperBound - range.lowerBound) }
    private var fraction: Double { min(1, max(0, (value - range.lowerBound) / span)) }
    private var readout: String { format(value) }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(label)
                        .font(.system(size: 11.5, weight: .medium))
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
        .onHorizontalMoveCompat { nudge($0) }
    }

    private var trackBody: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Lumen.stage)
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
                    .shadow(color: Lumen.chalk.opacity(editing ? 0.5 : 0.22), radius: 6)
                    .offset(x: min(max(0, width * fraction - 2.5), width - 5))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !editing {
                            editing = true
                            onEditingChanged(true)
                        }
                        commit(x: drag.location.x, width: width)
                    }
                    .onEnded { drag in
                        commit(x: drag.location.x, width: width)
                        editing = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 22)
    }

    private func commit(x: CGFloat, width: CGFloat) {
        let ratio = min(1, max(0, Double(x / width)))
        value = quantized(range.lowerBound + ratio * span)
    }

    private func nudge(_ direction: Int) {
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

// MARK: - Power key

/// The lit power key. Replaces the platform switch wherever the toggle means
/// "this light, or these lights, are on".
struct LumenPowerKeyStyle: ToggleStyle {
    var tint: Color = Lumen.lit
    var size: CGFloat = 32
    /// Supplied by the call site because a `ToggleStyle` cannot read the text
    /// out of its own configuration label.
    var spokenLabel: String? = nil

    func makeBody(configuration: Configuration) -> some View {
        LumenPowerKeyFace(configuration: configuration,
                          tint: tint,
                          size: size,
                          spokenLabel: spokenLabel)
    }
}

private struct LumenPowerKeyFace: View {
    let configuration: ToggleStyleConfiguration
    let tint: Color
    let size: CGFloat
    let spokenLabel: String?

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Lumen.controlRadius, style: .continuous)
    }

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack {
                shape.fill(configuration.isOn ? tint : Lumen.stage)
                Image(systemName: "power")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(configuration.isOn ? Lumen.stage : Lumen.faint)
            }
            .frame(width: size, height: size)
            .shadow(color: tint.opacity(configuration.isOn ? 0.35 : 0), radius: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isOn)
        .accessibilityLabel(spokenLabel ?? "Power")
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(configuration.isOn ? [.isButton, .isSelected] : .isButton)
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isOn)
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

// MARK: - Selector

/// One option in a `LumenSelector`.
struct LumenOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var symbol: String? = nil

    var id: Value { value }
}

/// A segmented selector: options in a recessed well, the live one raised.
/// Replaces `.pickerStyle(.segmented)`.
struct LumenSelector<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [LumenOption<Value>]
    var showsLabel: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if showsLabel {
                LumenEyebrow(text: label)
            }
            HStack(spacing: 2) {
                ForEach(options) { option in
                    Button {
                        selection = option.value
                    } label: {
                        segment(for: option)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == option.value ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(2.5)
            .lumenWell(radius: 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func segment(for option: LumenOption<Value>) -> some View {
        let active = selection == option.value
        return HStack(spacing: 5) {
            if let symbol = option.symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .medium))
            }
            Text(option.title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(active ? Lumen.chalk : Lumen.muted)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Lumen.controlRadius, style: .continuous)
                .fill(active ? Lumen.stripLoud : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Readouts and indicators

/// A quiet control label. Sentence case as written by the call site: the
/// uppercase budget for the whole product is two, and both are spent
/// elsewhere.
struct LumenEyebrow: View {
    let text: String
    var tint: Color = Lumen.muted
    var size: CGFloat = 9

    var body: some View {
        Text(text)
            .font(.system(size: size + 2.5, weight: .medium))
            .foregroundStyle(tint)
            .lineLimit(1)
    }
}

/// A measured value over its caption — a panel's primary numeric.
struct LumenReadout: View {
    let value: String
    let caption: String
    var tint: Color = Lumen.chalk
    var size: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(LumenType.readout(size: size, weight: .medium))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            LumenEyebrow(text: caption)
        }
        .accessibilityElement(children: .combine)
    }
}

/// An indicator lamp. Round and small: on a screen full of coloured fixtures
/// this is a status, not a swatch, and it should not compete.
struct LumenStatusDot: View {
    let color: Color
    var size: CGFloat = 6
    var lit: Bool = true

    var body: some View {
        Circle()
            .fill(color.opacity(lit ? 1 : 0.3))
            .frame(width: size, height: size)
            .shadow(color: color.opacity(lit ? 0.6 : 0), radius: 5)
            .accessibilityHidden(true)
    }
}

/// A segmented level meter, for values being watched rather than set.
struct LumenMeter: View {
    let value: Double
    var tint: Color = Lumen.lit
    var segments: Int = 20
    var height: CGFloat = 10

    var body: some View {
        let clamped = min(1, max(0, value))
        let litCount = Int((clamped * Double(segments)).rounded())
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(index < litCount ? tint : Lumen.rule)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// An icon plate. The app's recurring container for a symbol.
struct LumenIconTile: View {
    let systemName: String
    var tint: Color = Lumen.chalk
    var size: CGFloat = Lumen.iconBubble
    var lit: Bool = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.4, weight: .medium))
            .foregroundStyle(lit ? Lumen.stage : tint)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(lit ? tint : Lumen.stripRaised)
            )
            .accessibilityHidden(true)
    }
}

/// The way a region of the app announces itself. Sentence case, hierarchy in
/// size, and no rule underneath it.
struct LumenTitleBlock: View {
    let eyebrow: String?
    let title: String
    var subtitle: String? = nil
    var size: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let eyebrow {
                LumenEyebrow(text: eyebrow, tint: Lumen.muted)
            }
            Text(title)
                .font(.system(size: size, weight: .semibold))
                .kerning(-size * 0.018)
                .foregroundStyle(Lumen.chalk)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Lumen.meter)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }
}

// MARK: - Icon key

/// A compact key for icon-only actions.
struct LumenIconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var tint: Color = Lumen.chalk
    var prominent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        LumenIconKeyFace(configuration: configuration, size: size, tint: tint, prominent: prominent)
    }
}

private struct LumenIconKeyFace: View {
    let configuration: ButtonStyle.Configuration
    let size: CGFloat
    let tint: Color
    let prominent: Bool

    @Environment(\.isEnabled) private var isEnabled

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Lumen.controlRadius, style: .continuous)
    }

    var body: some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(prominent ? Lumen.stage : tint)
            .frame(minWidth: size, minHeight: size)
            .padding(.horizontal, 4)
            .background(
                shape.fill(prominent
                           ? (configuration.isPressed ? Lumen.chalk : Lumen.lit)
                           : (configuration.isPressed ? Lumen.stripLoud : Lumen.stripRaised))
            )
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(shape)
    }
}

// MARK: - Lens

/// A fixture's own colour, shown as a field of that colour at that fixture's
/// own level. Used in the inspector, where the colour *is* the subject.
struct LumenLens: View {
    let color: Color
    var isOn: Bool = true
    var size: CGFloat = 40
    var isStale: Bool = false
    /// 0…1. A lamp at 18% should not present as a full-strength swatch.
    var level: Double = 1

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: max(size * 0.2, Lumen.minimumRadius), style: .continuous)
    }

    var body: some View {
        shape
            .fill(isOn ? color : Lumen.stage)
            .opacity(isOn ? 0.35 + min(max(level, 0), 1) * 0.65 : 1)
            .overlay(alignment: .topLeading) {
                // The highlight that makes the field read as glass.
                shape.fill(
                    LinearGradient(colors: [Color.white.opacity(isOn ? 0.16 : 0.03), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            }
            .overlay {
                if isStale {
                    shape.stroke(Lumen.faint, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Link facts
//
// The channel-strip layer that lived here belonged to the Wash direction,
// where the fixture was the primary object. The product went with Plan, so a
// fixture's control is a dot on a drawing and a row in the room inspector,
// and nothing renders a channel strip any more. Removed rather than left
// unreferenced; it is in the history if it is ever wanted back.

/// A key/value line of network truth. The only place in the product that
/// spends the one authored hue.
struct WashLinkFact: View {
    let key: String
    let value: String
    var dead: Bool = false

    var body: some View {
        HStack {
            Text(key)
                .font(LumenType.readout(size: 9.5, weight: .regular))
                .foregroundStyle(Lumen.muted)
            Spacer(minLength: 8)
            Text(value)
                .font(LumenType.readout(size: 9.5, weight: .medium))
                .foregroundStyle(dead ? Lumen.faint : Lumen.link)
                .monospacedDigit()
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
