import XCTest
@testable import ServersCore

final class RouteGraphTests: XCTestCase {
    /// VPN 이 기본 경로를 가져간 Mac: utun6(전체 트래픽) → en0, Wi-Fi 의 default 는 묶인 채 대기, 브리지 둘
    private let table = RouteTable(
        entries: [
            RouteEntry(destination: "default", gateway: nil, interfaces: ["utun6"], kind: .primary, rank: 1),
            RouteEntry(destination: "default", gateway: "192.168.100.254", interfaces: ["en0"], kind: .scoped, rank: 2),
            RouteEntry(destination: "10.1.0.0/24", gateway: "10.1.0.5", interfaces: ["utun6"], kind: .route),
            RouteEntry(destination: "192.168.100.0/24", gateway: nil, interfaces: ["en0"], kind: .route),
            RouteEntry(destination: "192.168.107.0/24", gateway: nil, interfaces: ["bridge101"], kind: .route),
            RouteEntry(destination: "203.0.113.5", gateway: "192.168.100.254", interfaces: ["en0"], kind: .route),
        ],
        interfaces: ["utun6": InterfaceDetail(ip: "10.1.0.5", mtu: 1420), "en0": InterfaceDetail(ip: "192.168.100.3")],
        tunnelEgress: ["utun6": ["en0"]])

    func testLanesFollowTableOrderAndGroupDestinations() {
        let graph = RouteGraph(table)
        XCTAssertEqual(graph.lanes.map(\.device), ["utun6", "en0", "bridge101"])
        XCTAssertEqual(graph.lanes[0].destinations.map(\.text), ["default", "10.1.0.0/24"])
        XCTAssertEqual(graph.lanes[0].destinations.map(\.role), [.internet, .network])
        XCTAssertEqual(graph.lanes[0].egress, ["en0"])
        XCTAssertEqual(graph.lanes[0].ip, "10.1.0.5")
        XCTAssertTrue(graph.lanes[0].carriesInternet)
        // 묶인 default 는 대기 — 인터넷 갈래로 치지 않는다
        XCTAssertEqual(graph.lanes[1].destinations.map(\.role), [.standby, .network, .network])
        XCTAssertFalse(graph.lanes[1].carriesInternet)
        // ifconfig 에 없는 장치도 갈래는 생긴다 (IP 만 빔)
        XCTAssertNil(graph.lanes[2].ip)
        XCTAssertEqual(graph.lanes[2].egress, [])
    }

    func testEmptyTableHasNoLanes() {
        XCTAssertEqual(RouteGraph(RouteTable(entries: [], interfaces: [:])).lanes, [])
        XCTAssertNil(RouteGraph.match("1.1.1.1", in: RouteTable(entries: [], interfaces: [:])))
    }

    func testEntryOnSeveralDevicesAppearsInEachLane() {
        let shared = RouteTable(entries: [RouteEntry(destination: "10.0.0.0/8", gateway: nil, interfaces: ["en0", "en1"], kind: .route)], interfaces: [:])
        XCTAssertEqual(RouteGraph(shared).lanes.map(\.device), ["en0", "en1"])
        XCTAssertEqual(RouteGraph(shared).lanes[1].destinations.map(\.text), ["10.0.0.0/8"])
    }

    /// 0/1 짝이 있으면 그 짝이 인터넷 길이고, 원래 default 는 대기로 밀린다
    func testSplitDefaultTakesInternetRole() {
        let split = RouteTable(entries: [
            RouteEntry(destination: "0.0.0.0/1", gateway: "10.8.0.1", interfaces: ["utun3"], kind: .splitDefault),
            RouteEntry(destination: "128.0.0.0/1", gateway: "10.8.0.1", interfaces: ["utun3"], kind: .splitDefault),
            RouteEntry(destination: "default", gateway: "192.168.0.1", interfaces: ["en0"], kind: .primary, rank: 1),
        ], interfaces: [:])
        let graph = RouteGraph(split)
        XCTAssertEqual(graph.lanes[0].destinations.map(\.role), [.internet, .internet])
        XCTAssertEqual(graph.lanes[1].destinations.map(\.role), [.standby])
        XCTAssertEqual(RouteGraph.match("8.8.8.8", in: split)?.interfaces, ["utun3"])
        XCTAssertEqual(RouteGraph.match("200.1.1.1", in: split)?.destination, "128.0.0.0/1")
    }

    func testMatchPicksLongestPrefix() {
        let cases: [(String, String?, String?)] = [
            ("8.8.8.8", "default", "utun6"),                 // 맞는 대역이 없으면 쓰이는 default (묶인 default 는 후보 아님)
            ("10.1.0.77", "10.1.0.0/24", "utun6"),
            ("192.168.100.9", "192.168.100.0/24", "en0"),
            ("192.168.107.1", "192.168.107.0/24", "bridge101"),
            ("203.0.113.5", "203.0.113.5", "en0"),           // 호스트 경로(/32)가 default 를 이긴다
            ("203.0.113.6", "default", "utun6"),
            (" 10.1.0.1 ", "10.1.0.0/24", "utun6"),          // 앞뒤 공백은 뗀다
            ("", nil, nil), ("example.com", nil, nil), ("10.1.0", nil, nil), ("300.1.1.1", nil, nil),
        ]
        for (address, destination, device) in cases {
            let entry = RouteGraph.match(address, in: table)
            XCTAssertEqual(entry?.destination, destination, address)
            XCTAssertEqual(entry?.interfaces.first, device, address)
        }
    }

    /// default 가 묶인 것뿐이면(쓰이는 default 없음) 대역 밖 주소는 갈 길이 없다
    func testNoUsableDefaultMeansNoMatch() {
        let onlyScoped = RouteTable(entries: [
            RouteEntry(destination: "default", gateway: "192.168.0.1", interfaces: ["en0"], kind: .scoped),
            RouteEntry(destination: "192.168.0.0/24", gateway: nil, interfaces: ["en0"], kind: .route),
        ], interfaces: [:])
        XCTAssertNil(RouteGraph.match("8.8.8.8", in: onlyScoped))
        XCTAssertEqual(RouteGraph.match("192.168.0.4", in: onlyScoped)?.destination, "192.168.0.0/24")
    }

    // MARK: 리눅스 · OpenWrt 서버

    private func route(_ destination: String, via: String? = nil, dev: String?, table: String = "main", kind: String? = nil, metric: Int? = nil) -> OpenWrtRoute {
        OpenWrtRoute(destination: destination, gateway: via, device: dev, interface: nil, table: table, kind: kind, metric: metric)
    }
    private let standardRules = [
        OpenWrtRouteRule(priority: 0, condition: "", table: "local", action: nil),
        OpenWrtRouteRule(priority: 32766, condition: "", table: "main", action: nil),
        OpenWrtRouteRule(priority: 32767, condition: "", table: "default", action: nil),
    ]

    /// docker 서버: 실제 NIC 하나 + 컨테이너 브리지들. 브리지는 그림에서 빼도 판정은 그대로 한다
    func testServerGraphExcludesContainerDevices() {
        let routing = OpenWrtRouting(rules: standardRules, routes: [
            route("172.17.0.0/16", dev: "docker0"),
            route("default", via: "192.168.8.1", dev: "enp1s0", metric: 100),
            route("192.168.8.0/24", dev: "enp1s0", metric: 100),
            route("192.168.8.1", dev: "enp1s0", metric: 100),
            route("10.42.0.0/24", dev: "cni0"),
        ])
        let graph = RouteGraph(routing: routing, details: ["enp1s0": "192.168.8.103"], excluding: ["docker0", "cni0"])
        XCTAssertEqual(graph.lanes.map(\.device), ["enp1s0"])
        XCTAssertEqual(graph.lanes[0].ip, "192.168.8.103")
        XCTAssertEqual(graph.lanes[0].destinations.map(\.text), ["default", "192.168.8.0/24", "192.168.8.1"])
        XCTAssertEqual(graph.lanes[0].destinations.map(\.role), [.internet, .network, .network])
        // 빼지 않으면 인터넷 갈래가 맨 위, 나머지는 ip 가 찍은 순서
        XCTAssertEqual(RouteGraph(routing: routing).lanes.map(\.device), ["enp1s0", "docker0", "cni0"])

        XCTAssertTrue(RouteGraph.supportsLookup(routing))
        XCTAssertEqual(RouteGraph.hit("8.8.8.8", in: routing)?.text, "→ enp1s0 · default")
        XCTAssertEqual(RouteGraph.hit("192.168.8.1", in: routing)?.text, "→ enp1s0 · 192.168.8.1")   // 호스트 경로가 대역을 이긴다
        XCTAssertEqual(RouteGraph.hit("192.168.8.50", in: routing)?.devices, ["enp1s0"])
        XCTAssertEqual(RouteGraph.hit("172.17.0.9", in: routing)?.devices, ["docker0"])               // 그림에서 뺀 장치여도 답은 한다
        XCTAssertNil(RouteGraph.hit("example.com", in: routing))
    }

    /// 같은 대역이 두 장치에 있으면 metric 이 작은 쪽, default 가 둘이면 쓰이는 쪽만 인터넷이고 나머지는 대기
    func testServerMetricTieAndStandbyDefault() {
        let routing = OpenWrtRouting(rules: standardRules, routes: [
            route("default", via: "10.0.0.1", dev: "wlan0", metric: 600),
            route("default", via: "192.168.8.1", dev: "eth0", metric: 100),
            route("192.168.8.0/24", dev: "wlan0", metric: 600),
            route("192.168.8.0/24", dev: "eth0", metric: 100),
        ])
        let graph = RouteGraph(routing: routing)
        XCTAssertEqual(graph.lanes.map(\.device), ["eth0", "wlan0"])
        XCTAssertEqual(graph.lanes[0].destinations.map(\.role), [.internet, .network])
        XCTAssertEqual(graph.lanes[1].destinations.map(\.role), [.standby, .network])
        XCTAssertEqual(RouteGraph.hit("192.168.8.9", in: routing)?.devices, ["eth0"])
        XCTAssertEqual(RouteGraph.hit("1.1.1.1", in: routing)?.devices, ["eth0"])
    }

    /// 정책 라우팅이 있는 공유기: 조건 없는 규칙이 가리키는 테이블의 default 가 인터넷 길이고, 주소 판정은 하지 않는다
    func testPolicyRoutedRouterDrawsButDoesNotAnswer() {
        let rules = [
            OpenWrtRouteRule(priority: 0, condition: "", table: "local", action: nil),
            OpenWrtRouteRule(priority: 1000, condition: "fwmark 0x8000/0xf000", table: "2000", action: nil),
            OpenWrtRouteRule(priority: 9000, condition: "", table: "51820", action: nil),
            OpenWrtRouteRule(priority: 32766, condition: "", table: "main", action: nil),
        ]
        let routing = OpenWrtRouting(rules: rules, routes: [
            route("default", via: "203.0.113.1", dev: "eth1"),
            route("192.168.8.0/24", dev: "br-lan"),
            route("default", dev: "wgclient", table: "51820"),
            route("10.9.0.0/24", dev: "eth2", table: "2000"),
            route("default", dev: nil, table: "main", kind: "blackhole", metric: 65535),
        ])
        let graph = RouteGraph(routing: routing, details: ["eth1": "wan 203.0.113.7"])
        XCTAssertEqual(graph.lanes.map(\.device), ["wgclient", "eth1", "br-lan"])           // 조건 달린 테이블 2000 의 eth2 는 안 그린다
        XCTAssertEqual(graph.lanes[0].destinations.map(\.role), [.internet])
        XCTAssertEqual(graph.lanes[1].destinations.map(\.role), [.standby])                 // main 의 default 는 밀려 대기
        XCTAssertEqual(graph.lanes[1].ip, "wan 203.0.113.7")
        XCTAssertFalse(RouteGraph.supportsLookup(routing))
        XCTAssertNil(RouteGraph.hit("8.8.8.8", in: routing))
    }

    func testServerBlackholeAndEmpty() {
        let routing = OpenWrtRouting(rules: standardRules, routes: [
            route("192.168.8.0/24", dev: "eth0"),
            route("10.0.0.0/8", dev: nil, kind: "blackhole"),
        ])
        XCTAssertEqual(RouteGraph.hit("10.2.3.4", in: routing)?.devices, [])
        XCTAssertEqual(RouteGraph.hit("10.2.3.4", in: routing)?.text, "→ blackhole · 10.0.0.0/8")
        XCTAssertNil(RouteGraph.hit("8.8.8.8", in: routing))                                // default 가 없으면 갈 길이 없다
        XCTAssertEqual(RouteGraph(routing: OpenWrtRouting(rules: [], routes: [])).lanes, [])
    }

    func testMacHitMatchesMatch() {
        XCTAssertEqual(RouteGraph.hit("10.1.0.77", in: table)?.text, "→ utun6 · 10.1.0.0/24")
        XCTAssertEqual(RouteGraph.hit("10.1.0.77", in: table)?.devices, ["utun6"])
        XCTAssertNil(RouteGraph.hit("nope", in: table))
    }
}
