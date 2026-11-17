// 데모 모드: 가상의 목록이 읽히고, 러너가 정해진 응답만 돌려주는지 (프로세스를 띄우는 코드가 없다)

import XCTest
@testable import ServersCore

final class DemoModeTests: XCTestCase {
    func testRequestedOnlyWithFlag() {
        XCTAssertTrue(DemoMode.requested(arguments: ["Nexus", "--demo"]))
        XCTAssertFalse(DemoMode.requested(arguments: ["Nexus", "--select", "demo"]))
        XCTAssertFalse(DemoMode.active)   // 테스트 프로세스는 데모가 아니다 — 상태 폴더가 임시 폴더로 바뀌지 않는다
    }

    func testConfParsesWithEveryNetwork() throws {
        let config = try ServerConfigParser.parse(DemoMode.conf)
        XCTAssertEqual(config.servers.map(\.key), ["web", "was", "db", "jenkins", "router", "homelab", "desktop"])
        XCTAssertEqual(config.lan?.service, DemoMode.lanService)
        XCTAssertEqual(Set(config.servers.map(\.network)), [.lan, .direct, .tailscale])
    }

    /// 상태 확인 한 바퀴: 망은 모두 켜져 있고, 꺼진 것으로 정한 서버만 꺼짐
    func testStatusRound() async throws {
        let runner = DemoRunner()
        let config = try ServerConfigParser.parse(DemoMode.conf)
        let snapshot = await StatusMonitor(config: config, runner: runner, tcpProbe: runner.tcpProbe).refresh(previous: StatusSnapshot())
        XCTAssertEqual(snapshot.lan, .up)
        XCTAssertEqual(snapshot.lanDevice, "en7")
        XCTAssertEqual(snapshot.tailscale, .running)
        for server in config.servers {
            let state = try XCTUnwrap(snapshot.remote[server.key])
            if case .ok = state { XCTAssertNotEqual(server.key, "desktop") } else { XCTAssertEqual(server.key, "desktop", "\(server.key): \(state)") }
        }
    }

    func testSpecReplyParses() async throws {
        let runner = DemoRunner()
        let server = try XCTUnwrap(try ServerConfigParser.parse(DemoMode.conf).server("web"))
        let q = try XCTUnwrap(RemoteCommands.query(.spec, for: .linux))
        let result = await runner.run("ssh", ["-p", "22", server.target, q.command], stdin: q.stdin, timeout: 5)
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.stdout.contains("HOSTNAME     web"))
        // 꺼진 서버·모르는 명령은 실패, 모르는 실행 파일은 127
        let off = try XCTUnwrap(try ServerConfigParser.parse(DemoMode.conf).server("desktop"))
        let offResult = await runner.run("ssh", [off.target, "exit"], timeout: 5)
        XCTAssertFalse(offResult.ok)
        let unknown = await runner.run("ssh", [server.target, "rm -rf /"], timeout: 5)
        XCTAssertFalse(unknown.ok)
        let other = await runner.run("curl", ["https://example.com"], timeout: 5)
        XCTAssertEqual(other.exitCode, 127)
    }

    func testWiredSnapshotShowsEthernetAndIntranet() async {
        let snapshot = await WiredSnapshot.fetch(runner: DemoRunner())
        XCTAssertEqual(snapshot.adapters(excluding: [DemoMode.lanService]).map(\.service), ["Ethernet"])
        XCTAssertEqual(snapshot.gateways[DemoMode.lanService], true)
    }
}

extension DemoModeTests {
    /// 두 번 읽으면 그 사이만큼 늘어 속도가 나온다
    func testCountersGrowWithTime() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let a = try XCTUnwrap(NetworkProbe.parseCounters(DemoRunner.counters(device: "en7", now: start), at: start))
        let b = try XCTUnwrap(NetworkProbe.parseCounters(DemoRunner.counters(device: "en7", now: start + 2), at: start + 2))
        XCTAssertEqual(b.rxBytes - a.rxBytes, 3_600_000)
        XCTAssertEqual(b.txBytes - a.txBytes, 480_000)
    }
}
