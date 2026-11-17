// 캡처 필터 도우미: tcpdump 식을 몰라도 고르기만 하면 되게.
//   suggestions  지금 글자(마지막 낱말까지) → 다음에 올 수 있는 낱말·값·조합 (빈 칸이면 자주 쓰는 것도)
//   apply        고른 것을 넣은 새 글자 (프리셋은 통째로, 그 밖은 쓰던 낱말을 바꿔 끼움)
//   fromRow      목록 행·대화에서 거꾸로 만들기 (오른쪽 클릭)
//   validate     적용 전 문법 검사 — 헤더만 있는 pcap 파일로 tcpdump -r … -d (root 없이, 패킷 없이 식만 해석)

import Foundation

public struct FilterSuggestion: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case keyword, value, combinator, preset }
    public var id: String { "\(kind)|\(insert)|\(title)" }
    /// 목록에 보이는 이름 ("host" · "nexus" · "and")
    public let title: String
    /// 설명 ("이 주소와 오가는 패킷" · "192.168.8.103 · servers.conf")
    public let detail: String
    /// 넣을 글자 (프리셋은 식 전체)
    public let insert: String
    public let kind: Kind

    public init(_ title: String, _ detail: String, insert: String, kind: Kind) {
        self.title = title; self.detail = detail; self.insert = insert; self.kind = kind
    }
}

/// 값 후보 — 앱이 이미 아는 것 (servers.conf · 게이트웨이 · DNS · 지금 캡처의 상대·포트)
public struct FilterContext: Sendable, Equatable {
    public var hosts: [(value: String, label: String)]
    public var ports: [(value: UInt16, label: String)]
    public var nets: [(value: String, label: String)]
    /// 서버 이름 프리셋 ("nexus 와의 통신")
    public var servers: [(name: String, ip: String)]

    public init(hosts: [(String, String)] = [], ports: [(UInt16, String)] = [], nets: [(String, String)] = [], servers: [(String, String)] = []) {
        self.hosts = hosts.map { ($0.0, $0.1) }
        self.ports = ports.map { ($0.0, $0.1) }
        self.nets = nets.map { ($0.0, $0.1) }
        self.servers = servers.map { ($0.0, $0.1) }
    }

    public static func == (a: FilterContext, b: FilterContext) -> Bool {
        a.hosts.map(\.value) == b.hosts.map(\.value) && a.ports.map(\.value) == b.ports.map(\.value)
            && a.nets.map(\.value) == b.nets.map(\.value) && a.servers.map(\.ip) == b.servers.map(\.ip)
    }

    /// 자주 쓰는 포트 (캡처에서 본 포트 앞에 붙는다)
    public static let commonPorts: [(UInt16, String)] = [(22, "SSH"), (53, "DNS"), (80, "HTTP"), (443, "HTTPS·QUIC"), (51820, "WireGuard"),
                                                         (3389, "RDP"), (5432, "PostgreSQL"), (3306, "MySQL"), (6379, "Redis")]
}

/// 대화 끝점 문자열("1.2.3.4:443" · "[fe80::1]:443" · 포트 없는 "fe80::1" · "1.2.3.4")을 호스트와 포트로 가른다.
public enum CaptureEndpoint {
    /// DecodedPacket.endpoint 가 내는 꼴 그대로: IPv6 는 포트가 있을 때만 대괄호, 포트가 없으면 주소(또는 MAC)만.
    /// 대괄호 없는 IPv6·MAC 은 ':' 가 여럿이라 포트로 읽지 않는다 ("fe80::1" 을 fe80 의 1번 포트로 읽었다)
    public static func parts(_ endpoint: String) -> (host: String, port: Int?) {
        if endpoint.hasPrefix("["), let close = endpoint.firstIndex(of: "]") {
            let host = String(endpoint[endpoint.index(after: endpoint.startIndex)..<close])
            let rest = endpoint[endpoint.index(after: close)...]
            return (host, rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil)
        }
        let pieces = endpoint.split(separator: ":", omittingEmptySubsequences: false)
        if pieces.count == 2, !pieces[0].isEmpty, let port = Int(pieces[1]) { return (String(pieces[0]), port) }
        return (endpoint, nil)
    }
}

public enum CaptureFilterAssist {
    static let keywords: [FilterSuggestion] = [
        FilterSuggestion("host", "이 주소와 오가는 패킷 → 다음에 주소", insert: "host", kind: .keyword),
        FilterSuggestion("port", "이 포트 (TCP·UDP) → 다음에 번호", insert: "port", kind: .keyword),
        FilterSuggestion("net", "이 대역 → 다음에 192.168.8.0/24 꼴", insert: "net", kind: .keyword),
        FilterSuggestion("tcp", "TCP 만 (뒤에 port 를 붙일 수 있음)", insert: "tcp", kind: .keyword),
        FilterSuggestion("udp", "UDP 만 (뒤에 port 를 붙일 수 있음)", insert: "udp", kind: .keyword),
        FilterSuggestion("icmp", "ping·도달 불가 같은 ICMP 만", insert: "icmp", kind: .keyword),
        FilterSuggestion("arp", "ARP (주소 묻기) 만", insert: "arp", kind: .keyword),
        FilterSuggestion("src", "보내는 쪽이 … (뒤에 host·port·net)", insert: "src", kind: .keyword),
        FilterSuggestion("dst", "받는 쪽이 … (뒤에 host·port·net)", insert: "dst", kind: .keyword),
        FilterSuggestion("not", "다음 조건을 뺀다", insert: "not", kind: .keyword),
    ]
    static let combinators: [FilterSuggestion] = [
        FilterSuggestion("and", "그리고 — 둘 다 맞는 것", insert: "and", kind: .combinator),
        FilterSuggestion("or", "또는 — 하나라도 맞는 것", insert: "or", kind: .combinator),
        FilterSuggestion("and not", "그리고 이것은 빼고", insert: "and not", kind: .combinator),
    ]
    static let fixedPresets: [FilterSuggestion] = [
        FilterSuggestion("DNS 만", "port 53", insert: "port 53", kind: .preset),
        FilterSuggestion("WireGuard 만", "udp port 51820", insert: "udp port 51820", kind: .preset),
        FilterSuggestion("웹 (80·443)", "tcp port 80 or tcp port 443 or udp port 443", insert: "tcp port 80 or tcp port 443 or udp port 443", kind: .preset),
        FilterSuggestion("연결 시작·끊김만", "SYN·FIN·RST 가 있는 TCP", insert: "tcp[tcpflags] & (tcp-syn|tcp-fin|tcp-rst) != 0", kind: .preset),
        FilterSuggestion("ping·ICMP 만", "icmp or icmp6", insert: "icmp or icmp6", kind: .preset),
        FilterSuggestion("WireGuard 빼고", "not udp port 51820", insert: "not udp port 51820", kind: .preset),
    ]

    /// (앞 낱말들, 쓰던 낱말) — 끝이 빈칸이면 쓰던 낱말은 ""
    static func split(_ text: String) -> (done: [String], partial: String) {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if text.isEmpty || text.last == " " || text.last == "\t" { return (words, "") }
        return (Array(words.dropLast()), words.last ?? "")
    }

    public static func suggestions(for text: String, context: FilterContext, limit: Int = 12) -> [FilterSuggestion] {
        let (done, partial) = split(text)
        let prev = done.last?.lowercased() ?? ""
        let needle = partial.lowercased()
        // 낱말·프리셋은 앞부분으로만, 값은 설명(서버 이름 등)으로도 찾는다 — "ho" 에 설명에 host 가 든 src·dst 가 끼지 않게
        func keep(_ s: FilterSuggestion) -> Bool {
            if needle.isEmpty || s.title.lowercased().hasPrefix(needle) || s.insert.lowercased().hasPrefix(needle) { return true }
            return s.kind == .value && s.detail.lowercased().contains(needle)
        }
        var out: [FilterSuggestion] = []
        switch prev {
        case "host":
            out = context.hosts.map { FilterSuggestion($0.value, $0.label, insert: $0.value, kind: .value) }
                + (context.hosts.isEmpty ? [FilterSuggestion("192.168.8.103", "주소를 직접 쓰세요", insert: "", kind: .value)] : [])
        case "port":
            var seen = Set<UInt16>()
            out = (context.ports + FilterContext.commonPorts.map { ($0.0, $0.1) }).compactMap { item in
                guard seen.insert(item.0).inserted else { return nil }
                return FilterSuggestion("\(item.0)", item.1, insert: "\(item.0)", kind: .value)
            }
        case "net":
            out = context.nets.map { FilterSuggestion($0.value, $0.label, insert: $0.value, kind: .value) }
        case "src", "dst":
            out = keywords.filter { ["host", "port", "net"].contains($0.insert) }
        case "tcp", "udp":
            out = [FilterSuggestion("port", "이 프로토콜의 포트 → 다음에 번호", insert: "port", kind: .keyword)] + combinators
        case "", "and", "or", "not", "(":
            out = keywords.filter { prev != "not" || $0.insert != "not" }
            if done.isEmpty {
                out += context.servers.map { FilterSuggestion("\($0.name) 와의 통신", "host \($0.ip)", insert: "host \($0.ip)", kind: .preset) }
                out += fixedPresets
            }
        default:
            // 값·프로토콜 뒤 → 이어 붙이기
            out = combinators
        }
        return Array(out.filter(keep).prefix(limit))
    }

    /// 고른 것을 넣은 새 글자 (끝에 빈칸 — 다음 제안이 바로 이어지게)
    public static func apply(_ suggestion: FilterSuggestion, to text: String) -> String {
        if suggestion.kind == .preset { return suggestion.insert }
        guard !suggestion.insert.isEmpty else { return text }
        let (done, _) = split(text)
        return (done + [suggestion.insert]).joined(separator: " ") + " "
    }

    /// 목록 행에서 거꾸로: (이름, 식). 주소 둘·포트 둘이면 "이 대화만"
    public static func fromPacket(_ p: DecodedPacket) -> [(title: String, filter: String)] {
        var out: [(String, String)] = []
        let ipHosts = [p.source, p.destination].filter { !$0.isEmpty && ($0.contains(".") || $0.contains(":")) && $0.count <= 45 && !$0.contains(" ") && p.sourceMAC != $0 && p.destinationMAC != $0 }
        if ipHosts.count == 2, let sp = p.sourcePort, let dp = p.destinationPort, ["TCP", "UDP"].contains(p.transport) {
            let proto = p.transport.lowercased()
            out.append(("이 대화만 캡처", "host \(p.source) and host \(p.destination) and \(proto) port \(sp) and \(proto) port \(dp)"))
        }
        for host in ipHosts { out.append(("host \(host)", "host \(host)")) }
        if let port = p.destinationPort { out.append(("port \(port)", "port \(port)")) }
        if let port = p.sourcePort, port != p.destinationPort { out.append(("port \(port)", "port \(port)")) }
        if let mac = p.sourceMAC, p.transport == "Ethernet" { out.append(("ether host \(mac)", "ether host \(mac)")) }
        if let port = p.destinationPort { out.append(("이 포트 빼고 (port \(port))", "not port \(port)")) }
        return out
    }

    /// 대화 줄에서: 두 끝 주소(+포트)
    public static func fromConversation(_ c: Conversation) -> String? {
        let (a, ap) = CaptureEndpoint.parts(c.a), (b, bp) = CaptureEndpoint.parts(c.b)
        guard !a.isEmpty, !b.isEmpty, !a.contains(" "), !b.contains(" ") else { return nil }
        if c.transport == "Ethernet" { return "ether host \(a) and ether host \(b)" }
        var filter = "host \(a) and host \(b)"
        if let ap, let bp, ["TCP", "UDP"].contains(c.transport) {
            let proto = c.transport.lowercased()
            filter += " and \(proto) port \(ap) and \(proto) port \(bp)"
        }
        return filter
    }

    // MARK: 문법 검사

    /// 헤더만 있는 pcap (링크 종류만 정해 준다)
    public static func headerFile(linkType: UInt32) -> Data {
        PcapWriter.data(linkType: linkType, snaplen: UInt32(CaptureCommand.snaplen), packets: [])
    }

    /// 장치 이름으로 링크 종류 짐작 (캡처 전 검사용) — utun·lo·ipsec 은 BSD loopback, 그 밖은 Ethernet
    public static func linkType(forDevice device: String) -> UInt32 {
        ["utun", "lo", "ipsec", "gif", "stf"].contains(where: device.hasPrefix) ? LinkType.null : LinkType.ethernet
    }

    /// tcpdump -d 의 표준 오류 → 화면 문구 ("unknown host 'prot'" → "필터 문법 오류: unknown host 'prot'")
    public static func validationMessage(exitCode: Int32, stderr: String) -> String? {
        guard exitCode != 0 else { return nil }
        let line = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.hasPrefix("reading from file") } ?? "tcpdump 가 식을 읽지 못했습니다"
        return "필터 문법 오류: " + line.replacingOccurrences(of: "tcpdump: ", with: "")
    }

    /// 적용 전 검사 (root 불필요). nil = 통과. 검사 자체를 못 하면(임시 파일 실패 등) 통과로 보고 tcpdump 에 맡긴다
    public static func validate(_ filter: String, linkType: UInt32, runner: any CommandRunner) async -> String? {
        guard !filter.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let arguments = CaptureCommand.arguments(device: "lo0", filter: filter) else {
            return "필터에 - 로 시작하는 낱말은 쓸 수 없습니다 (tcpdump 옵션으로 읽힘)"
        }
        let words = Array(arguments.drop { $0 != "-" }.dropFirst())   // "-w" "-" 뒤의 식 낱말
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nexus-filter-\(linkType).pcap")
        guard (try? headerFile(linkType: linkType).write(to: url)) != nil else { return nil }
        let result = await runner.run("/usr/sbin/tcpdump", ["-r", url.path, "-d"] + words, timeout: 5)
        return validationMessage(exitCode: result.exitCode, stderr: result.stderr)
    }
}
