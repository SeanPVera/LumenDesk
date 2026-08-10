import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - LumenDesk design system — "The Lighting Desk"
//
// LumenDesk should look like an instrument for a room, not a generic neon
// dashboard. Warm graphite surfaces recall lighting consoles and architectural
// materials. Signal amber marks direct control, while cool blue is reserved
// for the local network. A light's own colour remains data and is shown only
// where the user is working with that light.

enum Lumen {

    // MARK: Surfaces

    /// Window background.
    static let ink           = Color(hex: 0x11120F)
    /// Deepest tone, used for the window well and high-contrast controls.
    static let inkDeep       = Color(hex: 0x0B0C0A)
    /// Cards & rows.
    static let surface       = Color(hex: 0x191B17)
    /// Sheets, popovers, hovered/raised surfaces.
    static let surfaceRaised = Color(hex: 0x22251F)
    /// High-contrast cockpit panels used for oversized controls.
    static let surfaceLoud   = Color(hex: 0x2B2F27)

    // MARK: Hairlines & separators

    static let hairline       = Color(hex: 0x34382F)
    static let hairlineStrong = Color(hex: 0x4C5345)

    // MARK: Instrument accents

    /// The physical-control color: selected navigation, primary actions, focus.
    static let signal       = Color(hex: 0xE7B35A)
    static let signalBright = Color(hex: 0xFFD68A)
    /// Local-link blue appears only on discovery and network truth.
    static let cyan         = Color(hex: 0x73B4BD)
    /// Copper is a restrained creative accent for motion and music.
    static let copper       = Color(hex: 0xC97852)
    static let copperBright = Color(hex: 0xE59A70)
    static let acid         = Color(hex: 0x83B67A)
    static let gold         = signal
    static let goldBright   = signalBright
    static let coral        = copperBright

    // Legacy aliases keep presentation-only refactors narrow. New UI should
    // use `signal` and `copper` so the intent is obvious at the call site.
    static let violet       = Color(hex: 0xB99A62)
    static let violetBright = signal
    static let pink         = copper
    static let pinkBright   = copperBright

    // MARK: Text

    static let textPrimary   = Color(hex: 0xF1EFE8)
    static let textSecondary = Color(hex: 0xB8B8AF)
    static let textTertiary  = Color(hex: 0x858A80)

    // MARK: Semantic

    static let success = Color(hex: 0x83B67A)
    static let warning = Color(hex: 0xD6A24C)
    static let danger  = Color(hex: 0xD86E60)
    static let offline = Color(hex: 0x858A80)
    static let focus   = Color(hex: 0xFFD68A)

    // MARK: Gradients

    /// The warm aperture is the only brand gradient. Interface chrome stays
    /// flat so gradients retain meaning when they appear in light previews.
    static let brandGradient = LinearGradient(
        colors: [signalBright, signal],
        startPoint: .top,
        endPoint: .bottom
    )

    /// A low-contrast work surface used behind the whole app.
    static let backdropGradient = LinearGradient(
        colors: [Color(hex: 0x171912), ink, inkDeep],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: Metrics

    static let cardRadius: CGFloat = 12
    static let tileRadius: CGFloat = 8
    static let iconBubble: CGFloat = 40
}

/// Typography has two voices: New York for orientation and SF Mono for
/// instrument labels. Standard controls continue to use native SF Pro.
enum LumenType {
    static func display(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static func instrumentLabel(size: CGFloat = 10) -> Font {
        .system(size: size, weight: .semibold, design: .monospaced)
    }
}

/// Semantic aliases shared with the prototype and Figma variable names.
/// Keeping the hierarchy explicit makes future design-token reconciliation
/// mechanical without forcing the existing view layer to rename every token.
enum LumenToken {
    enum Background {
        static let base = Lumen.ink
        static let subtle = Color(hex: 0x141611)
    }

    enum Surface {
        static let `default` = Lumen.surface
        static let raised = Lumen.surfaceRaised
        static let emphasis = Lumen.surfaceLoud
        static let hover = Color(hex: 0x30342B)
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

// MARK: - App backdrop

/// The app-wide work surface. A faint tapered beam repeats the geometry of the
/// LumenDesk mark without turning every screen into decorative wallpaper.
struct LumenBackground: View {
    var glow: Bool = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(AppPreferenceKey.quietInterface) private var quietInterface = false

    var body: some View {
        ZStack {
            if reduceTransparency || quietInterface { Lumen.inkDeep } else { Lumen.backdropGradient }
            if glow && !quietInterface && !reduceTransparency {
                LumenBeamShape()
                    .fill(
                        LinearGradient(
                            colors: [Lumen.signalBright.opacity(0.055), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(maxWidth: 680)
                    .offset(y: -120)
            }
        }
        .ignoresSafeArea()
    }
}

private struct LumenBeamShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX - rect.width * 0.07, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX + rect.width * 0.07, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Card surface

/// Standard instrument panel: flat graphite, a deliberate hairline, and a
/// quiet leading signal rail for selection.
struct LumenCardModifier: ViewModifier {
    var radius: CGFloat = Lumen.cardRadius
    var fill: Color = Lumen.surface
    var highlighted: Bool = false
    var glowColor: Color? = nil

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Lumen.hairline, lineWidth: 1)
            )
            .overlay {
                if highlighted {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(Lumen.signal, lineWidth: 1.5)
                }
            }
            .overlay(alignment: .leading) {
                if highlighted {
                    Capsule()
                        .fill(Lumen.signal)
                        .frame(width: 3)
                        .padding(.vertical, 10)
                        .padding(.leading, 6)
                }
            }
            .shadow(
                color: glowColor?.opacity(0.12) ?? Color.black.opacity(0.16),
                radius: glowColor == nil ? 3 : 7,
                x: 0,
                y: glowColor == nil ? 2 : 0
            )
    }
}

extension View {
    func lumenCard(radius: CGFloat = Lumen.cardRadius,
                   fill: Color = Lumen.surface,
                   highlighted: Bool = false,
                   glowColor: Color? = nil) -> some View {
        modifier(LumenCardModifier(radius: radius, fill: fill,
                                   highlighted: highlighted, glowColor: glowColor))
    }
}

// MARK: - Button styles

/// Warm, squared primary action inspired by a console's illuminated key.
struct LumenPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .default, weight: .semibold))
            .foregroundStyle(Lumen.inkDeep)
            .padding(.vertical, 10)
            .padding(.horizontal, 18)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? Lumen.signal : Lumen.signalBright)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Quiet, outlined secondary action.
struct LumenSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .default, weight: .semibold))
            .foregroundStyle(Lumen.textPrimary)
            .padding(.vertical, 10)
            .padding(.horizontal, 18)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? Lumen.surfaceLoud : Lumen.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Lumen.hairlineStrong, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Wordmark

/// The aperture casts one beam onto a desk rail. It is drawn in SwiftUI so the
/// product never falls back to a stock lightbulb as its identity.
struct LumenMark: View {
    var size: CGFloat = 30
    var monochrome = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: width * 0.43, y: height * 0.23))
                    path.addLine(to: CGPoint(x: width * 0.57, y: height * 0.23))
                    path.addLine(to: CGPoint(x: width * 0.77, y: height * 0.70))
                    path.addLine(to: CGPoint(x: width * 0.23, y: height * 0.70))
                    path.closeSubpath()
                }
                .fill(monochrome ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Lumen.brandGradient))

                RoundedRectangle(cornerRadius: height * 0.035, style: .continuous)
                    .fill(monochrome ? Color.primary : Lumen.signalBright)
                    .frame(width: width * 0.24, height: height * 0.09)
                    .position(x: width * 0.5, y: height * 0.18)

                RoundedRectangle(cornerRadius: height * 0.045, style: .continuous)
                    .fill(monochrome ? Color.primary : Lumen.textPrimary)
                    .frame(width: width * 0.72, height: height * 0.11)
                    .position(x: width * 0.5, y: height * 0.78)

                HStack(spacing: width * 0.055) {
                    Circle().fill(monochrome ? Color.clear : Lumen.cyan)
                    Circle().fill(monochrome ? Color.clear : Lumen.signal)
                    Circle().fill(monochrome ? Color.clear : Lumen.success)
                }
                .frame(width: width * 0.25, height: height * 0.035)
                .position(x: width * 0.5, y: height * 0.78)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// LumenDesk wordmark: editorial type beside the product-specific aperture.
struct LumenWordmark: View {
    var size: CGFloat = 34

    var body: some View {
        HStack(spacing: size * 0.28) {
            LumenMark(size: size * 1.05)
            Text("LumenDesk")
                .font(LumenType.display(size: size, weight: .semibold))
                .foregroundStyle(Lumen.textPrimary)
                .tracking(-0.4)
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
