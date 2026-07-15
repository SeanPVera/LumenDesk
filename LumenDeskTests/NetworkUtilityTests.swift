import XCTest
import Darwin
@testable import LumenDesk

final class NetworkUtilityTests: XCTestCase {
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
        let local = try XCTUnwrap(LocalSubnet.ipv4Address(from: "192.168.10.42"))
        let hosts = LocalSubnet.probeHosts(localAddresses: [local])

        XCTAssertEqual(hosts.count, 253)
        XCTAssertEqual(hosts.first, "192.168.10.1")
        XCTAssertEqual(hosts.last, "192.168.10.254")
        XCTAssertTrue(hosts.contains("192.168.10.41"))
        XCTAssertTrue(hosts.contains("192.168.10.43"))
    }

    func testDuplicateInterfaceSuppression() throws {
        let local = try XCTUnwrap(LocalSubnet.ipv4Address(from: "10.0.4.20"))
        let hosts = LocalSubnet.probeHosts(localAddresses: [local, local, local])

        XCTAssertEqual(hosts.count, 253)
        XCTAssertEqual(Set(hosts).count, hosts.count)
    }

    func testLocalNetworkAndBroadcastAddressesAreExcluded() throws {
        let firstLocal = try XCTUnwrap(LocalSubnet.ipv4Address(from: "172.16.8.20"))
        let secondLocal = try XCTUnwrap(LocalSubnet.ipv4Address(from: "172.16.8.21"))
        let hosts = LocalSubnet.probeHosts(localAddresses: [firstLocal, secondLocal])

        XCTAssertEqual(hosts.count, 252)
        XCTAssertFalse(hosts.contains("172.16.8.0"))
        XCTAssertFalse(hosts.contains("172.16.8.20"))
        XCTAssertFalse(hosts.contains("172.16.8.21"))
        XCTAssertFalse(hosts.contains("172.16.8.255"))
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
