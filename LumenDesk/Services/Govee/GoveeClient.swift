import Foundation

protocol GoveeClientDelegate: AnyObject {
    func goveeDiscovered(deviceID: String, address: String, sku: String?)
    func goveeDidUpdate(deviceID: String, isOn: Bool, brightness: Int, r: Int, g: Int, b: Int, kelvin: Int)
    func goveeCommandFailed(_ error: Error)
}

/// Drives Govee LAN discovery and control. The bulbs respond to scan and
/// status requests on UDP 4002 (so we bind there) and accept commands on 4003.
final class GoveeClient {
    weak var delegate: GoveeClientDelegate?

    private let socket: UDPSocket
    private let queue = DispatchQueue(label: "LumenDesk.govee")
    private var addressByDevice: [String: String] = [:]

    /// Minimum spacing between commands sent to one device. Govee firmware
    /// processes one LAN command at a time and drops datagrams that arrive
    /// back-to-back; multi-segment devices (curtain and string lights) are the
    /// slowest, so power/color/brightness bursts from themes and effects were
    /// only partially applied on them. Commands of the same kind coalesce to
    /// the newest payload so effect frames never back up the queue.
    private let commandGap: TimeInterval = 0.1
    private var queuedOrder: [String: [String]] = [:]          // deviceID -> kinds in send order
    private var queuedPayloads: [String: [String: Data]] = [:] // deviceID -> kind -> latest payload
    private var drainScheduled: Set<String> = []
    private var earliestSend: [String: DispatchTime] = [:]

    init() throws {
        socket = try UDPSocket(boundPort: GoveeProtocol.responsePort, queue: queue)
        do {
            try socket.joinMulticast(GoveeProtocol.multicastGroup)
        } catch {
            // iOS denies multicast membership without the restricted
            // entitlement; discovery still works via the unicast sweep below.
            NSLog("Govee multicast join failed: \(error)")
        }
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
        #if os(iOS)
        // Without the multicast entitlement the group send above fails, but
        // Govee bulbs also answer scan requests sent straight to their IP.
        queue.async { [socket] in
            for host in LocalSubnet.probeHosts() {
                try? socket.send(pkt, to: host, port: GoveeProtocol.discoveryPort)
            }
        }
        #endif
    }

    func refresh(deviceID: String) {
        enqueue(deviceID: deviceID, kind: "status", payload: GoveeProtocol.statusRequest())
    }

    func setPower(deviceID: String, on: Bool) {
        enqueue(deviceID: deviceID, kind: "turn", payload: GoveeProtocol.turnRequest(on: on))
    }

    func setBrightness(deviceID: String, percent: Int) {
        enqueue(deviceID: deviceID, kind: "brightness", payload: GoveeProtocol.brightnessRequest(percent))
    }

    func setColor(deviceID: String, r: Int, g: Int, b: Int, kelvin: Int = 0) {
        enqueue(deviceID: deviceID, kind: "colorwc", payload: GoveeProtocol.colorRequest(r: r, g: g, b: b, kelvin: kelvin))
    }

    // MARK: - Paced per-device send queue

    private func enqueue(deviceID: String, kind: String, payload: Data) {
        queue.async { [weak self] in
            guard let self, self.addressByDevice[deviceID] != nil else { return }
            if self.queuedPayloads[deviceID, default: [:]].updateValue(payload, forKey: kind) == nil {
                self.queuedOrder[deviceID, default: []].append(kind)
            }
            self.scheduleDrain(deviceID)
        }
    }

    private func scheduleDrain(_ deviceID: String) {
        guard !drainScheduled.contains(deviceID) else { return }
        drainScheduled.insert(deviceID)
        let now = DispatchTime.now()
        let deadline = max(earliestSend[deviceID] ?? now, now)
        queue.asyncAfter(deadline: deadline) { [weak self] in self?.drainQueued(deviceID) }
    }

    private func drainQueued(_ deviceID: String) {
        drainScheduled.remove(deviceID)
        guard let host = addressByDevice[deviceID],
              var order = queuedOrder[deviceID], !order.isEmpty else { return }
        let kind = order.removeFirst()
        queuedOrder[deviceID] = order
        guard let payload = queuedPayloads[deviceID]?.removeValue(forKey: kind) else {
            if !order.isEmpty { scheduleDrain(deviceID) }
            return
        }
        earliestSend[deviceID] = DispatchTime.now() + commandGap
        sendCommand(payload, to: host)
        if !order.isEmpty { scheduleDrain(deviceID) }
    }

    private func sendCommand(_ data: Data, to host: String) {
        do {
            try socket.send(data, to: host, port: GoveeProtocol.controlPort)
        } catch {
            delegate?.goveeCommandFailed(error)
        }
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
            refresh(deviceID: id)
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
