import Foundation

protocol LIFXClientDelegate: AnyObject {
    func lifxDiscovered(macHex: String, address: String)
    func lifxDidIdentify(macHex: String, vendorID: UInt32, productID: UInt32)
    func lifxDidUpdate(macHex: String, label: String, color: LIFXHSBK, isOn: Bool)
    func lifxDidUpdateMatrix(macHex: String, productID: UInt32,
                             width: Int, height: Int, colors: [LIFXHSBK])
    func lifxCommandFailed(_ error: Error)
    /// What the last discovery pass actually put on the wire.
    func lifxDiscoveryProbe(_ report: DiscoveryProbeReport)
}

/// Drives LIFX LAN discovery and control. Discovery broadcasts a GetService
/// packet; responses come back as StateService. We then ask each bulb for its
/// current label and color via LightGet (101) and parse LightState (107).
final class LIFXClient {
    weak var delegate: LIFXClientDelegate?

    private let socket: UDPSocket
    private let queue = DispatchQueue(label: "LumenDesk.lifx")
    private let source: UInt32 = UInt32.random(in: 1...UInt32.max)
    private var addressesByMac: [String: String] = [:]
    private var targetsByMac: [String: Data] = [:]
    private var macByTarget: [Data: String] = [:]
    private var productByMac: [String: UInt32] = [:]
    private var matrixDimensionsByMac: [String: (width: Int, height: Int)] = [:]

    init() throws {
        socket = try UDPSocket(boundPort: 0, queue: queue)
        socket.onReceive = { [weak self] data, host, _ in
            self?.handle(data: data, from: host)
        }
    }

    func discover() {
        let pkt = LIFXProtocol.packet(type: .getService,
                                      source: source,
                                      target: Data(),
                                      payload: Data())
        // The unicast sweep is no longer iOS-only. iOS needs it because
        // broadcast is gated behind the restricted multicast entitlement, but
        // macOS needs it just as badly: routers with AP client isolation or
        // broadcast filtering drop the GetService, and a Mac holding a VPN
        // default route never puts it on the LAN at all. Bulbs answer a probe
        // addressed straight to them, and the reply is ordinary unicast.
        socket.probeSubnets(pkt,
                            port: LIFXProtocol.port,
                            interfaces: LocalSubnet.interfaces(),
                            extraTargets: [LIFXProtocol.broadcastAddress]) { [weak self] report in
            self?.delegate?.lifxDiscoveryProbe(report)
        }
    }

    func refresh(macHex: String) {
        queue.async { [weak self] in
            guard let self,
                  let host = self.addressesByMac[macHex],
                  let target = self.targetsByMac[macHex] else { return }
            let packet = LIFXProtocol.packet(type: .lightGet, source: self.source,
                                             target: target, payload: Data())
            self.sendCommand(packet, to: host)
            self.sendMatrixRefreshIfKnown(macHex: macHex, host: host, target: target)
        }
    }

    func refreshMatrix(macHex: String) {
        queue.async { [weak self] in
            guard let self,
                  let host = self.addressesByMac[macHex],
                  let target = self.targetsByMac[macHex] else { return }
            if self.matrixDimensionsByMac[macHex] != nil {
                self.sendMatrixRefreshIfKnown(macHex: macHex, host: host, target: target)
            } else {
                let version = LIFXProtocol.packet(type: .getVersion, source: self.source,
                                                  target: target, payload: Data())
                self.sendCommand(version, to: host)
            }
        }
    }

    func setPower(macHex: String, on: Bool) {
        queue.async { [weak self] in
            guard let self,
                  let host = self.addressesByMac[macHex],
                  let target = self.targetsByMac[macHex] else { return }
            let payload = LIFXProtocol.setPowerPayload(on: on)
            let packet = LIFXProtocol.packet(type: .setLightPower, source: self.source,
                                             target: target, payload: payload)
            self.sendCommand(packet, to: host)
        }
    }

    func setColor(macHex: String, color: LIFXHSBK, durationMS: UInt32 = 200) {
        queue.async { [weak self] in
            guard let self,
                  let host = self.addressesByMac[macHex],
                  let target = self.targetsByMac[macHex] else { return }
            let payload = LIFXProtocol.setColorPayload(color, durationMS: durationMS)
            let packet = LIFXProtocol.packet(type: .lightSetColor, source: self.source,
                                             target: target, payload: payload)
            self.sendCommand(packet, to: host)
        }
    }

    func setMatrixColors(macHex: String, colors: [LIFXHSBK], width: Int,
                         durationMS: UInt32 = 250) {
        queue.async { [weak self] in
            guard let self,
                  let host = self.addressesByMac[macHex],
                  let target = self.targetsByMac[macHex] else { return }
            let payload = LIFXProtocol.set64Payload(colors: colors, width: width,
                                                    durationMS: durationMS)
            let packet = LIFXProtocol.packet(type: .set64, source: self.source,
                                             target: target, payload: payload)
            self.sendCommand(packet, to: host)
        }
    }

    private func sendMatrixRefreshIfKnown(macHex: String, host: String, target: Data) {
        guard let dimensions = matrixDimensionsByMac[macHex] else { return }
        let payload = LIFXProtocol.get64Payload(width: dimensions.width)
        let packet = LIFXProtocol.packet(type: .get64, source: source,
                                         target: target, payload: payload)
        sendCommand(packet, to: host)
    }

    private func sendCommand(_ data: Data, to host: String) {
        do {
            try socket.send(data, to: host, port: LIFXProtocol.port)
        } catch {
            delegate?.lifxCommandFailed(error)
        }
    }

    // MARK: - Receive

    private func handle(data: Data, from host: String) {
        guard let header = LIFXProtocol.parse(data) else { return }
        // Filter to packets meant for our source id, but allow source==0 too
        // (some firmwares echo zero).
        if header.source != source && header.source != 0 { return }

        let macHex: String
        if let cached = macByTarget[header.target] {
            macHex = cached
        } else {
            macHex = header.target.hexString
            macByTarget[header.target] = macHex
        }
        targetsByMac[macHex] = header.target
        guard let type = LIFXMessage(rawValue: header.type) else { return }

        switch type {
        case .stateService:
            // Announce every response, not only an address that changed.
            // Suppressing repeats meant a rescan never counted a bulb that had
            // kept its address, never re-marked it as seen — so it aged into
            // "not seen recently" while it was answering every scan — and, if
            // the one announcement it did make was dropped downstream (Demo
            // Mode swallows live callbacks), left the bulb invisible until its
            // address changed or the app restarted. LightManager already folds
            // a repeat into the existing device. Govee was fixed for exactly
            // this; LIFX was missed.
            addressesByMac[macHex] = host
            delegate?.lifxDiscovered(macHex: macHex, address: host)
            // Immediately query state.
            let packet = LIFXProtocol.packet(type: .lightGet, source: source,
                                             target: header.target, payload: Data())
            sendCommand(packet, to: host)
            let version = LIFXProtocol.packet(type: .getVersion, source: source,
                                              target: header.target, payload: Data())
            sendCommand(version, to: host)
        case .stateVersion:
            guard let version = LIFXProtocol.parseVersion(header.payload) else { return }
            productByMac[macHex] = version.productID
            delegate?.lifxDidIdentify(macHex: macHex, vendorID: version.vendorID,
                                      productID: version.productID)
            if version.vendorID == 1 && Self.lunaProductIDs.contains(version.productID) {
                let chain = LIFXProtocol.packet(type: .getDeviceChain, source: source,
                                                target: header.target, payload: Data())
                sendCommand(chain, to: host)
            }
        case .stateDeviceChain:
            guard let matrix = LIFXProtocol.parseMatrixDevice(header.payload) else { return }
            productByMac[macHex] = matrix.productID
            matrixDimensionsByMac[macHex] = (matrix.width, matrix.height)
            delegate?.lifxDidIdentify(macHex: macHex, vendorID: matrix.vendorID,
                                      productID: matrix.productID)
            sendMatrixRefreshIfKnown(macHex: macHex, host: host, target: header.target)
        case .state64:
            guard let matrix = LIFXProtocol.parseState64(header.payload) else { return }
            let dimensions = matrixDimensionsByMac[macHex]
            let width = dimensions?.width ?? matrix.width
            let height = dimensions?.height ?? max(1, min(64 / max(1, width), 6))
            delegate?.lifxDidUpdateMatrix(macHex: macHex,
                                          productID: productByMac[macHex] ?? 0,
                                          width: width, height: height,
                                          colors: matrix.colors)
        case .lightState:
            if let parsed = LIFXProtocol.parseLightState(header.payload) {
                delegate?.lifxDidUpdate(macHex: macHex,
                                        label: parsed.label,
                                        color: parsed.color,
                                        isOn: parsed.power > 0)
            }
        default:
            break
        }
    }

    private static let lunaProductIDs: Set<UInt32> = [219, 220]
}

extension Data {
    init?(hex: String) {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let b = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }
            bytes.append(b)
        }
        self.init(bytes)
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
