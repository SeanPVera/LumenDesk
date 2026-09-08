import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - LumenDesk design system — "Wash"
//
// A wash is what a fixture lays down over a surface. That is the whole system.
//
//     Every fixture owns a strip, and the strip is lit by the fixture.
//
// Structure comes from a lighting board: every controllable thing is a channel
// strip, strips sit side by side, and the level on each one is always visible
// and always live. Material comes from the light itself: surfaces separate by
// luminance rather than by borders, elevation is brightness, and a powered
// fixture washes its own strip in its own colour at its own level.
//
// Exactly one hue is authored into the interface, and it is rationed to
// network truth — discovery, confirmed packets, round-trip time, addresses.
// Every other colour on screen is a real fixture reporting a real state.
//
// Replaces "Spectral Bench", which put console cues (a chamfered corner, an
// etched fader scale, uppercase mono legends, a dispersion ramp) on top of a
// dashboard skeleton. The cues read as instrumentation, the layout read as a
// web admin panel, and the gap between them is what felt wrong.

enum Lumen {

    // MARK: The bench — warm neutrals
    //
    // Home light lives between 2200 K and 4000 K. A blue-black chrome argues
    // with every lamp in the house, so the ground is warm near-black and a
    // tungsten wash sits on it without looking like a colour cast.

    /// Ground beneath everything, and the well a control recesses into.
    static let stage        = Color(hex: 0x0C0B0A)
    /// The strip field and other large working areas.
    static let deck         = Color(hex: 0x141210)
    /// An unlit channel strip, and the standard panel fill.
    static let strip        = Color(hex: 0x1C1917)
    /// Hovered, selected, or otherwise raised. Elevation is brightness.
    static let stripRaised  = Color(hex: 0x262220)
    /// The loudest surface in the system, used for grouped controls.
    static let stripLoud    = Color(hex: 0x302B27)

    // MARK: Separators
    //
    // Used sparingly. Wash separates surfaces by value first; a rule only
    // appears where two areas share a value and still need a boundary.

    static let ruleSoft = Color(hex: 0x221F1C)
    static let rule     = Color(hex: 0x2E2926)

    // MARK: Text

    static let chalk = Color(hex: 0xF4F0EA)
    static let meter = Color(hex: 0xA79F96)
    static let muted = Color(hex: 0x6B645D)
    static let faint = Color(hex: 0x423D38)

    /// Illumination. A lit key face, a fader cap, a powered legend.
    static let lit = Color(hex: 0xFFFCF6)

    // MARK: The one hue
    //
    // Link cyan means the network, and nothing else. Discovery, a confirmed
    // packet, a round-trip figure, an address. It is deliberately the only
    // authored hue in the product, so a coloured pixel anywhere else on screen
    // is a fixture reporting its own colour.

    static let link    = Color(hex: 0x5FE0D8)
    static let linkDim = Color(hex: 0x2C6E6A)

    /// Status. Both are rare and both always ship with an icon, because hue
    /// alone cannot carry meaning on a screen full of coloured fixtures.
    static let warn = Color(hex: 0xF0B03C)
    static let fail = Color(hex: 0xFF5A52)

    // MARK: Wash geometry
    //
    // How much of its own colour a fixture pours into its strip. Compressed so
    // an 18% bedside lamp still tints legibly and a 100% key light does not
    // flood the readout sitting on top of it.

    /// Opacity of the colour wash across a strip at a given 0…1 level.
    static func washOpacity(level: Double, isOn: Bool) -> Double {
        guard isOn else { return 0 }
        return 0.16 + min(max(level, 0), 1) * 0.42
    }

    /// Opacity of the two-point spill under a lit strip.
    static func spillOpacity(level: Double, isOn: Bool) -> Double {
        guard isOn else { return 0 }
        return 0.45 + min(max(level, 0), 1) * 0.55
    }

    // MARK: Gradients

    /// Illumination falling off. Replaces the old dispersion ramp everywhere
    /// it was used as an ornament, so a lit edge reads as lit rather than as
    /// branded.
    static let litGradient = LinearGradient(
        colors: [lit, chalk.opacity(0.35)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// A fixture's colour spilling up from the floor of its strip. Bottom
    /// weighted because light rises off a surface, and because it keeps the
    /// level readout on dark ground whatever the fixture is doing.
    static func washGradient(_ color: Color) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: color, location: 0),
                .init(color: color.opacity(0), location: 0.76)
            ],
            startPoint: .bottom,
            endPoint: .top
        )
    }

    /// Correlated colour temperature, warm to cool. The one place a ramp is
    /// still correct, because the fixture really does travel along it.
    static let kelvinRamp = LinearGradient(
        colors: [Color(hex: 0xFFB765), Color(hex: 0xFFD9AE), Color(hex: 0xFFFFFF),
                 Color(hex: 0xCFE1FF), Color(hex: 0x9FC2FF)],
        startPoint: .leading,
        endPoint: .trailing
    )

    // MARK: Metrics

    static let stripRadius: CGFloat = 10
    static let controlRadius: CGFloat = 6
    /// No call site may produce a corner sharper than the system allows.
    static let minimumRadius: CGFloat = 6
    static let hairlineWidth: CGFloat = 1
    static let stripWidth: CGFloat = 96
    static let masterStripWidth: CGFloat = 108
    static let faderTravel: CGFloat = 128

    // MARK: - Compatibility aliases
    //
    // Spectral Bench names, remapped onto Wash values. Roughly 375 call sites
    // across the app referred to the old tokens; rebinding the names re-skins
    // every one of them without touching a single view. New code should use
    // the Wash names above.

    static let void          = stage
    static let ink           = stage
    static let inkDeep       = stage
    static let surface       = strip
    static let surfaceRaised = stripRaised
    static let surfaceLoud   = stripLoud

    static let hairline       = ruleSoft
    static let hairlineStrong = rule
    static let edgeHighlight  = Color(hex: 0xFFFFFF, alpha: 0.04)

    static let beam       = chalk
    static let beamBright = lit
    static let beamDim    = muted

    static let textPrimary   = chalk
    static let textSecondary = meter
    static let textTertiary  = muted

    static let signal       = chalk
    static let signalBright = lit
    static let cyan         = link
    static let focus        = link

    /// A confirmed device is a network fact, so it speaks in link cyan.
    static let success = link
    static let warning = warn
    static let danger  = fail
    static let offline = faint

    /// Vendor identity is a three-letter mono tag in Wash, never a colour, so
    /// both former brand tints collapse to neutral.
    static let violet       = meter
    static let violetBright = meter
    static let copper       = meter
    static let copperBright = meter
    static let coral        = meter
    static let magenta      = meter

    /// Motion and music are states of the desk rather than of the network, so
    /// they read as illumination.
    static let pink       = chalk
    static let pinkBright = lit
    static let acid       = link
    static let gold       = warn
    static let goldBright = warn

    /// The dispersion ramp is gone. Its call sites were ornamental edges and
    /// fader fills, and they all want illumination instead.
    static let spectrum      = litGradient
    static let brandGradient = litGradient

    /// The bench backdrop is flat now. Elevation comes from value, so a
    /// gradient behind everything only muddies the strips sitting on it.
    static let backdropGradient = LinearGradient(
        colors: [stage, stage],
        startPoint: .top,
        endPoint: .bottom
    )

    static let cardRadius: CGFloat = stripRadius
    static let tileRadius: CGFloat = 8
    /// Chamfers are gone; the token survives so old call sites still compile.
    static let chamfer: CGFloat = 0
    static let iconBubble: CGFloat = 34
}

/// Three voices, all system faces, none of them condensed.
///
/// Spectral Bench put SF Pro Condensed on titles and uppercase mono on labels,
/// which made every line of the app weigh the same and stripped proper nouns
/// of their shape. Wash carries hierarchy in size and weight so a fixture name
/// gets to look like language.
enum LumenType {
    /// Names and titles. Standard-width SF Pro, sentence case at call sites.
    static func display(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }

    /// Measured values: levels, kelvin, counts, timings, addresses. Monospaced
    /// and tabular, because the whole point of a strip field is comparing
    /// numbers down a column.
    static func readout(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Control labels. Sentence case in new code; the face is sans so that
    /// legacy call sites still uppercasing their text read as small caps
    /// rather than as engraving.
    static func instrumentLabel(size: CGFloat = 10) -> Font {
        .system(size: size + 1, weight: .semibold)
    }
}

/// Semantic aliases shared with the prototype and Figma variable names.
enum LumenToken {
    enum Background {
        static let base = Lumen.stage
        static let subtle = Lumen.deck
    }

    enum Surface {
        static let `default` = Lumen.strip
        static let raised = Lumen.stripRaised
        static let emphasis = Lumen.stripLoud
        static let hover = Lumen.stripRaised
    }

    enum Status {
        static let success = Lumen.link
        static let warning = Lumen.warn
        static let error = Lumen.fail
        static let offline = Lumen.faint
    }

    enum Spacing {
        static let s1: CGFloat = 4
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let s5: CGFloat = 20
        static let s6: CGFloat = 24
        static let s8: CGFloat = 32
        static let s10: CGFloat = 40
    }
}

// MARK: - Hex color initializer

extension Color {
    /// Create a `Color` from a `0xRRGGBB` integer literal.
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >>  8) & 0xFF) / 255.0,
            blue:  Double( hex        & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}

// MARK: - Panel geometry

/// A plain rounded rectangle, floored at the system's minimum radius.
///
/// This used to cut a 14 pt chamfer off the top-trailing corner of every
/// panel. Clamped at 42% of the short side, that bite disfigured anything
/// small, and repeated across 61 call sites it stopped reading as a signature
/// at about the fourth one. `chamfer` survives in the signature so existing
/// call sites compile, and is deliberately ignored.
struct LumenPanelShape: Shape {
    var radius: CGFloat = Lumen.stripRadius
    var chamfer: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let limit = min(rect.width, rect.height)
        let r = max(0, min(max(radius, Lumen.minimumRadius), limit / 2))
        return Path(roundedRect: rect, cornerRadius: r, style: .continuous)
    }
}

// MARK: - Rules

/// A quiet hairline. Was the dispersion ramp drawn whole; a rainbow under
/// every title made brand colour and fixture colour compete for the same eye.
struct SpectrumRule: View {
    var height: CGFloat = 1
    var opacity: Double = 1
    var tapered: Bool = false

    var body: some View {
        Rectangle()
            .fill(Lumen.rule)
            .frame(height: max(1, height * 0.5))
            .opacity(opacity)
            .mask(alignment: .leading) {
                if tapered {
                    LinearGradient(colors: [.white, .white.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                } else {
                    Rectangle()
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - App backdrop

/// Flat warm ground. There is no wallpaper in Wash: an etched rail and a soft
/// beam behind the content only competed with the fixtures washing the strips
/// in front of it.
struct LumenBackground: View {
    var glow: Bool = true

    var body: some View {
        Lumen.stage.ignoresSafeArea()
    }
}

// MARK: - Panel surface

/// The standard panel: a fill one step up from its ground, no border, no
/// shadow. Elevation is value.
///
/// The old treatment hung a `black.opacity(0.35)` shadow on all 61 panels.
/// Between `#0E1219` and `#080B11` that shadow rendered essentially nothing
/// while still costing an offscreen pass per panel.
struct LumenPanelModifier: ViewModifier {
    var radius: CGFloat = Lumen.stripRadius
    var fill: Color = Lumen.strip
    var highlighted: Bool = false
    var glowColor: Color? = nil
    var chamfer: Bool = true

    private var shape: LumenPanelShape { LumenPanelShape(radius: radius) }

    func body(content: Content) -> some View {
        content
            .background(shape.fill(highlighted ? Lumen.stripRaised : fill))
            .clipShape(shape)
            .overlay {
                if highlighted {
                    shape.stroke(Lumen.rule, lineWidth: Lumen.hairlineWidth)
                }
            }
    }
}

extension View {
    /// The standard panel. Name kept for continuity with 59 existing call
    /// sites; the treatment is the flat, borderless surface described above.
    func lumenCard(radius: CGFloat = Lumen.stripRadius,
                   fill: Color = Lumen.strip,
                   highlighted: Bool = false,
                   glowColor: Color? = nil,
                   chamfer: Bool = true) -> some View {
        modifier(LumenPanelModifier(radius: radius, fill: fill,
                                   highlighted: highlighted, glowColor: glowColor,
                                   chamfer: chamfer))
    }

    /// A recessed well — the ground a control travels in.
    func lumenWell(radius: CGFloat = Lumen.controlRadius) -> some View {
        background(
            RoundedRectangle(cornerRadius: max(radius, Lumen.minimumRadius), style: .continuous)
                .fill(Lumen.stage)
        )
    }

    /// Washes a surface in a fixture's own colour, at that fixture's own
    /// level, and lays two points of spill under it. This is the system's
    /// single ornament, and it carries two facts at once: the fixture is lit,
    /// and this is the colour it is lit in.
    func washed(color: Color, level: Double, isOn: Bool,
                radius: CGFloat = Lumen.stripRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: max(radius, Lumen.minimumRadius),
                                     style: .continuous)
        return background {
            shape
                .fill(Lumen.washGradient(color))
                .opacity(Lumen.washOpacity(level: level, isOn: isOn))
        }
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(color)
                .frame(height: 2)
                .padding(.horizontal, radius)
                .opacity(Lumen.spillOpacity(level: level, isOn: isOn))
                .shadow(color: color.opacity(isOn ? 0.7 : 0), radius: 8)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Button styles

/// The lit key: a chalk face with the legend cut out of it.
struct LumenPrimaryButtonStyle: ButtonStyle {
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        LumenKeyFace(configuration: configuration, lit: true, compact: compact)
    }
}

/// The unlit key: a raised face carrying a chalk legend.
struct LumenSecondaryButtonStyle: ButtonStyle {
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        LumenKeyFace(configuration: configuration, lit: false, compact: compact)
    }
}

/// Both keys share one face so a lit and an unlit key stay the same size on a
/// row. `isEnabled` is read here rather than in the `ButtonStyle`, which is
/// not part of the view hierarchy and would never see it.
private struct LumenKeyFace: View {
    let configuration: ButtonStyle.Configuration
    let lit: Bool
    var compact: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Lumen.controlRadius, style: .continuous)
    }

    private var face: Color {
        if lit { return configuration.isPressed ? Lumen.chalk : Lumen.lit }
        return configuration.isPressed ? Lumen.stripLoud : Lumen.stripRaised
    }

    private var legend: Color {
        if lit { return Lumen.stage }
        return configuration.isPressed ? Lumen.lit : Lumen.chalk
    }

    var body: some View {
        configuration.label
            .font(.system(size: compact ? 11.5 : 12.5, weight: .medium))
            .foregroundStyle(legend)
            .padding(.vertical, compact ? 6 : 9)
            .padding(.horizontal, compact ? 11 : 15)
            .background(shape.fill(face))
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(shape)
    }
}

/// A destructive key.
struct LumenDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Lumen.fail)
            .padding(.vertical, 9)
            .padding(.horizontal, 15)
            .background(
                RoundedRectangle(cornerRadius: Lumen.controlRadius, style: .continuous)
                    .fill(Lumen.fail.opacity(configuration.isPressed ? 0.20 : 0.11))
            )
            .contentShape(RoundedRectangle(cornerRadius: Lumen.controlRadius, style: .continuous))
    }
}

// MARK: - Mark

/// Four channels at four levels, each lit in its own colour.
///
/// The mark is the product's thesis in its smallest form: many fixtures,
/// different states, one surface. It reads as a strip field and as a meter at
/// the same time, and four bars still resolve at 16 px.
///
/// It replaces the dispersing beam, whose prism-and-rainbow reading described
/// optics rather than control.
struct LumenMark: View {
    var size: CGFloat = 30
    var monochrome = false

    /// x origin, bar top, and lit colour, as fractions of the tile.
    private static let bars: [(x: CGFloat, top: CGFloat, color: Color)] = [
        (0.09375, 0.46875, Color(hex: 0xFFB35C)),
        (0.31250, 0.28125, Color(hex: 0xF5E9D8)),
        (0.53125, 0.59375, Color(hex: 0x6ED8D0)),
        (0.75000, 0.18750, Color(hex: 0x9E8CE0))
    ]
    private static let barWidth: CGFloat = 0.15625
    private static let baseline: CGFloat = 0.875

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack(alignment: .topLeading) {
                ForEach(Array(Self.bars.enumerated()), id: \.offset) { _, bar in
                    RoundedRectangle(cornerRadius: w * 0.05, style: .continuous)
                        .fill(monochrome ? Color.primary : bar.color)
                        .frame(width: w * Self.barWidth,
                               height: h * (Self.baseline - bar.top))
                        .offset(x: w * bar.x, y: h * bar.top)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// LumenDesk wordmark: the channel mark beside the name, set in the same face
/// the product uses for every other name.
struct LumenWordmark: View {
    var size: CGFloat = 34

    var body: some View {
        HStack(spacing: size * 0.30) {
            LumenMark(size: size * 1.05)
            Text("LumenDesk")
                .font(.system(size: size * 0.85, weight: .semibold))
                .kerning(-size * 0.012)
                .foregroundStyle(Lumen.chalk)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("LumenDesk")
    }
}

// MARK: - Platform compatibility

/// Shims that let the shared SwiftUI code compile on both macOS and iOS.
extension View {
    /// Gives compact icon and text controls a forgiving click/tap area without
    /// forcing their visible artwork to grow. Forty-four points matches the
    /// platform accessibility guidance and keeps neighboring targets distinct.
    func lumenInteractiveTarget(minimumSize: CGFloat = 44) -> some View {
        frame(minWidth: minimumSize, minHeight: minimumSize)
            .contentShape(Rectangle())
    }

    /// Desktop windows and sheets get generous minimum sizes; on iPhone the
    /// sheet should simply fill the available screen, so this is a no-op there.
    func sheetFrame(minWidth: CGFloat? = nil,
                    idealWidth: CGFloat? = nil,
                    minHeight: CGFloat? = nil,
                    idealHeight: CGFloat? = nil) -> some View {
        #if os(macOS)
        return frame(minWidth: minWidth, idealWidth: idealWidth,
                     minHeight: minHeight, idealHeight: idealHeight)
        #else
        return self
        #endif
    }

    /// `.focusable` predates iOS 17, so only apply it on macOS.
    func focusableCompat() -> some View {
        #if os(macOS)
        return focusable(true)
        #else
        return self
        #endif
    }

    /// Escape-key handling only exists on macOS.
    func onExitCommandCompat(perform action: @escaping () -> Void) -> some View {
        #if os(macOS)
        return onExitCommand(perform: action)
        #else
        return self
        #endif
    }

    /// Left/right arrow adjustment for the bespoke instrument controls. Only
    /// macOS routes move commands, so iOS relies on the accessibility
    /// adjustable action instead.
    func onHorizontalMoveCompat(perform action: @escaping (Int) -> Void) -> some View {
        #if os(macOS)
        return onMoveCommand { direction in
            switch direction {
            case .left: action(-1)
            case .right: action(1)
            default: break
            }
        }
        #else
        return self
        #endif
    }

    /// Up/down arrow adjustment, for the vertical faders on a strip.
    func onVerticalMoveCompat(perform action: @escaping (Int) -> Void) -> some View {
        #if os(macOS)
        return onMoveCommand { direction in
            switch direction {
            case .up: action(1)
            case .down: action(-1)
            default: break
            }
        }
        #else
        return self
        #endif
    }
}

enum PlatformOpener {
    /// Opens the most specific privacy/settings pane the platform allows.
    /// macOS can deep-link System Settings panes; iOS can only open the
    /// app's own settings page (which hosts Local Network and Microphone).
    static func openSettings(macPane: String) {
        #if os(macOS)
        if let url = URL(string: macPane) { NSWorkspace.shared.open(url) }
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
}
