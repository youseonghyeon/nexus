// 패킷 캡처 창의 상태: 최근 패킷(목록·.pcap 저장용, 최대 limit 개) + 요약(대화 · TCP 문제 · DNS · WireGuard).
// 요약은 목록에서 밀려난 패킷까지 계속 센다. UI 없는 로직이라 여기서 테스트한다 (PacketCaptureTests).
//
// TCP 문제 판정 (흐름 = 양 끝 주소·포트 쌍, 방향별 상태):
//   거부    SYN 에 RST 로 답함 (포트 닫힘·방화벽 거부)
//   닫은 뒤 RST  이미 FIN 을 보낸 쪽이 RST — 연결하자마자 닫는 포트 확인(이 앱의 상태 확인 등)에서 정상으로 나온다
//   RST     그 밖의 중간 끊김
//   재전송  같은 방향에서 이미 보낸 범위(seq+len)를 다시 보냄 (keep-alive 1바이트는 뺀다)
//   응답 없는 SYN  SYN 뒤 3초 넘게 SYN/ACK 가 없음 (마지막 패킷 시각 기준)
//   Win=0   받는 쪽 버퍼가 가득 (RST 는 뺀다)

import Foundation

public enum TCPIssue: String, Sendable, CaseIterable {
    case refused = "거부"
    case resetAfterClose = "닫은 뒤 RST"
    case reset = "RST"
    case retransmission = "재전송"
    case zeroWindow = "Win=0"
}

public struct CaptureRow: Sendable, Identifiable, Equatable {
    public let id: Int
    public let raw: CapturedPacket
    public let decoded: DecodedPacket
    public let conversation: String
    public let issue: TCPIssue?
    /// TCP Seq·Ack 를 연결 기준 상대값으로 (Wireshark 처럼 SYN 이 0). 연결 시작을 못 봤으면 그 방향 첫 패킷이 기준
    public var relativeSeq: UInt32?
    public var relativeAck: UInt32?
    /// 검색용 글자 (소문자, 받을 때 한 번 만든다 — 2만 행을 검색할 때마다 잇고 소문자로 바꾸면 60ms 넘게 걸렸다)
    public var searchText = ""

    /// 주소·포트·프로토콜·Info·MAC·문제 이름 + vendors(제조사). 두 끝 글자를 이미 만들었으면 넘긴다 (패킷마다 다시 만들지 않게)
    static func makeSearchText(_ d: DecodedPacket, source: String? = nil, destination: String? = nil, issue: TCPIssue?, vendors: [String]) -> String {
        ([source ?? d.sourceEndpoint, destination ?? d.destinationEndpoint, d.proto, d.info, d.sourceMAC ?? "", d.destinationMAC ?? "", issue?.rawValue ?? ""] + vendors)
            .joined(separator: " ").lowercased()
    }

    /// 목록 검색: 낱말(빈칸으로 나눔)이 모두 들어 있으면 — 대소문자 무시
    public func matches(_ terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        let text = searchText.isEmpty ? Self.makeSearchText(decoded, issue: issue, vendors: []) : searchText
        return terms.allSatisfy { text.contains($0) }
    }

    public static func searchTerms(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }
}

public struct Conversation: Sendable, Identifiable, Equatable {
    public let id: String
    public let transport: String
    /// 정렬된 두 끝 ("192.168.8.101:52786" · "192.0.2.143:51820")
    public let a: String
    public let b: String
    /// 응용 이름 (TLS SNI · WireGuard · DNS …), 처음 알아본 것
    public var label: String?
    public var packets = 0
    public var bytes = 0
    public var first: Double
    public var last: Double
    /// SYN → SYN/ACK 걸린 시간 (초)
    public var handshake: Double?
}

public struct DNSTransaction: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let type: String
    public let server: String
    public let asked: Double
    public var answered: Double?
    public var rcode: Int?
    public var answers: [String] = []

    public var latency: Double? { answered.map { $0 - asked } }
}

public struct CaptureWireGuardPeer: Sendable, Identifiable, Equatable {
    /// 상대 끝 ("192.0.2.143:51820")
    public let id: String
    public var lastHandshake: Double?
    public var handshakes = 0
    public var dataPackets = 0
    public var lastData: Double?
}

public struct CaptureStore: Sendable {
    public static let defaultLimit = 20_000
    /// 목록에 들고 있는 바이트 (.pcap 저장은 이만큼만 — 헤더·SNI·DNS 를 읽기엔 충분)
    public static let keptBytes = 256

    public let limit: Int
    public private(set) var rows: [CaptureRow] = []
    public private(set) var linkType: UInt32 = LinkType.ethernet
    public private(set) var totalPackets = 0
    public private(set) var totalBytes = 0
    /// 목록에서 밀려난 패킷 수
    public private(set) var dropped = 0
    public private(set) var conversations: [String: Conversation] = [:]
    public private(set) var issueCounts: [TCPIssue: Int] = [:]
    public private(set) var dns: [DNSTransaction] = []
    public private(set) var wireguard: [String: CaptureWireGuardPeer] = [:]
    public private(set) var lastTime: Double?
    /// MAC → 제조사 (앱의 OUI 표). 검색용 글자에 넣는다
    public var vendorLookup: (@Sendable (String) -> String?)?
    private var vendorCache: [String: String] = [:]

    private var nextID = 1
    private var flows: [String: FlowState] = [:]
    private var pendingSYN: [String: Double] = [:]
    private var dnsIndex: [String: Int] = [:]
    /// 한 조각에 다 안 온 ClientHello (방향 키 → 지금까지의 TLS 바이트). 최근 OpenSSL·Chrome 은 1.5KB 가 넘고 SNI 가 뒤에 있다
    /// 기대 seq 가 맞는 다음 조각만 붙인다 — 조각을 놓쳤을 때 무관한 조각을 붙여 엉뚱한 SNI 를 만들지 않게 (2026-11-01 Fable 리뷰)
    /// 다음 조각이 helloTimeout 안에 안 오면 버린다 — 남아 있는 동안은 모든 TCP 패킷이 키를 만들어 찾아본다
    private var pendingHello: [String: (bytes: [UInt8], nextSeq: UInt32, at: Double)] = [:]
    static let helloTimeout: Double = 5

    /// 한 방향의 TCP 상태 ("출발 → 목적" 키)
    private struct FlowState {
        var maxEnd: UInt32?
        var sentFIN = false
        /// 상대 Seq 기준 (SYN 의 seq, 못 봤으면 첫 패킷)
        var base: UInt32?
    }
    /// 대화 개수 상한 — 넘으면 오래 조용한 것부터 버린다 (DNS·QUIC 처럼 포트가 매번 바뀌는 흐름)
    static let conversationLimit = 20_000

    public init(limit: Int = CaptureStore.defaultLimit) { self.limit = max(1, limit) }

    /// 새 캡처를 시작할 때 링크 종류를 정한다 (장치마다 다르다 — en11 Ethernet · utun·lo0 BSD loopback)
    public mutating func setLinkType(_ type: UInt32) { linkType = type }

    /// 목록·요약을 비운다 (링크 종류·제조사 표는 그대로 — 캡처 중이면 계속 받는다)
    public mutating func reset() {
        let lookup = vendorLookup
        self = CaptureStore(limit: limit, linkType: linkType)
        vendorLookup = lookup
    }

    private init(limit: Int, linkType: UInt32) {
        self.limit = limit
        self.linkType = linkType
    }

    private mutating func vendor(_ mac: String?) -> String? {
        guard let mac, let lookup = vendorLookup else { return nil }
        if let cached = vendorCache[mac] { return cached.isEmpty ? nil : cached }
        let name = lookup(mac) ?? ""
        if vendorCache.count > 4_096 { vendorCache.removeAll() }
        vendorCache[mac] = name
        return name.isEmpty ? nil : name
    }

    public mutating func ingest(_ packets: [CapturedPacket]) {
        for raw in packets { ingest(raw) }
        // 오래 켜 둬도 판정용 상태가 끝없이 늘지 않게 (포트 훑기·연결 폭주). 비우면 그 사이 재전송·거부 판정만 잠깐 놓친다
        if flows.count > 50_000 { flows.removeAll(keepingCapacity: false) }
        if pendingSYN.count > 10_000 { pendingSYN.removeAll(keepingCapacity: false) }
        if pendingHello.count > 1_000 { pendingHello.removeAll(keepingCapacity: false) }
        if !pendingHello.isEmpty, let lastTime { pendingHello = pendingHello.filter { lastTime - $0.value.at <= Self.helloTimeout } }
        if conversations.count > Self.conversationLimit {
            let stale = conversations.values.sorted { $0.last < $1.last }.prefix(conversations.count - Self.conversationLimit * 3 / 4)
            for c in stale { conversations[c.id] = nil }
        }
        // 넘친 만큼 한꺼번에 (limit 의 1/4 넘을 때) — 매 묶음마다 2만 개를 옮기지 않게 (2026-11-01 리뷰)
        if rows.count > limit + max(1, limit / 4) || (rows.count > limit && packets.isEmpty) {
            trimRows()
        }
    }

    /// 목록을 limit 개로 (화면에 넘기기 전에도 부른다)
    public mutating func trimRows() {
        guard rows.count > limit else { return }
        let extra = rows.count - limit
        rows.removeFirst(extra)
        dropped += extra
    }

    private mutating func ingest(_ raw: CapturedPacket) {
        var decoded = PacketDecoder.decode(raw.data, linkType: linkType)
        // 두 끝 글자는 패킷마다 한 번만 만든다 (대화 키 · 흐름 키 · 검색 글자가 같이 쓴다)
        let source = decoded.sourceEndpoint, destination = decoded.destinationEndpoint
        if decoded.tcp != nil { joinClientHello(&decoded, raw.data, source: source, destination: destination, time: raw.time) }
        totalPackets += 1
        totalBytes += raw.originalLength
        lastTime = raw.time
        let ends = source <= destination ? (source, destination) : (destination, source)
        let key = "\(decoded.transport.isEmpty ? decoded.proto : decoded.transport)|\(ends.0)|\(ends.1)"
        var conversation = conversations[key] ?? Conversation(id: key, transport: decoded.transport.isEmpty ? decoded.proto : decoded.transport,
                                                              a: ends.0, b: ends.1, first: raw.time, last: raw.time)
        conversation.packets += 1
        conversation.bytes += raw.originalLength
        conversation.last = raw.time
        // SNI 는 늦게(이어진 조각에서) 알 수 있어 "TLS" 를 덮어쓴다
        if let sni = decoded.tlsServerName { conversation.label = "TLS \(sni)" } else if conversation.label == nil { conversation.label = Self.label(decoded) }

        var issue: TCPIssue?
        var relative: (seq: UInt32, ack: UInt32?)?
        if let tcp = decoded.tcp { (issue, relative) = track(tcp, source: source, destination: destination, time: raw.time, conversation: &conversation) }
        // mDNS 는 응답이 멀티캐스트로 가 짝이 안 맞는다 — DNS 요약에서 뺀다 (목록에는 보인다)
        if let dnsMessage = decoded.dns, decoded.proto == "DNS" { track(dnsMessage, decoded, time: raw.time) }
        if let wg = decoded.wireguard { track(wg, decoded, time: raw.time) }
        conversations[key] = conversation
        if let issue { issueCounts[issue, default: 0] += 1 }

        let kept = raw.data.count > Self.keptBytes ? CapturedPacket(time: raw.time, originalLength: raw.originalLength, data: Array(raw.data.prefix(Self.keptBytes))) : raw
        let vendors = [vendor(decoded.sourceMAC), vendor(decoded.destinationMAC)].compactMap { $0 }
        rows.append(CaptureRow(id: nextID, raw: kept, decoded: decoded, conversation: key, issue: issue,
                               relativeSeq: relative?.seq, relativeAck: relative?.ack,
                               searchText: CaptureRow.makeSearchText(decoded, source: source, destination: destination, issue: issue, vendors: vendors)))
        nextID += 1
    }

    /// ClientHello 가 레코드 길이보다 짧게 왔으면 모아 두고, 같은 방향 다음 조각을 붙여 SNI 를 다시 찾는다 (최대 16KB · 조각 사이 helloTimeout 초)
    private mutating func joinClientHello(_ p: inout DecodedPacket, _ data: [UInt8], source: String, destination: String, time: Double) {
        guard let tcp = p.tcp, let offset = p.payloadOffset, offset < data.count else { return }
        let helloStart = p.info.hasPrefix("Client Hello") && p.tlsServerName == nil
        // 대부분의 TCP 패킷: ClientHello 시작도 아니고 기다리는 조각도 없다 — 키·바이트 사본을 만들지 않는다
        guard helloStart || !pendingHello.isEmpty else { return }
        let key = "\(source)>\(destination)"
        let payload = data[offset...].prefix(tcp.payloadLength)   // 사본 없이 조각으로 (모아 둘 때만 복사)
        // 잡은 바이트가 실린 길이보다 짧으면(snaplen) 이어 붙일 수 없다
        let complete = payload.count == tcp.payloadLength
        if helloStart, payload.count >= 5 {
            let recordLength = Int(payload[payload.startIndex + 3]) << 8 | Int(payload[payload.startIndex + 4])
            if complete, payload.count < 5 + recordLength { pendingHello[key] = (Array(payload), tcp.seq &+ UInt32(payload.count), time) }
            return
        }
        guard !payload.isEmpty, let waiting = pendingHello[key], waiting.nextSeq == tcp.seq else { return }
        pendingHello[key] = nil
        guard time - waiting.at <= Self.helloTimeout else { return }   // 너무 늦게 온 조각 — 같은 seq 라도 다른 연결일 수 있다
        var buffer = waiting.bytes
        buffer.append(contentsOf: payload)   // 꺼낸 버퍼에 바로 이어 붙인다
        if let name = PacketDecoder.clientHelloServerName(Bytes(buffer)) {
            p.tlsServerName = name
            p.proto = "TLS"
            p.info = "Client Hello (이어짐) · SNI \(name)"
        } else if complete, buffer.count < 16_384, buffer.count < 5 + (Int(buffer[3]) << 8 | Int(buffer[4])) {
            pendingHello[key] = (buffer, tcp.seq &+ UInt32(payload.count), time)
        }
    }

    static func label(_ p: DecodedPacket) -> String? {
        if let sni = p.tlsServerName { return "TLS \(sni)" }
        if p.transport == "Ethernet" { return p.proto }   // Realtek·LLDP 같은 2계층 프레임
        switch p.proto {
        case "WireGuard", "DNS", "mDNS", "SSH", "HTTP", "DHCP", "NTP", "QUIC", "TLS": return p.proto
        default: return nil
        }
    }

    // MARK: TCP

    /// → (문제, 상대 Seq·Ack)
    private mutating func track(_ tcp: TCPSegment, source: String, destination: String, time: Double, conversation: inout Conversation) -> (TCPIssue?, (seq: UInt32, ack: UInt32?)) {
        let forward = "\(source)>\(destination)"
        let backward = "\(destination)>\(source)"
        let flags = tcp.flags
        func relative(_ base: UInt32?) -> (seq: UInt32, ack: UInt32?) {
            let ackBase = flows[backward]?.base
            return (tcp.seq &- (base ?? tcp.seq), tcp.flags.contains(.ack) ? ackBase.map { tcp.ack &- $0 } : nil)
        }
        if flags.contains(.syn), !flags.contains(.ack) {
            pendingSYN[forward] = time
            flows[forward] = FlowState(maxEnd: tcp.seq &+ 1, base: tcp.seq)
            return (nil, relative(tcp.seq))
        }
        if flags.contains(.syn), flags.contains(.ack) {
            if let asked = pendingSYN.removeValue(forKey: backward), conversation.handshake == nil { conversation.handshake = time - asked }
            flows[forward] = FlowState(maxEnd: tcp.seq &+ 1, base: tcp.seq)
            return (nil, relative(tcp.seq))
        }
        if flags.contains(.rst) {
            let rel = relative(flows[forward]?.base)
            // SYN 에 바로 RST → 거부. 이미 FIN 을 보낸 쪽의 RST → 닫은 뒤 RST
            if pendingSYN.removeValue(forKey: backward) != nil { return (.refused, rel) }
            if flows[forward]?.sentFIN == true { return (.resetAfterClose, rel) }
            return (.reset, rel)
        }
        var state = flows[forward] ?? FlowState(base: tcp.seq)
        if state.base == nil { state.base = tcp.seq }
        var issue: TCPIssue?
        let length = UInt32(tcp.payloadLength)
        if length > 0, let maxEnd = state.maxEnd {
            let end = tcp.seq &+ length
            // 이미 보낸 범위 안 (wrap 은 부호 있는 차로) — keep-alive(1바이트, maxEnd-1)는 뺀다
            let behind = Int32(bitPattern: maxEnd &- end) >= 0
            let keepAlive = length == 1 && tcp.seq == maxEnd &- 1
            if behind, !keepAlive { issue = .retransmission }
        }
        let end = tcp.seq &+ length &+ (flags.contains(.fin) ? 1 : 0)
        if let maxEnd = state.maxEnd { if Int32(bitPattern: end &- maxEnd) > 0 { state.maxEnd = end } } else { state.maxEnd = end }
        if flags.contains(.fin) { state.sentFIN = true }
        flows[forward] = state
        if issue == nil, tcp.window == 0 { issue = .zeroWindow }
        return (issue, relative(state.base))
    }

    /// SYN 뒤 3초 넘게 답이 없는 연결 수 (마지막 패킷 시각 기준)
    public var unansweredSYN: Int {
        guard let lastTime else { return 0 }
        return pendingSYN.values.filter { lastTime - $0 > 3 }.count
    }

    // MARK: DNS

    private mutating func track(_ message: DNSMessage, _ p: DecodedPacket, time: Double) {
        if !message.isResponse {
            let id = "\(p.sourceEndpoint)#\(message.id)"
            let transaction = DNSTransaction(id: "\(id)@\(time)", name: message.name, type: message.type, server: p.destination, asked: time)
            dnsIndex[id] = dns.count
            dns.append(transaction)
        } else {
            let id = "\(p.destinationEndpoint)#\(message.id)"
            guard let index = dnsIndex.removeValue(forKey: id), index < dns.count, dns[index].answered == nil else { return }
            dns[index].answered = time
            dns[index].rcode = message.rcode
            dns[index].answers = message.answers
        }
        // 오래된 것부터 버린다 (요약은 최근 500건)
        if dns.count > 600 {
            dns.removeFirst(100)
            dnsIndex = dnsIndex.compactMapValues { $0 >= 100 ? $0 - 100 : nil }
        }
    }

    // MARK: WireGuard

    private mutating func track(_ message: WireGuardMessage, _ p: DecodedPacket, time: Double) {
        // 상대 끝: 51820 쪽을 서버로 본다. 둘 다 아니면 목적지
        let peer = p.sourcePort == 51820 ? p.sourceEndpoint : p.destinationPort == 51820 ? p.destinationEndpoint : p.destinationEndpoint
        var state = wireguard[peer] ?? CaptureWireGuardPeer(id: peer)
        if message.isHandshake {
            state.handshakes += 1
            state.lastHandshake = time
        } else if case .data = message {
            state.dataPackets += 1
            state.lastData = time
        }
        wireguard[peer] = state
    }

    // MARK: 화면용

    /// 바이트 많은 순 대화 — 전부 정렬하지 않고 한 번 훑으며 상위 count 개만 (대화 2만 개를 화면 갱신마다 정렬했다)
    public func topConversations(_ count: Int) -> [Conversation] {
        guard count > 0 else { return [] }
        var top: [Conversation] = []
        top.reserveCapacity(count + 1)
        for c in conversations.values {
            if top.count == count, !Self.ranksAbove(c, top[count - 1]) { continue }
            top.insert(c, at: top.firstIndex { Self.ranksAbove(c, $0) } ?? top.count)
            if top.count > count { top.removeLast() }
        }
        return top
    }

    /// 대화 순서: 바이트 → 패킷 → 키 (키가 달라 같은 순위가 없다 — 전체 정렬의 앞부분과 같다)
    static func ranksAbove(_ a: Conversation, _ b: Conversation) -> Bool {
        (a.bytes, a.packets, a.id) > (b.bytes, b.packets, b.id)
    }

    /// 화면용 가벼운 사본: 요약 숫자 · 상위 대화 · 거르고 검색한 행(최근 것이 위, 최대 shown) · 고른 행과 그 대화.
    /// 저장소를 통째로 넘기면 다음 패킷에 행·대화·흐름 버퍼가 전부 복사됐다 (2026-11-02). 먼저 목록을 limit 개로 맞춘다
    public mutating func snapshot(display: CaptureFilter, search: String, shown: Int, topCount: Int = 5, recentDNS: Int = 4,
                                  selectedRow: Int? = nil, selectedConversation: String? = nil) -> CaptureSnapshot {
        trimRows()
        var s = CaptureSnapshot(linkType: linkType)
        s.totalPackets = totalPackets
        s.rowCount = rows.count
        s.top = topConversations(topCount)
        s.issueCounts = issueCounts
        s.unansweredSYN = unansweredSYN
        s.recentDNS = Array(dns.suffix(recentDNS))
        s.lastTime = lastTime
        s.wireguard = wireguard.values.sorted { $0.id < $1.id }
        // 뒤에서부터 한 번 훑는다 — 맞는 행 전체를 배열로 만들지 않고 개수만 센다
        let terms = CaptureRow.searchTerms(search)
        let limit = max(0, shown)
        if display == .all, terms.isEmpty {
            s.visibleCount = rows.count
            s.visible = Array(rows.suffix(limit).reversed())
        } else {
            s.visible.reserveCapacity(min(limit, rows.count))
            for row in rows.reversed() where display.includes(row) && row.matches(terms) {
                s.visibleCount += 1
                if s.visible.count < limit { s.visible.append(row) }
            }
        }
        // 번호는 1씩 늘고 앞에서만 밀려나 자리를 바로 셀 수 있다
        if let id = selectedRow, let first = rows.first?.id, id >= first, id - first < rows.count, rows[id - first].id == id {
            s.selectedRow = rows[id - first]
        }
        s.selectedConversation = selectedConversation.flatMap { conversations[$0] }
        return s
    }

    /// .pcap 저장 — 들고 있는 패킷 (패킷마다 앞 keptBytes 만)
    public func pcapData() -> Data {
        PcapWriter.data(linkType: linkType, snaplen: UInt32(Self.keptBytes), packets: rows.map(\.raw))
    }
}

public enum CaptureFilter: Sendable, Hashable {
    case all
    case conversation(String)
    case issue(TCPIssue)
    case issues
    case dns
    case wireguard

    public func includes(_ row: CaptureRow) -> Bool {
        switch self {
        case .all: return true
        case .conversation(let key): return row.conversation == key
        case .issue(let issue): return row.issue == issue
        case .issues: return row.issue != nil
        case .dns: return row.decoded.dns != nil
        case .wireguard: return row.decoded.wireguard != nil
        }
    }
}

/// 패킷 캡처 창이 읽는 것만 담은 사본 (CaptureStore.snapshot). 판정용 상태(흐름·SYN·DNS 색인·ClientHello 조각)는 담지 않는다
public struct CaptureSnapshot: Sendable, Equatable {
    public var linkType: UInt32
    public var totalPackets = 0
    /// 들고 있는 행 수 (.pcap 저장할 것이 있나)
    public var rowCount = 0
    /// 바이트 많은 순 대화
    public var top: [Conversation] = []
    public var issueCounts: [TCPIssue: Int] = [:]
    public var unansweredSYN = 0
    /// 최근 DNS (오래된 것이 앞)
    public var recentDNS: [DNSTransaction] = []
    public var lastTime: Double?
    /// 상대 끝 순
    public var wireguard: [CaptureWireGuardPeer] = []
    /// 거르고 검색한 행 (최근 것이 위, 최대 shown) · 전체 개수
    public var visible: [CaptureRow] = []
    public var visibleCount = 0
    /// 상세 카드: 고른 행(목록에서 밀려났으면 nil)과 그 대화
    public var selectedRow: CaptureRow?
    public var selectedConversation: Conversation?

    public init(linkType: UInt32 = LinkType.ethernet) { self.linkType = linkType }
}
