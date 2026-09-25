import Foundation

struct NanoleafEndpoint: Codable, Equatable {
    let host: String
    let port: Int

    init(host: String, port: Int = 16021) throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        // Accept an address/Bonjour hostname, never a URL with credentials,
        // path, query or fragment. The port is a separate, validated field.
        guard !host.isEmpty, (1...65535).contains(port),
              host.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#@\\ \t\n\r")) == nil,
              !host.contains(":") || host.filter({ $0 == ":" }).count > 1 else {
            throw NanoleafError.invalidAddress
        }
        self.host = host
        self.port = port
        _ = try url(path: "/api/v1/new")
    }

    func url(path: String) throws -> URL {
        var parts = URLComponents()
        parts.scheme = "http"
        parts.host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        parts.port = port
        parts.path = path
        guard let url = parts.url else { throw NanoleafError.invalidAddress }
        return url
    }
}

struct NanoleafCandidate: Identifiable, Equatable {
    let id: String
    let name: String
    let endpoint: NanoleafEndpoint
    let model: String?
}

/// Kept only in Keychain, never in an exported LumenDesk configuration.
struct NanoleafPairing: Codable, Equatable {
    let serial: String
    var serviceID: String?
    var name: String
    var endpoint: NanoleafEndpoint
    let token: String
}

struct NanoleafAppearance: Codable, Equatable {
    var colorMode: String
    var effect: String?
}

struct NanoleafInfo: Decodable {
    struct Value<T: Decodable>: Decodable { let value: T }
    struct State: Decodable {
        let on: Value<Bool>
        let brightness: Value<Int>
        let hue: Value<Int>
        let sat: Value<Int>
        let ct: Value<Int>
        let colorMode: String
    }
    struct Effects: Decodable {
        let select: String
        let effectsList: [String]
    }

    let name: String
    let serialNo: String
    let model: String
    let state: State
    let effects: Effects

    var isShapes: Bool { model.uppercased() == "NL42" }
    var appearance: NanoleafAppearance {
        NanoleafAppearance(colorMode: state.colorMode,
                           effect: state.colorMode == "effect" && effects.effectsList.contains(effects.select)
                                ? effects.select : nil)
    }
}

enum NanoleafError: LocalizedError, Equatable {
    case invalidAddress, pairingRequired, pairingWindowClosed, unsupportedModel
    case invalidResponse, unavailable, storageFailure, http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Enter a device IP address or local hostname and a port from 1 to 65535."
        case .pairingRequired: return "Nanoleaf access expired. Pair this controller again."
        case .pairingWindowClosed: return "Hold the Shapes power button for 5–7 seconds until its LED flashes, then press Pair within 30 seconds."
        case .unsupportedModel: return "This integration supports Nanoleaf Shapes (NL42)."
        case .invalidResponse: return "The Nanoleaf controller returned an unreadable response."
        case .unavailable: return "Cannot reach the Nanoleaf controller. Check its power and your local network connection."
        case .storageFailure: return "Could not save Nanoleaf pairing in Keychain. Please try again."
        case .http(let code): return "The Nanoleaf controller rejected the request (HTTP \(code))."
        }
    }
}

enum NanoleafProtocol {
    static let serviceType = "_nanoleafapi._tcp."
    static let kelvinRange = 1200...6500

    static func color(hue: Double, saturation: Double, brightness: Double? = nil) -> [String: Any] {
        let hue = hue.isFinite ? hue - floor(hue) : 0
        var result: [String: Any] = [
            "hue": ["value": min(359, Int((hue * 360).rounded()))],
            "sat": ["value": percent(saturation)]
        ]
        if let brightness { result["brightness"] = ["value": percent(brightness)] }
        return result
    }

    static func percent(_ value: Double) -> Int {
        Int(((value.isFinite ? min(1, max(0, value)) : 0) * 100).rounded())
    }

    static func kelvin(_ value: Int) -> Int {
        min(kelvinRange.upperBound, max(kelvinRange.lowerBound, value))
    }
}
