import Foundation
import Darwin

/// Minimal BSD-socket UDP wrapper that supports broadcast, multicast joins,
/// and asynchronous receive via a dispatch read source.
final class UDPSocket {
    enum SocketError: Error, CustomStringConvertible {
        case create(Int32)
        case bind(Int32)
        case send(Int32)
        case option(String, Int32)

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

    /// Called on `queue` for every datagram received.
    var onReceive: ((Data, String, UInt16) -> Void)?

    init(boundPort: UInt16 = 0, queue: DispatchQueue) throws {
        self.queue = queue
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { throw SocketError.create(errno) }
        self.fd = s

        try setOpt(SOL_SOCKET, SO_REUSEADDR, 1, name: "SO_REUSEADDR")
        try setOpt(SOL_SOCKET, SO_REUSEPORT, 1, name: "SO_REUSEPORT")
        try setOpt(SOL_SOCKET, SO_BROADCAST, 1, name: "SO_BROADCAST")

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
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buf.withUnsafeMutableBufferPointer { bptr -> Int in
                withUnsafeMutablePointer(to: &addr) { aptr in
                    aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                        recvfrom(fd, bptr.baseAddress, bptr.count, 0, sptr, &len)
                    }
                }
            }
            if n <= 0 { return }
            let data = Data(buf.prefix(n))
            let host = Self.ipString(addr.sin_addr)
            let port = UInt16(bigEndian: addr.sin_port)
            onReceive?(data, host, port)
        }
    }

    func send(_ data: Data, to host: String, port: UInt16) throws {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        if inet_pton(AF_INET, host, &addr.sin_addr) != 1 {
            throw SocketError.send(EINVAL)
        }
        let n = data.withUnsafeBytes { raw -> Int in
            withUnsafePointer(to: &addr) { aptr in
                aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                    sendto(fd, raw.baseAddress, raw.count, 0, sptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if n < 0 { throw SocketError.send(errno) }
    }

    func joinMulticast(_ group: String) throws {
        var mreq = ip_mreq()
        if inet_pton(AF_INET, group, &mreq.imr_multiaddr) != 1 {
            throw SocketError.option("IP_ADD_MEMBERSHIP/inet_pton", EINVAL)
        }
        mreq.imr_interface.s_addr = in_addr_t(0) // INADDR_ANY
        if setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size)) < 0 {
            throw SocketError.option("IP_ADD_MEMBERSHIP", errno)
        }
    }

    private static func ipString(_ addr: in_addr) -> String {
        var a = addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        _ = inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }
}
