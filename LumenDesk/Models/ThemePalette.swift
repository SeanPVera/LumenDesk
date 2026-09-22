import Foundation

// MARK: - Palette tones

/// One palette entry split into the two things a fixture treats separately:
/// its chroma (hue and saturation) and how bright that entry is meant to burn
/// relative to the rest of the palette.
///
/// A hex value carries both at once, which is fine on screen and wrong on a
/// bulb. LIFX takes hue, saturation, and brightness as independent channels
/// and ignores how dark the authored hex was; Govee takes raw RGB, so the
/// same dark hex arrives dimmed once by its own value and again by the
/// fixture's brightness. Splitting the entry here lets both transports be fed
/// the identical chroma at full value plus one agreed brightness, so a theme
/// looks the same across brands instead of a shade darker on one of them.
struct PaletteTone: Equatable {
    /// 0…1, wrapping.
    var hue: Double
    /// 0…1.
    var saturation: Double
    /// 0…1. The entry's own value, before the theme's brightness is applied.
    var level: Double

    init(hue: Double, saturation: Double, level: Double) {
        self.hue = hue.wrappedHue
        self.saturation = max(0, min(1, saturation))
        self.level = max(0, min(1, level))
    }

    /// Decomposes a `0xRRGGBB` literal without going through `NSColor` or
    /// `UIColor`, so the result is identical on both platforms and in tests.
    init(hex: UInt) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        let maximum = max(r, max(g, b))
        let minimum = min(r, min(g, b))
        let delta = maximum - minimum

        var hue = 0.0
        if delta > 0 {
            if maximum == r {
                hue = (g - b) / delta
            } else if maximum == g {
                hue = 2 + (b - r) / delta
            } else {
                hue = 4 + (r - g) / delta
            }
            hue /= 6
        }
        self.init(hue: hue,
                  saturation: maximum > 0 ? delta / maximum : 0,
                  level: maximum)
    }

    /// sRGB components for this tone at an explicit value.
    func rgb(atLevel value: Double) -> (red: Double, green: Double, blue: Double) {
        let v = max(0, min(1, value))
        guard saturation > 0 else { return (v, v, v) }
        let sector = hue * 6
        let index = Int(sector) % 6
        let fraction = sector - Double(Int(sector))
        let p = v * (1 - saturation)
        let q = v * (1 - saturation * fraction)
        let t = v * (1 - saturation * (1 - fraction))
        switch index {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    /// The tone rebuilt as a `0xRRGGBB` literal at an explicit value. Used for
    /// Music Mode palettes and for the catalog audit.
    func hex(atLevel value: Double) -> UInt32 {
        let components = rgb(atLevel: value)
        let r = UInt32(max(0, min(255, (components.red * 255).rounded())))
        let g = UInt32(max(0, min(255, (components.green * 255).rounded())))
        let b = UInt32(max(0, min(255, (components.blue * 255).rounded())))
        return (r << 16) | (g << 8) | b
    }

    /// Blend toward another tone, taking the short way around the hue circle
    /// so a red-to-magenta ramp never detours through green.
    static func blend(_ from: PaletteTone, _ to: PaletteTone, fraction: Double) -> PaletteTone {
        let t = max(0, min(1, fraction))
        var delta = to.hue - from.hue
        if delta > 0.5 { delta -= 1 }
        if delta < -0.5 { delta += 1 }
        // An achromatic endpoint has no hue worth travelling to; hold the
        // other end's hue so a ramp into white doesn't swing through a
        // hue it was never given.
        let hue: Double
        if from.saturation <= 0.001 {
            hue = to.hue
        } else if to.saturation <= 0.001 {
            hue = from.hue
        } else {
            hue = from.hue + delta * t
        }
        return PaletteTone(
            hue: hue,
            saturation: from.saturation + (to.saturation - from.saturation) * t,
            level: from.level + (to.level - from.level) * t
        )
    }

    /// Samples a palette at a 0…1 position across its whole length.
    static func ramp(_ tones: [PaletteTone], position: Double) -> PaletteTone {
        guard let first = tones.first else { return PaletteTone(hue: 0, saturation: 0, level: 1) }
        guard tones.count > 1 else { return first }
        let clamped = max(0, min(1, position))
        let scaled = clamped * Double(tones.count - 1)
        let low = min(tones.count - 1, Int(scaled))
        let high = min(tones.count - 1, low + 1)
        return blend(tones[low], tones[high], fraction: scaled - Double(low))
    }
}

private extension Double {
    var wrappedHue: Double {
        guard isFinite else { return 0 }
        let value = truncatingRemainder(dividingBy: 1)
        return value < 0 ? value + 1 : value
    }
}

// MARK: - Distribution

/// How a theme's colours are meant to be spread over whatever the room has.
///
/// The same five rules drive fixture-to-fixture placement and segment-to-segment
/// placement inside one RGBIC strip or matrix, so a theme reads as itself
/// whether the room holds one bulb, six bulbs, or a 200-bead string.
enum ThemeDistribution: String, CaseIterable {
    /// One key colour fills the room. The rest of the palette only shows up as
    /// a low-contrast breath inside segmented fixtures.
    case wash
    /// The key colour holds most of the room; the remaining colours land on a
    /// minority of fixtures and in short runs along a strip.
    case anchored
    /// The palette ramps in order across the room and along each strip.
    case gradient
    /// Colours change fixture by fixture and in even blocks along a strip.
    case alternating
    /// Colours spread so that no two neighbours match, without reading as a
    /// repeating loop.
    case scattered

    var displayName: String {
        switch self {
        case .wash: return "Even wash"
        case .anchored: return "Anchored"
        case .gradient: return "Gradient"
        case .alternating: return "Alternating"
        case .scattered: return "Scattered"
        }
    }

    /// Plain-language description of where the colours are meant to land.
    var summary: String {
        switch self {
        case .wash:
            return "One colour fills the room; strips carry a faint second tone."
        case .anchored:
            return "One colour holds the room; the others appear as accents."
        case .gradient:
            return "The palette ramps in order across the room and along strips."
        case .alternating:
            return "Colours change from fixture to fixture in even blocks."
        case .scattered:
            return "Colours spread so neighbouring fixtures never match."
        }
    }

    /// Whether a fixture that can blend neighbouring segments should.
    /// Crisp distributions lose their point when the hardware smears them.
    var blendsSegments: Bool {
        switch self {
        case .wash, .gradient: return true
        case .anchored, .alternating, .scattered: return false
        }
    }

    /// Which palette entry a fixture at `position` takes, for the index-based
    /// distributions. `gradient` is sampled continuously instead.
    func paletteIndex(position: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let i = max(0, position)
        switch self {
        case .wash:
            return 0
        case .gradient:
            // Callers ramp; this keeps the function total.
            return min(count - 1, i % count)
        case .anchored:
            // Accents take roughly every third slot, starting at the second
            // fixture so a pair of lights still shows two colours.
            guard i % 3 == 1 else { return 0 }
            return 1 + ((i / 3) % (count - 1))
        case .alternating:
            return i % count
        case .scattered:
            // Each pass through the palette starts on a different entry, so
            // the spread never settles into a visible loop. The rotation is
            // chosen so the last slot of one pass can't repeat the first slot
            // of the next: a rotation of `count - 1` would always do exactly
            // that, which rules out 2 for three-colour palettes.
            let rotation = count <= 2 ? 0 : (count == 3 ? 1 : 2)
            return (i + (i / count) * rotation) % count
        }
    }
}
