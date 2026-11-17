import Foundation
@testable import ServersCore
import XCTest

final class RouteTableTests: XCTestCase {
    /// Fixtures/netstat-routes-inet.txt 는 이 Mac(WireGuard 전체 터널 + 유선·Wi-Fi 같은 대역 + OrbStack·VM 브리지)에서
    /// `netstat -rn -f inet` 을 그대로 받은 것 (98줄, ARP 의 MAC 만 0 으로 가림)
    private func realOutput() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/netstat-routes-inet.txt")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 수백 줄 중 남는 건 default 3 · 대역 4 — 호스트 캐시(W)·ARP·멀티캐스트·lo0·169.254·브로드캐스트·자기 주소·브리지 default 는 빠진다
    func testRealOutputKeepsDefaultsAndNetworksOnly() throws {
        let entries = RouteTable.parse(try realOutput())
        XCTAssertEqual(entries.map(\.destination), ["default", "default", "default", "10.1.0.0/24", "192.168.8.0/24", "192.168.107.0/24", "192.168.138.0/23"])
        XCTAssertEqual(entries.map(\.interfaces), [["utun6"], ["en11"], ["en0"], ["utun6"], ["en11", "en0"], ["bridge101"], ["bridge100"]])
        XCTAssertEqual(entries.map(\.gateway), [nil, "192.168.8.1", "192.168.8.1", "10.1.0.2", nil, nil, nil])
        XCTAssertEqual(entries.map(\.kind), [.primary, .scoped, .scoped, .route, .route, .route, .route])
    }

    /// Fixtures/scutil-nwi.txt 는 같은 Mac 에서 `scutil --nwi` 를 그대로 받은 것 (utun6 > en11 > en0)
    private func realOrder() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/scutil-nwi.txt")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 실제 출력: IPv4 블록 순서만 (IPv6 블록·REACH·"Network interfaces:" 줄은 안 읽는다) → default 에 1·2·3
    func testRealOrderRanksDefaults() throws {
        let order = RouteTable.parseInterfaceOrder(try realOrder())
        XCTAssertEqual(order, ["utun6", "en11", "en0"])
        let defaults = RouteTable.parse(try realOutput(), order: order).filter { $0.destination == "default" }
        XCTAssertEqual(defaults.map(\.interfaces), [["utun6"], ["en11"], ["en0"]])
        XCTAssertEqual(defaults.map(\.rank), [1, 2, 3])
        XCTAssertNil(RouteTable.parse(try realOutput(), order: order).first { $0.destination != "default" }?.rank)
    }

    /// 묶인 default 는 netstat 순서가 아니라 서비스 순서대로 (스크린샷: netstat 은 en0 을 먼저 찍지만 순위는 en11 이 앞)
    func testScopedDefaultsFollowServiceOrderNotNetstat() {
        let text = """
        Destination        Gateway            Flags               Netif Expire
        default            link#26            UCSg                utun6
        default            192.168.8.1        UGScIg                en0
        default            192.168.8.1        UGScIg               en11
        """
        let entries = RouteTable.parse(text, order: ["utun6", "en11", "en0"])
        XCTAssertEqual(entries.map(\.interfaces), [["utun6"], ["en11"], ["en0"]])
        XCTAssertEqual(entries.map(\.rank), [1, 2, 3])
    }

    /// 순서 목록에 없는 장치는 번호 없이 맨 뒤, 화면에서 빠진 default(라우터 없는 브리지)는 번호를 건너뛰게 하지 않는다
    func testRanksAreContiguousAndUnknownDevicesLast() {
        let text = """
        Destination        Gateway            Flags               Netif Expire
        default            10.9.9.1           UGScIg               en5
        default            link#26            UCSg                utun6
        default            link#30            UCSIg           bridge100
        default            192.168.8.1        UGScIg                en0
        """
        let entries = RouteTable.parse(text, order: ["utun6", "bridge100", "en0"])
        XCTAssertEqual(entries.map(\.interfaces), [["utun6"], ["en0"], ["en5"]])
        XCTAssertEqual(entries.map(\.rank), [1, 2, nil])
    }

    /// 읽는 시점이 달라 서비스 순서 1위가 쓰이는 default 와 다르면, 쓰이는 default(딱지)가 1 — 딱지와 번호가 엇갈리지 않게
    func testPrimaryIsRankOneEvenIfOrderDisagrees() {
        let text = """
        Destination        Gateway            Flags               Netif Expire
        default            192.168.8.1        UGScIg               en11
        default            192.168.8.1        UGSc                  en0
        """
        let entries = RouteTable.parse(text, order: ["en11", "en0"])
        XCTAssertEqual(entries.map(\.interfaces), [["en0"], ["en11"]])
        XCTAssertEqual(entries.map(\.kind), [.primary, .scoped])
        XCTAssertEqual(entries.map(\.rank), [1, 2])
    }

    /// 순서를 못 읽으면 번호 없이 예전처럼 (쓰이는 default → netstat 순서)
    func testNoRanksWithoutOrder() {
        let text = """
        Destination        Gateway            Flags               Netif Expire
        default            192.168.8.1        UGScIg                en0
        default            link#26            UCSg                utun6
        default            192.168.8.1        UGScIg               en11
        """
        let entries = RouteTable.parse(text)
        XCTAssertEqual(entries.map(\.interfaces), [["utun6"], ["en0"], ["en11"]])
        XCTAssertEqual(entries.map(\.rank), [nil, nil, nil])
    }

    /// 0/1 · 128.0/1 짝(OpenVPN def1 등)은 맨 위, 딱지는 짝에 — default 는 접두사가 짧아 밀리므로 딱지를 떼고 옅게
    func testSplitDefaultPairBeatsDefault() {
        let text = """
        Destination        Gateway            Flags               Netif Expire
        default            192.168.8.1        UGScg                 en0
        0/1                10.8.0.1           UGScg               utun3
        10.8/24            link#30            UCS                 utun3
        128.0/1            10.8.0.1           UGScg               utun3
        """
        let table = RouteTable(entries: RouteTable.parse(text, order: ["en0"]), interfaces: [:])
        XCTAssertEqual(table.entries.map(\.destination), ["0.0.0.0/1", "128.0.0.0/1", "default", "10.8.0.0/24"])
        XCTAssertEqual(table.entries.map(\.kind), [.splitDefault, .splitDefault, .primary, .route])
        XCTAssertEqual(table.entries.map(\.rank), [nil, nil, 1, nil])
        XCTAssertEqual(table.entries.map(table.carriesTraffic), [true, true, false, false])
    }

    /// 짝 중 한쪽만 있으면 절반만 덮으니 그냥 대역 — 딱지는 default 그대로
    func testHalfSplitIsPlainRoute() {
        let text = """
        Destination        Gateway            Flags               Netif Expire
        default            192.168.8.1        UGScg                 en0
        0/1                10.8.0.1           UGScg               utun3
        """
        let table = RouteTable(entries: RouteTable.parse(text), interfaces: [:])
        XCTAssertEqual(table.entries.map(\.kind), [.primary, .route])
        XCTAssertEqual(table.entries.map(table.carriesTraffic), [true, false])
    }

    /// IPv4 상태가 없거나 빈 출력이면 빈 순서 (IPv6 블록 장치를 끌어오지 않는다)
    func testInterfaceOrderEmptyCases() {
        XCTAssertEqual(RouteTable.parseInterfaceOrder(""), [])
        let noV4 = """
        Network information

        IPv4 network interface information
           No IPv4 states found

        IPv6 network interface information
           utun6 : flags      : 0x7 (IPv4,IPv6,DNS)

        Network interfaces: utun6
        """
        XCTAssertEqual(RouteTable.parseInterfaceOrder(noV4), [])
    }

    /// 쓰이는 default 는 묶이지 않은(I 없는) 첫 줄 — netstat 이 묶인 줄을 먼저 찍어도 맨 위로
    func testPrimaryDefaultIsFirstUnscopedEvenIfListedLater() {
        let text = """
        Destination        Gateway            Flags               Netif Expire
        default            192.168.8.1        UGScIg               en0
        default            192.168.8.1        UGScg               en11
        default            10.0.0.1           UGSc                en12
        """
        let entries = RouteTable.parse(text)
        XCTAssertEqual(entries.map(\.interfaces), [["en11"], ["en0"], ["en12"]])
        XCTAssertEqual(entries.map(\.kind), [.primary, .scoped, .scoped])
    }

    /// 모두 묶인 default 면 쓰이는 줄 표시는 없다 (거짓 "기본 경로" 딱지 X)
    func testNoPrimaryWhenEveryDefaultIsScoped() {
        let text = """
        Destination        Gateway            Flags               Netif Expire
        default            192.168.8.1        UGScIg               en0
        """
        XCTAssertEqual(RouteTable.parse(text).map(\.kind), [.scoped])
    }

    /// 라우터를 거치는 호스트 경로(VPN 서버 주소를 유선으로 빼는 등)는 남기고, 라우터 없는 호스트(자기 주소·p2p 상대)는 뺀다
    func testHostRouteKeptOnlyViaRouter() {
        let text = """
        Destination        Gateway            Flags               Netif Expire
        203.0.113.5        192.168.8.1        UGHS                 en11
        10.1.0.2           10.1.0.2           UH                  utun6
        192.168.8.101/32   link#9             UCS                  en11      !
        """
        let entries = RouteTable.parse(text)
        XCTAssertEqual(entries.map(\.destination), ["203.0.113.5"])
        XCTAssertEqual(entries.first?.gateway, "192.168.8.1")
    }

    /// Linux 처럼 네 옥텟·"/길이" — netstat 이 줄인 0 옥텟을 채우고, 생략된 길이는 A·B·C 클래스대로. 호스트는 "/32" 없이
    func testNormalizeWritesFullOctetsLikeLinux() {
        XCTAssertEqual(RouteTable.normalize("10"), "10.0.0.0/8")
        XCTAssertEqual(RouteTable.normalize("172.16"), "172.16.0.0/16")
        XCTAssertEqual(RouteTable.normalize("192.168.8"), "192.168.8.0/24")
        XCTAssertEqual(RouteTable.normalize("10.1/24"), "10.1.0.0/24")
        XCTAssertEqual(RouteTable.normalize("192.168.138/23"), "192.168.138.0/23")
        XCTAssertEqual(RouteTable.normalize("224.0.0/4"), "224.0.0.0/4")
        XCTAssertEqual(RouteTable.normalize("203.0.113.5"), "203.0.113.5")
        XCTAssertEqual(RouteTable.normalize("203.0.113.5/32"), "203.0.113.5")
        XCTAssertEqual(RouteTable.normalize("garbage"), "garbage")
    }

    /// 라우터 거치는 "/32" 경로도 호스트로 보여 준다
    func testSlash32HostViaRouterShownWithoutLength() {
        let text = """
        Destination        Gateway            Flags               Netif Expire
        203.0.113.5/32     192.168.8.1        UGSc                 en11
        """
        XCTAssertEqual(RouteTable.parse(text).map(\.destination), ["203.0.113.5"])
    }

    /// 빈 출력·머리줄 없는 출력은 빈 목록 (머리줄 앞 "Routing tables" · "Internet:" 을 행으로 읽지 않는다)
    func testEmptyAndHeaderlessOutput() {
        XCTAssertEqual(RouteTable.parse(""), [])
        XCTAssertEqual(RouteTable.parse("Routing tables\n\nInternet:\n"), [])
        XCTAssertEqual(RouteTable.parse("default 192.168.8.1 UGSc en0\n"), [])
    }

    /// 설명은 IP, MTU 는 1500 아닐 때만. 합친 줄은 장치마다, ifconfig 에 없는 장치는 건너뛴다
    func testDetailShowsIPAndNonDefaultMTU() {
        let ifconfig = """
        en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tinet6 fe80::1%en0 prefixlen 64
        \tinet 192.168.8.104 netmask 0xffffff00 broadcast 192.168.8.255
        en11: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tinet 192.168.8.101 netmask 0xffffff00 broadcast 192.168.8.255
        \tinet 192.168.8.200 netmask 0xffffff00 broadcast 192.168.8.255
        utun6: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1420
        \tinet 10.1.0.2 --> 10.1.0.2 netmask 0xffffff00
        bridge101: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        """
        let details = RouteTable.parseInterfaceDetails(ifconfig)
        XCTAssertEqual(details["en11"], InterfaceDetail(ip: "192.168.8.101", mtu: 1500))   // 첫 IPv4
        XCTAssertEqual(details["bridge101"], InterfaceDetail(ip: nil, mtu: 1500))
        let table = RouteTable(entries: [], interfaces: details)
        XCTAssertEqual(table.detail(for: RouteEntry(destination: "default", gateway: nil, interfaces: ["utun6"], kind: .primary)), "10.1.0.2 · MTU 1420")
        XCTAssertEqual(table.detail(for: RouteEntry(destination: "192.168.8/24", gateway: nil, interfaces: ["en11", "en0"], kind: .route)), "192.168.8.101, 192.168.8.104")
        XCTAssertEqual(table.detail(for: RouteEntry(destination: "192.168.107/24", gateway: nil, interfaces: ["bridge101", "gone9"], kind: .route)), "")
    }

    /// VPN 터널 줄은 나가는 물리 장치를 잇는다 ("→ en11"). 터널이 아닌 줄·ifconfig 정보 없는 터널도 처리
    func testDetailAppendsTunnelEgress() {
        let table = RouteTable(entries: [], interfaces: ["utun6": InterfaceDetail(ip: "10.1.0.2", mtu: 1420), "en0": InterfaceDetail(ip: "192.168.8.104", mtu: 1500)],
                               tunnelEgress: ["utun6": ["en11"], "utun9": ["en0", "en11"], "utun3": []])
        XCTAssertEqual(table.detail(for: RouteEntry(destination: "default", gateway: nil, interfaces: ["utun6"], kind: .primary)), "10.1.0.2 · MTU 1420 → en11")
        XCTAssertEqual(table.detail(for: RouteEntry(destination: "default", gateway: nil, interfaces: ["utun9"], kind: .primary)), "→ en0, en11")
        XCTAssertEqual(table.detail(for: RouteEntry(destination: "default", gateway: nil, interfaces: ["utun3"], kind: .primary)), "")
        XCTAssertEqual(table.detail(for: RouteEntry(destination: "default", gateway: "192.168.8.1", interfaces: ["en0"], kind: .scoped)), "192.168.8.104")
    }

    /// netstat 실패면 nil (화면이 "읽지 못했습니다"), 성공이면 ifconfig 까지 읽어 묶는다
    func testFetchReturnsNilWhenNetstatFails() async {
        final class Runner: CommandRunner, @unchecked Sendable {
            let netstat: CommandResult
            init(_ netstat: CommandResult) { self.netstat = netstat }
            func hasExecutable(_ name: String) -> Bool { true }
            func run(_ executable: String, _ arguments: [String], stdin: String?, environment: [String: String], timeout: TimeInterval) async -> CommandResult {
                switch executable {
                case "netstat": return netstat
                case "ifconfig": return CommandResult(exitCode: 0, stdout: "utun6: flags=8051<UP> mtu 1420\n\tinet 10.1.0.2 --> 10.1.0.2 netmask 0xffffff00\n")
                case "scutil": return CommandResult(exitCode: 0, stdout: "IPv4 network interface information\n   utun6 : flags      : 0x7 (IPv4,IPv6,DNS)\n")
                default: return CommandResult(exitCode: 127)
                }
            }
        }
        let failed = await RouteTable.fetch(runner: Runner(CommandResult(exitCode: CommandResult.timedOutExitCode)))
        XCTAssertNil(failed)
        let ok = await RouteTable.fetch(runner: Runner(CommandResult(exitCode: 0, stdout: "Destination Gateway Flags Netif Expire\ndefault link#26 UCSg utun6\n")))
        XCTAssertEqual(ok?.entries.map(\.kind), [.primary])
        XCTAssertEqual(ok?.entries.map(\.rank), [1])
        XCTAssertEqual(ok?.interfaces["utun6"]?.mtu, 1420)
    }
}
