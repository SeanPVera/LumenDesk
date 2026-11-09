import SwiftUI

// MARK: - Polar Instrument tokens
//
// Source of truth: the Polar Instrument design system (stage #070B14,
// desk #0F1624, accent #4F8CFF, mint #2EE6A6, chalk #EEF3FB; SF Pro Rounded
// display, SF Pro Text UI, SF Mono numerics). Every other colour or type
// decision in the app should resolve to a name in this file. `Lumen` in
// `Theme.swift` re-exports these under the app's older semantic names.

enum Polar {
    // Surfaces, deepest first.
    /// App canvas and the Room Stage floor.
    static let stage = Color(hex: 0x070B14)
    /// Sidebar and window chrome, one step up from the stage.
    static let deck = Color(hex: 0x0B111D)
    /// Panels, header bars and sheets.
    static let desk = Color(hex: 0x0F1624)
    /// Cards and control wells.
    static let raised = Color(hex: 0x182234)
    /// Selected or hovered cards.
    static let raisedHi = Color(hex: 0x1D2A42)
    /// Stage geometry: grid and room walls.
    static let wall = Color(hex: 0x243044)

    // Rules.
    static let ruleSoft = Color(hex: 0x1C2638)
    static let rule = Color(hex: 0x2A3850)

    // Text.
    /// Primary text.
    static let chalk = Color(hex: 0xEEF3FB)
    /// Secondary text (AA on stage and desk).
    static let meter = Color(hex: 0xA3B6CE)

    // Action and identity.
    /// Primary actions and focus.
    static let accent = Color(hex: 0x4F8CFF)
    /// Secondary accent and the success glow.
    static let mint = Color(hex: 0x2EE6A6)
    /// Selection ring.
    static let select = Color(hex: 0x7EB6FF)
    /// Supporting hues for room identity dots and charts.
    static let violet = Color(hex: 0xA78BFA)
    static let coral = Color(hex: 0xFF8C6B)
    static let amber = Color(hex: 0xF5B84B)

    // Status. Always shipped with a symbol and a word.
    static let confirm = mint
    static let pending = Color(hex: 0xF5C542)
    static let changed = Color(hex: 0x8B9BB4)
    static let attention = Color(hex: 0xFF5D6C)

    /// Stable identity colour for the n-th room in the sidebar.
    static func roomTint(_ index: Int) -> Color {
        let tints = [accent, mint, violet, amber, coral, select]
        return tints[((index % tints.count) + tints.count) % tints.count]
    }

    // Radii.
    static let radiusSmall: CGFloat = 8
    static let radiusCard: CGFloat = 14
    static let radiusPanel: CGFloat = 18
    static let radiusStage: CGFloat = 20
}

/// The 4-point spacing scale used by Polar layouts.
enum PolarSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    /// Gutter around the Room Stage and light-page panels.
    static let page: CGFloat = 20
}

extension Color {
    static let polarStage = Polar.stage
    static let polarDeck = Polar.deck
    static let polarDesk = Polar.desk
    static let polarRaised = Polar.raised
    static let polarWall = Polar.wall
    static let polarChalk = Polar.chalk
    static let polarMeter = Polar.meter
    static let polarAccent = Polar.accent
    static let polarMint = Polar.mint
    static let polarSelect = Polar.select
    static let polarPending = Polar.pending
    static let polarChanged = Polar.changed
    static let polarAttention = Polar.attention
}

extension Font {
    /// SF Pro Rounded — titles, room names, light names.
    static func polarDisplay(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// SF Pro Text — body, labels, chrome.
    static func polarUI(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// SF Mono — Kelvin, percentages, zone and segment numbers.
    static func polarMono(_ size: CGFloat = 12, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Small uppercase section captions ("ROOMS", "SELECTION").
    static let polarCaption: Font = .system(size: 11, weight: .semibold, design: .default)
}
