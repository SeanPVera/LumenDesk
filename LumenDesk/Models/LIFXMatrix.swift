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
        self.init(
            hue: UInt16(max(0, min(65_535, Int((hsb.h * 65_535).rounded())))),
            saturation: UInt16(max(0, min(65_535, Int((hsb.s * 65_535).rounded())))),
            brightness: UInt16(max(0, min(65_535, Int((brightness * 65_535).rounded())))),
            kelvin: UInt16(max(1_500, min(9_000, kelvin)))
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

    func settingBrightness(_ value: Double) -> LIFXMatrixColor {
        var copy = self
        copy.brightness = UInt16(max(0, min(65_535, Int((value * 65_535).rounded()))))
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
