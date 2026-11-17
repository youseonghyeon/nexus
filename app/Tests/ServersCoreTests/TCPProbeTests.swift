import Foundation
@testable import ServersCore
import XCTest

/// 로컬 리스너로만 확인한다 (서버 접속 없음).
final class TCPProbeTests: XCTestCase {
    /// 127.0.0.1 의 빈 포트에 리스너를 열고 포트를 돌려준다
    private func listen() throws -> (fd: Int32, port: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0; addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(bound, 0); XCTAssertEqual(Darwin.listen(fd, 4), 0)
        var got = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return (fd, Int(UInt16(bigEndian: got.sin_port)))
    }

    func testOpenAndClosedPorts() async throws {
        let (fd, port) = try listen()
        let open = await TCPProbe.connect(host: "127.0.0.1", port: port, timeout: 2, device: nil)
        XCTAssertTrue(open)
        close(fd)
        let closed = await TCPProbe.connect(host: "127.0.0.1", port: port, timeout: 2, device: nil)
        XCTAssertFalse(closed)
    }

    func testBoundInterface() async throws {
        let (fd, port) = try listen()
        defer { close(fd) }
        let viaLoopback = await TCPProbe.connect(host: "127.0.0.1", port: port, timeout: 2, device: "lo0")
        XCTAssertTrue(viaLoopback, "루프백 장치에 묶어도 127.0.0.1 은 닿는다")
        let unknown = await TCPProbe.connect(host: "127.0.0.1", port: port, timeout: 2, device: "en999")
        XCTAssertFalse(unknown, "없는 장치면 실패 — 묶지 못한 채 다른 길로 새지 않는다")
    }

    /// 풀 수 없는 호스트는 실패 (빈 이름은 리졸버가 망에 묻지 않고 거절한다)
    func testBadHost() async {
        let bad = await TCPProbe.connect(host: "", port: 22, timeout: 1, device: nil)
        XCTAssertFalse(bad)
        XCTAssertNil(TCPProbe.resolveIPv4(""))
    }

    /// ip= 에 호스트 이름을 적은 서버: 이름을 IPv4 로 풀어 확인한다 (예전엔 inet_pton 만 받아 늘 닫힘이었다). localhost 는 /etc/hosts — 망에 나가지 않는다
    func testHostNameResolvesToIPv4() async throws {
        let (fd, port) = try listen()
        defer { close(fd) }
        let named = await TCPProbe.connect(host: "localhost", port: port, timeout: 2, device: nil)
        XCTAssertTrue(named, "이름으로도 열린 포트를 본다")
        XCTAssertEqual(TCPProbe.resolveIPv4("localhost")?.s_addr, inet_addr("127.0.0.1"))
        XCTAssertEqual(TCPProbe.resolveIPv4("192.0.2.7")?.s_addr, inet_addr("192.0.2.7"), "IPv4 주소는 그대로")
    }
}
