// OpenWrt(type=openwrt) 원격 정보: Spec · Network · Firewall · Clients · WireGuard · Services · Ports · Live 출력 파싱.
// Fixtures/openwrt-*.txt 는 각 스크립트를 로컬 openwrt/rootfs:x86-64-23.05.5 컨테이너(procd 로 부팅, wan 고정 IP,
// WireGuard 서버·클라이언트를 루프백으로 이어 실제 핸드셰이크, DHCP 임대 4개 · 고정 할당 2개)에서 돌린 실제 출력이다. 실제 장비에는 접속하지 않는다.
// 키는 컨테이너에서 만든 버리는 키이고, 스크립트가 개인 키·사전 공유 키를 지우고 보낸 결과라 공개 키만 남아 있다.

import Foundation
import XCTest
@testable import ServersCore

final class OpenWrtTests: XCTestCase {
    /// 앱과 같은 정리를 거친 줄 (탭 → 공백 4칸)
    private func fixture(_ name: String) throws -> [String] {
        var lines = RemoteCommands.cleanOutput(try fixtureText("openwrt-\(name)"), type: .openwrt)
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    // MARK: 조회 연결

    func testQueriesPerType() {
        for query in RemoteCommands.Query.allCases where query != .schedule && query != .diagnose {
            XCTAssertNotNil(RemoteCommands.query(query, for: .openwrt), "OpenWrt 는 schedule · diagnose(linux 만, 조회가 아니다) 말고 모든 탭: \(query)")
        }
        XCTAssertNil(RemoteCommands.query(.schedule, for: .openwrt), "cron·systemd 타이머는 리눅스 탭")
        for type in [ServerType.linux, .windows] {
            for query in [RemoteCommands.Query.firewall, .clients, .wireguard] {
                XCTAssertNil(RemoteCommands.query(query, for: type), "\(type) 에는 OpenWrt 탭이 없다")
            }
        }
        XCTAssertNotNil(RemoteCommands.query(.network, for: .windows), "Windows Network 탭은 WindowsNetwork (2026-11-10)")
        XCTAssertNotNil(RemoteCommands.query(.network, for: .linux), "리눅스 Network 탭은 LinuxInfoScripts (2026-11-07)")
        // OpenWrt 에는 bash 가 없다 — 리눅스 Spec 의 bash -s 를 쓰면 탭이 통째로 실패한다
        XCTAssertEqual(RemoteCommands.query(.spec, for: .openwrt)?.command, "sh -s")
        XCTAssertFalse(OpenWrt.specScript.contains("[["), "ash 전용이 아닌 문법은 피한다")
        XCTAssertEqual(RemoteCommands.Query.wireguard.title, "WireGuard")
        XCTAssertEqual(RemoteCommands.Query.allCases.map(\.title), ["Spec", "Network", "Firewall", "Clients", "WireGuard", "Services", "Ports", "Schedule", "Diagnose", "Live"])
    }

    func testConfigTypeAndSession() throws {
        let text = "[group:g]\ntheme=on\n\n[r]\ngroup=g\ntype=openwrt\nip=192.168.8.1\nuser=root\nport=22\n"
        let config = try ServerConfigParser.parse(text)
        let router = try XCTUnwrap(config.server("r"))
        XCTAssertEqual(router.type, .openwrt)
        XCTAssertEqual(router.check, .tcp, "direct 는 리눅스처럼 tcp 확인")
        let overTailscale = try ServerConfigParser.parse("[r]\ngroup=g\nnetwork=tailscale\ntype=openwrt\nip=100.64.0.9\nuser=root\nport=22\n")
        XCTAssertEqual(overTailscale.server("r")?.check, .tcp, "공유기는 보통 비밀번호 로그인 — Tailscale 이어도 ssh(BatchMode) 확인은 늘 실패한다")
        // 테마 그룹이어도 bash 로 띄우지 않는다 (OpenWrt 에는 bash 가 없다)
        let ssh = SessionCommand.sshCommandLine(to: router, config: config, home: "/h")
        XCTAssertFalse(ssh.contains("bash"))
        XCTAssertTrue(ssh.hasSuffix("'root@192.168.8.1'"))
        XCTAssertThrowsError(try ServerConfigParser.parse(text.replacingOccurrences(of: "type=openwrt", with: "type=openwrt2")))
        XCTAssertEqual(TerminalPaste.remoteDirectory(type: .openwrt), "/tmp")
        XCTAssertEqual(RemoteCommands.parseHome("/root\n", type: .openwrt), "/root")
    }

    // MARK: Spec

    func testSpec() throws {
        let items = RemoteInfo.parseSpec(try fixture("spec"))
        XCTAssertEqual(items.map(\.key), ["HOSTNAME", "OS", "KERNEL", "ARCH", "CPU", "MEMORY", "ROOT DISK", "UPTIME"],
                       "모델이 비면(컨테이너) 줄을 숨긴다")
        XCTAssertTrue(items[1].value.hasPrefix("OpenWrt 23.05.5"))
        XCTAssertEqual(items[3].value, "x86/64")
        XCTAssertNotNil(items[5].usage, "메모리 사용률")
        XCTAssertNotNil(items[6].usage, "루트(overlay) 사용률")
        XCTAssertTrue(items[4].value.hasSuffix("스레드)"))
        // 보드 이름은 /tmp/sysinfo/model 그대로
        XCTAssertEqual(RemoteInfo.parseSpec(["MODEL        |GL.iNet GL-MT5000||"]).first?.value, "GL.iNet GL-MT5000")
    }

    // MARK: Network

    func testNetwork() throws {
        let network = try XCTUnwrap(OpenWrtNetwork.parse(try fixture("network")))
        XCTAssertEqual(network.interfaces.map(\.name), ["wan", "lan", "wgclient", "wgserver"], "loopback 빼고 wan · lan · 그 밖 이름 순")
        let wan = network.interfaces[0]
        XCTAssertTrue(wan.up)
        XCTAssertEqual(wan.proto, "static")
        XCTAssertEqual(wan.device, "eth0")
        XCTAssertEqual(wan.addresses, ["172.30.0.10/24"])
        XCTAssertEqual(wan.gateway, "172.30.0.1")
        XCTAssertEqual(wan.dns, ["1.1.1.1"])
        XCTAssertNotNil(wan.rxBytes)
        XCTAssertNotNil(wan.uptime)
        XCTAssertNil(network.interfaces[1].gateway)
        XCTAssertEqual(network.interfaces[3].proto, "wireguard")
        XCTAssertEqual(network.interfaces[3].addresses, ["10.0.0.1/24"])
        // 포트: ethernet 장치만 (br-lan · wg · lo 는 아니다)
        XCTAssertEqual(network.ports.map(\.name), ["eth0"])
        XCTAssertEqual(network.ports[0].speedMbps, 10000)
        XCTAssertEqual(network.ports[0].interfaces, ["wan"], "wan 장치가 eth0")
        XCTAssertEqual(network.ports[0].fullDuplex, true)
        XCTAssertTrue(network.ports[0].carrier)
    }

    // MARK: Routes
    // Fixtures/openwrt-routes-mt5000.txt: GL-MT5000 실제 출력 (2026-11-05 사용자, 공인 주소만 203.0.113.x 로 바꿈).
    // Fixtures/openwrt-routes-policy.txt: 로컬 ubuntu:24.04 컨테이너의 iproute2 에 더미 장치로 정책 규칙·별도 테이블·멀티패스·blackhole 을 만들어 받은 실제 출력.

    private func routing(_ name: String, ifaces: String) throws -> OpenWrtRouting? {
        try XCTUnwrap(OpenWrtNetwork.parse(["@IFACES", ifaces, "@DEVICES", "{}"] + (try fixture(name)))).routing
    }

    func testRoutesRealDevice() throws {
        let ifaces = #"{"interface":[{"interface":"wan6","l3_device":"eth1"},{"interface":"wan","l3_device":"eth1"},{"interface":"lan","l3_device":"br-lan"},{"interface":"wgserver","l3_device":"wgserver"}]}"#
        let r = try XCTUnwrap(try routing("routes-mt5000", ifaces: ifaces))
        XCTAssertEqual(r.routes.map(\.destination), ["default", "10.1.0.0/24", "203.0.113.0/24", "192.168.8.0/24"])
        XCTAssertEqual(r.routes.map(\.interface), ["wan", "wgserver", "wan", "lan"], "wan · wan6 이 같은 장치면 wan")
        XCTAssertEqual(r.routes.map(\.gateway), ["203.0.113.1", nil, nil, nil], "via 없으면 On-link")
        XCTAssertEqual(r.routes[0].metric, 1)
        XCTAssertEqual(r.defaultRoutes, [r.routes[0]], "iif lo 규칙(테이블 16800 비어 있음)을 지나 main 의 default")
        XCTAssertFalse(r.hasOtherTables)
        XCTAssertEqual(r.policyRules.map(\.condition), ["iif lo"], "기본 규칙 셋은 숨긴다")
        XCTAssertEqual(r.policyRules.first?.table, "16800")
        XCTAssertEqual(r.routeCount(inTable: "16800"), 0)
    }

    func testRoutesPolicyFormats() throws {
        let r = try XCTUnwrap(try routing("routes-policy", ifaces: #"{"interface":[{"interface":"wan","l3_device":"wan0"},{"interface":"vpn","l3_device":"vpn0"}]}"#))
        XCTAssertEqual(r.routes.prefix(3).map(\.table), ["main", "main", "main"], "ip 가 다른 테이블을 먼저 찍어도 main 먼저")
        // metric 없는 줄(0)이 metric 10 · 20 을 이긴다
        XCTAssertEqual(r.defaultRoutes.map(\.device), ["eth0"])
        // 조건 있는 규칙은 기본 경로 판정에 들지 않는다 — main 앞의 "suppress_prefixlength" 도 조건
        XCTAssertEqual(r.policyRules.map(\.condition), ["fwmark 0x8000/0xf000", "from 192.168.8.50", "not fwmark 0xca6c", "suppress_prefixlength 0", "iif lo", "to 192.0.2.9"])
        XCTAssertEqual(r.policyRules.map(\.table), ["100", "200", "300", "main", "16800", nil])
        XCTAssertEqual(r.policyRules.last?.action, "unreachable")
        XCTAssertFalse(try XCTUnwrap(r.policyRules.first { $0.table == "main" }).isStandard, "조건 달린 main 은 기본 규칙이 아니다")
        // 멀티패스는 다음 홉마다 한 줄, 머리 줄은 남지 않는다
        let multipath = r.routes.filter { $0.table == "300" && $0.destination == "default" }
        XCTAssertEqual(multipath.map(\.gateway), ["203.0.113.1", "198.51.100.1"])
        XCTAssertEqual(multipath.map(\.interface), ["wan", nil])
        // 보내지 않는 경로
        XCTAssertEqual(r.routes.filter { $0.table == "200" }.map(\.kind), ["blackhole", "unreachable"])
        XCTAssertEqual(r.routes.first { $0.destination == "10.0.0.0/8" }?.kind, "throw")
        XCTAssertEqual(Set(r.routes.map(\.id)).count, r.routes.count, "ForEach 키가 겹치지 않는다")
        XCTAssertTrue(r.hasOtherTables)
    }

    func testDefaultRouteDecisions() throws {
        func decide(rules: [String] = [], _ routes: [String]) throws -> [String] {
            try XCTUnwrap(OpenWrtRouting.parse(rules: rules, routes: routes, interfaceNames: [:])).defaultRoutes.map { $0.kind ?? $0.device ?? "-" }
        }
        let wan = "default via 1.1.1.1 dev wan0 metric 10"
        let lan = "192.168.8.0/24 dev br-lan"
        XCTAssertEqual(try decide([lan]), [], "default 가 없으면 없다고")
        XCTAssertEqual(try decide([wan, lan]), ["wan0"], "규칙을 못 읽으면 main")
        XCTAssertEqual(try decide([wan, "default via 2.2.2.2 dev wan1 metric 20"]), ["wan0"], "metric 낮은 쪽")
        // 조건 없는 규칙이 main 보다 앞서면 그 테이블
        let vpnFirst = ["5: from all lookup 100", "32766: from all lookup main"]
        XCTAssertEqual(try decide(rules: vpnFirst, [wan, "default dev wg0 table 100"]), ["wg0"])
        XCTAssertEqual(try decide(rules: vpnFirst, [wan, lan]), ["wan0"], "테이블이 비면 다음 규칙으로")
        XCTAssertEqual(try decide(rules: vpnFirst, [wan, "blackhole default table 100"]), ["blackhole"], "킬 스위치: wan 으로 샌다고 하면 안 된다")
        XCTAssertEqual(try decide(rules: vpnFirst, [wan, "throw default table 100"]), ["wan0"], "throw 는 다음 규칙으로")
        XCTAssertEqual(try decide(rules: ["5: from all prohibit", "32766: from all lookup main"], [wan]), [], "모든 트래픽을 막는 규칙")
        XCTAssertEqual(try decide(rules: ["5: from all fwmark 0x1 lookup 100", "32766: from all lookup main"], [wan, "default dev wg0 table 100"]), ["wan0"], "조건 달린 규칙은 건너뛴다")
        // OpenVPN def1: 0/1 · 128/1 짝이 default 를 이긴다. 한쪽만 있으면 전체를 덮지 않는다
        XCTAssertEqual(try decide([wan, "0.0.0.0/1 via 10.8.0.1 dev tun0", "128.0.0.0/1 via 10.8.0.1 dev tun0"]), ["tun0", "tun0"])
        XCTAssertEqual(try decide([wan, "0.0.0.0/1 via 10.8.0.1 dev tun0"]), ["wan0"])
    }

    // MARK: Network 화면 구성

    /// GL-MT5000 화면(2026-11-05 스크린샷)과 같은 구성: wan · lan · 장치 없는 secondwan · proto 와 장치가 이름과 같은 wgserver
    private let mt5000Ifaces = #"""
    {"interface":[
    {"interface":"wan","up":true,"proto":"dhcp","l3_device":"eth1","ipv4-address":[{"address":"203.0.113.143","mask":24}],"route":[{"target":"0.0.0.0","mask":0,"nexthop":"203.0.113.1"}],"dns-server":["168.126.63.1"]},
    {"interface":"lan","up":true,"proto":"static","l3_device":"br-lan","ipv4-address":[{"address":"192.168.8.1","mask":24}]},
    {"interface":"secondwan","up":false,"proto":"dhcp","errors":[{"code":"NO_DEVICE"}]},
    {"interface":"wgserver","up":true,"proto":"wgserver","l3_device":"wgserver","ipv4-address":[{"address":"10.1.0.1","mask":24}]}
    ]}
    """#
    private let mt5000Devices = #"{"eth0":{"devtype":"ethernet","carrier":true,"speed":"2500F"},"eth1":{"devtype":"ethernet","carrier":true,"speed":"1000F"},"eth2":{"devtype":"ethernet","carrier":false},"br-lan":{"devtype":"bridge","bridge-members":["eth0"]}}"#

    func testLayoutRealDevice() throws {
        let network = try XCTUnwrap(OpenWrtNetwork.parse(["@IFACES", mt5000Ifaces, "@DEVICES", mt5000Devices] + (try fixture("routes-mt5000"))))
        let items = network.layout.items
        XCTAssertEqual(items.map(\.id), ["wan", "lan", "secondwan", "wgserver"])
        let wan = items[0], lan = items[1], second = items[2], wg = items[3]
        // 게이트웨이를 타는 경로만 행 아래, 자기 대역 On-link 는 metric 이 있어도 펼침으로
        XCTAssertEqual(wan.routes.map(\.destination), ["default"])
        XCTAssertEqual(wan.subnetRoutes.map(\.destination), ["203.0.113.0/24"])
        XCTAssertEqual(wan.subnetRoutes.first?.metric, 1)
        XCTAssertEqual(wan.ports.map(\.name), ["eth1"])
        XCTAssertNil(wan.detailGateway, "default 줄에 같은 값이 보인다")
        XCTAssertEqual(wan.descriptors, ["dhcp", "eth1"])
        XCTAssertEqual(lan.routes, [])
        XCTAssertEqual(lan.subnetRoutes.map(\.destination), ["192.168.8.0/24"])
        XCTAssertEqual(lan.ports.map(\.name), ["eth0"], "브리지 구성원")
        XCTAssertEqual(wg.descriptors, [], "wgserver · wgserver 를 이름 옆에 또 적지 않는다")
        XCTAssertEqual(wg.subnetRoutes.map(\.destination), ["10.1.0.0/24"])
        XCTAssertEqual(second.descriptors, ["dhcp"])
        XCTAssertFalse(second.hasDetail, "펼칠 게 없으면 누를 수 없다")
        XCTAssertTrue(wg.hasDetail)
        XCTAssertEqual(network.layout.otherRoutes, [])
        XCTAssertEqual(network.layout.otherPorts.map(\.name), ["eth2"], "어느 인터페이스도 안 쓰는 포트는 따로")
        // 이 공유기의 iif lo → 16800 은 비어 있어 접힌다
        let routing = try XCTUnwrap(network.routing)
        XCTAssertEqual(routing.policyRules.map { routing.isEmptyLookup($0) }, [true])
    }

    func testLayoutKeepsEveryRoute() throws {
        let ifaces = #"{"interface":[{"interface":"wan","l3_device":"wan0","ipv4-address":[{"address":"203.0.113.2","mask":24}]},{"interface":"vpn","l3_device":"vpn0"}]}"#
        let network = try XCTUnwrap(OpenWrtNetwork.parse(["@IFACES", ifaces, "@DEVICES", "{}"] + (try fixture("routes-policy"))))
        let layout = network.layout
        let routing = try XCTUnwrap(network.routing)
        let shown = layout.items.flatMap { $0.routes + $0.subnetRoutes } + layout.otherRoutes
        XCTAssertEqual(Set(shown.map(\.id)), Set(routing.routes.map(\.id)), "모든 경로가 어딘가에 보인다")
        XCTAssertEqual(shown.count, routing.routes.count, "두 번 나오지 않는다")
        let wan = try XCTUnwrap(layout.items.first { $0.id == "wan" })
        XCTAssertEqual(wan.routes.map(\.destination), ["default"], "밀린 default 도 행 아래에")
        XCTAssertEqual(wan.subnetRoutes.map(\.destination), ["203.0.113.0/24"])
        XCTAssertFalse(wan.routes.contains { $0.table != "main" }, "다른 테이블은 인터페이스 밑에 넣지 않는다")
        // 주소를 모르면 On-link 라도 자기 대역이라 단정하지 않는다
        XCTAssertEqual(try XCTUnwrap(layout.items.first { $0.id == "vpn" }).routes.map(\.destination), ["10.9.0.0/24"])
        XCTAssertTrue(layout.otherRoutes.contains { $0.device == "eth0" && $0.destination == "default" }, "모르는 장치의 기본 경로도 사라지지 않는다")
        XCTAssertTrue(layout.otherRoutes.contains { $0.kind == "blackhole" })
        XCTAssertTrue(routing.defaultRoutes.allSatisfy { layout.otherRoutes.contains($0) }, "이 픽스처의 기본 경로는 eth0")
        // 비어 있는 테이블만 접힌다: 경로가 있는 테이블 · 동작 규칙 · 조건 달린 main 은 그대로
        XCTAssertEqual(routing.policyRules.filter { routing.isEmptyLookup($0) }.map(\.table), ["16800"])
    }

    func testLayoutSubnetAndGatewayEdges() throws {
        func network(_ address: String, gateway: String? = nil, routes: [String]) throws -> OpenWrtNetworkLayout.Item {
            let route = gateway.map { #","route":[{"target":"::","mask":0,"nexthop":"\#($0)"}]"# } ?? ""
            let iface = #"{"interface":[{"interface":"wan","l3_device":"eth1","ipv4-address":[{"address":"\#(address)","mask":24}]\#(route)}]}"#
            let parsed = try XCTUnwrap(OpenWrtNetwork.parse(["@IFACES", iface, "@DEVICES", "{}", "@RULES", "@ROUTES"] + routes + ["@END"]))
            return try XCTUnwrap(parsed.layout.items.first)
        }
        let item = try network("192.168.8.77", routes: ["192.168.8.0/24 dev eth1", "192.168.0.0/16 dev eth1", "10.0.0.2 dev eth1", "192.168.8.0/24 via 192.168.8.5 dev eth1 metric 5", "default dev eth1"])
        XCTAssertEqual(item.subnetRoutes.map(\.destination), ["192.168.8.0/24"], "호스트 부분을 지운 대역만 같다고 본다")
        XCTAssertEqual(item.routes.map(\.destination), ["192.168.0.0/16", "10.0.0.2", "192.168.8.0/24", "default"], "더 넓은 대역 · /32 · 게이트웨이를 타는 같은 대역 · 장치 default 는 보인다")
        // 경로 표에 없는 게이트웨이(IPv6)는 펼침에 남는다
        XCTAssertEqual(try network("192.168.8.77", gateway: "fe80::1", routes: ["192.168.8.0/24 dev eth1"]).detailGateway, "fe80::1")
        // 자기 대역 판정은 리눅스 Network 탭과 같은 IPv4Prefix (그쪽 테스트: LinuxInfoTests.testIPv4Prefix)
        XCTAssertTrue(IPv4Prefix.sameNetwork("10.1.2.3/8", "10.0.0.0/8"))
        XCTAssertTrue(IPv4Prefix.sameNetwork("10.1.2.3/32", "10.1.2.3/32"))
        XCTAssertFalse(IPv4Prefix.sameNetwork("10.1.2.3/32", "10.1.2.3"), "ip route 가 /32 를 접두사 없이 찍은 줄은 자기 대역으로 접지 않는다")
        XCTAssertFalse(IPv4Prefix.sameNetwork("fe80::1/64", "fe80::/64"), "IPv4 만")
        XCTAssertFalse(IPv4Prefix.sameNetwork("10.1.2.3/33", "10.1.2.3/33"))
        // 경로를 못 읽어도 인터페이스·포트는 나온다
        let unread = try XCTUnwrap(OpenWrtNetwork.parse(["@IFACES", mt5000Ifaces, "@DEVICES", mt5000Devices, "@END"]))
        XCTAssertNil(unread.routing)
        XCTAssertEqual(unread.layout.items.count, 4)
        XCTAssertEqual(unread.layout.items[0].detailGateway, "203.0.113.1", "경로 줄이 없으면 게이트웨이는 펼침에")
        // local 테이블은 파서가 경로를 담지 않으니 비었다고 하지 않는다
        let routing = try XCTUnwrap(OpenWrtRouting.parse(rules: ["5: from 10.0.0.1 lookup local", "6: from 10.0.0.1 lookup 99", "7: from 10.0.0.1 unreachable"], routes: ["default dev wan0"], interfaceNames: [:]))
        XCTAssertEqual(routing.rules.map { routing.isEmptyLookup($0) }, [false, true, false])
    }

    func testClientDisplayValues() {
        func client(lease: TimeInterval?, isStatic: Bool) -> OpenWrtClient {
            OpenWrtClient(mac: "aa:bb:cc:dd:ee:ff", ip: "192.168.8.2", name: nil, leaseRemaining: lease, isStatic: isStatic, active: true)
        }
        // 고정 + 임대: 시간은 행에 내지 않는다
        XCTAssertFalse(client(lease: 3600, isStatic: true).isDynamic)
        XCTAssertNil(client(lease: 3600, isStatic: true).visibleLease)
        // 유동
        XCTAssertTrue(client(lease: 3600, isStatic: false).isDynamic)
        XCTAssertEqual(client(lease: 3600, isStatic: false).visibleLease, 3600)
        XCTAssertEqual(client(lease: .infinity, isStatic: false).visibleLease, .infinity, "무기한도 유동 임대")
        // 임대 없이 ARP 에만 보이는 장비: DHCP 라고 하면 틀린다
        XCTAssertFalse(client(lease: nil, isStatic: false).isDynamic)
        XCTAssertNil(client(lease: nil, isStatic: false).visibleLease)
        // 임대 없는 고정 할당 (Nexus-Core 모양)
        XCTAssertFalse(client(lease: nil, isStatic: true).isDynamic)
    }

    // MARK: 스위치 포트
    // Fixtures/openwrt-switch-mt5000.txt: GL-MT5000 실제 출력 (2026-11-06 사용자). board.json 은 grep 으로 받은 switch 부분이고 닫는 괄호만 채웠다. LAN 에 2.5G·1G 장비가 하나씩 꽂힌 상태

    private let brumeIfaces = #"{"interface":[{"interface":"wan","up":true,"l3_device":"eth1","device":"eth1"},{"interface":"lan","up":true,"l3_device":"br-lan","device":"br-lan"}]}"#
    private let brumeDevices = #"{"br-lan":{"devtype":"bridge","bridge-members":["eth0.1"]},"eth0":{"devtype":"ethernet","carrier":true,"speed":"2500F"},"eth0.1":{"devtype":"vlan"},"eth1":{"devtype":"ethernet","carrier":true,"speed":"1000F"}}"#

    func testSwitchPortsRealDevice() throws {
        let network = try XCTUnwrap(OpenWrtNetwork.parse(["@IFACES", brumeIfaces, "@DEVICES", brumeDevices] + (try fixture("switch-mt5000"))))
        XCTAssertEqual(network.ports.map(\.name), ["eth1", "port 0", "port 1"], "eth0 은 CPU 로 가는 내부 연결이라 빠진다. board.json 에 없는 2·3 은 포트가 아니다")
        let lan = try XCTUnwrap(network.layout.items.first { $0.id == "lan" })
        XCTAssertEqual(lan.ports.map(\.name), ["port 0", "port 1"], "br-lan ⊃ eth0.1 = lan 역할의 장치")
        XCTAssertEqual(lan.ports.map(\.speedMbps), [2500, 1000])
        XCTAssertEqual(lan.ports.map(\.carrier), [true, true])
        XCTAssertEqual(lan.ports.map(\.fullDuplex), [true, true])
        XCTAssertEqual(try XCTUnwrap(network.layout.items.first { $0.id == "wan" }).ports.map(\.name), ["eth1"], "스위치 밖 포트는 그대로")
        XCTAssertEqual(network.layout.otherPorts, [])
    }

    func testSwitchPortsEdges() throws {
        func ports(board: String?, links: [String]?) throws -> [OpenWrtPort] {
            var lines = ["@IFACES", brumeIfaces, "@DEVICES", brumeDevices]
            if let board { lines += ["@BOARD", board] }
            if let links { lines += ["@SWITCH"] + links }
            return try XCTUnwrap(OpenWrtNetwork.parse(lines + ["@END"])).ports
        }
        let board = #"{"switch":{"switch0":{"ports":[{"num":0,"role":"lan"},{"num":1,"role":"lan"},{"num":17,"device":"eth0"}],"roles":[{"role":"lan","device":"eth0.1"}]}}}"#
        let up = "\tlink: port:0 link:up speed:2500baseT full-duplex"
        // 읽지 못하면 지금까지처럼 eth0
        let plain = ["eth0", "eth1"]
        XCTAssertEqual(try ports(board: nil, links: nil).map(\.name), plain, "swconfig 없음")
        XCTAssertEqual(try ports(board: board, links: []).map(\.name), plain, "swconfig 가 아무것도 안 줌")
        XCTAssertEqual(try ports(board: board, links: ["switch switch0"]).map(\.name), plain, "show 시간 초과")
        XCTAssertEqual(try ports(board: "not json", links: ["switch switch0", up]).map(\.name), plain)
        XCTAssertEqual(try ports(board: #"{"model":{}}"#, links: ["switch switch0", up]).map(\.name), plain, "board.json 에 스위치가 없다")
        XCTAssertEqual(try ports(board: board, links: ["switch other", up]).map(\.name), plain, "다른 스위치의 줄")
        XCTAssertEqual(try ports(board: board, links: ["switch switch0", "\tlink: ???", "\tlink: port:17 link:up speed:2500baseT full-duplex"]).map(\.name), plain, "??? 줄과 CPU 포트만 있다")
        // 포트 상태
        let states = try ports(board: board, links: ["switch switch0", up, "\tlink: port:1 link:up speed:100baseT half-duplex"])
        XCTAssertEqual(states.map(\.fullDuplex), [true, true, false], "eth1 · port 0 · port 1")
        let down = try ports(board: board, links: ["switch switch0", "\tlink: port:0 link:down", "\tlink: port:1 link:up speed:unknown"])
        XCTAssertEqual(down.map(\.name), ["eth1", "port 0", "port 1"])
        XCTAssertEqual(down[1].carrier, false)
        XCTAssertNil(down[1].speedMbps)
        XCTAssertEqual(down[2].carrier, true)
        XCTAssertNil(down[2].speedMbps, "속도를 모르면 지어내지 않는다")
        // 역할에 장치가 없으면 인터페이스에 못 묶지만 사라지지 않는다
        let loose = #"{"switch":{"switch0":{"ports":[{"num":0,"role":"lan"},{"num":17,"device":"eth0"}]}}}"#
        let parsed = try XCTUnwrap(OpenWrtNetwork.parse(["@IFACES", brumeIfaces, "@DEVICES", brumeDevices, "@BOARD", loose, "@SWITCH", "switch switch0", up, "@END"]))
        XCTAssertEqual(parsed.layout.otherPorts.map(\.name), ["port 0"])
        // 스위치가 둘이면 번호가 겹치지 않게
        let two = #"{"switch":{"a":{"ports":[{"num":0,"role":"lan"}]},"b":{"ports":[{"num":0,"role":"lan"}]}}}"#
        XCTAssertEqual(try ports(board: two, links: ["switch a", up, "switch b", up]).map(\.name).filter { $0.contains("port") }, ["a port 0", "b port 0"])
        XCTAssertTrue(OpenWrt.networkScript.contains("command -v swconfig"), "스위치 없는 공유기에서도 Network 탭 전체는 살아야 한다")
        XCTAssertTrue(OpenWrt.networkScript.contains("command -v timeout"), "순정 OpenWrt 23.05 busybox 에는 timeout 이 없다 (컨테이너로 확인) — 없을 때도 포트를 읽는다")
    }

    func testRoutesMissingOrUnreadable() throws {
        let iface = #"{"interface":[]}"#
        XCTAssertNil(try XCTUnwrap(OpenWrtNetwork.parse(["@IFACES", iface, "@END"])).routing, "ip 가 없으면 구역이 없다")
        XCTAssertNil(try XCTUnwrap(OpenWrtNetwork.parse(["@IFACES", iface, "@RULES", "@ROUTES", "@END"])).routing, "ip 가 실패하면 없다고 말하지 않는다")
        XCTAssertNil(OpenWrtRouting.parse(rules: [], routes: ["garbage line", "nat 1.2.3.4 dev x"], interfaceNames: [:]), "경로로 읽히는 줄이 없다")
        XCTAssertTrue(OpenWrt.networkScript.contains("command -v ip"), "busybox 에 ip 가 없어도 Network 탭 전체는 살아야 한다")
    }

    // MARK: Firewall
    // Fixtures/openwrt-firewall.txt: GL-MT5000 실제 `uci show firewall` (2026-11-05 사용자). 150줄에서 잘린 출력이라 끝의 wgserver2lan 은 옵션이 일부만 있다.

    func testFirewallRealDevice() throws {
        let fw = try XCTUnwrap(OpenWrtFirewall.parse(try fixture("firewall")))
        XCTAssertEqual(fw.zones.map(\.name), ["lan", "wan", "wgserver"])
        XCTAssertEqual(fw.zones[1].networks, ["wan", "wan6", "wwan", "secondwan", "tethering"])
        XCTAssertEqual([fw.zones[1].input, fw.zones[1].output, fw.zones[1].forward], ["DROP", "ACCEPT", "REJECT"])
        XCTAssertEqual(fw.zones[2].forward, "REJECT", "존에 forward 가 없으면 defaults 값")
        XCTAssertEqual(fw.zones.map(\.masq), [false, true, true])
        XCTAssertEqual(fw.forwardings.map(\.flow), ["lan → wan"])
        // GL 관리 화면의 포트 포워딩: firewall 에는 redirect 가 없고 port_forward 에만 있다
        XCTAssertEqual(fw.portForwards.map(\.name), ["GL-nexus http", "GL-nexus https"])
        XCTAssertEqual(fw.portForwards.map(\.match), ["tcp 80 → 192.168.8.103:80", "tcp 443 → 192.168.8.103:443"])
        XCTAssertEqual(fw.portForwards.map(\.flow), ["wan → lan", "wan → lan"])
        XCTAssertEqual(fw.portForwards.map(\.source), ["GL", "GL"])
        XCTAssertEqual(fw.portForwards.map(\.enabled), [true, true])
        XCTAssertEqual(fw.portForwards.map(\.extras), [nil, nil], "idx 는 GL 내부 순번이라 내지 않는다")
        // 나온 순서 그대로 — 이름순이면 @rule[10] 이 @rule[2] 앞에 온다
        XCTAssertEqual(fw.rules.map(\.name), ["Allow-DHCP-Renew", "Allow-IGMP", "Allow-DHCPv6", "Allow-MLD", "Allow-ICMPv6-Input", "Allow-ICMPv6-Forward", "Allow-IPSec-ESP", "Allow-ISAKMP",
                                              "Support-UDP-Traceroute", "wgserver_allow", "wgserver2lan-visitor", "wgserver2lan"])
        func rule(_ name: String) throws -> OpenWrtFirewall.Rule { try XCTUnwrap(fw.rules.first { $0.name == name }) }
        let allow = try rule("wgserver_allow")
        XCTAssertEqual(allow.flow, "wan → this device", "dest 가 없으면 장비로 들어오는 규칙")
        XCTAssertEqual(allow.match, "udp 51820 · IPv4")
        XCTAssertEqual(allow.target, "ACCEPT")
        XCTAssertNil(allow.extras)
        XCTAssertEqual(try rule("Allow-ICMPv6-Forward").flow, "wan → any", "* 는 모든 존")
        let visitor = try rule("wgserver2lan-visitor")
        XCTAssertEqual(visitor.flow, "wgserver → lan")
        XCTAssertEqual(visitor.match, "all · from 10.0.0.99")
        XCTAssertEqual(visitor.target, "REJECT")
        let traceroute = try rule("Support-UDP-Traceroute")
        XCTAssertFalse(traceroute.enabled)
        XCTAssertEqual(traceroute.match, "udp 33434:33689 · IPv4", "포트 범위")
        XCTAssertEqual(try rule("Allow-MLD").extras, "icmp_type: 130/0, 131/0, 132/0, 143/0", "한 줄에 안 낸 옵션은 빠뜨리지 않는다")
        // proto 를 안 적은 규칙은 tcp·udp, target 이 없으면 비운다 (여기선 잘려서 없다)
        let cut = try rule("wgserver2lan")
        XCTAssertEqual(cut.match, "tcp/udp")
        XCTAssertEqual(cut.target, "")
        // 숨은 규칙의 출처: 스크립트 목록. uci 타입이 script 가 아니어도 include 면 낸다
        XCTAssertEqual(fw.scripts.map(\.path), ["/etc/firewall.user", "/etc/firewall.nat6", "/etc/firewall.dns_order", "/usr/bin/rtp2.sh", "/etc/firewall.dmz.exclude",
                                                "/etc/firewall.security", "/etc/netifyd/iptables-init.sh", "/usr/bin/gl_block.sh"])
    }

    // MARK: 존 매트릭스

    private typealias Endpoint = FirewallMatrix.Endpoint

    func testMatrixRealDevice() throws {
        let m = try XCTUnwrap(OpenWrtFirewall.parse(try fixture("firewall"))).matrix
        XCTAssertEqual(m.rows, [.zone("lan"), .zone("wan"), .zone("wgserver"), .device])
        XCTAssertEqual(m.columns, [.device, .zone("lan"), .zone("wan"), .zone("wgserver")])
        XCTAssertNil(m.cell(from: .device, to: .device))
        func cell(_ from: Endpoint, _ to: Endpoint) throws -> FirewallMatrix.Cell { try XCTUnwrap(m.cell(from: from, to: to)) }
        // wan → 장비: 차단, 켜진 허용 규칙 6개가 예외. 꺼진 Traceroute 는 목록에만
        let input = try cell(.zone("wan"), .device)
        XCTAssertEqual(input.policy, "DROP")
        XCTAssertEqual(input.policySource, "wan zone input")
        XCTAssertFalse(input.allowed)
        XCTAssertEqual(input.exceptionText, "예외 규칙 6")
        XCTAssertEqual(input.rules.count, 7)
        XCTAssertTrue(input.rules.contains { $0.name == "Support-UDP-Traceroute" && !$0.enabled })
        // wan → lan: 적용 순서대로, 포트 포워딩은 규칙 뒤. 허용 쪽으로 센다 (wan→any · ESP · ISAKMP · GL 2)
        let inbound = try cell(.zone("wan"), .zone("lan"))
        XCTAssertEqual(inbound.policy, "REJECT")
        XCTAssertEqual(inbound.policySource, "defaults forward")
        XCTAssertEqual(inbound.rules.map(\.name), ["Allow-ICMPv6-Forward", "Allow-IPSec-ESP", "Allow-ISAKMP", "GL-nexus http", "GL-nexus https"])
        XCTAssertEqual(inbound.exceptionCount, 5)
        // lan → wan: forwarding
        let outbound = try cell(.zone("lan"), .zone("wan"))
        XCTAssertTrue(outbound.allowed)
        XCTAssertEqual(outbound.policySource, "forwarding lan → wan")
        XCTAssertNil(outbound.exceptionText)
        // 존의 forward 는 같은 존 안에서만: lan 은 forward ACCEPT 지만 wgserver 로는 forwarding 이 없어 defaults
        XCTAssertTrue(try cell(.zone("lan"), .zone("lan")).allowed)
        XCTAssertEqual(try cell(.zone("lan"), .zone("lan")).policySource, "lan zone forward")
        XCTAssertFalse(try cell(.zone("lan"), .zone("wgserver")).allowed)
        // 존에 forward 를 안 적은 wgserver 는 defaults 를 물려받는다
        XCTAssertEqual(try cell(.zone("wgserver"), .zone("wgserver")).policy, "REJECT")
        // 차단인 칸의 거부 규칙은 예외가 아니다 (목록에는 나온다)
        let visitor = try cell(.zone("wgserver"), .zone("lan"))
        XCTAssertEqual(visitor.rules.map(\.name), ["wgserver2lan-visitor"])
        XCTAssertEqual(visitor.exceptionCount, 0)
        XCTAssertEqual(try cell(.device, .zone("wan")).policySource, "wan zone output")
    }

    /// 칸마다 규칙이 어디로 가는지. 같은 설정을 `fw4 print`(openwrt/rootfs 23.05) 에 넣어 나온 체인과 대조했다:
    /// R-src-only → input_wan · R-src-any-dest → forward_wan · R-any-src-only → input · R-dest-only → output_wan · R-any-dest-only·R-neither → output ·
    /// R-both-any → forward · P-* → dstnat_wan (dest 없고 dest_ip 도 없으면 redirect = 장비로)
    func testMatrixRulePlacement() throws {
        func section(_ name: String, _ type: String, _ options: [String: String]) -> [String] {
            ["firewall.\(name)=\(type)"] + options.sorted { $0.key < $1.key }.map { "firewall.\(name).\($0.key)='\($0.value)'" }
        }
        var lines = ["@UCI"]
        lines += section("d", "defaults", ["forward": "REJECT"])
        lines += section("lan", "zone", ["name": "lan", "input": "ACCEPT", "output": "ACCEPT", "forward": "ACCEPT"])
        lines += section("wan", "zone", ["name": "wan", "input": "DROP", "output": "ACCEPT", "forward": "REJECT"])
        lines += section("wg", "zone", ["name": "wg", "input": "ACCEPT", "output": "ACCEPT"])
        lines += section("off", "zone", ["name": "off", "enabled": "0"])
        lines += section("f1", "forwarding", ["src": "lan", "dest": "wan"])
        lines += section("f2", "forwarding", ["src": "wg", "dest": "lan", "enabled": "0"])
        lines += section("r1", "rule", ["name": "R-src-only", "src": "wan", "target": "ACCEPT"])
        lines += section("r2", "rule", ["name": "R-src-any-dest", "src": "wan", "dest": "*", "target": "ACCEPT"])
        lines += section("r3", "rule", ["name": "R-any-src-only", "src": "*", "target": "ACCEPT"])
        lines += section("r4", "rule", ["name": "R-dest-only", "dest": "wan", "target": "REJECT"])
        lines += section("r5", "rule", ["name": "R-any-dest-only", "dest": "*", "target": "REJECT"])
        lines += section("r6", "rule", ["name": "R-neither", "target": "REJECT"])
        lines += section("r7", "rule", ["name": "R-both-any", "src": "*", "dest": "*", "target": "ACCEPT"])
        lines += section("r8", "rule", ["name": "R-notrack", "src": "wan", "target": "NOTRACK"])
        lines += section("p1", "redirect", ["name": "P-with-dest", "src": "wan", "dest": "lan", "dest_ip": "192.168.8.2", "target": "DNAT"])
        lines += section("p2", "redirect", ["name": "P-no-dest", "src": "wan", "dest_ip": "192.168.8.3"])
        lines += section("p3", "redirect", ["name": "P-no-ip", "src": "wan", "dest_port": "22"])
        lines += section("p4", "redirect", ["name": "P-snat", "src": "lan", "dest": "wan", "target": "SNAT"])
        lines.append("@END")
        let m = try XCTUnwrap(OpenWrtFirewall.parse(lines)).matrix
        XCTAssertFalse(m.rows.contains(.zone("off")), "꺼진 존은 판정에 없다")
        func names(_ from: Endpoint, _ to: Endpoint) throws -> [String] { try XCTUnwrap(m.cell(from: from, to: to)).rules.map(\.name) }
        let wan = Endpoint.zone("wan"), lan = Endpoint.zone("lan"), wg = Endpoint.zone("wg")
        // 적용 순서: "*" 규칙(공통 체인) → 존 체인 → 포트 포워딩
        XCTAssertEqual(try names(wan, .device), ["R-any-src-only", "R-src-only", "R-notrack", "P-no-ip"])
        XCTAssertEqual(try names(lan, .device), ["R-any-src-only"], "src=* 는 모든 존에서 장비로")
        XCTAssertEqual(try names(wan, lan), ["R-both-any", "R-src-any-dest", "P-with-dest", "P-no-dest"])
        XCTAssertEqual(try names(wan, wg), ["R-both-any", "R-src-any-dest", "P-no-dest"], "dest 없는 포트 포워딩은 어느 존일지 모른다")
        XCTAssertEqual(try names(lan, wg), ["R-both-any"])
        XCTAssertEqual(try names(lan, wan), ["R-both-any"], "SNAT 는 칸에 넣지 않는다")
        XCTAssertEqual(try names(.device, wan), ["R-any-dest-only", "R-neither", "R-dest-only"])
        XCTAssertEqual(try names(.device, lan), ["R-any-dest-only", "R-neither"], "src 도 dest 도 없으면 나가는 규칙")
        // 판정
        func policy(_ from: Endpoint, _ to: Endpoint) throws -> String { try XCTUnwrap(m.cell(from: from, to: to)).policySource }
        XCTAssertEqual(try policy(wg, lan), "defaults forward", "꺼진 forwarding 은 없는 것")
        XCTAssertEqual(try policy(wg, wg), "wg zone forward")
        // 예외: 허용 칸은 거부 규칙, 차단 칸은 허용 규칙. NOTRACK 은 어느 쪽도 아니다
        XCTAssertEqual(try XCTUnwrap(m.cell(from: .device, to: wan)).exceptionText, "거부 규칙 3")
        XCTAssertEqual(try XCTUnwrap(m.cell(from: wan, to: .device)).exceptionText, "예외 규칙 3")
        XCTAssertEqual(try XCTUnwrap(m.cell(from: wan, to: wan)).exceptionText, "예외 규칙 3", "wan→* 규칙 둘 + dest 없는 포트 포워딩 (forward_wan 의 ct status dnat accept 는 도착 존을 가리지 않는다)")
        XCTAssertNil(try XCTUnwrap(m.cell(from: lan, to: lan)).exceptionText, "허용 칸의 허용 규칙은 예외가 아니다")
    }

    /// 사용자 화면(2026-11-06)의 wgserver2lan: 잘린 픽스처에 화면에 나온 옵션을 채운다. 기본 정책은 REJECT 지만 실제론 10.0.0.99 만 막힌다
    func testMatrixUnconditionalRuleRealDevice() throws {
        var lines = try fixture("firewall")
        let at = try XCTUnwrap(lines.firstIndex(of: "firewall.wgserver2lan.src='wgserver'"))
        lines.insert(contentsOf: ["firewall.wgserver2lan.dest='lan'", "firewall.wgserver2lan.proto='all'", "firewall.wgserver2lan.family='ipv4'", "firewall.wgserver2lan.target='ACCEPT'"], at: at + 1)
        let cell = try XCTUnwrap(try XCTUnwrap(OpenWrtFirewall.parse(lines)).matrix.cell(from: .zone("wgserver"), to: .zone("lan")))
        XCTAssertEqual(cell.policy, "REJECT", "기본 정책은 그대로 보인다 (LuCI Zones 표와 같다)")
        XCTAssertEqual(cell.policySource, "defaults forward")
        XCTAssertEqual(cell.decidingRule?.name, "wgserver2lan")
        XCTAssertTrue(cell.allowed)
        XCTAssertEqual(cell.exceptionText, "거부 규칙 1", "위에 있는 visitor")
        XCTAssertEqual(cell.note, "기본 차단 · 거부 규칙 1", "판정이 기본 정책과 다르면 기본값도 함께, 위의 visitor 도 보인다")
    }

    /// 판정 순서는 같은 모양의 설정을 `fw4 print`(openwrt/rootfs 23.05) 에 넣어 나온 체인과 대조했다:
    /// forward_wg = visitor → all-ipv4 → after-full → 정책, forward_wan = 규칙 → `ct status dnat accept` → 정책, src=* 는 forward 체인에서 존 체인보다 먼저
    func testMatrixDecidingRule() throws {
        func section(_ name: String, _ type: String, _ options: [String: String]) -> [String] {
            ["firewall.\(name)=\(type)"] + options.sorted { $0.key < $1.key }.map { "firewall.\(name).\($0.key)='\($0.value)'" }
        }
        func rule(_ name: String, _ options: [String: String]) -> [String] { section(name, "rule", options.merging(["name": name]) { a, _ in a }) }
        func cell(_ rules: [[String]], from: String = "wg", to: String = "lan") throws -> FirewallMatrix.Cell {
            var lines = ["@UCI"] + section("d", "defaults", ["forward": "REJECT"])
            for zone in ["lan", "wan", "wg"] { lines += section(zone, "zone", ["name": zone, "input": "ACCEPT", "output": "ACCEPT"]) }
            lines += rules.flatMap { $0 } + ["@END"]
            return try XCTUnwrap(try XCTUnwrap(OpenWrtFirewall.parse(lines)).matrix.cell(from: .zone(from), to: .zone(to)))
        }
        let wgLan = ["src": "wg", "dest": "lan"]
        let acceptAll = wgLan.merging(["proto": "all", "target": "ACCEPT"]) { a, _ in a }
        func base(_ extra: [String: String]) -> [String: String] { acceptAll.merging(extra) { _, b in b } }

        // 위 규칙만 예외로 세고, 아래 규칙은 적용되지 않는다
        let ordered = try cell([rule("visitor", wgLan.merging(["src_ip": "10.0.0.99", "proto": "all", "target": "REJECT"]) { a, _ in a }),
                                rule("all", base(["family": "ipv4"])),
                                rule("after", wgLan.merging(["proto": "tcp", "dest_port": "22", "target": "REJECT"]) { a, _ in a })])
        XCTAssertTrue(ordered.allowed)
        XCTAssertEqual(ordered.decidingRule?.name, "all")
        XCTAssertEqual(ordered.exceptionText, "거부 규칙 1", "after 는 세지 않는다")
        XCTAssertEqual(ordered.rules.map { ordered.isShadowed($0) }, [false, false, true])

        // 조건이 하나라도 있으면 전체가 아니다
        XCTAssertNil(try cell([rule("noproto", wgLan.merging(["target": "ACCEPT"]) { a, _ in a })]).decidingRule, "proto 없음 = tcp·udp")
        XCTAssertNil(try cell([rule("two", wgLan.merging(["proto": "tcp udp", "target": "ACCEPT"]) { a, _ in a })]).decidingRule)
        for (name, extra) in [("ip", ["src_ip": "10.0.0.2"]), ("dstip", ["dest_ip": "192.168.8.2"]), ("port", ["dest_port": "22"]), ("srcport", ["src_port": "22"]),
                              ("limit", ["limit": "10/sec"]), ("mac", ["src_mac": "aa:bb:cc:dd:ee:ff"]), ("v6", ["family": "ipv6"])] {
            let c = try cell([rule(name, base(extra))])
            XCTAssertNil(c.decidingRule, name)
            XCTAssertFalse(c.allowed, "\(name): 기본 정책 그대로")
            XCTAssertEqual(c.exceptionText, "예외 규칙 1", name)
        }
        // 꺼진 규칙 · 판정이 아닌 target
        XCTAssertNil(try cell([rule("off", base(["enabled": "0"]))]).decidingRule)
        XCTAssertNil(try cell([rule("notrack", base(["target": "NOTRACK"]))]).decidingRule)
        for proto in ["all", "ALL", "any", "*"] {
            XCTAssertNotNil(try cell([rule("p", base(["proto": proto]))]).decidingRule, proto)
        }

        // 허용 칸을 막는 조건 없는 규칙: 뒤의 포트 포워딩도 못 지난다 (ct status dnat accept 가 규칙 뒤)
        let blocked = try cell([rule("noisy", ["src": "wan", "dest": "lan", "proto": "tcp", "dest_port": "1000", "target": "ACCEPT"]),
                                rule("reject", ["src": "wan", "dest": "lan", "proto": "all", "target": "REJECT"]),
                                section("p", "redirect", ["name": "dnat", "src": "wan", "dest": "lan", "dest_ip": "192.168.8.2", "src_dport": "80"])], from: "wan")
        XCTAssertFalse(blocked.allowed)
        XCTAssertEqual(blocked.rules.map(\.name), ["noisy", "reject", "dnat"])
        XCTAssertEqual(blocked.exceptionText, "예외 규칙 1", "noisy 만 — dnat 은 reject 아래")
        XCTAssertTrue(blocked.isShadowed(blocked.rules[2]))

        // src=* 는 설정 순서와 상관없이 존 체인보다 먼저
        let any = try cell([rule("zone-reject", base(["target": "REJECT"])), rule("any-accept", ["src": "*", "dest": "lan", "proto": "all", "target": "ACCEPT"])])
        XCTAssertEqual(any.rules.map(\.name), ["any-accept", "zone-reject"])
        XCTAssertEqual(any.decidingRule?.name, "any-accept")
        XCTAssertTrue(any.allowed)

        // 칸 둘째 줄: 기본 정책과 다를 때만 기본값을 붙인다
        XCTAssertEqual(blocked.note, "예외 규칙 1", "기본도 차단, 판정도 차단")
        XCTAssertEqual(try cell([]).note, nil, "규칙이 없으면 비운다")
        XCTAssertEqual(try cell([rule("cond", base(["dest_port": "22"]))]).note, "예외 규칙 1")
        XCTAssertEqual(try cell([rule("drop", base(["target": "DROP"]))], from: "lan", to: "lan").note, nil, "다른 방향의 규칙은 상관없다")
        let opened = try { () throws -> FirewallMatrix.Cell in
            var lines = ["@UCI"] + section("d", "defaults", ["forward": "ACCEPT"])
            for zone in ["lan", "wg"] { lines += section(zone, "zone", ["name": zone, "input": "ACCEPT", "output": "ACCEPT"]) }
            lines += rule("block", ["src": "wg", "dest": "lan", "proto": "all", "target": "DROP"]) + ["@END"]
            return try XCTUnwrap(try XCTUnwrap(OpenWrtFirewall.parse(lines)).matrix.cell(from: .zone("wg"), to: .zone("lan")))
        }()
        XCTAssertFalse(opened.allowed)
        XCTAssertEqual(opened.note, "기본 허용", "반대 방향도 같다. 예외가 없으면 기본값만")
    }

    /// 칸 누르기 과정: 열기 → 다른 칸으로 옮기기 → 같은 칸으로 닫기 → 새로고침으로 존이 사라짐 → 다시 열기
    func testMatrixSelectionSequence() throws {
        let m = try XCTUnwrap(OpenWrtFirewall.parse(try fixture("firewall"))).matrix
        let input = FirewallMatrix.Key(from: .zone("wan"), to: .device)
        let forward = FirewallMatrix.Key(from: .zone("wan"), to: .zone("lan"))
        var selection = FirewallSelection()
        XCTAssertNil(selection.cell(in: m), "처음엔 아무것도 안 펼친다")
        selection.tap(input)
        XCTAssertEqual(selection.cell(in: m)?.key, input)
        selection.tap(forward)
        XCTAssertEqual(selection.cell(in: m)?.key, forward, "다른 칸을 누르면 옮긴다 (닫혔다 열리지 않는다)")
        selection.tap(forward)
        XCTAssertNil(selection.key, "같은 칸을 또 누르면 닫는다")
        selection.tap(forward)
        selection.tap(forward)
        selection.tap(forward)
        XCTAssertEqual(selection.key, forward, "다시 열린다")
        // 새로고침: lan 존이 없어졌다
        let gone = try XCTUnwrap(OpenWrtFirewall.parse(["@UCI", "firewall.z=zone", "firewall.z.name='wan'", "@END"])).matrix
        XCTAssertNil(selection.cell(in: gone), "없어진 칸은 펼치지 않는다")
        selection.tap(input)
        XCTAssertEqual(selection.cell(in: gone)?.key, input, "남은 칸은 그대로 열린다")
        // 새로고침 뒤 같은 칸이 있으면 새 값으로
        XCTAssertEqual(selection.cell(in: m)?.policy, "DROP")
    }

    func testFirewallPortForwardsAndEdges() throws {
        let uci = #"""
        @UCI
        firewall.@redirect[0]=redirect
        firewall.@redirect[0].name='Web'
        firewall.@redirect[0].src='wan'
        firewall.@redirect[0].dest='lan'
        firewall.@redirect[0].proto='tcp' 'udp'
        firewall.@redirect[0].src_dport='8080'
        firewall.@redirect[0].dest_ip='192.168.8.2'
        firewall.@redirect[0].dest_port='80'
        firewall.@redirect[0].target='DNAT'
        firewall.same=redirect
        firewall.same.src='wan'
        firewall.same.proto='tcp'
        firewall.same.src_dport='22'
        firewall.same.dest_ip='192.168.8.3'
        firewall.same.src_ip='203.0.113.9'
        firewall.same.enabled='0'
        firewall.@zone[0]=zone
        firewall.@zone[0].name='x'
        firewall.@zone[0].enabled='off'
        firewall.@forwarding[0]=forwarding
        firewall.@forwarding[0].src='x'
        firewall.@forwarding[0].dest='y'
        firewall.@forwarding[0].enabled='0'
        firewall.out=rule
        firewall.out.dest='wan'
        firewall.out.dest_ip='8.8.8.8'
        firewall.out.dest_port='80' '443'
        firewall.out.target='reject'
        firewall.@nat[0]=nat
        firewall.@nat[0].name='ignored'
        @PORTFORWARD
        port_forward.@redirect[0]=redirect
        port_forward.@redirect[0].name='GL one'
        port_forward.@redirect[0].src_dport='9000'
        port_forward.@redirect[0].dest_ip='192.168.8.9'
        port_forward.@other[0]=other
        port_forward.@other[0].name='ignored'
        @END
        """#.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let fw = try XCTUnwrap(OpenWrtFirewall.parse(uci))
        XCTAssertEqual(fw.portForwards[0].match, "tcp/udp 8080 → 192.168.8.2:80")
        XCTAssertEqual(fw.portForwards[0].flow, "wan → lan")
        XCTAssertEqual(fw.portForwards[0].target, "DNAT")
        XCTAssertEqual(fw.portForwards[1].match, "tcp 22 → 192.168.8.3:22 · from 203.0.113.9", "dest_port 가 없으면 들어온 포트 그대로")
        XCTAssertEqual(fw.portForwards[1].name, "same", "이름이 없으면 섹션 이름")
        XCTAssertFalse(fw.portForwards[1].enabled)
        XCTAssertEqual(fw.portForwards[1].target, "DNAT", "target 기본값")
        XCTAssertEqual(fw.zones[0].forward, "DROP", "존에도 defaults 에도 없으면 DROP (fw4)")
        XCTAssertFalse(fw.zones[0].enabled)
        XCTAssertFalse(fw.forwardings[0].enabled)
        XCTAssertEqual(fw.rules[0].flow, "this device → wan", "src 가 없으면 장비에서 나가는 규칙")
        XCTAssertEqual(fw.rules[0].match, "tcp/udp 80,443 · to 8.8.8.8")
        XCTAssertEqual(fw.rules[0].target, "REJECT", "소문자로 적어도 대문자로")
        XCTAssertEqual(Set(fw.rules.map(\.id)).count, fw.rules.count)
        // firewall 것 먼저, 그다음 GL. 익명 섹션 이름 @redirect[0] 이 겹쳐도 ForEach 키는 달라야 한다
        XCTAssertEqual(fw.portForwards.map(\.name), ["Web", "same", "GL one"], "redirect 가 아닌 섹션은 뺀다")
        XCTAssertEqual(fw.portForwards.map(\.source), [nil, nil, "GL"])
        XCTAssertEqual(Set(fw.portForwards.map(\.id)).count, 3)
        // port_forward 가 없는 펌웨어 (구역이 비거나 아예 없다)
        let stock = ["@UCI", "firewall.@zone[0]=zone", "firewall.@zone[0].name='lan'"]
        XCTAssertEqual(try XCTUnwrap(OpenWrtFirewall.parse(stock + ["@PORTFORWARD", "@END"])).portForwards, [])
        XCTAssertEqual(try XCTUnwrap(OpenWrtFirewall.parse(stock + ["@END"])).portForwards, [])
        XCTAssertNotNil(OpenWrtFirewall.parse(["@UCI", "@PORTFORWARD", "port_forward.@redirect[0]=redirect", "@END"]), "firewall 을 못 읽어도 GL 포워딩은 보인다")
        XCTAssertNil(OpenWrtFirewall.parse(Array(uci.dropLast())), "끊긴 출력")
        XCTAssertNil(OpenWrtFirewall.parse(["@UCI", "@END"]), "uci 가 실패했으면 원문을 보여준다")
        XCTAssertNil(OpenWrtFirewall.parse([]))
        XCTAssertEqual(ParsedRemoteInfo.parse(.firewall, lines: uci, type: .openwrt), .firewall(fw))
    }

    func testNetworkDownInterfaceAndUnpluggedPort() throws {
        let lines = ["@IFACES",
                     #"{"interface":[{"interface":"wan","up":false,"proto":"dhcp","device":"eth1","errors":[{"subsystem":"interface","code":"NO_DEVICE"}]}]}"#,
                     "@DEVICES",
                     #"{"lan1":{"type":"Network device","devtype":"dsa","up":true,"carrier":false},"br-lan":{"type":"bridge","devtype":"bridge","speed":"1000F"}}"#,
                     "@END"]
        let network = try XCTUnwrap(OpenWrtNetwork.parse(lines))
        XCTAssertEqual(network.interfaces.first?.up, false)
        XCTAssertEqual(network.interfaces.first?.error, "NO_DEVICE")
        XCTAssertEqual(network.interfaces.first?.state, .unused, "장치가 없는 자리(GL.iNet secondwan)는 오류색이 아니다")
        XCTAssertEqual(network.interfaces.first?.device, "eth1", "l3_device 가 없으면 device")
        XCTAssertEqual(network.ports.map(\.name), ["lan1"], "선이 빠진 DSA 포트도 남기고 브리지는 뺀다")
        XCTAssertNil(network.ports.first?.speedMbps)
        // 2026-10-20 Brume 3: eth0.1(VLAN)이 부모 eth0 의 속도로 포트에 한 번 더 나왔다
        let vlan = ["@IFACES", #"{"interface":[{"interface":"lan","up":true,"device":"br-lan"},{"interface":"x","up":false,"errors":[{"code":"DEVICE_CLAIM_FAILED"}]},{"interface":"y","up":false}]}"#, "@DEVICES",
                    #"{"eth0":{"devtype":"ethernet","carrier":true,"speed":"2500F"},"eth0.1":{"devtype":"vlan","carrier":true,"speed":"2500F"},"eth0.2":{"carrier":true,"speed":"2500F"}}"#, "@END"]
        let parsed = try XCTUnwrap(OpenWrtNetwork.parse(vlan))
        XCTAssertEqual(parsed.ports.map(\.name), ["eth0"], "VLAN 은 devtype 이 없어도 이름(.)으로 뺀다")
        XCTAssertEqual(parsed.interfaces.map(\.state), [.up, .failed, .down])
        let unknown = ["@IFACES", #"{"interface":[]}"#, "@DEVICES", #"{"eth1":{"devtype":"ethernet","carrier":true,"speed":"-1F"},"eth2":{"devtype":"ethernet","carrier":true,"speed":"100H"}}"#, "@END"]
        let ports = try XCTUnwrap(OpenWrtNetwork.parse(unknown)).ports
        XCTAssertNil(ports[0].speedMbps, "-1F 는 모름 (1 Mbps 가 아니다)")
        XCTAssertEqual(ports[1].speedMbps, 100)
        XCTAssertEqual(ports[1].fullDuplex, false)
        XCTAssertNil(OpenWrtNetwork.parse(Array(lines.dropLast())), "끊긴 출력")
        XCTAssertNil(OpenWrtNetwork.parse(["@IFACES", "not json", "@END"]))
    }

    /// 포트 옆 인터페이스 이름: Brume 3 모양(wan=eth1, lan=br-lan ⊃ eth0.1)과 DSA 모양(br-lan.1 ⊃ lan1·lan2, wan6 은 l3_device 만 같음)
    func testPortInterfaces() throws {
        let brume = ["@IFACES",
                     #"{"interface":[{"interface":"wan","up":true,"l3_device":"eth1","device":"eth1"},{"interface":"lan","up":true,"l3_device":"br-lan","device":"br-lan"},{"interface":"secondwan","up":false}]}"#,
                     "@DEVICES",
                     #"{"br-lan":{"devtype":"bridge","bridge-members":["eth0.1"]},"eth0":{"devtype":"ethernet","carrier":true,"speed":"2500F"},"eth0.1":{"devtype":"vlan"},"eth1":{"devtype":"ethernet","carrier":true,"speed":"1000F"}}"#,
                     "@END"]
        let a = try XCTUnwrap(OpenWrtNetwork.parse(brume))
        XCTAssertEqual(a.ports.map(\.name), ["eth0", "eth1"])
        XCTAssertEqual(a.ports.map(\.interfaces), [["lan"], ["wan"]])
        let dsa = ["@IFACES",
                   #"{"interface":[{"interface":"lan","up":true,"l3_device":"br-lan.1","device":"br-lan.1"},{"interface":"wan","up":true,"l3_device":"wan","device":"wan"},{"interface":"wan6","up":true,"l3_device":"wan","device":"@wan"}]}"#,
                   "@DEVICES",
                   #"{"br-lan":{"devtype":"bridge","bridge-members":["lan1","lan2"]},"lan1":{"devtype":"dsa","carrier":true,"speed":"1000F"},"lan2":{"devtype":"dsa","carrier":false},"lan3":{"devtype":"dsa","carrier":false},"wan":{"devtype":"dsa","carrier":true,"speed":"1000F"}}"#,
                   "@END"]
        let b = try XCTUnwrap(OpenWrtNetwork.parse(dsa))
        XCTAssertEqual(b.ports.map(\.name), ["lan1", "lan2", "lan3", "wan"])
        XCTAssertEqual(b.ports.map(\.interfaces), [["lan"], ["lan"], [], ["wan", "wan6"]], "어느 인터페이스에도 없는 포트는 빈칸")
    }

    // MARK: Clients

    func testClients() throws {
        // 이 픽스처는 @NEIGH·@ALIAS 를 넣기 전 스크립트 출력이라 ip 가 없는 공유기와 같은 길(ARP 표)로 읽힌다
        let clients = try XCTUnwrap(OpenWrtClients.parse(try fixture("clients")))
        // 임대 4 + 고정 할당의 두 번째 MAC 1. WAN 쪽 ARP(eth0 의 상위 게이트웨이)는 장비가 아니다
        XCTAssertEqual(clients.map(\.ip), ["192.168.8.5", "192.168.8.5", "192.168.8.20", "192.168.8.103", "192.168.8.150"], "IP 순")
        XCTAssertFalse(clients.contains { $0.ip == "172.30.0.1" })
        let pi = try XCTUnwrap(clients.first { $0.mac == "dc:a6:32:12:34:56" })
        XCTAssertEqual(pi.leaseRemaining, .infinity, "만료 0 = 무기한")
        XCTAssertTrue(pi.isStatic)
        let piSecond = try XCTUnwrap(clients.first { $0.mac == "dc:a6:32:12:34:57" })
        XCTAssertNil(piSecond.leaseRemaining, "임대 없는 고정 할당")
        XCTAssertEqual(piSecond.name, "pi")
        let nas = try XCTUnwrap(clients.first { $0.mac == "00:11:32:aa:bb:cc" })
        XCTAssertEqual(nas.name, "nas", "임대 이름이 * 면 고정 할당 이름")
        XCTAssertEqual(nas.leaseRemaining, 0, "만료 시각이 공유기 시계보다 앞 — 0")
        let nexus = try XCTUnwrap(clients.first { $0.name == "nexus" })
        XCTAssertFalse(nexus.isStatic)
        XCTAssertEqual(nexus.leaseRemaining, 1792498352 - 1792458681, "만료 − 공유기 now")
    }

    func testClientsArp() throws {
        let lines = ["@NOW", "1000", "@LEASES", "2000 AA:BB:CC:00:00:01 192.168.8.103 nexus *",
                     "@STATIC", "@ARP",
                     "IP address       HW type     Flags       HW address            Mask     Device",
                     "192.168.8.103    0x1         0x2         aa:bb:cc:00:00:01     *        br-lan",
                     "192.168.8.77     0x1         0x2         12:34:56:78:9a:bc     *        br-guest",
                     "192.168.8.88     0x1         0x0         00:00:00:00:00:00     *        br-lan",
                     "203.0.113.1      0x1         0x2         de:ad:be:ef:00:01     *        wan",
                     "@END"]
        let clients = try XCTUnwrap(OpenWrtClients.parse(lines))
        XCTAssertEqual(clients.map(\.mac), ["12:34:56:78:9a:bc", "aa:bb:cc:00:00:01"], "MAC 은 소문자로 합치고, 미완성·WAN ARP 는 뺀다 (IP 순)")
        XCTAssertEqual(clients[1].leaseRemaining, 1000)
        XCTAssertTrue(clients[1].active)
        XCTAssertTrue(clients[0].active)
        XCTAssertEqual(clients[0].ip, "192.168.8.77", "고정 IP 장비는 ARP 로만 보인다")
        XCTAssertNil(clients[0].leaseRemaining)
        XCTAssertNil(OpenWrtClients.parse(Array(lines.dropLast())))
    }

    /// 2026-10-20 Brume 3(GL.iNet) 출력 모양 (MAC·이름은 바꾼 값). GL 별칭은 gl-client 에, dhcp host 에는 name 대신 tag.
    /// 활성은 ip neigh: GL 화면 온라인 2대(REACHABLE) · 오프라인(STALE·FAILED)과 같아야 한다 — ARP 표로는 STALE 인 .101 이 초록이었다
    func testClientsGLAliasAndNeighbor() throws {
        let lines = ["@NOW", "1000",
                     "@LEASES", "5000 02:00:00:00:00:03 192.168.8.103 nexus 01:02:00:00:00:00:03",
                     "5000 02:00:00:00:00:05 192.168.8.105 myiPhone 01:02:00:00:00:00:05",
                     "@STATIC",
                     "dhcp.@host[2]=host", "dhcp.@host[2].mac='02:00:00:00:00:99'", "dhcp.@host[2].ip='192.168.8.99'", "dhcp.@host[2].tag='Core'",
                     "dhcp.@host[3]=host", "dhcp.@host[3].mac='02:00:00:00:00:01'", "dhcp.@host[3].ip='192.168.8.101'",
                     "dhcp.@host[4]=host", "dhcp.@host[4].mac='02:00:00:00:00:02'", "dhcp.@host[4].ip='192.168.8.102'",
                     "@ARP",
                     "IP address       HW type     Flags       HW address            Mask     Device",
                     "192.168.8.101    0x1         0x2         02:00:00:00:00:01     *        br-lan",
                     "@NEIGH",
                     "192.168.8.105 dev br-lan FAILED",
                     "192.168.8.102 dev br-lan FAILED",
                     "203.0.113.1 dev eth1 lladdr 02:00:00:00:00:fe REACHABLE",
                     "192.168.8.118 dev br-lan lladdr 02:00:00:00:00:05 STALE",
                     "192.168.8.103 dev br-lan lladdr 02:00:00:00:00:03 REACHABLE",
                     "192.168.8.101 dev br-lan lladdr 02:00:00:00:00:01 STALE",
                     "192.168.8.99 dev br-lan lladdr 02:00:00:00:00:99 ref 1 used 0/0/0 probes 4 REACHABLE",
                     "fe80::1 dev br-lan lladdr 02:00:00:00:00:77 REACHABLE",
                     "@ALIAS",
                     "gl-client.@client[0]=client", "gl-client.@client[0].mac='02:00:00:00:00:02'", "gl-client.@client[0].alias='window-pc'",
                     "gl-client.@client[1]=client", "gl-client.@client[1].mac='02:00:00:00:00:01'", "gl-client.@client[1].alias='TP-link 2.5G NIC'",
                     "gl-client.@client[2]=client", "gl-client.@client[2].mac='02:00:00:00:00:03'", "gl-client.@client[2].alias='Nexus'",
                     "gl-client.@client[3]=client", "gl-client.@client[3].mac='02:00:00:00:00:99'", "gl-client.@client[3].alias='Core'",
                     "gl-client.@client[4]=client", "gl-client.@client[4].mac='02:00:00:00:00:44'", "gl-client.@client[4].alias='gone'",
                     "@END"]
        let clients = try XCTUnwrap(OpenWrtClients.parse(lines))
        XCTAssertEqual(clients.map(\.ip), ["192.168.8.99", "192.168.8.101", "192.168.8.102", "192.168.8.103", "192.168.8.105"],
                       "IPv6·WAN 이웃과 목록에 없는 별칭(gone)은 장비로 더하지 않는다")
        XCTAssertEqual(clients.map(\.name), ["Core", "TP-link 2.5G NIC", "window-pc", "Nexus", "myiPhone"], "GL 별칭 → 임대 이름")
        XCTAssertEqual(clients.filter(\.active).map(\.ip), ["192.168.8.99", "192.168.8.103"], "REACHABLE 만 — STALE·FAILED 는 활성이 아니다")
        XCTAssertEqual(clients.last?.ip, "192.168.8.105", "다른 IP 의 STALE 이웃이 임대 IP 를 덮지 않는다")

        // ip 가 없는 공유기(@NEIGH 구역 없음)는 ARP 표 — 예전처럼 완성 항목이면 활성
        let noIP = try XCTUnwrap(OpenWrtClients.parse(lines.filter { !$0.contains(" dev ") && $0 != "@NEIGH" }))
        XCTAssertEqual(noIP.filter(\.active).map(\.ip), ["192.168.8.101"])
    }

    func testUciValues() {
        XCTAssertEqual(OpenWrtClients.uciValues("'a' 'b c'"), ["a", "b c"])
        XCTAssertEqual(OpenWrtClients.uciValues("'x'"), ["x"])
        XCTAssertEqual(OpenWrtClients.uciValues("host"), ["host"])
        XCTAssertEqual(OpenWrtClients.uciValues(""), [])
        XCTAssertEqual(OpenWrtClients.uciValues(#"'Bob'\''s iPhone'"#), ["Bob's iPhone"], "uci 가 ' 를 '\\'' 로 내보낸다")
    }

    // MARK: WireGuard

    func testWireGuard() throws {
        guard case let .interfaces(interfaces) = try XCTUnwrap(WireGuardReport.parse(try fixture("wireguard"))) else {
            return XCTFail("wg 가 있는 출력")
        }
        XCTAssertEqual(interfaces.map(\.name), ["wgclient", "wgserver"])
        let server = interfaces[1]
        XCTAssertEqual(server.listenPort, 51820)
        XCTAssertEqual(server.publicKey, "4Ksb6B9C+FGo3C3h1joJoIoO8yOZtHcKtDeIqrzNw2I=", "지운 개인 키(-) 자리가 아니라 공개 키")
        XCTAssertEqual(server.peers.map(\.name), ["iPhone", "MacBook"], "uci description 을 공개 키로 잇는다")
        let phone = server.peers[0]
        XCTAssertEqual(phone.handshakeAgo, 9)
        XCTAssertTrue(phone.isActive)
        XCTAssertEqual(phone.endpoint, "127.0.0.1:35634")
        XCTAssertEqual(phone.allowedIPs, ["10.0.0.2/32"])
        XCTAssertEqual(phone.rxBytes, 1200)
        XCTAssertEqual(phone.txBytes, 368)
        XCTAssertNil(phone.keepalive)
        let laptop = server.peers[1]
        XCTAssertNil(laptop.handshakeAgo, "핸드셰이크 0 = 한 번도 없음")
        XCTAssertFalse(laptop.isActive)
        XCTAssertNil(laptop.endpoint)
        let client = interfaces[0]
        XCTAssertEqual(client.peers.first?.name, "brume server")
        XCTAssertEqual(client.peers.first?.keepalive, 25)
        // 받은 출력 어디에도 키를 지운 자리 말고는 비밀 값이 없다 (사전 공유 키 칸은 - 또는 (none))
        XCTAssertTrue(try fixture("wireguard").filter { $0.hasPrefix("wg") }.allSatisfy { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            return f.count == 5 ? f[1] == "-" : (f[2] == "-" || f[2] == "(none)")
        })
    }

    func testWireGuardStaleAndMissing() throws {
        let stale = ["@NOW", "1000", "@WG",
                     "wg0    -    PUB=    51820    off",
                     "wg0    PEER=    (none)    1.2.3.4:51820    10.0.0.2/32,fd00::2/128    800    10    20    off",
                     "@NAMES", "@END"]
        guard case let .interfaces(interfaces) = try XCTUnwrap(WireGuardReport.parse(stale)) else { return XCTFail() }
        let peer = try XCTUnwrap(interfaces.first?.peers.first)
        XCTAssertEqual(peer.handshakeAgo, 200)
        XCTAssertFalse(peer.isActive, "3분이 넘은 핸드셰이크는 끊긴 것")
        XCTAssertEqual(peer.allowedIPs, ["10.0.0.2/32", "fd00::2/128"])
        XCTAssertNil(peer.name)
        // 스크립트: 칸 수 5·9 인 줄만 키를 지워 보내고, 그 밖의 줄(어디가 키인지 모름)은 보내지 않는다
        XCTAssertTrue(OpenWrt.wireguardScript.contains(#"NF == 5 { $2 = "-"; print } NF == 9 { if ($3 != "(none)") $3 = "-"; print }'"#))
        XCTAssertFalse(OpenWrt.wireguardScript.contains("{ print }"), "조건 없는 print 가 있으면 형식이 다른 줄의 키가 그대로 나간다")
        XCTAssertEqual(WireGuardReport.parse(["@NOW", "1", "@NOWG", "@NAMES", "@END"]), .notInstalled)
        XCTAssertEqual(WireGuardReport.parse(["@NOW", "1", "@WG", "@NAMES", "@END"]), .interfaces([]))
        XCTAssertNil(WireGuardReport.parse(["@NOW", "1", "@WG"]), "끊긴 출력")
    }

    // MARK: Services

    func testServices() throws {
        let report = try XCTUnwrap(OpenWrtServices.parse(try fixture("services")))
        XCTAssertEqual(report.stopped.map(\.name), ["dnsmasq", "sysntpd"], "켜 뒀는데 exit 1 로 멈춘 procd 서비스")
        XCTAssertEqual(report.stopped.first?.exitCode, 1)
        XCTAssertEqual(report.running.map(\.name), ["dropbear", "log", "network", "odhcpd", "rpcd", "uhttpd", "urngd"])
        // exit 0 으로 끝난 일회성 작업 · procd 가 모르는 스크립트 · 꺼 둔 서비스는 그 밖
        XCTAssertTrue(report.other.contains { $0.name == "urandom_seed" })
        XCTAssertTrue(report.other.contains { $0.name == "boot" && !$0.managed })
        XCTAssertEqual(report.other.first { $0.name == "umount" }?.enabled, false)
        let all = report.stopped.count + report.running.count + report.other.count
        XCTAssertEqual(all, 22, "init.d 스크립트마다 한 번씩")
        XCTAssertNil(OpenWrtServices.parse(["@PROCD", "{}", "@INIT"]), "끊긴 출력")
    }

    func testServiceLogCommand() {
        XCTAssertEqual(OpenWrt.serviceLogCommand(name: "dnsmasq"), "logread -e 'dnsmasq' 2>/dev/null | tail -n 50")
        XCTAssertNil(OpenWrt.serviceLogCommand(name: "a;reboot"))
        XCTAssertNil(OpenWrt.serviceLogCommand(name: ""))
    }

    // MARK: Ports · Live

    func testPorts() throws {
        let ports = RemoteInfo.parsePorts(try fixture("ports"))
        XCTAssertEqual(ports.map(\.port), [22, 80, 443, 41213])
        XCTAssertEqual(ports.first?.addresses, ["*"], "busybox netstat 의 0.0.0.0 · ::: 도 모든 주소 한 줄")
        XCTAssertEqual(ports.first?.tunnelAddress, "*")
        XCTAssertEqual(ports.last?.addresses, ["127.0.0.11"])
    }

    /// eMMC 부트·보안 영역은 장치 목록·속도에서 뺀다 (옛 스크립트가 보낸 줄이 와도 파서가 거른다)
    func testEMMCBootAreasAreNotDisks() throws {
        let blk = "mmcblk0 0 0 15269888 \nmmcblk0boot0 0 0 8192 \nmmcblk0boot1 0 0 8192 \nmmcblk0rpmb 0 0 8192 \nsda 0 0 976773168 PSSD T7 Touch"
        let disk = ["mmcblk0", "mmcblk0boot0", "mmcblk0boot1", "sda"].map { " 179 0 \($0) 10 0 100 0 5 0 50 0 0 0 0" }.joined(separator: "\n")
        let text = "@INFO\n100\n4096\nTest\n@UP\n100.0 50.0\n@STAT\ncpu 0 0 0 1000 0 0 0 0\n@LOAD\n0.1 0.1 0.1 1/1 1\n@MEM\nMemTotal: 1000 kB\n@DISK\n\(disk)\n@BLK\n\(blk)\n@DF\n@TEMP\n@PROC\n@END\n"
        let raw = try XCTUnwrap(LinuxRaw.parse(text))
        XCTAssertEqual(Set(raw.diskInfo.keys), ["mmcblk0", "sda"])
        XCTAssertEqual(Set(raw.disks.keys), ["mmcblk0", "sda"])
        XCTAssertEqual(raw.diskInfo["sda"]?.model, "PSSD T7 Touch")
        XCTAssertTrue(LinuxLive.script.contains("mmcblk*boot*|mmcblk*rpmb"))
    }

    /// busybox df 에는 -l 이 없다 — 예전 스크립트는 @DF 가 비어 디스크가 하나도 안 보였다
    func testLiveOnBusybox() throws {
        let raw = try XCTUnwrap(LinuxRaw.parse(try fixtureText("openwrt-live")))
        XCTAssertTrue(raw.volumes.contains { $0.mountPoint == "/" && $0.fsType == "overlay" })
        XCTAssertFalse(raw.volumes.contains { $0.fsType == "tmpfs" })
        XCTAssertNotNil(raw.cpu)
        XCTAssertGreaterThan(raw.memory["MemTotal"] ?? 0, 0)
        XCTAssertFalse(raw.processes.isEmpty)
        XCTAssertTrue(LinuxLive.script.contains("if [ -n \"$out\" ]; then") && LinuxLive.script.contains("else\n  $t df -kPT 2>/dev/null"),
                      "-l 결과가 비었을 때만 다시")
    }
}
