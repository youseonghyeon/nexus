// StatusMonitor: 망·서버 상태 스냅샷 (FakeRunner).

import Foundation
import XCTest
@testable import ServersCore

final class StatusTests: XCTestCase {
    func testAllUp() async throws {
        let config = try ServerConfigParser.parse(fixture)
        let runner = FakeRunner()
        let monitor = StatusMonitor(config: config, runner: runner, tcpProbe: runner.tcpProbe)
        let snap = await monitor.refresh(previous: StatusSnapshot())
        XCTAssertEqual(snap.tailscale, .running)
        XCTAssertEqual(snap.lan, .up)
        XCTAssertTrue(snap.lanAdapterPresent)
        XCTAssertEqual(snap.lanDevice, "en9", "내부망 서비스의 장치 — lan 연결을 여기 묶는다")
        XCTAssertEqual(snap.peer("nexus"), .online)
        XCTAssertEqual(runner.calls.filter { $0.executable == "tailscale" }.count, 1, "상태·피어를 tailscale status --json 한 번으로")
        XCTAssertEqual(snap.peer("ghost"), .missing)
        XCTAssertTrue(snap.remote("nexus").isReachable)
        XCTAssertTrue(snap.remote("win").isReachable)
        XCTAssertTrue(snap.remote("was").isReachable)
        XCTAssertEqual(snap.remote("ghost"), .skip(reason: "peer missing"))
        let ssh = runner.calls.filter { $0.executable == "ssh" }
        XCTAssertEqual(ssh.count, 1)
        XCTAssertEqual(ssh[0].arguments, ["-o", "ConnectTimeout=3", "-o", "ConnectionAttempts=1", "-p", "2222",
                                          "-o", "ControlMaster=auto", "-o", "ControlPath=\(NSHomeDirectory())/.ssh/srv-%C",
                                          "-o", "ControlPersist=10m", "-o", "BatchMode=yes", "tester@100.64.0.1", "true"])
        // check=tcp 는 소켓 프로브: lan 서버(was)는 내부망 장치에 묶고, tailscale 서버(win)는 묶지 않는다
        XCTAssertEqual(Set(runner.probes), [FakeRunner.Probe(host: "100.64.0.2", port: 2222, device: nil),
                                             FakeRunner.Probe(host: "192.0.2.22", port: 2222, device: "en9")])
        XCTAssertFalse(runner.calls.contains { $0.executable == "nc" || $0.executable == "sudo" })
        XCTAssertFalse(runner.calls.contains { $0.executable == "ping" }, "정상이면 ping 을 보내지 않는다")
    }

    /// 먼저 끝난 서버는 느린 서버를 기다리지 않고 onProgress 로 넘어온다.
    /// win(tcp)은 nexus·was 결과가 progress 로 나온 뒤에야 응답한다 — 한꺼번에 넘기면 2초 뒤 포기해 꺼짐이 된다.
    func testProgressReportsFastServersBeforeSlowOne() async throws {
        let config = try ServerConfigParser.parse(fixture)
        let runner = FakeRunner()
        let seen = ProgressLog()
        let slowProbe: TCPProbeFunction = { host, port, timeout, device in
            if host == "100.64.0.2" {
                for _ in 0..<200 {
                    if seen.fastDone { return true }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return false
            }
            return await runner.tcpProbe(host, port, timeout, device)
        }
        let snap = await StatusMonitor(config: config, runner: runner, tcpProbe: slowProbe)
            .refresh(previous: StatusSnapshot()) { seen.record($0) }
        XCTAssertTrue(snap.remote("win").isReachable, "nexus·was 결과가 win 보다 먼저 progress 로 나와야 한다")
        let first = try XCTUnwrap(seen.snapshots.first)
        XCTAssertEqual(first.tailscale, .running, "첫 progress 에 로컬 상태")
        XCTAssertEqual(first.remote("ghost"), .skip(reason: "peer missing"), "확인 안 하는 서버도 첫 progress 에")
        XCTAssertEqual(first.remote("nexus"), .pending)
        XCTAssertEqual(seen.snapshots.count, 4, "로컬 1 + 확인한 서버 3")
        XCTAssertEqual(seen.snapshots.last, snap, "마지막 progress 가 결과와 같다")
    }

    /// 결과가 그대로인 라운드는 도중 게시가 로컬 상태 한 번뿐 — 예전엔 서버마다 한 번씩(확인 시각만 바뀐 스냅샷) 넘겼다.
    /// 달라진 서버만 넘기고, 그대로인 서버의 확인 시각은 돌려주는 스냅샷에서 한 번에 갱신된다.
    func testProgressOnlyForChangedServers() async throws {
        let config = try ServerConfigParser.parse(fixture)
        let runner = FakeRunner()
        let monitor = StatusMonitor(config: config, runner: runner, tcpProbe: runner.tcpProbe)
        let first = await monitor.refresh(previous: StatusSnapshot())

        let same = ProgressLog()
        let second = await monitor.refresh(previous: first) { same.record($0) }
        XCTAssertEqual(same.snapshots.count, 1, "로컬 1 — 서버 셋은 그대로라 넘기지 않는다")
        for key in ["nexus", "win", "was"] {
            XCTAssertTrue(second.remote(key).isReachable, key)
            let before = try XCTUnwrap(first.checkedAt[key]), after = try XCTUnwrap(second.checkedAt[key])
            XCTAssertGreaterThan(after, before, "그대로여도 확인 시각은 결과 스냅샷에 갱신된다: \(key)")
            XCTAssertEqual(same.snapshots.first?.checkedAt[key], before, "도중 스냅샷은 확인 시각을 건드리지 않는다: \(key)")
        }

        // tcp 서버 둘(win·was)만 달라진다 — nexus(ssh)는 그대로
        runner.tcpOK = false
        let changed = ProgressLog()
        let third = await monitor.refresh(previous: second) { changed.record($0) }
        XCTAssertEqual(changed.snapshots.count, 3, "로컬 1 + 달라진 서버 2")
        XCTAssertEqual(changed.snapshots.last?.remote, third.remote, "달라진 결과는 도중에 다 넘어왔다")
        XCTAssertTrue(third.remote("nexus").isReachable)
        XCTAssertTrue(third.remote("win").blocksSSH); XCTAssertTrue(third.remote("was").blocksSSH)

        XCTAssertTrue(RemoteState.ok(latencyMs: 3).sameOutcome(as: .ok(latencyMs: 90)), "응답 시간만 다르면 같은 결과")
        XCTAssertFalse(RemoteState.fail(latencyMs: 3).sameOutcome(as: .off(latencyMs: 3)))
        XCTAssertFalse(RemoteState.skip(reason: "lan down").sameOutcome(as: .skip(reason: "lan missing")))
        XCTAssertFalse(RemoteState.pending.sameOutcome(as: .ok(latencyMs: 1)))
    }

    func testNetworksDown() async throws {
        let config = try ServerConfigParser.parse(fixture)
        let runner = FakeRunner()
        runner.tailscaleBackend = "Stopped"; runner.lanEnabled = false
        let snap = await StatusMonitor(config: config, runner: runner, tcpProbe: runner.tcpProbe).refresh(previous: StatusSnapshot())
        XCTAssertEqual(snap.tailscale, .stopped("Stopped"))
        XCTAssertEqual(snap.lan, .down)
        XCTAssertEqual(snap.remote("nexus"), .skip(reason: "tailscale down"))
        XCTAssertEqual(snap.remote("was"), .skip(reason: "lan down"))
        XCTAssertFalse(runner.calls.contains { $0.executable == "ssh" })
        XCTAssertTrue(runner.probes.isEmpty)
    }

    /// 망 설정 없음 서버는 Tailscale·내부망이 꺼져 있어도 바로 확인하고, 장치에 묶지 않는다 (이 Mac 의 기본 경로로)
    func testDirectServersIgnoreNetworkState() async throws {
        let config = try ServerConfigParser.parse(fixture + """

            [ext]
            group=ext
            network=direct
            type=linux
            ip=10.1.0.20
            user=tester
            port=22
            check=ssh

            [extwin]
            group=ext
            type=windows
            ip=10.1.0.21
            user=tester
            port=3389
            """)
        let runner = FakeRunner()
        runner.tailscaleBackend = "Stopped"; runner.lanEnabled = false
        let snap = await StatusMonitor(config: config, runner: runner, tcpProbe: runner.tcpProbe).refresh(previous: StatusSnapshot())
        XCTAssertEqual(snap.remote("nexus"), .skip(reason: "tailscale down"))
        XCTAssertEqual(snap.remote("was"), .skip(reason: "lan down"))
        XCTAssertTrue(snap.remote("ext").isReachable, "\(snap.remote("ext"))")
        XCTAssertTrue(snap.remote("extwin").isReachable, "\(snap.remote("extwin"))")
        let ssh = runner.calls.filter { $0.executable == "ssh" }
        XCTAssertEqual(ssh.count, 1)
        let args = try XCTUnwrap(ssh.first?.arguments)
        XCTAssertTrue(args.contains("tester@10.1.0.20"))
        XCTAssertFalse(args.contains { $0.hasPrefix("BindInterface") }, "장치에 묶지 않는다: \(args)")
        XCTAssertEqual(runner.probes, [FakeRunner.Probe(host: "10.1.0.21", port: 3389, device: nil)])

        runner.sshExit = 255; runner.tcpOK = false
        let down = await StatusMonitor(config: config, runner: runner, tcpProbe: runner.tcpProbe).refresh(previous: snap)
        if case .fail = down.remote("ext") {} else { XCTFail("ping 은 되는데 ssh 가 안 되면 실패(빨강)로: \(down.remote("ext"))") }
        // VPN 을 끈 상태 등 ping 도 안 되면 꺼짐(회색) — 장치에 묶지 않는다
        runner.pingOK = false
        let gone = await StatusMonitor(config: config, runner: runner, tcpProbe: runner.tcpProbe).refresh(previous: down)
        if case .off = gone.remote("ext") {} else { XCTFail("\(gone.remote("ext"))") }
        XCTAssertTrue(runner.calls.contains { $0.executable == "ping" && $0.arguments == ["-c", "1", "-t", "2", "10.1.0.20"] })
    }

    func testFailuresAndPeerOffline() async throws {
        let config = try ServerConfigParser.parse(fixture)
        let runner = FakeRunner()
        runner.sshExit = 255; runner.tcpOK = false
        var snap = await StatusMonitor(config: config, runner: runner, tcpProbe: runner.tcpProbe).refresh(previous: StatusSnapshot())
        if case .fail = snap.remote("nexus") {} else { XCTFail("\(snap.remote("nexus"))") }
        if case .fail = snap.remote("was") {} else { XCTFail("\(snap.remote("was"))") }
        if case .off = snap.remote("win") {} else { XCTFail("Windows 는 ping 없이 바로 꺼짐: \(snap.remote("win"))") }
        XCTAssertTrue(snap.remote("nexus").blocksSSH)
        XCTAssertTrue(snap.remote("win").blocksSSH)
        XCTAssertNotNil(snap.lastFailAt["nexus"])
        XCTAssertNil(snap.lastFailAt["win"], "꺼짐은 실패가 아니다")
        let pings = runner.calls.filter { $0.executable == "ping" }.map(\.arguments)
        XCTAssertFalse(pings.contains { $0.last == "100.64.0.2" }, "Windows 에는 ping 을 보내지 않는다")
        XCTAssertTrue(pings.contains(["-c", "1", "-t", "2", "-b", "en9", "192.0.2.22"]), "내부망 서버의 ping 은 그 장치에 묶는다: \(pings)")

        runner.pingOK = false
        snap = await StatusMonitor(config: config, runner: runner, tcpProbe: runner.tcpProbe).refresh(previous: snap)
        if case .off = snap.remote("nexus") {} else { XCTFail("ssh·ping 모두 안 되면 꺼짐: \(snap.remote("nexus"))") }
        runner.pingOK = true

        runner.peers = [("100.64.0.1", false)]
        snap = await StatusMonitor(config: config, runner: runner, tcpProbe: runner.tcpProbe).refresh(previous: snap)
        XCTAssertEqual(snap.peer("nexus"), .offline)
        XCTAssertEqual(snap.remote("nexus"), .skip(reason: "peer offline"))
    }

    func testAdapterAbsent() async throws {
        let config = try ServerConfigParser.parse(fixture)
        let runner = FakeRunner()
        runner.adapterPresent = false
        let snap = await StatusMonitor(config: config, runner: runner, tcpProbe: runner.tcpProbe).refresh(previous: StatusSnapshot())
        XCTAssertEqual(snap.lan, .up)
        XCTAssertFalse(snap.lanAdapterPresent)
        XCTAssertEqual(snap.lanDevice, "en9", "장치 이름은 서비스 순서에서 오고, 있고 없고는 ifconfig 로 본다")
    }

    func testMissingTools() async throws {
        let config = try ServerConfigParser.parse(fixture)
        let runner = FakeRunner()
        runner.missing = ["tailscale", "nc"]
        let snap = await StatusMonitor(config: config, runner: runner, tcpProbe: runner.tcpProbe).refresh(previous: StatusSnapshot())
        XCTAssertEqual(snap.tailscale, .missing)
        XCTAssertEqual(snap.remote("nexus"), .skip(reason: "no tailscale"))
        XCTAssertTrue(snap.remote("was").isReachable, "tcp 확인은 nc 없이 소켓 프로브로 한다")
    }

    // 비JSON tailscale 출력 → unknown → "tailscale ?"
    func testTailscaleGarbage() async throws {
        final class Garbage: CommandRunner, @unchecked Sendable {
            func hasExecutable(_ name: String) -> Bool { true }
            func run(_ executable: String, _ arguments: [String], stdin: String?, environment: [String: String], timeout: TimeInterval) async -> CommandResult {
                executable == "tailscale" ? CommandResult(exitCode: 0, stdout: "not json") : CommandResult(exitCode: 0, stdout: "Test Ethernet\n")
            }
        }
        let config = try ServerConfigParser.parse(fixture)
        let snap = await StatusMonitor(config: config, runner: Garbage()).refresh(previous: StatusSnapshot())
        XCTAssertEqual(snap.tailscale, .unknown)
        XCTAssertEqual(snap.remote("nexus"), .skip(reason: "tailscale ?"))
    }

    /// Tailscale SSH check 만료: ssh 가 배너(로그인 URL)를 남기고 실패하면 fail 이 아니라 needsAuth. 그 상태는 60초 안엔 다시 확인하지 않는다.
    func testTailscaleCheckRequiredIsSeparateStateWithBackoff() async throws {
        let config = try ServerConfigParser.parse(fixture)
        let runner = FakeRunner()
        runner.sshExit = 255
        runner.sshStderr = "# Tailscale SSH requires an additional check.\n# To authenticate, visit: https://login.tailscale.com/a/abc123def\n"
        let monitor = StatusMonitor(config: config, runner: runner, tcpProbe: runner.tcpProbe)   // 가짜 프로브 — 빼면 win·was 로 실제 소켓이 나간다
        let first = await monitor.refresh(previous: StatusSnapshot())
        XCTAssertEqual(first.remote("nexus"), .needsAuth(url: "https://login.tailscale.com/a/abc123def"))
        XCTAssertFalse(first.remote("nexus").isReachable)
        XCTAssertTrue(first.remote("nexus").blocksSSH)
        XCTAssertNil(first.lastFailAt["nexus"], "인증 필요는 실패로 세지 않는다")
        let sshCalls = runner.calls.filter { $0.executable == "ssh" }.count
        let second = await monitor.refresh(previous: first)
        XCTAssertEqual(second.remote("nexus"), first.remote("nexus"))
        XCTAssertEqual(runner.calls.filter { $0.executable == "ssh" }.count, sshCalls, "60초 안에는 ssh 를 다시 부르지 않는다")
        // 마지막 확인이 recheckInterval 보다 오래됐으면 다시 확인한다
        var stale = second
        stale.checkedAt["nexus"] = Date().addingTimeInterval(-(TailscaleCheck.recheckInterval + 1))
        let third = await monitor.refresh(previous: stale)
        XCTAssertEqual(runner.calls.filter { $0.executable == "ssh" }.count, sshCalls + 1, "60초가 지나면 ssh 로 다시 본다")
        XCTAssertTrue(third.remote("nexus").needsAuth)
        XCTAssertGreaterThan(try XCTUnwrap(third.checkedAt["nexus"]), try XCTUnwrap(stale.checkedAt["nexus"]), "다시 확인한 시각으로 — 다음 60초를 센다")

        XCTAssertEqual(TailscaleCheck.url(in: "visit: https://login.tailscale.com/a/xyz and wait"), "https://login.tailscale.com/a/xyz")
        XCTAssertNil(TailscaleCheck.url(in: "Permission denied (publickey)."))
        XCTAssertTrue(TailscaleCheck.isCheckRequired("Tailscale SSH requires an additional check"))
    }

    /// 확인 안 하는 이유 표 (eligibility). 값은 skip(reason:) 에 들어가 툴팁에 그대로 보이므로 문자열도 함께 고정한다.
    func testEligibilityTable() throws {
        let monitor = StatusMonitor(config: try ServerConfigParser.parse(fixture), runner: FakeRunner())
        func server(_ network: ServerNetwork, vpn: String? = nil) -> Server {
            Server(key: "s", group: "g", network: network, type: .linux, ip: "192.0.2.9", user: "u", port: 22,
                   check: .ssh, role: nil, env: nil, wolMac: nil, vpn: vpn)
        }
        func snap(_ configure: (inout StatusSnapshot) -> Void) -> StatusSnapshot {
            var s = StatusSnapshot(); configure(&s); return s
        }
        let rows: [(String, Server, StatusSnapshot, String?)] = [
            // 빈 스냅숏 (앱을 켠 직후)
            ("tailscale 빈 상태", server(.tailscale), StatusSnapshot(), "tailscale ?"),
            ("lan 빈 상태", server(.lan), StatusSnapshot(), "lan missing"),
            ("vpn 빈 상태", server(.vpn), StatusSnapshot(), "vpn missing"),
            ("direct 빈 상태", server(.direct), StatusSnapshot(), nil),
            // tailscale
            ("tailscale 없음", server(.tailscale), snap { $0.tailscale = .missing }, "no tailscale"),
            ("tailscale 꺼짐", server(.tailscale), snap { $0.tailscale = .stopped("Stopped") }, "tailscale down"),
            ("피어 미확인", server(.tailscale), snap { $0.tailscale = .running }, "peer missing"),
            ("피어 없음", server(.tailscale), snap { $0.tailscale = .running; $0.peers["s"] = .missing }, "peer missing"),
            ("피어 offline", server(.tailscale), snap { $0.tailscale = .running; $0.peers["s"] = .offline }, "peer offline"),
            ("피어 online", server(.tailscale), snap { $0.tailscale = .running; $0.peers["s"] = .online }, nil),
            // 내부망
            ("lan 켜짐", server(.lan), snap { $0.lan = .up }, nil),
            ("lan 꺼짐", server(.lan), snap { $0.lan = .down }, "lan down"),
            ("lan 서비스 없음", server(.lan), snap { $0.lan = .missing }, "lan missing"),
            // vpn
            ("vpn 연결", server(.vpn, vpn: "Home"), snap { $0.vpnLinks = [VPNLink(name: "Home", device: "utun7")] }, nil),
            ("vpn 꺼짐", server(.vpn, vpn: "Home"), snap { $0.vpnLinks = [VPNLink(name: "Home", device: nil)] }, "vpn down"),
            ("vpn 이름 없음", server(.vpn, vpn: "Gone"), snap { $0.vpnLinks = [VPNLink(name: "Home", device: "utun7")] }, "vpn missing"),
        ]
        for (name, server, snapshot, reason) in rows {
            XCTAssertEqual(monitor.eligibility(server, in: snapshot)?.rawValue, reason, name)
        }
        XCTAssertEqual(Set(StatusMonitor.SkipReason.allCases.map(\.rawValue)),
                       ["no tailscale", "tailscale ?", "tailscale down", "peer offline", "peer missing",
                        "lan down", "lan missing", "vpn missing", "vpn down"])
    }
}

/// progress 기록. fastDone: nexus·was 가 확인된 스냅샷이 넘어왔는가
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [StatusSnapshot] = []
    var snapshots: [StatusSnapshot] { lock.withLock { items } }
    var fastDone: Bool {
        lock.withLock { items.contains { $0.remote("nexus").isReachable && $0.remote("was").isReachable } }
    }
    func record(_ snapshot: StatusSnapshot) { lock.withLock { items.append(snapshot) } }
}
