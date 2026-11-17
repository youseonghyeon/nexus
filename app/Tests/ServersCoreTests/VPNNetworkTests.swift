// network=vpn: vpn= 파싱 · VPN 의 utun 에 묶어 확인 · 꺼짐/없음 판정 · 편집기의 vpn= 줄.
// scutil 출력은 이 Mac 의 실제 출력 픽스처 (scutil-nc-list: WireGuard "MacBook" 연결됨 · scutil-nc-status-connected: utun7).

import Foundation
import XCTest
@testable import ServersCore

final class VPNNetworkTests: XCTestCase {
    private let wireguardID = "11111111-1111-4111-8111-111111111111"

    private let vpnServers = """

        [home1]
        group=ext
        network=vpn
        vpn=MacBook
        type=windows
        ip=192.168.8.102
        user=tester
        port=22

        [home2]
        group=ext
        network=vpn
        type=linux
        ip=192.168.8.10
        user=tester
        port=22

        [home3]
        group=ext
        network=vpn
        vpn=Office
        type=linux
        ip=192.168.9.10
        user=tester
        port=22
        """

    func testParse() throws {
        let config = try ServerConfigParser.parse(fixture + vpnServers)
        let home1 = try XCTUnwrap(config.server("home1"))
        XCTAssertEqual(home1.network, .vpn)
        XCTAssertEqual(home1.vpn, "MacBook")
        XCTAssertEqual(home1.check, .tcp, "vpn 도 tailscale 이 아니라 기본 tcp")
        XCTAssertNil(config.server("home2")?.vpn, "이름 없음 = 연결된 첫 VPN")
        XCTAssertNil(try ServerConfigParser.parse(fixture + vpnServers.replacingOccurrences(of: "vpn=MacBook", with: "vpn=")).server("home1")?.vpn)

        XCTAssertThrowsError(try ServerConfigParser.parse(fixture + vpnServers.replacingOccurrences(of: "network=vpn\nvpn=MacBook", with: "network=direct\nvpn=MacBook"))) { error in
            XCTAssertTrue((error as? ConfigError)?.problem.contains("vpn=") == true, "\(error)")
        }
        XCTAssertThrowsError(try ServerConfigParser.parse(fixture + vpnServers.replacingOccurrences(of: "network=vpn\nvpn=MacBook", with: "network=wireguard")))
    }

    func testChecksThroughConnectedVPNInterface() async throws {
        let config = try ServerConfigParser.parse(fixture + vpnServers)
        let runner = FakeRunner()
        runner.scripted["scutil --nc list"] = CommandResult(exitCode: 0, stdout: try fixtureText("scutil-nc-list"))
        runner.scripted["scutil --nc status \(wireguardID)"] = CommandResult(exitCode: 0, stdout: try fixtureText("scutil-nc-status-connected"))
        let snap = await StatusMonitor(config: config, runner: runner, tcpProbe: runner.tcpProbe).refresh(previous: StatusSnapshot())

        XCTAssertEqual(snap.vpnLinks.first { $0.name == "MacBook" }?.device, "utun7")
        XCTAssertFalse(snap.vpnLinks.contains { $0.name == "Tailscale" }, "Tailscale 은 자기 망이 따로 있다")
        XCTAssertTrue(snap.remote("home1").isReachable, "\(snap.remote("home1"))")
        XCTAssertTrue(snap.remote("home2").isReachable, "이름 없으면 연결된 첫 VPN: \(snap.remote("home2"))")
        XCTAssertEqual(snap.remote("home3"), .skip(reason: "vpn missing"), "목록에 없는 이름")
        XCTAssertEqual(Set(runner.probes.filter { $0.host.hasPrefix("192.168.") }),
                       [FakeRunner.Probe(host: "192.168.8.102", port: 22, device: "utun7"), FakeRunner.Probe(host: "192.168.8.10", port: 22, device: "utun7")],
                       "연결을 그 VPN 의 utun 에 묶는다")
        XCTAssertFalse(runner.calls.contains { $0.arguments == ["--nc", "status", "33333333-3333-4333-8333-333333333333"] },
                       "연결된 VPN 만 인터페이스를 묻는다 (Invalid 는 묻지 않음)")
        XCTAssertEqual(snap.bindInterface(for: try XCTUnwrap(config.server("home1"))), "utun7")
        XCTAssertNil(snap.bindInterface(for: try XCTUnwrap(config.server("nexus"))), "tailscale 은 묶지 않는다")
    }

    func testDisconnectedVPNSkipsAndListFailureKeepsLast() async throws {
        let config = try ServerConfigParser.parse(fixture + vpnServers)
        let runner = FakeRunner()
        let list = try fixtureText("scutil-nc-list")
        runner.scripted["scutil --nc list"] = CommandResult(exitCode: 0, stdout: list.replacingOccurrences(of: "(Connected)      \(wireguardID)", with: "(Disconnected)   \(wireguardID)"))
        let off = await StatusMonitor(config: config, runner: runner, tcpProbe: runner.tcpProbe).refresh(previous: StatusSnapshot())
        XCTAssertEqual(off.vpnLinks.first { $0.name == "MacBook" }, VPNLink(name: "MacBook", device: nil))
        XCTAssertEqual(off.remote("home1"), .skip(reason: "vpn down"))
        XCTAssertEqual(off.remote("home2"), .skip(reason: "vpn down"), "연결된 VPN 이 없으면 첫 VPN 으로 — 꺼짐")
        XCTAssertFalse(runner.probes.contains { $0.host.hasPrefix("192.168.") }, "VPN 이 꺼지면 확인하지 않는다 (같은 대역의 다른 장비로 새지 않게)")
        XCTAssertNil(off.bindInterface(for: try XCTUnwrap(config.server("home1"))))

        // 목록 읽기가 한 번 실패해도 이전 값 유지
        runner.scripted["scutil --nc list"] = CommandResult(exitCode: 1)
        var previous = off
        previous.vpnLinks = [VPNLink(name: "MacBook", device: "utun5")]
        let kept = await StatusMonitor(config: config, runner: runner, tcpProbe: runner.tcpProbe).refresh(previous: previous)
        XCTAssertEqual(kept.vpnLinks, [VPNLink(name: "MacBook", device: "utun5")])
        XCTAssertTrue(kept.remote("home1").isReachable)
    }

    /// 서버 추가 창: 목록에 vpn 서버가 없어도(상태 확인이 VPN 을 안 읽어도) 고른 VPN 의 utun 을 바로 읽는다
    func testVPNDeviceReadsOnDemand() async throws {
        let runner = FakeRunner()
        let list = try fixtureText("scutil-nc-list")
        runner.scripted["scutil --nc list"] = CommandResult(exitCode: 0, stdout: list)
        runner.scripted["scutil --nc status \(wireguardID)"] = CommandResult(exitCode: 0, stdout: try fixtureText("scutil-nc-status-connected"))
        let named = await StatusMonitor.vpnDevice(name: "MacBook", runner: runner)
        let first = await StatusMonitor.vpnDevice(name: nil, runner: runner)
        let unknown = await StatusMonitor.vpnDevice(name: "Office", runner: runner)
        XCTAssertEqual(named, "utun7")
        XCTAssertEqual(first, "utun7", "이름 없으면 연결된 첫 VPN")
        XCTAssertNil(unknown, "목록에 없는 이름")

        runner.scripted["scutil --nc list"] = CommandResult(exitCode: 0, stdout: list.replacingOccurrences(of: "(Connected)      \(wireguardID)", with: "(Disconnected)   \(wireguardID)"))
        let off = await StatusMonitor.vpnDevice(name: "MacBook", runner: runner)
        XCTAssertNil(off, "꺼져 있으면 묶을 장치가 없다")
        runner.scripted["scutil --nc list"] = CommandResult(exitCode: 1)
        let failed = await StatusMonitor.vpnDevice(name: nil, runner: runner)
        XCTAssertNil(failed, "목록을 못 읽으면 없음")
    }

    func testNoVPNServersSkipsScutil() async throws {
        let runner = FakeRunner()
        _ = await StatusMonitor(config: try ServerConfigParser.parse(fixture), runner: runner, tcpProbe: runner.tcpProbe).refresh(previous: StatusSnapshot())
        XCTAssertFalse(runner.calls.contains { $0.executable == "scutil" }, "vpn 서버가 없으면 VPN 을 읽지 않는다")
    }

    func testBindInterfaceByNetwork() {
        var snap = StatusSnapshot()
        snap.lanDevice = "en9"
        snap.vpnLinks = [VPNLink(name: "Off", device: nil), VPNLink(name: "MacBook", device: "utun5")]
        XCTAssertEqual(snap.bindInterface(network: .lan, vpn: nil), "en9")
        XCTAssertEqual(snap.bindInterface(network: .vpn, vpn: "MacBook"), "utun5")
        XCTAssertEqual(snap.bindInterface(network: .vpn, vpn: nil), "utun5", "이름 없으면 연결된 첫 VPN")
        XCTAssertNil(snap.bindInterface(network: .vpn, vpn: "Off"))
        XCTAssertNil(snap.bindInterface(network: .direct, vpn: nil))
        XCTAssertNil(snap.bindInterface(network: .tailscale, vpn: nil))
    }

    /// 확인 전(pending)이라 버튼이 켜져 있어도 묶을 utun 이 없으면 연결하지 않는다 (시스템 경로로 새는 길)
    func testLacksVPNBindBeforeFirstCheck() throws {
        let config = try ServerConfigParser.parse(fixture + vpnServers)
        let home1 = try XCTUnwrap(config.server("home1")), nexus = try XCTUnwrap(config.server("nexus")), was = try XCTUnwrap(config.server("was"))
        var snap = StatusSnapshot()
        XCTAssertEqual(snap.remote("home1"), .pending)
        XCTAssertTrue(snap.lacksVPNBind(home1), "앱을 켠 직후 — VPN 목록을 아직 못 읽음")
        XCTAssertFalse(snap.lacksVPNBind(nexus)); XCTAssertFalse(snap.lacksVPNBind(was), "vpn 서버만")
        snap.vpnLinks = [VPNLink(name: "MacBook", device: nil)]
        XCTAssertTrue(snap.lacksVPNBind(home1), "꺼짐")
        snap.vpnLinks = [VPNLink(name: "MacBook", device: "utun5")]
        XCTAssertFalse(snap.lacksVPNBind(home1))
    }

    func testStatusReadFailureKeepsLastInterface() async throws {
        let config = try ServerConfigParser.parse(fixture + vpnServers)
        let runner = FakeRunner()
        runner.scripted["scutil --nc list"] = CommandResult(exitCode: 0, stdout: try fixtureText("scutil-nc-list"))
        runner.scripted["scutil --nc status \(wireguardID)"] = CommandResult(exitCode: 1)
        var previous = StatusSnapshot()
        previous.vpnLinks = [VPNLink(name: "MacBook", device: "utun7")]
        let snap = await StatusMonitor(config: config, runner: runner, tcpProbe: runner.tcpProbe).refresh(previous: previous)
        XCTAssertEqual(snap.vpnLinks.first { $0.name == "MacBook" }?.device, "utun7", "연결됨인데 status 만 실패 — 이전 utun")
        let fresh = await StatusMonitor(config: config, runner: runner, tcpProbe: runner.tcpProbe).refresh(previous: StatusSnapshot())
        XCTAssertEqual(fresh.remote("home1"), .skip(reason: "vpn down"), "이전 값이 없으면 꺼짐으로")
    }

    /// 꺼짐 알림의 근거: 같은 VPN 너머 서버가 응답해야 그 서버가 꺼진 것 (다른 VPN 은 근거가 아니다)
    func testPowerWitnessNeedsSameVPN() throws {
        let config = try ServerConfigParser.parse(fixture + vpnServers + """

            [home4]
            group=ext
            network=vpn
            vpn=MacBook
            type=linux
            ip=192.168.8.11
            user=tester
            port=22
            """)
        func state(_ remote: [String: RemoteState]) -> PowerState? {
            var snap = StatusSnapshot()
            snap.remote = remote
            return PowerWatch.state(of: config.server("home1")!, in: snap, among: config.servers)
        }
        let fail = RemoteState.fail(latencyMs: 3000), ok = RemoteState.ok(latencyMs: 5)
        XCTAssertNil(state(["home1": fail, "home3": ok]), "다른 VPN(Office) 서버의 응답은 근거가 아니다")
        XCTAssertEqual(state(["home1": fail, "home4": ok]), .down, "같은 VPN 의 다른 서버는 응답")
    }

    func testEditorWritesVPNLine() throws {
        let added = try ServerConfigEditor.appending(NewServer(key: "pc", group: "ext", network: .vpn, type: .windows, ip: "192.168.8.102", user: "me", vpn: " MacBook "), to: fixture)
        XCTAssertTrue(added.contains("[pc]\ngroup=ext\nnetwork=vpn\nvpn=MacBook\ntype=windows"), added)
        XCTAssertEqual(try ServerConfigParser.parse(added).server("pc")?.vpn, "MacBook")
        let auto = try ServerConfigEditor.appending(NewServer(key: "pc", group: "ext", network: .vpn, type: .linux, ip: "192.168.8.10", user: "me"), to: fixture)
        XCTAssertFalse(auto.contains("vpn="), "이름을 안 고르면 줄 없음 (연결된 첫 VPN)")
        let notVPN = try ServerConfigEditor.appending(NewServer(key: "pc", group: "ext", network: .direct, type: .linux, ip: "10.0.0.1", user: "me", vpn: "MacBook"), to: fixture)
        XCTAssertFalse(notVPN.contains("vpn="), "다른 망이면 쓰지 않는다")
        XCTAssertNotNil(ServerConfigEditor.problem(NewServer(key: "pc", group: "ext", network: .vpn, type: .linux, ip: "1.2.3.4", user: "me", vpn: "a#b")))

        // 편집: vpn → direct 로 바꾸면 vpn= 줄을 지우고, 이름만 바꾸면 그 줄만
        let config = try ServerConfigParser.parse(added)
        let pc = try XCTUnwrap(config.server("pc"))
        var direct = NewServer(pc); direct.network = .direct
        let switched = try ServerConfigEditor.updating(direct, notify: false, from: pc, in: added)
        XCTAssertFalse(switched.contains("vpn="), switched)
        XCTAssertEqual(try ServerConfigParser.parse(switched).server("pc")?.network, .direct)
        var renamed = NewServer(pc); renamed.vpn = "Home"
        let renamedText = try ServerConfigEditor.updating(renamed, notify: false, from: pc, in: added)
        XCTAssertTrue(renamedText.contains("network=vpn\nvpn=Home\ntype=windows"), renamedText)
    }
}
