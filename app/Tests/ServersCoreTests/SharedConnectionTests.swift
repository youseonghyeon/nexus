// 공유 연결 끊기: 소켓 경로가 ssh 의 srv-%C 와 같은지 · 소켓 있는 계정만 · 끊기 인자. 실제 소켓·서버는 건드리지 않는다.

import Foundation
import XCTest
@testable import ServersCore

final class SharedConnectionTests: XCTestCase {
    private func server(_ ip: String, _ user: String, port: Int = 22, extra: [String] = []) -> Server {
        Server.sample(network: .direct, type: .linux, ip: ip, user: user, port: port, check: .ssh, extraUsers: extra)
    }

    /// 기댓값은 이 Mac(hostname mac)에서 `ssh -G -p 22 -o ControlPath=~/.ssh/srv-%C <대상>` 이 계산한 값 (2026-11-09, OpenSSH 10.5)
    /// (둘째는 주소를 문서용 대역으로 바꾸며 같은 식으로 다시 계산한 값 — ssh 와의 대조는 첫째가 맡는다)
    func testSocketPathMatchesSSHControlPathHash() {
        XCTAssertEqual(SharedConnection.socketPath(for: server("192.168.8.1", "root"), home: "/h", localHost: "mac"),
                       "/h/.ssh/srv-1bc84ec36ad59d65e4d81ae2e452e162c494d00a")
        XCTAssertEqual(SharedConnection.socketPath(for: server("203.0.113.17", "manager"), home: "/h", localHost: "mac"),
                       "/h/.ssh/srv-004fc28c79430096a2a4bc2a73e905e65382e6be")
    }

    func testSocketPathDependsOnAccountPortAndLocalHost() {
        let base = SharedConnection.socketPath(for: server("10.0.0.1", "a"), home: "/h", localHost: "mac")
        XCTAssertNotEqual(base, SharedConnection.socketPath(for: server("10.0.0.1", "b"), home: "/h", localHost: "mac"))
        XCTAssertNotEqual(base, SharedConnection.socketPath(for: server("10.0.0.1", "a", port: 2222), home: "/h", localHost: "mac"))
        XCTAssertNotEqual(base, SharedConnection.socketPath(for: server("10.0.0.1", "a"), home: "/h", localHost: "other"))
    }

    func testActiveAccountsOnlyThoseWithSocket() {
        let s = server("203.0.113.17", "manager", extra: ["k3s-master"])
        let k3s = SharedConnection.socketPath(for: s.account("k3s-master"), home: "/h", localHost: "mac")
        XCTAssertEqual(SharedConnection.activeAccounts(of: s, home: "/h", localHost: "mac", fileExists: { $0 == k3s }), ["k3s-master"])
        XCTAssertEqual(SharedConnection.activeAccounts(of: s, home: "/h", localHost: "mac", fileExists: { _ in true }), ["manager", "k3s-master"])
        XCTAssertEqual(SharedConnection.activeAccounts(of: s, home: "/h", localHost: "mac", fileExists: { _ in false }), [])
        // 추가 계정을 골라 둔 값으로 물어도 기본 계정이 먼저 (고른 계정 순서가 아니다)
        XCTAssertEqual(SharedConnection.activeAccounts(of: s.account("k3s-master"), home: "/h", localHost: "mac", fileExists: { _ in true }),
                       ["manager", "k3s-master"])
    }

    func testStopArgumentsUseSameControlPathAsConnections() {
        let args = SharedConnection.stopArguments(for: server("192.168.8.1", "root", port: 2222), home: "/h")
        XCTAssertEqual(args, ["-p", "2222", "-o", "ControlPath=/h/.ssh/srv-%C", "-O", "stop", "root@192.168.8.1"])
        XCTAssertTrue(ConnectPolicy.controlOptions(home: "/h").contains("ControlPath=/h/.ssh/srv-%C"))
    }

    func testLocalHostNameIsNotEmpty() {
        XCTAssertFalse(SharedConnection.localHostName().isEmpty)
    }
}
