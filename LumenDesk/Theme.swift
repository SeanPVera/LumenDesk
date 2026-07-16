import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - LumenDesk design system — "Aurora Noir"
//
// A single source of truth for the app's dark, sophisticated visual language.
// The refined palette keeps everyday control surfaces calm and reserves
// expressive colour for lighting previews and creative editing.
// The app is locked to dark mode (see `RootView`), so these are fixed values
// with no light-appearance variants to maintain.

enum Lumen {

    // MARK: Surfaces (never flat black — a violet undertone adds depth)

    /// Window background.
    static let ink           = Color(hex: 0x090B12)
    /// Deepest tone, used for the backdrop gradient base / vignette.
    static let inkDeep       = Color(hex: 0x090B12)
    /// Cards & rows.
    static let surface       = Color(hex: 0x121722)
    /// Sheets, popovers, hovered/raised surfaces.
    static let surfaceRaised = Color(hex: 0x181E2C)
    /// High-contrast cockpit panels used for oversized controls.
    static let surfaceLoud   = Color(hex: 0x20283A)

    // MARK: Hairlines & separators

    static let hairline       = Color(hex: 0x2A3040)
    static let hairlineStrong = Color(hex: 0x3A4358)

    // MARK: Accents

    static let violet       = Color(hex: 0x7566E8)
    static let violetBright = Color(hex: 0x8B7BFF)
    static let cyan         = Color(hex: 0x45D8E8)
    static let acid         = Color(hex: 0x45D5A4)
    static let pink         = Color(hex: 0xD65BB8)
    static let pinkBright   = Color(hex: 0xEE68CB)
    /// Used sparingly — favorites, key dividers, premium emphasis.
    static let gold         = Color(hex: 0xF2B85B)
    static let goldBright   = Color(hex: 0xFFD27A)
    /// Govee brand accent, tuned to harmonize with the saturated palette.
    static let coral        = Color(hex: 0xFF8A68)

    // MARK: Text

    static let textPrimary   = Color(hex: 0xF5F7FB)
    static let textSecondary = Color(hex: 0xAEB8C9)
    static let textTertiary  = Color(hex: 0x758096)

    // MARK: Semantic

    static let success = Color(hex: 0x45D5A4)
    static let warning = Color(hex: 0xF2B85B)
    static let danger  = Color(hex: 0xFF657D)
    static let offline = Color(hex: 0x8992A6)
    static let focus   = Color(hex: 0x65DDFF)

    // MARK: Gradients

    /// Primary brand gradient — violet → neon pink. Used for the wordmark,
    /// primary CTAs, and key emphasis.
    static let brandGradient = LinearGradient(
        colors: [cyan, violetBright, pinkBright],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// A soft wash used behind the whole app.
    static let backdropGradient = LinearGradient(
        colors: [Color(hex: 0x0D1019), Color(hex: 0x111322), inkDeep],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: Metrics

    static let cardRadius: CGFloat = 18
    static let tileRadius: CGFloat = 12
    static let iconBubble: CGFloat = 44
}

/// Semantic aliases shared with the prototype and Figma variable names.
/// Keeping the hierarchy explicit makes future design-token reconciliation
/// mechanical without forcing the existing view layer to rename every token.
enum LumenToken {
    enum Background {
        static let base = Lumen.ink
        static let subtle = Color(hex: 0x0D1019)
    }

    enum Surface {
        static let `default` = Lumen.surface
        static let raised = Lumen.surfaceRaised
        static let emphasis = Lumen.surfaceLoud
        static let hover = Color(hex: 0x242D40)
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

/// The app-wide background: a deep violet-to-black gradient with a couple of
/// faint aurora glows. Sits at the bottom of the view stack and ignores the
/// safe area so it bleeds to every edge.
struct LumenBackground: View {
    var glow: Bool = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(AppPreferenceKey.quietInterface) private var quietInterface = false

    var body: some View {
        ZStack {
            if reduceTransparency || quietInterface { Lumen.inkDeep } else { Lumen.backdropGradient }
            if glow && !quietInterface && !reduceTransparency {
                RadialGradient(
                    colors: [Lumen.cyan.opacity(0.10), .clear],
                    center: .topLeading, startRadius: 0, endRadius: 440
                )
                RadialGradient(
                    colors: [Lumen.violetBright.opacity(0.10), .clear],
                    center: .bottomTrailing, startRadius: 0, endRadius: 480
                )
                .blendMode(.screen)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Card surface

/// Standard elevated surface: violet-tinted fill, hairline border, soft shadow.
/// Pass `highlighted` for a brand-gradient border or `glowColor` for a colored
/// glow (e.g. a light that is currently on).
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
                        .stroke(Lumen.brandGradient, lineWidth: 1.5)
                }
            }
            .shadow(
                color: glowColor?.opacity(0.22) ?? Color.black.opacity(0.22),
                radius: glowColor == nil ? 8 : 12,
                x: 0,
                y: glowColor == nil ? 3 : 0
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

/// Filled, gradient primary action with a soft neon glow.
struct LumenPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.vertical, 11)
            .padding(.horizontal, 24)
            .background(Capsule().fill(Lumen.brandGradient))
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
            .shadow(color: Lumen.pink.opacity(configuration.isPressed ? 0.20 : 0.45),
                    radius: configuration.isPressed ? 6 : 14, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Quiet, outlined secondary action.
struct LumenSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Lumen.textPrimary)
            .padding(.vertical, 11)
            .padding(.horizontal, 24)
            .background(Capsule().fill(Lumen.surfaceRaised))
            .overlay(Capsule().stroke(Lumen.hairlineStrong, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

// MARK: - Wordmark

/// The LumenDesk brand lockup: a gradient-filled bulb glyph beside the
/// gradient wordmark. Used on the welcome screen (and reusable elsewhere).
struct LumenWordmark: View {
    var size: CGFloat = 34

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: size * 0.82))
                .foregroundStyle(Lumen.brandGradient)
                .shadow(color: Lumen.pink.opacity(0.5), radius: 12)
                .accessibilityHidden(true)
            Text("LumenDesk")
                .font(.system(size: size, weight: .bold, design: .rounded))
                .foregroundStyle(Lumen.brandGradient)
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
