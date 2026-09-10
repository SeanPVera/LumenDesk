import Foundation
import Darwin

/// What one discovery sweep actually managed to put on the wire.
///
/// Every send on the discovery path used to be `try?`-ed or logged and
/// forgotten, which made a scan that failed at the socket layer look exactly
/// like a scan that reached a healthy network with no lights on it. Clients
/// hand this back so the UI can tell those two apart.
struct DiscoveryProbeReport: Equatable {
    /// Interfaces the sweep addressed, e.g. `en0 192.168.1.42/24`.
    var interfaces: [String] = []
    var datagramsSent = 0
    /// Addresses the kernel could not resolve at the link layer, meaning
    /// nothing is listening there.
    ///
    /// This is counted apart from a real failure because on a home /24 it is
    /// most of the subnet: a sweep of 254 addresses on a network with nine
    /// devices *should* come back with 245 of these. Lumping them in with
    /// refusals made a perfectly healthy scan read as "most probes were
    /// refused, a VPN is intercepting your traffic", which is the opposite of
    /// what happened.
    var addressesUnoccupied = 0
    /// Sends the system actually refused: no permission, no route to the
    /// network, no buffers. These are faults.
    var datagramsFailed = 0
    /// `strerror` text for the most recent genuine failure.
    var lastError: String?

    var reachedNetwork: Bool { datagramsSent > 0 }

    mutating func absorb(_ tally: UDPSocket.SweepTally) {
        datagramsSent += tally.sent
        addressesUnoccupied += tally.unoccupied
        datagramsFailed += tally.failed
        if let error = tally.lastError { lastError = error }
    }

    var summary: String {
        guard !interfaces.isEmpty else { return "No IPv4 network interface" }
        var text = "\(datagramsSent) probe\(datagramsSent == 1 ? "" : "s") on \(interfaces.joined(separator: ", "))"
        if addressesUnoccupied > 0 { text += " · \(addressesUnoccupied) address\(addressesUnoccupied == 1 ? "" : "es") empty" }
        if datagramsFailed > 0 {
            text += " · \(datagramsFailed) refused"
            if let lastError { text += " (\(lastError))" }
        }
        return text
    }
}

/// Minimal BSD-socket UDP wrapper that supports broadcast, multicast joins,
/// and asynchronous receive via a dispatch read source.
final class UDPSocket {
    enum SocketError: Error, CustomStringConvertible {
        case create(Int32)
        case bind(Int32)
        case send(Int32)
        case option(String, Int32)

        /// The underlying errno, for callers that need to tell "nothing is at
        /// that address" apart from "the system refused this".
        var errnoCode: Int32 {
            switch self {
            case .create(let e), .bind(let e), .send(let e): return e
            case .option(_, let e): return e
            }
        }

        var description: String {
            switch self {
            case .create(let e): return "socket() failed: \(String(cString: strerror(e)))"
            case .bind(let e): return "bind() failed: \(String(cString: strerror(e)))"
            case .send(let e): return "sendto() failed: \(String(cString: strerror(e)))"
            case .option(let n, let e): return "setsockopt(\(n)) failed: \(String(cString: strerror(e)))"
            }
        }
    }

    let fd: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var receiveBuffer = [UInt8](repeating: 0, count: 4096)

    /// Called on `queue` for every datagram received.
    var onReceive: ((Data, String, UInt16) -> Void)?

    init(boundPort: UInt16 = 0, queue: DispatchQueue) throws {
        self.queue = queue
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { throw SocketError.create(errno) }
        self.fd = s

        // Do not enable SO_REUSEPORT here. Govee replies to a fixed UDP port
        // (4002), and multiple LumenDesk processes sharing that port cause the
        // kernel to distribute discovery replies between unrelated app
        // instances. An exclusive bind makes the second instance fail loudly
        // instead of making lights appear intermittently undiscoverable.
        try setOpt(SOL_SOCKET, SO_BROADCAST, 1, name: "SO_BROADCAST")

        // A subnet sweep answers in a burst: 250-odd bulbs can reply inside a
        // few milliseconds of each other. The 9 KB default receive buffer
        // holds only a handful of those datagrams, and the surplus is dropped
        // by the kernel before the dispatch source ever runs. Both directions
        // are advisory, so a kernel that refuses the bigger size is not fatal.
        try? setOpt(SOL_SOCKET, SO_RCVBUF, 256 * 1024, name: "SO_RCVBUF")
        try? setOpt(SOL_SOCKET, SO_SNDBUF, 256 * 1024, name: "SO_SNDBUF")

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = boundPort.bigEndian
        addr.sin_addr.s_addr = in_addr_t(0) // INADDR_ANY
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc < 0 { let e = errno; close(fd); throw SocketError.bind(e) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.drain() }
        src.resume()
        self.source = src
    }

    deinit {
        source?.cancel()
        close(fd)
    }

    private func setOpt(_ level: Int32, _ name: Int32, _ value: Int32, name nameStr: String) throws {
        var v = value
        if setsockopt(fd, level, name, &v, socklen_t(MemoryLayout<Int32>.size)) < 0 {
            throw SocketError.option(nameStr, errno)
        }
    }

    private func drain() {
        while true {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = receiveBuffer.withUnsafeMutableBufferPointer { bptr -> Int in
                withUnsafeMutablePointer(to: &addr) { aptr in
                    aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                        recvfrom(fd, bptr.baseAddress, bptr.count, 0, sptr, &len)
                    }
                }
            }
            // Only a negative result means the queue is empty. A zero-length
            // datagram is legal, and treating it as end-of-queue used to stop
            // the drain with real replies still sitting in the socket.
            if n < 0 { return }
            let data = Data(receiveBuffer.prefix(n))
            let host = Self.ipString(addr.sin_addr)
            let port = UInt16(bigEndian: addr.sin_port)
            onReceive?(data, host, port)
        }
    }

    func send(_ data: Data, to host: String, port: UInt16) throws {
        if let code = sendReturningErrno(data, to: host, port: port) {
            throw SocketError.send(code)
        }
    }

    /// `send` without the throw: returns `nil` on success, otherwise `errno`.
    /// The sweep needs to count failures by kind rather than abandon the pass
    /// at the first address the kernel has no route to.
    @discardableResult
    func sendReturningErrno(_ data: Data, to host: String, port: UInt16) -> Int32? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        if inet_pton(AF_INET, host, &addr.sin_addr) != 1 { return EINVAL }
        let n = data.withUnsafeBytes { raw -> Int in
            withUnsafePointer(to: &addr) { aptr in
                aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                    sendto(fd, raw.baseAddress, raw.count, 0, sptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return n < 0 ? errno : nil
    }

    func joinMulticast(_ group: String) throws {
        try joinMulticast(group, interfaceAddress: 0)
    }

    /// Joins `group` on one specific interface. `interfaceAddress` is a
    /// host-order IPv4 address, or 0 for `INADDR_ANY`.
    ///
    /// `INADDR_ANY` does not mean "every interface" — the kernel resolves it to
    /// the single default multicast interface, which on a Mac with a VPN, a
    /// Thunderbolt bridge, or a tethered iPhone is routinely not the one the
    /// lights are on. Joining per interface is what makes Govee replies arrive
    /// on a multi-homed machine.
    func joinMulticast(_ group: String, interfaceAddress: UInt32) throws {
        var mreq = ip_mreq()
        if inet_pton(AF_INET, group, &mreq.imr_multiaddr) != 1 {
            throw SocketError.option("IP_ADD_MEMBERSHIP/inet_pton", EINVAL)
        }
        mreq.imr_interface.s_addr = in_addr_t(interfaceAddress.bigEndian)
        if setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size)) < 0 {
            throw SocketError.option("IP_ADD_MEMBERSHIP", errno)
        }
    }

    /// Pins outbound multicast to one interface, for the same reason the join
    /// is pinned: an unset `IP_MULTICAST_IF` sends the scan out whatever the
    /// default route happens to be.
    func setMulticastInterface(_ interfaceAddress: UInt32) throws {
        var addr = in_addr(s_addr: in_addr_t(interfaceAddress.bigEndian))
        if setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &addr, socklen_t(MemoryLayout<in_addr>.size)) < 0 {
            throw SocketError.option("IP_MULTICAST_IF", errno)
        }
    }

    /// Sends `packet` to every host in `hosts`, in small bursts spaced apart on
    /// `queue`, and reports what left the machine.
    ///
    /// The burst matters. Firing 253 datagrams at never-before-seen neighbours
    /// in a tight loop overruns the interface output queue: the kernel holds
    /// exactly one packet per address while it ARPs, and `sendto` starts
    /// returning `ENOBUFS` for the rest. The old sweep swallowed those with
    /// `try?`, so most of it silently never went out. Pacing keeps the sweep
    /// inside that budget without blocking the caller's queue.
    func sweep(_ packet: Data,
               hosts: [String],
               port: UInt16,
               burst: Int = 24,
               gap: TimeInterval = 0.012,
               completion: @escaping (SweepTally) -> Void) {
        guard !hosts.isEmpty else {
            queue.async { completion(SweepTally()) }
            return
        }
        queue.async { [weak self] in
            guard let self else { return completion(SweepTally()) }
            self.sweepChunk(packet, hosts: hosts, port: port, from: 0,
                            burst: max(1, burst), gap: gap,
                            tally: SweepTally(), completion: completion)
        }
    }

    /// Running totals for one sweep pass.
    struct SweepTally: Equatable {
        var sent = 0
        var unoccupied = 0
        var failed = 0
        var lastError: String?
    }

    /// One burst of the sweep, then the next scheduled a `gap` later. Tallies
    /// are threaded through as parameters rather than captured, so the whole
    /// pass stays on `queue` with nothing shared across hops.
    private func sweepChunk(_ packet: Data,
                            hosts: [String],
                            port: UInt16,
                            from index: Int,
                            burst: Int,
                            gap: TimeInterval,
                            tally: SweepTally,
                            completion: @escaping (SweepTally) -> Void) {
        var tally = tally
        let end = min(index + burst, hosts.count)
        for cursor in index..<end {
            var code = sendReturningErrno(packet, to: hosts[cursor], port: port)
            // ENOBUFS means the output queue is momentarily full, not that the
            // address is unreachable. One short retry recovers the probe that
            // pacing alone did not.
            if code == ENOBUFS {
                _ = usleep(2000)
                code = sendReturningErrno(packet, to: hosts[cursor], port: port)
            }
            guard let code else { tally.sent += 1; continue }
            if Self.isUnoccupied(code) {
                tally.unoccupied += 1
            } else {
                tally.failed += 1
                tally.lastError = Self.errorText(code)
            }
        }
        guard end < hosts.count else {
            completion(tally)
            return
        }
        let carried = tally
        queue.asyncAfter(deadline: .now() + gap) { [weak self] in
            guard let self else { return completion(carried) }
            self.sweepChunk(packet, hosts: hosts, port: port, from: end,
                            burst: burst, gap: gap, tally: carried,
                            completion: completion)
        }
    }

    /// Runs one full discovery pass and reports what left the machine.
    ///
    /// Three delivery routes, because no single one survives every network:
    /// each interface's subnet-directed broadcast (connected route, so the
    /// kernel picks the right interface), the limited broadcast as a fallback,
    /// and a paced unicast probe of every host on those subnets for routers
    /// that filter broadcast outright.
    ///
    /// The sweep runs twice. macOS parks a single datagram per unresolved
    /// neighbour while it ARPs and drops it if resolution is slow, so a cold
    /// ARP cache eats most of a first pass; the second runs against warm
    /// entries and is the one that reliably lands.
    func probeSubnets(_ packet: Data,
                      port: UInt16,
                      interfaces: [LocalSubnet.Interface],
                      extraTargets: [String] = [],
                      warmupDelay: TimeInterval = 0.7,
                      completion: @escaping (DiscoveryProbeReport) -> Void) {
        let hosts = LocalSubnet.probeHosts(interfaces: interfaces)
        let broadcasts = extraTargets + LocalSubnet.directedBroadcasts(interfaces: interfaces)

        queue.async { [weak self] in
            guard let self else { return }
            var report = DiscoveryProbeReport(interfaces: interfaces.map(\.description))
            for address in broadcasts {
                if let code = self.sendReturningErrno(packet, to: address, port: port) {
                    report.datagramsFailed += 1
                    report.lastError = Self.errorText(code)
                } else {
                    report.datagramsSent += 1
                }
            }
            self.sweep(packet, hosts: hosts, port: port) { first in
                report.absorb(first)
                self.queue.asyncAfter(deadline: .now() + warmupDelay) {
                    self.sweep(packet, hosts: hosts, port: port) { second in
                        report.absorb(second)
                        completion(report)
                    }
                }
            }
        }
    }

    static func errorText(_ code: Int32) -> String { String(cString: strerror(code)) }

    /// Whether an errno means "nothing is at that address" rather than "the
    /// send was refused".
    ///
    /// On a directly-connected subnet these come from ARP giving up, which is
    /// the normal answer for an address with no device on it — exactly what a
    /// sweep exists to discover. `ENETUNREACH` is deliberately absent: no route
    /// to the *network* is a real fault, and it is the signature of a VPN
    /// holding the default route.
    static func isUnoccupied(_ code: Int32) -> Bool {
        code == EHOSTUNREACH || code == EHOSTDOWN
    }

    private static func ipString(_ addr: in_addr) -> String {
        var a = addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        _ = inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }
}

/// Enumerates the local IPv4 interfaces and the peers reachable on them.
///
/// Discovery cannot lean on a single limited broadcast to `255.255.255.255`.
/// That address is not routed: the kernel picks one interface from the default
/// route, so on a Mac running a VPN, sharing a Thunderbolt bridge, or tethered
/// to a phone the scan leaves by an interface with no lights on it. Every
/// active interface therefore gets its own subnet-directed broadcast and, when
/// that is refused or ignored, a unicast probe per host — replies to which are
/// ordinary unicast datagrams that need no entitlement or router cooperation.
enum LocalSubnet {
    /// One usable IPv4 interface.
    struct Interface: Equatable {
        var name: String
        /// Host-order IPv4 address.
        var address: UInt32
        /// Host-order netmask.
        var netmask: UInt32

        var prefixLength: Int { netmask.nonzeroBitCount }
        var network: UInt32 { address & netmask }
        /// Subnet-directed broadcast, e.g. `192.168.1.255` on a /24.
        var broadcast: UInt32 { network | ~netmask }
        var description: String { "\(name) \(LocalSubnet.ipv4String(from: address))/\(prefixLength)" }
    }

    /// Interfaces that never carry a smart bulb. `awdl0` and `llw0` are Apple's
    /// peer-to-peer radios, `anpi*`/`ap1` are internal, and the tunnel families
    /// are point-to-point links with no broadcast domain to scan.
    private static let excludedPrefixes = ["awdl", "llw", "anpi", "ap1", "utun", "ipsec", "ppp", "gif", "stf"]

    /// Hard ceiling on one sweep. A machine with several bridged interfaces
    /// could otherwise emit thousands of datagrams per scan.
    static let maximumProbeHosts = 1024

    static func ipv4Address(from string: String) -> UInt32? {
        let octets = string.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var address: UInt32 = 0
        for octet in octets {
            guard let value = UInt8(octet) else { return nil }
            address = (address << 8) | UInt32(value)
        }
        return address
    }

    static func ipv4String(from address: UInt32) -> String {
        "\((address >> 24) & 255).\((address >> 16) & 255).\((address >> 8) & 255).\(address & 255)"
    }

    /// Active, non-loopback IPv4 interfaces with a broadcast domain worth
    /// scanning.
    static func interfaces() -> [Interface] {
        var found: [Interface] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(ifaddrPtr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard (ifa.ifa_flags & UInt32(IFF_UP)) != 0,
                  (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  (ifa.ifa_flags & UInt32(IFF_POINTOPOINT)) == 0,
                  let sa = ifa.ifa_addr,
                  sa.pointee.sa_family == sa_family_t(AF_INET),
                  let address = ipv4(fromSockaddr: sa) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard !excludedPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            // A netmask sockaddr from getifaddrs often carries family 0 and a
            // short sa_len, so it is read positionally rather than by family.
            let netmask = ifa.ifa_netmask.flatMap { ipv4(fromSockaddr: $0) } ?? 0xFFFF_FF00
            guard isContiguous(netmask), netmask.nonzeroBitCount <= 30 else { continue }
            found.append(Interface(name: name, address: address, netmask: netmask))
        }
        return found.sorted { ($0.name, $0.address) < ($1.name, $1.address) }
    }

    /// Subnet-directed broadcast addresses, one per interface.
    ///
    /// These are what makes discovery work on a multi-homed Mac: a datagram to
    /// `192.168.1.255` has a connected route, so the kernel picks the matching
    /// interface instead of the default one.
    static func directedBroadcasts(interfaces: [Interface]) -> [String] {
        var seen = Set<UInt32>()
        return interfaces.compactMap { interface -> String? in
            let broadcast = interface.broadcast
            guard broadcast != interface.address, seen.insert(broadcast).inserted else { return nil }
            return ipv4String(from: broadcast)
        }
    }

    /// Dotted-quad strings for every other host reachable on each interface.
    /// Networks wider than a /24 are capped to the /24 around our own address
    /// so one sweep stays bounded. Duplicate subnets are folded together, and
    /// every local address is excluded even when two interfaces share a subnet.
    static func probeHosts(interfaces: [Interface]) -> [String] {
        let localSet = Set(interfaces.map(\.address))
        var seen = Set<UInt32>()
        var hosts: [String] = []
        for interface in interfaces.sorted(by: { $0.address < $1.address }) {
            // Cap at /24: a /16 home network is rare but a /16 sweep is 65k
            // datagrams, which is a denial of service against our own router.
            let mask = max(interface.netmask, 0xFFFF_FF00)
            let network = interface.address & mask
            let broadcast = network | ~mask
            guard broadcast > network + 1 else { continue }
            for candidate in (network + 1)...(broadcast - 1) {
                guard !localSet.contains(candidate), seen.insert(candidate).inserted else { continue }
                hosts.append(ipv4String(from: candidate))
                if hosts.count >= maximumProbeHosts { return hosts }
            }
        }
        return hosts
    }

    /// A netmask is only usable if its set bits are contiguous from the top.
    static func isContiguous(_ netmask: UInt32) -> Bool {
        netmask != 0 && (~netmask &+ 1) & ~netmask == 0
    }

    /// Reads the 4 address bytes out of a `sockaddr` positionally.
    ///
    /// `sockaddr_in` is len(1) family(1) port(2) addr(4), and netmask entries
    /// from `getifaddrs` can be shorter than a full `sockaddr_in`, so binding
    /// the whole struct would over-read.
    private static func ipv4(fromSockaddr sa: UnsafeMutablePointer<sockaddr>) -> UInt32? {
        guard Int(sa.pointee.sa_len) >= 8 else { return nil }
        let value = UnsafeRawPointer(sa).loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        return UInt32(bigEndian: value)
    }
}
