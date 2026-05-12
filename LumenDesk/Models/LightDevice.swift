import Foundation
import SwiftUI

/// A single bulb shown in the UI. The model is backend-agnostic; the manager
/// fans control calls out to the correct vendor client based on `brand`.
final class LightDevice: ObservableObject, Identifiable {
    enum Brand: String { case lifx, govee }

    let id: String              // brand-prefixed unique id, e.g. "lifx:d073d5..." or "govee:AB:CD:..."
    let brand: Brand
    let backendID: String       // raw vendor ID (MAC hex for LIFX, device string for Govee)

    @Published var name: String
    @Published var address: String
    @Published var isOn: Bool
    @Published var brightness: Double  // 0…1
    @Published var color: Color
    @Published var lastSeen: Date

    init(id: String, brand: Brand, backendID: String, name: String, address: String,
         isOn: Bool = false, brightness: Double = 1.0, color: Color = .white) {
        self.id = id
        self.brand = brand
        self.backendID = backendID
        self.name = name
        self.address = address
        self.isOn = isOn
        self.brightness = brightness
        self.color = color
        self.lastSeen = Date()
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
        case .lifx: return .purple
        case .govee: return .orange
        }
    }
}
