import Foundation
import SwiftUI

enum LIFXProductCatalog {
    static let lunaProductIDs: Set<UInt32> = [219, 220]
    static let lunaSKU = "LFXCAP8/RGBW/WH"

    static func isLuna(_ productID: UInt32?) -> Bool {
        productID.map(lunaProductIDs.contains) == true
    }

    static func sku(for productID: UInt32) -> String? {
        isLuna(productID) ? lunaSKU : nil
    }
}

/// Codable representation of one matrix zone. Keeping the protocol-native
/// values lets scenes and undo restore a Luna layout without losing per-zone
/// brightness or white temperature.
struct LIFXMatrixColor: Codable, Equatable {
    var hue: UInt16
    var saturation: UInt16
    var brightness: UInt16
    var kelvin: UInt16

    init(hue: UInt16, saturation: UInt16, brightness: UInt16, kelvin: UInt16) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
        self.kelvin = kelvin
    }

    init(_ color: LIFXHSBK) {
        self.init(hue: color.hue, saturation: color.saturation,
                  brightness: color.brightness, kelvin: color.kelvin)
    }

    init(color: Color, brightness: Double, kelvin: Int) {
        let hsb = color.hsbComponents
        let safeH = hsb.h.isFinite ? min(1, max(0, hsb.h)) : 0
        let safeS = hsb.s.isFinite ? min(1, max(0, hsb.s)) : 0
        let safeB = brightness.isFinite ? min(1, max(0, brightness)) : 0
        self.init(
            hue: UInt16(max(0, min(65_535, Int((safeH * 65_535).rounded())))),
            saturation: UInt16(max(0, min(65_535, Int((safeS * 65_535).rounded())))),
            brightness: UInt16(max(0, min(65_535, Int((safeB * 65_535).rounded())))),
            kelvin: UInt16(max(1_500, min(9_000, kelvin)))
        )
    }

    enum CodingKeys: String, CodingKey {
        case hue, saturation, brightness, kelvin
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hue = try container.decode(UInt16.self, forKey: .hue)
        let saturation = try container.decode(UInt16.self, forKey: .saturation)
        let brightness = try container.decode(UInt16.self, forKey: .brightness)
        let rawKelvin = try container.decode(UInt16.self, forKey: .kelvin)
        self.init(
            hue: hue,
            saturation: saturation,
            brightness: brightness,
            kelvin: min(9_000, max(1_500, rawKelvin))
        )
    }

    var hsbk: LIFXHSBK {
        LIFXHSBK(hue: hue, saturation: saturation,
                 brightness: brightness, kelvin: kelvin)
    }

    var color: Color {
        Color(hue: Double(hue) / 65_535,
              saturation: Double(saturation) / 65_535,
              brightness: max(0.04, Double(brightness) / 65_535))
    }

    func painted(_ color: Color, fallbackBrightness: Double, kelvin: Int) -> LIFXMatrixColor {
        let retainedBrightness = brightness == 0
            ? fallbackBrightness
            : Double(brightness) / 65_535
        return LIFXMatrixColor(color: color,
                               brightness: retainedBrightness,
                               kelvin: kelvin)
    }

    /// Exact chroma editing preserves the independent HSBK channels, including
    /// zero brightness and the zone's existing white point.
    func settingChroma(_ color: Color) -> LIFXMatrixColor {
        let converted = LIFXMatrixColor(color: color, brightness: 1, kelvin: 3500)
        var copy = self
        copy.hue = converted.hue
        copy.saturation = converted.saturation
        return copy
    }

    func settingBrightness(_ value: Double) -> LIFXMatrixColor {
        var copy = self
        let safe = value.isFinite ? min(1, max(0, value)) : 0
        copy.brightness = UInt16(max(0, min(65_535, Int((safe * 65_535).rounded()))))
        return copy
    }
}

struct LIFXMatrixState: Codable, Equatable {
    var productID: UInt32
    var width: Int
    var height: Int
    /// Set64 always transports 64 values, even when the physical matrix uses
    /// fewer cells. Keeping all 64 avoids overwriting firmware-owned cells.
    var colors: [LIFXMatrixColor]
    var isActive: Bool

    init(productID: UInt32, width: Int, height: Int,
         colors: [LIFXMatrixColor], isActive: Bool = true) {
        self.productID = productID
        self.width = max(1, min(8, width))
        self.height = max(1, min(8, height))
        let off = LIFXMatrixColor(hue: 0, saturation: 0, brightness: 0, kelvin: 3_500)
        self.colors = Array((colors + Array(repeating: off, count: 64)).prefix(64))
        self.isActive = isActive
    }

    enum CodingKeys: String, CodingKey {
        case productID, width, height, colors, isActive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let productID = try container.decode(UInt32.self, forKey: .productID)
        let width = try container.decode(Int.self, forKey: .width)
        let height = try container.decode(Int.self, forKey: .height)
        let colors = try container.decode([LIFXMatrixColor].self, forKey: .colors)
        let isActive = (try? container.decode(Bool.self, forKey: .isActive)) ?? true
        self.init(productID: productID, width: width, height: height, colors: colors, isActive: isActive)
    }

    /// Luna reports a 5×6 matrix but has 26 physical zones; the four corner
    /// cells are outside its oval diffuser. Other matrix products expose every
    /// cell inside their reported dimensions.
    var activeZoneIndices: [Int] {
        let count = min(64, width * height)
        guard LIFXProductCatalog.isLuna(productID), width == 5, height == 6 else {
            return Array(0..<count)
        }
        let corners: Set<Int> = [0, width - 1, width * (height - 1), width * height - 1]
        return (0..<count).filter { !corners.contains($0) }
    }

    var zoneCount: Int { activeZoneIndices.count }

    func containsZone(_ index: Int) -> Bool {
        activeZoneIndices.contains(index)
    }

    func settingBrightness(_ value: Double) -> LIFXMatrixState {
        var copy = self
        for index in activeZoneIndices where copy.colors.indices.contains(index) {
            copy.colors[index] = copy.colors[index].settingBrightness(value)
        }
        copy.isActive = true
        return copy
    }

    static func demoLuna(brightness: Double = 0.72) -> LIFXMatrixState {
        let palette: [Color] = [
            Color(hue: 0.78, saturation: 0.82, brightness: 1),
            Color(hue: 0.92, saturation: 0.78, brightness: 1),
            Color(hue: 0.08, saturation: 0.9, brightness: 1),
            Color(hue: 0.52, saturation: 0.78, brightness: 1)
        ]
        var state = LIFXMatrixState(productID: 219, width: 5, height: 6, colors: [])
        for (offset, index) in state.activeZoneIndices.enumerated() {
            state.colors[index] = LIFXMatrixColor(
                color: palette[(offset / 4) % palette.count],
                brightness: brightness,
                kelvin: 3_500
            )
        }
        return state
    }
}
