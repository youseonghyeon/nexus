// Ethernet 화면의 서비스 관리: 하드웨어 포트 읽기 · 서비스 추가 입력 검사 · 켜기/끄기·추가 스크립트
// 하드웨어 포트 출력은 2026-10-15 이 Mac 의 networksetup -listallhardwareports 모양 (MAC 은 예시).

import Foundation
@testable import ServersCore
import XCTest

final class NetworkServicesTests: XCTestCase {
    private let ports = """
        Hardware Port: Ethernet Adapter (en4)
        Device: en4
        Ethernet Address: 1e:00:00:00:00:01

        Hardware Port: USB 10/100/1000 LAN
        Device: en10
        Ethernet Address: 00:00:00:00:00:02

        Hardware Port: Thunderbolt Bridge
        Device: bridge0
        Ethernet Address: 02:00:00:00:00:00

        Hardware Port: Wi-Fi
        Device: en0
        Ethernet Address: 00:00:00:00:00:03

        VLAN Configurations
        ===================
        """

    func testHardwarePorts() {
        let parsed = HardwarePort.parse(ports)
        XCTAssertEqual(parsed.map(\.device), ["en4", "en10", "bridge0", "en0"])
        XCTAssertEqual(parsed[1].name, "USB 10/100/1000 LAN")
        XCTAssertEqual(parsed.filter(\.isWired).map(\.device), ["en4", "en10"], "브리지·Wi-Fi 는 유선이 아니다")
    }

    func testDraftProblems() {
        let ok = NetworkServiceDraft(name: " acme ethernet ", port: "USB 10/100/1000 LAN", ip: "10.50.10.17", router: "10.50.10.254")
        XCTAssertNil(ok.problem(existing: ["Wi-Fi", "iptime Hub NIC"]))
        XCTAssertEqual(ok.trimmed.name, "acme ethernet")
        func p(_ change: (inout NetworkServiceDraft) -> Void) -> String? {
            var d = ok; change(&d); return d.problem(existing: ["Wi-Fi", "ACME Ethernet 2"])
        }
        XCTAssertEqual(p { $0.name = "" }, "이름을 입력하세요")
        XCTAssertNotNil(p { $0.name = "a # b" })
        XCTAssertNotNil(p { $0.name = "*hidden" })
        XCTAssertNotNil(p { $0.name = "wi-fi" }, "대소문자만 다른 이름도 겹침")
        XCTAssertEqual(p { $0.port = "" }, "어댑터를 고르세요")
        XCTAssertNotNil(p { $0.ip = "10.50.10" })
        XCTAssertNotNil(p { $0.ip = "10.50.10.256" })
        XCTAssertNotNil(p { $0.ip = "10.50.10.-1" })
        XCTAssertNotNil(p { $0.mask = "255.0.255.0" }, "연속된 1 비트가 아님")
        XCTAssertNotNil(p { $0.mask = "255.255.255.255" })
        XCTAssertEqual(p { $0.router = "10.50.11.254" }, "게이트웨이가 IP 와 같은 대역이 아닙니다")
        XCTAssertNil(p { $0.mask = "255.255.0.0"; $0.router = "10.50.11.254" }, "/16 이면 같은 대역")
        XCTAssertEqual(p { $0.router = "10.50.10.17" }, "IP 와 게이트웨이가 같습니다")
        XCTAssertNotNil(p { $0.ip = "010.50.10.17" }, "앞자리 0 은 8진수로 읽힐 수 있다")
        XCTAssertNil(p { $0.ip = "10.50.10.0"; $0.mask = "255.255.0.0" }, "/16 안에선 .0 도 일반 주소")
        XCTAssertEqual(p { $0.ip = "10.50.10.0" }, "IP 가 대역의 네트워크·브로드캐스트 주소입니다")
        XCTAssertEqual(p { $0.ip = "10.50.10.255" }, "IP 가 대역의 네트워크·브로드캐스트 주소입니다")
        XCTAssertEqual(p { $0.router = "10.50.10.255" }, "게이트웨이가 대역의 네트워크·브로드캐스트 주소입니다")
        XCTAssertNil(p { $0.dns = " 10.50.10.1, 8.8.8.8 " })
        XCTAssertNotNil(p { $0.dns = "10.50.10.1, dns.example" }, "DNS 는 IPv4 만")
    }

    /// 켜짐과 연결됨은 다르다: 꺼짐 · 어댑터 없음 · 링크 없음 · 주소 없음 · 연결됨(그 서비스의 IP 가 장치에 붙음)
    /// (2026-10-15 화면: TPlink·Samsung 은 켜져 있지만 어댑터를 뽑아 장치가 없었는데 "켜짐"만 보여 연결된 것처럼 보였다)
    func testServiceLink() {
        let on = LanServiceEntry(name: "acme ethernet", hardwarePort: "USB 10/100/1000 LAN", device: "en10", enabled: true)
        let off = LanServiceEntry(name: "acme ethernet", hardwarePort: "USB 10/100/1000 LAN", device: "en10", enabled: false)
        let en10 = InterfaceState(ipv4: "172.30.1.149", active: true, addresses: ["172.30.1.149", "10.50.10.17"])
        XCTAssertEqual(ServiceLink.of(off, interface: en10, serviceIP: "10.50.10.17"), .disabled)
        XCTAssertEqual(ServiceLink.of(on, interface: nil, serviceIP: nil), .noAdapter)
        XCTAssertEqual(ServiceLink.of(on, interface: InterfaceState(active: false), serviceIP: "10.50.10.17"), .noLink)
        XCTAssertEqual(ServiceLink.of(on, interface: InterfaceState(ipv4: "172.30.1.149", active: true, addresses: ["172.30.1.149"]), serviceIP: "10.50.10.17"),
                       .noAddress, "같은 장치에 다른 서비스 IP 만 있으면 이 서비스는 연결 아님")
        XCTAssertEqual(ServiceLink.of(on, interface: en10, serviceIP: "10.50.10.17"), .connected(ip: "10.50.10.17"))
        XCTAssertEqual(ServiceLink.of(on, interface: InterfaceState(active: true, addresses: ["169.254.1.2"]), serviceIP: "169.254.1.2"), .noAddress)
        // 수동 IP 는 어느 선에서든 붙는다 — 게이트웨이가 응답하지 않으면 연결로 보지 않는다 (2026-10-15: 인터넷 선인데 acme ethernet 이 "연결됨")
        XCTAssertEqual(ServiceLink.of(on, interface: en10, serviceIP: "10.50.10.17", gatewayPresent: false), .noGateway(ip: "10.50.10.17"))
        XCTAssertEqual(ServiceLink.of(on, interface: en10, serviceIP: "10.50.10.17", gatewayPresent: true), .connected(ip: "10.50.10.17"))
        XCTAssertEqual(ServiceLink.noGateway(ip: "10.50.10.17").text, "활성 · 게이트웨이 응답 없음")
        XCTAssertFalse(ServiceLink.noGateway(ip: "10.50.10.17").isConnected)
        XCTAssertEqual(ServiceLink.noAdapter.text, "활성 · 어댑터 없음")
        XCTAssertEqual(ServiceLink.connected(ip: "10.50.10.17").text, "연결됨 · 10.50.10.17")
    }

    /// "활성 · " 머리를 뗀 문구 (Ethernet 행·결론). 예전 뷰의 text.replacingOccurrences(of: "활성 · ", with: "") 결과와 같아야 한다.
    func testServiceLinkShortTextTable() {
        let rows: [(ServiceLink, String, String)] = [
            (.disabled, "비활성", "비활성"),
            (.noAdapter, "활성 · 어댑터 없음", "어댑터 없음"),
            (.noLink, "활성 · 링크 없음", "링크 없음"),
            (.noAddress, "활성 · 주소 없음", "주소 없음"),
            (.noGateway(ip: "10.50.10.17"), "활성 · 게이트웨이 응답 없음", "게이트웨이 응답 없음"),
            (.connected(ip: "10.50.10.17"), "연결됨 · 10.50.10.17", "연결됨 · 10.50.10.17"),
        ]
        for (link, text, short) in rows {
            XCTAssertEqual(link.text, text, "\(link)")
            XCTAssertEqual(link.shortText, short, "\(link)")
        }
    }

    private func zshSyntaxOK(_ script: String) throws -> Bool {
        try shellSyntaxStatus("/bin/zsh", script) == 0
    }

    func testScripts() throws {
        let on = LanCommands.serviceEnableScript("TPlink 2.5G Ethernet", on: true)
        XCTAssertTrue(on.contains("sudo networksetup -setnetworkserviceenabled 'TPlink 2.5G Ethernet' on"), on)
        XCTAssertTrue(on.contains("env -u SUDO_ASKPASS sudo -v"), "인증은 다른 관리자 작업과 같은 길")
        XCTAssertTrue(try zshSyntaxOK(on))

        let draft = NetworkServiceDraft(name: "acme's lan", port: "USB 10/100/1000 LAN", ip: "10.50.10.17", router: "10.50.10.254")
        let create = LanCommands.createServiceScript(draft, libDir: "/x/lib")
        let name = #"'acme'\''s lan'"#
        // 만들기 → 끄기 → 수동 IP 순서, 실패하면 지운다, 순서는 맨 뒤로
        let order = ["-createnetworkservice \(name) 'USB 10/100/1000 LAN'", "-setnetworkserviceenabled \(name) off",
                     "-setmanual \(name) '10.50.10.17' '255.255.255.0' '10.50.10.254'", "-removenetworkservice \(name)", "_lan_move_last \(name)"]
        var last = create.startIndex
        for piece in order {
            guard let range = create.range(of: piece, range: last..<create.endIndex) else { return XCTFail("\(piece) 없음\n\(create)") }
            last = range.upperBound
        }
        XCTAssertTrue(try zshSyntaxOK(create))
        XCTAssertFalse(create.contains("-setdnsservers"), "DNS 칸이 비면 건드리지 않는다")
        var withDNS = draft; withDNS.dns = "10.50.10.1 8.8.8.8"
        let dnsScript = LanCommands.createServiceScript(withDNS, libDir: "/x/lib")
        XCTAssertTrue(dnsScript.contains("sudo networksetup -setdnsservers \(name) '10.50.10.1' '8.8.8.8'"), dnsScript)
        XCTAssertTrue(try zshSyntaxOK(dnsScript))
    }
}
