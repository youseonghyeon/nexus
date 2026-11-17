// 패킷 한 개를 화면 한 줄로: 링크(Ethernet·BSD loopback·raw IP) → IPv4/IPv6/ARP → TCP/UDP/ICMP → DNS·TLS SNI·HTTP·SSH 배너·WireGuard.
// Wireshark 처럼 모든 프로토콜을 풀지 않는다 — 요약(대화·TCP 문제·DNS·WireGuard)에 필요한 필드와 한 줄 설명만. 깊이 볼 때는 .pcap 저장.

import Foundation

public enum LinkType {
    public static let null: UInt32 = 0        // BSD loopback — lo0·utun (앞 4바이트 주소 계열, 호스트 바이트 순서)
    public static let ethernet: UInt32 = 1
    public static let raw: UInt32 = 12        // 일부 시스템의 raw IP
    public static let rawIP: UInt32 = 101
    public static let loop: UInt32 = 108      // OpenBSD loopback (네트워크 바이트 순서)
}

public struct TCPFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let fin = TCPFlags(rawValue: 0x01)
    public static let syn = TCPFlags(rawValue: 0x02)
    public static let rst = TCPFlags(rawValue: 0x04)
    public static let psh = TCPFlags(rawValue: 0x08)
    public static let ack = TCPFlags(rawValue: 0x10)

    /// "SYN, ACK" — Wireshark 와 같은 순서
    public var text: String {
        [(TCPFlags.syn, "SYN"), (.fin, "FIN"), (.rst, "RST"), (.psh, "PSH"), (.ack, "ACK")].filter { contains($0.0) }.map(\.1).joined(separator: ", ")
    }
}

public struct TCPSegment: Sendable, Equatable {
    public let flags: TCPFlags
    public let seq: UInt32
    public let ack: UInt32
    public let window: UInt16
    public let payloadLength: Int
}

public struct DNSMessage: Sendable, Equatable {
    public let id: UInt16
    public let isResponse: Bool
    /// 0 정상 · 2 SERVFAIL · 3 NXDOMAIN · 5 REFUSED
    public let rcode: Int
    public let name: String
    public let type: String
    /// A·AAAA·CNAME 값
    public let answers: [String]

    public var rcodeText: String { Self.rcodeName(rcode) }

    public static func rcodeName(_ rcode: Int) -> String {
        [0: "NOERROR", 1: "FORMERR", 2: "SERVFAIL", 3: "NXDOMAIN", 4: "NOTIMP", 5: "REFUSED"][rcode] ?? "RCODE \(rcode)"
    }
}

public enum WireGuardMessage: Sendable, Equatable {
    case initiation, response, cookie
    case data(counter: UInt64)

    public var isHandshake: Bool { self == .initiation || self == .response }
}

public struct DecodedPacket: Sendable, Equatable {
    public var source = ""
    public var destination = ""
    public var sourcePort: UInt16?
    public var destinationPort: UInt16?
    /// 목록의 프로토콜 칸: "TCP" · "UDP" · "ICMP" · "ARP" · "DNS" · "TLS" · "HTTP" · "SSH" · "WireGuard" · "IPv6" …
    public var proto = "?"
    /// 대화 묶음의 전송 계층 ("TCP" · "UDP" · "ICMP" · 그 밖)
    public var transport = ""
    public var info = ""
    public var tcp: TCPSegment?
    public var dns: DNSMessage?
    public var wireguard: WireGuardMessage?
    public var tlsServerName: String?
    /// TCP 내용이 시작하는 자리 (원래 바이트 기준) — 여러 조각에 걸친 ClientHello 를 이어 붙일 때
    public var payloadOffset: Int?
    /// Ethernet 일 때 MAC (IP 가 아닌 프레임은 출발·목적 칸도 MAC)
    public var sourceMAC: String?
    public var destinationMAC: String?

    /// "192.168.8.101:58108" · IPv6 는 "[fd00::2]:443"
    public var sourceEndpoint: String { Self.endpoint(source, sourcePort) }
    public var destinationEndpoint: String { Self.endpoint(destination, destinationPort) }
    static func endpoint(_ host: String, _ port: UInt16?) -> String {
        guard let port else { return host }
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

public enum PacketDecoder {
    public static func decode(_ data: [UInt8], linkType: UInt32) -> DecodedPacket {
        var b = Bytes(data)
        switch linkType {
        case LinkType.ethernet:
            guard b.count >= 14 else { return unknown("Ethernet (잘림)") }
            var etherType = b.u16(12), at = 14
            if etherType == 0x8100, b.count >= 18 { etherType = b.u16(16); at = 18 }   // VLAN
            let destinationMAC = b.mac(0), sourceMAC = b.mac(6)
            b.skip(at)
            var p: DecodedPacket
            switch etherType {
            case 0x0800: p = ipv4(b)
            case 0x86dd: p = ipv6(b)
            case 0x0806: p = arp(b)
            default:
                // IP 가 아닌 2계층 프레임: 출발·목적은 MAC, 이름을 아는 EtherType 은 이름으로 (802.3 길이 필드면 LLC)
                p = DecodedPacket()
                p.source = sourceMAC; p.destination = destinationMAC
                p.transport = "Ethernet"
                let name = etherType < 0x0600 ? "LLC" : etherTypeNames[etherType]
                p.proto = name ?? "Ethernet"
                p.info = name.map { etherType < 0x0600 ? "IEEE 802.3 (길이 \(etherType))" : "\($0) · EtherType " + String(format: "0x%04x", etherType) }
                    ?? String(format: "EtherType 0x%04x", etherType)
            }
            p.sourceMAC = sourceMAC
            p.destinationMAC = destinationMAC
            return p
        case LinkType.null, LinkType.loop:
            guard b.count >= 4 else { return unknown("Loopback (잘림)") }
            let family = loopbackFamily(b, linkType: linkType)
            b.skip(4)
            switch family {
            case 2: return ipv4(b)
            case 24, 28, 30: return ipv6(b)   // macOS AF_INET6 = 30 (BSD 마다 다름)
            default: return guessIP(b)
            }
        case LinkType.raw, LinkType.rawIP:
            return guessIP(b)
        default:
            return unknown("링크 종류 \(linkType)")
        }
    }

    /// 자주 보이는 2계층 EtherType (Wireshark 이름)
    static let etherTypeNames: [UInt16: String] = [
        0x8899: "Realtek",          // RRCP·루프 감지 (Realtek 칩 스위치·랜카드)
        0x88cc: "LLDP", 0x888e: "EAPOL", 0x8809: "Slow (LACP)", 0x88f7: "PTP", 0x0842: "Wake-on-LAN",
        0x9000: "Loopback (CTP)", 0x88e1: "HomePlug AV", 0x893a: "IEEE 1905.1", 0x8863: "PPPoE Discovery", 0x8864: "PPPoE",
        0x88a8: "802.1ad", 0x8847: "MPLS", 0x88e5: "MACsec", 0x8035: "RARP", 0x80f3: "AARP", 0x9100: "VLAN (Q-in-Q)",
    ]

    /// BSD loopback 머리의 주소 계열 (null 은 호스트 순서 = 리틀엔디언, loop 는 네트워크 순서). 4바이트가 있을 때만 부른다.
    /// 2 = IPv4 · 24/28/30 = IPv6 · 그 밖은 첫 니블로 짐작 — 상세(PacketDetails)도 같은 값으로 가른다
    static func loopbackFamily(_ b: Bytes, linkType: UInt32) -> UInt32 {
        linkType == LinkType.loop ? UInt32(b.u16(0)) << 16 | UInt32(b.u16(2)) : UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    private static func unknown(_ info: String) -> DecodedPacket {
        var p = DecodedPacket(); p.info = info; return p
    }

    private static func guessIP(_ b: Bytes) -> DecodedPacket {
        guard b.count >= 1 else { return unknown("빈 패킷") }
        switch b[0] >> 4 {
        case 4: return ipv4(b)
        case 6: return ipv6(b)
        default: return unknown("IP 아님")
        }
    }

    // MARK: 네트워크 계층

    private static func ipv4(_ input: Bytes) -> DecodedPacket {
        var b = input
        guard b.count >= 20, b[0] >> 4 == 4 else { return unknown("IPv4 (잘림)") }
        let headerLength = Int(b[0] & 0x0f) * 4
        let totalLength = Int(b.u16(2))
        let fragmentOffset = b.u16(6) & 0x1fff
        let proto = b[9]
        var p = DecodedPacket()
        p.source = b.ipv4(12)
        p.destination = b.ipv4(16)
        guard headerLength >= 20, b.count >= headerLength else { p.proto = "IPv4"; p.info = "머리 잘림"; return p }
        // 실린 길이: 머리의 총길이 기준 (Ethernet 은 짧은 패킷 뒤를 0 으로 채운다)
        let ipPayload = max(0, (totalLength > 0 ? totalLength : b.count) - headerLength)
        b.skip(headerLength)
        if fragmentOffset != 0 { p.proto = "IPv4"; p.transport = "IP"; p.info = "조각 (offset \(Int(fragmentOffset) * 8))"; return p }
        return transport(proto, b, payloadLength: ipPayload, into: p, v6: false)
    }

    private static func ipv6(_ input: Bytes) -> DecodedPacket {
        var b = input
        guard b.count >= 40, b[0] >> 4 == 6 else { return unknown("IPv6 (잘림)") }
        var p = DecodedPacket()
        p.source = b.ipv6(8)
        p.destination = b.ipv6(24)
        var next = b[6]
        var payload = Int(b.u16(4))
        b.skip(40)
        // 확장 머리: hop-by-hop 0 · routing 43 · fragment 44 · destination 60
        var fragmentOffset = 0
        while [0, 43, 44, 60].contains(next), b.count >= 8 {
            let length = next == 44 ? 8 : (Int(b[1]) + 1) * 8
            guard b.count >= length else { break }
            if next == 44 { fragmentOffset = Int(b.u16(2) >> 3) }
            next = b[0]
            payload -= length
            b.skip(length)
        }
        // 첫 조각이 아니면 전송 계층 머리가 없다 (IPv4 와 같게)
        if fragmentOffset != 0 { p.proto = "IPv6"; p.transport = "IP"; p.info = "조각 (offset \(fragmentOffset * 8))"; return p }
        return transport(next, b, payloadLength: max(0, payload), into: p, v6: true)
    }

    private static func arp(_ b: Bytes) -> DecodedPacket {
        var p = DecodedPacket()
        p.proto = "ARP"; p.transport = "ARP"
        guard b.count >= 28, b.u16(0) == 1, b.u16(2) == 0x0800 else { p.info = "ARP"; return p }
        let op = b.u16(6)
        let senderMAC = b.mac(8), senderIP = b.ipv4(14), targetIP = b.ipv4(24)
        p.source = senderIP; p.destination = targetIP
        p.info = op == 1 ? "Who has \(targetIP)? Tell \(senderIP)" : op == 2 ? "\(senderIP) is at \(senderMAC)" : "ARP op \(op)"
        return p
    }

    // MARK: 전송 계층

    private static func transport(_ proto: UInt8, _ input: Bytes, payloadLength: Int, into packet: DecodedPacket, v6: Bool) -> DecodedPacket {
        var p = packet
        var b = input
        switch proto {
        case 6:
            p.proto = "TCP"; p.transport = "TCP"
            guard b.count >= 20 else { p.info = "TCP (잘림)"; return p }
            p.sourcePort = b.u16(0); p.destinationPort = b.u16(2)
            let offset = Int(b[12] >> 4) * 4
            let segment = TCPSegment(flags: TCPFlags(rawValue: b[13] & 0x1f), seq: b.u32(4), ack: b.u32(8), window: b.u16(14),
                                     payloadLength: max(0, payloadLength - offset))
            p.tcp = segment
            var info = "\(p.sourcePort!) → \(p.destinationPort!) [\(segment.flags.text)]"
            if segment.window == 0, !segment.flags.contains(.rst) { info += " Win=0" }
            info += " Len=\(segment.payloadLength)"
            p.info = info
            guard offset >= 20, b.count > offset, segment.payloadLength > 0 else { return p }
            b.skip(offset)
            p.payloadOffset = b.start
            application(tcp: b, into: &p)
            return p
        case 17:
            p.proto = "UDP"; p.transport = "UDP"
            guard b.count >= 8 else { p.info = "UDP (잘림)"; return p }
            p.sourcePort = b.u16(0); p.destinationPort = b.u16(2)
            let length = max(0, Int(b.u16(4)) - 8)
            p.info = "\(p.sourcePort!) → \(p.destinationPort!) Len=\(length)"
            b.skip(8)
            application(udp: b, length: length, into: &p)
            return p
        case 1, 58:
            p.proto = v6 ? "ICMPv6" : "ICMP"; p.transport = "ICMP"
            guard b.count >= 2 else { p.info = "ICMP (잘림)"; return p }
            p.info = v6 ? icmp6Text(b[0], b[1]) : icmpText(b[0], b[1], quoted: b)
            return p
        default:
            p.proto = v6 ? "IPv6" : "IPv4"; p.transport = "IP \(proto)"
            p.info = "프로토콜 \(proto)"
            return p
        }
    }

    private static func icmpText(_ type: UInt8, _ code: UInt8, quoted b: Bytes) -> String {
        switch type {
        case 0: return "Echo reply"
        case 8: return "Echo request"
        case 3:
            let reason = [0: "net unreachable", 1: "host unreachable", 3: "port unreachable", 4: "fragmentation needed", 13: "administratively prohibited"][Int(code)] ?? "code \(code)"
            // 안에 실린 원래 패킷의 목적지·포트 ("udp port 18053 unreachable")
            if b.count >= 8 + 20 {
                let inner = Bytes(Array(b.bytes[(b.start + 8)...]))
                let headerLength = Int(inner[0] & 0x0f) * 4
                if inner[0] >> 4 == 4, inner.count >= headerLength + 4 {
                    let proto = inner[9] == 6 ? "tcp" : inner[9] == 17 ? "udp" : "ip \(inner[9])"
                    return "Destination unreachable (\(reason)) — \(inner.ipv4(16)) \(proto) \(inner.u16(headerLength + 2))"
                }
            }
            return "Destination unreachable (\(reason))"
        case 11: return "Time exceeded (TTL)"
        case 5: return "Redirect"
        default: return "ICMP type \(type) code \(code)"
        }
    }

    private static func icmp6Text(_ type: UInt8, _ code: UInt8) -> String {
        [1: "Destination unreachable", 3: "Time exceeded", 128: "Echo request", 129: "Echo reply",
         133: "Router solicitation", 134: "Router advertisement", 135: "Neighbor solicitation", 136: "Neighbor advertisement"][Int(type)]
            ?? "ICMPv6 type \(type) code \(code)"
    }

    // MARK: 응용 계층

    /// HTTP 요청·응답의 첫 글자들 · SSH 배너 — 바이트로 견준다 (TCP 내용마다 String 을 만들어 견주지 않게)
    private static let httpPrefixes: [[UInt8]] = ["GET ", "POST ", "PUT ", "DELETE ", "HEAD ", "OPTIONS ", "PATCH ", "CONNECT ", "HTTP/1."].map { Array($0.utf8) }
    private static let sshPrefix: [UInt8] = Array("SSH-".utf8)

    private static func application(tcp b: Bytes, into p: inout DecodedPacket) {
        let ports = [p.sourcePort, p.destinationPort]
        // TLS 레코드: 0x16(handshake) · 0x17(데이터) · 0x15(alert) · 0x14(change cipher spec), 버전 0x03xx
        if b.count >= 6, [0x14, 0x15, 0x16, 0x17].contains(b[0]), b[1] == 0x03 {
            p.proto = "TLS"
            switch b[0] {
            case 0x16:
                switch b[5] {
                case 1:
                    p.tlsServerName = clientHelloServerName(b)
                    p.info = "Client Hello" + (p.tlsServerName.map { " · SNI \($0)" } ?? "")
                case 2: p.info = "Server Hello"
                default: p.info = "Handshake"
                }
            case 0x17: p.info = "Application Data"
            case 0x15: p.info = "Alert"
            default: p.info = "Change Cipher Spec"
            }
            return
        }
        if b.hasPrefix(sshPrefix) {
            p.proto = "SSH"
            p.info = "Banner " + b.asciiPrefix(160).prefix { !$0.isNewline }
            return
        }
        if httpPrefixes.contains(where: { b.hasPrefix($0) }) {
            p.proto = "HTTP"
            p.info = String(b.asciiPrefix(160).prefix { !$0.isNewline })
            return
        }
        if ports.contains(53), b.count >= 2 {   // DNS over TCP: 앞 2바이트 길이
            if let dns = dnsMessage(Bytes(Array(b.bytes[(b.start + 2)...]))) { p.proto = "DNS"; p.dns = dns; p.info = dnsText(dns) }
            return
        }
        if ports.contains(22) { p.proto = "SSH"; p.info = "Encrypted · Len=\(p.tcp?.payloadLength ?? 0)" }
    }

    private static func application(udp b: Bytes, length: Int, into p: inout DecodedPacket) {
        let ports = [p.sourcePort, p.destinationPort]
        if ports.contains(53) || ports.contains(5353), let dns = dnsMessage(b) {
            p.proto = ports.contains(5353) ? "mDNS" : "DNS"
            p.dns = dns
            p.info = dnsText(dns)
            return
        }
        if let wg = wireguard(b, length: length, port51820: ports.contains(51820)) {
            p.proto = "WireGuard"
            p.wireguard = wg
            switch wg {
            case .initiation: p.info = "Handshake Initiation"
            case .response: p.info = "Handshake Response"
            case .cookie: p.info = "Cookie Reply"
            case .data(let counter): p.info = "Transport Data · counter=\(counter) · Len=\(length)"
            }
            return
        }
        if ports.contains(67) || ports.contains(68) { p.proto = "DHCP" }
        else if ports.contains(123) { p.proto = "NTP" }
        else if ports.contains(443) { p.proto = "QUIC" }
    }

    /// WireGuard 메시지: 첫 바이트 종류(1~4) + 0 세 개. 핸드셰이크는 길이가 정해져 있어 포트 없이도 알아보고, 데이터는 51820 포트일 때만
    static func wireguard(_ b: Bytes, length: Int, port51820: Bool) -> WireGuardMessage? {
        guard b.count >= 4, b[1] == 0, b[2] == 0, b[3] == 0 else { return nil }
        switch (b[0], length) {
        case (1, 148): return .initiation
        case (2, 92): return .response
        case (3, 64): return .cookie
        case (4, _) where port51820 && length >= 32 && b.count >= 16:
            var counter: UInt64 = 0
            for i in 0..<8 { counter |= UInt64(b[8 + i]) << (8 * UInt64(i)) }
            return .data(counter: counter)
        default: return nil
        }
    }

    // MARK: DNS

    static func dnsText(_ dns: DNSMessage) -> String {
        guard dns.isResponse else { return "Query \(dns.type) \(dns.name)" }
        if dns.rcode != 0 { return "Response \(dns.rcodeText) \(dns.name)" }
        return "Response \(dns.type) \(dns.name)" + (dns.answers.isEmpty ? " (답 없음)" : " → " + dns.answers.prefix(3).joined(separator: ", "))
    }

    static func dnsMessage(_ b: Bytes) -> DNSMessage? {
        guard b.count >= 12 else { return nil }
        let flags = b.u16(2)
        let questions = Int(b.u16(4)), answers = Int(b.u16(6))
        guard questions >= 1, questions <= 4, answers <= 64 else { return nil }
        var at = 12
        guard let (name, end) = dnsName(b, at) else { return nil }
        at = end
        guard b.count >= at + 4 else { return nil }
        let qtype = b.u16(at)
        at += 4
        for _ in 1..<questions {   // 둘째 질문부터는 건너뛴다
            guard let (_, next) = dnsName(b, at), b.count >= next + 4 else { break }
            at = next + 4
        }
        var values: [String] = []
        for _ in 0..<answers {
            guard let (_, next) = dnsName(b, at), b.count >= next + 10 else { break }
            let type = b.u16(next), length = Int(b.u16(next + 8))
            let data = next + 10
            guard b.count >= data + length else { break }
            if type == 1, length == 4 { values.append(b.ipv4(data)) }
            else if type == 28, length == 16 { values.append(b.ipv6(data)) }
            else if type == 5, let (cname, _) = dnsName(b, data) { values.append(cname) }
            at = data + length
        }
        return DNSMessage(id: b.u16(0), isResponse: flags & 0x8000 != 0, rcode: Int(flags & 0x000f), name: name.isEmpty ? "." : name,
                          type: dnsTypeName(qtype), answers: values)
    }

    static func dnsTypeName(_ type: UInt16) -> String {
        [1: "A", 2: "NS", 5: "CNAME", 6: "SOA", 12: "PTR", 15: "MX", 16: "TXT", 28: "AAAA", 33: "SRV", 64: "SVCB", 65: "HTTPS", 255: "ANY"][Int(type)] ?? "TYPE\(type)"
    }

    /// 이름 (압축 포인터 따라가기, 무한 고리 막음) → (이름, 원래 자리의 다음 위치)
    static func dnsName(_ b: Bytes, _ start: Int) -> (String, Int)? {
        var labels: [String] = []
        var at = start, end: Int?, jumps = 0
        while true {
            guard at < b.count else { return nil }
            let length = Int(b[at])
            if length == 0 { at += 1; break }
            if length & 0xc0 == 0xc0 {
                guard at + 1 < b.count, jumps < 16 else { return nil }
                if end == nil { end = at + 2 }
                at = (length & 0x3f) << 8 | Int(b[at + 1])
                jumps += 1
                continue
            }
            guard length <= 63, at + 1 + length <= b.count else { return nil }
            labels.append(b.ascii(at + 1, length))
            at += 1 + length
        }
        return (labels.joined(separator: "."), end ?? at)
    }

    // MARK: TLS SNI

    /// ClientHello 의 server_name 확장. 확장이 첫 TCP 조각 밖이면(긴 ClientHello) nil
    static func clientHelloServerName(_ b: Bytes) -> String? {
        // 레코드 머리 5 + 핸드셰이크 머리 4 + 버전 2 + random 32
        var at = 5 + 4 + 2 + 32
        guard b.count > at else { return nil }
        at += 1 + Int(b[at])                                   // session id
        guard b.count >= at + 2 else { return nil }
        at += 2 + Int(b.u16(at))                               // cipher suites
        guard b.count > at else { return nil }
        at += 1 + Int(b[at])                                   // compression
        guard b.count >= at + 2 else { return nil }
        let extensionsEnd = at + 2 + Int(b.u16(at))
        at += 2
        while at + 4 <= min(extensionsEnd, b.count) {
            let type = b.u16(at), length = Int(b.u16(at + 2))
            let body = at + 4
            if type == 0 {
                // server_name_list 길이 2 · 이름 종류 1 · 이름 길이 2 · 이름
                guard b.count >= body + 5, b[body + 2] == 0 else { return nil }
                let nameLength = Int(b.u16(body + 3))
                guard b.count >= body + 5 + nameLength else { return nil }
                return b.ascii(body + 5, nameLength)
            }
            at = body + length
        }
        return nil
    }
}

/// 바이트 읽기 (앞을 건너뛴 시작점 + 경계 검사는 호출 쪽에서)
struct Bytes {
    let bytes: [UInt8]
    private(set) var start: Int

    init(_ bytes: [UInt8]) { self.bytes = bytes; start = 0 }

    var count: Int { bytes.count - start }
    subscript(_ i: Int) -> UInt8 { bytes[start + i] }
    mutating func skip(_ n: Int) { start = min(bytes.count, start + n) }

    func u16(_ i: Int) -> UInt16 { UInt16(self[i]) << 8 | UInt16(self[i + 1]) }
    func u32(_ i: Int) -> UInt32 { UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3]) }
    func ipv4(_ i: Int) -> String { "\(self[i]).\(self[i + 1]).\(self[i + 2]).\(self[i + 3])" }
    /// "aa:bb:cc:dd:ee:ff" — 표에서 글자를 바로 꺼낸다 (패킷마다 String(format:) 12번이 해석 시간의 큰 몫이었다)
    func mac(_ i: Int) -> String {
        String(unsafeUninitializedCapacity: 17) { out in
            for k in 0..<6 {
                let byte = self[i + k]
                out[k * 3] = Self.hexDigits[Int(byte >> 4)]
                out[k * 3 + 1] = Self.hexDigits[Int(byte & 0x0f)]
                if k < 5 { out[k * 3 + 2] = UInt8(ascii: ":") }
            }
            return 17
        }
    }

    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    /// RFC 5952 짧은 꼴 (가장 긴 0 묶음을 ::)
    func ipv6(_ i: Int) -> String {
        let groups = (0..<8).map { u16(i + $0 * 2) }
        var bestStart = -1, bestLength = 0, runStart = -1
        for index in 0...8 {
            let value: UInt16 = index < 8 ? groups[index] : 1   // 끝에 0 이 아닌 값을 하나 둬 마지막 묶음도 닫는다
            if value == 0 { if runStart < 0 { runStart = index } }
            else if runStart >= 0 {
                if index - runStart > bestLength, index - runStart >= 2 { bestStart = runStart; bestLength = index - runStart }
                runStart = -1
            }
        }
        let hex = groups.map { String($0, radix: 16) }
        guard bestStart >= 0 else { return hex.joined(separator: ":") }
        return hex[..<bestStart].joined(separator: ":") + "::" + hex[(bestStart + bestLength)...].joined(separator: ":")
    }

    func ascii(_ i: Int, _ length: Int) -> String {
        String(decoding: bytes[(start + i)..<min(bytes.count, start + i + length)], as: UTF8.self)
    }

    /// 앞부분이 이 바이트들인가
    func hasPrefix(_ prefix: [UInt8]) -> Bool {
        guard count >= prefix.count else { return false }
        for i in prefix.indices where self[i] != prefix[i] { return false }
        return true
    }

    /// 앞부분을 글자로 (판정용 — 비 ASCII 는 그대로 깨진 글자)
    func asciiPrefix(_ length: Int) -> String { ascii(0, min(length, count)) }
}
