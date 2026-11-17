// 주기 갱신의 읽기 줄이기 (FakeRunner 가 부른 명령을 센다): 한 라운드 안의 같은 읽기는 한 번(SharedReads) ·
// 게이트웨이 응답 15초(GatewayCache) · VPN 바깥 장치 45초(VPNEgressCache) · 강제는 캐시를 지난다.

import Foundation
import XCTest
@testable import ServersCore

final class RoundReadsTests: XCTestCase {
    private func count(_ runner: FakeRunner, _ command: String) -> Int {
        runner.calls.filter { ([$0.executable] + $0.arguments).joined(separator: " ") == command }.count
    }

    /// 내부망 + vpn 서버가 있는 목록 (5초 갱신이 scutil --nc list 를 StatusMonitor·VPN 목록 둘 다에서 읽던 조건)
    private func vpnConfig() throws -> ServerConfig {
        try ServerConfigParser.parse(fixture + """


        [home1]
        group=ext
        network=vpn
        vpn=MacBook
        type=linux
        ip=192.168.8.10
        user=tester
        port=22
        """)
    }

    private func runnerWithVPN() throws -> FakeRunner {
        let runner = FakeRunner()
        runner.scripted["scutil --nc list"] = CommandResult(exitCode: 0, stdout: try fixtureText("scutil-nc-list"))
        runner.scripted["scutil --nc status 11111111-1111-4111-8111-111111111111"] = CommandResult(exitCode: 0, stdout: try fixtureText("scutil-nc-status-connected"))
        runner.ifconfigOutput = "en9: flags=8863<UP> mtu 1500\n\tinet 10.50.10.17 netmask 0xffffff00\n\tstatus: active\n"
        return runner
    }

    /// 5초 갱신 한 바퀴를 앱처럼 흉내 낸다: 로컬 상태(StatusMonitor) · VPN 목록 · 유선 스냅숏 · Intranet 화면 정보를 함께, 같은 SharedReads 로
    private func round(_ runner: FakeRunner, config: ServerConfig) async -> (StatusSnapshot, [SystemVPN]?, WiredSnapshot, LanInfo) {
        let reads = SharedReads(runner)
        async let local: StatusSnapshot = {
            var snapshot = StatusSnapshot()
            await StatusMonitor(config: config, runner: reads, tcpProbe: runner.tcpProbe).collectLocal(into: &snapshot)
            return snapshot
        }()
        async let vpns = SystemVPNs.list(runner: reads)
        async let wired = WiredSnapshot.fetch(runner: reads)
        async let lan = NetworkInfoFetcher.lan(config.lan!, runner: reads)
        async let tailscale = NetworkInfoFetcher.tailscale(runner: reads)   // Tailscale 화면을 보고 있을 때
        _ = await tailscale
        return await (local, vpns, wired, lan)
    }

    /// 한 라운드에 서비스 목록·ifconfig·scutil --nc list·내부망 -getinfo 는 한 번씩. -listallnetworkservices·-listallhardwareports 는 더 읽지 않는다.
    func testOneRoundReadsEachListingOnce() async throws {
        let runner = try runnerWithVPN()
        let (local, vpns, wired, lan) = await round(runner, config: try vpnConfig())
        XCTAssertEqual(count(runner, "scutil --nc list"), 1, "StatusMonitor 의 vpn 연결 확인과 VPN 목록이 나눠 쓴다")
        XCTAssertEqual(count(runner, "tailscale status --json"), 1, "상태 확인과 Tailscale 화면이 나눠 쓴다")
        XCTAssertEqual(count(runner, "networksetup -listnetworkserviceorder"), 1, "내부망 상태·장치·유선 스냅숏·Intranet 화면 공통")
        XCTAssertEqual(count(runner, "ifconfig"), 1, "어댑터 있음·유선 스냅숏·Intranet 실제 주소 공통")
        XCTAssertEqual(count(runner, "networksetup -getinfo Test Ethernet"), 1, "유선 스냅숏과 Intranet 화면 공통")
        XCTAssertEqual(count(runner, "networksetup -listallnetworkservices"), 0, "활성 여부는 서비스 순서 목록의 (*) 로")
        XCTAssertEqual(count(runner, "networksetup -listallhardwareports"), 0, "어댑터 있음은 ifconfig 로")
        // 나눠 써도 값은 같다
        XCTAssertEqual(local.lan, .up)
        XCTAssertEqual(local.lanDevice, "en9")
        XCTAssertTrue(local.lanAdapterPresent)
        XCTAssertEqual(local.vpnLinks.first { $0.name == "MacBook" }?.device, "utun7")
        XCTAssertEqual(vpns?.map(\.name), ["Unicorn HTTPS", "MacBook"])
        XCTAssertEqual(wired.link(named: "Test Ethernet"), .connected(ip: "10.50.10.17"))
        XCTAssertEqual(lan.actualIP, "10.50.10.17")
        XCTAssertTrue(lan.enabled)
    }

    /// 라운드를 넘어 값을 쥐지 않는다 — 다음 라운드(새 SharedReads)는 다시 읽는다
    func testNextRoundReadsAgain() async throws {
        let runner = try runnerWithVPN()
        let config = try vpnConfig()
        _ = await round(runner, config: config)
        _ = await round(runner, config: config)
        XCTAssertEqual(count(runner, "scutil --nc list"), 2)
        XCTAssertEqual(count(runner, "networksetup -listnetworkserviceorder"), 2)
    }

    /// 라운드 도중 켜기·끄기 뒤(invalidate) 묻는 읽기는 새로 돈다 — 받아 둔 목록을 나눠 주지 않는다
    func testInvalidateMakesLaterReadsFresh() async {
        let runner = FakeRunner()
        let reads = SharedReads(runner)
        _ = await reads.run("networksetup", ["-listnetworkserviceorder"], timeout: 5)
        _ = await reads.run("networksetup", ["-listnetworkserviceorder"], timeout: 5)
        XCTAssertEqual(count(runner, "networksetup -listnetworkserviceorder"), 1)
        reads.invalidate()
        runner.lanEnabled = false
        _ = await reads.run("networksetup", ["-listnetworkserviceorder"], timeout: 5)
        _ = await reads.run("networksetup", ["-listnetworkserviceorder"], timeout: 5)
        XCTAssertEqual(count(runner, "networksetup -listnetworkserviceorder"), 2, "비운 뒤 한 번 새로 읽고, 그 뒤로는 다시 나눈다")
    }

    /// 나누지 않는 명령(ping·ssh·쓰기)은 그대로 매번 — ssh 의 조기 중단(abortOnLine)도 그대로 넘긴다
    func testSharedReadsPassesOtherCommandsThrough() async {
        final class AbortRunner: CommandRunner, @unchecked Sendable {
            var sawAbort = false
            func hasExecutable(_ name: String) -> Bool { true }
            func run(_ executable: String, _ arguments: [String], stdin: String?, environment: [String: String], timeout: TimeInterval) async -> CommandResult {
                CommandResult(exitCode: 0)
            }
            func run(_ executable: String, _ arguments: [String], stdin: String?, environment: [String: String], timeout: TimeInterval,
                     abortOnLine: (@Sendable (String) -> Bool)?) async -> CommandResult {
                if abortOnLine != nil { sawAbort = true }
                return CommandResult(exitCode: 0)
            }
        }
        let runner = FakeRunner()
        let reads = SharedReads(runner)
        _ = await reads.run("ping", ["-c", "1", "10.0.0.1"], timeout: 3)
        _ = await reads.run("ping", ["-c", "1", "10.0.0.1"], timeout: 3)
        _ = await reads.run("scutil", ["--nc", "start", "X"], timeout: 3)
        _ = await reads.run("scutil", ["--nc", "start", "X"], timeout: 3)
        _ = await reads.run("ifconfig", ["en9"], timeout: 3)
        _ = await reads.run("ifconfig", ["en9"], timeout: 3)
        XCTAssertEqual(count(runner, "ping -c 1 10.0.0.1"), 2)
        XCTAssertEqual(count(runner, "scutil --nc start X"), 2)
        XCTAssertEqual(count(runner, "ifconfig en9"), 2, "장치 하나 ifconfig 는 나누지 않는다 (링크 속도 등 화면별 읽기)")
        let abort = AbortRunner()
        _ = await SharedReads(abort).run("ssh", ["host", "true"], stdin: nil, environment: [:], timeout: 8, abortOnLine: { _ in false })
        XCTAssertTrue(abort.sawAbort)
    }

    /// 내부망 서비스가 꺼져 있으면 (*) 로 down, 목록에 없으면 missing (장치 nil) — 예전 -listallnetworkservices 판정과 같다
    func testLanStateFromServiceOrder() async throws {
        let config = try ServerConfigParser.parse(fixture)
        let runner = FakeRunner()
        runner.lanEnabled = false
        var snapshot = StatusSnapshot()
        await StatusMonitor(config: config, runner: runner, tcpProbe: runner.tcpProbe).collectLocal(into: &snapshot)
        XCTAssertEqual(snapshot.lan, .down)
        XCTAssertEqual(snapshot.lanDevice, "en9")
        runner.scripted["networksetup -listnetworkserviceorder"] = CommandResult(exitCode: 0, stdout: "(1) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en0)\n")
        snapshot.lanAdapterPresent = false
        await StatusMonitor(config: config, runner: runner, tcpProbe: runner.tcpProbe).collectLocal(into: &snapshot)
        XCTAssertEqual(snapshot.lan, .missing)
        XCTAssertNil(snapshot.lanDevice)
        XCTAssertFalse(snapshot.lanAdapterPresent, "서비스가 없으면 어댑터 값은 건드리지 않는다 (예전과 같다)")
    }

    // MARK: 게이트웨이 응답 (GatewayCache)

    /// 수동 IP 서비스 (FakeRunner: Test Ethernet 10.50.10.17 → 10.50.10.254, en9 에 붙음)
    private func manualRunner() -> FakeRunner {
        let runner = FakeRunner()
        runner.ifconfigOutput = "en9: flags=8863<UP> mtu 1500\n\tinet 10.50.10.17 netmask 0xffffff00\n\tstatus: active\n"
        return runner
    }

    private let gatewayPing = "ping -c 1 -t 1 -b en9 10.50.10.254"

    func testGatewayAnswerIsReusedFor15Seconds() async {
        let runner = manualRunner()
        let cache = GatewayCache()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var snapshot = await WiredSnapshot.fetch(runner: runner, gateways: cache, now: t0)
        XCTAssertEqual(snapshot.gateways["Test Ethernet"], true)
        for at in [5.0, 10, 14.9] { snapshot = await WiredSnapshot.fetch(runner: runner, gateways: cache, now: t0 + at) }
        XCTAssertEqual(count(runner, gatewayPing), 1, "15초 안에는 ping 하지 않는다")
        XCTAssertEqual(snapshot.gateways["Test Ethernet"], true, "캐시 값으로 연결 판정은 그대로")
        XCTAssertEqual(snapshot.link(named: "Test Ethernet"), .connected(ip: "10.50.10.17"))
        _ = await WiredSnapshot.fetch(runner: runner, gateways: cache, now: t0 + 15)
        XCTAssertEqual(count(runner, gatewayPing), 2, "15초가 지나면 다시")
        XCTAssertEqual(count(runner, "networksetup -getinfo Test Ethernet"), 5, "-getinfo 는 매번 (IP·게이트웨이가 바뀌었는지 이걸로 안다)")
    }

    func testGatewayCacheForcedOrChangedAddressAsksAgain() async {
        let runner = manualRunner()
        let cache = GatewayCache()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = await WiredSnapshot.fetch(runner: runner, gateways: cache, now: t0)
        runner.pingOK = false
        var snapshot = await WiredSnapshot.fetch(runner: runner, gateways: cache, force: true, now: t0 + 1)
        XCTAssertEqual(count(runner, gatewayPing), 2, "활성화·지정 뒤(force)는 캐시를 보지 않는다")
        XCTAssertEqual(snapshot.gateways["Test Ethernet"], false, "새 답 (ping 실패 · ARP 도 없음)")
        snapshot = await WiredSnapshot.fetch(runner: runner, gateways: cache, now: t0 + 2)
        XCTAssertEqual(snapshot.gateways["Test Ethernet"], false)
        XCTAssertEqual(count(runner, gatewayPing), 3, "응답 없음은 캐시하지 않는다 — 다음 읽기가 바로 다시 묻는다 (꽂은 직후 첫 실패)")
        // 게이트웨이가 바뀌면 (같은 서비스라도) 다시 묻는다
        runner.scripted["networksetup -getinfo Test Ethernet"] = CommandResult(exitCode: 0, stdout: "Manual Configuration\nIP address: 10.50.10.17\nSubnet mask: 255.255.255.0\nRouter: 10.50.10.1\n")
        runner.pingOK = true
        snapshot = await WiredSnapshot.fetch(runner: runner, gateways: cache, now: t0 + 3)
        XCTAssertEqual(count(runner, "ping -c 1 -t 1 -b en9 10.50.10.1"), 1)
        XCTAssertEqual(snapshot.gateways["Test Ethernet"], true)
    }

    /// 캐시 없이 부르면 예전처럼 매번 묻는다
    func testWithoutGatewayCacheAsksEveryTime() async {
        let runner = manualRunner()
        _ = await WiredSnapshot.fetch(runner: runner)
        _ = await WiredSnapshot.fetch(runner: runner)
        XCTAssertEqual(count(runner, gatewayPing), 2)
    }

    // MARK: VPN 바깥 장치 (VPNEgressCache)

    private func egressRunner() throws -> FakeRunner {
        let runner = FakeRunner()
        runner.scripted["ps -axo pid=,comm="] = CommandResult(exitCode: 0, stdout: "  1 /sbin/launchd\n 1260 /Library/SystemExtensions/AB/com.example.vpn.ext.systemextension/Contents/MacOS/com.example.vpn.ext\n")
        runner.scripted["nettop -L 1 -n -m udp -p 1260"] = CommandResult(exitCode: 0, stdout: try fixtureText("nettop-wireguard-udp"))
        runner.scripted["nettop -L 1 -n -m tcp -p 1260"] = CommandResult(exitCode: 0, stdout: "")
        runner.scripted["route -n get -ifscope en11 default"] = CommandResult(exitCode: 0, stdout: "    gateway: 192.168.8.1\n  interface: en11\n")
        return runner
    }

    func testEgressIsReusedWhileNetworkIsSame() async throws {
        let runner = try egressRunner()
        let cache = VPNEgressCache()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func fetch(_ at: TimeInterval, network: String = "en11|Ethernet", force: Bool = false) async -> [VPNEgress] {
            await cache.fetch(vpnID: "V1", providerBundleID: "com.example.vpn.ext", tunnel: "utun7", network: network, force: force, runner: runner, now: t0 + at)
        }
        var egress = await fetch(0)
        XCTAssertEqual(egress.map(\.text), ["en11 (Ethernet) · 192.168.8.1"])
        egress = await fetch(5)
        egress = await fetch(44)
        XCTAssertEqual(count(runner, "ps -axo pid=,comm="), 1, "45초 안·같은 망이면 ps·nettop·route 를 다시 돌지 않는다")
        XCTAssertEqual(count(runner, "nettop -L 1 -n -m udp -p 1260"), 1)
        XCTAssertEqual(egress.map(\.text), ["en11 (Ethernet) · 192.168.8.1"])
        _ = await fetch(45)
        XCTAssertEqual(count(runner, "ps -axo pid=,comm="), 2, "45초가 지나면 다시")
        _ = await fetch(46, network: "en0|Wi-Fi")
        XCTAssertEqual(count(runner, "ps -axo pid=,comm="), 3, "회선(기본 경로·연결된 장치)이 바뀌면 다시")
        _ = await fetch(47, network: "en0|Wi-Fi", force: true)
        XCTAssertEqual(count(runner, "ps -axo pid=,comm="), 4, "새로고침은 캐시를 보지 않는다")
    }

    /// 못 찾은 결과는 쥐지 않는다 — 확장이 아직 소켓을 안 열었을 때 45초 동안 "–" 로 남지 않게
    func testEmptyEgressIsNotCached() async throws {
        let runner = FakeRunner()   // ps 없음 → 빈 목록
        let cache = VPNEgressCache()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = await cache.fetch(vpnID: "V1", providerBundleID: "com.example.vpn.ext", tunnel: "utun7", network: "n", runner: runner, now: t0)
        _ = await cache.fetch(vpnID: "V1", providerBundleID: "com.example.vpn.ext", tunnel: "utun7", network: "n", runner: runner, now: t0 + 5)
        XCTAssertEqual(count(runner, "ps -axo pid=,comm="), 2)
    }

    // MARK: TimedValue

    func testTimedValue() {
        var value = TimedValue<Int>()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(value.fresh(now: t0, ttl: 30))
        value.store(7, at: t0, key: "a")
        XCTAssertEqual(value.fresh(now: t0 + 29.9, ttl: 30, key: "a"), 7)
        XCTAssertNil(value.fresh(now: t0 + 30, ttl: 30, key: "a"), "ttl 이 지나면")
        XCTAssertNil(value.fresh(now: t0 + 1, ttl: 30, key: "b"), "조건이 바뀌면")
        XCTAssertNil(value.fresh(now: t0 - 1, ttl: 30, key: "a"), "시계가 뒤로 가면")
    }
}
