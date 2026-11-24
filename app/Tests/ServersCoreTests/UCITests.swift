// `uci show` 출력 풀이 (UCI.swift)와 그것을 쓰는 세 곳의 차이: Clients 는 이름순으로 모으고, Firewall 은 나온 순서대로, WireGuard 는 패키지.섹션으로 잇는다
// (2026-11-24 파서를 한 곳으로 모으기 전에 넣은 테스트 — 보통 출력의 검증은 OpenWrtTests).

import Foundation
import XCTest
@testable import ServersCore

final class UCITests: XCTestCase {
    /// Clients(고정 할당 · GL 별칭): 그 종류의 섹션만, 이름순. 옵션 줄이 섹션 줄보다 먼저 와도 · 패키지가 달라도 같은 이름이면 합친다
    func testSectionsOfTypeMergeByNameAndSort() {
        let lines = ["dhcp.b=host", "dhcp.b.mac='AA'", "dhcp.a.ip='192.0.2.1'", "dhcp.a=host", "dhcp.c=dnsmasq", "dhcp.c.x='1'", "other.a.name='n'",
                     "no equals", "dhcp.a.b.c='deep'", "dhcp.b.mac='BB' 'CC'", "dhcp.@host[10]=host", "dhcp.@host[10].tag='t'", "dhcp.@host[2]=host", "dhcp.e=host", "dhcp.a.dns=plain"]
        XCTAssertEqual(UCI.sections(lines, type: "host"),
                       [["tag": ["t"]], [:], ["ip": ["192.0.2.1"], "name": ["n"], "dns": ["plain"]], ["mac": ["BB", "CC"]], [:]],
                       "이름순(@host[10] < @host[2] < a < b < e) · 같은 옵션은 뒤의 값 · 네 칸 경로와 = 없는 줄은 버린다")
        XCTAssertEqual(UCI.sections(lines, type: "dnsmasq"), [["x": ["1"]]])
        XCTAssertEqual(UCI.sections(lines, type: "none"), [])
        XCTAssertEqual(UCI.sections(["dhcp.a=host", "dhcp.a=other", "dhcp.a.x='1'"], type: "host"), [["x": ["1"]]], "종류가 다시 적혀도 처음 맞은 것은 남는다")
    }

    /// Firewall: 나온 순서 그대로. 섹션 줄보다 먼저 온 옵션은 버리고, 같은 이름의 섹션 줄이 다시 나오면 새 섹션이다
    func testFirewallKeepsFileOrder() throws {
        let lines = ["@UCI",
                     "firewall.early.name='dropped'",
                     "firewall.@rule[10]=rule", "firewall.@rule[10].name='ten'", "firewall.@rule[10].target='accept'",
                     "firewall.@rule[2]=rule", "firewall.@rule[2].name='two'", "firewall.@rule[2].proto='tcp' 'udp'", "firewall.@rule[2].dest_port='53'",
                     "firewall.early=rule",
                     "firewall.dup=rule", "firewall.dup.name='first'", "firewall.dup.src='wan'",
                     "firewall.dup=rule", "firewall.dup.name='second'",
                     "no equals", "firewall.a.b.c='deep'", "firewall.ghost.name='no section'",
                     "@PORTFORWARD",
                     "port_forward.@redirect[0]=redirect", "port_forward.@redirect[0].name='pf'", "port_forward.@redirect[0].src='wan'", "port_forward.x=other",
                     "@END"]
        let fw = try XCTUnwrap(OpenWrtFirewall.parse(lines))
        XCTAssertEqual(fw.rules.map(\.id), ["@rule[10]", "@rule[2]", "early", "dup", "dup"])
        XCTAssertEqual(fw.rules.map(\.name), ["ten", "two", "early", "first", "second"], "섹션 줄 앞의 옵션은 붙지 않는다 · 다시 나온 섹션은 따로")
        XCTAssertEqual(fw.rules.map(\.src), [nil, nil, nil, "wan", nil], "다시 나온 섹션은 앞의 옵션을 물려받지 않는다")
        XCTAssertEqual(fw.rules[0].target, "ACCEPT")
        XCTAssertEqual(fw.rules[1].match, "tcp/udp 53")
        XCTAssertEqual(fw.portForwards.map(\.name), ["pf"])
        XCTAssertEqual(fw.portForwards.map(\.source), ["GL"])
    }

    /// WireGuard 이름: 섹션 줄 없이 "패키지.섹션" 으로 공개 키와 이름을 잇는다 (세 패키지 출력이 섞여 온다)
    func testWireGuardNamesJoinByPackageAndSection() throws {
        let lines = ["@NOW", "1000", "@WG",
                     "wg0 priv pubS 51820 off",
                     "wg0 keyA (none) (none) (none) 0 0 0 off", "wg0 keyB (none) (none) (none) 0 0 0 off",
                     "wg0 keyC (none) (none) (none) 0 0 0 off", "wg0 keyD (none) (none) (none) 0 0 0 off", "wg0 keyE (none) (none) (none) 0 0 0 off",
                     "@NAMES",
                     "network.peer1.public_key='keyA'", "network.peer1.description='Laptop'",
                     "wireguard_server.peer1.public_key='keyB'", "wireguard_server.peer1.name='Bob'\\''s phone'",
                     "network.peer2.name='first'", "network.peer2.name='second'", "network.peer2.public_key='keyC'",
                     "network.peer3.name='n'", "network.peer3.description='desc wins'", "network.peer3.public_key=keyD",
                     "network.peer4.public_key='keyE'", "network.peer4.description=''", "network.peer5=wireguard_peer", "network.a.b.c='keyE'",
                     "@END"]
        guard case let .interfaces(interfaces) = try XCTUnwrap(WireGuardReport.parse(lines)) else { return XCTFail("wg 가 있는 출력") }
        XCTAssertEqual(interfaces.first?.peers.map(\.name), ["Laptop", "Bob's phone", "first", "desc wins", nil],
                       "같은 섹션 이름이라도 패키지가 다르면 따로 · name 은 처음 것, description 이 있으면 그것 · 따옴표 없는 값도 · 빈 이름은 없음")
    }

    func testValues() {
        XCTAssertEqual(UCI.values("'a' 'b c'"), ["a", "b c"])
        XCTAssertEqual(UCI.values("''"), [""])
        XCTAssertEqual(UCI.values("plain text"), ["plain text"])
        XCTAssertEqual(UCI.values("'a'\\''b' 'c'"), ["a'b", "c"])
        XCTAssertEqual(UCI.values("'unterminated"), [])
    }
}
