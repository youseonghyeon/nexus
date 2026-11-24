// ifconfig 출력을 읽는 세 곳(Ethernet.parseInterfaces · LocalCommands.parseInterfaceAddresses · RouteTable.parseInterfaceDetails)이
// 같은 글에서 각자 내는 값. 장치 덩이를 나누는 일은 Ifconfig 하나가 하고, 무엇을 고르는지는 곳마다 다르다 — 그 차이를 고정한다
// (2026-11-24 파서를 하나로 모으기 전에 넣은 테스트). 주소·MAC 은 문서용 값.

import Foundation
import XCTest
@testable import ServersCore

final class IfconfigTests: XCTestCase {
    /// 머리 줄 앞의 내용 줄 · lo0 · 주소 둘인 장치 · 주소 없는 장치 · 이름이 두 번 나오는 장치 · 들여쓰기 없이 콜론이 있는 줄
    private let text = """
    \tinet 198.51.100.9 netmask 0xffffff00 broadcast 198.51.100.255
    lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
    \toptions=1203<RXCSUM,TXCSUM,TXSTATUS,SW_TIMESTAMP>
    \tinet 127.0.0.1 netmask 0xff000000
    \tinet6 ::1 prefixlen 128
    en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
    \tether 02:00:5e:00:53:01
    \tinet6 fe80::1%en0 prefixlen 64 secured scopeid 0xe
    \tinet 192.0.2.10 netmask 0xffffff00 broadcast 192.0.2.255
    \tinet 203.0.113.7 netmask 0xfffffffc broadcast 203.0.113.7
    \tmedia: autoselect (1000baseT <full-duplex>)
    \tstatus: active
    bridge0: flags=8822<BROADCAST,SMART,SIMPLEX,MULTICAST> mtu 1500
    \tether 02:00:5e:00:53:02
    \tConfiguration:
    \t\tid 0:0:0:0:0:0 priority 0 hellotime 0 fwddelay 0
    \tmember: en1 flags=3<LEARNING,DISCOVER>
    \tstatus: inactive
    utun3: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
       inet 100.64.0.5 --> 100.64.0.5 netmask 0xffffffff
    en5: flags=8863<UP> mtu 9000
    \tinet 198.51.100.20 netmask 0xffffff00
    en5: flags=8863<UP>
    \tinet 198.51.100.21 netmask 0xffff0000
    status: active
    """

    func testEthernetStates() {
        let map = Ethernet.parseInterfaces(text)
        XCTAssertEqual(Set(map.keys), ["lo0", "en0", "bridge0", "utun3", "en5", "status"], "머리 줄 앞의 줄은 버린다 · 들여쓰기 없이 콜론이 있는 줄은 장치 줄")
        XCTAssertEqual(map["lo0"], InterfaceState(ipv4: "127.0.0.1", netmask: "255.0.0.0", addresses: ["127.0.0.1"]))
        XCTAssertEqual(map["en0"], InterfaceState(mac: "02:00:5e:00:53:01", ipv4: "192.0.2.10", netmask: "255.255.255.0", media: "1000baseT <full-duplex>", active: true,
                                                  addresses: ["192.0.2.10", "203.0.113.7"]), "첫 주소와 그 마스크 · 주소는 전부")
        XCTAssertEqual(map["bridge0"], InterfaceState(mac: "02:00:5e:00:53:02"))
        XCTAssertEqual(map["utun3"], InterfaceState(ipv4: "100.64.0.5", netmask: "255.255.255.255", addresses: ["100.64.0.5"]), "공백으로 들여쓴 줄도 내용")
        XCTAssertEqual(map["en5"], InterfaceState(ipv4: "198.51.100.21", netmask: "255.255.0.0", addresses: ["198.51.100.21"]), "같은 이름이 다시 나오면 새로 시작")
        XCTAssertEqual(map["status"], InterfaceState())
    }

    func testEthernetTreatsAnyUnindentedColonLineAsDevice() {
        // 들여쓰기 없이 콜론이 있는 줄은 무엇이든 장치 줄이다 ("status" 라는 장치가 생긴다)
        let map = Ethernet.parseInterfaces("en0: flags=1 mtu 1500\nstatus: active\n\tinet 192.0.2.1 netmask 0xffffff00\nplain line\n\tether 02:00:5e:00:53:03")
        XCTAssertEqual(map["en0"], InterfaceState())
        XCTAssertEqual(map["status"], InterfaceState(mac: "02:00:5e:00:53:03", ipv4: "192.0.2.1", netmask: "255.255.255.0", addresses: ["192.0.2.1"]))
        XCTAssertEqual(Ethernet.parseInterfaces(":x\n\tinet 192.0.2.2 netmask 0xffffff00")[""]?.ipv4, "192.0.2.2", "빈 이름도 장치로")
    }

    func testLocalAddressPairs() {
        let pairs = LocalCommands.parseInterfaceAddresses(text)
        XCTAssertEqual(pairs.map(\.device), ["", "en0", "en0", "utun3", "en5", "en5"], "나온 순서 · lo0 은 뺀다 · 머리 줄 앞의 주소는 빈 장치 이름으로 · 같은 이름이 다시 나와도 이어 붙인다")
        XCTAssertEqual(pairs.map(\.ip), ["198.51.100.9", "192.0.2.10", "203.0.113.7", "100.64.0.5", "198.51.100.20", "198.51.100.21"])
        XCTAssertTrue(LocalCommands.parseInterfaceAddresses("").isEmpty)
    }

    func testRouteInterfaceDetails() {
        let details = RouteTable.parseInterfaceDetails(text)
        XCTAssertEqual(details, ["lo0": InterfaceDetail(ip: "127.0.0.1", mtu: 16384), "en0": InterfaceDetail(ip: "192.0.2.10", mtu: 1500), "bridge0": InterfaceDetail(mtu: 1500),
                                 "utun3": InterfaceDetail(ip: "100.64.0.5", mtu: 1280), "en5": InterfaceDetail(ip: "198.51.100.21"), "status": InterfaceDetail()],
                       "첫 주소만 · MTU 는 장치 줄에서 · 같은 이름이 다시 나오면 새로 시작(MTU 도) · 머리 줄 앞의 주소는 버린다")
        XCTAssertEqual(RouteTable.parseInterfaceDetails(":x mtu 1400\n\tinet 192.0.2.2 netmask 0xffffff00"), ["": InterfaceDetail(mtu: 1400)], "빈 이름의 장치는 주소를 받지 않는다")
        XCTAssertEqual(RouteTable.parseInterfaceDetails("en0: flags=1 mtu x\n\tinet 192.0.2.1"), ["en0": InterfaceDetail(ip: "192.0.2.1")])
    }
}
