// 화면에서 옮긴 판정 · 문구의 상태 표 (NetworkScreenText · ServerFormText · SheetText).
// 기댓값은 옮기기 전 뷰의 분기(NetworkDashboardView · NetworkParts · WiFiDashboardView · EthernetDashboardView · ServerFormSheet ·
// TunnelSheets · TransferViews · TransferSession, 2026-11-24)를 입력 조합별로 읽어 적은 것 — 화면 글자가 달라지면 여기서 걸린다.
// 빈 상태(설정 없음 · 못 읽음 · 확인 전 · 서버 0대)를 꼭 넣는다.

import Foundation
@testable import ServersCore
import XCTest

final class ScreenTextTests: XCTestCase {
    // MARK: Intranet 화면

    func testLanConclusionTable() {
        // (상태, 링크, 어댑터 있음) → 결론
        let rows: [(LanState, ServiceLink?, Bool, String)] = [
            (.none, nil, true, "설정 없음"),
            (.none, nil, false, "설정 없음"),
            (.missing, nil, true, "서비스 없음"),
            (.down, nil, true, "비활성"),
            (.down, .disabled, false, "비활성"),   // 꺼져 있으면 링크 · 어댑터를 보지 않는다
            (.up, nil, true, "활성"),               // 지정 서비스를 못 읽음 — 어댑터 유무로
            (.up, nil, false, "활성 · 어댑터 없음"),
            (.up, .connected(ip: "192.0.2.17"), true, "연결됨 · 192.0.2.17"),
            (.up, .connected(ip: "192.0.2.17"), false, "연결됨 · 192.0.2.17"),   // 링크 판정이 있으면 그것만
            (.up, .noAdapter, false, "활성 · 어댑터 없음"),
            (.up, .noLink, true, "활성 · 링크 없음"),
            (.up, .noAddress, true, "활성 · 주소 없음"),
            (.up, .noGateway(ip: "192.0.2.17"), true, "활성 · 게이트웨이 응답 없음"),
        ]
        for (state, link, adapter, text) in rows {
            XCTAssertEqual(StatusText.lanConclusion(state, link: link, adapterPresent: adapter), text, "\(state) \(String(describing: link)) \(adapter)")
        }
    }

    func testLanServiceStateTable() {
        let rows: [(LanState, String)] = [(.up, "활성"), (.missing, "서비스 없음"), (.down, "비활성"), (.none, "비활성")]
        for (state, text) in rows { XCTAssertEqual(StatusText.lanServiceState(state), text, "\(state)") }
    }

    private func lanInfo(device: String?, router: String? = nil) -> LanInfo {
        LanInfo(service: "Acme Intranet", enabled: true, device: device, hardwarePort: "USB LAN", configuration: nil,
                configuredIP: nil, subnetMask: nil, router: router, actualIP: nil)
    }

    func testLanInterfaceText() {
        XCTAssertEqual(StatusText.lanInterfaceText(nil, adapterPresent: true), "–")   // 아직 못 읽음
        XCTAssertEqual(StatusText.lanInterfaceText(nil, adapterPresent: false), "–")
        XCTAssertEqual(StatusText.lanInterfaceText(lanInfo(device: nil), adapterPresent: true), "장치 없음")
        XCTAssertEqual(StatusText.lanInterfaceText(lanInfo(device: nil), adapterPresent: false), "장치 없음")
        XCTAssertEqual(StatusText.lanInterfaceText(lanInfo(device: "en10"), adapterPresent: true), "en10")
        XCTAssertEqual(StatusText.lanInterfaceText(lanInfo(device: "en10"), adapterPresent: false), "en10 · 연결 안 됨")
    }

    func testLanGatewayText() {
        let ping = PingSummary(averageMs: 1.25, lossPercent: 0, jitterMs: nil)
        XCTAssertEqual(StatusText.lanGatewayText(router: nil, ping: nil), "–")
        XCTAssertEqual(StatusText.lanGatewayText(router: nil, ping: ping), "–")   // 게이트웨이를 모르면 응답이 있어도 "–"
        XCTAssertEqual(StatusText.lanGatewayText(router: "192.0.2.1", ping: nil), "192.0.2.1")
        XCTAssertEqual(StatusText.lanGatewayText(router: "192.0.2.1", ping: ping), "192.0.2.1 · \(ping.text)")
        XCTAssertEqual(StatusText.lanGatewayText(router: "192.0.2.1", ping: PingSummary.none), "192.0.2.1 · 응답 없음")
    }

    func testLanGatewayIdleCaption() {
        XCTAssertEqual(StatusText.lanGatewayIdleCaption(router: "192.0.2.1", state: .down), "192.0.2.1")
        XCTAssertEqual(StatusText.lanGatewayIdleCaption(router: nil, state: .up), "확인 중…")
        for state in [LanState.down, .missing, .none] {
            XCTAssertEqual(StatusText.lanGatewayIdleCaption(router: nil, state: state), "연결 안 됨", "\(state)")
        }
    }

    // MARK: 망 화면 공통

    func testServerCountLevelTable() {
        // (접속 가능, 전체) → 색
        let rows: [(Int, Int, StatusLevel)] = [
            (0, 0, .muted),   // 이 망의 서버가 없다 (빈 상태)
            (0, 1, .bad), (0, 3, .bad),
            (1, 3, .warn), (2, 3, .warn),
            (1, 1, .good), (3, 3, .good),
        ]
        for (reachable, total, level) in rows {
            XCTAssertEqual(StatusText.serverCountLevel(reachable: reachable, total: total), level, "\(reachable)/\(total)")
        }
    }

    func testRemoteBriefTable() {
        let rows: [(RemoteState, CheckMethod, String)] = [
            (.pending, .ssh, "확인 중"),
            (.ok(latencyMs: 3), .ssh, "SSH ok · 3ms"),
            (.ok(latencyMs: 3), .tcp, "포트 ok · 3ms"),
            (.fail(latencyMs: 40), .ssh, "SSH 실패 · 40ms"),
            (.fail(latencyMs: 40), .tcp, "포트 실패 · 40ms"),
            (.off(latencyMs: 2000), .ssh, "꺼짐"),
            (.off(latencyMs: 2000), .tcp, "꺼짐"),
            (.needsAuth(url: nil), .ssh, "Tailscale 인증 필요"),
            (.skip(reason: StatusMonitor.SkipReason.lanDown.rawValue), .ssh, "Acme down"),
            (.skip(reason: StatusMonitor.SkipReason.tailscaleDown.rawValue), .ssh, "Tailscale 꺼짐"),
            (.skip(reason: "모르는 이유"), .tcp, "모르는 이유"),
        ]
        for (state, check, text) in rows {
            XCTAssertEqual(StatusText.remoteBrief(state, check: check, lanName: "Acme"), text, "\(state) \(check)")
        }
    }

    func testTrafficCaptionTable() {
        // (누적, 장치 있음, 연결됨, 속도 있음, 보내기, 표본 수) → 아래 줄
        let rows: [(Int64?, Bool, Bool, Bool, Bool, Int, String?)] = [
            (nil, false, false, false, false, 0, nil),          // 연결 안 됨: 빈 줄
            (nil, false, false, false, true, 0, nil),
            (nil, false, true, false, false, 0, "측정 중…"),    // 망은 연결됐는데 장치를 아직 못 읽음 (VPN)
            (nil, true, false, false, false, 0, "측정 중…"),    // 장치는 있고 첫 표본 전
            (nil, true, false, false, true, 0, "측정 중…"),
            (nil, true, false, true, false, 7, nil),            // 받기: 아래 줄 없음
            (nil, true, false, true, true, 7, "최근 7회"),      // 보내기: 표본 수
            (2048, true, false, true, true, 7, "누적 \(TransferMeter.format(2048))"),   // 누적이 있으면 그것만
            (0, false, false, false, false, 0, "누적 \(TransferMeter.format(0))"),
        ]
        for (total, device, connected, measured, sending, samples, text) in rows {
            XCTAssertEqual(StatusText.trafficCaption(total: total, hasDevice: device, connected: connected, measured: measured,
                                                     sending: sending, samples: samples), text,
                           "\(String(describing: total)) \(device) \(connected) \(measured) \(sending)")
        }
    }

    func testAddressText() {
        XCTAssertEqual(StatusText.addressText(ip: nil, mask: nil), "–")
        XCTAssertEqual(StatusText.addressText(ip: nil, mask: "255.255.255.0"), "–")
        XCTAssertEqual(StatusText.addressText(ip: "192.0.2.17", mask: nil), "192.0.2.17")
        XCTAssertEqual(StatusText.addressText(ip: "192.0.2.17", mask: "255.255.255.0"), "192.0.2.17/24")
        XCTAssertEqual(StatusText.addressText(ip: "198.51.100.9", mask: "255.255.252.0"), "198.51.100.9/22")
        XCTAssertEqual(StatusText.addressText(ip: "192.0.2.17", mask: "엉뚱한 값"), "192.0.2.17")   // 마스크를 못 읽으면 주소만
    }

    // MARK: Wi-Fi 화면

    func testWiFiTable() {
        typealias W = StatusText.WiFi
        // (값, 위치 권한) → (결론, 제목)
        let rows: [(W?, Bool, String, String)] = [
            (nil, true, "인터페이스 없음", "Wi-Fi"),
            (nil, false, "인터페이스 없음", "Wi-Fi"),
            (W(powerOn: false, associated: false, ssid: nil), true, "꺼짐", "Wi-Fi"),
            (W(powerOn: false, associated: true, ssid: "Acme-5G"), true, "꺼짐", "Wi-Fi"),   // 꺼져 있으면 남은 값을 보지 않는다
            (W(powerOn: true, associated: false, ssid: nil), true, "연결 안 됨", "연결 안 됨"),
            (W(powerOn: true, associated: false, ssid: "Acme-5G"), false, "연결 안 됨", "연결 안 됨"),
            (W(powerOn: true, associated: true, ssid: "Acme-5G"), true, "연결됨", "Acme-5G"),
            (W(powerOn: true, associated: true, ssid: "Acme-5G"), false, "연결됨", "Acme-5G"),
            (W(powerOn: true, associated: true, ssid: nil), true, "연결됨", "이름 없음"),
            (W(powerOn: true, associated: true, ssid: nil), false, "연결됨", "이름 숨김"),
        ]
        for (info, authorized, conclusion, title) in rows {
            XCTAssertEqual(StatusText.wifiConclusion(info), conclusion, "\(String(describing: info))")
            XCTAssertEqual(StatusText.wifiTitle(info, locationAuthorized: authorized), title, "\(String(describing: info)) \(authorized)")
        }
    }

    func testWiFiNearbyEmptyTextTable() {
        let searching = "검색 중…", failed = "주변 네트워크를 검색하지 못했습니다 · 다시 검색하세요"
        let empty = "주변 네트워크가 없습니다.", noPermission = "위치 권한이 없어 네트워크 이름을 읽지 못했습니다."
        // (검색 중, 한 번 끝냄, 실패, 위치 권한) → 글
        let rows: [(Bool, Bool, Bool, Bool, String)] = [
            (false, false, false, true, searching),    // 화면을 막 열었다 (아직 검색 전)
            (true, false, false, true, searching),
            (true, true, false, true, searching),      // [다시 검색] 중
            (true, true, true, true, searching),       // 실패한 뒤 다시 검색 중
            (false, false, true, true, failed),        // 첫 검색이 실패
            (false, true, true, false, failed),
            (false, true, false, true, empty),
            (false, true, false, false, noPermission),
        ]
        for (scanning, scanned, fail, authorized, text) in rows {
            XCTAssertEqual(StatusText.wifiNearbyEmptyText(scanning: scanning, scanned: scanned, failed: fail, locationAuthorized: authorized),
                           text, "\(scanning) \(scanned) \(fail) \(authorized)")
        }
    }

    // MARK: Ethernet 화면

    private func adapter(active: Bool, addresses: [String] = [], serviceIP: String? = nil, media: String? = nil,
                         gatewayPresent: Bool? = nil) -> EthernetAdapter {
        EthernetAdapter(service: "USB LAN", hardwarePort: "USB 10/100/1000 LAN", device: "en8",
                        interface: InterfaceState(ipv4: addresses.first, netmask: "255.255.255.0", media: media, active: active, addresses: addresses),
                        info: ServiceInfo(ip: serviceIP, mask: "255.255.255.0"), gatewayPresent: gatewayPresent)
    }

    func testEthernetTable() {
        let connected = adapter(active: true, addresses: ["192.0.2.30"], serviceIP: "192.0.2.30", media: "1000baseT <full-duplex>")
        let connectedNoMedia = adapter(active: true, addresses: ["192.0.2.30"], serviceIP: "192.0.2.30")
        let noLink = adapter(active: false)
        let noAddress = adapter(active: true, media: "1000baseT <full-duplex>")
        let noGateway = adapter(active: true, addresses: ["192.0.2.30"], serviceIP: "192.0.2.30", gatewayPresent: false)

        // 결론: 못 읽음 → 대표 없음 → 서비스 판정
        XCTAssertEqual(StatusText.ethernetConclusion(loaded: false, primary: nil), "확인 중…")
        XCTAssertEqual(StatusText.ethernetConclusion(loaded: false, primary: connected), "확인 중…")
        XCTAssertEqual(StatusText.ethernetConclusion(loaded: true, primary: nil), "연결 안 됨")
        XCTAssertEqual(StatusText.ethernetConclusion(loaded: true, primary: connected), "연결됨")   // IP 는 결론에 넣지 않는다
        XCTAssertEqual(StatusText.ethernetConclusion(loaded: true, primary: noLink), "링크 없음")
        XCTAssertEqual(StatusText.ethernetConclusion(loaded: true, primary: noAddress), "주소 없음")
        XCTAssertEqual(StatusText.ethernetConclusion(loaded: true, primary: noGateway), "게이트웨이 응답 없음")

        // 링크 줄
        XCTAssertEqual(StatusText.ethernetLinkText(connected), "1000baseT <full-duplex>")
        XCTAssertEqual(StatusText.ethernetLinkText(connectedNoMedia), "연결됨")
        XCTAssertEqual(StatusText.ethernetLinkText(noLink), "링크 없음")
        XCTAssertEqual(StatusText.ethernetLinkText(noAddress), "–")    // 같은 NIC 의 다른 서비스가 쓰는 선
        XCTAssertEqual(StatusText.ethernetLinkText(noGateway), "–")

        // IP 줄 (화면은 addressText(ip: adapter.address, mask: adapter.netmask))
        XCTAssertEqual(StatusText.addressText(ip: connected.address, mask: connected.netmask), "192.0.2.30/24")
        XCTAssertEqual(StatusText.addressText(ip: noAddress.address, mask: noAddress.netmask), "–")
        XCTAssertEqual(StatusText.addressText(ip: noGateway.address, mask: noGateway.netmask), "192.0.2.30/24")
    }

    // MARK: 서버 추가·편집 창

    func testPortResultTable() {
        typealias P = ServerFormCheck.PortResult
        // 입력칸 글자 그대로(앞뒤 공백만 뗀다)
        let rows: [(P, String?, String?)] = [
            (.idle, nil, nil),
            (.checking, "192.0.2.10:22 확인 중…", nil),
            (.open(3), "192.0.2.10:22 응답 있음 · 3ms", "3ms"),
            (.open(0), "192.0.2.10:22 응답 있음 · 0ms", "0ms"),
            (.closed, "192.0.2.10:22 응답이 없습니다", "응답 없음"),
        ]
        for (state, text, short) in rows {
            XCTAssertEqual(state.text(ip: " 192.0.2.10 ", port: " 22"), text, "\(state)")
            XCTAssertEqual(state.resultText, short, "\(state)")
        }
        XCTAssertEqual(P.checking.text(ip: "", port: ""), ": 확인 중…")   // 빈 칸이어도 그대로 (버튼이 꺼져 있어 실제로는 안 나온다)
    }

    func testPingResultTable() {
        typealias P = ServerFormCheck.PingResult
        let rows: [(P, String?, String?, Bool)] = [
            (.idle, nil, nil, false),
            (.checking, "192.0.2.10 ping 중…", nil, false),
            (.replied(ms: 12, loss: 0), "192.0.2.10 응답 있음 · 평균 12ms · 손실 0%", "12ms", false),
            (.replied(ms: 12, loss: 33), "192.0.2.10 응답 있음 · 평균 12ms · 손실 33%", "12ms", true),
            (.none, "192.0.2.10 ping 응답이 없습니다", "응답 없음", false),
        ]
        for (state, text, short, loss) in rows {
            XCTAssertEqual(state.text(ip: " 192.0.2.10 "), text, "\(state)")
            XCTAssertEqual(state.resultText, short, "\(state)")
            XCTAssertEqual(state.hasLoss, loss, "\(state)")
        }
    }

    func testPingResultFromSummary() {
        typealias P = ServerFormCheck.PingResult
        XCTAssertEqual(P.of(nil), P.none)                // 재지 못함
        XCTAssertEqual(P.of(PingSummary.none), P.none)   // 응답이 하나도 없음
        XCTAssertEqual(P.of(PingSummary(averageMs: 12.4, lossPercent: 0, jitterMs: nil)), .replied(ms: 12, loss: 0))
        XCTAssertEqual(P.of(PingSummary(averageMs: 12.5, lossPercent: 33.3, jitterMs: 1)), .replied(ms: 13, loss: 33))   // 반올림
        XCTAssertEqual(P.of(PingSummary(averageMs: 0.4, lossPercent: 66.7, jitterMs: nil)), .replied(ms: 0, loss: 67))
    }

    func testPortNumber() {
        XCTAssertEqual(ServerFormCheck.portNumber("22"), 22)
        XCTAssertEqual(ServerFormCheck.portNumber(" 8080 "), 8080)
        XCTAssertEqual(ServerFormCheck.portNumber("1"), 1)
        XCTAssertEqual(ServerFormCheck.portNumber("65535"), 65535)
        for bad in ["", " ", "0", "65536", "-1", "22a", "2 2", "ssh"] {
            XCTAssertNil(ServerFormCheck.portNumber(bad), bad)
        }
    }

    func testMissingFieldsAndHint() {
        func missing(key: String = "web-01", lan: Bool = false, ip: String = "192.0.2.10", user: String = "deploy", group: String = "Acme") -> [String] {
            ServerFormCheck.missingFields(key: key, lanServiceMissing: lan, ip: ip, user: user, group: group)
        }
        XCTAssertEqual(missing(), [])
        XCTAssertEqual(missing(key: "", lan: true, ip: "", user: "", group: " "), ["이름", "서비스", "IP", "사용자", "그룹"])   // 빈 창 (순서 고정)
        XCTAssertEqual(missing(key: "", ip: ""), ["이름", "IP"])
        XCTAssertEqual(missing(group: ""), ["그룹"])
        XCTAssertEqual(missing(key: " "), [])   // 이름 · IP · 사용자는 공백을 떼지 않고 본다 (그룹만 뗀다)

        // 조사는 마지막 칸에 맞춘다
        XCTAssertNil(ServerFormCheck.missingHint([], adding: true))
        XCTAssertEqual(ServerFormCheck.missingHint(["이름"], adding: true), "이름을 채우면 추가할 수 있습니다")
        XCTAssertEqual(ServerFormCheck.missingHint(["그룹"], adding: false), "그룹을 채우면 저장할 수 있습니다")
        XCTAssertEqual(ServerFormCheck.missingHint(["이름", "IP"], adding: true), "이름·IP를 채우면 추가할 수 있습니다")
        XCTAssertEqual(ServerFormCheck.missingHint(["서비스"], adding: true), "서비스를 채우면 추가할 수 있습니다")
        XCTAssertEqual(ServerFormCheck.missingHint(["IP", "사용자"], adding: false), "IP·사용자를 채우면 저장할 수 있습니다")
        XCTAssertEqual(ServerFormCheck.missingHint(["이름", "서비스", "IP", "사용자", "그룹"], adding: true),
                       "이름·서비스·IP·사용자·그룹을 채우면 추가할 수 있습니다")
    }

    func testRenameClosesText() {
        XCTAssertNil(ServerFormCheck.renameClosesText(tabs: 0, tunnels: 0))
        XCTAssertEqual(ServerFormCheck.renameClosesText(tabs: 2, tunnels: 0), "이름을 바꾸면 열린 탭 2개가 닫힙니다")
        XCTAssertEqual(ServerFormCheck.renameClosesText(tabs: 0, tunnels: 1), "이름을 바꾸면 터널 1개가 닫힙니다")
        XCTAssertEqual(ServerFormCheck.renameClosesText(tabs: 2, tunnels: 3), "이름을 바꾸면 열린 탭 2개·터널 3개가 닫힙니다")
    }

    // MARK: 터널 정보 창

    func testTunnelSheetTextTable() {
        let server = Server.sample(key: "web-01", network: .direct, type: .linux, ip: "192.0.2.10", check: .ssh)
        let port = TunnelSpec(server: server, kind: .port(remotePort: 3000), localPort: 3001)
        let portOther = TunnelSpec(server: server, kind: .port(remotePort: 443, remoteHost: "198.51.100.7"), localPort: 8443)
        let named = TunnelSpec(server: server, kind: .port(remotePort: 3000), localPort: 3000, bindAddress: "127.0.0.2", hostName: "web-01.acme")
        let db = TunnelSpec(server: server, kind: .db(host: "198.51.100.6", port: 5432, name: "orders"), localPort: 15432)
        let dbUnnamed = TunnelSpec(server: server, kind: .db(host: "198.51.100.6", port: 5432, name: nil), localPort: 5432,
                                   bindAddress: "127.0.0.3", hostName: "db.acme")
        let socks = TunnelSpec(server: server, kind: .socks, localPort: 1080)

        // (터널) → (제목, 오른쪽 칸 이름, 오른쪽 주소, 붙여 쓰는 주소)
        let rows: [(TunnelSpec, String, String, String, String)] = [
            (port, "web-01 포트 터널", "web-01 에서", "127.0.0.1:3000", "localhost:3001"),
            (portOther, "web-01 포트 터널", "web-01 에서", "198.51.100.7:443", "localhost:8443"),
            (named, "web-01 포트 터널", "web-01 에서", "127.0.0.1:3000", "web-01.acme:3000"),
            (db, "web-01 DB 터널", "web-01 경유", "198.51.100.6:5432", "localhost:15432"),
            (dbUnnamed, "web-01 DB 터널", "web-01 경유", "198.51.100.6:5432", "db.acme:5432"),
            (socks, "web-01 프록시 터널", "web-01 경유", "모든 주소 (SOCKS5)", "socks5://localhost:1080"),
        ]
        for (spec, heading, title, remote, primary) in rows {
            XCTAssertEqual(spec.sheetHeading, heading, spec.summary)
            XCTAssertEqual(spec.remoteTitle, title, spec.summary)
            XCTAssertEqual(spec.remoteAddress, remote, spec.summary)
            XCTAssertEqual(spec.primaryAddress, primary, spec.summary)
        }

        // DB 터널만 복사용 값
        XCTAssertNil(port.dbConnection)
        XCTAssertNil(socks.dbConnection)
        XCTAssertEqual(db.dbConnection?.name, "orders")
        XCTAssertEqual(db.dbConnection?.jdbc, "jdbc:postgresql://localhost:15432/orders")
        XCTAssertEqual(db.dbConnection?.psql, "psql \"postgresql://<user>:<password>@localhost:15432/orders\"")
        XCTAssertEqual(dbUnnamed.dbConnection?.name, "<db>")   // DB 이름을 모르면 자리 표시
        XCTAssertEqual(dbUnnamed.dbConnection?.jdbc, "jdbc:postgresql://db.acme:5432/<db>")
        XCTAssertEqual(dbUnnamed.dbConnection?.psql, "psql \"postgresql://<user>:<password>@db.acme:5432/<db>\"")
    }

    func testTunnelStateSheetText() {
        let rows: [(TunnelState, String)] = [
            (.idle, "지난번에 연 터널 · [다시 연결]로 엽니다"),
            (.connecting, "연결 중"),
            (.open, "열림"),
            (.closed(exitCode: 255, message: "Connection refused"), "닫힘"),
            (.closed(exitCode: 0, message: ""), "닫힘"),
        ]
        for (state, text) in rows { XCTAssertEqual(state.sheetText, text, "\(state)") }
    }

    func testTunnelElapsedText() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        // (지난 초) → 글. 경계: 1분 · 1시간
        let rows: [(TimeInterval, String)] = [
            (0, "방금"), (59, "방금"), (-30, "방금"),   // 시계가 뒤로 가도 "방금"
            (60, "1분 경과"), (119, "1분 경과"), (3599, "59분 경과"),
            (3600, "1시간 0분 경과"), (3660, "1시간 1분 경과"), (2 * 3600 + 5 * 60 + 59, "2시간 5분 경과"), (26 * 3600, "26시간 0분 경과"),
        ]
        for (seconds, text) in rows {
            XCTAssertEqual(TunnelState.elapsedText(from: start, to: start.addingTimeInterval(seconds)), text, "\(seconds)")
        }
    }

    // MARK: 전송

    private func progress(_ file: String, _ percent: Int, _ transferred: String, rate: String = "10.0MB/s", eta: String = "00:12") -> TransferProgress {
        TransferProgress(file: file, percent: percent, transferred: transferred, rate: rate, eta: eta)
    }

    private func meter(total: Int64? = nil, _ records: [TransferProgress]) -> TransferMeter {
        var meter = TransferMeter(totalBytes: total)
        for record in records { meter.record(record) }
        return meter
    }

    func testTransferProgressTable() {
        let one = progress("a.bin", 45, "512KB")
        let second = progress("b.bin", 20, "512KB")
        let mb: Int64 = 1024 * 1024

        // 연결 중 (진행률 줄이 아직 없다)
        let idle = TransferState.running(nil)
        XCTAssertNil(idle.fraction(meter: TransferMeter()))
        XCTAssertNil(idle.progressText(meter: TransferMeter()))
        XCTAssertEqual(idle.rowDetail(meter: TransferMeter()), "연결 중…")
        XCTAssertEqual(idle.sheetTitle(meter: TransferMeter()), "연결 중…")

        // 파일 하나 · 전체 크기 모름: 그 파일의 % 와 scp 가 찍은 값 그대로
        let single = meter([one])
        XCTAssertEqual(TransferState.running(one).fraction(meter: single), 0.45)
        XCTAssertEqual(TransferState.running(one).progressText(meter: single), "45% · 512KB · 10.0MB/s · 00:12")
        XCTAssertEqual(TransferState.running(one).rowDetail(meter: single), "45% · 512KB · 10.0MB/s · 00:12")
        XCTAssertEqual(TransferState.running(one).sheetTitle(meter: single), "전송 중 · 45%")

        // 파일 하나 · 전체 크기 앎: 전체 기준 % 와 "받은 / 전체"
        let sized = meter(total: 2 * mb, [one])   // 512KB / 2MB = 25%
        XCTAssertEqual(TransferState.running(one).fraction(meter: sized), 0.25)
        XCTAssertEqual(TransferState.running(one).progressText(meter: sized),
                       "25% · \(TransferMeter.format(512 * 1024)) / \(TransferMeter.format(2 * mb)) · 10.0MB/s · 00:12")
        XCTAssertEqual(TransferState.running(one).sheetTitle(meter: sized), "전송 중 · 25%")

        // 여러 파일 · 전체 크기 모름: 막대는 움직이는 막대(nil), 글은 "n번째 파일" 먼저
        let many = meter([one, second])
        XCTAssertEqual(many.fileCount, 2)
        XCTAssertNil(TransferState.running(second).fraction(meter: many))
        XCTAssertEqual(TransferState.running(second).progressText(meter: many), "2번째 파일 · 20% · 10.0MB/s")
        XCTAssertEqual(TransferState.running(second).sheetTitle(meter: many), "전송 중")

        // 여러 파일 · 전체 크기 앎: 남은 시간 대신 "n번째 파일" (scp 의 남은 시간은 파일 기준)
        let manySized = meter(total: 4 * mb, [one, second])   // 1MB / 4MB
        XCTAssertEqual(TransferState.running(second).fraction(meter: manySized), 0.25)
        XCTAssertEqual(TransferState.running(second).progressText(meter: manySized),
                       "25% · \(TransferMeter.format(mb)) / \(TransferMeter.format(4 * mb)) · 10.0MB/s · 2번째 파일")

        // 끝난 상태: 진행 값은 없다
        for state in [TransferState.done, .cancelled, .failed(exitCode: 1, message: "x")] {
            XCTAssertNil(state.fraction(meter: sized), "\(state)")
            XCTAssertNil(state.progressText(meter: sized), "\(state)")
        }
    }

    func testTransferEndStateText() {
        let m = TransferMeter()
        // (상태) → (목록 행, 창 머리)
        let rows: [(TransferState, String, String)] = [
            (.done, "완료", "완료"),
            (.cancelled, "취소됨", "취소됨"),
            (.failed(exitCode: 1, message: "scp: /srv/app: Permission denied"), "실패 (exit 1) · scp: /srv/app: Permission denied", "실패 · exit 1"),
            (.failed(exitCode: 255, message: "첫 줄\n마지막 줄"), "실패 (exit 255) · 마지막 줄", "실패 · exit 255"),   // 행은 마지막 줄만
            (.failed(exitCode: 2, message: ""), "실패 (exit 2) · ", "실패 · exit 2"),   // 메시지가 없어도 꼴은 그대로
        ]
        for (state, row, title) in rows {
            XCTAssertEqual(state.rowDetail(meter: m), row, "\(state)")
            XCTAssertEqual(state.sheetTitle(meter: m), title, "\(state)")
        }
    }
}
