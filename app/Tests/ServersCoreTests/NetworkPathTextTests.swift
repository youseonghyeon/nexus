import Foundation
@testable import ServersCore
import XCTest

final class NetworkPathTextTests: XCTestCase {
    private let services = [
        LanServiceEntry(name: "Wi-Fi", hardwarePort: "Wi-Fi", device: "en0", enabled: true),
        LanServiceEntry(name: "Office LAN", hardwarePort: "USB 10/100/1000 LAN", device: "en11", enabled: true),
        // 같은 장치에 서비스가 둘 (꺼진 것이 먼저) — 켜진 것을 본다
        LanServiceEntry(name: "Old", hardwarePort: "USB 10/100/1000 LAN", device: "en10", enabled: false),
        LanServiceEntry(name: "Acme Intranet", hardwarePort: "USB 10/100/1000 LAN", device: "en10", enabled: true),
        LanServiceEntry(name: "Thunderbolt Bridge", hardwarePort: "Thunderbolt Bridge", device: "bridge0", enabled: true),
        LanServiceEntry(name: "iPhone USB", hardwarePort: "iPhone USB", device: "en7", enabled: true),
        LanServiceEntry(name: "Office VPN", hardwarePort: nil, device: nil, enabled: true),
    ]

    func testRouteNamesTheDeviceLikeTheSidebar() {
        func route(_ device: String) -> String { NetworkPathText.route(device: device, services: services) }
        XCTAssertEqual(route("en0"), "Wi-Fi (en0)")
        XCTAssertEqual(route("en11"), "Ethernet (en11)", "유선은 어댑터 이름이 아니라 사이드바 행 이름")
        XCTAssertEqual(route("en10"), "Ethernet (en10)")
        XCTAssertEqual(route("en7"), "iPhone USB (en7)", "Wi-Fi·유선이 아닌 서비스는 어댑터 이름")
        XCTAssertEqual(route("bridge0"), "Thunderbolt Bridge (bridge0)")
        XCTAssertEqual(route("utun6"), "utun6", "서비스 목록에 없는 장치는 그대로")
        XCTAssertEqual(NetworkPathText.route(device: "en11", services: []), "en11", "서비스 목록을 아직 못 읽었을 때")
    }

    /// 줄 전체 표: 망 종류 × 장치를 아는가 × VPN 이름
    func testTextTable() {
        func text(_ network: ServerNetwork, _ name: String, vpn: String? = nil, device: String?) -> String {
            NetworkPathText.text(network: network, networkName: name, vpn: vpn, device: device, services: services)
        }
        XCTAssertEqual(text(.direct, "Direct", device: "en11"), "Ethernet (en11)", "Direct 는 나가는 길만")
        XCTAssertEqual(text(.direct, "Direct", device: "en0"), "Wi-Fi (en0)")
        XCTAssertEqual(text(.direct, "Direct", device: nil), "Direct", "길을 모르면 망 이름 — 줄이 비지 않는다")
        XCTAssertEqual(text(.direct, "Direct", device: ""), "Direct")
        XCTAssertEqual(text(.lan, "Intranet", device: "en10"), "Intranet · Ethernet (en10)")
        XCTAssertEqual(text(.lan, "Intranet", device: nil), "Intranet")
        XCTAssertEqual(text(.tailscale, "Tailscale VPN", device: "utun4"), "Tailscale VPN · utun4")
        XCTAssertEqual(text(.vpn, "VPN", vpn: "Office", device: "utun6"), "VPN · Office · utun6")
        XCTAssertEqual(text(.vpn, "VPN", vpn: "Office", device: nil), "VPN · Office", "vpn 은 묶을 utun 이 없으면 장치를 모른다")
    }
}
