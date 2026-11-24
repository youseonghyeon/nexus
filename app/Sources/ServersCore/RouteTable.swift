// 이 Mac 의 IPv4 라우팅 테이블 (LOCAL 화면 Routes 카드). `netstat -rn -f inet` 을 읽어 사람이 볼 줄만 남긴다.
// 날것은 수백 줄이고 대부분 복제된 호스트 캐시(W)·ARP 라 뺀다. 남기는 것: default · 대역 · 라우터를 거치는 호스트 경로.
// 루트 권한 없이 읽기만 한다.

import Foundation

public struct RouteEntry: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// 실제로 쓰이는 default (장치에 묶이지 않은 첫 default)
        case primary
        /// 그 장치로 묶인(I) default — 그 장치를 지정한 연결만 쓴다
        case scoped
        /// 0.0.0.0/1 · 128.0.0.0/1 짝 — 둘이 합쳐 전체를 덮고 접두사가 default 보다 길어 default 를 이긴다 (OpenVPN def1 등)
        case splitDefault
        case route
    }

    public var id: String { "\(destination) \(gateway ?? "-") \(interfaces.joined(separator: ","))" }
    /// "default" · "192.168.8.0/24" · "10.1.0.0/24" · "203.0.113.5"(호스트) — Linux ip route 표기
    public let destination: String
    /// 라우터 IP. nil 이면 On-link(link#N — 라우터 없이 그 장치로 바로)
    public let gateway: String?
    /// 같은 대역·게이트웨이가 여러 장치에 붙어 있으면 한 줄에 모은다 (netstat 순서)
    public var interfaces: [String]
    public var kind: Kind
    /// default 끼리의 순위 (1 = 쓰이는 default, 나머지는 `scutil --nwi` 서비스 순서). 순서를 못 읽었거나 거기 없는 장치면 nil
    public var rank: Int?

    public init(destination: String, gateway: String?, interfaces: [String], kind: Kind, rank: Int? = nil) {
        self.destination = destination
        self.gateway = gateway
        self.interfaces = interfaces
        self.kind = kind
        self.rank = rank
    }
}

public struct InterfaceDetail: Sendable, Equatable {
    public var ip: String?
    public var mtu: Int?

    public init(ip: String? = nil, mtu: Int? = nil) {
        self.ip = ip
        self.mtu = mtu
    }
}

public struct RouteTable: Sendable, Equatable {
    public var entries: [RouteEntry]
    /// 장치별 IPv4 · MTU (ifconfig)
    public var interfaces: [String: InterfaceDetail]
    /// 연결된 VPN 터널(utun6) → 암호화한 패킷이 나가는 물리 장치 (VPNEgress). 테이블엔 안 보이는 다음 길
    public var tunnelEgress: [String: [String]]

    public init(entries: [RouteEntry], interfaces: [String: InterfaceDetail], tunnelEgress: [String: [String]] = [:]) {
        self.entries = entries
        self.interfaces = interfaces
        self.tunnelEgress = tunnelEgress
    }

    /// 인터넷 쪽 트래픽이 실제로 타는 줄 ("기본 경로" 딱지). 0/1 짝이 있으면 그 짝, 없으면 쓰이는 default
    public func carriesTraffic(_ entry: RouteEntry) -> Bool {
        if entries.contains(where: { $0.kind == .splitDefault }) { return entry.kind == .splitDefault }
        return entry.kind == .primary
    }

    /// 인터페이스 옆 설명: IP, MTU 는 1500 이 아닐 때만 ("10.1.0.2 · MTU 1420"). 여러 장치면 장치마다 쉼표로.
    /// VPN 터널이면 나가는 물리 장치를 잇는다 ("10.1.0.2 · MTU 1420 → en11").
    public func detail(for entry: RouteEntry) -> String {
        entry.interfaces.compactMap { device -> String? in
            let info = interfaces[device] ?? InterfaceDetail()
            var parts = [info.ip, info.mtu.flatMap { $0 == 1500 ? nil : "MTU \($0)" }].compactMap { $0 }.joined(separator: " · ")
            if let out = tunnelEgress[device], !out.isEmpty {
                parts += (parts.isEmpty ? "" : " ") + "→ " + out.joined(separator: ", ")
            }
            return parts.isEmpty ? nil : parts
        }.joined(separator: ", ")
    }

    /// `netstat -rn -f inet` → 볼 줄만. 순서: 0/1 짝 → 쓰이는 default → 묶인 default(order 순, 거기 없는 장치는 뒤) → 나머지(netstat 순서).
    ///  order 는 `scutil --nwi` 의 IPv4 장치 순서. 비어 있으면(못 읽음) 번호 없이 netstat 순서.
    ///  번호는 화면에 남는 default 끼리 1·2·3 — 쓰이는 default 가 1 (순서 목록과 잠깐 어긋나도 딱지와 번호가 엇갈리지 않게).
    ///  뺀다: 복제(W, 호스트 캐시·ARP) · 멀티캐스트(m) · lo0 · 브로드캐스트 255.255.255.255 · 169.254 ·
    ///        라우터 없는 호스트 경로(자기 주소·p2p 상대) · 라우터 없는 묶인 default(브리지·VM 이 만드는 것)
    public static func parse(_ text: String, order: [String] = []) -> [RouteEntry] {
        var defaults: [RouteEntry] = []
        var routes: [RouteEntry] = []
        var sawHeader = false
        for raw in text.split(separator: "\n") {
            let cols = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if cols.first == "Destination" { sawHeader = true; continue }
            guard sawHeader, cols.count >= 4 else { continue }
            let (dest, gw, flags, netif) = (cols[0], cols[1], cols[2], cols[3])
            if flags.contains("W") || flags.contains("m") || netif.hasPrefix("lo") { continue }
            let gateway: String? = gw.hasPrefix("link#") ? nil : gw
            let viaRouter = flags.contains("G")
            let scoped = flags.contains("I")

            if dest == "default" {
                if scoped && !viaRouter { continue }
                let primary = !scoped && !defaults.contains { $0.kind == .primary }
                defaults.append(RouteEntry(destination: dest, gateway: gateway, interfaces: [netif], kind: primary ? .primary : .scoped))
                continue
            }
            let destination = normalize(dest)
            if destination == "255.255.255.255" || destination.hasPrefix("169.254.") { continue }
            let host = flags.contains("H") || dest.hasSuffix("/32")
            if host && !viaRouter { continue }
            if let i = routes.firstIndex(where: { $0.destination == destination && $0.gateway == gateway }) {
                if !routes[i].interfaces.contains(netif) { routes[i].interfaces.append(netif) }
            } else {
                routes.append(RouteEntry(destination: destination, gateway: gateway, interfaces: [netif], kind: .route))
            }
        }
        // 0/1 · 128.0/1 은 둘 다 있을 때만 default 를 이긴다 (한쪽만이면 그냥 대역)
        let halves = ["0.0.0.0/1", "128.0.0.0/1"]
        var split: [RouteEntry] = []
        if halves.allSatisfy({ half in routes.contains { $0.destination == half } }) {
            split = halves.flatMap { half in routes.filter { $0.destination == half } }
            routes.removeAll { halves.contains($0.destination) }
            for i in split.indices { split[i].kind = .splitDefault }
        }
        return split + ranked(defaults, order: order) + routes
    }

    /// 쓰이는 default 맨 앞, 묶인 default 는 order 순(없는 장치는 뒤, netstat 순서 유지). 번호는 order 를 읽었을 때만
    static func ranked(_ defaults: [RouteEntry], order: [String]) -> [RouteEntry] {
        func key(_ entry: RouteEntry) -> Int {
            if entry.kind == .primary { return -1 }
            return order.firstIndex(of: entry.interfaces[0]) ?? Int.max
        }
        var sorted = defaults.enumerated().sorted { (key($0.element), $0.offset) < (key($1.element), $1.offset) }.map(\.element)
        guard !order.isEmpty else { return sorted }
        var next = 1
        for i in sorted.indices where sorted[i].kind == .primary || order.contains(sorted[i].interfaces[0]) {
            sorted[i].rank = next
            next += 1
        }
        return sorted
    }

    /// `scutil --nwi` → IPv4 장치 순서 (macOS 가 고른 서비스 우선순위). "IPv4 network interface information" 블록의 "<장치> : flags" 줄만
    public static func parseInterfaceOrder(_ text: String) -> [String] {
        var out: [String] = []
        var inIPv4 = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("IPv4 network interface information") { inIPv4 = true; continue }
            if line.hasPrefix("IPv6 network interface information") || line.hasPrefix("Network interfaces:") { inIPv4 = false; continue }
            guard inIPv4, raw.hasPrefix(" ") else { continue }
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[1].hasPrefix("flags"), !parts[0].isEmpty, parts[0] != "REACH", !parts[0].contains(" ") else { continue }
            if !out.contains(parts[0]) { out.append(parts[0]) }
        }
        return out
    }

    /// Linux `ip route` 처럼 네 옥텟·"/길이" 로 쓴다 ("10.1/24" → "10.1.0.0/24", "192.168.8" → "192.168.8.0/24", 호스트 "x/32" → "x").
    /// netstat 은 끝의 0 옥텟을 줄이고, 마스크가 클래스 기본값이면 "/길이" 도 뺀다 — 그땐 첫 옥텟의 클래스(A /8 · B /16 · C /24)로 채운다.
    static func normalize(_ destination: String) -> String {
        let halves = destination.split(separator: "/", maxSplits: 1).map(String.init)
        var octets = halves[0].split(separator: ".").map(String.init)
        guard (1...4).contains(octets.count), let first = Int(octets[0]) else { return destination }
        var length = halves.count == 2 ? halves[1] : nil
        if length == nil, octets.count < 4 { length = first < 128 ? "8" : first < 192 ? "16" : "24" }
        while octets.count < 4 { octets.append("0") }
        let address = octets.joined(separator: ".")
        guard let length, length != "32" else { return address }
        return "\(address)/\(length)"
    }

    /// ifconfig 출력 → 장치별 첫 IPv4 · MTU
    public static func parseInterfaceDetails(_ text: String) -> [String: InterfaceDetail] {
        var out: [String: InterfaceDetail] = [:]
        for block in Ifconfig.blocks(text) {
            guard let header = block.header else { continue }   // 장치 줄보다 먼저 나온 줄은 버린다
            var detail = InterfaceDetail()
            if let range = header.range(of: " mtu ") {
                detail.mtu = Int(header[range.upperBound...].prefix { $0.isNumber })
            }
            if !block.device.isEmpty { detail.ip = block.inetAddresses.first }
            out[block.device] = detail   // 같은 이름이 다시 나오면 뒤의 것
        }
        return out
    }

    /// netstat 이 실패하면 nil (화면은 "읽지 못했습니다")
    public static func fetch(runner: any CommandRunner) async -> RouteTable? {
        let result = await runner.run("netstat", ["-rn", "-f", "inet"], timeout: 5)
        guard result.exitCode == 0, result.stdout.contains("Destination") else { return nil }
        let interfaces = parseInterfaceDetails(await runner.run("ifconfig", [], timeout: 5).stdout)
        let nwi = await runner.run("scutil", ["--nwi"], timeout: 5)
        let order = nwi.exitCode == 0 ? parseInterfaceOrder(nwi.stdout) : []
        return RouteTable(entries: parse(result.stdout, order: order), interfaces: interfaces)
    }
}
