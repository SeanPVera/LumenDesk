import Foundation
import SwiftUI

final class LightDevice: ObservableObject, Identifiable {
    enum Brand: String { case lifx, govee }

    let id: String
    let brand: Brand
    let backendID: String

    @Published var name: String
    /// User-set override displayed in place of the vendor label. Persisted by LightManager.
    @Published var customName: String?
    /// Vendor model code (e.g. Govee "H619A"), when discovery reports one.
    /// Drives capability detection such as the Segment Studio defaults.
    @Published var sku: String?
    /// LIFX product registry identifier returned by StateVersion (33).
    @Published var productID: UInt32?
    @Published var address: String
    @Published var isOn: Bool
    @Published var brightness: Double   // 0…1
    @Published var color: Color
    @Published var kelvin: Int          // 2500…9000 K; used in white-light mode
    // Reachability UI only needs a refresh when the stale flag changes. Publishing
    // every heartbeat forced every visible row to redraw even though nothing the
    // user could see had changed.
    var lastSeen: Date
    @Published var isStale: Bool = false

    /// The label shown in the UI: custom name when set, otherwise the vendor label.
    var label: String { customName ?? name }

    init(id: String, brand: Brand, backendID: String, name: String, address: String,
         sku: String? = nil, productID: UInt32? = nil,
         isOn: Bool = false, brightness: Double = 1.0, color: Color = .white, kelvin: Int = 3500) {
        self.id = id
        self.brand = brand
        self.backendID = backendID
        self.name = name
        self.sku = sku
        self.productID = productID
        self.address = address
        self.isOn = isOn
        self.brightness = brightness
        self.color = color
        self.kelvin = kelvin
        self.lastSeen = Date()
    }

    var isLIFXLuna: Bool {
        brand == .lifx
            && (LIFXProductCatalog.isLuna(productID)
                || sku?.uppercased() == LIFXProductCatalog.lunaSKU)
    }
}

extension LightDevice.Brand {
    var displayName: String {
        switch self {
        case .lifx: return "LIFX"
        case .govee: return "Govee"
        }
    }

    var tint: Color {
        switch self {
        case .lifx: return Lumen.violetBright
        case .govee: return Lumen.coral
        }
    }
}
