import Foundation

protocol GoveeClientDelegate: AnyObject {
    func goveeDiscovered(deviceID: String, address: String, sku: String?)
    func goveeDidUpdate(deviceID: String, isOn: Bool, brightness: Int, r: Int, g: Int, b: Int, kelvin: Int)
}

/// Drives Govee LAN discovery and control. The bulbs respond to scan and
/// status requests on UDP 4002 (so we bind there) and accept commands on 4003.
final class GoveeClient {
    weak var delegate: GoveeClientDelegate?

    private let socket: UDPSocket
    private let queue = DispatchQueue(label: "LumenDesk.govee")
    private var addressByDevice: [String: String] = [:]

    init() throws {
        socket = try UDPSocket(boundPort: GoveeProtocol.responsePort, queue: queue)
        try socket.joinMulticast(GoveeProtocol.multicastGroup)
        socket.onReceive = { [weak self] data, host, _ in
            self?.handle(data: data, from: host)
        }
    }

    func discover() {
        let pkt = GoveeProtocol.scanRequest()
        do {
            try socket.send(pkt, to: GoveeProtocol.multicastGroup, port: GoveeProtocol.discoveryPort)
        } catch {
            NSLog("Govee discover send failed: \(error)")
        }
    }

    func refresh(deviceID: String) {
        guard let host = addressByDevice[deviceID] else { return }
        try? socket.send(GoveeProtocol.statusRequest(), to: host, port: GoveeProtocol.controlPort)
    }

    func setPower(deviceID: String, on: Bool) {
        guard let host = addressByDevice[deviceID] else { return }
        try? socket.send(GoveeProtocol.turnRequest(on: on), to: host, port: GoveeProtocol.controlPort)
    }

    func setBrightness(deviceID: String, percent: Int) {
        guard let host = addressByDevice[deviceID] else { return }
        try? socket.send(GoveeProtocol.brightnessRequest(percent), to: host, port: GoveeProtocol.controlPort)
    }

    func setColor(deviceID: String, r: Int, g: Int, b: Int, kelvin: Int = 0) {
        guard let host = addressByDevice[deviceID] else { return }
        try? socket.send(GoveeProtocol.colorRequest(r: r, g: g, b: b, kelvin: kelvin),
                         to: host, port: GoveeProtocol.controlPort)
    }

    // MARK: - Receive

    private func handle(data: Data, from host: String) {
        // Govee occasionally emits truncated/duplicated frames; ignore failures.
        if let scan = try? JSONDecoder().decode(GoveeProtocol.ScanResponse.self, from: data),
           scan.msg.cmd == "scan" {
            let id = scan.msg.data.device
            if addressByDevice[id] != scan.msg.data.ip {
                addressByDevice[id] = scan.msg.data.ip
                delegate?.goveeDiscovered(deviceID: id, address: scan.msg.data.ip, sku: scan.msg.data.sku)
            }
            // Pull status right after discovery.
            try? socket.send(GoveeProtocol.statusRequest(),
                             to: scan.msg.data.ip, port: GoveeProtocol.controlPort)
            return
        }

        if let status = try? JSONDecoder().decode(GoveeProtocol.StatusResponse.self, from: data),
           status.msg.cmd == "devStatus" {
            // We don't have a device ID in the status payload, so we match by source IP.
            guard let id = addressByDevice.first(where: { $0.value == host })?.key else { return }
            let d = status.msg.data
            delegate?.goveeDidUpdate(deviceID: id,
                                     isOn: d.onOff == 1,
                                     brightness: d.brightness,
                                     r: d.color?.r ?? 255,
                                     g: d.color?.g ?? 255,
                                     b: d.color?.b ?? 255,
                                     kelvin: d.colorTemInKelvin ?? 0)
        }
    }
}
