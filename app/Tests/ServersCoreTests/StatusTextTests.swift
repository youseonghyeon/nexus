// 상태 → (단계, 문구) 표 (StatusText). 기댓값은 뷰에 있던 분기(StatusDisplay·ServerInfoView, 2026-11-10)를 한 줄씩 옮겨 적은 것.
// 빈 상태(설정 없음·인터페이스 없음·어댑터 없음·확인 전)를 꼭 넣는다.

import Foundation
@testable import ServersCore
import XCTest

final class StatusTextTests: XCTestCase {
    private func server(_ network: ServerNetwork, key: String = "s", type: ServerType = .linux,
                        check: CheckMethod = .ssh, vpn: String? = nil) -> Server {
        Server.sample(key: key, network: network, type: type, ip: "192.168.8.10", check: check, vpn: vpn)
    }

    // MARK: Tailscale

    func testTailscaleTable() {
        let rows: [(TailscaleState, StatusLevel, String)] = [
            (.running, .good, "연결됨"),
            (.stopped("Stopped"), .bad, "꺼짐 (Stopped)"),
            (.stopped("NeedsLogin"), .bad, "꺼짐 (NeedsLogin)"),
            (.missing, .bad, "tailscale 명령 없음"),
            (.unknown, .warn, "상태 확인 실패"),
        ]
        for (state, level, text) in rows {
            XCTAssertEqual(StatusText.tailscaleLevel(state), level, "\(state)")
            XCTAssertEqual(StatusText.tailscaleDetail(state), text, "\(state)")
        }
    }

    // MARK: Intranet

    func testLanTable() {
        let connected = ServiceLink.connected(ip: "10.50.10.17")
        // (상태, 서비스 이름, 링크, 어댑터 있음) → (단계, 문구)
        let rows: [(LanState, String?, ServiceLink?, Bool, StatusLevel, String)] = [
            // 설정 없음 (빈 상태)
            (.none, nil, nil, true, .muted, "설정 없음"),
            (.none, nil, nil, false, .muted, "설정 없음"),
            // 켜짐: 링크 판정이 있으면 그것만
            (.up, "Acme Intranet", connected, true, .good, "Acme Intranet · 연결됨 · 10.50.10.17"),
            (.up, "Acme Intranet", connected, false, .good, "Acme Intranet · 연결됨 · 10.50.10.17"),
            (.up, "Acme Intranet", .noAddress, true, .warn, "Acme Intranet · 활성 · 주소 없음"),
            (.up, "Acme Intranet", .noGateway(ip: "10.50.10.17"), true, .warn, "Acme Intranet · 활성 · 게이트웨이 응답 없음"),
            (.up, "Acme Intranet", .noAdapter, false, .warn, "Acme Intranet · 활성 · 어댑터 없음"),
            // 켜짐: 링크를 못 읽었으면 어댑터 유무로
            (.up, "Acme Intranet", nil, true, .good, "Acme Intranet · 활성"),
            (.up, "Acme Intranet", nil, false, .warn, "Acme Intranet · 활성 · 어댑터 없음"),
            (.up, nil, nil, true, .good, "활성"),
            // 꺼짐은 평소 상태 — 회색
            (.down, "Acme Intranet", .disabled, true, .muted, "Acme Intranet · 비활성"),
            (.down, "Acme Intranet", nil, false, .muted, "Acme Intranet · 비활성 · 어댑터 없음"),
            (.down, nil, nil, true, .muted, "비활성"),
            // 서비스가 목록에 없음
            (.missing, "Acme Intranet", nil, true, .bad, "Acme Intranet · 서비스 없음"),
            (.missing, nil, nil, true, .bad, "서비스 없음"),
        ]
        for (state, service, link, adapter, level, text) in rows {
            let name = "\(state) · \(service ?? "nil") · \(link.map(\.text) ?? "nil") · adapter \(adapter)"
            XCTAssertEqual(StatusText.lanLevel(state, link: link, adapterPresent: adapter), level, name)
            XCTAssertEqual(StatusText.lanDetail(state, service: service, link: link, adapterPresent: adapter), text, name)
        }
    }

    // MARK: Wi-Fi

    func testWiFiTable() {
        typealias W = StatusText.WiFi
        // (값, 위치 권한) → (단계, 문구)
        let rows: [(W?, Bool, StatusLevel, String)] = [
            (nil, true, .muted, "인터페이스 없음"),   // 빈 상태: Wi-Fi 인터페이스 없음
            (nil, false, .muted, "인터페이스 없음"),
            (W(powerOn: false, associated: false, ssid: nil), true, .bad, "꺼짐"),
            (W(powerOn: true, associated: false, ssid: nil), true, .warn, "연결 안 됨"),
            (W(powerOn: true, associated: true, ssid: "office-5G"), true, .good, "office-5G"),
            (W(powerOn: true, associated: true, ssid: "office-5G"), false, .good, "office-5G"),
            (W(powerOn: true, associated: true, ssid: nil), true, .good, "연결됨"),
            (W(powerOn: true, associated: true, ssid: nil), false, .good, "연결됨 · 이름은 위치 권한 필요"),
        ]
        for (info, authorized, level, text) in rows {
            let name = "\(String(describing: info)) · 권한 \(authorized)"
            XCTAssertEqual(StatusText.wifiLevel(info), level, name)
            XCTAssertEqual(StatusText.wifiDetail(info, locationAuthorized: authorized), text, name)
        }
    }

    // MARK: Ethernet

    func testEthernetTable() {
        let up = InterfaceState(ipv4: "192.168.0.201", media: "1000baseT <full-duplex>", active: true)
        let connected = EthernetAdapter(service: "Samsung Hub NIC", hardwarePort: "AX88179B", device: "en8", interface: up)
        let noAddress = EthernetAdapter(service: "Samsung Hub NIC", hardwarePort: "AX88179B", device: "en8",
                                        interface: InterfaceState(active: true))
        let noGateway = EthernetAdapter(service: "iptime Hub NIC", hardwarePort: nil, device: "en10", interface: up, gatewayPresent: false)
        let noLink = EthernetAdapter(service: "Samsung Hub NIC", hardwarePort: "AX88179B", device: "en8", interface: InterfaceState())
        // (읽음, 대표) → (단계, 문구)
        let rows: [(String, Bool, EthernetAdapter?, StatusLevel, String)] = [
            ("아직 안 읽음", false, nil, .muted, "확인 중…"),
            ("어댑터 없음", true, nil, .muted, "연결 안 됨"),   // 빈 상태: 꽂힌 유선 어댑터가 없다
            ("연결됨", true, connected, .good, "Samsung Hub NIC · en8"),
            ("주소 없음", true, noAddress, .warn, "Samsung Hub NIC · en8 · 주소 없음"),
            ("게이트웨이 응답 없음", true, noGateway, .warn, "iptime Hub NIC · en10 · 게이트웨이 응답 없음"),
            ("링크 없음", true, noLink, .muted, "연결 안 됨"),
        ]
        for (name, loaded, primary, level, text) in rows {
            XCTAssertEqual(StatusText.ethernetLevel(primary), level, name)
            XCTAssertEqual(StatusText.ethernetDetail(loaded: loaded, primary: primary), text, name)
        }
    }

    // MARK: 서버 — 점·툴팁·머리글

    func testRemoteLevelAndHelpTable() {
        // (상태) → (단계, ssh 툴팁, tcp 툴팁, windows ssh 툴팁, 머리글)
        let rows: [(RemoteState, StatusLevel, String, String, String, String)] = [
            (.pending, .warn, "확인 중", "확인 중", "확인 중", "확인 중"),   // 빈 상태: 확인 전
            (.ok(latencyMs: 3), .good, "SSH 로그인 확인됨 · 3ms", "포트 확인됨 · 3ms", "SSH 로그인 확인됨 · 3ms", "접속 가능"),
            (.fail(latencyMs: 120), .bad, "SSH 로그인 실패 · 120ms", "포트 실패 · 120ms", "SSH 로그인 실패 · 120ms", "접속 불가"),
            (.off(latencyMs: 8000), .muted, "SSH 로그인·ping 응답 없음 · 꺼짐", "포트·ping 응답 없음 · 꺼짐", "SSH 로그인 응답 없음 · 꺼짐", "꺼짐"),
            (.needsAuth(url: nil), .warn, "Tailscale 인증 필요", "Tailscale 인증 필요", "Tailscale 인증 필요", "Tailscale 인증 필요"),
            (.needsAuth(url: "https://login.tailscale.com/a/x"), .warn, "Tailscale 인증 필요", "Tailscale 인증 필요", "Tailscale 인증 필요", "Tailscale 인증 필요"),
            (.skip(reason: "peer offline"), .muted, "확인 안 함 · Peer offline", "확인 안 함 · Peer offline", "확인 안 함 · Peer offline", "Peer offline"),
        ]
        for (state, level, ssh, tcp, windows, conclusion) in rows {
            XCTAssertEqual(StatusText.remoteLevel(state), level, "\(state)")
            XCTAssertEqual(StatusText.remoteHelp(state, check: .ssh, type: .linux, lanName: "Intranet"), ssh, "\(state) · ssh")
            XCTAssertEqual(StatusText.remoteHelp(state, check: .tcp, type: .linux, lanName: "Intranet"), tcp, "\(state) · tcp")
            XCTAssertEqual(StatusText.remoteHelp(state, check: .ssh, type: .windows, lanName: "Intranet"), windows, "\(state) · windows")
            XCTAssertEqual(StatusText.conclusion(state, lanName: "Intranet"), conclusion, "\(state) · 머리글")
        }
        // windows + tcp 꺼짐: ping 을 보내지 않으므로 ping 없이
        XCTAssertEqual(StatusText.remoteHelp(.off(latencyMs: 1), check: .tcp, type: .windows, lanName: "Intranet"), "포트 응답 없음 · 꺼짐")
    }

    /// skip 이유 문구. 머리글·툴팁(remoteHelp)·망 화면 서버 목록이 모두 이 표를 쓴다 (2026-11-10 통일).
    func testSkipReasonTextTable() {
        let rows: [(StatusMonitor.SkipReason, String)] = [
            (.tailscaleDown, "Tailscale 꺼짐"),
            (.noTailscale, "tailscale 명령 없음"),
            (.tailscaleUnknown, "Tailscale 상태 확인 실패"),
            (.peerOffline, "Peer offline"),
            (.peerMissing, "피어 없음"),
            (.lanDown, "Intranet down"),
            (.lanMissing, "Intranet missing"),
            (.vpnDown, "VPN down"),
            (.vpnMissing, "VPN missing"),
        ]
        XCTAssertEqual(rows.count, StatusMonitor.SkipReason.allCases.count, "이유마다 한 줄")
        for (reason, text) in rows {
            XCTAssertEqual(StatusText.skipReasonText(reason.rawValue, lanName: "Intranet"), text, reason.rawValue)
            XCTAssertEqual(StatusText.conclusion(.skip(reason: reason.rawValue), lanName: "Intranet"), text, reason.rawValue)
        }
        // 내부망 이름은 받은 값 그대로
        XCTAssertEqual(StatusText.skipReasonText("lan down", lanName: "LAN"), "LAN down")
        // 모르는 이유(빈 문자열 포함)는 그대로
        XCTAssertEqual(StatusText.skipReasonText("no nc", lanName: "Intranet"), "no nc")
        XCTAssertEqual(StatusText.skipReasonText("", lanName: "Intranet"), "")
    }

    // MARK: 상태 파이프라인

    private typealias Step = StatusText.PipelineStep

    private func steps(_ server: Server, _ configure: (inout StatusSnapshot) -> Void = { _ in }) -> [Step] {
        var snap = StatusSnapshot()
        configure(&snap)
        return StatusText.pipeline(server, in: snap, lanName: "Intranet")
    }

    func testPipelineEmptySnapshot() {
        // 앱을 켠 직후 (스냅숏 기본값): tailscale unknown · 피어 미확인 · 내부망 none · VPN 목록 없음 · 확인 전
        let pending = Step(label: "SSH", value: "…", level: .warn)
        XCTAssertEqual(steps(server(.tailscale)), [Step(label: "Tailscale", value: "?", level: .warn),
                                                   Step(label: "Peer", value: "–", level: .muted), pending])
        XCTAssertEqual(steps(server(.lan)), [Step(label: "Intranet", value: "not set", level: .muted), pending])
        XCTAssertEqual(steps(server(.vpn)), [Step(label: "VPN", value: "missing", level: .bad), pending])
        XCTAssertEqual(steps(server(.direct)), [pending], "direct 는 망 단계 없이 SSH 만")
    }

    func testPipelineNetworkStepTable() {
        let tailscale: [(TailscaleState, Step)] = [
            (.running, Step(label: "Tailscale", value: "up", level: .good)),
            (.stopped("Stopped"), Step(label: "Tailscale", value: "down (Stopped)", level: .bad)),
            (.missing, Step(label: "Tailscale", value: "missing", level: .bad)),
            (.unknown, Step(label: "Tailscale", value: "?", level: .warn)),
        ]
        for (state, step) in tailscale {
            XCTAssertEqual(steps(server(.tailscale)) { $0.tailscale = state }.first, step, "\(state)")
        }
        let peers: [(PeerState, Step)] = [
            (.online, Step(label: "Peer", value: "online", level: .good)),
            (.offline, Step(label: "Peer", value: "offline", level: .bad)),
            (.missing, Step(label: "Peer", value: "missing", level: .warn)),
            (.unchecked, Step(label: "Peer", value: "–", level: .muted)),
        ]
        for (peer, step) in peers {
            let out = steps(server(.tailscale, key: "nexus")) { $0.tailscale = .running; $0.peers["nexus"] = peer }
            XCTAssertEqual(out.count, 3)
            XCTAssertEqual(out[1], step, "\(peer)")
        }
        let lan: [(LanState, Bool, Step)] = [
            (.up, true, Step(label: "Intranet", value: "up", level: .good)),
            (.up, false, Step(label: "Intranet", value: "up · no adapter", level: .warn)),
            (.down, true, Step(label: "Intranet", value: "down", level: .bad)),
            (.down, false, Step(label: "Intranet", value: "down", level: .bad)),
            (.missing, true, Step(label: "Intranet", value: "missing", level: .bad)),
            (.none, true, Step(label: "Intranet", value: "not set", level: .muted)),
        ]
        for (state, adapter, step) in lan {
            XCTAssertEqual(steps(server(.lan)) { $0.lan = state; $0.lanAdapterPresent = adapter }.first, step, "\(state) · adapter \(adapter)")
        }
        // vpn: 라벨은 vpn= 이름(없으면 "VPN")
        let links = [VPNLink(name: "Office", device: nil), VPNLink(name: "Home", device: "utun7")]
        let vpn: [(String?, [VPNLink], Step)] = [
            ("Home", links, Step(label: "Home", value: "up · utun7", level: .good)),
            ("Office", links, Step(label: "Office", value: "down", level: .bad)),
            ("Gone", links, Step(label: "Gone", value: "missing", level: .bad)),
            ("Home", [], Step(label: "Home", value: "missing", level: .bad)),
            (nil, links, Step(label: "VPN", value: "up · utun7", level: .good)),   // 이름 없으면 연결된 첫 VPN
            (nil, [VPNLink(name: "Office", device: nil)], Step(label: "VPN", value: "down", level: .bad)),
            (nil, [], Step(label: "VPN", value: "missing", level: .bad)),
        ]
        for (name, list, step) in vpn {
            XCTAssertEqual(steps(server(.vpn, vpn: name)) { $0.vpnLinks = list }.first, step, "\(name ?? "nil") · \(list.count)")
        }
    }

    func testPipelineSSHStepTable() {
        // 마지막 단계는 망과 무관하게 라벨 SSH (check=tcp 도)
        // SSH 가 되면 SSH 하나, 안 될 때만 그 앞에 ping (응답 = 켜져 있음 · 없음 = 꺼짐)
        let rows: [(RemoteState, [Step])] = [
            (.pending, [Step(label: "SSH", value: "…", level: .warn)]),
            (.ok(latencyMs: 3), [Step(label: "SSH", value: "up 3ms", level: .good)]),
            (.fail(latencyMs: 120), [Step(label: "ping", value: "up", level: .good), Step(label: "SSH", value: "fail 120ms", level: .bad)]),
            (.off(latencyMs: 8000), [Step(label: "ping", value: "down", level: .muted), Step(label: "SSH", value: "down", level: .muted)]),
            (.needsAuth(url: nil), [Step(label: "SSH", value: "auth required", level: .warn)]),
            (.skip(reason: "lan down"), [Step(label: "SSH", value: "skip", level: .muted)]),
        ]
        for (state, expected) in rows {
            for check in [CheckMethod.ssh, .tcp] {
                XCTAssertEqual(steps(server(.direct, key: "was", check: check)) { $0.remote["was"] = state }, expected, "\(state) · \(check)")
            }
        }
        // Windows 는 ping 을 보내지 않는다 — 꺼짐이어도 SSH 하나
        XCTAssertEqual(steps(server(.direct, key: "win", type: .windows)) { $0.remote["win"] = .off(latencyMs: 3000) },
                       [Step(label: "SSH", value: "down", level: .muted)])
        // 망 단계가 있으면 망 → ping → SSH, 망이 꺼져 있으면 확인하지 않으므로 ping 없이 망 → SSH skip
        XCTAssertEqual(steps(server(.lan, key: "was")) { $0.lan = .up; $0.remote["was"] = .fail(latencyMs: 9) }.map(\.label), ["Intranet", "ping", "SSH"])
        XCTAssertEqual(steps(server(.lan, key: "was")) { $0.lan = .down; $0.remote["was"] = .skip(reason: "lan down") }.map(\.label), ["Intranet", "SSH"])
    }

    // MARK: 터널

    func testTunnelDetailTable() {
        let rows: [(TunnelState, String)] = [
            (.idle, "3001 → 3000 · 닫힘"),
            (.connecting, "3001 → 3000 · 연결 중"),
            (.open, "3001 → 3000 · 연결됨"),
            (.closed(exitCode: 255, message: "Warning: x\nbind: Address already in use"), "3001 → 3000 · 끊김 (exit 255) bind: Address already in use"),
            (.closed(exitCode: 1, message: ""), "3001 → 3000 · 끊김 (exit 1) "),   // 메시지 없음: 끝에 빈칸 하나 (옛 문구 그대로)
            (.closed(exitCode: 0, message: "done\n"), "3001 → 3000 · 끊김 (exit 0) done"),
        ]
        for (state, text) in rows {
            XCTAssertEqual(StatusText.tunnelDetail(mapping: "3001 → 3000", state: state), text, "\(state)")
        }
    }
}
