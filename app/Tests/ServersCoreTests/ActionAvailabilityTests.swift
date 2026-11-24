// 버튼 가능 여부 상태 표 (ActionAvailability). 조합마다 한 줄 — 빈 상태(그 종류의 첫 항목을 추가할 때)를 꼭 넣는다.
// 실제 명령은 실행하지 않는다 (FakeRunner).

import Foundation
import XCTest
@testable import ServersCore

final class ActionAvailabilityTests: XCTestCase {
    private let wireguardID = "11111111-1111-4111-8111-111111111111"

    private func server(_ key: String, _ network: ServerNetwork, type: ServerType = .linux, vpn: String? = nil) -> Server {
        Server.sample(key: key, network: network, type: type, ip: "192.168.8.10", check: .tcp, vpn: vpn)
    }

    private let remoteStates: [(name: String, state: RemoteState?)] = [
        ("확인 전", nil), ("ok", .ok(latencyMs: 5)), ("fail", .fail(latencyMs: 5)), ("off", .off(latencyMs: 5)),
        ("skip", .skip(reason: "vpn down")), ("needsAuth", .needsAuth(url: nil)),
    ]

    private func snapshot(_ key: String, _ state: RemoteState?, vpnDevice: String? = nil) -> StatusSnapshot {
        var snap = StatusSnapshot()
        if let state { snap.remote[key] = state }
        if let vpnDevice { snap.vpnLinks = [VPNLink(name: "MacBook", device: vpnDevice)] }
        return snap
    }

    // MARK: 연결 (SSH·터널·전송·원격 정보·파일 놓기)

    func testAllowsConnectionTable() {
        // 묶지 않는 망·묶을 장치가 있는 vpn: 확인 전·ok 만 허용
        let open: [String: Bool] = ["확인 전": true, "ok": true, "fail": false, "off": false, "skip": false, "needsAuth": false]
        for (name, state) in remoteStates {
            for network in [ServerNetwork.direct, .tailscale, .lan] {
                XCTAssertEqual(snapshot("s", state).allowsConnection(to: server("s", network)), open[name], "\(network) · \(name)")
            }
            XCTAssertEqual(snapshot("s", state, vpnDevice: "utun7").allowsConnection(to: server("s", .vpn, vpn: "MacBook")), open[name], "vpn 연결됨 · \(name)")
            // vpn 인데 묶을 utun 이 없으면 무엇이든 막는다 — 확인 전(막 추가한 서버)·ok(방금 끊긴 VPN)도
            XCTAssertFalse(snapshot("s", state).allowsConnection(to: server("s", .vpn, vpn: "MacBook")), "vpn 목록 없음 · \(name)")
            var down = snapshot("s", state)
            down.vpnLinks = [VPNLink(name: "MacBook", device: nil)]
            XCTAssertFalse(down.allowsConnection(to: server("s", .vpn, vpn: "MacBook")), "vpn 꺼짐 · \(name)")
            XCTAssertFalse(snapshot("s", state, vpnDevice: "utun7").allowsConnection(to: server("s", .vpn, vpn: "Office")), "다른 이름의 vpn · \(name)")
        }
    }

    // MARK: 전원

    func testWakeAndShutdownTable() {
        let via = server("via", .direct)
        for type in [ServerType.linux, .windows] {
            let target = server("t", .direct, type: type)
            for (name, state) in remoteStates {
                for (viaName, viaState) in remoteStates {
                    for idle in [true, false] {
                        var snap = snapshot("t", state)
                        if let viaState { snap.remote["via"] = viaState }
                        let wake = snap.canWake(target, via: via, idle: idle)
                        let shutdown = snap.canShutdown(target, idle: idle)
                        let label = "\(type) · 대상 \(name) · 경유 \(viaName) · idle \(idle)"
                        let on = name == "ok"
                        XCTAssertEqual(wake, idle && !on && (viaName == "확인 전" || viaName == "ok"), "Wake — \(label)")
                        XCTAssertEqual(shutdown, idle && on && type == .windows, "Shutdown — \(label)")
                        XCTAssertFalse(wake && shutdown, "둘이 함께 켜지지 않는다 — \(label)")
                    }
                }
            }
            XCTAssertFalse(snapshot("t", .off(latencyMs: 1)).canWake(target, via: nil, idle: true), "경유 서버 없음")
            // 경유 서버가 vpn 인데 묶을 utun 이 없다
            XCTAssertFalse(snapshot("t", .off(latencyMs: 1)).canWake(target, via: server("via", .vpn, vpn: "MacBook"), idle: true))
            XCTAssertTrue(snapshot("t", .off(latencyMs: 1), vpnDevice: "utun7").canWake(target, via: server("via", .vpn, vpn: "MacBook"), idle: true))
        }
    }

    // MARK: 망 켜기·끄기 (사이드바 NETWORK 행 · 망 화면 · 메뉴 막대의 네트워크 메뉴)

    func testNetworkToggleTable() {
        // 옮기기 전 조건: `status.tailscale != .missing && busyAction == nil` (세 곳이 같은 식)
        let tailscaleRows: [(TailscaleState, idle: Bool, expected: Bool)] = [
            (.running, true, true), (.stopped("Stopped"), true, true),
            (.unknown, true, true),            // 확인 전 (앱을 켠 직후) — 막지 않는다
            (.missing, true, false),           // 이 Mac 에 Tailscale 이 없다
            // 다른 관리자 작업 중이면 무엇이든 막는다
            (.running, false, false), (.stopped("Stopped"), false, false), (.unknown, false, false), (.missing, false, false),
        ]
        for (state, idle, expected) in tailscaleRows {
            var snap = StatusSnapshot()
            snap.tailscale = state
            XCTAssertEqual(snap.canToggleTailscale(idle: idle), expected, "Tailscale \(state) · idle \(idle)")
        }
        // 옮기기 전 조건: `status.lan != .missing && busyAction == nil`
        let lanRows: [(LanState, idle: Bool, expected: Bool)] = [
            (.up, true, true), (.down, true, true),
            (.none, true, true),               // 내부망 설정 없음 (첫 lan 서버 전) — 행·메뉴가 보이지 않아 쓰이지 않지만 막지는 않는다
            (.missing, true, false),           // 지정한 서비스가 이 Mac 에 없다
            (.up, false, false), (.down, false, false), (.none, false, false), (.missing, false, false),
        ]
        for (state, idle, expected) in lanRows {
            var snap = StatusSnapshot()
            snap.lan = state
            XCTAssertEqual(snap.canToggleLan(idle: idle), expected, "Intranet \(state) · idle \(idle)")
        }
        // 서로의 상태는 보지 않는다
        var snap = StatusSnapshot()
        snap.tailscale = .missing
        XCTAssertTrue(snap.canToggleLan(idle: true), "Tailscale 이 없어도 Intranet 은 켤 수 있다")
        snap.tailscale = .running
        snap.lan = .missing
        XCTAssertTrue(snap.canToggleTailscale(idle: true), "Intranet 서비스가 없어도 Tailscale 은 켤 수 있다")
    }

    // MARK: 진단 카드의 Run · Scan · Capture

    private let allTasks: [DiagnosticTask] = [.ping, .trace, .locate, .http, .tcp, .dns, .arp]

    private func others(than busy: Set<DiagnosticTask>) -> Set<DiagnosticTask> {
        Set(allTasks).subtracting(busy)
    }

    func testDiagnosticRunWithoutDeviceTable() {
        // 장치 없음 (그 화면의 망이 연결 안 됨 · 첫 VPN 의 상세를 아직 못 읽음): 입력이 맞아도 모두 꺼진다
        XCTAssertFalse(DiagnosticRun.canCapture(device: nil))
        XCTAssertFalse(DiagnosticRun.canPing("192.168.0.1", device: nil, running: []))
        XCTAssertFalse(DiagnosticRun.canHTTP("example.com", device: nil, running: []))
        XCTAssertFalse(DiagnosticRun.canTCP("192.168.112.11:22", device: nil, running: []))
        XCTAssertFalse(DiagnosticRun.canDNS("www.example.com", device: nil, server: "1.1.1.1", running: []))
        XCTAssertFalse(DiagnosticRun.canScanArp(device: nil, running: []))
        XCTAssertTrue(DiagnosticRun.canCapture(device: "en0"))
    }

    func testDiagnosticPingTable() {
        // 옮기기 전: `device != nil && PingTest.target(입력) != nil && !running && !tracing && !locating`
        let rows: [(String, Set<DiagnosticTask>, Bool)] = [
            ("192.168.0.1", [], true), ("www.example.com", [], true), ("  10.0.0.1 ", [], true),
            ("", [], false),                   // 빈 입력 (카드를 처음 연 상태)
            ("a b;rm", [], false), ("-c1", [], false),
            ("192.168.0.1", [.ping], false), ("192.168.0.1", [.trace], false), ("192.168.0.1", [.locate], false),
            ("192.168.0.1", others(than: [.ping, .trace, .locate]), true),   // 다른 도구가 돌아도 켜진다
        ]
        for (input, running, expected) in rows {
            XCTAssertEqual(DiagnosticRun.canPing(input, device: "en0", running: running), expected, "ping '\(input)' · \(running)")
        }
    }

    func testDiagnosticHTTPTable() {
        // 옮기기 전: `device != nil && HTTPTest.url(입력) != nil && !http 실행 중`
        let rows: [(String, Set<DiagnosticTask>, Bool)] = [
            ("example.com", [], true), ("https://example.com/a", [], true),
            ("", [], false), ("ftp://example.com", [], false), ("http://user:pw@example.com", [], false),
            ("example.com", [.http], false),
            ("example.com", others(than: [.http]), true),
        ]
        for (input, running, expected) in rows {
            XCTAssertEqual(DiagnosticRun.canHTTP(input, device: "en0", running: running), expected, "HTTP '\(input)' · \(running)")
        }
    }

    func testDiagnosticTCPTable() {
        // 옮기기 전: `device != nil && TCPPortTest.target(입력) != nil && !tcp 실행 중`
        let rows: [(String, Set<DiagnosticTask>, Bool)] = [
            ("192.168.112.11:22", [], true), ("192.168.112.11 22", [], true),
            ("", [], false), ("192.168.112.11", [], false), ("server:22", [], false), ("192.168.112.11:0", [], false),
            ("192.168.112.11:22", [.tcp], false),
            ("192.168.112.11:22", others(than: [.tcp]), true),
        ]
        for (input, running, expected) in rows {
            XCTAssertEqual(DiagnosticRun.canTCP(input, device: "en0", running: running), expected, "TCP '\(input)' · \(running)")
        }
    }

    func testDiagnosticDNSTable() {
        // 옮기기 전: `device != nil && server != nil && DNSLookup.name(입력) != nil && !dns 실행 중`
        let rows: [(String, String?, Set<DiagnosticTask>, Bool)] = [
            ("www.example.com", "1.1.1.1", [], true),
            ("www.example.com", nil, [], false),   // 물을 DNS 서버가 없다 (그 장치의 scoped DNS 없음 · VPN 상세 전)
            ("", "1.1.1.1", [], false), ("-x", "1.1.1.1", [], false), ("a b", "1.1.1.1", [], false),
            ("www.example.com", "1.1.1.1", [.dns], false),
            ("www.example.com", "1.1.1.1", others(than: [.dns]), true),
        ]
        for (input, server, running, expected) in rows {
            XCTAssertEqual(DiagnosticRun.canDNS(input, device: "en0", server: server, running: running), expected,
                           "DNS '\(input)' @\(server ?? "없음") · \(running)")
        }
    }

    func testDiagnosticArpTable() {
        // 옮기기 전: `.disabled(device == nil || running)`
        XCTAssertTrue(DiagnosticRun.canScanArp(device: "en0", running: []))
        XCTAssertFalse(DiagnosticRun.canScanArp(device: "en0", running: [.arp]))
        XCTAssertTrue(DiagnosticRun.canScanArp(device: "en0", running: others(than: [.arp])))
    }

    // MARK: 원격 정보 카드

    func testRemoteInfoTabSwitchTable() {
        // 옮기기 전: `.disabled(!reachable && entry.fetchedAt == nil && tab != .live)`
        let at = Date(timeIntervalSince1970: 1_000)
        let rows: [(reachable: Bool, current: RemoteCommands.Query, fetchedAt: Date?, expected: Bool)] = [
            (true, .spec, nil, true),          // 막 추가한 서버 (확인 전 = 닿는 것으로 본다) · 아직 아무것도 안 가져옴
            (true, .spec, at, true),
            (false, .spec, at, true),          // 꺼져도 가져온 결과가 있으면 옮길 수 있다
            (false, .spec, nil, false),        // 꺼졌고 이 탭도 비었다
            (false, .services, nil, false),
            (false, .live, nil, true),         // 실시간 탭엔 fetchedAt 이 없다 — 꺼져도 다른 탭으로
            (true, .live, nil, true),
        ]
        for row in rows {
            XCTAssertEqual(RemoteInfoTabs.canSwitch(reachable: row.reachable, current: row.current, currentFetchedAt: row.fetchedAt), row.expected,
                           "reachable \(row.reachable) · \(row.current) · fetched \(row.fetchedAt != nil)")
        }
    }

    func testRemoteInfoFetchOnSelectTable() {
        // 옮기기 전 (Binding setter): `if 탭 != .live, info(server, 탭).fetchedAt == nil { fetchInfo(…, allowPrompt: false) }`
        let at = Date(timeIntervalSince1970: 1_000)
        let rows: [(RemoteCommands.Query, Date?, Bool)] = [
            (.spec, nil, true),                // 처음 고른 탭
            (.ports, nil, true),
            (.spec, at, false),                // 이미 가져왔다 — 새로고침(↻)으로
            (.live, nil, false),               // 실시간은 수집기가 읽는다
        ]
        for (tab, fetchedAt, expected) in rows {
            XCTAssertEqual(RemoteInfoTabs.fetchesOnSelect(tab, fetchedAt: fetchedAt), expected, "\(tab) · fetched \(fetchedAt != nil)")
        }
    }

    // MARK: 서버 추가·편집 창의 Ping · 포트 확인

    func testFormSendTable() {
        // 망 × 묶을 장치 → 보낼 수 있는가. lan·vpn 은 장치가 있어야 한다 (없이 보내면 기본 경로로 나가 그 망이 아닌 곳에 묻는다).
        let rows: [(ServerNetwork, String?, Bool)] = [
            (.direct, nil, true), (.tailscale, nil, true),
            (.lan, "en9", true),
            (.lan, nil, false),       // 내부망 서비스가 없거나(첫 lan 서버인데 아직 안 고름) 어댑터가 없다
            (.vpn, "utun7", true),
            (.vpn, nil, false),       // VPN 꺼짐·목록에 없는 이름
        ]
        for (network, device, expected) in rows {
            XCTAssertEqual(ServerFormCheck.canSend(network: network, device: device), expected, "\(network) · \(device ?? "장치 없음")")
            XCTAssertEqual(ServerFormCheck.canPing(ip: "192.168.8.1", network: network, device: device, checking: false), expected)
            XCTAssertEqual(ServerFormCheck.canProbePort(ip: "192.168.8.1", port: 22, network: network, device: device, checking: false), expected)
            // 보낼 수 있는 망이어도 입력이 비었거나 확인 중이면 꺼진다
            XCTAssertFalse(ServerFormCheck.canPing(ip: "", network: network, device: device, checking: false))
            XCTAssertFalse(ServerFormCheck.canPing(ip: "a b;rm", network: network, device: device, checking: false), "ping 에 넘길 수 없는 글자")
            XCTAssertFalse(ServerFormCheck.canPing(ip: "192.168.8.1", network: network, device: device, checking: true))
            XCTAssertFalse(ServerFormCheck.canProbePort(ip: "", port: 22, network: network, device: device, checking: false))
            XCTAssertFalse(ServerFormCheck.canProbePort(ip: "192.168.8.1", port: nil, network: network, device: device, checking: false))
            XCTAssertFalse(ServerFormCheck.canProbePort(ip: "192.168.8.1", port: 22, network: network, device: device, checking: true))
        }
    }

    // MARK: "안 읽기" 조건의 쓰는 쪽

    /// 목록에 vpn 서버가 없으면 상태 확인은 VPN 을 읽지 않는다 (VPNNetworkTests.testNoVPNServersSkipsScutil).
    /// 그 스냅숏을 쓰는 곳마다, 건너뛴 상태에서 어떻게 되는지 적는다.
    /// 2026-11-09: 첫 vpn 서버를 추가하는 창이 스냅숏만 봐서 VPN 이 켜져 있어도 Ping·포트 확인이 꺼져 있었다.
    func testConsumersWhenVPNReadIsSkipped() async throws {
        let runner = FakeRunner()
        let list = try fixtureText("scutil-nc-list")
        runner.scripted["scutil --nc list"] = CommandResult(exitCode: 0, stdout: list)
        runner.scripted["scutil --nc status \(wireguardID)"] = CommandResult(exitCode: 0, stdout: try fixtureText("scutil-nc-status-connected"))
        let noVPNServers = try ServerConfigParser.parse(fixture)
        let snap = await StatusMonitor(config: noVPNServers, runner: runner, tcpProbe: runner.tcpProbe).refresh(previous: StatusSnapshot())
        XCTAssertTrue(snap.vpnLinks.isEmpty, "전제: vpn 서버가 없으면 스냅숏에 VPN 이 없다")

        // 쓰는 곳 1 — 서버 추가 창: 스냅숏에 없으면 직접 읽어 켜져 있는 VPN 으로 보낼 수 있다
        for name in ["MacBook", nil] {
            let device = await ServerFormCheck.bindDevice(network: .vpn, vpn: name, snapshot: snap, runner: runner)
            XCTAssertEqual(device, "utun7", name ?? "연결된 첫 VPN")
            XCTAssertTrue(ServerFormCheck.canPing(ip: "192.168.8.102", network: .vpn, device: device, checking: false))
            XCTAssertTrue(ServerFormCheck.canProbePort(ip: "192.168.8.102", port: 22, network: .vpn, device: device, checking: false))
        }
        let unknown = await ServerFormCheck.bindDevice(network: .vpn, vpn: "Office", snapshot: snap, runner: runner)
        XCTAssertNil(unknown, "목록에 없는 이름은 여전히 막는다")
        // vpn 이 아닌 망은 VPN 을 읽으러 가지 않는다
        let before = runner.calls.count
        let direct = await ServerFormCheck.bindDevice(network: .direct, vpn: nil, snapshot: snap, runner: runner)
        XCTAssertNil(direct)
        XCTAssertEqual(runner.calls.count, before)

        // 쓰는 곳 2 — 막 추가한 vpn 서버: 다음 라운드 전엔 묶을 장치를 몰라 연결을 막는다 (새지 않게)
        let added = server("home9", .vpn, vpn: "MacBook")
        XCTAssertFalse(snap.allowsConnection(to: added))

        // 다음 라운드: 목록에 vpn 서버가 생겨 읽는다 → 연결 허용, 창은 스냅숏 값을 쓴다 (다시 읽지 않음)
        let withVPN = try ServerConfigParser.parse(fixture + "\n[home9]\ngroup=ext\nnetwork=vpn\nvpn=MacBook\ntype=linux\nip=192.168.8.10\nuser=tester\nport=22\n")
        let next = await StatusMonitor(config: withVPN, runner: runner, tcpProbe: runner.tcpProbe).refresh(previous: snap)
        XCTAssertTrue(next.allowsConnection(to: try XCTUnwrap(withVPN.server("home9"))))
        let calls = runner.calls.count
        let fromSnapshot = await ServerFormCheck.bindDevice(network: .vpn, vpn: "MacBook", snapshot: next, runner: runner)
        XCTAssertEqual(fromSnapshot, "utun7")
        XCTAssertEqual(runner.calls.count, calls, "스냅숏에 있으면 명령을 더 부르지 않는다")

        // VPN 이 꺼져 있으면 창도 막는다
        runner.scripted["scutil --nc list"] = CommandResult(exitCode: 0, stdout: list.replacingOccurrences(of: "(Connected)      \(wireguardID)", with: "(Disconnected)   \(wireguardID)"))
        let off = await ServerFormCheck.bindDevice(network: .vpn, vpn: "MacBook", snapshot: snap, runner: runner)
        XCTAssertNil(off)
        XCTAssertFalse(ServerFormCheck.canPing(ip: "192.168.8.102", network: .vpn, device: off, checking: false))
    }

    /// 내부망 설정([network:lan])이 없으면 스냅숏에 내부망 장치가 없다 — 첫 lan 서버를 추가하는 창은 고른 서비스의 장치에 묶는다.
    /// 2026-11-09: 묶지 않고 기본 경로로 보내 내부망이 아닌 쪽에 묻고 있었다.
    func testConsumersWhenLanIsNotConfigured() async throws {
        let runner = FakeRunner()
        let noLan = try ServerConfigParser.parse("[a]\ngroup=g\nnetwork=direct\ntype=linux\nip=1.1.1.1\nuser=u\nport=22\n")
        XCTAssertNil(noLan.lan, "전제: 내부망 설정 없음")
        let snap = await StatusMonitor(config: noLan, runner: runner, tcpProbe: runner.tcpProbe).refresh(previous: StatusSnapshot())
        XCTAssertNil(snap.lanDevice, "전제: 스냅숏에 내부망 장치가 없다")

        // 서비스를 아직 안 골랐으면 보내지 않는다
        let unchosen = await ServerFormCheck.bindDevice(network: .lan, vpn: nil, lanServiceDevice: nil, snapshot: snap, runner: runner)
        XCTAssertNil(unchosen)
        XCTAssertFalse(ServerFormCheck.canPing(ip: "192.0.2.22", network: .lan, device: unchosen, checking: false))
        XCTAssertFalse(ServerFormCheck.canProbePort(ip: "192.0.2.22", port: 22, network: .lan, device: unchosen, checking: false))
        // 고른 서비스의 장치에 묶는다 (장치 없는 서비스 = 어댑터가 빠져 있음 → 보내지 않는다)
        let chosen = await ServerFormCheck.bindDevice(network: .lan, vpn: nil, lanServiceDevice: "en10", snapshot: snap, runner: runner)
        XCTAssertEqual(chosen, "en10")
        XCTAssertTrue(ServerFormCheck.canPing(ip: "192.0.2.22", network: .lan, device: chosen, checking: false))
        let noAdapter = await ServerFormCheck.bindDevice(network: .lan, vpn: nil, lanServiceDevice: "", snapshot: snap, runner: runner)
        XCTAssertNil(noAdapter)

        // 내부망 설정이 있으면 그 장치가 우선 (창에서 서비스를 고르지 않는다)
        let configured = await StatusMonitor(config: try ServerConfigParser.parse(fixture), runner: runner, tcpProbe: runner.tcpProbe).refresh(previous: StatusSnapshot())
        XCTAssertEqual(configured.lanDevice, "en9")
        let fromSnapshot = await ServerFormCheck.bindDevice(network: .lan, vpn: nil, lanServiceDevice: "en10", snapshot: configured, runner: runner)
        XCTAssertEqual(fromSnapshot, "en9")
        // 고른 서비스는 lan 에만 쓴다
        let direct = await ServerFormCheck.bindDevice(network: .direct, vpn: nil, lanServiceDevice: "en10", snapshot: snap, runner: runner)
        XCTAssertNil(direct)
    }

    // MARK: 화면에 조건을 다시 적지 않게

    /// 화면(Views)이 판정 재료를 직접 조합하면 여기 표가 그 조건을 덮지 못한다.
    func testViewsDoNotComposeNetworkConditions() throws {
        let views = TestPaths.appDir.appendingPathComponent("Sources/ServersApp/Views")
        // 망 켜기·끄기·진단 입력 꼴·공유 연결 유무는 ActionAvailability·AppModel 메서드로 옮겼다 (2026-11-10)
        let banned = ["status.bindInterface(", "lacksVPNBind", "blocksSSH",
                      "tailscale != .missing", "tailscale == .missing", "lan != .missing", "lan == .missing", "lanToggleAvailable",
                      "PingTest.target(", "HTTPTest.url(", "TCPPortTest.target(", "DNSLookup.name(",
                      "SharedConnection.activeAccounts("]
        // 화면은 모델 속성에 직접 쓰지 않는다 — 탭 고르기·시트 닫기·선택 모두 AppModel 메서드로 (조회 판단까지 화면에 적지 않게)
        let bannedWrites = try NSRegularExpression(pattern: #"\bmodel\.\w+(\[[^\]]*\])?\s*=[^=]"#)
        var hits: [String] = []
        for file in try FileManager.default.contentsOfDirectory(at: views, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                let text = String(line)
                let write = bannedWrites.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
                if write || banned.contains(where: { text.contains($0) }) { hits.append("\(file.lastPathComponent):\(index + 1)") }
            }
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: views.path).isEmpty, "Views 폴더를 찾지 못함: \(views.path)")
        XCTAssertTrue(hits.isEmpty, """
            문제: 화면이 망·접속 판정 재료를 직접 쓴다 — \(hits.joined(separator: ", "))
            해결: 조건을 ServersCore 의 ActionAvailability(StatusSnapshot.allowsConnection·canToggleLan·ServerFormCheck·DiagnosticRun 등)로 옮기고 이 파일의 상태 표에 줄을 더한다
            참조: app/Sources/ServersCore/ActionAvailability.swift · AGENTS.md 코드 규칙
            """)
    }
}
