// NetworkInfoFetcher: tailscale status·networksetup 출력 파서.

import Foundation
import XCTest
@testable import ServersCore

final class NetworkInfoTests: XCTestCase {
    /// 이 Mac 에서 실제로 받은 출력 형식 (값만 바꿈)
    func testParseTailscaleStatus() {
        let json = """
        {"BackendState":"Running","Version":"1.102.4-t3caf7d9e7-g084ee3b64",
         "Self":{"HostName":"My MacBook","DNSName":"macbook.tail1234.ts.net.","TailscaleIPs":["100.101.1.0","fd7a:115c:a1e0::3333:4444"],"Online":true},
         "CurrentTailnet":{"Name":"me@example.com","MagicDNSSuffix":"tail1234.ts.net","MagicDNSEnabled":true},
         "Peer":{"k1":{"HostName":"nexus","DNSName":"nexus.tail1234.ts.net.","TailscaleIPs":["100.64.0.1"],"Online":true},
                 "k2":{"HostName":"win","DNSName":"win.tail1234.ts.net.","TailscaleIPs":["100.64.0.2"],"Online":false},
                 "k3":{"HostName":"argocd","TailscaleIPs":["100.64.0.9"],"Online":true}}}
        """
        let info = NetworkInfoFetcher.parseTailscaleStatus(json)!
        XCTAssertEqual(info.backendState, "Running")
        XCTAssertEqual(info.shortVersion, "1.102.4")
        XCTAssertEqual(info.hostName, "My MacBook")
        XCTAssertEqual(info.shortDNSName, "macbook.tail1234.ts.net")
        XCTAssertEqual(info.ipv4, "100.101.1.0")
        XCTAssertEqual(info.ipv6, "fd7a:115c:a1e0::3333:4444")
        XCTAssertEqual(info.tailnet, "me@example.com")
        XCTAssertEqual(info.peers.map(\.hostName), ["argocd", "nexus", "win"], "online 먼저, 이름순")
        XCTAssertEqual(info.peers.filter(\.online).count, 2)
        XCTAssertNil(NetworkInfoFetcher.parseTailscaleStatus("not json"))
    }

    func testParseNetworksetupOutputs() {
        let info = NetworkInfoFetcher.parseGetInfo("Manual Configuration\nIP address: 10.50.10.17\nSubnet mask: 255.255.255.0\nRouter: 10.50.10.254\nIPv6: Off\nEthernet Address: 00:e0:4c:a3:b1:37\n")
        XCTAssertEqual(info.configuration, "Manual Configuration")
        XCTAssertEqual(info.ip, "10.50.10.17"); XCTAssertEqual(info.mask, "255.255.255.0"); XCTAssertEqual(info.router, "10.50.10.254")
        let dhcp = NetworkInfoFetcher.parseGetInfo("DHCP Configuration\nIP address: none\nSubnet mask: \nRouter: none\n")
        XCTAssertEqual(dhcp.configuration, "DHCP Configuration"); XCTAssertNil(dhcp.ip); XCTAssertNil(dhcp.router)
        let pending = NetworkInfoFetcher.parseGetInfo("DHCP Configuration\nIP address: (null)\nSubnet mask: (null)\nRouter: (null)\n")
        XCTAssertNil(pending.ip); XCTAssertNil(pending.mask); XCTAssertNil(pending.router, "DHCP 대기 중의 (null) 은 값이 아니다")
    }

    func testPrefixLength() {
        XCTAssertEqual(NetworkInfoFetcher.prefixLength(mask: "255.255.255.0"), 24)
        XCTAssertEqual(NetworkInfoFetcher.prefixLength(mask: "255.255.0.0"), 16)
        XCTAssertEqual(NetworkInfoFetcher.prefixLength(mask: "255.255.255.255"), 32)
        XCTAssertEqual(NetworkInfoFetcher.prefixLength(mask: "0.0.0.0"), 0)
        XCTAssertNil(NetworkInfoFetcher.prefixLength(mask: "255.0.255.0"), "비연속 마스크")
        XCTAssertNil(NetworkInfoFetcher.prefixLength(mask: "abc"))
    }

    /// 수집: 서비스·장치·주소. 서비스가 꺼져 있으면 실제 IP 를 묻지 않는다. 추가 경로는 더 이상 읽지 않는다.
    func testLanInfoReadsServiceAndAddress() async {
        let runner = FakeRunner()
        runner.lanEnabled = true
        // 같은 NIC 에 서비스가 둘: 장치의 첫 주소는 다른 서비스(172.30.1.149) — 이 서비스의 IP 가 붙었는지로 본다
        runner.ifconfigOutput = "en9: flags=8863<UP>\n\tinet 172.30.1.149 netmask 0xffffff00\n\tinet 10.50.10.17 netmask 0xffffff00\n\tstatus: active\n"
        let lan = LanNetwork(service: "Test Ethernet")
        let info = await NetworkInfoFetcher.lan(lan, runner: runner)
        XCTAssertTrue(info.enabled)
        XCTAssertEqual(info.device, "en9"); XCTAssertEqual(info.hardwarePort, "Ethernet")
        XCTAssertEqual(info.router, "10.50.10.254"); XCTAssertEqual(info.actualIP, "10.50.10.17")
        XCTAssertFalse(runner.calls.contains { $0.executable == "ipconfig" }, "장치 첫 주소(getifaddr)는 쓰지 않는다")
        runner.ifconfigOutput = "en9: flags=8863<UP>\n\tinet 172.30.1.149 netmask 0xffffff00\n\tstatus: active\n"
        let notAttached = await NetworkInfoFetcher.lan(lan, runner: runner)
        XCTAssertNil(notAttached.actualIP, "다른 서비스 주소만 있으면 이 서비스는 미적용")
        XCTAssertFalse(runner.calls.contains { $0.arguments.first == "-getadditionalroutes" }, "분할 라우팅은 없어졌다")
        runner.lanEnabled = false
        let off = await NetworkInfoFetcher.lan(lan, runner: runner)
        XCTAssertFalse(off.enabled)
        XCTAssertNil(off.actualIP)
    }

    /// Wi-Fi 서비스 이름은 장치로 찾는다 — 이름을 바꿨거나 다른 언어로 만든 Mac 에서 "Wi-Fi" 로 -getinfo 하면 값이 비었다
    func testServiceNameForDevice() {
        let services = NetworkInfoFetcher.parseAllServices("(1) 사무실 무선\n(Hardware Port: Wi-Fi, Device: en0)\n(2) Acme Intranet\n(Hardware Port: USB LAN, Device: en10)\n")
        XCTAssertEqual(NetworkInfoFetcher.serviceName(forDevice: "en0", in: services), "사무실 무선")
        XCTAssertEqual(NetworkInfoFetcher.serviceName(forDevice: "en10", in: services), "Acme Intranet")
        XCTAssertEqual(NetworkInfoFetcher.serviceName(forDevice: "en7", in: services), "Wi-Fi", "못 찾으면 기본 이름")
        XCTAssertEqual(NetworkInfoFetcher.serviceName(forDevice: nil, in: []), "Wi-Fi")
        let two = NetworkInfoFetcher.parseAllServices("(*) 옛 무선\n(Hardware Port: Wi-Fi, Device: en0)\n(2) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en0)\n")
        XCTAssertEqual(NetworkInfoFetcher.serviceName(forDevice: "en0", in: two), "Wi-Fi", "같은 장치에 서비스가 둘이면 켜진 것")
    }

    /// 서비스 목록: 번호(활성)·'*'(비활성) 항목을 순서대로, 하드웨어 포트·장치까지. 기타 줄은 무시.
    func testParseAllServicesListsEnabledAndDisabled() {
        let text = """
        An asterisk (*) denotes that a network service is disabled.
        (1) Samsung Hub NIC
        (Hardware Port: AX88179B, Device: en8)

        (*) iptime Hub NIC
        (Hardware Port: USB 10/100/1000 LAN, Device: en10)

        (2) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)

        (3) Acme Intranet
        (Hardware Port: USB 10/100/1000 LAN, Device: en10)

        (*) Unicorn HTTPS
        """
        let list = NetworkInfoFetcher.parseAllServices(text)
        XCTAssertEqual(list.map(\.name), ["Samsung Hub NIC", "iptime Hub NIC", "Wi-Fi", "Acme Intranet", "Unicorn HTTPS"])
        XCTAssertEqual(list.map(\.enabled), [true, false, true, true, false])
        XCTAssertEqual(list[3], LanServiceEntry(name: "Acme Intranet", hardwarePort: "USB 10/100/1000 LAN", device: "en10", enabled: true))
        XCTAssertEqual(list[3].label, "Acme Intranet · USB 10/100/1000 LAN (en10)")
        XCTAssertEqual(list[4], LanServiceEntry(name: "Unicorn HTTPS", hardwarePort: nil, device: nil, enabled: false))
    }
}
