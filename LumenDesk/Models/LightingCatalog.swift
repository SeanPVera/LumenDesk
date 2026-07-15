import SwiftUI

struct CatalogColor: Hashable {
    let hex: UInt

    var color: Color { Color(hex: hex) }
}

struct LightingTheme: Identifiable, Hashable {
    enum Category: String, CaseIterable {
        case nature = "Nature"
        case atmosphere = "Atmosphere"
        case celebration = "Celebration"
        case focus = "Focus"
    }

    let id: String
    let name: String
    let summary: String
    let category: Category
    let icon: String
    let colors: [CatalogColor]
    let brightness: Double
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
    static let themes: [LightingTheme] = [
        theme("aurora", "Aurora Veil", "Icy turquoise, violet, and arctic blue drift across the room.", .nature, "mountain.2.fill", [0x38E8D4, 0x6D7CFF, 0xB65CFF, 0x2EA9FF], 0.72),
        theme("afterglow", "Afterglow", "A mellow horizon of peach, coral, rose, and fading violet.", .atmosphere, "sun.horizon.fill", [0xFFB36B, 0xFF6F61, 0xF24B88, 0x7B4BD4], 0.64),
        theme("tidepool", "Tidepool", "Clear cyan, sea glass, and deep-water blue.", .nature, "water.waves", [0x43E6D1, 0x27B9E8, 0x246BCE, 0x18438E], 0.68),
        theme("forest-bath", "Forest Bath", "Moss, fern, jade, and a touch of filtered sunlight.", .nature, "leaf.fill", [0x294F35, 0x3E8E58, 0x79C267, 0xD2C66D], 0.58),
        theme("wildflowers", "Wildflowers", "A playful meadow of poppy, lavender, buttercup, and cornflower.", .nature, "camera.macro", [0xFF5D6C, 0xB779FF, 0xFFD45A, 0x568CFF, 0xFF91C8], 0.76),
        theme("moon-garden", "Moon Garden", "Moonlit silver-blue with mysterious indigo and lilac.", .atmosphere, "moon.stars.fill", [0xC7D5FF, 0x8299E8, 0x4D56A8, 0x8C68C8], 0.38),
        theme("ember", "Ember & Ash", "Low, intimate tones of coal red, amber, and firelight.", .atmosphere, "flame.fill", [0x7D1D18, 0xD64724, 0xFF8A32, 0xFFC45B], 0.52),
        theme("candy-cloud", "Candy Cloud", "Soft strawberry, cotton-candy blue, and whipped lavender.", .atmosphere, "cloud.fill", [0xFF9EBB, 0x8FD8FF, 0xD5A6FF, 0xFFD0E5], 0.62),
        theme("synthwave", "Synthwave", "Electric magenta and laser blue against a violet night.", .celebration, "waveform.path.ecg", [0xFF2E9A, 0x8A35FF, 0x1B8CFF, 0x24104F], 0.82),
        theme("arcade", "Arcade Tokens", "Saturated cabinet colors: cyan, lime, hot pink, and coin gold.", .celebration, "gamecontroller.fill", [0x00E5FF, 0x8CFF4D, 0xFF3B9D, 0xFFD43B], 0.86),
        theme("festival", "Festival Lanterns", "A warm gathering of crimson, marigold, jade, and plum.", .celebration, "party.popper.fill", [0xD93A3A, 0xFFB52E, 0x2CAB6F, 0x8E44AD], 0.78),
        theme("ice-cream", "Ice Cream Social", "Pistachio, mango, raspberry, and blueberry sorbet.", .celebration, "birthday.cake.fill", [0xA7E8A1, 0xFFD27D, 0xFF7BA8, 0x83B6FF], 0.72),
        theme("deep-work", "Deep Work", "Calm cobalt and cool cyan designed to keep visual energy steady.", .focus, "brain.head.profile", [0x3157C8, 0x397ED1, 0x4CB6C4], 0.66),
        theme("reading-nook", "Reading Nook", "Warm amber and honey tones for a cozy evening chapter.", .focus, "book.closed.fill", [0xFFB45C, 0xFFD08A, 0xE58B3F], 0.58),
        theme("creative-spark", "Creative Spark", "Bright coral, golden yellow, and energizing turquoise.", .focus, "paintpalette.fill", [0xFF665A, 0xFFC83D, 0x2FD6C5, 0x6878FF], 0.78),
        theme("calm", "Quiet Mind", "Muted lavender, dusk blue, and gentle rose for winding down.", .focus, "figure.mind.and.body", [0x9B8FD2, 0x7187B5, 0xC58FA8], 0.36),
        theme("desert", "Desert Modern", "Terracotta, sandstone, sage, and a clear turquoise accent.", .atmosphere, "sun.max.fill", [0xC75B3A, 0xD9A66F, 0x82936F, 0x3FA7A3], 0.64),
        theme("galaxy", "Pocket Galaxy", "Nebula pink, cosmic violet, star blue, and midnight.", .atmosphere, "sparkles", [0xEF4FA6, 0x8A4FFF, 0x3A75E8, 0x17123F], 0.68)
    ]

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

    private static func theme(_ id: String, _ name: String, _ summary: String, _ category: LightingTheme.Category, _ icon: String, _ colors: [UInt], _ brightness: Double) -> LightingTheme {
        LightingTheme(id: id, name: name, summary: summary, category: category, icon: icon, colors: colors.map(CatalogColor.init), brightness: brightness)
    }

    private static func effect(_ id: String, _ name: String, _ summary: String, _ icon: String, _ style: LightingEffect.Style, _ colors: [UInt], _ speed: Double, audio: Bool = false, energy: Bool = false) -> LightingEffect {
        LightingEffect(id: id, name: name, summary: summary, icon: icon, style: style, colors: colors.map(CatalogColor.init), speed: speed, isAudioReactive: audio, isHighEnergy: energy)
    }
}
