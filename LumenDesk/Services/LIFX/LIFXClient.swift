import Foundation

protocol LIFXClientDelegate: AnyObject {
    func lifxDiscovered(macHex: String, address: String)
    func lifxDidUpdate(macHex: String, label: String, color: LIFXHSBK, isOn: Bool)
    func lifxCommandFailed(_ error: Error)
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
        do {
            try socket.send(pkt, to: LIFXProtocol.broadcastAddress, port: LIFXProtocol.port)
        } catch {
            NSLog("LIFX discover send failed: \(error)")
        }
        #if os(iOS)
        // Broadcast requires the restricted multicast entitlement on iOS, so
        // also probe each subnet host directly; bulbs answer via unicast.
        queue.async { [socket] in
            for host in LocalSubnet.probeHosts() {
                try? socket.send(pkt, to: host, port: LIFXProtocol.port)
            }
        }
        #endif
    }

    func refresh(macHex: String) {
        queue.async { [weak self] in
            guard let self,
                  let host = self.addressesByMac[macHex],
                  let target = self.targetsByMac[macHex] else { return }
            let packet = LIFXProtocol.packet(type: .lightGet, source: self.source,
                                             target: target, payload: Data())
            self.sendCommand(packet, to: host)
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
            if addressesByMac[macHex] != host {
                addressesByMac[macHex] = host
                delegate?.lifxDiscovered(macHex: macHex, address: host)
            }
            // Immediately query state.
            let packet = LIFXProtocol.packet(type: .lightGet, source: source,
                                             target: header.target, payload: Data())
            sendCommand(packet, to: host)
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
