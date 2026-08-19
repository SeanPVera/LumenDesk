import SwiftUI

// MARK: - Spectral Bench instrument controls
//
// The controls a lighting desk needs do not exist in the standard library, so
// LumenDesk draws its own: a fader with an etched scale, an illuminated power
// key, a rocker, a machined selector, and a segmented meter. They are built on
// the tokens in `Theme.swift` and follow the same rule — chrome is achromatic,
// colour means light.
//
// Every control here is keyboard- and VoiceOver-reachable. Nothing in this
// file talks to a device: these are presentation only, driven by bindings the
// existing views already own.

// MARK: - Fader

/// How a fader's filled travel is coloured. A fader shows either illumination
/// (beam), a device's own colour (tint), the spectrum, or a CCT ramp.
struct LumenFaderTrack {
    let gradient: LinearGradient

    static let beam = LumenFaderTrack(
        gradient: LinearGradient(colors: [Lumen.beam.opacity(0.22), Lumen.beamBright],
                                 startPoint: .leading, endPoint: .trailing)
    )

    static let spectrum = LumenFaderTrack(gradient: Lumen.spectrum)

    static let kelvin = LumenFaderTrack(gradient: Lumen.kelvinRamp)

    static func tint(_ color: Color) -> LumenFaderTrack {
        LumenFaderTrack(
            gradient: LinearGradient(colors: [color.opacity(0.28), color],
                                     startPoint: .leading, endPoint: .trailing)
        )
    }
}

/// A console fader: an engraved scale, a lit travel, and a machined cap.
///
/// Replaces `Slider` everywhere a level is set. Drag anywhere on the track to
/// jump to that value; arrow keys nudge on macOS; VoiceOver gets an adjustable
/// action. `onEditingChanged` keeps the existing commit-on-release semantics
/// the light and segment editors depend on.
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
    var showsScale: Bool = true
    var onEditingChanged: (Bool) -> Void = { _ in }

    @Environment(\.isEnabled) private var isEnabled
    @State private var editing = false

    private var span: Double { max(0.000001, range.upperBound - range.lowerBound) }
    private var fraction: Double { min(1, max(0, (value - range.lowerBound) / span)) }
    private var readout: String { format(value) }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if showsHeader {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    LumenEyebrow(text: label)
                    Spacer(minLength: 8)
                    Text(readout)
                        .font(LumenType.readout(size: 12, weight: .semibold))
                        .foregroundStyle(editing ? Lumen.beamBright : Lumen.textSecondary)
                        .monospacedDigit()
                }
            }
            trackBody
        }
        .opacity(isEnabled ? 1 : 0.4)
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
            VStack(spacing: 5) {
                if showsScale {
                    LumenFaderScale()
                        .frame(height: 7)
                }
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Lumen.void)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .stroke(Lumen.hairline, lineWidth: 1)
                        )
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(track.gradient)
                        .frame(width: max(0, width * fraction))
                }
                .frame(height: 8)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Lumen.beamBright)
                        .frame(width: 5, height: 20)
                        .shadow(color: Lumen.beam.opacity(editing ? 0.7 : 0.35), radius: 6)
                        .offset(x: min(max(0, width * fraction - 2.5), width - 5))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
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
        .frame(height: showsScale ? 32 : 22)
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

/// The etched scale above a fader's travel. Every fifth graduation is major,
/// which is what makes a fader read as an instrument rather than a progress bar.
private struct LumenFaderScale: View {
    var body: some View {
        Canvas { context, size in
            let divisions = 20
            for index in 0...divisions {
                let ratio = CGFloat(index) / CGFloat(divisions)
                let x = min(size.width - 0.5, max(0.5, size.width * ratio))
                let major = index % 5 == 0
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x, y: size.height - (major ? 7 : 4)))
                context.stroke(path,
                               with: .color(major ? Lumen.hairlineStrong : Lumen.hairline),
                               lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Power key

/// The illuminated power key. Replaces the platform switch wherever the toggle
/// means "this light, or these lights, are on".
struct LumenPowerKeyStyle: ToggleStyle {
    var tint: Color = Lumen.beamBright
    var size: CGFloat = 34
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
        RoundedRectangle(cornerRadius: 3, style: .continuous)
    }

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack {
                if configuration.isOn {
                    shape.fill(
                        LinearGradient(colors: [tint, tint.opacity(0.78)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                } else {
                    shape.fill(Lumen.surfaceRaised)
                    shape.fill(
                        LinearGradient(colors: [Lumen.edgeHighlight, .clear],
                                       startPoint: .top, endPoint: .bottom)
                    )
                }
                shape.stroke(configuration.isOn ? Color.white.opacity(0.6) : Lumen.hairlineStrong,
                             lineWidth: 1)
                Image(systemName: "power")
                    .font(.system(size: size * 0.44, weight: .heavy))
                    .foregroundStyle(configuration.isOn ? Lumen.void : Lumen.beamDim)
            }
            .frame(width: size, height: size)
            .shadow(color: tint.opacity(configuration.isOn ? 0.4 : 0), radius: 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isOn)
        .accessibilityLabel(spokenLabel ?? "Power")
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(configuration.isOn ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Rocker

/// A squared rocker for settings and options. Every other toggle in the app —
/// anything that is not a light's power — uses this.
struct LumenRockerStyle: ToggleStyle {
    var tint: Color = Lumen.beamBright
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
                        .foregroundStyle(Lumen.textPrimary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                rocker
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(configuration.isOn ? [.isButton, .isSelected] : .isButton)
    }

    private var rocker: some View {
        ZStack(alignment: configuration.isOn ? .trailing : .leading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(configuration.isOn ? tint.opacity(0.9) : Lumen.void)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(configuration.isOn ? Color.white.opacity(0.45) : Lumen.hairlineStrong,
                                lineWidth: 1)
                )
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(configuration.isOn ? Lumen.void : Lumen.beamDim)
                .frame(width: 16, height: 16)
                .padding(3)
        }
        .frame(width: 44, height: 22)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isOn)
    }
}

// MARK: - Chip

/// A filter chip. Replaces `.toggleStyle(.button)`, which renders as a stock
/// bordered button on both platforms and belongs to no product in particular.
struct LumenChipStyle: ToggleStyle {
    var tint: Color = Lumen.beamBright

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
                .font(LumenType.instrumentLabel(size: 10))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(configuration.isOn ? Lumen.void : Lumen.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(configuration.isOn ? tint : Lumen.surfaceRaised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .stroke(configuration.isOn ? Color.clear : Lumen.hairline, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
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

/// A machined selector: engraved legends in a recessed well, with the live
/// option lit and underlined by the spectrum. Replaces `.pickerStyle(.segmented)`.
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
            .padding(2)
            .lumenWell()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func segment(for option: LumenOption<Value>) -> some View {
        let active = selection == option.value
        return VStack(spacing: 4) {
            HStack(spacing: 5) {
                if let symbol = option.symbol {
                    Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                }
                Text(option.title)
                    .font(LumenType.instrumentLabel(size: 10))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .lineLimit(1)
            }
            .foregroundStyle(active ? Lumen.beamBright : Lumen.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)

            Rectangle()
                .fill(Lumen.spectrum)
                .frame(height: 2)
                .opacity(active ? 1 : 0)
        }
        .background(
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(active ? Lumen.surfaceLoud : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Readouts and indicators

/// An engraved uppercase label. Used beside every control that carries one.
struct LumenEyebrow: View {
    let text: String
    var tint: Color = Lumen.textTertiary
    var size: CGFloat = 9

    var body: some View {
        Text(text.uppercased())
            .font(LumenType.instrumentLabel(size: size))
            .tracking(1.2)
            .foregroundStyle(tint)
            .lineLimit(1)
    }
}

/// A measured value over its engraved caption — the panel's primary numeric.
struct LumenReadout: View {
    let value: String
    let caption: String
    var tint: Color = Lumen.textPrimary
    var size: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(LumenType.readout(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            LumenEyebrow(text: caption)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A square indicator lamp. Square, because every round dot in every dashboard
/// looks the same and this one should not.
struct LumenStatusDot: View {
    let color: Color
    var size: CGFloat = 7
    var lit: Bool = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(color.opacity(lit ? 1 : 0.35))
            .frame(width: size, height: size)
            .shadow(color: color.opacity(lit ? 0.7 : 0), radius: 4)
            .accessibilityHidden(true)
    }
}

/// A segmented level meter. Used for audio bands, aggregate brightness, and
/// anywhere a continuous value is being watched rather than set.
struct LumenMeter: View {
    let value: Double
    var tint: Color = Lumen.beamBright
    var segments: Int = 20
    var height: CGFloat = 10

    var body: some View {
        let clamped = min(1, max(0, value))
        let litCount = Int((clamped * Double(segments)).rounded())
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(index < litCount ? tint : Lumen.hairline)
                    .opacity(index < litCount ? 1 : 0.55)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A chamfered icon plate. The app's recurring container for a symbol.
struct LumenIconTile: View {
    let systemName: String
    var tint: Color = Lumen.beam
    var size: CGFloat = Lumen.iconBubble
    var lit: Bool = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.4, weight: .medium))
            .foregroundStyle(lit ? Lumen.void : tint)
            .frame(width: size, height: size)
            .background(
                LumenPanelShape(radius: 3, chamfer: size * 0.28)
                    .fill(lit ? AnyShapeStyle(tint) : AnyShapeStyle(Lumen.surfaceRaised))
            )
            .overlay(
                LumenPanelShape(radius: 3, chamfer: size * 0.28)
                    .stroke(lit ? Color.white.opacity(0.4) : Lumen.hairline, lineWidth: 1)
            )
            .accessibilityHidden(true)
    }
}

/// A title with the dispersion ramp beneath it. The standard way a region of
/// the app announces itself.
struct LumenTitleBlock: View {
    let eyebrow: String?
    let title: String
    var subtitle: String? = nil
    var size: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let eyebrow {
                LumenEyebrow(text: eyebrow, tint: Lumen.beamDim)
            }
            Text(title)
                .font(LumenType.display(size: size, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(Lumen.textPrimary)
            SpectrumRule(height: 2, tapered: true)
                .frame(width: max(120, size * 4))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Lumen.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Icon key

/// A compact square key for icon-only actions, so a toolbar of glyphs reads as
/// a row of console keys rather than as stock bordered buttons.
struct LumenIconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var tint: Color = Lumen.textPrimary
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
        RoundedRectangle(cornerRadius: 3, style: .continuous)
    }

    var body: some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(prominent ? Lumen.void : tint)
            .frame(minWidth: size, minHeight: size)
            .padding(.horizontal, 4)
            .background(
                shape.fill(prominent
                           ? (configuration.isPressed ? Lumen.beam : Lumen.beamBright)
                           : (configuration.isPressed ? Lumen.surfaceLoud : Lumen.surfaceRaised))
            )
            .overlay(
                shape.stroke(prominent ? Color.white.opacity(0.5) : Lumen.hairlineStrong, lineWidth: 1)
            )
            .shadow(color: Lumen.beam.opacity(prominent && isEnabled ? 0.2 : 0), radius: 8)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(shape)
    }
}

// MARK: - Lens

/// A light's own colour, shown as the lens plate of a fixture rather than as a
/// coloured dot. Lit lenses cast a short halo; dark ones read as cold glass.
///
/// This is the only place in the interface where arbitrary colour is allowed,
/// because here the colour *is* the data.
struct LumenLens: View {
    let color: Color
    var isOn: Bool = true
    var size: CGFloat = 40
    var isStale: Bool = false

    private var shape: LumenPanelShape {
        LumenPanelShape(radius: 3, chamfer: size * 0.3)
    }

    var body: some View {
        shape
            .fill(isOn ? AnyShapeStyle(
                    LinearGradient(colors: [color, color.opacity(0.62)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
                       : AnyShapeStyle(Lumen.void))
            .overlay(
                shape.stroke(isOn ? Color.white.opacity(0.28) : Lumen.hairlineStrong, lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                // The catchlight that makes the plate read as glass.
                Rectangle()
                    .fill(Color.white.opacity(isOn ? 0.22 : 0.04))
                    .frame(width: size * 0.42, height: 1.5)
                    .padding(.leading, size * 0.17)
                    .padding(.top, size * 0.2)
            }
            .overlay {
                if isStale {
                    shape.stroke(Lumen.offline, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .frame(width: size, height: size)
            .shadow(color: isOn ? color.opacity(0.4) : .clear, radius: size * 0.22)
            .accessibilityHidden(true)
    }
}
