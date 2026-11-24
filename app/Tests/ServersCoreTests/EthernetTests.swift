// Ethernet: 유선 서비스 고르기(내부망과 가르기)·ifconfig 파싱·대표 어댑터·링크 속도. 읽기 전용이라 명령은 networksetup·ifconfig 읽기뿐.

import Foundation
import XCTest
@testable import ServersCore

final class EthernetTests: XCTestCase {
    /// 어댑터 카드 만들기 — 운영과 같은 길 (WiredSnapshot.adapters). serviceInfo 를 안 준 서비스는 getinfo 가 장치의 첫 주소를 답한 경우
    /// (서비스가 하나인 장치). getinfo 를 못 읽은 경우는 testUnreadServiceInfoIsNoAddress
    private func makeAdapters(services: [LanServiceEntry], interfaces: [String: InterfaceState],
                          serviceInfo: [String: (ip: String?, mask: String?)] = [:]) -> [EthernetAdapter] {
        var infos: [String: ServiceInfo] = [:]
        for entry in services {
            if let given = serviceInfo[entry.name] {
                infos[entry.name] = ServiceInfo(ip: given.ip, mask: given.mask)
            } else if let interface = entry.device.flatMap({ interfaces[$0] }) {
                infos[entry.name] = ServiceInfo(ip: interface.ipv4, mask: interface.netmask)
            }
        }
        return WiredSnapshot(services: services, interfaces: interfaces, infos: infos).adapters(excluding: [])
    }

    /// 이 Mac 에서 실제로 받은 networksetup -listnetworkserviceorder (2026-10-11, 삼성 허브 유선을 꽂은 상태)
    let order = """
    An asterisk (*) denotes that a network service is disabled.
    (1) Samsung Hub NIC
    (Hardware Port: AX88179B, Device: en8)

    (*) iptime Hub NIC
    (Hardware Port: USB 10/100/1000 LAN, Device: en10)

    (2) Wi-Fi
    (Hardware Port: Wi-Fi, Device: en0)

    (*) Thunderbolt Bridge
    (Hardware Port: Thunderbolt Bridge, Device: bridge0)

    (*) iPhone USB 테더링
    (Hardware Port: iPhone USB, Device: en7)

    (*) Unicorn HTTPS
    (Hardware Port: com.unicorn-soft.unicornhttpsformac, Device: )

    (3) Tailscale
    (Hardware Port: io.tailscale.ipn.macsys, Device: )

    (*) acme ethernet
    (Hardware Port: USB 10/100/1000 LAN, Device: en10)

    """

    /// 같은 날 실제 ifconfig 의 en0·en8·bridge0 블록 (en10 은 없음 — 허브가 안 꽂힘)
    let ifconfig = """
    lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
    \tinet 127.0.0.1 netmask 0xff000000
    en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
    \toptions=6460<TSO4,TSO6,CHANNEL_IO,PARTIAL_CSUM,ZEROINVERT_CSUM>
    \tether aa:19:41:a6:b1:0a
    \tinet6 fe80::895:2f93:c71:3a39%en0 prefixlen 64 secured scopeid 0xe
    \tinet 192.168.0.241 netmask 0xffffff00 broadcast 192.168.0.255
    \tnd6 options=201<PERFORMNUD,DAD>
    \tmedia: autoselect
    \tstatus: active
    bridge0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
    \toptions=63<RXCSUM,TXCSUM,TSO4,TSO6>
    \tether 36:f7:cc:a7:b1:40
    \tConfiguration:
    \t\tid 0:0:0:0:0:0 priority 0 hellotime 0 fwddelay 0
    \tmember: en1 flags=3<LEARNING,DISCOVER>
    \t        ifmaxaddr 0 port 10 priority 0 path cost 0
    \tnd6 options=201<PERFORMNUD,DAD>
    \tmedia: <unknown type>
    \tstatus: inactive
    en8: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
    \toptions=404<VLAN_MTU,CHANNEL_IO>
    \tether 6c:6e:07:a2:b1:4c
    \tinet6 fe80::48:fe80:18d8:e2f5%en8 prefixlen 64 secured scopeid 0x1a
    \tinet 192.168.0.201 netmask 0xffffff00 broadcast 192.168.0.255
    \tnd6 options=201<PERFORMNUD,DAD>
    \tmedia: autoselect (1000baseT <full-duplex>)
    \tstatus: active
    """

    /// 허브는 꽂혔는데 케이블이 없는 en10 (USB 랜 어댑터의 링크 없음 형식)
    let en10NoLink = """
    en10: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
    \tether 00:e0:4c:a3:b1:37
    \tnd6 options=201<PERFORMNUD,DAD>
    \tmedia: autoselect (none)
    \tstatus: inactive
    """

    private let intranet: Set<String> = ["acme ethernet"]

    private func services(_ text: String, enabling: [String] = [], disabling: [String] = []) -> [LanServiceEntry] {
        NetworkInfoFetcher.parseAllServices(text).map { entry in
            let enabled = enabling.contains(entry.name) ? true : disabling.contains(entry.name) ? false : entry.enabled
            return LanServiceEntry(name: entry.name, hardwarePort: entry.hardwarePort, device: entry.device, enabled: enabled)
        }
    }

    // MARK: 어느 서비스가 Ethernet 인가

    func testWiredFilterKeepsOnlyUSBAndBuiltInEthernet() {
        let all = NetworkInfoFetcher.parseAllServices(order)
        XCTAssertEqual(all.filter(\.isWiredAdapter).map(\.name), ["Samsung Hub NIC", "iptime Hub NIC", "acme ethernet"],
                       "Wi-Fi·브리지·iPhone 테더링·장치 없는 VPN 은 유선이 아니다")
    }

    func testCurrentStateShowsOnlySamsungHub() {
        // 실제 상태: en10 의 두 서비스가 모두 꺼져 있다 → Samsung Hub NIC 만
        let picked = Ethernet.services(services(order), intranet: intranet)
        XCTAssertEqual(picked.map(\.name), ["Samsung Hub NIC"])
    }

    /// 서비스 기준 (2026-10-15): Intranet 으로 지정한 서비스 하나만 뺀다 — 같은 장치(en10)의 다른 서비스는 내부망이 켜져 있어도 남는다
    /// (예전엔 내부망이 켜진 장치째 빼서 같은 NIC 의 인터넷 서비스 iptime Hub NIC 까지 사라졌다)
    func testOnlyTheIntranetServiceIsExcluded() {
        let iptimeOn = Ethernet.services(services(order, enabling: ["iptime Hub NIC"]), intranet: intranet)
        XCTAssertEqual(iptimeOn.map(\.name), ["Samsung Hub NIC", "iptime Hub NIC"])
        let intranetOn = Ethernet.services(services(order, enabling: ["iptime Hub NIC", "acme ethernet"]), intranet: intranet)
        XCTAssertEqual(intranetOn.map(\.name), ["Samsung Hub NIC", "iptime Hub NIC"])
        let onlyIntranet = Ethernet.services(services(order, enabling: ["acme ethernet"]), intranet: intranet)
        XCTAssertEqual(onlyIntranet.map(\.name), ["Samsung Hub NIC"])
    }

    /// 같은 장치에 서비스가 둘이면 주소는 그 서비스의 IP — 장치의 첫 주소가 다른 서비스 것이어도
    func testServiceAddressOnSharedDevice() {
        let en10 = InterfaceState(ipv4: "10.50.10.17", netmask: "255.255.255.0", active: true, addresses: ["10.50.10.17", "172.30.1.149"])
        let iptime = LanServiceEntry(name: "iptime Hub NIC", hardwarePort: "USB 10/100/1000 LAN", device: "en10", enabled: true)
        let withIP = makeAdapters(services: [iptime], interfaces: ["en10": en10], serviceInfo: ["iptime Hub NIC": ("172.30.1.149", "255.255.255.0")])
        XCTAssertEqual(withIP.first?.address, "172.30.1.149")
        XCTAssertEqual(withIP.first?.state, .connected)
        let noLease = makeAdapters(services: [iptime], interfaces: ["en10": en10], serviceInfo: ["iptime Hub NIC": ("172.30.1.200", nil)])
        XCTAssertEqual(noLease.first?.state, .noAddress, "그 서비스의 IP 가 장치에 없으면 주소 없음")
        // getinfo 를 읽었는데 IP 가 없다(내부망 선에서 DHCP 실패) — 같은 장치의 다른 서비스 주소를 끌어오지 않는다
        let empty = makeAdapters(services: [iptime], interfaces: ["en10": en10], serviceInfo: ["iptime Hub NIC": (nil, nil)])
        XCTAssertNil(empty.first?.address)
        XCTAssertEqual(empty.first?.state, .noAddress)
        XCTAssertNil(empty.first?.netmask)
        // 대표: 인터넷이 나가는 서비스가 먼저
        let samsung = EthernetAdapter(service: "Samsung Hub NIC", hardwarePort: nil, device: "en8", interface: InterfaceState(ipv4: "192.168.0.2", active: true),
                                      info: ServiceInfo(ip: "192.168.0.2"))
        XCTAssertEqual(Ethernet.primary([samsung] + withIP, internetService: "iptime Hub NIC", defaultRoute: "utun7")?.service, "iptime Hub NIC")
    }

    /// getinfo 를 못 읽은 서비스(스냅숏 infos 에 없음)는 주소 없음 — 장치에 붙은 주소를 이 서비스 것으로 끌어오지 않는다.
    /// 어댑터 카드(adapters)와 서비스 카드(link)가 같은 판정
    func testUnreadServiceInfoIsNoAddress() async {
        let en10 = InterfaceState(ipv4: "10.50.10.17", netmask: "255.255.255.0", active: true, addresses: ["10.50.10.17", "172.30.1.149"])
        let iptime = LanServiceEntry(name: "iptime Hub NIC", hardwarePort: "USB 10/100/1000 LAN", device: "en10", enabled: true)
        let snapshot = WiredSnapshot(services: [iptime], interfaces: ["en10": en10])
        let adapter = snapshot.adapters(excluding: []).first
        XCTAssertNotNil(adapter, "어댑터는 꽂혀 있으니 카드는 있다")
        XCTAssertNil(adapter?.address)
        XCTAssertNil(adapter?.netmask)
        XCTAssertEqual(adapter?.state, .noAddress)
        XCTAssertEqual(snapshot.link(iptime), .noAddress)

        // 수집까지: -getinfo 가 실패(빈 출력)해도 같은 결과
        let runner = FakeRunner()
        runner.scripted["networksetup -listnetworkserviceorder"] = CommandResult(exitCode: 0, stdout: "(1) iptime Hub NIC\n(Hardware Port: USB 10/100/1000 LAN, Device: en10)\n")
        runner.scripted["ifconfig"] = CommandResult(exitCode: 0, stdout: "en10: flags=8863<UP> mtu 1500\n\tinet 10.50.10.17 netmask 0xffffff00\n\tstatus: active\n")
        runner.scripted["networksetup -getinfo iptime Hub NIC"] = CommandResult(exitCode: 1)
        let fetched = await WiredSnapshot.fetch(runner: runner)
        XCTAssertEqual(fetched.adapters(excluding: []).map(\.state), [.noAddress])
        XCTAssertFalse(runner.calls.contains { $0.executable == "ping" }, "수동 IP 인지 모르면 게이트웨이도 묻지 않는다")
    }

    func testWithoutIntranetConfigEveryEnabledWiredServiceIsEthernet() {
        let picked = Ethernet.services(services(order, enabling: ["acme ethernet"]), intranet: [])
        XCTAssertEqual(picked.map(\.name), ["Samsung Hub NIC", "acme ethernet"])
    }

    func testDisabledSamsungHubIsNotShown() {
        XCTAssertTrue(Ethernet.services(services(order, disabling: ["Samsung Hub NIC"]), intranet: intranet).isEmpty)
    }

    // MARK: ifconfig

    func testParseInterfaces() {
        let map = Ethernet.parseInterfaces(ifconfig)
        let en8 = map["en8"]!
        XCTAssertEqual(en8.mac, "6c:6e:07:a2:b1:4c")
        XCTAssertEqual(en8.ipv4, "192.168.0.201")
        XCTAssertEqual(en8.netmask, "255.255.255.0")
        XCTAssertEqual(en8.media, "1000baseT <full-duplex>")
        XCTAssertTrue(en8.active)
        XCTAssertEqual(map["en0"]?.media, "Autoselect")
        XCTAssertEqual(map["bridge0"]?.active, false)
        XCTAssertNil(map["bridge0"]?.ipv4, "member 줄의 들여쓴 내용은 장치 줄로 보지 않는다")
        XCTAssertNil(map["member"])
        XCTAssertNil(map["en10"])

        let noLink = Ethernet.parseInterfaces(en10NoLink)["en10"]!
        XCTAssertFalse(noLink.active); XCTAssertNil(noLink.media); XCTAssertNil(noLink.ipv4)
        XCTAssertTrue(Ethernet.parseInterfaces("").isEmpty)
    }

    func testRealMAC() {
        XCTAssertEqual(Ethernet.realMAC("6c:6e:07:a2:b1:4c"), "6c:6e:07:a2:b1:4c")
        XCTAssertNil(Ethernet.realMAC("02:00:00:00:00:00"), "앱 안 ifconfig 가 받는 가린 값")
        XCTAssertNil(Ethernet.realMAC("(null)")); XCTAssertNil(Ethernet.realMAC(nil)); XCTAssertNil(Ethernet.realMAC(""))
        // 이 Mac 의 실제 networksetup -getinfo (연결 · 어댑터 없음)
        let connected = "DHCP Configuration\nIP address: 192.168.0.201\nSubnet mask: 255.255.255.0\nRouter: 192.168.0.1\nClient ID: \nIPv6: Automatic\nIPv6 IP address: none\nIPv6 Router: none\nEthernet Address: 6c:6e:07:a2:b1:4c\n"
        XCTAssertEqual(Ethernet.parseMAC(getInfo: connected), "6c:6e:07:a2:b1:4c")
        let absent = "(Please note: iptime Hub NIC is currently disabled)\nDHCP Configuration\nClient ID: \nIPv6: Automatic\nEthernet Address: (null)\n"
        XCTAssertNil(Ethernet.parseMAC(getInfo: absent))
    }

    func testDottedMask() {
        XCTAssertEqual(Ethernet.dottedMask(hex: "0xffffff00"), "255.255.255.0")
        XCTAssertEqual(Ethernet.dottedMask(hex: "0xfffffe00"), "255.255.254.0")
        XCTAssertEqual(Ethernet.dottedMask(hex: "0xff000000"), "255.0.0.0")
        XCTAssertNil(Ethernet.dottedMask(hex: "255.255.255.0"))
        XCTAssertNil(Ethernet.dottedMask(hex: "0xzz"))
        XCTAssertEqual(IPv4.dotted(0x0A320A11), "10.50.10.17", "parse 의 반대")
        XCTAssertEqual(IPv4.parse(IPv4.dotted(0xC0A80001)).map(IPv4.dotted), "192.168.0.1")
    }

    // MARK: 상태·대표

    func testStates() {
        let picked = Ethernet.services(services(order, enabling: ["iptime Hub NIC"]), intranet: intranet)
        // en8 연결 · en10 허브 안 꽂힘 → en10 은 목록에서 빠진다
        var adapters = makeAdapters(services: picked, interfaces: Ethernet.parseInterfaces(ifconfig))
        XCTAssertEqual(adapters.map(\.device), ["en8"])
        XCTAssertEqual(adapters.map(\.state), [.connected])
        // en10 허브만 꽂힘 (케이블 없음)
        adapters = makeAdapters(services: picked, interfaces: Ethernet.parseInterfaces(ifconfig + "\n" + en10NoLink))
        XCTAssertEqual(adapters.map(\.state), [.connected, .noLink])
        // 링크는 있는데 주소 없음 (DHCP 실패)
        let noAddress = ["en8": InterfaceState(mac: "6c:6e:07:a2:b1:4c", media: "1000baseT <full-duplex>", active: true)]
        XCTAssertEqual(makeAdapters(services: picked, interfaces: noAddress).first?.state, .noAddress)
        // DHCP 를 못 받으면 macOS 가 몇 초 뒤 스스로 붙이는 169.254.x.x 도 주소 없음 — 초록 "연결됨" 이 아니다
        let selfAssigned = ["en8": InterfaceState(ipv4: "169.254.12.34", netmask: "255.255.0.0", active: true)]
        XCTAssertEqual(makeAdapters(services: picked, interfaces: selfAssigned).first?.state, .noAddress)
        let selfAssignedText = "en8: flags=8863<UP> mtu 1500\n\tinet 169.254.12.34 netmask 0xffff0000 broadcast 169.254.255.255\n\tstatus: active\n"
        XCTAssertEqual(makeAdapters(services: picked, interfaces: Ethernet.parseInterfaces(selfAssignedText)).first?.state, .noAddress)
    }

    /// 2026-10-13 실제 상태: 한 번 꽂았던 허브 서비스 셋이 켜진 채 남아 있고 장치는 하나도 안 꽂힘 → 카드 없음
    func testUnpluggedAdaptersAreNotShown() {
        let order = """
        An asterisk (*) denotes that a network service is disabled.
        (1) TPlink 2.5G Ethernet
        (Hardware Port: USB 10/100/1G/2.5G LAN, Device: en11)

        (2) Samsung Hub NIC
        (Hardware Port: AX88179B, Device: en8)

        (3) iptime Hub NIC
        (Hardware Port: USB 10/100/1000 LAN, Device: en10)

        (4) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)

        (*) acme ethernet
        (Hardware Port: USB 10/100/1000 LAN, Device: en10)

        """
        let picked = Ethernet.services(services(order), intranet: intranet)
        XCTAssertEqual(picked.map(\.name), ["TPlink 2.5G Ethernet", "Samsung Hub NIC", "iptime Hub NIC"], "서비스로는 셋 다 Ethernet 몫")
        let lo0 = "lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384\n\tinet 127.0.0.1 netmask 0xff000000\n"
        XCTAssertTrue(makeAdapters(services: picked, interfaces: Ethernet.parseInterfaces(lo0)).isEmpty)
        // TPlink 만 꽂으면(케이블 없음) 그 하나만
        let en11 = "en11: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n\tmedia: autoselect (none)\n\tstatus: inactive\n"
        let one = makeAdapters(services: picked, interfaces: Ethernet.parseInterfaces(lo0 + en11))
        XCTAssertEqual(one.map(\.service), ["TPlink 2.5G Ethernet"])
        XCTAssertEqual(one.map(\.state), [.noLink])
    }

    func testPrimaryOrder() {
        let picked = Ethernet.services(services(order, enabling: ["iptime Hub NIC"]), intranet: intranet)
        let en8 = InterfaceState(ipv4: "192.168.0.201", active: true)
        let en10 = InterfaceState(ipv4: "192.168.0.202", active: true)
        let both = makeAdapters(services: picked, interfaces: ["en8": en8, "en10": en10])
        XCTAssertEqual(Ethernet.primary(both, defaultRoute: "en10")?.device, "en10", "둘 다 연결이면 기본 경로 쪽")
        XCTAssertEqual(Ethernet.primary(both, defaultRoute: "en0")?.device, "en8", "기본 경로가 Wi-Fi 면 서비스 순서 첫 연결")
        // 기본 경로라고 남아 있어도 링크가 없으면 고르지 않는다 (경로 값은 화면을 볼 때만 갱신돼 낡을 수 있다)
        let routeStale = makeAdapters(services: picked, interfaces: ["en8": en8, "en10": InterfaceState(active: false)])
        XCTAssertEqual(Ethernet.primary(routeStale, defaultRoute: "en10")?.device, "en8")
        // 연결된 게 없으면: 링크 → 첫 번째
        let linkOnly = makeAdapters(services: picked, interfaces: ["en10": InterfaceState(active: true)])
        XCTAssertEqual(Ethernet.primary(linkOnly, defaultRoute: nil)?.device, "en10")
        let presentOnly = makeAdapters(services: picked, interfaces: ["en10": InterfaceState()])
        XCTAssertEqual(Ethernet.primary(presentOnly, defaultRoute: nil)?.device, "en10")
        let nothing = makeAdapters(services: picked, interfaces: [:])
        XCTAssertNil(Ethernet.primary(nothing, defaultRoute: nil), "꽂힌 어댑터가 없으면 대표도 없다 (행은 \"연결 안 됨\")")
        XCTAssertNil(Ethernet.primary([], defaultRoute: "en8"))
    }

    // MARK: 링크 속도

    func testSpeed() {
        XCTAssertEqual(Ethernet.speedMbps(media: "1000baseT <full-duplex>"), 1000)
        XCTAssertEqual(Ethernet.speedMbps(media: "100baseTX <full-duplex,flow-control>"), 100)
        XCTAssertEqual(Ethernet.speedMbps(media: "2500Base-T <full-duplex>"), 2500)
        XCTAssertEqual(Ethernet.speedMbps(media: "10GBase-T <full-duplex>"), 10000)
        XCTAssertEqual(Ethernet.speedMbps(media: "10baseT/UTP <half-duplex>"), 10)
        XCTAssertNil(Ethernet.speedMbps(media: "Autoselect"))
        XCTAssertNil(Ethernet.speedMbps(media: nil))

        XCTAssertTrue(Ethernet.speedText(mbps: 1000) == ("1", "Gbps"))
        XCTAssertTrue(Ethernet.speedText(mbps: 2500) == ("2.5", "Gbps"))
        XCTAssertTrue(Ethernet.speedText(mbps: 100) == ("100", "Mbps"))
        XCTAssertEqual(Ethernet.speedLabel(mbps: 2500), "2.5 Gbps")
        XCTAssertEqual(Ethernet.speedLabel(mbps: 10000), "10 Gbps")
        XCTAssertEqual(Ethernet.speedLabel(mbps: 100), "100 Mbps")

        XCTAssertEqual(Ethernet.duplex(media: "1000baseT <full-duplex>"), "full-duplex")
        XCTAssertEqual(Ethernet.duplex(media: "100baseTX <full-duplex,flow-control>"), "full-duplex")
        XCTAssertEqual(Ethernet.duplex(media: "10baseT/UTP <half-duplex>"), "half-duplex")
        XCTAssertNil(Ethernet.duplex(media: "Autoselect"))
    }

    /// 링크 타일 경고: 1 Gbps 미만 또는 half-duplex. duplex 표기가 없으면(Autoselect) 속도만 본다
    func testLinkWarnsTable() {
        let rows: [(Int, String?, Bool)] = [
            (1000, "full-duplex", false),
            (2500, "full-duplex", false),
            (10000, nil, false),
            (1000, nil, false),
            (999, "full-duplex", true),
            (100, "full-duplex", true),
            (10, nil, true),
            (1000, "half-duplex", true),
            (2500, "half-duplex", true),
            (100, "half-duplex", true),
        ]
        for (mbps, duplex, warns) in rows {
            XCTAssertEqual(Ethernet.linkWarns(mbps: mbps, duplex: duplex), warns, "\(mbps) · \(duplex ?? "nil")")
        }
        // 실제 media 표기에서 (speedMbps·duplex 를 거쳐)
        let media: [(String, Bool)] = [
            ("1000baseT <full-duplex>", false), ("100baseTX <full-duplex,flow-control>", true),
            ("10baseT/UTP <half-duplex>", true), ("2500Base-T <full-duplex>", false), ("1000baseT <half-duplex>", true),
        ]
        for (text, warns) in media {
            XCTAssertEqual(Ethernet.speedMbps(media: text).map { Ethernet.linkWarns(mbps: $0, duplex: Ethernet.duplex(media: text)) }, warns, text)
        }
    }

    // MARK: 수집 (읽기 전용)

    /// 스냅숏 한 번: 서비스 순서 · ifconfig · 활성 유선 서비스마다 getinfo — 읽기만 (활성화·비활성화·sudo 없음)
    func testSnapshotFetchRunsOnlyReadCommands() async {
        let runner = FakeRunner()
        runner.scripted["networksetup -listnetworkserviceorder"] = CommandResult(exitCode: 0, stdout: order)
        runner.scripted["ifconfig"] = CommandResult(exitCode: 0, stdout: ifconfig)
        runner.scripted["networksetup -getinfo Samsung Hub NIC"] = CommandResult(exitCode: 0, stdout: "DHCP Configuration\nIP address: 192.168.0.201\nSubnet mask: 255.255.255.0\nRouter: 192.168.0.1\n")
        let snapshot = await WiredSnapshot.fetch(runner: runner)
        let adapters = snapshot.adapters(excluding: intranet)
        XCTAssertEqual(adapters.map(\.service), ["Samsung Hub NIC"])
        XCTAssertEqual(adapters.first?.state, .connected)
        XCTAssertEqual(adapters.first?.address, "192.168.0.201", "그 서비스의 IP (getinfo)")
        XCTAssertEqual(adapters.first?.info?.router, "192.168.0.1")
        XCTAssertEqual(runner.calls.map { ([$0.executable] + $0.arguments).joined(separator: " ") },
                       ["networksetup -listnetworkserviceorder", "ifconfig", "networksetup -getinfo Samsung Hub NIC"],
                       "활성화·비활성화(-setnetworkserviceenabled)나 sudo 없이 읽기만 (DHCP 라 게이트웨이 ping 도 없음)")
    }

    func testFetchWhenCommandsFail() async {
        let runner = FakeRunner()
        runner.scripted["networksetup -listnetworkserviceorder"] = CommandResult(exitCode: 1, stdout: "")
        runner.scripted["ifconfig"] = CommandResult(exitCode: 1, stdout: "")
        let snapshot = await WiredSnapshot.fetch(runner: runner)
        XCTAssertTrue(snapshot.adapters(excluding: intranet).isEmpty)
        XCTAssertTrue(snapshot.services.isEmpty)
    }
}
