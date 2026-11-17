// 패킷 상세 (캡처 창에서 행을 고르면): 계층별 "이름 · 값" 줄. hex·펼치는 트리는 두지 않는다.
// 목록이 들고 있는 앞 256 바이트로 다시 읽는다 — 헤더·DNS·SNI·HTTP 앞부분까지는 충분하고, 그 뒤는 "잘림" 으로 표시.

import Foundation

public struct DetailSection: Sendable, Equatable, Identifiable {
    public var id: String { title }
    public let title: String
    public let lines: [DetailLine]
}

public struct DetailLine: Sendable, Equatable, Identifiable {
    public var id: String { name + "\u{1f}" + value }
    public let name: String
    public let value: String
    public init(_ name: String, _ value: String) { self.name = name; self.value = value }
}

public enum PacketDetails {
    /// vendor: MAC → 제조사 (앱의 OUI 표). 없으면 MAC 만
    public static func sections(_ row: CaptureRow, linkType: UInt32, vendor: (String) -> String? = { _ in nil }) -> [DetailSection] {
        var out: [DetailSection] = []
        let raw = row.raw
        let captured = raw.data.count
        out.append(DetailSection(title: "Frame", lines: [
            DetailLine("Time", timeText(raw.time)),
            DetailLine("Length", "\(raw.originalLength) bytes" + (captured < raw.originalLength ? " (앞 \(captured) bytes 만 들고 있음)" : "")),
        ]))
        var b = Bytes(raw.data)
        var ipStart: Bytes?
        var family = 0   // 4 · 6
        switch linkType {
        case LinkType.ethernet:
            guard b.count >= 14 else { return out }
            var type = b.u16(12), at = 14
            var lines = [DetailLine("Source", macText(b.mac(6), vendor)), DetailLine("Destination", macText(b.mac(0), vendor))]
            if type == 0x8100, b.count >= 18 {
                lines.append(DetailLine("VLAN", "\(b.u16(14) & 0x0fff)"))
                type = b.u16(16); at = 18
            }
            lines.append(DetailLine("EtherType", String(format: "0x%04x", type) + (PacketDecoder.etherTypeNames[type].map { " (\($0))" } ?? "")))
            out.append(DetailSection(title: "Ethernet", lines: lines))
            b.skip(at)
            if type == 0x0800 { ipStart = b; family = 4 } else if type == 0x86dd { ipStart = b; family = 6 }
            else if type == 0x0806, let arp = arpSection(b, vendor) { out.append(arp) }
        case LinkType.null, LinkType.loop:
            guard b.count >= 4 else { return out }
            // 목록(PacketDecoder.decode)과 같은 판정: 머리의 주소 계열, 모르는 계열이면 첫 니블
            let loopback = PacketDecoder.loopbackFamily(b, linkType: linkType)
            b.skip(4)
            switch loopback {
            case 2: family = 4
            case 24, 28, 30: family = 6
            default: family = ipVersion(b)
            }
            if family != 0 { ipStart = b }
        case LinkType.raw, LinkType.rawIP:
            family = ipVersion(b)
            if family != 0 { ipStart = b }
        default:
            break
        }
        guard var ip = ipStart else { return out + issueSection(row) }
        var proto: UInt8 = 0
        if family == 4, ip.count >= 20, ip[0] >> 4 == 4 {
            let headerLength = Int(ip[0] & 0x0f) * 4
            let flags = ip.u16(6)
            out.append(DetailSection(title: "IPv4", lines: [
                DetailLine("Source → Destination", "\(ip.ipv4(12)) → \(ip.ipv4(16))"),
                DetailLine("TTL", "\(ip[8])"),
                DetailLine("ID", String(format: "0x%04x", ip.u16(4))),
                DetailLine("Flags", [flags & 0x4000 != 0 ? "DF" : nil, flags & 0x2000 != 0 ? "MF" : nil].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "–"),
                DetailLine("DSCP · ECN", "\(ip[1] >> 2) · \(ip[1] & 3)"),
                DetailLine("Length", "Header \(headerLength) · Total \(ip.u16(2)) bytes"),
            ]))
            proto = ip[9]
            // 첫 조각이 아니면 뒤는 전송 계층 머리가 아니다 — 목록도 "조각" 으로만 낸다
            guard headerLength >= 20, ip.count >= headerLength, flags & 0x1fff == 0 else { return out + issueSection(row) }
            ip.skip(headerLength)
        } else if family == 6, ip.count >= 40, ip[0] >> 4 == 6 {
            out.append(DetailSection(title: "IPv6", lines: [
                DetailLine("Source → Destination", "\(ip.ipv6(8)) → \(ip.ipv6(24))"),
                DetailLine("Hop limit", "\(ip[7])"),
                DetailLine("Flow label", String(format: "0x%05x", (UInt32(ip[1] & 0x0f) << 16) | UInt32(ip.u16(2)))),
                DetailLine("Payload length", "\(ip.u16(4))"),
            ]))
            proto = ip[6]
            ip.skip(40)
            while [0, 43, 44, 60].contains(proto), ip.count >= 8 {
                let length = proto == 44 ? 8 : (Int(ip[1]) + 1) * 8
                guard ip.count >= length else { break }
                if proto == 44, ip.u16(2) >> 3 != 0 { return out + issueSection(row) }   // 첫 조각이 아니다
                proto = ip[0]
                ip.skip(length)
            }
        } else {
            return out + issueSection(row)
        }
        let d = row.decoded
        switch proto {
        case 6 where ip.count >= 20:
            let headerLength = Int(ip[12] >> 4) * 4
            var lines = [
                DetailLine("Ports", "\(ip.u16(0)) → \(ip.u16(2))"),
                DetailLine("Flags", d.tcp?.flags.text.nonEmpty ?? "–"),
                DetailLine("Seq", row.relativeSeq.map { "\($0) (relative) · \(ip.u32(4))" } ?? "\(ip.u32(4))"),
            ]
            if d.tcp?.flags.contains(.ack) == true {
                lines.append(DetailLine("Ack", row.relativeAck.map { "\($0) (relative) · \(ip.u32(8))" } ?? "\(ip.u32(8))"))
            }
            lines.append(DetailLine("Window", "\(ip.u16(14))"))
            lines.append(DetailLine("Payload", "\(d.tcp?.payloadLength ?? 0) bytes"))
            if headerLength > 20, ip.count >= headerLength {
                let options = tcpOptions(ip, from: 20, to: headerLength)
                if !options.isEmpty { lines.append(DetailLine("Options", options.joined(separator: " · "))) }
            }
            out.append(DetailSection(title: "TCP", lines: lines))
        case 17 where ip.count >= 8:
            out.append(DetailSection(title: "UDP", lines: [
                DetailLine("Ports", "\(ip.u16(0)) → \(ip.u16(2))"),
                DetailLine("Length", "\(ip.u16(4))"),
            ]))
        case 1, 58:
            if ip.count >= 2 { out.append(DetailSection(title: proto == 1 ? "ICMP" : "ICMPv6", lines: [
                DetailLine("Type · Code", "\(ip[0]) · \(ip[1])"), DetailLine("Meaning", d.info),
            ])) }
        default:
            break
        }
        if let app = applicationSection(row) { out.append(app) }
        return out + issueSection(row)
    }

    /// "23:39:17.696123" — 오늘이 아니면 앞에 날짜 ("2026-10-31 23:39:17.696123"). 목록과 같은 24시간 꼴
    static func timeText(_ time: Double, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: time)
        let micro = Int(((time - time.rounded(.down)) * 1_000_000).rounded()) % 1_000_000
        let clock = date.formatted(.verbatim("\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
                                             timeZone: .current, calendar: .current)) + String(format: ".%06d", micro)
        guard !Calendar.current.isDate(date, inSameDayAs: now) else { return clock }
        return date.formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)", timeZone: .current, calendar: .current)) + " " + clock
    }

    /// 첫 니블로 본 IP 버전 (4 · 6, 아니면 0)
    private static func ipVersion(_ b: Bytes) -> Int {
        guard b.count >= 1 else { return 0 }
        switch b[0] >> 4 {
        case 4: return 4
        case 6: return 6
        default: return 0
        }
    }

    private static func macText(_ mac: String, _ vendor: (String) -> String?) -> String {
        vendor(mac).map { "\(mac) (\($0))" } ?? mac
    }

    private static func arpSection(_ b: Bytes, _ vendor: (String) -> String?) -> DetailSection? {
        guard b.count >= 28 else { return nil }
        let op = b.u16(6)
        return DetailSection(title: "ARP", lines: [
            DetailLine("Operation", op == 1 ? "Request (who-has)" : op == 2 ? "Reply (is-at)" : "op \(op)"),
            DetailLine("Sender", "\(b.ipv4(14)) · \(macText(b.mac(8), vendor))"),
            DetailLine("Target", "\(b.ipv4(24))" + (op == 2 ? " · \(macText(b.mac(18), vendor))" : "")),
        ])
    }

    /// MSS · WS · SACK 허용 · SACK 블록 · Timestamps
    static func tcpOptions(_ b: Bytes, from start: Int, to end: Int) -> [String] {
        var out: [String] = []
        var at = start
        while at < end, at < b.count {
            let kind = b[at]
            if kind == 0 { break }
            if kind == 1 { at += 1; continue }
            guard at + 1 < end, at + 1 < b.count else { break }
            let length = Int(b[at + 1])
            guard length >= 2, at + length <= end, at + length <= b.count else { break }
            switch kind {
            case 2 where length == 4: out.append("MSS \(b.u16(at + 2))")
            case 3 where length == 3: out.append("WS ×\(1 << min(Int(b[at + 2]), 14))")
            case 4: out.append("SACK permitted")
            case 5: out.append("SACK \((length - 2) / 8) blocks")
            case 8 where length == 10: out.append("TS \(b.u32(at + 2))")
            default: out.append("Option \(kind)")
            }
            at += length
        }
        return out
    }

    private static func applicationSection(_ row: CaptureRow) -> DetailSection? {
        let d = row.decoded
        if let dns = d.dns {
            var lines = [DetailLine("ID", String(format: "0x%04x", dns.id)), DetailLine("Type", dns.isResponse ? "Response · \(dns.rcodeText)" : "Query"),
                         DetailLine("Question", "\(dns.type) \(dns.name)")]
            if dns.isResponse { lines.append(DetailLine("Answers", dns.answers.isEmpty ? "–" : dns.answers.joined(separator: ", "))) }
            return DetailSection(title: d.proto, lines: lines)
        }
        if let wg = d.wireguard {
            var lines: [DetailLine]
            switch wg {
            case .initiation: lines = [DetailLine("Type", "Handshake Initiation (1)")]
            case .response: lines = [DetailLine("Type", "Handshake Response (2)")]
            case .cookie: lines = [DetailLine("Type", "Cookie Reply (3)")]
            case .data(let counter): lines = [DetailLine("Type", "Transport Data (4)"), DetailLine("Counter", "\(counter)")]
            }
            lines.append(DetailLine("Payload", "암호화됨 — 안쪽은 utun 장치에서 캡처하면 보입니다"))
            return DetailSection(title: "WireGuard", lines: lines)
        }
        switch d.proto {
        case "TLS":
            var lines = [DetailLine("Record", d.info)]
            if let sni = d.tlsServerName { lines.append(DetailLine("SNI", sni)) }
            lines.append(DetailLine("Payload", "Encrypted"))
            return DetailSection(title: "TLS", lines: lines)
        case "SSH" where !d.info.hasPrefix("Banner"):
            // 배너 뒤는 암호문이다 — 글자로 풀면 깨진 글자만 나온다
            return DetailSection(title: "SSH", lines: [DetailLine("Payload", "Encrypted")])
        case "HTTP", "SSH":
            guard let offset = d.payloadOffset, offset < row.raw.data.count else { return nil }
            let text = String(decoding: row.raw.data[offset...], as: UTF8.self)
            let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).prefix(8)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let truncated = row.raw.data.count < row.raw.originalLength
            return DetailSection(title: d.proto, lines: lines.enumerated().map { DetailLine($0.offset == 0 ? "First line" : "", String($0.element)) }
                                 + (truncated ? [DetailLine("", "… (앞 \(CaptureStore.keptBytes) bytes 까지)")] : []))
        default:
            return nil
        }
    }

    private static func issueSection(_ row: CaptureRow) -> [DetailSection] {
        guard let issue = row.issue else { return [] }
        return [DetailSection(title: "Issues", lines: [DetailLine(issue.rawValue, issue.explanation)])]
    }
}

extension TCPIssue {
    /// 판정 이유 (상세 칸·도움말)
    public var explanation: String {
        switch self {
        case .refused: return "SYN 에 RST 로 답함 — 포트가 닫혔거나 방화벽이 거부"
        case .resetAfterClose: return "먼저 닫은(FIN) 쪽이 보낸 RST — 연결하자마자 닫는 포트 확인(이 앱의 상태 확인 등)에서 정상으로 나옵니다"
        case .reset: return "연결 중간의 RST — 한쪽이 연결을 끊음"
        case .retransmission: return "이미 보낸 범위를 다시 보냄 — 손실·지연"
        case .zeroWindow: return "받는 쪽 버퍼가 가득 참 — 상대가 읽지 못하고 있음"
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
