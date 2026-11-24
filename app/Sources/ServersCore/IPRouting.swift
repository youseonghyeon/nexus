// 경로·정책 규칙 (`ip rule show` · `ip -4 route show table all`)의 구조화. OpenWrt 와 리눅스 Network 탭이 같이 쓴다 (이름의 OpenWrt 는 처음 쓴 곳).

import Foundation

public struct OpenWrtRoute: Sendable, Equatable, Identifiable {
    public var id: String { "\(table) \(kind ?? "") \(destination) \(gateway ?? "-") \(device ?? "-") \(metric ?? 0)" }
    /// "default" · "192.168.8.0/24" — ip route 표기 그대로
    public let destination: String
    /// nil 이면 On-link (라우터 없이 그 장치로 바로)
    public let gateway: String?
    public let device: String?
    /// 장치를 쓰는 인터페이스 (wan · lan …). 모르는 장치면 nil
    public let interface: String?
    /// "main" 또는 ip 가 찍은 테이블 이름·번호
    public let table: String
    /// 보내지 않는 경로: blackhole · unreachable · prohibit · throw. 보통 경로는 nil
    public let kind: String?
    public let metric: Int?
}

public struct OpenWrtRouteRule: Sendable, Equatable, Identifiable {
    public var id: String { "\(priority) \(condition) \(table ?? "") \(action ?? "")" }
    public let priority: Int
    /// "from all" 을 뺀 조건 ("iif lo" · "fwmark 0x8000/0xf000" · "not fwmark 0xca6c" · "suppress_prefixlength 0" 같은 수식 포함). 빈 문자열 = 모든 트래픽
    public let condition: String
    /// 찾아볼 테이블. nil 이면 action
    public let table: String?
    /// 테이블 대신 바로 하는 동작 (blackhole · unreachable · prohibit · nop · goto N)
    public let action: String?

    /// 리눅스 기본 규칙 (local · main · default). 있는 게 당연해 화면에 내지 않는다
    public var isStandard: Bool {
        guard condition.isEmpty, let table else { return false }
        return ["local", "main", "default"].contains(table)
    }
}

public struct OpenWrtRouting: Sendable, Equatable {
    public let rules: [OpenWrtRouteRule]
    /// main 먼저, 그 밖 테이블은 ip 가 찍은 순서
    public let routes: [OpenWrtRoute]
    /// 조건 없는 트래픽이 실제로 타는 줄. 비어 있으면 기본 경로가 없다 (blackhole 도 "버린다" 는 판정이라 그대로 담는다)
    public let defaultRoutes: [OpenWrtRoute]

    public init(rules: [OpenWrtRouteRule], routes: [OpenWrtRoute]) {
        self.rules = rules
        self.routes = routes.filter { $0.table == "main" } + routes.filter { $0.table != "main" }
        self.defaultRoutes = Self.resolveDefault(rules: rules, routes: routes)
    }

    /// 화면에 낼 규칙: 기본 규칙을 뺀 것
    public var policyRules: [OpenWrtRouteRule] { rules.filter { !$0.isStandard } }

    public var hasOtherTables: Bool { routes.contains { $0.table != "main" } }

    public func routeCount(inTable table: String) -> Int { routes.filter { $0.table == table }.count }

    /// 찾아볼 테이블에 IPv4 경로가 없어 지금은 다음 규칙으로 넘어가는 규칙. local 테이블은 파서가 경로를 담지 않아(local·broadcast 줄) 판단하지 않는다
    public func isEmptyLookup(_ rule: OpenWrtRouteRule) -> Bool {
        guard let table = rule.table, table != "local" else { return false }
        return routeCount(inTable: table) == 0
    }

    /// 규칙을 우선순위대로 따라가 조건 없는 트래픽의 경로를 찾는다. 조건 달린 규칙은 일부 트래픽만의 일이라 건너뛴다 — 화면에 따로 나온다.
    /// 규칙을 못 읽었으면 main 만 본다.
    private static func resolveDefault(rules: [OpenWrtRouteRule], routes: [OpenWrtRoute]) -> [OpenWrtRoute] {
        let walk = rules.isEmpty ? [OpenWrtRouteRule(priority: 0, condition: "", table: "main", action: nil)] : rules
        for rule in walk where rule.condition.isEmpty {
            guard let table = rule.table else { return [] }   // 모든 트래픽을 blackhole 등으로
            let inTable = routes.filter { $0.table == table && $0.kind != "throw" }
            // 0.0.0.0/1 · 128.0.0.0/1 짝은 둘이 합쳐 전체를 덮고 접두사가 default 보다 길어 default 를 이긴다 (OpenVPN def1 — RouteTable 과 같은 판정)
            let split = inTable.filter { $0.destination == "0.0.0.0/1" || $0.destination == "128.0.0.0/1" }
            if Set(split.map(\.destination)).count == 2 { return split }
            let defaults = inTable.filter { $0.destination == "default" }
            // metric 이 같은 줄이 여럿이면 멀티패스 — 전부 쓰인다
            if let best = defaults.map({ $0.metric ?? 0 }).min() { return defaults.filter { ($0.metric ?? 0) == best } }
        }
        return []
    }

    /// `ip rule show` · `ip -4 route show table all` 출력. 형식은 Fixtures/openwrt-routes-*.txt
    public static func parse(rules: [String], routes: [String], interfaceNames: [String: String]) -> OpenWrtRouting? {
        let parsedRoutes = parseRoutes(routes, interfaceNames: interfaceNames)
        guard !parsedRoutes.isEmpty else { return nil }
        return OpenWrtRouting(rules: rules.compactMap(parseRule), routes: parsedRoutes)
    }

    /// "1:  from all iif lo lookup 16800" · "600:  from all to 192.0.2.9 unreachable" · "400:  from all lookup main suppress_prefixlength 0"
    private static func parseRule(_ line: String) -> OpenWrtRouteRule? {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = tokens.first, first.hasSuffix(":"), let priority = Int(first.dropLast()) else { return nil }
        let rest = Array(tokens.dropFirst())
        var table: String?
        var action: String?
        var condition: [String]
        if let i = rest.firstIndex(of: "lookup"), i + 1 < rest.count {
            table = rest[i + 1]
            condition = Array(rest[..<i]) + rest[(i + 2)...]
        } else if let i = rest.firstIndex(where: { ["blackhole", "unreachable", "prohibit", "nop", "goto"].contains($0) }) {
            action = rest[i...].joined(separator: " ")
            condition = Array(rest[..<i])
        } else {
            return nil
        }
        if let i = condition.firstIndex(of: "from"), i + 1 < condition.count, condition[i + 1] == "all" { condition.removeSubrange(i...(i + 1)) }
        return OpenWrtRouteRule(priority: priority, condition: condition.joined(separator: " "), table: table, action: action)
    }

    /// "default via A dev eth1 proto static src B metric 1" · "blackhole default table 200" · 멀티패스는 머리 줄("default table 300") 뒤에 "nexthop via A dev eth1 weight 1" 들 — 다음 홉마다 한 줄로 푼다.
    private static func parseRoutes(_ lines: [String], interfaceNames: [String: String]) -> [OpenWrtRoute] {
        var result: [OpenWrtRoute] = []
        /// 다음 홉을 기다리는 멀티패스 머리 줄
        var header: OpenWrtRoute?
        func value(_ key: String, in tokens: [String]) -> String? {
            guard let i = tokens.firstIndex(of: key), i + 1 < tokens.count else { return nil }
            return tokens[i + 1]
        }
        func route(_ base: OpenWrtRoute, _ tokens: [String]) -> OpenWrtRoute {
            let device = value("dev", in: tokens)
            return OpenWrtRoute(destination: base.destination, gateway: value("via", in: tokens), device: device,
                                interface: device.flatMap { interfaceNames[$0] }, table: base.table, kind: base.kind, metric: base.metric)
        }
        for line in lines {
            var tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let first = tokens.first else { continue }
            if first == "nexthop" {
                if let header { result.append(route(header, tokens)) }
                continue
            }
            let kind = ["unreachable", "blackhole", "prohibit", "throw"].contains(first) ? first : nil
            if kind != nil { tokens.removeFirst() }
            guard let destination = tokens.first, destination == "default" || destination.first?.isNumber == true else { continue }
            let parsed = OpenWrtRoute(destination: destination, gateway: value("via", in: tokens), device: value("dev", in: tokens), interface: nil,
                                      table: value("table", in: tokens) ?? "main", kind: kind, metric: value("metric", in: tokens).flatMap { Int($0) })
            if kind == nil, parsed.gateway == nil, parsed.device == nil {
                header = parsed   // 장치 없는 보통 경로 = 멀티패스 머리
            } else {
                header = nil
                result.append(route(parsed, tokens))
            }
        }
        return result
    }
}

/// "a.b.c.d/n" 의 대역 비교 (IPv4 만)
enum IPv4Prefix {
    static func parse(_ text: String) -> (address: UInt32, prefix: Int)? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]), (0...32).contains(prefix) else { return nil }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt32($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 < 256 }) else { return nil }
        return (octets.reduce(0) { $0 << 8 | $1 }, prefix)
    }

    /// 인터페이스 주소("192.168.8.103/24")가 경로 대역("192.168.8.0/24") 안에 같은 접두사로 있는가
    static func sameNetwork(_ address: String, _ destination: String) -> Bool {
        guard let a = parse(address), let d = parse(destination), a.prefix == d.prefix else { return false }
        let mask = IPv4.mask(prefix: a.prefix)
        return a.address & mask == d.address & mask
    }
}
