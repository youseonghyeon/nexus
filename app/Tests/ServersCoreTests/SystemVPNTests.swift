// 시스템 설정 VPN (scutil --nc): 목록 해석 · 요약 · 켜기/끄기 뒤 상태 기다리기.
// Fixtures/scutil-nc-list.txt 는 이 Mac 의 실제 출력이다 (2026-10-15 — Unicorn Invalid · Tailscale · WireGuard).

import Foundation
import XCTest
@testable import ServersCore

/// scutil --nc status 에 차례로 다른 상태를 돌려주는 가짜 (start/stop 은 startExit 로)
private final class VPNRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [[String]] = []
    var startExit: Int32 = 0
    var startStderr = ""
    var statuses: [String]
    init(statuses: [String]) { self.statuses = statuses }

    func hasExecutable(_ name: String) -> Bool { true }
    func run(_ executable: String, _ arguments: [String], stdin: String?, environment: [String: String], timeout: TimeInterval) async -> CommandResult {
        lock.withLock {
            calls.append([executable] + arguments)
            if arguments.dropFirst().first == "status" {
                let word = statuses.count > 1 ? statuses.removeFirst() : (statuses.first ?? "")
                return CommandResult(exitCode: 0, stdout: "\(word)\nExtended Status <dictionary> {\n}\n")
            }
            return CommandResult(exitCode: startExit, stderr: startStderr)
        }
    }
}

final class SystemVPNTests: XCTestCase {
    func testParsesRealListAndHidesTailscale() throws {
        let vpns = SystemVPNs.parse(try fixtureText("scutil-nc-list"))
        XCTAssertEqual(vpns.map(\.name), ["Unicorn HTTPS", "MacBook"])   // Tailscale 은 자기 행이 있어 뺀다
        let unicorn = vpns[0]
        XCTAssertEqual(unicorn.state, .invalid)
        XCTAssertFalse(unicorn.enabled)
        XCTAssertFalse(unicorn.canToggle)
        let wireguard = vpns[1]
        XCTAssertEqual(wireguard.id, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(wireguard.kind, "WireGuard")
        XCTAssertTrue(wireguard.enabled)
        XCTAssertTrue(wireguard.isOn)
        XCTAssertTrue(wireguard.canToggle)
    }

    /// macOS 내장 VPN 줄 모양 (번들 없음) — 이 Mac 엔 없어 손으로 적은 줄
    func testBuiltInKinds() {
        let text = """
        Available network connection services in the current set (*=enabled):
        * (Disconnected)   11111111-2222-3333-4444-555555555555 IPSec              "Office \\"A\\""   [IPSec]
          (Connecting)     66666666-7777-8888-9999-000000000000 PPP --> L2TP       "Old"              [PPP:L2TP]
        """
        let vpns = SystemVPNs.parse(text)
        XCTAssertEqual(vpns.map(\.kind), ["IPSec", "L2TP"])
        XCTAssertEqual(vpns.map(\.state), [.disconnected, .connecting])
        XCTAssertEqual(vpns[1].isOn, true)
        XCTAssertFalse(vpns[1].canToggle)   // * 없음 = 현재 위치에서 꺼진 서비스 → start 가 듣지 않는다
        XCTAssertTrue(vpns[0].canToggle)
        XCTAssertTrue(SystemVPNs.parse("").isEmpty)
    }

    func testSummary() {
        func vpn(_ name: String, _ state: SystemVPN.State) -> SystemVPN { SystemVPN(id: name, name: name, kind: "WireGuard", enabled: true, state: state) }
        XCTAssertEqual(SystemVPNs.summary([vpn("A", .connected), vpn("B", .invalid)]), "A 연결됨")
        XCTAssertEqual(SystemVPNs.summary([vpn("A", .connected), vpn("B", .connected)]), "2개 연결")
        XCTAssertEqual(SystemVPNs.summary([vpn("A", .disconnected), vpn("B", .connecting)]), "B 연결 중")
        XCTAssertEqual(SystemVPNs.summary([vpn("A", .disconnected)]), "꺼짐")
    }

    /// 사이드바 버튼: 켜진 게 있으면 그것 전부 끄기(연결 중도 켜짐), 없으면 하나는 바로 켜기 · 여럿은 고르기 · 켤 수 없는 것(비활성·Invalid)은 후보에서 뺀다
    func testRowAction() {
        func vpn(_ name: String, _ state: SystemVPN.State, enabled: Bool = true) -> SystemVPN { SystemVPN(id: name, name: name, kind: "WireGuard", enabled: enabled, state: state) }
        let brume = vpn("Brume 3", .disconnected), office = vpn("Office", .disconnected)
        XCTAssertEqual(SystemVPNs.rowAction([]), .unavailable)
        XCTAssertEqual(SystemVPNs.rowAction([brume]), .turnOn(brume))
        XCTAssertEqual(SystemVPNs.rowAction([brume, office]), .choose([brume, office]))
        XCTAssertEqual(SystemVPNs.rowAction([brume, vpn("Off", .disconnected, enabled: false), vpn("Bad", .invalid)]), .turnOn(brume))
        XCTAssertEqual(SystemVPNs.rowAction([vpn("Off", .disconnected, enabled: false)]), .unavailable)
        let connected = vpn("Brume 3", .connected), connecting = vpn("Office", .connecting)
        XCTAssertEqual(SystemVPNs.rowAction([connected, office]), .turnOff([connected]))
        XCTAssertEqual(SystemVPNs.rowAction([connected, connecting]), .turnOff([connected, connecting]))
    }

    func testListFailureIsNil() async {
        let runner = VPNRunner(statuses: [])
        runner.startExit = 1
        let listed = await SystemVPNs.list(runner: runner)
        XCTAssertNil(listed)
    }

    private let wireguard = SystemVPN(id: "11111111-1111-4111-8111-111111111111", name: "MacBook", kind: "WireGuard", enabled: true, state: .disconnected)

    func testTurnOnWaitsUntilConnected() async {
        let runner = VPNRunner(statuses: ["Disconnected", "Connecting", "Connecting", "Connected"])
        let error = await SystemVPNs.set(wireguard, on: true, runner: runner, timeout: 5, interval: 0)
        XCTAssertNil(error)
        XCTAssertEqual(runner.calls.first, ["scutil", "--nc", "start", wireguard.id])   // 이름이 아니라 UUID 로
        XCTAssertEqual(runner.calls.filter { $0.contains("status") }.count, 4)
    }

    func testTurnOffUsesStop() async {
        let runner = VPNRunner(statuses: ["Disconnecting", "Disconnected"])
        let error = await SystemVPNs.set(wireguard, on: false, runner: runner, timeout: 5, interval: 0)
        XCTAssertNil(error)
        XCTAssertEqual(runner.calls.first, ["scutil", "--nc", "stop", wireguard.id])
    }

    /// 연결 중을 거쳐 다시 꺼짐 = 연결 실패. 시간 끝까지 기다리지 않는다.
    func testConnectFailureStopsEarly() async {
        let runner = VPNRunner(statuses: ["Connecting", "Disconnected"])
        let started = Date()
        let error = await SystemVPNs.set(wireguard, on: true, runner: runner, timeout: 30, interval: 0)
        XCTAssertEqual(error, "MacBook VPN 을 켜지 못했습니다 · 지금 상태 꺼짐")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// 요청 직후엔 아직 꺼짐일 수 있다 — 연결 중을 거치기 전의 꺼짐은 실패로 보지 않는다
    func testDisconnectedBeforeConnectingIsNotFailure() async {
        let runner = VPNRunner(statuses: ["Disconnected", "Disconnected", "Connecting", "Connected"])
        let error = await SystemVPNs.set(wireguard, on: true, runner: runner, timeout: 5, interval: 0)
        XCTAssertNil(error)
    }

    /// 전환 중·알 수 없는 상태에서 [켜기] 를 보내지 않는다
    func testTransitionalStatesShowAsOn() {
        for state: SystemVPN.State in [.connecting, .disconnecting, .other("Reasserting")] {
            XCTAssertTrue(SystemVPN(id: "x", name: "x", kind: "x", enabled: true, state: state).isOn, "\(state)")
        }
        XCTAssertFalse(SystemVPN(id: "x", name: "x", kind: "x", enabled: true, state: .disconnected).isOn)
    }

    /// 연결 중을 못 본 빠른 실패: 꺼짐이 settle 초 넘게 이어지면 timeout 전에 실패
    func testFastFailureWithoutConnectingStopsAfterSettle() async {
        let runner = VPNRunner(statuses: ["Disconnected"])
        let started = Date()
        let error = await SystemVPNs.set(wireguard, on: true, runner: runner, timeout: 30, interval: 0.01, settle: 0.1)
        XCTAssertEqual(error, "MacBook VPN 을 켜지 못했습니다 · 지금 상태 꺼짐")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // MARK: 상세 (실제 출력 — 공인 IP·tailnet 이름은 예시 값으로, 비밀번호 줄은 지움)

    private func fixture(_ name: String) throws -> String {
        try fixtureText(name)
    }

    func testDetailFromRealConnectedOutput() throws {
        let detail = SystemVPNs.parseDetail(show: try fixture("scutil-nc-show-wireguard"), status: try fixture("scutil-nc-status-connected"),
                                            statistics: try fixture("scutil-nc-statistics"))
        XCTAssertEqual(detail.server, "203.0.113.10:51820")
        XCTAssertEqual(detail.onDemand, false)
        XCTAssertEqual(detail.providerBundleID, "com.wireguard.macos.network-extension")
        XCTAssertEqual(detail.interface, "utun7")
        XCTAssertEqual(detail.ipv4, ["10.1.0.2"])
        XCTAssertEqual(detail.ipv6, ["fd00:1111:2222:3333::2"])
        XCTAssertEqual(detail.routes, ["10.1.0.0/24", "fd00:1111:2222:3333::/64"])
        XCTAssertEqual(detail.dnsServers, ["10.1.0.1", "fd00:1111:2222:3333::1"])
        XCTAssertEqual(detail.searchDomains, ["example.ts.net"])   // 빈 값("0 : ")은 빠진다
        XCTAssertEqual(detail.primary, true)
        XCTAssertNotNil(detail.connectedAt)   // 값 판정은 testConnectedAtFromLastStatusChangeNotConnectTime
        XCTAssertEqual(detail.bytesIn, 280_669_198)
        XCTAssertEqual(detail.bytesOut, 12_338_891)
    }

    /// 연결 시작 = LastStatusChangeTime. VPN.ConnectTime 은 길이가 아니라 "깨어 있던 시간" 도장이다
    /// (2026-11-10 실측: 방금 켠 연결이 ConnectTime 56367 — 길이로 쓰면 "15시간 39분". 그때 깨어 있던 시간은 56588, LastStatusChangeTime 은 221초 전)
    func testConnectedAtFromLastStatusChangeNotConnectTime() throws {
        let seoul = TimeZone(identifier: "Asia/Seoul")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = seoul
        let connected = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 13, minute: 57, second: 10))!
        let now = connected.addingTimeInterval(221)
        let status = try fixture("scutil-nc-status-connected")
            .replacingOccurrences(of: "LastStatusChangeTime : 10/15/2026 09:31:20", with: "LastStatusChangeTime : 11/10/2026 13:57:10")
            .replacingOccurrences(of: "ConnectTime : 1547", with: "ConnectTime : 56367")
        let detail = SystemVPNs.parseDetail(show: "", status: status, statistics: "", now: now, uptime: 56588, timeZone: seoul)
        XCTAssertEqual(detail.connectedAt, connected)
        XCTAssertEqual(detail.connectedSeconds, 221)   // 56367 이 아니다

        // 잠든 시간이 끼어도 벽시계 기준: 어제 21:19 에 연결 → 16시간 41분 (깨어 있던 시간만 세면 6시간)
        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 21, minute: 19, second: 8))!
        let slept = SystemVPNs.connectedAt(lastStatusChange: "11/09/2026 21:19:08", connectTime: 34015, now: now, uptime: 56588, timeZone: seoul)
        XCTAssertEqual(slept, yesterday)
    }

    /// LastStatusChangeTime 을 못 쓰면 깨어 있던 시간으로 거슬러 센다. 그것도 없으면 모른다 (틀린 값을 내지 않는다)
    func testConnectedAtFallbacks() {
        let seoul = TimeZone(identifier: "Asia/Seoul")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cases: [(String?, Double?, TimeInterval?, Date?)] = [
            (nil, 56367, 56588, now.addingTimeInterval(-221)),                 // 시각 줄 없음 → 깨어 있던 시간 차
            ("not a date", 56367, 56588, now.addingTimeInterval(-221)),        // 못 읽는 꼴
            ("01/01/2099 00:00:00", 56367, 56588, now.addingTimeInterval(-221)),   // 미래 시각은 믿지 않는다
            (nil, 56367, nil, nil),                                            // 깨어 있던 시간을 모름
            (nil, nil, 56588, nil),                                            // ConnectTime 없음
            (nil, 60000, 56588, nil),                                          // 재부팅 뒤 옛 도장(깨어 있던 시간보다 큼)
        ]
        for (stamp, connectTime, uptime, expected) in cases {
            XCTAssertEqual(SystemVPNs.connectedAt(lastStatusChange: stamp, connectTime: connectTime, now: now, uptime: uptime, timeZone: seoul),
                           expected, "\(stamp ?? "nil") \(String(describing: connectTime)) \(String(describing: uptime))")
        }
    }

    /// 꺼진·Invalid VPN: 구성에서 읽은 것만 (주소·통계 없음)
    func testDetailWhenNotConnected() throws {
        let detail = SystemVPNs.parseDetail(show: try fixture("scutil-nc-show-invalid"), status: try fixture("scutil-nc-status-invalid"), statistics: "")
        XCTAssertEqual(detail, SystemVPNDetail())
        let configOnly = SystemVPNs.parseDetail(show: try fixture("scutil-nc-show-wireguard"), status: "Disconnected\n", statistics: "")
        XCTAssertEqual(configOnly.server, "203.0.113.10:51820")
        XCTAssertNil(configOnly.interface)
        XCTAssertTrue(configOnly.ipv4.isEmpty)
    }

    func testDetailFetchSkipsStatisticsWhenDisconnected() async {
        let runner = VPNRunner(statuses: ["Disconnected"])
        _ = await SystemVPNs.detail(wireguard, runner: runner)
        XCTAssertFalse(runner.calls.contains { $0.contains("statistics") })
        XCTAssertFalse(runner.calls.contains { $0.first == "ifconfig" })
    }

    func testHelpers() {
        XCTAssertEqual(SystemVPNs.mtu("utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1420\n"), 1420)
        XCTAssertEqual(SystemVPNs.duration(975), "16분 15초")
        XCTAssertEqual(SystemVPNs.duration(3 * 3600 + 120), "3시간 2분")
        XCTAssertEqual(SystemVPNs.duration(2 * 86_400 + 4 * 3600), "2일 4시간")
        XCTAssertEqual(SystemVPNs.duration(5), "5초")
        XCTAssertTrue(SystemVPNs.splitEndpoint("203.0.113.10:51820") == ("203.0.113.10", "51820"))
        XCTAssertTrue(SystemVPNs.splitEndpoint("[2001:db8::1]:51820") == ("2001:db8::1", "51820"))
        XCTAssertTrue(SystemVPNs.splitEndpoint("2001:db8::1") == ("2001:db8::1", nil))
        XCTAssertTrue(SystemVPNs.splitEndpoint("vpn.example.com") == ("vpn.example.com", nil))
    }

    func testTimeoutReportsLastState() async {
        let runner = VPNRunner(statuses: ["Connecting"])
        let error = await SystemVPNs.set(wireguard, on: true, runner: runner, timeout: 0.05, interval: 0.01)
        XCTAssertEqual(error, "MacBook VPN 을 켜지 못했습니다 · 지금 상태 연결 중")
    }

    func testStartCommandFailure() async {
        let runner = VPNRunner(statuses: ["Disconnected"])
        runner.startExit = 1
        runner.startStderr = "No service\n"
        let error = await SystemVPNs.set(wireguard, on: true, runner: runner, timeout: 5, interval: 0)
        XCTAssertEqual(error, "MacBook VPN 을 켜지 못했습니다 · No service")
        XCTAssertEqual(runner.calls.count, 1)   // 상태를 기다리지 않는다
    }

    /// 잘린 출력(시간 제한에 걸려 닫는 "}" 가 없음): 이름 없는 맨 바깥 사전도 닫힌 것과 같이 뿌리로 읽는다 (statistics · --proxy 꼴)
    func testTruncatedOutputKeepsUnnamedRoot() {
        let whole = SCDictionary.parse("<dictionary> {\n  VPN : <dictionary> {\n    BytesIn : 10\n    BytesOut : 20\n  }\n}\n")
        let cut = SCDictionary.parse("<dictionary> {\n  VPN : <dictionary> {\n    BytesIn : 10\n    BytesOut : 20\n")
        XCTAssertEqual(cut.child("VPN")?.values["BytesIn"], "10")
        XCTAssertEqual(cut, whole)
        XCTAssertEqual(SystemProxy.parse("<dictionary> {\n  HTTPEnable : 1\n  HTTPPort : 8080\n  HTTPProxy : 10.0.0.1\n"), ["HTTP 10.0.0.1:8080"])
        // 이름 있는 사전이 안 닫힌 경우는 예전대로 그 이름 아래에
        XCTAssertEqual(SCDictionary.parse("Extended Status <dictionary> {\n  IsPrimaryInterface : 1\n").child("Extended Status")?.values["IsPrimaryInterface"], "1")
    }

    /// 상세는 show · status · statistics 를 함께 읽는다 — 연결된 VPN 은 셋 다 한 번씩 (순서는 정해지지 않는다)
    func testDetailReadsShowStatusStatisticsOnce() async {
        var on = wireguard
        on.state = .connected
        let runner = VPNRunner(statuses: ["Disconnected"])
        _ = await SystemVPNs.detail(on, runner: runner)
        for verb in ["show", "status", "statistics"] {
            XCTAssertEqual(runner.calls.filter { $0 == ["scutil", "--nc", verb, on.id] }.count, 1, verb)
        }
    }
}
