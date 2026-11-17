// 라우팅 테이블을 그림으로 볼 때의 뼈대 (LOCAL 화면 Routes 카드 · 서버 Network 탭의 경로 그림): 장치마다 한 갈래, 그 갈래로 나가는 목적지들.
// "이 주소는 어디로 가나" 판정(가장 긴 대역이 이긴다)도 여기 — 화면은 그리기만 한다.
// 이 Mac 은 RouteTable(netstat), 리눅스·OpenWrt 서버는 OpenWrtRouting(ip route · ip rule)에서 만든다.

import Foundation

public struct RouteGraph: Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        /// 인터넷 쪽 트래픽이 실제로 타는 길 (쓰이는 default 또는 0/1 짝)
        case internet
        /// 지금은 안 쓰이는 default (장치에 묶였거나 밀린 것)
        case standby
        /// 대역 · 호스트 경로
        case network
    }

    public struct Destination: Sendable, Equatable, Identifiable {
        /// RouteEntry.id — 표의 그 줄
        public let id: String
        /// "default" · "10.1.0.0/24"
        public let text: String
        public let role: Role
    }

    /// 장치 하나의 갈래
    public struct Lane: Sendable, Equatable, Identifiable {
        public var id: String { device }
        public let device: String
        /// 장치 옆 설명: IP (OpenWrt 는 인터페이스 이름과 함께 "wan 203.0.113.7")
        public let ip: String?
        /// VPN 터널이면 암호화한 패킷이 나가는 물리 장치 (없으면 빔)
        public let egress: [String]
        public let destinations: [Destination]
        /// 인터넷 쪽 트래픽이 이 갈래로 나가는가
        public var carriesInternet: Bool { destinations.contains { $0.role == .internet } }
    }

    /// 표에 처음 나오는 장치 순서 (쓰이는 default 의 장치가 맨 위)
    public let lanes: [Lane]

    public init(_ table: RouteTable) {
        var order: [String] = []
        var byDevice: [String: [Destination]] = [:]
        for entry in table.entries {
            let role: Role = table.carriesTraffic(entry) ? .internet
                : (entry.kind == .primary || entry.kind == .scoped || entry.kind == .splitDefault ? .standby : .network)
            for device in entry.interfaces {
                if byDevice[device] == nil { order.append(device) }
                byDevice[device, default: []].append(Destination(id: entry.id, text: entry.destination, role: role))
            }
        }
        lanes = order.map { device in
            Lane(device: device, ip: table.interfaces[device]?.ip, egress: table.tunnelEgress[device] ?? [], destinations: byDevice[device] ?? [])
        }
    }

    /// 그 IPv4 주소로 나가는 연결이 타는 줄: 가장 긴 대역이 이긴다. 장치에 묶인 default 는 보통 연결이 쓰지 않으니 후보에서 뺀다.
    /// IPv4 꼴이 아니거나 맞는 줄이 없으면 nil.
    public static func match(_ address: String, in table: RouteTable) -> RouteEntry? {
        guard let ip = NetworkServiceDraft.ipv4(address.trimmingCharacters(in: .whitespaces)) else { return nil }
        var best: (entry: RouteEntry, length: Int)?
        for entry in table.entries where entry.kind != .scoped {
            guard let (network, length) = prefix(of: entry.destination) else { continue }
            let mask: UInt32 = length == 0 ? 0 : ~UInt32(0) << UInt32(32 - length)
            if ip & mask == network & mask, best == nil || length > best!.length { best = (entry, length) }
        }
        return best?.entry
    }

    /// 목적지 표기 → (대역 주소, 접두사 길이). "default" 는 /0, 접두사 없는 주소는 호스트(/32)
    private static func prefix(of destination: String) -> (UInt32, Int)? {
        if destination == "default" { return (0, 0) }
        let parts = destination.split(separator: "/", omittingEmptySubsequences: false)
        guard let network = NetworkServiceDraft.ipv4(String(parts[0])) else { return nil }
        if parts.count == 1 { return (network, 32) }
        guard parts.count == 2, let length = Int(parts[1]), (0...32).contains(length) else { return nil }
        return (network, length)
    }

    // MARK: 리눅스 · OpenWrt 서버 (ip route · ip rule)

    /// 입력한 주소가 타는 길 (화면이 강조할 것)
    public struct Hit: Sendable, Equatable {
        /// 나가는 장치 (blackhole 등 보내지 않는 경로면 빔)
        public let devices: [String]
        /// 그림의 목적지 딱지 id (그림에서 뺀 장치의 경로여도 값은 있다)
        public let destinationID: String
        /// "→ eth1 · 10.1.0.0/24"
        public let text: String
    }

    /// 서버의 경로 그림. 그리는 것: main 테이블의 보통 경로 + 조건 없는 트래픽이 실제로 타는 줄(다른 테이블에 있어도).
    /// 조건 달린 정책 테이블의 경로는 일부 트래픽만의 일이라 뺀다 (탭의 Other routes · Policy rules 에 따로 나온다).
    /// - details: 장치 → 옆 설명 (IP 등)
    /// - excluding: 그리지 않을 장치 (컨테이너 배선 veth · 브리지 — docker 서버는 수십 개라 그림이 쓸모없어진다)
    public init(routing: OpenWrtRouting, details: [String: String] = [:], excluding: Set<String> = []) {
        let inUse = Set(routing.defaultRoutes.map(\.id))
        var order: [String] = []
        var byDevice: [String: [Destination]] = [:]
        for route in routing.routes where route.kind == nil && (route.table == "main" || inUse.contains(route.id)) {
            guard let device = route.device, !excluding.contains(device) else { continue }
            let isDefault = route.destination == "default" || route.destination == "0.0.0.0/1" || route.destination == "128.0.0.0/1"
            let role: Role = inUse.contains(route.id) ? .internet : (isDefault ? .standby : .network)
            if byDevice[device] == nil { order.append(device) }
            // 같은 목적지가 metric 만 달리 두 번 나오면 한 번만 (먼저 나온 것)
            if byDevice[device]?.contains(where: { $0.text == route.destination && $0.role == role }) == true { continue }
            byDevice[device, default: []].append(Destination(id: route.id, text: route.destination, role: role))
        }
        // 인터넷이 타는 갈래를 맨 위로 (ip route 는 테이블·대역 순이라 섞여 나온다)
        let lanes = order.map { Lane(device: $0, ip: details[$0], egress: [], destinations: byDevice[$0] ?? []) }
        self.lanes = lanes.filter(\.carriesInternet) + lanes.filter { !$0.carriesInternet }
    }

    /// 주소 하나로 길을 판정할 수 있는 서버인가: 정책 규칙이 기본 셋(local·main·default)뿐일 때만.
    /// 규칙이 더 있으면(VPN 정책 라우팅 등) 출발지·표식에 따라 다른 테이블을 타므로 main 만 보고 답하면 틀린다 — 그때는 그림만.
    public static func supportsLookup(_ routing: OpenWrtRouting) -> Bool { routing.policyRules.isEmpty }

    /// 그 IPv4 주소가 타는 main 테이블 경로: 가장 긴 대역, 같으면 metric 이 작은 것. 판정할 수 없는 서버(supportsLookup)·IPv4 아님·맞는 줄 없음이면 nil.
    /// blackhole·unreachable 도 "거기서 버린다"는 답이라 그대로 돌려준다.
    public static func hit(_ address: String, in routing: OpenWrtRouting) -> Hit? {
        guard supportsLookup(routing), let ip = NetworkServiceDraft.ipv4(address.trimmingCharacters(in: .whitespaces)) else { return nil }
        var best: (route: OpenWrtRoute, length: Int)?
        for route in routing.routes where route.table == "main" && route.kind != "throw" {
            guard let (network, length) = prefix(of: route.destination) else { continue }
            let mask: UInt32 = length == 0 ? 0 : ~UInt32(0) << UInt32(32 - length)
            guard ip & mask == network & mask else { continue }
            if let current = best, length < current.length || (length == current.length && (route.metric ?? 0) >= (current.route.metric ?? 0)) { continue }
            best = (route, length)
        }
        guard let route = best?.route else { return nil }
        let out = route.device ?? route.kind ?? "–"
        return Hit(devices: route.kind == nil ? [route.device].compactMap { $0 } : [], destinationID: route.id,
                   text: "→ \(route.kind.map { "\($0) " } ?? "")\(route.kind == nil ? out : "") · \(route.destination)".replacingOccurrences(of: "  ", with: " "))
    }

    /// 이 Mac 의 표에서 (match 와 같은 판정, 화면이 쓰는 꼴로)
    public static func hit(_ address: String, in table: RouteTable) -> Hit? {
        guard let entry = match(address, in: table) else { return nil }
        return Hit(devices: entry.interfaces, destinationID: entry.id, text: "→ \(entry.interfaces.joined(separator: ", ")) · \(entry.destination)")
    }
}
