import Foundation

/// Govee LAN API. The user must enable "LAN Control" in the Govee Home app on
/// each supported bulb. Reference:
/// https://app-h5.govee.com/user-manual/wlan-guide
enum GoveeProtocol {
    static let multicastGroup = "239.255.255.250"
    static let discoveryPort: UInt16 = 4001
    static let responsePort: UInt16 = 4002
    static let controlPort: UInt16 = 4003

    struct ScanResponse: Decodable {
        let msg: Inner
        struct Inner: Decodable {
            let cmd: String
            let data: ScanData
        }
        struct ScanData: Decodable {
            let ip: String
            let device: String
            let sku: String?
            let deviceName: String?
        }
    }

    struct StatusResponse: Decodable {
        let msg: Inner
        struct Inner: Decodable {
            let cmd: String
            let data: StatusData
        }
        struct StatusData: Decodable {
            let onOff: Int
            let brightness: Int
            let color: RGB?
            let colorTemInKelvin: Int?
            struct RGB: Decodable {
                let r: Int
                let g: Int
                let b: Int
            }
        }
    }

    static func scanRequest() -> Data {
        Data(#"{"msg":{"cmd":"scan","data":{"account_topic":"reserve"}}}"#.utf8)
    }

    static func statusRequest() -> Data {
        Data(#"{"msg":{"cmd":"devStatus","data":{}}}"#.utf8)
    }

    static func turnRequest(on: Bool) -> Data {
        Data(#"{"msg":{"cmd":"turn","data":{"value":\#(on ? 1 : 0)}}}"#.utf8)
    }

    static func brightnessRequest(_ value: Int) -> Data {
        let clamped = max(0, min(100, value))
        return Data(#"{"msg":{"cmd":"brightness","data":{"value":\#(clamped)}}}"#.utf8)
    }

    /// Set color or color temperature. If `kelvin` > 0, RGB is ignored by the bulb.
    static func colorRequest(r: Int, g: Int, b: Int, kelvin: Int = 0) -> Data {
        let rr = max(0, min(255, r)); let gg = max(0, min(255, g)); let bb = max(0, min(255, b))
        return Data(#"{"msg":{"cmd":"colorwc","data":{"color":{"r":\#(rr),"g":\#(gg),"b":\#(bb)},"colorTemInKelvin":\#(kelvin)}}}"#.utf8)
    }
}
