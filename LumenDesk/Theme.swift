import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - LumenDesk design system — "Spectral Bench"
//
// LumenDesk is an optical bench for a home: a beam enters, a prism splits it,
// and every light on the network lands somewhere along that spectrum.
//
// The system has exactly one rule, and everything below follows from it:
//
//     Chrome is achromatic. Colour means light.
//
// Interface surfaces are cool obsidian neutrals. The only colour authored into
// the product is a single dispersion ramp — the visible spectrum — which is
// sampled at fixed wavelengths for every semantic role the app needs, and
// drawn whole as the one branded ornament. Illumination itself is rendered in
// beam white, so a lit control reads as *lit* rather than as *branded*. Real
// device colour is data and stays inside the controls that edit it.

enum Lumen {

    // MARK: Neutrals — the bench

    /// Window well, keycap legends, and the ground beneath everything.
    static let void          = Color(hex: 0x04060A)
    /// Window background.
    static let ink           = Color(hex: 0x080B11)
    /// Deepest tone; alias kept for call sites that mean "darker than ink".
    static let inkDeep       = void
    /// Panels & rows.
    static let surface       = Color(hex: 0x0E1219)
    /// Sheets, popovers, hovered/raised surfaces.
    static let surfaceRaised = Color(hex: 0x151A23)
    /// Machined face plates used for oversized controls.
    static let surfaceLoud   = Color(hex: 0x1E2530)

    // MARK: Hairlines & separators

    static let hairline       = Color(hex: 0x1F2732)
    static let hairlineStrong = Color(hex: 0x333D4B)
    /// The 1 px lit edge along the top of a raised panel.
    static let edgeHighlight  = Color(hex: 0xFFFFFF, alpha: 0.05)

    // MARK: Beam — illumination, not branding

    /// The interaction colour: lit keys, selection, focus, primary actions.
    static let beam       = Color(hex: 0xDCE7F6)
    static let beamBright = Color(hex: 0xF6FAFF)
    /// Beam at rest — an unlit key legend or an inactive instrument label.
    static let beamDim    = Color(hex: 0x8C99AB)

    // MARK: The dispersion ramp
    //
    // Eight samples along the visible spectrum, short wavelength first. Every
    // semantic colour in the product is one of these; nothing else is coloured.

    static let wave400 = Color(hex: 0x6C4BF0)   // violet
    static let wave460 = Color(hex: 0x3D7BF5)   // blue
    static let wave490 = Color(hex: 0x21C4DE)   // cyan
    static let wave530 = Color(hex: 0x46D08A)   // green
    static let wave570 = Color(hex: 0xD9D45F)   // yellow
    static let wave590 = Color(hex: 0xFFB13D)   // amber
    static let wave620 = Color(hex: 0xFF7A38)   // orange
    static let wave660 = Color(hex: 0xF1495C)   // red

    /// Non-spectral closure of the ramp, used only where the wheel must wrap.
    static let magenta = Color(hex: 0xE2569E)

    // MARK: Semantic — every value is a sample above

    /// Direct control and selection. Illumination, so beam rather than a hue.
    static let signal       = beam
    static let signalBright = beamBright
    /// Local-link cyan appears only on discovery and network truth.
    static let cyan         = wave490
    /// Motion, music, and other creative-energy surfaces.
    static let copper       = wave620
    static let copperBright = Color(hex: 0xFF9A63)
    static let acid         = wave530
    static let gold         = wave590
    static let goldBright   = Color(hex: 0xFFC96B)
    static let coral        = copperBright

    /// Vendor and effect accents. Violet marks LIFX fixtures and mid-band
    /// energy; magenta closes the ramp on music surfaces.
    static let violet       = wave400
    static let violetBright = Color(hex: 0x8E7BFF)
    static let pink         = magenta
    static let pinkBright   = Color(hex: 0xFF7FC0)

    // MARK: Text

    static let textPrimary   = Color(hex: 0xE8EEF7)
    static let textSecondary = Color(hex: 0x9AA6B5)
    static let textTertiary  = Color(hex: 0x64707F)

    // MARK: Status

    static let success = wave530
    static let warning = wave590
    static let danger  = wave660
    static let offline = Color(hex: 0x64707F)
    static let focus   = beamBright

    // MARK: Gradients

    /// The dispersion ramp, drawn whole. This is the brand: a `SpectrumRule`
    /// under a title, the fill of a master fader, the edge of a selected key.
    /// It is never used as a background for text.
    static let spectrum = LinearGradient(
        colors: [wave400, wave460, wave490, wave530, wave570, wave590, wave620, wave660],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// Kept for call sites that want "the brand gradient". Illumination falls
    /// off from the beam rather than fanning, so the mark reads at 16 px.
    static let brandGradient = LinearGradient(
        colors: [beamBright, beam.opacity(0.55)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// The bench itself: a cold, near-black work surface.
    static let backdropGradient = LinearGradient(
        colors: [Color(hex: 0x0A0E15), ink, void],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Correlated colour temperature, warm to cool, for CCT controls.
    static let kelvinRamp = LinearGradient(
        colors: [Color(hex: 0xFFB765), Color(hex: 0xFFD9AE), Color(hex: 0xFFFFFF), Color(hex: 0xCFE1FF), Color(hex: 0x9FC2FF)],
        startPoint: .leading,
        endPoint: .trailing
    )

    // MARK: Metrics
    //
    // The bench is machined, not moulded: small radii, one chamfered corner,
    // and pills reserved for status.

    static let cardRadius: CGFloat = 5
    static let tileRadius: CGFloat = 4
    static let controlRadius: CGFloat = 3
    static let chamfer: CGFloat = 14
    static let iconBubble: CGFloat = 38
    static let hairlineWidth: CGFloat = 1
}

/// Typography has three voices and no serif. SF Pro Condensed carries titles
/// and orientation, SF Mono carries instrument labels and every measured
/// value, and standard SF Pro carries body copy and controls.
enum LumenType {
    /// Condensed grotesque. Titles, page headers, and named things.
    static func display(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).width(.condensed)
    }

    /// Monospaced measurement. Percentages, kelvin, counts, timings — anything
    /// the user reads as a number that changes.
    static func readout(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Short uppercase instrument labels engraved beside a control.
    static func instrumentLabel(size: CGFloat = 10) -> Font {
        .system(size: size, weight: .semibold, design: .monospaced)
    }
}

/// Semantic aliases shared with the prototype and Figma variable names.
enum LumenToken {
    enum Background {
        static let base = Lumen.ink
        static let subtle = Color(hex: 0x0A0D14)
    }

    enum Surface {
        static let `default` = Lumen.surface
        static let raised = Lumen.surfaceRaised
        static let emphasis = Lumen.surfaceLoud
        static let hover = Color(hex: 0x262E3B)
    }

    enum Status {
        static let success = Lumen.success
        static let warning = Lumen.warning
        static let error = Lumen.danger
        static let offline = Lumen.offline
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

/// The signature shape: a machined face plate with one corner cut away. The
/// chamfer always sits top-trailing, so a stack of panels reads as one rack.
struct LumenPanelShape: Shape {
    var radius: CGFloat = Lumen.cardRadius
    var chamfer: CGFloat = Lumen.chamfer

    func path(in rect: CGRect) -> Path {
        let limit = min(rect.width, rect.height)
        let r = max(0, min(radius, limit / 2))
        let c = max(0, min(chamfer, limit * 0.42))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - c, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + c))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - The spectrum rule

/// The one branded ornament. A hairline of the full dispersion ramp, used to
/// mark what is live, selected, or currently being controlled.
struct SpectrumRule: View {
    var height: CGFloat = 2
    var opacity: Double = 1
    /// Fades the long-wavelength end so the rule can run under wide titles
    /// without turning into a rainbow banner.
    var tapered: Bool = false

    var body: some View {
        Rectangle()
            .fill(Lumen.spectrum)
            .frame(height: height)
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

/// The bench surface: cold ground, a faint optical rail with tick marks, and a
/// single soft beam where the light enters. It is structure, not wallpaper.
struct LumenBackground: View {
    var glow: Bool = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(AppPreferenceKey.quietInterface) private var quietInterface = false

    private var plain: Bool { reduceTransparency || quietInterface }

    var body: some View {
        ZStack {
            if plain { Lumen.void } else { Lumen.backdropGradient }

            if !plain {
                BenchRail()
                    .opacity(0.5)
            }

            if glow && !plain {
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [Lumen.beam.opacity(0.055), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 420
                        )
                    )
                    .frame(width: 900, height: 520)
                    .offset(y: -260)
            }
        }
        .ignoresSafeArea()
    }
}

/// Graduated rules running the height of the window, like the scale etched
/// into an optical bench. Drawn once in a `Canvas` so it costs nothing.
private struct BenchRail: View {
    private let spacing: CGFloat = 72

    var body: some View {
        Canvas { context, size in
            let line = Color(hex: 0xFFFFFF, alpha: 0.022)
            let tick = Color(hex: 0xFFFFFF, alpha: 0.05)

            var x: CGFloat = spacing
            var index = 1
            while x < size.width {
                var rule = Path()
                rule.move(to: CGPoint(x: x, y: 0))
                rule.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(rule, with: .color(line), lineWidth: 1)

                let length: CGFloat = index % 4 == 0 ? 14 : 7
                var mark = Path()
                mark.move(to: CGPoint(x: x, y: 0))
                mark.addLine(to: CGPoint(x: x, y: length))
                context.stroke(mark, with: .color(tick), lineWidth: 1)

                x += spacing
                index += 1
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Panel surface

/// Standard face plate: obsidian fill, a lit top edge, a deliberate hairline,
/// and a spectrum rail down the leading edge when the panel is the one the
/// user is working in.
struct LumenPanelModifier: ViewModifier {
    var radius: CGFloat = Lumen.cardRadius
    var fill: Color = Lumen.surface
    var highlighted: Bool = false
    var glowColor: Color? = nil
    var chamfer: Bool = true

    private var shape: LumenPanelShape {
        LumenPanelShape(radius: radius, chamfer: chamfer ? Lumen.chamfer : 0)
    }

    func body(content: Content) -> some View {
        content
            .background {
                // The lit edge sits on top of the fill, not behind it.
                ZStack {
                    shape.fill(fill)
                    shape.fill(
                        LinearGradient(colors: [Lumen.edgeHighlight, .clear],
                                       startPoint: .top, endPoint: .bottom)
                    )
                }
            }
            .clipShape(shape)
            .overlay(
                shape.stroke(highlighted ? Lumen.hairlineStrong : Lumen.hairline,
                             lineWidth: Lumen.hairlineWidth)
            )
            .overlay(alignment: .leading) {
                if highlighted {
                    Rectangle()
                        .fill(Lumen.spectrum)
                        .frame(width: 2)
                        .padding(.vertical, radius)
                }
            }
            .shadow(
                color: glowColor?.opacity(0.18) ?? Color.black.opacity(0.35),
                radius: glowColor == nil ? 6 : 10,
                x: 0,
                y: glowColor == nil ? 3 : 0
            )
    }
}

extension View {
    /// The standard panel. Named `lumenCard` for continuity with existing call
    /// sites; the treatment is the machined face plate described above.
    func lumenCard(radius: CGFloat = Lumen.cardRadius,
                   fill: Color = Lumen.surface,
                   highlighted: Bool = false,
                   glowColor: Color? = nil,
                   chamfer: Bool = true) -> some View {
        modifier(LumenPanelModifier(radius: radius, fill: fill,
                                   highlighted: highlighted, glowColor: glowColor,
                                   chamfer: chamfer))
    }

    /// A quiet inset well — the recess a control sits in.
    func lumenWell(radius: CGFloat = Lumen.controlRadius) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Lumen.void.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Lumen.hairline, lineWidth: Lumen.hairlineWidth)
        )
    }
}

// MARK: - Button styles

/// The illuminated key: a beam-white face with the legend cut out of it.
struct LumenPrimaryButtonStyle: ButtonStyle {
    /// Matches the footprint the platform's `.controlSize(.small)` used to give
    /// these buttons inside dense cards.
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        LumenKeyFace(configuration: configuration, lit: true, compact: compact)
    }
}

/// The unlit key: engraved legend on a face plate.
struct LumenSecondaryButtonStyle: ButtonStyle {
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        LumenKeyFace(configuration: configuration, lit: false, compact: compact)
    }
}

/// Both console keys share one face so a lit and an unlit key stay the same
/// size on a row. `isEnabled` is read here rather than in the `ButtonStyle`,
/// which is not part of the view hierarchy and would never see it.
private struct LumenKeyFace: View {
    let configuration: ButtonStyle.Configuration
    let lit: Bool
    var compact: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Lumen.controlRadius, style: .continuous)
    }

    private var face: Color {
        if lit { return configuration.isPressed ? Lumen.beam : Lumen.beamBright }
        return configuration.isPressed ? Lumen.surfaceLoud : Lumen.surfaceRaised
    }

    private var legend: Color {
        if lit { return Lumen.void }
        return configuration.isPressed ? Lumen.beamBright : Lumen.textPrimary
    }

    var body: some View {
        configuration.label
            .font(LumenType.instrumentLabel(size: compact ? 10 : 11))
            .tracking(0.9)
            .textCase(.uppercase)
            .foregroundStyle(legend)
            .padding(.vertical, compact ? 7 : 11)
            .padding(.horizontal, compact ? 12 : 18)
            .background(shape.fill(face))
            .overlay(
                shape.stroke(lit ? Color.white.opacity(0.5) : Lumen.hairlineStrong,
                             lineWidth: 1)
            )
            .overlay(alignment: .top) {
                if !lit {
                    Rectangle()
                        .fill(Lumen.edgeHighlight)
                        .frame(height: 1)
                        .padding(.horizontal, 2)
                }
            }
            .shadow(color: Lumen.beam.opacity(lit && isEnabled ? 0.22 : 0), radius: 10)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(shape)
    }
}

/// A destructive key. Red is a sample of the ramp, so it stays in the system.
struct LumenDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LumenType.instrumentLabel(size: 11))
            .tracking(0.9)
            .textCase(.uppercase)
            .foregroundStyle(Lumen.danger)
            .padding(.vertical, 11)
            .padding(.horizontal, 18)
            .background(
                RoundedRectangle(cornerRadius: Lumen.controlRadius, style: .continuous)
                    .fill(Lumen.danger.opacity(configuration.isPressed ? 0.22 : 0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Lumen.controlRadius, style: .continuous)
                    .stroke(Lumen.danger.opacity(0.55), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Lumen.controlRadius, style: .continuous))
    }
}

// MARK: - Wordmark

/// Light leaves the aperture white and lands on the desk rail as the full
/// visible spectrum. The mark is the product's thesis: one input, every
/// colour, one control surface.
struct LumenMark: View {
    var size: CGFloat = 30
    var monochrome = false

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack {
                // The source slot.
                RoundedRectangle(cornerRadius: h * 0.02, style: .continuous)
                    .fill(monochrome ? Color.primary : Lumen.beamBright)
                    .frame(width: w * 0.24, height: h * 0.062)
                    .position(x: w * 0.5, y: h * 0.178)

                // The beam, dispersing as it falls.
                LumenBeamShape()
                    .fill(monochrome ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Lumen.spectrum))
                    .overlay {
                        if !monochrome {
                            LumenBeamShape()
                                .fill(
                                    LinearGradient(
                                        stops: [
                                            .init(color: Lumen.beamBright, location: 0),
                                            .init(color: Lumen.beamBright, location: 0.12),
                                            .init(color: Lumen.beamBright.opacity(0), location: 0.86)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        }
                    }

                // The desk rail.
                RoundedRectangle(cornerRadius: h * 0.02, style: .continuous)
                    .fill(monochrome ? Color.primary : Lumen.textPrimary)
                    .frame(width: w * 0.727, height: h * 0.094)
                    .position(x: w * 0.5, y: h * 0.79)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The tapered beam, in the mark's own proportions.
private struct LumenBeamShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.430, y: rect.minY + rect.height * 0.244))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.570, y: rect.minY + rect.height * 0.244))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.793, y: rect.minY + rect.height * 0.703))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.207, y: rect.minY + rect.height * 0.703))
        path.closeSubpath()
        return path
    }
}

/// LumenDesk wordmark: condensed type beside the prism, with the ramp beneath.
struct LumenWordmark: View {
    var size: CGFloat = 34

    var body: some View {
        HStack(spacing: size * 0.26) {
            LumenMark(size: size * 1.1)
            VStack(alignment: .leading, spacing: size * 0.11) {
                Text("LUMENDESK")
                    .font(LumenType.display(size: size, weight: .bold))
                    .tracking(size * 0.045)
                    .foregroundStyle(Lumen.textPrimary)
                SpectrumRule(height: max(1.5, size * 0.055))
            }
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
