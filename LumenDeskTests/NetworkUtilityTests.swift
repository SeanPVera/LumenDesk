import XCTest
import Darwin
@testable import LumenDesk

final class NetworkUtilityTests: XCTestCase {
    private func interface(_ name: String, _ address: String, prefix: Int) throws -> LocalSubnet.Interface {
        let value = try XCTUnwrap(LocalSubnet.ipv4Address(from: address))
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
        return LocalSubnet.Interface(name: name, address: value, netmask: mask)
    }

    func testIPv4Conversion() {
        let address = LocalSubnet.ipv4Address(from: "192.168.40.7")
        XCTAssertEqual(address, 0xC0A8_2807)
        XCTAssertEqual(address.map(LocalSubnet.ipv4String), "192.168.40.7")
        XCTAssertEqual(LocalSubnet.ipv4Address(from: "0.0.0.0"), 0)
        XCTAssertEqual(LocalSubnet.ipv4Address(from: "255.255.255.255"), UInt32.max)
        XCTAssertNil(LocalSubnet.ipv4Address(from: "192.168.1"))
        XCTAssertNil(LocalSubnet.ipv4Address(from: "192.168.1.256"))
        XCTAssertNil(LocalSubnet.ipv4Address(from: "192.168.-1.2"))
    }

    func testSlash24HostEnumeration() throws {
        let hosts = LocalSubnet.probeHosts(interfaces: [try interface("en0", "192.168.10.42", prefix: 24)])

        XCTAssertEqual(hosts.count, 253)
        XCTAssertEqual(hosts.first, "192.168.10.1")
        XCTAssertEqual(hosts.last, "192.168.10.254")
        XCTAssertTrue(hosts.contains("192.168.10.41"))
        XCTAssertTrue(hosts.contains("192.168.10.43"))
    }

    func testDuplicateInterfaceSuppression() throws {
        let duplicate = try interface("en0", "10.0.4.20", prefix: 24)
        let hosts = LocalSubnet.probeHosts(interfaces: [duplicate, duplicate, duplicate])

        XCTAssertEqual(hosts.count, 253)
        XCTAssertEqual(Set(hosts).count, hosts.count)
    }

    func testLocalNetworkAndBroadcastAddressesAreExcluded() throws {
        let hosts = LocalSubnet.probeHosts(interfaces: [
            try interface("en0", "172.16.8.20", prefix: 24),
            try interface("en1", "172.16.8.21", prefix: 24)
        ])

        XCTAssertEqual(hosts.count, 252)
        XCTAssertFalse(hosts.contains("172.16.8.0"))
        XCTAssertFalse(hosts.contains("172.16.8.20"))
        XCTAssertFalse(hosts.contains("172.16.8.21"))
        XCTAssertFalse(hosts.contains("172.16.8.255"))
    }

    // MARK: - Interface-aware discovery targets

    func testInterfaceDerivesNetworkAndBroadcast() throws {
        let en0 = try interface("en0", "192.168.1.42", prefix: 24)
        XCTAssertEqual(en0.prefixLength, 24)
        XCTAssertEqual(LocalSubnet.ipv4String(from: en0.network), "192.168.1.0")
        XCTAssertEqual(LocalSubnet.ipv4String(from: en0.broadcast), "192.168.1.255")
        XCTAssertEqual(en0.description, "en0 192.168.1.42/24")

        let narrow = try interface("en1", "10.0.0.130", prefix: 25)
        XCTAssertEqual(LocalSubnet.ipv4String(from: narrow.network), "10.0.0.128")
        XCTAssertEqual(LocalSubnet.ipv4String(from: narrow.broadcast), "10.0.0.255")
    }

    func testDirectedBroadcastPerInterface() throws {
        let broadcasts = LocalSubnet.directedBroadcasts(interfaces: [
            try interface("en0", "192.168.1.42", prefix: 24),
            try interface("en1", "10.4.0.9", prefix: 16)
        ])
        XCTAssertEqual(broadcasts, ["192.168.1.255", "10.4.255.255"])
    }

    func testDirectedBroadcastFoldsInterfacesSharingASubnet() throws {
        let broadcasts = LocalSubnet.directedBroadcasts(interfaces: [
            try interface("en0", "192.168.1.42", prefix: 24),
            try interface("en1", "192.168.1.43", prefix: 24)
        ])
        XCTAssertEqual(broadcasts, ["192.168.1.255"])
    }

    func testSweepHonoursANetmaskNarrowerThanSlash24() throws {
        // A /25 must not spray the other half of the /24: those addresses are
        // off-link, so every probe to them leaves by the default route.
        let hosts = LocalSubnet.probeHosts(interfaces: [try interface("en0", "10.0.0.130", prefix: 25)])
        XCTAssertEqual(hosts.count, 125)
        XCTAssertEqual(hosts.first, "10.0.0.129")
        XCTAssertEqual(hosts.last, "10.0.0.254")
        XCTAssertFalse(hosts.contains("10.0.0.1"))
        XCTAssertFalse(hosts.contains("10.0.0.128"))
        XCTAssertFalse(hosts.contains("10.0.0.130"))
    }

    func testSweepCapsANetworkWiderThanSlash24() throws {
        // A /16 sweep would be 65,000 datagrams aimed at our own router.
        let hosts = LocalSubnet.probeHosts(interfaces: [try interface("en0", "172.16.9.20", prefix: 16)])
        XCTAssertEqual(hosts.count, 253)
        XCTAssertEqual(hosts.first, "172.16.9.1")
        XCTAssertEqual(hosts.last, "172.16.9.254")
    }

    func testSweepCoversEveryInterfaceAndStaysBounded() throws {
        let hosts = LocalSubnet.probeHosts(interfaces: [
            try interface("en0", "192.168.1.42", prefix: 24),
            try interface("en1", "10.0.7.5", prefix: 24)
        ])
        XCTAssertTrue(hosts.contains("192.168.1.1"))
        XCTAssertTrue(hosts.contains("10.0.7.200"))
        XCTAssertFalse(hosts.contains("192.168.1.42"))
        XCTAssertFalse(hosts.contains("10.0.7.5"))
        XCTAssertLessThanOrEqual(hosts.count, LocalSubnet.maximumProbeHosts)
        XCTAssertEqual(Set(hosts).count, hosts.count)
    }

    func testSweepStopsAtTheProbeCeiling() throws {
        let many = try (0..<8).map { try interface("en\($0)", "10.\($0).0.5", prefix: 24) }
        let hosts = LocalSubnet.probeHosts(interfaces: many)
        XCTAssertEqual(hosts.count, LocalSubnet.maximumProbeHosts)
    }

    func testNoncontiguousNetmasksAreRejected() {
        XCTAssertTrue(LocalSubnet.isContiguous(0xFFFF_FF00))
        XCTAssertTrue(LocalSubnet.isContiguous(0xFFFF_FF80))
        XCTAssertTrue(LocalSubnet.isContiguous(0x8000_0000))
        XCTAssertFalse(LocalSubnet.isContiguous(0))
        XCTAssertFalse(LocalSubnet.isContiguous(0xFFFF_FF0F))
        XCTAssertFalse(LocalSubnet.isContiguous(0x00FF_0000))
    }

    func testLiveInterfacesAreUsableWhenPresent() {
        // The host running the tests may have no IPv4 network at all, so this
        // asserts the shape of whatever is there rather than its presence.
        for interface in LocalSubnet.interfaces() {
            XCTAssertTrue(LocalSubnet.isContiguous(interface.netmask), "\(interface.description)")
            XCTAssertLessThanOrEqual(interface.prefixLength, 30)
            XCTAssertFalse(interface.name.hasPrefix("utun"))
            XCTAssertFalse(interface.name.hasPrefix("awdl"))
        }
    }

    // MARK: - Telling an empty address apart from a refused send

    func testUnoccupiedCodesAreNotFailures() {
        // EHOSTUNREACH on a directly-connected subnet is ARP giving up: nothing
        // is at that address. On a home /24 that is most of the subnet, and
        // counting it as a failure made a healthy scan read as though a
        // firewall were eating the traffic.
        XCTAssertTrue(UDPSocket.isUnoccupied(EHOSTUNREACH))
        XCTAssertTrue(UDPSocket.isUnoccupied(EHOSTDOWN))
        // No route to the *network* is a real fault, and the signature of a
        // VPN holding the default route.
        XCTAssertFalse(UDPSocket.isUnoccupied(ENETUNREACH))
        XCTAssertFalse(UDPSocket.isUnoccupied(EACCES))
        XCTAssertFalse(UDPSocket.isUnoccupied(ENOBUFS))
    }

    func testProbeReportSeparatesEmptyAddressesFromRefusals() {
        var report = DiscoveryProbeReport(interfaces: ["en0 192.168.1.57/24"])
        // The shape a real /24 produces: a handful of live hosts, the rest empty.
        report.absorb(UDPSocket.SweepTally(sent: 9, unoccupied: 499))

        XCTAssertTrue(report.reachedNetwork)
        XCTAssertEqual(report.datagramsFailed, 0)
        XCTAssertTrue(report.summary.contains("9 probes"))
        XCTAssertTrue(report.summary.contains("499 addresses empty"))
        XCTAssertFalse(report.summary.contains("refused"),
                       "a sparse subnet must not read as a refusal")

        // A pass with nothing to qualify carries no extra clause at all.
        var quiet = DiscoveryProbeReport(interfaces: ["en0 192.168.1.42/24"])
        quiet.absorb(UDPSocket.SweepTally(sent: 254))
        XCTAssertEqual(quiet.summary, "254 probes on en0 192.168.1.42/24")
    }

    func testProbeReportSurfacesGenuineRefusals() {
        var report = DiscoveryProbeReport(interfaces: ["en0 192.168.1.57/24"])
        report.absorb(UDPSocket.SweepTally(sent: 0, unoccupied: 0, failed: 254,
                                           lastError: "Permission denied"))

        XCTAssertFalse(report.reachedNetwork)
        XCTAssertTrue(report.summary.contains("254 refused"))
        XCTAssertTrue(report.summary.contains("Permission denied"))
        XCTAssertEqual(DiscoveryProbeReport().summary, "No IPv4 network interface")
    }

    func testSocketErrorExposesItsErrno() {
        XCTAssertEqual(UDPSocket.SocketError.send(EHOSTUNREACH).errnoCode, EHOSTUNREACH)
        XCTAssertEqual(UDPSocket.SocketError.bind(EADDRINUSE).errnoCode, EADDRINUSE)
        XCTAssertEqual(UDPSocket.SocketError.option("IP_MULTICAST_IF", EINVAL).errnoCode, EINVAL)
    }

    // MARK: - Govee command addressing

    func testGoveeCommandsUseTheAddressTheReplyCameFrom() {
        // Govee firmware bakes its `ip` field at join time and keeps announcing
        // the address it had before a DHCP renewal. Trusting the claim pointed
        // every command at a dead address and sendto answered EHOSTUNREACH,
        // while discovery still listed the light as present.
        XCTAssertEqual(GoveeClient.commandAddress(source: "192.168.1.57", reported: "192.0.2.99"),
                       "192.168.1.57")
        XCTAssertEqual(GoveeClient.commandAddress(source: "192.168.1.57", reported: "192.168.1.57"),
                       "192.168.1.57")
        XCTAssertEqual(GoveeClient.commandAddress(source: "192.168.1.57", reported: nil),
                       "192.168.1.57")
        XCTAssertEqual(GoveeClient.commandAddress(source: "192.168.1.57", reported: ""),
                       "192.168.1.57")
    }

    func testBoundUDPPortIsExclusive() throws {
        let first = try UDPSocket(boundPort: 0, queue: DispatchQueue(label: "LumenDeskTests.udp.first"))
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(first.fd, $0, &length)
            }
        }
        XCTAssertEqual(result, 0)
        let port = UInt16(bigEndian: address.sin_port)
        XCTAssertNotEqual(port, 0)

        XCTAssertThrowsError(
            try UDPSocket(boundPort: port, queue: DispatchQueue(label: "LumenDeskTests.udp.second"))
        )
    }
}
