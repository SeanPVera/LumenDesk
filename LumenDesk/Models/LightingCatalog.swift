import SwiftUI

struct CatalogColor: Hashable {
    let hex: UInt

    var color: Color { Color(hex: hex) }

    /// The entry split into chroma and its own level, so both transports can
    /// be handed the same colour at one agreed brightness.
    var tone: PaletteTone { PaletteTone(hex: hex) }
}

extension PaletteTone {
    /// The tone at full value, which is what both transports are sent. Level
    /// travels separately as the fixture's brightness, so a swatch here shows
    /// the colour the light emits rather than a pre-dimmed version of it.
    var displayColor: Color {
        let components = rgb(atLevel: 1)
        return Color(.sRGB, red: components.red, green: components.green,
                     blue: components.blue, opacity: 1)
    }

    /// The tone as it will actually land in the room, for previews that show
    /// brightness as well as colour.
    func emittedColor(scaledBy brightness: Double) -> Color {
        let components = rgb(atLevel: max(0, min(1, level * brightness)))
        return Color(.sRGB, red: components.red, green: components.green,
                     blue: components.blue, opacity: 1)
    }
}

struct LightingTheme: Identifiable, Hashable {
    enum Category: String, CaseIterable {
        case warmth = "Warmth"
        case nature = "Nature"
        case atmosphere = "Atmosphere"
        case jewel = "Jewel"
        case nightlife = "Nightlife"
        case dreamy = "Dreamy"
        case celebration = "Celebration"
        case focus = "Focus"
        case everyday = "Everyday"
    }

    let id: String
    let name: String
    let summary: String
    let category: Category
    let icon: String
    let colors: [CatalogColor]
    let brightness: Double
    /// Where the palette is meant to land across a room and along a strip.
    /// Part of the theme's design, not a rendering detail: two themes with the
    /// same four colours and different distributions are different themes.
    let distribution: ThemeDistribution

    /// The palette as tones, with every level measured against the brightest
    /// entry. A palette authored entirely in dark hexes keeps its internal
    /// contrast instead of being crushed twice — how dim the theme runs is
    /// `brightness`'s job, not the hex values'.
    var normalizedTones: [PaletteTone] {
        let tones = colors.map(\.tone)
        let peak = tones.map(\.level).max() ?? 0
        guard peak > 0 else { return tones }
        return tones.map { tone in
            // A shadow colour still has to emit something, or a fixture
            // holding it reads as broken rather than dark.
            PaletteTone(hue: tone.hue,
                        saturation: tone.saturation,
                        level: max(0.2, tone.level / peak))
        }
    }

    /// The colour a lone bulb takes, and the colour every fixture takes under
    /// an even wash.
    var keyTone: PaletteTone {
        normalizedTones.first ?? PaletteTone(hue: 0, saturation: 0, level: 1)
    }

    /// The palette as Music Mode carries it. The choreography engine takes hue
    /// and saturation from each entry and gets brightness from the audio, so
    /// the colours travel across unchanged and the theme keeps its identity
    /// while the music owns timing, intensity, and where the movement goes.
    var musicPalette: [MusicPaletteColor] {
        colors.map { MusicPaletteColor(UInt32($0.hex & 0x00FF_FFFF)) }
    }

    /// How much of a room each palette entry takes under this theme's
    /// distribution, so a swatch can show where the colour actually goes
    /// instead of implying an even split.
    ///
    /// Every entry keeps a visible sliver even when the distribution barely
    /// uses it across fixtures, because on a segmented light it still shows up
    /// — and a card that hid it would be lying about the palette.
    func distributionShares(across fixtures: Int = 8) -> [(tone: PaletteTone, share: Double)] {
        let tones = normalizedTones
        guard tones.count > 1 else { return tones.map { ($0, 1.0) } }
        let room = max(tones.count, fixtures)

        var counts = Array(repeating: 0.0, count: tones.count)
        if distribution == .gradient {
            // A ramp visits every entry on its way across the room.
            counts = Array(repeating: 1.0, count: tones.count)
        } else {
            for position in 0..<room {
                let index = distribution.paletteIndex(position: position, count: tones.count)
                counts[min(index, tones.count - 1)] += 1
            }
        }

        let minimumShare = 0.06
        let raw = counts.map { max(minimumShare, $0 / Double(room)) }
        let total = raw.reduce(0, +)
        guard total > 0 else { return tones.map { ($0, 1.0 / Double(tones.count)) } }
        return tones.indices.map { (tones[$0], raw[$0] / total) }
    }
}

struct LightingEffect: Identifiable, Hashable {
    enum Style: String {
        case colorFlow
        case oceanWave
        case breathe
        case candlelight
        case musicPulse
        case prismShuffle
        case lightning
        case sunrise
        case sunset
    }

    let id: String
    let name: String
    let summary: String
    let icon: String
    let style: Style
    let colors: [CatalogColor]
    let speed: Double
    let isAudioReactive: Bool
    let isHighEnergy: Bool

    /// Target cadence for this effect's animation frames, in seconds.
    ///
    /// `speed` only advances the animation *phase* per frame; it does not set
    /// how often a frame is pushed to the lights. Most effects animate on a
    /// fixed timer at this interval. Audio-reactive effects instead render off
    /// the live audio and use this as the *minimum* spacing between frames, so
    /// the ~50 Hz analysis stream can't flood the bulbs. Calm effects stay
    /// relaxed; the party and music effects tick fast so beats and color
    /// shuffles feel snappy instead of sluggish.
    var frameInterval: TimeInterval {
        switch style {
        case .musicPulse: return 0.06   // Legacy Music Mode compatibility cadence
        case .prismShuffle: return 0.12 // Prism Shuffle: instant party energy
        default: return 0.22
        }
    }
}

enum LightingCatalog {
    /// Built one `add` call at a time rather than as a single array literal.
    /// Swift solves a collection literal as one expression, and forty-eight
    /// struct initialisers in one literal turns a fast file into a slow one;
    /// independent statements are type-checked in isolation and stay cheap
    /// however far the catalog grows. `GoveeSegmentProfile` is built the same
    /// way for the same reason.
    static let themes: [LightingTheme] = {
        var rows: [LightingTheme] = []
        func add(_ id: String, _ name: String, _ summary: String,
                 _ category: LightingTheme.Category, _ icon: String,
                 _ colors: [UInt], _ brightness: Double,
                 _ distribution: ThemeDistribution) {
            rows.append(LightingTheme(id: id, name: name, summary: summary,
                                      category: category, icon: icon,
                                      colors: colors.map(CatalogColor.init),
                                      brightness: brightness,
                                      distribution: distribution))
        }

        // MARK: Original catalog
        // Identifiers, names, palettes, and brightness are unchanged. Each row
        // gained the distribution that matches how it was already described.
        add("aurora", "Aurora Veil", "Icy turquoise, violet, and arctic blue drift across the room.", .nature, "mountain.2.fill", [0x38E8D4, 0x6D7CFF, 0xB65CFF, 0x2EA9FF], 0.72, .gradient)
        add("afterglow", "Afterglow", "A mellow horizon of peach, coral, rose, and fading violet.", .atmosphere, "sun.horizon.fill", [0xFFB36B, 0xFF6F61, 0xF24B88, 0x7B4BD4], 0.64, .gradient)
        add("tidepool", "Tidepool", "Clear cyan, sea glass, and deep-water blue.", .nature, "water.waves", [0x43E6D1, 0x27B9E8, 0x246BCE, 0x18438E], 0.68, .gradient)
        add("forest-bath", "Forest Bath", "Moss, fern, jade, and a touch of filtered sunlight.", .nature, "leaf.fill", [0x294F35, 0x3E8E58, 0x79C267, 0xD2C66D], 0.58, .scattered)
        add("wildflowers", "Wildflowers", "A playful meadow of poppy, lavender, buttercup, and cornflower.", .nature, "camera.macro", [0xFF5D6C, 0xB779FF, 0xFFD45A, 0x568CFF, 0xFF91C8], 0.76, .scattered)
        add("moon-garden", "Moon Garden", "Moonlit silver-blue with mysterious indigo and lilac.", .atmosphere, "moon.stars.fill", [0xC7D5FF, 0x8299E8, 0x4D56A8, 0x8C68C8], 0.38, .anchored)
        add("ember", "Ember & Ash", "Low, intimate tones of coal red, amber, and firelight.", .atmosphere, "flame.fill", [0x7D1D18, 0xD64724, 0xFF8A32, 0xFFC45B], 0.52, .anchored)
        add("candy-cloud", "Candy Cloud", "Soft strawberry, cotton-candy blue, and whipped lavender.", .atmosphere, "cloud.fill", [0xFF9EBB, 0x8FD8FF, 0xD5A6FF, 0xFFD0E5], 0.62, .scattered)
        add("synthwave", "Synthwave", "Electric magenta and laser blue against a violet night.", .celebration, "waveform.path.ecg", [0xFF2E9A, 0x8A35FF, 0x1B8CFF, 0x24104F], 0.82, .alternating)
        add("arcade", "Arcade Tokens", "Saturated cabinet colors: cyan, lime, hot pink, and coin gold.", .celebration, "gamecontroller.fill", [0x00E5FF, 0x8CFF4D, 0xFF3B9D, 0xFFD43B], 0.86, .scattered)
        add("festival", "Festival Lanterns", "A warm gathering of crimson, marigold, jade, and plum.", .celebration, "party.popper.fill", [0xD93A3A, 0xFFB52E, 0x2CAB6F, 0x8E44AD], 0.78, .alternating)
        add("ice-cream", "Ice Cream Social", "Pistachio, mango, raspberry, and blueberry sorbet.", .celebration, "birthday.cake.fill", [0xA7E8A1, 0xFFD27D, 0xFF7BA8, 0x83B6FF], 0.72, .alternating)
        add("deep-work", "Deep Work", "Calm cobalt and cool cyan designed to keep visual energy steady.", .focus, "brain.head.profile", [0x3157C8, 0x397ED1, 0x4CB6C4], 0.66, .wash)
        add("reading-nook", "Reading Nook", "Warm amber and honey tones for a cozy evening chapter.", .focus, "book.closed.fill", [0xFFB45C, 0xFFD08A, 0xE58B3F], 0.58, .wash)
        add("creative-spark", "Creative Spark", "Bright coral, golden yellow, and energizing turquoise.", .focus, "paintpalette.fill", [0xFF665A, 0xFFC83D, 0x2FD6C5, 0x6878FF], 0.78, .scattered)
        add("calm", "Quiet Mind", "Muted lavender, dusk blue, and gentle rose for winding down.", .focus, "figure.mind.and.body", [0x9B8FD2, 0x7187B5, 0xC58FA8], 0.36, .wash)
        add("desert", "Desert Modern", "Terracotta, sandstone, sage, and a clear turquoise accent.", .atmosphere, "sun.max.fill", [0xC75B3A, 0xD9A66F, 0x82936F, 0x3FA7A3], 0.64, .anchored)
        add("galaxy", "Pocket Galaxy", "Nebula pink, cosmic violet, star blue, and midnight.", .atmosphere, "sparkles", [0xEF4FA6, 0x8A4FFF, 0x3A75E8, 0x17123F], 0.68, .anchored)

        // MARK: Warmth — low, close, and deliberately not another amber ramp
        add("mulled-wine", "Mulled Wine", "Wine and garnet held low, with one slice of orange peel.", .warmth, "cup.and.saucer.fill", [0x7A1C33, 0xB32D3C, 0xD9803C, 0xC2A05E], 0.38, .anchored)
        add("lantern-street", "Lantern Street", "Sodium-gold street light with a deep teal shadow behind it.", .warmth, "lamp.ceiling.fill", [0xFFA63C, 0xE07326, 0xB44A18, 0x1F4E52], 0.54, .anchored)
        add("cocoa-rose", "Cocoa Rose", "Cocoa deepening into blush and warm cream. No orange in it.", .warmth, "heart.fill", [0x63332F, 0xC47C76, 0xEDAFA8, 0xF7DBCE], 0.50, .gradient)
        add("brass-smoke", "Brass & Smoke", "Old brass and tobacco over grey smoke, with a single ember.", .warmth, "smoke.fill", [0xC79A42, 0x8A6B33, 0x5A5550, 0xA33518], 0.44, .anchored)
        add("paper-lantern", "Paper Lantern", "Warm paper glow carrying a faint persimmon and a thread of jade.", .warmth, "lamp.table.fill", [0xFFD9A0, 0xF2B071, 0xD9674B, 0x8FA87A], 0.56, .wash)

        // MARK: Nature — landscape light, mostly desaturated
        add("petrichor", "Petrichor", "Wet stone and damp moss. Grey-green, flat, and quiet.", .nature, "cloud.drizzle.fill", [0xA8B8B6, 0x7E9390, 0x5E6F73, 0x46605A], 0.46, .wash)
        add("salt-flat", "Salt Flat", "Bleached white with pale mineral blue, faint pink, and dry straw.", .nature, "sun.haze.fill", [0xE4EEF2, 0xB4CEDC, 0xE6C6CE, 0xD6CCA8], 0.74, .gradient)
        add("kelp-forest", "Kelp Forest", "Dark water and olive kelp, cut by one shaft of amber sun.", .nature, "fish.fill", [0x123F3A, 0x2C6B4F, 0x6E8F3C, 0xD9A441], 0.50, .gradient)
        add("glacier-melt", "Glacier Melt", "Ice blue thinning into meltwater, over crevasse blue and silt.", .nature, "snowflake", [0xBDE6F2, 0x6FB8D9, 0x1F5F85, 0x9AA6A8], 0.62, .gradient)
        add("thunder-plain", "Thunder Plain", "Storm grey and bruised violet with wheat gold under it.", .nature, "cloud.bolt.fill", [0x3A4750, 0x5C5A72, 0x8C8A5E, 0xD9C27E], 0.48, .anchored)

        // MARK: Jewel — one saturated stone, one metal, and somewhere dark to sit
        add("emerald-study", "Emerald Study", "Deep emerald with brass, against near-black bottle green.", .jewel, "books.vertical.fill", [0x0B6B45, 0x139960, 0xC9A227, 0x06332A], 0.46, .anchored)
        add("sapphire-hour", "Sapphire Hour", "Royal sapphire climbing to a cold platinum highlight.", .jewel, "diamond.fill", [0x143C8C, 0x1E5FC4, 0x2B86E0, 0xCBD9F2], 0.50, .gradient)
        add("ruby-velvet", "Ruby Velvet", "Ruby over oxblood with a rose-gold edge.", .jewel, "theatermasks.fill", [0x8C0F2B, 0xC41E3A, 0xE0736B, 0x4A0A1C], 0.40, .anchored)
        add("amethyst-court", "Amethyst Court", "Amethyst and violet lifted by a single antique gold.", .jewel, "crown.fill", [0x5B2D8C, 0x8547C9, 0xB79CE0, 0xC9A227], 0.48, .anchored)
        add("malachite-ink", "Malachite & Ink", "Malachite green against ink blue, with pale jade on top.", .jewel, "drop.fill", [0x0F8A7A, 0x19B49C, 0x101C3A, 0x7FD9CE], 0.44, .alternating)

        // MARK: Nightlife — sign colours, high output
        add("tokyo-rain", "Tokyo Rain", "Sign cyan and sign red over wet asphalt blue, with one white hit.", .nightlife, "cloud.rain.fill", [0x12D9E8, 0xE81E4D, 0x1B2A6B, 0xF0F4FF], 0.78, .scattered)
        add("acid-house", "Acid House", "Acid yellow-green against blacklight violet and magenta.", .nightlife, "circle.hexagongrid.fill", [0xD8FF2E, 0x8CE01E, 0x6A1FE0, 0xFF2FD0], 0.84, .alternating)
        add("last-call", "Last Call", "Warm bar neon: pink and amber over bottle green and dark red.", .nightlife, "music.mic", [0xFF5C8A, 0xE8A33D, 0x1F5E3A, 0x8C1A2B], 0.64, .scattered)
        add("blacklight", "Blacklight", "Ultraviolet violet with lime and cyan fluorescing out of it.", .nightlife, "bolt.fill", [0x6A22E0, 0x3A0F8C, 0xA8FF3C, 0x2BE0D9], 0.60, .anchored)
        add("chrome-bass", "Chrome Bass", "Cold steel and ice blue over navy, with one sodium orange.", .nightlife, "speaker.wave.3.fill", [0xE6F0FA, 0x8FB6D9, 0x1F3A66, 0xFF7A1F], 0.72, .anchored)

        // MARK: Dreamy — soft, low chroma, nothing competing
        add("linen-dusk", "Linen Dusk", "Oat linen and faded denim with a soft clay warmth.", .dreamy, "sunset.fill", [0xEFDCC0, 0x8FA6C4, 0xC9A08A, 0xF7EEDC], 0.52, .gradient)
        add("peony-fade", "Peony Fade", "Peony pink fading into cream, with a quiet sage behind.", .dreamy, "sparkle", [0xF4C2CC, 0xE49AAE, 0xF8E6D4, 0xAEC2A0], 0.56, .gradient)
        add("sea-glass", "Sea Glass", "Misted aqua and mint over pale sand. Nothing saturated.", .dreamy, "wind", [0x9CDCC6, 0x6FBCB4, 0xDCE8C0, 0xC4E2E8], 0.60, .wash)
        add("cashmere", "Cashmere", "Warm grey and taupe with a mauve you almost miss.", .dreamy, "moon.fill", [0xDCCFC0, 0xA89080, 0xC496A6, 0xF2E9DE], 0.50, .wash)
        add("nightlight", "Nightlight", "Low amber against plum and near-black blue. For three in the morning.", .dreamy, "moon.zzz.fill", [0x8C5A2B, 0x4A2340, 0x1A1F3A, 0xD9A05E], 0.16, .anchored)

        // MARK: Everyday — light you can actually live under
        add("morning-desk", "Morning Desk", "Cool near-white with a faint blue lift. Plain working light.", .everyday, "desktopcomputer", [0xF7FAFD, 0xE2EEF7, 0xC9E0F0], 0.86, .wash)
        add("kitchen-noon", "Kitchen Noon", "Bright neutral white with a warm bias, so food looks right.", .everyday, "fork.knife", [0xFFF4E2, 0xFCE8C8, 0xF0D9A8], 0.92, .wash)
        add("supper-table", "Supper Table", "A warm gold pool at the table, neutral walls, one sage note.", .everyday, "table.furniture", [0xFFC87A, 0xF5EDE0, 0x9AA88C], 0.66, .anchored)
        add("hallway-low", "Hallway Low", "Low warm neutral for moving through a house at night.", .everyday, "figure.walk", [0xEADACA, 0xC5AE96, 0x8A7A6A], 0.26, .wash)
        add("wind-down", "Wind Down", "Amber falling to rust, with no blue in it at all.", .everyday, "bed.double.fill", [0xD9925A, 0xA85436, 0x6B2E2A], 0.34, .gradient)

        return rows
    }()

    static func theme(withID id: String) -> LightingTheme? {
        themes.first { $0.id == id }
    }

    static let effects: [LightingEffect] = [
        effect("color-flow", "Color Flow", "A smooth rainbow travels from bulb to bulb.", "rainbow", .colorFlow, [0xFF3B5C, 0xFFB13B, 0x50E36B, 0x36C5F0, 0x7657FF, 0xEE4BCE], 0.16),
        effect("ocean-wave", "Ocean Wave", "Rolling bands of aqua and deep blue rise and recede.", "water.waves", .oceanWave, [0x56E0D5, 0x22AFCF, 0x2867C7, 0x15366E], 0.12),
        effect("breathe", "Breathe", "The room slowly inhales and exhales with a tranquil violet glow.", "lungs.fill", .breathe, [0x7E6BFF, 0xC17DFF, 0x5976D9], 0.10),
        effect("candlelight", "Candlelight", "Independent amber flickers create the warmth of a cluster of candles.", "flame.fill", .candlelight, [0xFF7A24, 0xFFAA3C, 0xFFD178, 0xD94A1E], 0.22),
        effect("music-pulse", "Music Mode", "Local system-audio choreography on Mac and microphone-driven lighting on iPhone and iPad. Soundcheck is included as a preset.", "music.note.list", .musicPulse, [0xFF3B9D, 0x7D5CFF, 0x16D9D0, 0xFFB52E], 0.09, audio: true, energy: true),
        effect("prism-shuffle", "Prism Shuffle", "Bold color combinations reshuffle for instant party energy.", "die.face.5.fill", .prismShuffle, [0xFF3155, 0xFFCC33, 0x39E681, 0x32A8FF, 0xA64DFF], 0.24, energy: true),
        effect("summer-storm", "Summer Storm", "Moody blue calm interrupted by sudden white-violet lightning.", "cloud.bolt.rain.fill", .lightning, [0x132957, 0x274B8C, 0x899FE8, 0xE9EDFF], 0.20, energy: true),
        effect("sunrise", "Golden Sunrise", "Night blue gradually warms through rose into daylight gold.", "sunrise.fill", .sunrise, [0x172B62, 0x6D4D91, 0xE96F76, 0xFFB45D, 0xFFF0C2], 0.025),
        effect("sunset", "Slow Sunset", "Daylight melts into amber, magenta, and a restful deep violet.", "sunset.fill", .sunset, [0xFFE2A6, 0xFF9A52, 0xE34C73, 0x753B8F, 0x251D59], 0.025)
    ]

    private static func effect(_ id: String, _ name: String, _ summary: String, _ icon: String, _ style: LightingEffect.Style, _ colors: [UInt], _ speed: Double, audio: Bool = false, energy: Bool = false) -> LightingEffect {
        LightingEffect(id: id, name: name, summary: summary, icon: icon, style: style, colors: colors.map(CatalogColor.init), speed: speed, isAudioReactive: audio, isHighEnergy: energy)
    }
}
