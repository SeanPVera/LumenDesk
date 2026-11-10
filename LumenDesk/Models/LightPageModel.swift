import Foundation

// MARK: - Per-light page routing
//
// Each fixture model Sean owns gets its own light page, chosen by its exact
// vendor model code or LIFX product ID — never by a loose family guess. Any
// other fixture keeps the pre-redesign routing (Shapes studio, Luna editor,
// Govee segment studio, basic editor) through `.fallback`, so nothing that
// worked before loses its editor.

/// The LIFX colour bulbs that share the Colour Bulb page, keyed by the
/// product ID StateVersion (33) reports.
enum LIFXBulbVariant: UInt32, CaseIterable, Equatable {
    case colorA19 = 93
    case color800 = 129
    case color800lm = 91
    case mini = 181

    var displayName: String {
        switch self {
        case .colorA19: return "LIFX Color A19"
        case .color800: return "LIFX Color 800"
        case .color800lm: return "LIFX Color 800 lm"
        case .mini: return "LIFX Mini"
        }
    }

    var chipLabel: String {
        switch self {
        case .colorA19: return "A19 · 93"
        case .color800: return "Color 800 · 129"
        case .color800lm: return "800lm · 91"
        case .mini: return "Mini · 181"
        }
    }
}

/// A dedicated light page. One case per owned model.
enum LightPageModel: Equatable {
    /// LIFX Luna (product 219): 5×6 matrix paint.
    case lifxLuna
    /// LIFX colour bulbs (Mini, A19, Color 800): colour and white point.
    case lifxColorBulb(LIFXBulbVariant)
    /// Nanoleaf Shapes NL42 (White Hexagons): panel layout studio.
    case nanoleafHexagons
    /// Govee H70B1 Curtain Lights: 20 LAN-addressable columns.
    case goveeCurtain
    /// Govee H70BC (Living Room String Light): curtain-family, 20 columns.
    case goveeCurtainString
    /// Govee H61E6 COB strip: 15 blended zones.
    case goveeCOBStrip
    /// Govee H6062 Glide light bars: 28 chained zones.
    case goveeGlideBars
    /// Govee H60B0 Uplighter floor lamp: 3 named zones, 2 lit at once.
    case goveeUplighter
    /// Govee H608B string pods: 15 bulbs.
    case goveeStringPods
    /// Govee H612B Strip Light S: 75 segments.
    case goveeStripS
    /// Anything else: the editor routing that predates the redesign.
    case fallback(FallbackEditor)

    enum FallbackEditor: Equatable {
        case nanoleafStudio
        case lunaMatrix
        case goveeSegments
        case basic
    }

    /// Resolves the page from what discovery reported. Pure, so tests can
    /// pin every owned model without a LightManager.
    static func resolve(brand: LightDevice.Brand, sku: String?, productID: UInt32?) -> LightPageModel {
        let code = sku?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch brand {
        case .lifx:
            if productID == 219 { return .lifxLuna }
            if let productID, let variant = LIFXBulbVariant(rawValue: productID) {
                return .lifxColorBulb(variant)
            }
            if LIFXProductCatalog.isLuna(productID) || code == LIFXProductCatalog.lunaSKU {
                return .fallback(.lunaMatrix)
            }
            return .fallback(.basic)
        case .nanoleaf:
            if code == "NL42" { return .nanoleafHexagons }
            return .fallback(.nanoleafStudio)
        case .govee:
            switch code {
            case "H70B1": return .goveeCurtain
            case "H70BC": return .goveeCurtainString
            case "H61E6": return .goveeCOBStrip
            case "H6062": return .goveeGlideBars
            case "H60B0": return .goveeUplighter
            case "H608B": return .goveeStringPods
            case "H612B": return .goveeStripS
            default: return .fallback(.goveeSegments)
            }
        }
    }

    static func resolve(_ device: LightDevice) -> LightPageModel {
        resolve(brand: device.brand, sku: device.sku, productID: device.productID)
    }

    /// True for the models that have a bespoke Polar page.
    var isDedicatedPage: Bool {
        if case .fallback = self { return false }
        return true
    }

    /// The model line under the light's name, e.g. "Govee H70B1 · Curtain · 20 LAN columns".
    var modelLine: String {
        switch self {
        case .lifxLuna: return "LIFX Luna · product 219 · 5×6 matrix"
        case .lifxColorBulb(let variant): return "\(variant.displayName) · product \(variant.rawValue)"
        case .nanoleafHexagons: return "Nanoleaf Shapes Hexagons · NL42"
        case .goveeCurtain: return "Govee H70B1 · Curtain · 20 LAN columns"
        case .goveeCurtainString: return "Govee H70BC · Curtain family · 20 LAN columns"
        case .goveeCOBStrip: return "Govee H61E6 · COB strip · 15 zones"
        case .goveeGlideBars: return "Govee H6062 · Glide light bars · 28 zones"
        case .goveeUplighter: return "Govee H60B0 · Uplighter · ripple, side ring, down light · 2 lit"
        case .goveeStringPods: return "Govee H608B · RGBIC string pods · 15"
        case .goveeStripS: return "Govee H612B · Strip Light S · 75 segments"
        case .fallback: return ""
        }
    }

    /// Caption over the hero visual.
    var heroTitle: String {
        switch self {
        case .lifxLuna: return "LIFX Luna · 26 zones"
        case .lifxColorBulb: return "Colour bulb · single emitter"
        case .nanoleafHexagons: return "Shapes Hexagons · layout"
        case .goveeCurtain, .goveeCurtainString: return "Curtain · 20 columns"
        case .goveeCOBStrip: return "COB strip · 15 zones"
        case .goveeGlideBars: return "Glide bars · 28 zones"
        case .goveeUplighter: return "Uplighter · 3 sections"
        case .goveeStringPods: return "String pods · 15"
        case .goveeStripS: return "LED strip · 75 segments"
        case .fallback: return "Fixture"
        }
    }

    /// Caption over the painter / control panel.
    var painterTitle: String {
        switch self {
        case .lifxLuna: return "Matrix paint"
        case .lifxColorBulb: return "Colour & white"
        case .nanoleafHexagons: return "Paint & scenes"
        case .goveeCurtain, .goveeCurtainString: return "Column painter · 20"
        case .goveeCOBStrip: return "Zone painter · 15"
        case .goveeGlideBars: return "Wall-chain zones · 28"
        case .goveeUplighter: return "Sections · 2 lit at a time"
        case .goveeStringPods: return "Pod painter · 15"
        case .goveeStripS: return "Segment painter · 75"
        case .fallback: return "Controls"
        }
    }

    var silhouette: OrbSilhouette {
        switch self {
        case .lifxLuna: return .matrix
        case .lifxColorBulb: return .bulb
        case .nanoleafHexagons: return .panels
        case .goveeCurtain, .goveeCurtainString: return .curtain
        case .goveeCOBStrip, .goveeStripS: return .strip
        case .goveeGlideBars: return .bars
        case .goveeUplighter: return .lamp
        case .goveeStringPods: return .pods
        case .fallback(let editor):
            switch editor {
            case .nanoleafStudio: return .panels
            case .lunaMatrix: return .matrix
            case .goveeSegments: return .strip
            case .basic: return .bulb
            }
        }
    }

    /// Segment-strip layout hints for the hero read-out of zoned Govee pages.
    var heroRowLength: Int? {
        switch self {
        case .goveeStripS: return 15
        case .goveeGlideBars: return 14
        default: return nil
        }
    }

    var heroLabelEvery: Int {
        switch self {
        case .goveeStripS: return 5
        case .goveeGlideBars: return 1
        default: return 1
        }
    }
}
