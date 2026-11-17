// 진단 카드가 보낼 곳 (DiagnosticNetwork) 상태 표: 망 상태 → 장치 · DNS 서버 · ARP 를 거를 대역. 화면마다 빈 상태(아직 못 읽음·연결 없음)를 꼭 넣는다.
// 기댓값은 옮기기 전 AppModel.diagnosticDevice·diagnosticDNSServer·diagnosticSubnet 의 조건식에서 적었다.

import Foundation
import XCTest
@testable import ServersCore

final class DiagnosticTargetsTests: XCTestCase {
    private func lan(enabled: Bool, device: String? = "en10", ip: String? = "192.0.2.10", mask: String? = "255.255.255.0") -> LanInfo {
        LanInfo(service: "Intranet LAN", enabled: enabled, device: device, hardwarePort: "USB 10/100/1000 LAN", configuration: "Manual Configuration",
                configuredIP: ip, subnetMask: mask, router: nil, actualIP: nil)
    }

    /// 연결됨 · 링크 없음 · 게이트웨이 응답 없음 (수동 IP — 주소는 있지만 연결 아님)
    private func ethernet(_ link: String) -> EthernetAdapter {
        let up = InterfaceState(ipv4: "192.168.0.2", netmask: "255.255.255.0", active: link != "noLink")
        return EthernetAdapter(service: "USB LAN", hardwarePort: nil, device: "en8", interface: up,
                               info: ServiceInfo(ip: "192.168.0.2", mask: "255.255.255.0"), gatewayPresent: link == "noGateway" ? false : nil)
    }

    private func vpn(_ id: String, _ state: SystemVPN.State) -> SystemVPN {
        SystemVPN(id: id, name: id, kind: "WireGuard", enabled: true, state: state)
    }

    private func detail(interface: String?, dns: [String] = []) -> SystemVPNDetail {
        var detail = SystemVPNDetail()
        detail.interface = interface
        detail.dnsServers = dns
        return detail
    }

    private func dns(_ scoped: [String: String]) -> DNSConfig {
        DNSConfig(primary: nil, scoped: scoped.mapValues { DNSResolver(nameservers: [$0]) })
    }

    private func subnetText(_ net: DiagnosticNetwork, _ screen: DiagnosticScreen) -> String? {
        net.subnet(screen).map { "\($0.ip)/\($0.mask)" }
    }

    func testEmptyNetworkHasNoTargets() {
        // 아무것도 아직 못 읽음 (앱을 켠 직후) — 모든 화면에서 버튼이 꺼진다
        let empty = DiagnosticNetwork()
        for screen in DiagnosticScreen.allCases {
            XCTAssertNil(empty.device(screen), "\(screen)")
            XCTAssertNil(empty.dnsServer(screen), "\(screen)")
            XCTAssertNil(empty.subnet(screen), "\(screen)")
        }
    }

    func testIntranetTable() {
        // 장치: `lanInfo?.enabled == true ? lanInfo?.device : nil` · 대역: configuredIP·subnetMask (켜짐과 무관)
        let rows: [(name: String, lan: LanInfo?, device: String?, subnet: String?)] = [
            ("설정 없음·아직 안 읽음", nil, nil, nil),
            ("꺼짐", lan(enabled: false), nil, "192.0.2.10/255.255.255.0"),
            ("켜짐", lan(enabled: true), "en10", "192.0.2.10/255.255.255.0"),
            ("켜짐 · 어댑터 없음", lan(enabled: true, device: nil), nil, "192.0.2.10/255.255.255.0"),
            ("켜짐 · DHCP (수동 주소 없음)", lan(enabled: true, ip: nil, mask: nil), "en10", nil),
        ]
        for row in rows {
            let net = DiagnosticNetwork(lan: row.lan, dns: dns(["en10": "192.0.2.53"]))
            XCTAssertEqual(net.device(.lan), row.device, row.name)
            XCTAssertEqual(subnetText(net, .lan), row.subnet, row.name)
            XCTAssertEqual(net.dnsServer(.lan), row.device == nil ? nil : "192.0.2.53", "DNS 는 장치가 있을 때 그 장치의 scoped DNS — \(row.name)")
        }
        // 장치는 있는데 그 장치의 DNS 가 없다
        XCTAssertNil(DiagnosticNetwork(lan: lan(enabled: true), dns: dns(["en0": "192.168.0.1"])).dnsServer(.lan))
        XCTAssertNil(DiagnosticNetwork(lan: lan(enabled: true)).dnsServer(.lan), "DNS 를 아직 못 읽음")
    }

    func testWiFiTable() {
        // 장치: `wifi.info?.associated == true ? wifi.info?.interface : nil` · 대역: wifiAddress.ip·subnet
        let rows: [(name: String, interface: String?, associated: Bool, device: String?)] = [
            ("Wi-Fi 정보 없음", nil, false, nil),
            ("꺼짐·연결 안 됨", "en0", false, nil),
            ("연결됨", "en0", true, "en0"),
        ]
        for row in rows {
            let net = DiagnosticNetwork(wifiInterface: row.interface, wifiAssociated: row.associated, dns: dns(["en0": "192.168.0.1"]))
            XCTAssertEqual(net.device(.wifi), row.device, row.name)
            XCTAssertEqual(net.dnsServer(.wifi), row.device == nil ? nil : "192.168.0.1", row.name)
        }
        XCTAssertEqual(subnetText(DiagnosticNetwork(wifiIP: "192.168.0.5", wifiSubnet: "255.255.255.0"), .wifi), "192.168.0.5/255.255.255.0")
        XCTAssertNil(DiagnosticNetwork(wifiIP: "192.168.0.5").subnet(.wifi), "서브넷을 아직 못 읽음")
        XCTAssertNil(DiagnosticNetwork(wifiSubnet: "255.255.255.0").subnet(.wifi))
    }

    func testEthernetTable() {
        // 장치: 대표 어댑터가 연결됨일 때만 · 대역: 그 서비스의 주소가 있으면 (게이트웨이 응답 없음도 주소는 있다)
        let rows: [(name: String, adapter: EthernetAdapter?, device: String?, subnet: String?)] = [
            ("어댑터 없음", nil, nil, nil),
            ("연결됨", ethernet("connected"), "en8", "192.168.0.2/255.255.255.0"),
            ("링크 없음", ethernet("noLink"), nil, nil),
            ("게이트웨이 응답 없음", ethernet("noGateway"), nil, "192.168.0.2/255.255.255.0"),
        ]
        for row in rows {
            let net = DiagnosticNetwork(ethernet: row.adapter, dns: dns(["en8": "192.168.0.1"]))
            XCTAssertEqual(net.device(.ethernet), row.device, row.name)
            XCTAssertEqual(subnetText(net, .ethernet), row.subnet, row.name)
            XCTAssertEqual(net.dnsServer(.ethernet), row.device == nil ? nil : "192.168.0.1", row.name)
        }
    }

    func testVPNTable() {
        // 장치·DNS: 첫 번째로 연결된 VPN 의 상세 (interface · dnsServers.first). 대역은 늘 nil (거르지 않음)
        let up = detail(interface: "utun7", dns: ["10.0.0.53"])
        let rows: [(name: String, vpns: [SystemVPN]?, details: [String: SystemVPNDetail], device: String?, dns: String?)] = [
            ("목록을 아직 못 읽음", nil, [:], nil, nil),
            ("VPN 없음", [], [:], nil, nil),
            ("꺼짐", [vpn("A", .disconnected)], ["A": up], nil, nil),
            ("연결 중", [vpn("A", .connecting)], ["A": up], nil, nil),
            ("연결됨 · 상세 전 (첫 VPN 을 막 켬)", [vpn("A", .connected)], [:], nil, nil),
            ("연결됨", [vpn("A", .connected)], ["A": up], "utun7", "10.0.0.53"),
            ("앞의 꺼진 것은 건너뜀", [vpn("B", .disconnected), vpn("A", .connected)], ["A": up, "B": detail(interface: "utun3")], "utun7", "10.0.0.53"),
            ("첫 연결된 것의 상세가 없으면 둘째로 넘어가지 않는다", [vpn("A", .connected), vpn("B", .connected)], ["B": up], nil, nil),
            ("인터페이스 전 · DNS 만 (장치가 없어 카드의 DNS 는 꺼진다)", [vpn("A", .connected)], ["A": detail(interface: nil, dns: ["10.0.0.53"])], nil, "10.0.0.53"),
            ("DNS 없는 VPN", [vpn("A", .connected)], ["A": detail(interface: "utun7")], "utun7", nil),
        ]
        for row in rows {
            // scoped DNS 에 utun 이 있어도 VPN 화면은 VPN 상세의 DNS 를 쓴다
            let net = DiagnosticNetwork(vpns: row.vpns, vpnDetails: row.details, dns: dns(["utun7": "100.100.100.100"]))
            XCTAssertEqual(net.device(.vpn), row.device, row.name)
            XCTAssertEqual(net.dnsServer(.vpn), row.dns, row.name)
            XCTAssertNil(net.subnet(.vpn), row.name)
        }
    }

    func testScreensDoNotBorrowEachOthersValues() {
        // 다른 화면의 값만 있으면 그 화면은 비어 있다 (같은 NIC 의 다른 서비스 값이 섞이지 않게)
        let net = DiagnosticNetwork(lan: lan(enabled: true), wifiInterface: "en0", wifiAssociated: true, wifiIP: "192.168.0.5", wifiSubnet: "255.255.255.0",
                                    dns: dns(["en10": "192.0.2.53", "en0": "192.168.0.1"]))
        XCTAssertEqual(net.device(.lan), "en10")
        XCTAssertEqual(net.device(.wifi), "en0")
        XCTAssertNil(net.device(.ethernet))
        XCTAssertNil(net.device(.vpn))
        XCTAssertNil(net.dnsServer(.ethernet))
        XCTAssertEqual(net.dnsServer(.wifi), "192.168.0.1")
    }
}
