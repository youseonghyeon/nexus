// OpenWrt 방화벽(Firewall 탭): `uci show firewall` 을 존 매트릭스·포트 포워딩·규칙·스크립트로 정리한다. 읽기만.
// 포트 포워딩은 firewall 의 redirect 와 GL.iNet 관리 화면이 쓰는 port_forward 의 redirect 를 합친다.
// 설정에 적힌 것만 보인다 — 켜짐은 설정값이고 실제 적용 여부가 아니다 (GL 포워딩은 동작해도 iptables nat 표에 DNAT 가 없어 표로는 판정하지 못한다, 2026-11-05 MT5000).
// include 스크립트가 직접 넣는 규칙(gl_block.sh 등)도 나오지 않아 스크립트 목록을 함께 낸다.
// 실제 출력: Tests/ServersCoreTests/Fixtures/openwrt-firewall.txt

import Foundation

public struct OpenWrtFirewall: Sendable, Equatable {
    public struct Zone: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let networks: [String]
        /// 존에 없으면 defaults 값을 물려받은 결과 (fw4 와 같다), 대문자
        public let input: String
        public let output: String
        public let forward: String
        public let masq: Bool
        public let enabled: Bool
    }

    public struct Forwarding: Sendable, Equatable, Identifiable {
        public let id: String
        /// "lan → wan"
        public let flow: String
        public let enabled: Bool
        public var src: String?
        public var dest: String?
    }

    /// 규칙 · 포트 포워딩 한 줄
    public struct Rule: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        /// "wan → this device" · "wgserver → lan" · "wan → any"
        public let flow: String
        /// 규칙: "udp 51820 · IPv4", 포트 포워딩: "tcp/udp 8080 → 192.168.8.2:80"
        public let match: String
        /// 대문자 (ACCEPT · REJECT · DNAT …). 설정에 없으면 빈 문자열
        public let target: String
        public let enabled: Bool
        /// 위에 안 낸 옵션 (icmp_type · limit 등) — 마우스를 올리면 보인다
        public let extras: String?
        /// 설정이 firewall 밖에서 왔으면 그 출처 ("GL")
        public var source: String?
        /// 매트릭스 칸을 정하는 원값 ("*" = 모든 존, nil = 안 적음)
        public var src: String?
        public var dest: String?
        public var destIP: String?
        /// 조건 없이 모든 IPv4 새 연결에 걸리는 규칙 — 칸의 판정을 정한다
        public var coversAllIPv4 = false
    }

    public struct Script: Sendable, Equatable, Identifiable {
        public let id: String
        public let path: String
        public let enabled: Bool
    }

    public var zones: [Zone] = []
    public var forwardings: [Forwarding] = []
    public var portForwards: [Rule] = []
    public var rules: [Rule] = []
    public var scripts: [Script] = []
    /// 결과를 받을 때 한 번 계산해 둔다 (그리기마다 다시 하지 않게)
    public var matrix = FirewallMatrix()

    /// 방화벽 스크립트 출력. @END 가 없거나(끊김) 존·규칙이 하나도 없으면 nil — 화면은 원문을 보여준다.
    public static func parse(_ lines: [String]) -> OpenWrtFirewall? {
        guard let s = OpenWrt.sections(lines) else { return nil }
        let sections = uciSectionsInOrder(s["UCI"] ?? [])
        let defaults = sections.first { $0.type == "defaults" }?.options ?? [:]
        var result = OpenWrtFirewall()
        for section in sections {
            switch section.type {
            case "zone": result.zones.append(zone(section, defaults: defaults))
            case "forwarding":
                result.forwardings.append(Forwarding(id: section.name, flow: "\(section.first("src") ?? "any") → \(section.first("dest") ?? "any")", enabled: section.isEnabled,
                                                  src: section.first("src"), dest: section.first("dest")))
            case "redirect": result.portForwards.append(portForward(section))
            case "rule": result.rules.append(rule(section))
            case "include": result.scripts.append(Script(id: section.name, path: section.first("path") ?? section.name, enabled: section.isEnabled))
            default: break
            }
        }
        for section in uciSectionsInOrder(s["PORTFORWARD"] ?? []) where section.type == "redirect" {
            result.portForwards.append(portForward(section, source: "GL"))
        }
        guard !(result.zones.isEmpty && result.rules.isEmpty && result.portForwards.isEmpty) else { return nil }
        result.matrix = FirewallMatrix(result, defaultForward: (defaults["forward"]?.first ?? "DROP").uppercased())
        return result
    }

    // MARK: uci

    private struct UCISection {
        let name: String
        let type: String
        var options: [String: [String]] = [:]

        func first(_ key: String) -> String? { options[key]?.first }
        /// enabled 는 없으면 켜짐
        var isEnabled: Bool { !["0", "no", "off", "false"].contains(first("enabled") ?? "1") }
        func joined(_ key: String) -> String? { options[key].map { $0.joined(separator: ",") } }
    }

    /// 나온 순서 그대로 — 방화벽은 위쪽 규칙이 먼저 적용된다 (OpenWrtClients.uciSections 는 이름순이라 @rule[10] 이 @rule[2] 앞에 온다)
    private static func uciSectionsInOrder(_ lines: [String]) -> [UCISection] {
        var result: [UCISection] = []
        var index: [String: Int] = [:]
        for line in lines {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let path = line[..<eq].split(separator: ".").map(String.init)
            let value = String(line[line.index(after: eq)...])
            if path.count == 2 {
                index[path[1]] = result.count
                result.append(UCISection(name: path[1], type: value))
            } else if path.count == 3, let i = index[path[1]] {
                result[i].options[path[2]] = OpenWrtClients.uciValues(value)
            }
        }
        return result
    }

    private static func zone(_ section: UCISection, defaults: [String: [String]]) -> Zone {
        func policy(_ key: String) -> String { (section.first(key) ?? defaults[key]?.first ?? "DROP").uppercased() }
        return Zone(id: section.name, name: section.first("name") ?? section.name, networks: section.options["network"] ?? [],
                    input: policy("input"), output: policy("output"), forward: policy("forward"),
                    masq: ["1", "yes", "on", "true"].contains(section.first("masq") ?? "0"), enabled: section.isEnabled)
    }

    /// proto 를 안 적으면 방화벽은 tcp·udp 로 본다
    private static func proto(_ section: UCISection) -> String {
        (section.options["proto"] ?? ["tcp", "udp"]).joined(separator: "/")
    }

    private static func family(_ section: UCISection) -> String? {
        switch section.first("family") {
        case "ipv4": return "IPv4"
        case "ipv6": return "IPv6"
        default: return nil
        }
    }

    private static func extras(_ section: UCISection, shown: Set<String>) -> String? {
        let rest = section.options.keys.filter { !shown.contains($0) }.sorted()
            .map { "\($0): \(section.options[$0]?.joined(separator: ", ") ?? "")" }
        return rest.isEmpty ? nil : rest.joined(separator: "\n")
    }

    private static func rule(_ section: UCISection) -> Rule {
        // src·dest 가 없으면 장비 자신으로 들어오거나 나가는 규칙, "*" 는 모든 존
        func zone(_ value: String?) -> String { value.map { $0 == "*" ? "any" : $0 } ?? "this device" }
        let parts = [[proto(section), section.joined("dest_port")].compactMap { $0 }.joined(separator: " "),
                     section.joined("src_ip").map { "from \($0)" },
                     section.joined("src_port").map { "src port \($0)" },
                     section.joined("dest_ip").map { "to \($0)" },
                     family(section)].compactMap { $0 }
        return Rule(id: section.name, name: section.first("name") ?? section.name,
                    flow: "\(zone(section.first("src"))) → \(zone(section.first("dest")))",
                    match: parts.joined(separator: " · "), target: (section.first("target") ?? "").uppercased(), enabled: section.isEnabled,
                    extras: extras(section, shown: ["name", "src", "dest", "proto", "dest_port", "src_ip", "src_port", "dest_ip", "family", "target", "enabled"]),
                    src: section.first("src"), dest: section.first("dest"), destIP: section.first("dest_ip"), coversAllIPv4: coversAllIPv4(section))
    }

    /// proto 를 안 적으면 tcp·udp 뿐이라 전체가 아니다. 모르는 옵션(limit·src_mac·extra …)이 있으면 조건으로 본다 — 칸을 잘못 뒤집느니 예외로 센다
    private static func coversAllIPv4(_ section: UCISection) -> Bool {
        let unconditional: Set = ["name", "src", "dest", "proto", "family", "target", "enabled"]
        guard Set(section.options.keys).isSubset(of: unconditional), section.options["proto"]?.count == 1,
              ["all", "any", "*"].contains(section.first("proto")?.lowercased() ?? "") else { return false }
        return section.first("family")?.hasSuffix("6") != true
    }

    private static func portForward(_ section: UCISection, source: String? = nil) -> Rule {
        let from = [proto(section), section.joined("src_dport")].compactMap { $0 }.joined(separator: " ")
        // dest_port 를 안 적으면 들어온 포트 그대로, dest_ip 를 안 적으면 장비 자신
        let port = section.joined("dest_port") ?? section.joined("src_dport")
        let to = (section.first("dest_ip") ?? "this device") + (port.map { ":\($0)" } ?? "")
        let parts = ["\(from) → \(to)", section.joined("src_ip").map { "from \($0)" }, family(section)].compactMap { $0 }
        // 두 설정의 익명 섹션 이름(@redirect[0])이 겹치므로 출처를 붙인다
        return Rule(id: (source.map { "\($0) " } ?? "") + section.name, name: section.first("name") ?? section.name,
                    flow: [section.first("src"), section.first("dest")].compactMap { $0 }.joined(separator: " → "),
                    match: parts.joined(separator: " · "), target: (section.first("target") ?? "DNAT").uppercased(), enabled: section.isEnabled,
                    extras: extras(section, shown: ["name", "src", "dest", "proto", "src_dport", "dest_port", "dest_ip", "src_ip", "family", "target", "enabled", "idx"]), source: source,
                    src: section.first("src"), dest: section.first("dest"), destIP: section.first("dest_ip"))
    }
}

// MARK: 존 매트릭스

/// 어디서 어디로 새 연결을 낼 수 있나. 판정은 fw4 가 실제로 만드는 체인과 같다 (`fw4 print`, 2026-11-05 openwrt/rootfs 23.05 — fw3 도 같은 설정 의미):
/// 존 → 장비 = 그 존의 input · 장비 → 존 = 그 존의 output · 같은 존 안 = 그 존의 forward ·
/// 다른 존으로 = forwarding 이 있으면 허용, 없으면 defaults 의 forward. 존의 forward 는 다른 존으로 가는 길에 쓰이지 않는다.
/// 규칙은 그 정책보다 먼저 적용되므로, 조건 없는 규칙이 있으면 칸의 판정은 그 규칙이다 (2026-11-06 wgserver → lan: 기본 REJECT 인데 all · IPv4 ACCEPT 규칙으로 실제론 허용).
public struct FirewallMatrix: Sendable, Equatable {
    public enum Endpoint: Sendable, Hashable {
        case device
        case zone(String)

        public var title: String {
            switch self {
            case .device: return "this device"
            case .zone(let name): return name
            }
        }
    }

    public struct Key: Sendable, Hashable {
        public let from: Endpoint
        public let to: Endpoint

        public init(from: Endpoint, to: Endpoint) {
            self.from = from
            self.to = to
        }
    }

    public struct Cell: Sendable, Equatable, Identifiable {
        public var id: Key { key }
        public let key: Key
        /// 기본 정책 (ACCEPT · REJECT · DROP)
        public let policy: String
        /// 그 정책이 어디서 왔나 ("wan zone input" · "forwarding lan → wan" · "defaults forward")
        public let policySource: String
        /// 적용 순서: 공통 체인의 규칙("*") → 존 체인의 규칙 → 포트 포워딩(`ct status dnat accept` 는 규칙 뒤). 꺼진 것도 담는다
        public let rules: [OpenWrtFirewall.Rule]

        /// 위에서 처음 만나는 조건 없는 규칙. 있으면 이 아래 규칙과 기본 정책은 쓰이지 않는다. NOTRACK·MARK 등은 판정이 아니다
        public var decidingRule: OpenWrtFirewall.Rule? {
            rules.first { $0.enabled && $0.coversAllIPv4 && ["ACCEPT", "REJECT", "DROP"].contains($0.target) }
        }

        public var allowed: Bool { (decidingRule?.target ?? policy) == "ACCEPT" }

        /// 조건 없는 규칙 아래에 있어 적용되지 않는 규칙
        public func isShadowed(_ rule: OpenWrtFirewall.Rule) -> Bool {
            guard let deciding = decidingRule, let at = rules.firstIndex(of: deciding), let index = rules.firstIndex(of: rule) else { return false }
            return index > at
        }

        /// 켜져 있고 적용되는 규칙 중 칸의 판정과 반대로 하는 것의 수. 포트 포워딩은 허용 쪽, NOTRACK·MARK 등은 어느 쪽도 아니다
        public var exceptionCount: Int {
            rules.filter { rule in
                guard rule.enabled, !isShadowed(rule) else { return false }
                return allowed ? ["REJECT", "DROP"].contains(rule.target) : ["ACCEPT", "DNAT"].contains(rule.target)
            }.count
        }

        /// 칸 둘째 줄: 판정이 기본 정책과 다르면 그 기본값 + 예외 개수. 없으면 nil
        public var note: String? {
            let defaultAllowed = policy == "ACCEPT"
            let parts = [allowed == defaultAllowed ? nil : "기본 \(defaultAllowed ? "허용" : "차단")", exceptionText].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        /// 예외 규칙 개수 문구. 없으면 nil
        public var exceptionText: String? {
            exceptionCount == 0 ? nil : "\(allowed ? "거부" : "예외") 규칙 \(exceptionCount)"
        }
    }

    public private(set) var rows: [Endpoint] = []
    public private(set) var columns: [Endpoint] = []
    private var cells: [Key: Cell] = [:]

    public init() {}

    /// 장비 → 장비 칸은 없다
    public func cell(from: Endpoint, to: Endpoint) -> Cell? { cells[Key(from: from, to: to)] }

    init(_ firewall: OpenWrtFirewall, defaultForward: String) {
        // 꺼진 존은 체인이 만들어지지 않는다
        let zones = firewall.zones.filter(\.enabled)
        let endpoints = zones.map { Endpoint.zone($0.name) }
        rows = endpoints + [.device]
        columns = [.device] + endpoints
        func matches(_ value: String?, _ zone: String) -> Bool { value == zone || value == "*" }
        func add(_ from: Endpoint, _ to: Endpoint, policy: String, source: String,
                 portForward: (OpenWrtFirewall.Rule) -> Bool, rule: (OpenWrtFirewall.Rule) -> Bool, common: (OpenWrtFirewall.Rule) -> Bool) {
            let key = Key(from: from, to: to)
            // SNAT 는 나가는 주소를 바꿀 뿐이라 칸의 허용·차단과 무관하다 (Port forwards 목록에는 나온다)
            let forwards = firewall.portForwards.filter { $0.target == "DNAT" && portForward($0) }
            let rules = firewall.rules.filter(rule)
            cells[key] = Cell(key: key, policy: policy, policySource: source, rules: rules.filter(common) + rules.filter { !common($0) } + forwards)
        }
        // "*" 규칙은 input · output · forward 공통 체인에 들어가 존 체인보다 먼저 적용된다 (설정 순서와 무관, fw4 print)
        func anySource(_ rule: OpenWrtFirewall.Rule) -> Bool { rule.src == "*" }
        for zone in zones {
            let z = zone.name
            // src 만 있는 규칙 = 장비로 들어오는 규칙. 포트 포워딩은 dest · dest_ip 둘 다 없을 때만 장비로 온다
            add(.zone(z), .device, policy: zone.input, source: "\(z) zone input",
                portForward: { matches($0.src, z) && $0.dest == nil && $0.destIP == nil },
                rule: { matches($0.src, z) && $0.dest == nil }, common: anySource)
            // src 가 없으면 장비에서 나가는 규칙 — dest 도 없으면 모든 존으로 (fw3 경고: "assuming an output rule")
            add(.device, .zone(z), policy: zone.output, source: "\(z) zone output",
                portForward: { _ in false },
                rule: { $0.src == nil && ($0.dest == nil || matches($0.dest, z)) }, common: { $0.dest == nil || $0.dest == "*" })
            for other in zones {
                let y = other.name
                let policy: String, source: String
                if z == y {
                    (policy, source) = (zone.forward, "\(z) zone forward")
                } else if firewall.forwardings.contains(where: { $0.enabled && matches($0.src, z) && matches($0.dest, y) }) {
                    (policy, source) = ("ACCEPT", "forwarding \(z) → \(y)")
                } else {
                    (policy, source) = (defaultForward, "defaults forward")
                }
                // dest 없이 dest_ip 만 있는 포트 포워딩은 어느 존으로 갈지 설정만으론 모른다 → 그 src 의 모든 존 칸에 낸다
                add(.zone(z), .zone(y), policy: policy, source: source,
                    portForward: { matches($0.src, z) && (matches($0.dest, y) || ($0.dest == nil && $0.destIP != nil)) },
                    rule: { matches($0.src, z) && matches($0.dest, y) }, common: anySource)
            }
        }
    }
}

/// 누른 칸. 같은 칸을 또 누르면 닫고, 다른 칸을 누르면 옮긴다. 새로고침으로 그 칸(존)이 사라지면 아무것도 펼치지 않는다.
public struct FirewallSelection: Sendable, Equatable {
    public private(set) var key: FirewallMatrix.Key?

    public init() {}

    public mutating func tap(_ tapped: FirewallMatrix.Key) {
        key = key == tapped ? nil : tapped
    }

    public func cell(in matrix: FirewallMatrix) -> FirewallMatrix.Cell? {
        key.flatMap { matrix.cell(from: $0.from, to: $0.to) }
    }
}
