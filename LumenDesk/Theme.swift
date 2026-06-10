import SwiftUI

// MARK: - LumenDesk design system — "Aurora Noir"
//
// A single source of truth for the app's dark, sophisticated visual language:
// deep violet-tinted surfaces, neon-pink energy, and sparing gold accents.
// The app is locked to dark mode (see `RootView`), so these are fixed values
// with no light-appearance variants to maintain.

enum Lumen {

    // MARK: Surfaces (never flat black — a violet undertone adds depth)

    /// Window background.
    static let ink           = Color(hex: 0x0D0B14)
    /// Deepest tone, used for the backdrop gradient base / vignette.
    static let inkDeep       = Color(hex: 0x080610)
    /// Cards & rows.
    static let surface       = Color(hex: 0x17141F)
    /// Sheets, popovers, hovered/raised surfaces.
    static let surfaceRaised = Color(hex: 0x211C2E)

    // MARK: Hairlines & separators

    static let hairline       = Color.white.opacity(0.07)
    static let hairlineStrong = Color.white.opacity(0.12)

    // MARK: Accents

    static let violet       = Color(hex: 0x7C5CFF)
    static let violetBright = Color(hex: 0x9D7BFF)
    static let pink         = Color(hex: 0xFF4D9D)
    static let pinkBright   = Color(hex: 0xFF6FB5)
    /// Used sparingly — favorites, key dividers, premium emphasis.
    static let gold         = Color(hex: 0xE0B250)
    static let goldBright   = Color(hex: 0xF0C56B)
    /// Govee brand accent, tuned to harmonize with the gold/pink palette.
    static let coral        = Color(hex: 0xFF6F61)

    // MARK: Text

    static let textPrimary   = Color(hex: 0xF4F1FA)
    static let textSecondary = Color(hex: 0xB0A8C4)
    static let textTertiary  = Color(hex: 0x6E6883)

    // MARK: Semantic

    static let warning = Color(hex: 0xF2A94E)
    static let danger  = Color(hex: 0xFF5470)

    // MARK: Gradients

    /// Primary brand gradient — violet → neon pink. Used for the wordmark,
    /// primary CTAs, and key emphasis.
    static let brandGradient = LinearGradient(
        colors: [violetBright, pink],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// A soft wash used behind the whole app.
    static let backdropGradient = LinearGradient(
        colors: [Color(hex: 0x141022), inkDeep],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: Metrics

    static let cardRadius: CGFloat = 14
    static let tileRadius: CGFloat = 10
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
                    colors: [Lumen.violet.opacity(0.22), .clear],
                    center: .topLeading, startRadius: 0, endRadius: 440
                )
                RadialGradient(
                    colors: [Lumen.pink.opacity(0.15), .clear],
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
                color: glowColor?.opacity(0.45) ?? Color.black.opacity(0.30),
                radius: glowColor == nil ? 10 : 16,
                x: 0,
                y: glowColor == nil ? 6 : 0
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
