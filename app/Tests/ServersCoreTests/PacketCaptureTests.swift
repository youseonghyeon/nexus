import Foundation
@testable import ServersCore
import XCTest

/// 패킷 캡처: pcap 흐름 읽기·쓰기 · 패킷 해석 · 요약(대화·TCP 문제·DNS·WireGuard) · tcpdump 인자.
/// Fixtures/capture-lo0.pcap 은 이 Mac 의 lo0 에서 로컬 통신만 잡은 실제 출력 (2026-11-01, sudo tcpdump -i lo0 -s 256 -w -):
///   HTTP(python http.server :18080) · TLS(openssl s_server :18443, SNI test.example) · UDP(:18053 닫힘 → ICMP) · 닫힌 포트(:18099 → RST)
/// 화면은 snapshot 만 쓴다 — 거르기·검색을 통째로 한 목록은 테스트의 기준값으로만 필요하다 (예전 CaptureStore.rows(matching:))
private extension CaptureStore {
    func rows(matching filter: CaptureFilter, search: String = "") -> [CaptureRow] {
        let terms = CaptureRow.searchTerms(search)
        return rows.filter { filter.includes($0) && $0.matches(terms) }
    }
}

final class PacketCaptureTests: XCTestCase {
    private func fixture() throws -> [UInt8] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/capture-lo0.pcap")
        return [UInt8](try Data(contentsOf: url))
    }

    private func store(_ bytes: [UInt8], chunk: Int? = nil, limit: Int = CaptureStore.defaultLimit) throws -> CaptureStore {
        var reader = PcapReader()
        var packets: [CapturedPacket] = []
        if let chunk {
            var at = 0
            while at < bytes.count {
                packets += try reader.feed(Array(bytes[at..<min(bytes.count, at + chunk)]))
                at += chunk
            }
        } else {
            packets = try reader.feed(bytes)
        }
        var store = CaptureStore(limit: limit)
        store.setLinkType(reader.linkType ?? LinkType.ethernet)
        store.ingest(packets)
        return store
    }

    // MARK: 실제 출력

    func testRealLoopbackCapture() throws {
        let s = try store(try fixture())
        XCTAssertEqual(s.linkType, LinkType.null)
        XCTAssertEqual(s.totalPackets, 38, "tcpdump -r 과 같은 개수")
        let first = s.rows[0].decoded
        XCTAssertEqual(first.proto, "TCP")
        XCTAssertEqual(first.sourceEndpoint, "127.0.0.1:58260")
        XCTAssertEqual(first.destinationEndpoint, "127.0.0.1:18080")
        XCTAssertEqual(first.info, "58260 → 18080 [SYN] Len=0")

        let infos = s.rows.map(\.decoded.info)
        XCTAssertTrue(infos.contains("GET / HTTP/1.1"), infos.joined(separator: "\n"))
        XCTAssertTrue(infos.contains("HTTP/1.0 200 OK"))
        XCTAssertTrue(infos.contains("Client Hello"), "이 픽스처는 256 바이트까지만 잡아 SNI 확장이 잘렸다 (앱은 4096)")
        XCTAssertTrue(infos.contains("Server Hello"))
        XCTAssertTrue(infos.contains("54824 → 18053 Len=47"), "53 이 아닌 포트는 DNS 로 풀지 않는다 (만든 패킷으로 따로 본다)")
        XCTAssertTrue(infos.contains("Destination unreachable (port unreachable) — 127.0.0.1 udp 18053"))

        // 닫힌 포트(18099)는 SYN 에 RST → 거부, 그 밖의 문제 없음
        XCTAssertEqual(s.issueCounts, [.refused: 1])
        let refused = try XCTUnwrap(s.rows.first { $0.issue == .refused })
        XCTAssertEqual(refused.decoded.sourcePort, 18099)

        // 대화: HTTP·TLS 는 SYN → SYN/ACK 시간, TLS 는 SNI 이름표
        let tls = try XCTUnwrap(s.conversations.values.first { $0.b.hasSuffix(":58261") || $0.a.hasSuffix(":18443") })
        XCTAssertEqual(tls.label, "TLS")
        XCTAssertNotNil(tls.handshake)
        XCTAssertLessThan(tls.handshake ?? 1, 0.01)

        XCTAssertEqual(s.dns, [])
    }

    /// 흐름은 아무 데서나 잘려 온다 — 1바이트씩 넣어도 같은 결과
    func testChunkedStreamGivesSameResult() throws {
        let bytes = try fixture()
        let whole = try store(bytes), pieces = try store(bytes, chunk: 1), odd = try store(bytes, chunk: 37)
        XCTAssertEqual(pieces.rows.map(\.decoded), whole.rows.map(\.decoded))
        XCTAssertEqual(odd.rows.map(\.raw), whole.rows.map(\.raw))
    }

    func testNotPcapThrows() {
        var reader = PcapReader()
        XCTAssertThrowsError(try reader.feed(Array("tcpdump: en99: No such device exists\n".utf8))) {
            XCTAssertEqual($0 as? PcapReader.ReadError, .notPcap)
        }
        var empty = PcapReader()
        XCTAssertEqual(try empty.feed([]), [])
    }

    /// .pcap 저장 → 다시 읽기: 시각(µs)·길이·바이트가 같다. 목록은 앞 256 바이트만 들고 있다
    func testPcapRoundTrip() throws {
        let s = try store(try fixture())
        var reader = PcapReader()
        let back = try reader.feed([UInt8](s.pcapData()))
        XCTAssertEqual(reader.linkType, LinkType.null)
        XCTAssertEqual(back.count, s.rows.count)
        for (a, b) in zip(back, s.rows.map(\.raw)) {
            XCTAssertEqual(a.data, b.data)
            XCTAssertEqual(a.originalLength, b.originalLength)
            XCTAssertEqual(a.time, b.time, accuracy: 0.000_001)
        }
        XCTAssertTrue(s.rows.allSatisfy { $0.raw.data.count <= CaptureStore.keptBytes })
    }

    // MARK: 만든 패킷 (BSD loopback · Ethernet)

    private func null(_ ip: [UInt8], v6: Bool = false) -> [UInt8] { [v6 ? 30 : 2, 0, 0, 0] + ip }

    private func ipv4(_ src: [UInt8], _ dst: [UInt8], proto: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let total = 20 + payload.count
        return [0x45, 0, UInt8(total >> 8), UInt8(total & 0xff), 0, 0, 0, 0, 64, proto, 0, 0] + src + dst + payload
    }

    private func tcp(_ sport: UInt16, _ dport: UInt16, seq: UInt32, ack: UInt32 = 0, flags: TCPFlags, window: UInt16 = 65535, payload: [UInt8] = []) -> [UInt8] {
        func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
        func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        return be16(sport) + be16(dport) + be32(seq) + be32(ack) + [0x50, flags.rawValue] + be16(window) + [0, 0, 0, 0] + payload
    }

    private func udp(_ sport: UInt16, _ dport: UInt16, _ payload: [UInt8]) -> [UInt8] {
        let length = UInt16(8 + payload.count)
        return [UInt8(sport >> 8), UInt8(sport & 0xff), UInt8(dport >> 8), UInt8(dport & 0xff), UInt8(length >> 8), UInt8(length & 0xff), 0, 0] + payload
    }

    private let client: [UInt8] = [192, 168, 8, 101], server: [UInt8] = [192, 168, 8, 103]

    private func ingest(_ frames: [(Double, [UInt8])], linkType: UInt32 = LinkType.null, limit: Int = CaptureStore.defaultLimit) -> CaptureStore {
        var s = CaptureStore(limit: limit)
        s.setLinkType(linkType)
        s.ingest(frames.map { CapturedPacket(time: $0.0, originalLength: $0.1.count, data: $0.1) })
        return s
    }

    /// 상태 확인처럼 연결하자마자 닫으면: 클라이언트 FIN 뒤 서버 배너가 오고 클라이언트가 RST → "닫은 뒤 RST" (실패 아님)
    func testResetAfterCloseIsSeparatedFromReset() {
        let s = ingest([
            (0.000, null(ipv4(client, server, proto: 6, tcp(58108, 22, seq: 100, flags: .syn)))),
            (0.001, null(ipv4(server, client, proto: 6, tcp(22, 58108, seq: 500, ack: 101, flags: [.syn, .ack])))),
            (0.002, null(ipv4(client, server, proto: 6, tcp(58108, 22, seq: 101, ack: 501, flags: .ack)))),
            (0.003, null(ipv4(client, server, proto: 6, tcp(58108, 22, seq: 101, ack: 501, flags: [.fin, .ack])))),
            (0.020, null(ipv4(server, client, proto: 6, tcp(22, 58108, seq: 501, ack: 102, flags: [.psh, .ack], payload: Array("SSH-2.0-OpenSSH_9.6p1\r\n".utf8))))),
            (0.021, null(ipv4(client, server, proto: 6, tcp(58108, 22, seq: 102, flags: .rst)))),
            // 다른 연결의 중간 RST
            (1.000, null(ipv4(client, server, proto: 6, tcp(58200, 443, seq: 1, flags: .syn)))),
            (1.001, null(ipv4(server, client, proto: 6, tcp(443, 58200, seq: 9, ack: 2, flags: [.syn, .ack])))),
            (1.100, null(ipv4(server, client, proto: 6, tcp(443, 58200, seq: 10, flags: .rst)))),
        ])
        XCTAssertEqual(s.issueCounts, [.resetAfterClose: 1, .reset: 1])
        XCTAssertEqual(s.rows[4].decoded.proto, "SSH")
        XCTAssertEqual(s.rows[4].decoded.info, "Banner SSH-2.0-OpenSSH_9.6p1")
        XCTAssertEqual(s.conversations.values.first { $0.a.hasSuffix(":22") || $0.b.hasSuffix(":22") }?.handshake ?? 0, 0.001, accuracy: 0.0001)
    }

    /// 같은 범위를 다시 보내면 재전송, keep-alive(1바이트, 이미 보낸 끝-1)는 아님, 새 데이터는 아님. Win=0 은 따로
    func testRetransmissionKeepAliveAndZeroWindow() {
        let data = [UInt8](repeating: 0x41, count: 100)
        let s = ingest([
            (0.0, null(ipv4(client, server, proto: 6, tcp(50000, 8080, seq: 1000, flags: .syn)))),
            (0.1, null(ipv4(client, server, proto: 6, tcp(50000, 8080, seq: 1001, flags: [.psh, .ack], payload: data)))),
            (0.2, null(ipv4(client, server, proto: 6, tcp(50000, 8080, seq: 1101, flags: [.psh, .ack], payload: data)))),
            (0.5, null(ipv4(client, server, proto: 6, tcp(50000, 8080, seq: 1001, flags: [.psh, .ack], payload: data)))),   // 재전송
            (9.0, null(ipv4(client, server, proto: 6, tcp(50000, 8080, seq: 1200, flags: .ack, payload: [0])))),           // keep-alive
            (9.1, null(ipv4(server, client, proto: 6, tcp(8080, 50000, seq: 1, flags: .ack, window: 0)))),                  // Win=0
        ])
        XCTAssertEqual(s.rows.map(\.issue), [nil, nil, nil, .retransmission, nil, .zeroWindow])
        XCTAssertEqual(s.rows[5].decoded.info, "8080 → 50000 [ACK] Win=0 Len=0")
    }

    /// seq 가 2^32 을 넘어 돌아도 새 데이터는 재전송이 아니다
    func testSequenceWrapIsNotRetransmission() {
        let data = [UInt8](repeating: 0, count: 10)
        let s = ingest([
            (0.0, null(ipv4(client, server, proto: 6, tcp(50001, 80, seq: UInt32.max - 4, flags: .syn)))),
            (0.1, null(ipv4(client, server, proto: 6, tcp(50001, 80, seq: UInt32.max - 3, flags: .ack, payload: data)))),
            (0.2, null(ipv4(client, server, proto: 6, tcp(50001, 80, seq: 6, flags: .ack, payload: data)))),
        ])
        XCTAssertEqual(s.issueCounts, [:])
    }

    /// SYN 뒤 3초 넘게 답이 없으면 "응답 없는 SYN" (마지막 패킷 시각 기준)
    func testUnansweredSYN() {
        var frames: [(Double, [UInt8])] = [(0.0, null(ipv4(client, server, proto: 6, tcp(50002, 22, seq: 1, flags: .syn))))]
        XCTAssertEqual(ingest(frames).unansweredSYN, 0)
        frames.append((2.0, null(ipv4(client, server, proto: 17, udp(5000, 6000, [1])))))
        XCTAssertEqual(ingest(frames).unansweredSYN, 0, "아직 3초 안")
        frames.append((3.5, null(ipv4(client, server, proto: 17, udp(5000, 6000, [1])))))
        XCTAssertEqual(ingest(frames).unansweredSYN, 1)
    }

    /// DNS: 질의·응답 짝(같은 클라이언트 끝 + id) → 걸린 시간·답. NXDOMAIN, 압축 포인터
    func testDNSTransactions() {
        // 질의 id 0x1234 "example.com" A
        let question: [UInt8] = [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0, 0, 1, 0, 1]
        let query: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0] + question
        // 응답: 이름은 압축 포인터(0xc00c) · A 93.184.216.34 · CNAME 은 없음
        let answer: [UInt8] = [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 93, 184, 216, 34]
        let response: [UInt8] = [0x12, 0x34, 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0] + question + answer
        let nx: [UInt8] = [0x55, 0x66, 0x81, 0x83, 0, 1, 0, 0, 0, 0, 0, 0] + question
        let nxQuery: [UInt8] = [0x55, 0x66, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0] + question
        let dnsServer: [UInt8] = [10, 1, 0, 1]
        let s = ingest([
            (1.000, null(ipv4(client, dnsServer, proto: 17, udp(53000, 53, query)))),
            (1.012, null(ipv4(dnsServer, client, proto: 17, udp(53, 53000, response)))),
            (2.000, null(ipv4(client, dnsServer, proto: 17, udp(53001, 53, nxQuery)))),
            (2.030, null(ipv4(dnsServer, client, proto: 17, udp(53, 53001, nx)))),
        ])
        XCTAssertEqual(s.rows.map(\.decoded.info), ["Query A example.com", "Response A example.com → 93.184.216.34",
                                                    "Query A example.com", "Response NXDOMAIN example.com"])
        XCTAssertEqual(s.dns.count, 2)
        XCTAssertEqual(s.dns[0].answers, ["93.184.216.34"])
        XCTAssertEqual(s.dns[0].latency ?? 0, 0.012, accuracy: 0.0001)
        XCTAssertEqual(s.dns[1].rcode, 3)
        XCTAssertEqual(s.dns[0].server, "10.1.0.1")
    }

    /// 압축 포인터가 자기 자신을 가리키는 깨진 DNS 는 멈추지 않고 DNS 가 아닌 것으로
    func testDNSPointerLoopDoesNotHang() {
        let bad: [UInt8] = [0, 1, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0, 0xc0, 0x0c, 0, 1, 0, 1]
        let s = ingest([(0, null(ipv4(client, [10, 1, 0, 1], proto: 17, udp(5353, 53, bad))))])
        XCTAssertEqual(s.rows[0].decoded.proto, "UDP")
    }

    /// WireGuard: 핸드셰이크는 길이로(포트 무관), 데이터는 51820 일 때만 · counter 는 리틀엔디언 · 상대 끝별 마지막 핸드셰이크
    func testWireGuard() {
        let peer: [UInt8] = [192, 0, 2, 143]
        let initiation = [1, 0, 0, 0] + [UInt8](repeating: 7, count: 144)
        let response = [2, 0, 0, 0] + [UInt8](repeating: 7, count: 88)
        let data = [4, 0, 0, 0, 0xfb, 0xe8, 0x4e, 0x0c, 0x69, 0x01, 0, 0, 0, 0, 0, 0] + [UInt8](repeating: 9, count: 48)
        let s = ingest([
            (10.0, null(ipv4(client, peer, proto: 17, udp(52786, 51820, initiation)))),
            (10.03, null(ipv4(peer, client, proto: 17, udp(51820, 52786, response)))),
            (10.05, null(ipv4(client, peer, proto: 17, udp(52786, 51820, data)))),
            (10.06, null(ipv4(client, peer, proto: 17, udp(52786, 40000, data)))),   // 51820 아님 → UDP 그대로
        ])
        XCTAssertEqual(s.rows.map(\.decoded.proto), ["WireGuard", "WireGuard", "WireGuard", "UDP"])
        XCTAssertEqual(s.rows[2].decoded.wireguard, .data(counter: 361))
        XCTAssertEqual(s.rows[2].decoded.info, "Transport Data · counter=361 · Len=64")
        let state = s.wireguard["192.0.2.143:51820"]
        XCTAssertEqual(state?.handshakes, 2)
        XCTAssertEqual(state?.lastHandshake ?? 0, 10.03, accuracy: 0.0001)
        XCTAssertEqual(state?.dataPackets, 1)
        XCTAssertEqual(s.conversations["UDP|192.0.2.143:51820|192.168.8.101:52786"]?.label, "WireGuard")
        XCTAssertNil(s.conversations["UDP|192.0.2.143:40000|192.168.8.101:52786"]?.label)
    }

    /// Ethernet(+VLAN) · ARP · IPv6(확장 머리·주소 줄임) · ICMP
    func testEthernetVLANARPAndIPv6() {
        let macs: [UInt8] = [0x60, 0x15, 0x6f, 0x8d, 0xcb, 0xd9, 0x94, 0x83, 0xc4, 0xe0, 0x24, 0x64]
        let echo = ipv4(client, [1, 1, 1, 1], proto: 1, [8, 0, 0, 0, 0, 1, 0, 1])
        let vlan = macs + [0x81, 0x00, 0x00, 0x0a, 0x08, 0x00] + echo
        let arp: [UInt8] = macs + [0x08, 0x06, 0, 1, 0x08, 0x00, 6, 4, 0, 1] + Array(macs[6..<12]) + [192, 168, 8, 1]
            + [0, 0, 0, 0, 0, 0] + [192, 168, 8, 101]
        // IPv6: fd00::2 → fd00::1, hop-by-hop(8바이트) 뒤 UDP
        var v6: [UInt8] = [0x60, 0, 0, 0, 0, 17, 0, 64]
        v6 += [0xfd, 0] + [UInt8](repeating: 0, count: 13) + [2]
        v6 += [0xfd, 0] + [UInt8](repeating: 0, count: 13) + [1]
        v6[6] = 0   // 다음 머리: hop-by-hop
        v6 += [17, 0, 0, 0, 0, 0, 0, 0] + udp(1000, 2000, [9])
        let s = ingest([(0, vlan), (1, arp), (2, macs + [0x86, 0xdd] + v6)], linkType: LinkType.ethernet)
        XCTAssertEqual(s.rows[0].decoded.info, "Echo request")
        XCTAssertEqual(s.rows[0].decoded.destination, "1.1.1.1")
        XCTAssertEqual(s.rows[1].decoded.info, "Who has 192.168.8.101? Tell 192.168.8.1")
        XCTAssertEqual(s.rows[2].decoded.sourceEndpoint, "[fd00::2]:1000")
        XCTAssertEqual(s.rows[2].decoded.proto, "UDP")
    }

    /// 잘린·이상한 패킷에서 죽지 않는다
    func testTruncatedPacketsDoNotCrash() {
        for length in 0..<60 {
            let bytes = Array(null(ipv4(client, server, proto: 6, tcp(1, 2, seq: 1, flags: .syn, payload: [0x16, 0x03, 0x01, 0, 5, 1, 0, 0, 1, 0]))).prefix(length))
            _ = PacketDecoder.decode(bytes, linkType: LinkType.null)
            _ = PacketDecoder.decode(bytes, linkType: LinkType.ethernet)
            _ = PacketDecoder.decode(bytes, linkType: LinkType.rawIP)
        }
        XCTAssertEqual(PacketDecoder.decode([], linkType: 999).info, "링크 종류 999")
    }

    /// Fixtures/tls-clienthello.bin: python ssl(OpenSSL 4.1, 2026-11-01)이 네트워크 없이 만든 실제 ClientHello — 1549 바이트, SNI 가 맨 끝.
    /// 한 조각(lo0·utun)이면 바로, 망 MSS(1448)로 두 조각이면 이어 붙여 SNI 를 찾는다
    func testTLSClientHelloSNIWholeAndSplit() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/tls-clienthello.bin")
        let hello = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(hello.count, 1549)
        let whole = ingest([
            (0.0, null(ipv4(client, server, proto: 6, tcp(50443, 443, seq: 1, flags: .syn)))),
            (0.1, null(ipv4(client, server, proto: 6, tcp(50443, 443, seq: 2, flags: [.psh, .ack], payload: hello)))),
        ])
        XCTAssertEqual(whole.rows[1].decoded.info, "Client Hello · SNI test.example")
        XCTAssertEqual(whole.topConversations(1).first?.label, "TLS test.example")

        let split = ingest([
            (0.0, null(ipv4(client, server, proto: 6, tcp(50444, 443, seq: 1, flags: .syn)))),
            (0.1, null(ipv4(client, server, proto: 6, tcp(50444, 443, seq: 2, flags: .ack, payload: Array(hello[..<1448]))))),
            (0.1, null(ipv4(server, client, proto: 6, tcp(443, 50444, seq: 1, flags: .ack)))),   // 반대 방향은 상관없다
            (0.1, null(ipv4(client, server, proto: 6, tcp(50444, 443, seq: 1450, flags: [.psh, .ack], payload: Array(hello[1448...]))))),
        ])
        XCTAssertEqual(split.rows[1].decoded.info, "Client Hello")
        XCTAssertEqual(split.rows[3].decoded.info, "Client Hello (이어짐) · SNI test.example")
        XCTAssertEqual(split.topConversations(1).first?.label, "TLS test.example")
        XCTAssertEqual(split.issueCounts, [:])
    }

    // MARK: 저장소

    /// 목록은 limit 개까지, 밀려난 수는 dropped. 요약 숫자는 전부 센다. 초기화는 비우되 링크 종류는 남긴다
    func testRingLimitAndReset() {
        let frames = (0..<8).map { (Double($0), null(ipv4(client, server, proto: 17, udp(1000, 2000, [UInt8($0)])))) }
        var s = ingest(frames, limit: 5)
        XCTAssertEqual(s.rows.count, 5)
        XCTAssertEqual(s.rows.first?.id, 4)
        XCTAssertEqual(s.dropped, 3)
        XCTAssertEqual(s.totalPackets, 8)
        XCTAssertEqual(s.topConversations(10).first?.packets, 8)
        s.reset()
        XCTAssertEqual(s.rows.count, 0)
        XCTAssertEqual(s.totalPackets, 0)
        XCTAssertEqual(s.linkType, LinkType.null)
        s.ingest([CapturedPacket(time: 9, originalLength: 30, data: null(ipv4(client, server, proto: 17, udp(1, 2, []))))])
        XCTAssertEqual(s.rows.first?.id, 1, "번호도 다시 1부터")
    }

    func testFilters() {
        let s = ingest([
            (0.0, null(ipv4(client, server, proto: 6, tcp(1, 2, seq: 1, flags: .syn)))),
            (0.1, null(ipv4(server, client, proto: 6, tcp(2, 1, seq: 0, ack: 2, flags: [.rst, .ack])))),
            (0.2, null(ipv4(client, server, proto: 17, udp(1000, 2000, [1])))),
        ])
        XCTAssertEqual(s.rows(matching: .all).count, 3)
        XCTAssertEqual(s.rows(matching: .issues).map(\.id), [2])
        XCTAssertEqual(s.rows(matching: .issue(.refused)).map(\.id), [2])
        XCTAssertEqual(s.rows(matching: .conversation(s.rows[2].conversation)).map(\.id), [3])
        XCTAssertEqual(s.rows(matching: .dns), [])
    }

    // MARK: 리뷰 반영 · 상세 · 검색 (2026-11-01)

    /// Seq·Ack 는 연결 기준 상대값 (SYN 이 0, 첫 데이터 1). 시작을 못 본 연결은 그 방향 첫 패킷이 0
    func testRelativeSequenceNumbers() {
        let s = ingest([
            (0.0, null(ipv4(client, server, proto: 6, tcp(50010, 80, seq: 1000, flags: .syn)))),
            (0.1, null(ipv4(server, client, proto: 6, tcp(80, 50010, seq: 9000, ack: 1001, flags: [.syn, .ack])))),
            (0.2, null(ipv4(client, server, proto: 6, tcp(50010, 80, seq: 1001, ack: 9001, flags: .ack, payload: [1, 2, 3])))),
            (0.3, null(ipv4(client, server, proto: 6, tcp(60000, 443, seq: 777, ack: 5, flags: .ack, payload: [1])))),
        ])
        XCTAssertEqual(s.rows.map(\.relativeSeq), [0, 0, 1, 0])
        XCTAssertEqual(s.rows.map(\.relativeAck), [nil, 1, 1, nil], "SYN 은 ACK 없음 · 반대 방향 기준을 모르면 nil")
    }

    /// mDNS 는 응답이 멀티캐스트라 짝이 안 맞는다 — 목록엔 보이되 DNS 요약에선 뺀다 (리뷰 #5)
    func testMDNSNotInDNSSummary() {
        let question: [UInt8] = [5] + Array("_http".utf8) + [4] + Array("_tcp".utf8) + [5] + Array("local".utf8) + [0, 0, 12, 0, 1]
        let query: [UInt8] = [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0] + question
        let s = ingest([(0, null(ipv4(client, [224, 0, 0, 251], proto: 17, udp(5353, 5353, query))))])
        XCTAssertEqual(s.rows.first?.decoded.proto, "mDNS")
        XCTAssertEqual(s.rows.first?.decoded.info, "Query PTR _http._tcp.local")
        XCTAssertEqual(s.dns, [])
    }

    /// IP 가 아닌 프레임: 출발·목적은 MAC, 아는 EtherType 은 이름 (0x8899 Realtek), 대화 이름표도 그 이름
    func testNonIPEthernetFrames() {
        let dst: [UInt8] = [0xff, 0xff, 0xff, 0xff, 0xff, 0xff], src: [UInt8] = [0x60, 0x15, 0x6f, 0xa4, 0xb1, 0xd9]
        let s = ingest([
            (0, dst + src + [0x88, 0x99] + [UInt8](repeating: 0, count: 46)),
            (1, dst + src + [0x12, 0x34] + [UInt8](repeating: 0, count: 46)),
            (2, dst + src + [0x00, 0x26] + [UInt8](repeating: 0, count: 46)),
        ], linkType: LinkType.ethernet)
        XCTAssertEqual(s.rows.map(\.decoded.proto), ["Realtek", "Ethernet", "LLC"])
        XCTAssertEqual(s.rows[0].decoded.info, "Realtek · EtherType 0x8899")
        XCTAssertEqual(s.rows[1].decoded.info, "EtherType 0x1234")
        XCTAssertEqual(s.rows[0].decoded.source, "60:15:6f:a4:b1:d9")
        XCTAssertEqual(s.rows[0].decoded.destination, "ff:ff:ff:ff:ff:ff")
        XCTAssertEqual(s.conversations[s.rows[0].conversation]?.label, "Realtek")
        // IP 프레임에도 MAC 은 남는다 (상세·검색용)
        let ip = ingest([(0, dst + src + [0x08, 0x00] + ipv4(client, server, proto: 17, udp(1, 2, [0])))], linkType: LinkType.ethernet)
        XCTAssertEqual(ip.rows[0].decoded.sourceMAC, "60:15:6f:a4:b1:d9")
        XCTAssertEqual(ip.rows[0].decoded.source, "192.168.8.101")
    }

    /// 목록은 limit 의 1/4 이 넘칠 때만 자르고(매 묶음마다 2만 개를 옮기지 않게), 화면에 넘길 때는 limit 로 맞춘다 (리뷰 #3)
    func testTrimIsBatchedAndDisplayIsExact() {
        var s = CaptureStore(limit: 8)
        s.setLinkType(LinkType.null)
        func packet(_ i: Int) -> CapturedPacket { CapturedPacket(time: Double(i), originalLength: 30, data: null(ipv4(client, server, proto: 17, udp(1, 2, [UInt8(i)])))) }
        s.ingest((0..<9).map(packet))
        XCTAssertEqual(s.rows.count, 9, "8 + 1/4(2) 안이면 그대로")
        s.ingest((9..<11).map(packet))
        XCTAssertEqual(s.rows.count, 8, "10 을 넘으면 한꺼번에")
        XCTAssertEqual(s.dropped, 3)
        s.ingest([packet(11)])
        let shown = s.snapshot(display: .all, search: "", shown: 100)
        XCTAssertEqual(s.rows.count, 8)
        XCTAssertEqual(s.rows.first?.id, 5)
        XCTAssertEqual(s.dropped, 4)
        XCTAssertEqual(shown.rowCount, 8)
        XCTAssertEqual(shown.top.first?.packets, 12, "상위 대화는 화면에 넘길 때 계산")
    }

    /// 대화는 상한을 넘으면 오래 조용한 것부터 버린다 (리뷰 #4)
    func testConversationLimit() {
        var s = CaptureStore()
        s.setLinkType(LinkType.null)
        let count = CaptureStore.conversationLimit + 10
        s.ingest((0..<count).map { i in
            CapturedPacket(time: Double(i), originalLength: 30, data: null(ipv4(client, server, proto: 17, udp(UInt16(1024 + i % 60000), UInt16(1 + i / 60000), [0]))))
        })
        XCTAssertLessThanOrEqual(s.conversations.count, CaptureStore.conversationLimit)
        XCTAssertNotNil(s.conversations[s.rows.last!.conversation], "최근 대화는 남는다")
        XCTAssertEqual(s.totalPackets, count)
    }

    /// 검색: 낱말이 모두 들어 있어야, 대소문자 무시, 포트·프로토콜·Info·문제 이름 (제조사는 testSearchTextPrecomputedWithVendor)
    func testSearch() {
        let s = ingest([
            (0.0, null(ipv4(client, [199, 232, 193, 91], proto: 6, tcp(57241, 443, seq: 1, flags: .syn)))),
            (0.1, null(ipv4([199, 232, 193, 91], client, proto: 6, tcp(443, 57241, seq: 0, ack: 2, flags: [.rst, .ack])))),
            (0.2, null(ipv4(client, server, proto: 17, udp(5000, 53, [0])))),
        ])
        XCTAssertEqual(s.rows(matching: .all, search: "199.232").map(\.id), [1, 2])
        XCTAssertEqual(s.rows(matching: .all, search: "tcp 443 rst").map(\.id), [2])
        XCTAssertEqual(s.rows(matching: .all, search: "거부").map(\.id), [2])
        XCTAssertEqual(s.rows(matching: .all, search: "  ").count, 3)
        XCTAssertEqual(s.rows(matching: .all, search: "realtek").count, 0)
        XCTAssertEqual(s.rows(matching: .issues, search: "199").map(\.id), [2], "요약 거르기와 함께")
    }

    /// 상세: IPv4·TCP 필드와 옵션(MSS·WS·SACK·TS), 상대 Seq, 문제 설명, 앞 256 바이트만 있음 표시
    func testPacketDetails() throws {
        // TCP 머리 40 바이트: 옵션 MSS 1460 · NOP · WS 6 · SACK 허용 · TS
        func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
        var tcpHeader: [UInt8] = be16(58108) + be16(22) + [0, 0, 0, 100] + [0, 0, 0, 0] + [0xa0, TCPFlags.syn.rawValue] + be16(65535) + [0, 0, 0, 0]
        tcpHeader += [2, 4, 0x05, 0xb4, 1, 3, 3, 6, 4, 2, 8, 10, 0, 0, 0, 7, 0, 0, 0, 0]
        var ipHeader = ipv4(client, server, proto: 6, tcpHeader)
        ipHeader[6] = 0x40   // DF
        let s = ingest([(0, null(ipHeader)),
                        (1, null(ipv4(server, client, proto: 6, tcp(22, 58108, seq: 0, ack: 101, flags: [.rst, .ack]))))])
        let sections = PacketDetails.sections(s.rows[0], linkType: LinkType.null)
        XCTAssertEqual(sections.map(\.title), ["Frame", "IPv4", "TCP"])
        let ip = sections[1].lines, tcp = sections[2].lines
        XCTAssertTrue(ip.contains(DetailLine("Source → Destination", "192.168.8.101 → 192.168.8.103")))
        XCTAssertTrue(ip.contains(DetailLine("Flags", "DF")))
        XCTAssertTrue(tcp.contains(DetailLine("Seq", "0 (relative) · 100")))
        XCTAssertTrue(tcp.contains(DetailLine("Options", "MSS 1460 · WS ×64 · SACK permitted · TS 7")), tcp.map(\.value).joined(separator: "\n"))
        let refused = PacketDetails.sections(s.rows[1], linkType: LinkType.null)
        XCTAssertEqual(refused.last?.title, "Issues")
        XCTAssertEqual(refused.last?.lines.first?.name, "거부")

        // 앞 256 바이트만 들고 있는 큰 패킷
        let big = ingest([(0, null(ipv4(client, server, proto: 17, udp(1, 2, [UInt8](repeating: 0, count: 1000)))))])
        XCTAssertEqual(PacketDetails.sections(big.rows[0], linkType: LinkType.null).first?.lines.last?.value, "1032 bytes (앞 256 bytes 만 들고 있음)")
    }

    /// 상세는 잘린·이상한 바이트에서도 죽지 않는다 (옵션 길이 0·넘침 포함)
    func testPacketDetailsTruncated() {
        let base = null(ipv4(client, server, proto: 6, tcp(1, 2, seq: 1, flags: .syn) ))
        var weird = base
        weird[4 + 20 + 12] = 0xf0   // TCP 머리 60 이라고 주장
        for bytes in (0..<base.count).map({ Array(base.prefix($0)) }) + [weird, weird + [2, 0, 3]] {
            let row = CaptureRow(id: 1, raw: CapturedPacket(time: 0, originalLength: bytes.count, data: bytes),
                                 decoded: PacketDecoder.decode(bytes, linkType: LinkType.null), conversation: "", issue: nil)
            _ = PacketDetails.sections(row, linkType: LinkType.null)
            _ = PacketDetails.sections(row, linkType: LinkType.ethernet)
        }
        XCTAssertEqual(PacketDetails.tcpOptions(Bytes([2, 0, 3, 3, 6]), from: 0, to: 5), [], "길이 0 옵션은 멈춘다")
    }

    /// 조각을 놓쳐 seq 가 안 맞으면 붙이지 않는다 — 무관한 조각으로 엉뚱한 SNI 를 만들지 않게 (Fable 리뷰 #7)
    func testClientHelloJoinRequiresExpectedSeq() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/tls-clienthello.bin")
        let hello = [UInt8](try Data(contentsOf: url))
        let s = ingest([
            (0.0, null(ipv4(client, server, proto: 6, tcp(50445, 443, seq: 1, flags: .syn)))),
            (0.1, null(ipv4(client, server, proto: 6, tcp(50445, 443, seq: 2, flags: .ack, payload: Array(hello[..<1448]))))),
            (0.2, null(ipv4(client, server, proto: 6, tcp(50445, 443, seq: 3000, flags: [.psh, .ack], payload: Array(hello[1448...]))))),   // 사이 조각 유실
        ])
        XCTAssertNil(s.rows[2].decoded.tlsServerName)
        XCTAssertEqual(s.topConversations(1).first?.label, "TLS")
    }

    /// 상세 시각: 24시간 꼴 마이크로초, 오늘이 아니면 날짜를 앞에
    func testDetailTimeText() {
        let now = Date()
        let time = now.timeIntervalSince1970.rounded(.down) + 0.696123
        let today = PacketDetails.timeText(time, now: now)
        XCTAssertTrue(today.hasSuffix(".696123"), today)
        XCTAssertEqual(today.count, 15, "HH:mm:ss.SSSSSS")
        let yesterday = PacketDetails.timeText(time - 86_400 * 2, now: now)
        XCTAssertTrue(yesterday.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{6}$"#, options: .regularExpression) != nil, yesterday)
    }

    /// 검색용 글자는 받을 때 만든다 (제조사 포함) — 매번 잇지 않는다 (Fable 리뷰 #2)
    func testSearchTextPrecomputedWithVendor() {
        var s = CaptureStore()
        s.setLinkType(LinkType.ethernet)
        s.vendorLookup = { $0.hasPrefix("60:15:6f") ? "TP-Link Systems Inc." : nil }
        let frame: [UInt8] = [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x60, 0x15, 0x6f, 0x8d, 0xcb, 0xd9, 0x88, 0x99] + [UInt8](repeating: 0, count: 46)
        s.ingest([CapturedPacket(time: 0, originalLength: frame.count, data: frame)])
        XCTAssertTrue(s.rows[0].searchText.contains("tp-link"))
        XCTAssertEqual(s.rows(matching: .all, search: "TP-LINK realtek").count, 1)
        s.reset()
        XCTAssertNotNil(s.vendorLookup, "초기화해도 제조사 표는 남는다")
    }

    // MARK: 화면 사본 · 해석 비용 (2026-11-02)

    /// 옛 화면이 저장소 통째에서 읽던 값 (요약 · 상위 대화 전체 정렬 · 걸러 뒤집은 목록)
    private func oldView(_ s: CaptureStore, _ display: CaptureFilter, _ search: String, shown: Int)
        -> (top: [Conversation], dns: [DNSTransaction], wireguard: [CaptureWireGuardPeer], visible: [CaptureRow], count: Int) {
        let matched = s.rows(matching: display, search: search)
        return (Array(s.conversations.values.sorted { ($0.bytes, $0.packets, $0.id) > ($1.bytes, $1.packets, $1.id) }.prefix(5)),
                Array(s.dns.suffix(4)), s.wireguard.values.sorted { $0.id < $1.id },
                Array(matched.suffix(shown).reversed()), matched.count)
    }

    /// 실제 lo0 출력 + DNS 6건 · WireGuard · 바이트·패킷이 같은 대화 여럿 → 사본이 옛 화면 값과 같다 (거르기·검색·자르기 조합)
    func testSnapshotMatchesOldStoreView() throws {
        var reader = PcapReader()
        let real = try reader.feed(try fixture())
        var s = CaptureStore(limit: 40)
        s.setLinkType(LinkType.null)
        s.ingest(real)
        let dnsServer: [UInt8] = [10, 1, 0, 1]
        let question: [UInt8] = [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0, 0, 1, 0, 1]
        var frames: [(Double, [UInt8])] = []
        for i in 0..<6 {
            let query: [UInt8] = [0x10, UInt8(i), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0] + question
            frames.append((100 + Double(i), null(ipv4(client, dnsServer, proto: 17, udp(UInt16(53100 + i), 53, query)))))
        }
        // 같은 바이트·패킷의 대화 셋 (순위는 키로 갈린다) + 더 큰 대화 하나
        for port in [7003, 7001, 7002] { frames.append((110, null(ipv4(client, server, proto: 17, udp(UInt16(port), 9000, [UInt8](repeating: 1, count: 6000)))))) }
        frames.append((111, null(ipv4(client, server, proto: 17, udp(7100, 9000, [UInt8](repeating: 1, count: 9000))))))
        let initiation = [1, 0, 0, 0] + [UInt8](repeating: 7, count: 144)
        frames.append((112, null(ipv4(client, [192, 0, 2, 143], proto: 17, udp(52786, 51820, initiation)))))
        frames.append((113, null(ipv4(client, [1, 1, 1, 1], proto: 17, udp(52787, 51820, initiation)))))
        frames.append((114, null(ipv4(client, server, proto: 6, tcp(50002, 22, seq: 1, flags: .syn)))))
        frames.append((120, null(ipv4(client, server, proto: 17, udp(5000, 6000, [1])))))
        s.ingest(frames.map { CapturedPacket(time: $0.0, originalLength: $0.1.count, data: $0.1) })

        let tie = try XCTUnwrap(s.rows.last { $0.decoded.destinationPort == 9000 }).conversation
        let cases: [(CaptureFilter, String, Int)] = [(.all, "", 5_000), (.all, "", 7), (.issues, "", 5_000), (.dns, "", 3),
                                                    (.all, "udp 9000", 5_000), (.conversation(tie), "", 5_000), (.wireguard, "192.0", 5_000),
                                                    (.dns, "없는낱말", 5_000), (.all, "", 0)]
        for (display, search, shown) in cases {
            var copy = s
            let snap = copy.snapshot(display: display, search: search, shown: shown)
            copy.trimRows()
            let old = oldView(copy, display, search, shown: shown)
            let label = "\(display) '\(search)' \(shown)"
            XCTAssertEqual(snap.visible, old.visible, label)
            XCTAssertEqual(snap.visibleCount, old.count, label)
            XCTAssertEqual(snap.top, old.top, label)
            XCTAssertEqual(snap.recentDNS, old.dns, label)
            XCTAssertEqual(snap.wireguard, old.wireguard, label)
            XCTAssertEqual(snap.issueCounts, copy.issueCounts, label)
            XCTAssertEqual(snap.unansweredSYN, copy.unansweredSYN, label)
            XCTAssertEqual(snap.totalPackets, copy.totalPackets, label)
            XCTAssertEqual(snap.rowCount, copy.rows.count, label)
            XCTAssertEqual(snap.lastTime, copy.lastTime, label)
            XCTAssertEqual(snap.linkType, LinkType.null, label)
        }
        // 비교한 값이 실제로 찼는지 (빈 것끼리 같아서 통과하지 않게)
        let full = s.snapshot(display: .all, search: "", shown: 5_000)
        XCTAssertEqual(full.rowCount, 40)
        XCTAssertEqual(full.visible.first?.id, s.rows.last?.id, "최근 것이 위")
        XCTAssertEqual(full.recentDNS.count, 4)
        XCTAssertEqual(full.wireguard.map(\.id), ["1.1.1.1:51820", "192.0.2.143:51820"])
        XCTAssertEqual(full.unansweredSYN, 1)
        XCTAssertEqual(full.issueCounts, [.refused: 1])
        XCTAssertEqual(full.top.count, 5)
        XCTAssertEqual(full.top.first?.id, "UDP|192.168.8.101:7100|192.168.8.103:9000")
        XCTAssertEqual(full.top[1...3].map(\.id), ["UDP|192.168.8.101:7003|192.168.8.103:9000", "UDP|192.168.8.101:7002|192.168.8.103:9000",
                                                  "UDP|192.168.8.101:7001|192.168.8.103:9000"], "같은 바이트·패킷은 키 역순 (전체 정렬과 같게)")
        XCTAssertEqual(s.snapshot(display: .all, search: "udp 9000", shown: 2).visibleCount, 4, "그리는 건 2개여도 개수는 전부")
        XCTAssertEqual(s.snapshot(display: .dns, search: "", shown: 3).visible.count, 3)
    }

    /// 상세 카드: 고른 행(번호로 바로 찾음)과 그 대화 — 목록에서 밀려난 행은 nil, 대화는 남아 있으면 준다
    func testSnapshotSelection() {
        let frames = (0..<8).map { (Double($0), null(ipv4(client, server, proto: 17, udp(1000, 2000, [UInt8($0)])))) }
        var s = ingest(frames, limit: 5)
        let key = s.rows[0].conversation
        let picked = s.snapshot(display: .all, search: "", shown: 10, selectedRow: 6, selectedConversation: key)
        XCTAssertEqual(picked.selectedRow?.id, 6)
        XCTAssertEqual(picked.selectedRow, s.rows.first { $0.id == 6 })
        XCTAssertEqual(picked.selectedConversation, s.conversations[key])
        XCTAssertEqual(picked.selectedConversation?.packets, 8)
        let gone = s.snapshot(display: .all, search: "", shown: 10, selectedRow: 2, selectedConversation: "UDP|없음|없음")
        XCTAssertNil(gone.selectedRow, "밀려난 행")
        XCTAssertNil(gone.selectedConversation)
        XCTAssertNil(s.snapshot(display: .all, search: "", shown: 10, selectedRow: 99).selectedRow)
        XCTAssertNil(s.snapshot(display: .all, search: "", shown: 10).selectedConversation)
    }

    /// 상위 N 한 번 훑기 = 전체 정렬의 앞부분 (바이트·패킷이 같은 것이 많을 때도, N 이 대화 수보다 클 때도)
    func testTopConversationsEqualsSortedPrefix() {
        var s = CaptureStore()
        s.setLinkType(LinkType.null)
        var packets: [CapturedPacket] = []
        for i in 0..<60 {
            // 바이트는 네 갈래(같은 것이 많다), 패킷 수는 두 갈래
            let size = [10, 40, 40, 90][i % 4]
            for _ in 0..<(1 + i % 2) {
                let frame = null(ipv4(client, server, proto: 17, udp(UInt16(3000 + i), 53000, [UInt8](repeating: 0, count: size))))
                packets.append(CapturedPacket(time: Double(i), originalLength: frame.count, data: frame))
            }
        }
        s.ingest(packets)
        let sorted = s.conversations.values.sorted { ($0.bytes, $0.packets, $0.id) > ($1.bytes, $1.packets, $1.id) }
        XCTAssertEqual(sorted.count, 60)
        for n in [0, 1, 2, 5, 15, 59, 60, 61, 100] {
            XCTAssertEqual(s.topConversations(n), Array(sorted.prefix(n)), "N=\(n)")
        }
        XCTAssertEqual(CaptureStore().topConversations(5), [])
    }

    /// ClientHello 세 조각 + 사이에 다른 흐름의 TCP·같은 흐름의 빈 ACK → 이어 붙여 SNI. 다른 흐름은 그대로
    func testClientHelloSNIAcrossThreeSegmentsWithInterleaving() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/tls-clienthello.bin")
        let hello = [UInt8](try Data(contentsOf: url))
        let other: [UInt8] = [10, 0, 0, 9]
        let s = ingest([
            (0.0, null(ipv4(client, server, proto: 6, tcp(50446, 443, seq: 1, flags: .syn)))),
            (0.05, null(ipv4(client, other, proto: 6, tcp(50500, 5555, seq: 10, flags: .ack, payload: [1, 2, 3])))),   // 기다리는 조각 없음
            (0.1, null(ipv4(client, server, proto: 6, tcp(50446, 443, seq: 2, flags: .ack, payload: Array(hello[..<600]))))),
            (0.15, null(ipv4(client, other, proto: 6, tcp(50500, 5555, seq: 13, flags: .ack, payload: [4, 5])))),     // 다른 흐름
            (0.2, null(ipv4(client, server, proto: 6, tcp(50446, 443, seq: 602, flags: .ack, payload: Array(hello[600..<1200]))))),
            (0.25, null(ipv4(client, server, proto: 6, tcp(50446, 443, seq: 1202, flags: .ack)))),                   // 빈 ACK
            (0.3, null(ipv4(client, server, proto: 6, tcp(50446, 443, seq: 1202, flags: [.psh, .ack], payload: Array(hello[1200...]))))),
            (0.4, null(ipv4(client, other, proto: 6, tcp(50500, 5555, seq: 15, flags: .ack, payload: [6])))),
        ])
        XCTAssertEqual(s.rows[2].decoded.info, "Client Hello")
        XCTAssertNil(s.rows[4].decoded.tlsServerName, "아직 모자람")
        XCTAssertEqual(s.rows[6].decoded.info, "Client Hello (이어짐) · SNI test.example")
        XCTAssertEqual(s.rows[6].decoded.proto, "TLS")
        XCTAssertEqual([1, 3, 7].map { s.rows[$0].decoded.proto }, ["TCP", "TCP", "TCP"], "다른 흐름은 건드리지 않는다")
        XCTAssertEqual(s.conversations.values.first { $0.a.hasSuffix(":50446") || $0.b.hasSuffix(":50446") }?.label, "TLS test.example")
        XCTAssertEqual(s.issueCounts, [:])
    }

    /// MAC 글자: 표로 만든 것 = String(format: "%02x") (앞 0 포함, 모든 바이트 값)
    func testMACFormattingMatchesFormatString() {
        func reference(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: ":") }
        for value in 0...255 {
            let bytes: [UInt8] = [UInt8(value), 0, UInt8(255 - value), 0x0a, UInt8(value / 16), UInt8(value % 16)]
            XCTAssertEqual(Bytes(bytes).mac(0), reference(bytes))
        }
        var shifted = Bytes([0xff, 0xff, 0x00, 0x01, 0x02, 0x0a, 0xb0, 0xc3])
        shifted.skip(2)
        XCTAssertEqual(shifted.mac(0), "00:01:02:0a:b0:c3", "건너뛴 시작점 기준")
        XCTAssertEqual(Bytes([0xff, 0, 1, 2, 3, 4, 5]).mac(1), "00:01:02:03:04:05")
    }

    // MARK: 감사 반영 (2026-11-10) — 잘림·길이 과대값 · pcap 변종 · 상세의 응용 계층 · 조각 · 늦은 ClientHello 조각

    private func ipv6(next: UInt8, _ payload: [UInt8]) -> [UInt8] {
        [0x60, 0, 0, 0, UInt8(payload.count >> 8), UInt8(payload.count & 0xff), next, 64]
            + [0xfe, 0x80] + [UInt8](repeating: 0, count: 13) + [1] + [0xff, 0x02] + [UInt8](repeating: 0, count: 13) + [1] + payload
    }

    private func row(_ bytes: [UInt8], linkType: UInt32 = LinkType.null) -> CaptureRow {
        CaptureRow(id: 1, raw: CapturedPacket(time: 0, originalLength: bytes.count, data: bytes),
                   decoded: PacketDecoder.decode(bytes, linkType: linkType), conversation: "", issue: nil)
    }

    /// DNS 응답(압축 포인터) · ClientHello · ICMP unreachable(안쪽 머리) · IPv6 확장 머리 · WireGuard · ARP 를
    /// 아무 데서나 자르고, 바이트 하나씩을 0xff(길이 필드 과대값)로 바꿔도 목록 해석·상세·저장소가 죽지 않는다
    func testTruncatedAndOversizedFieldsDoNotCrash() throws {
        let question: [UInt8] = [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0, 0, 1, 0, 1]
        let dns: [UInt8] = [0x12, 0x34, 0x81, 0x80, 0, 1, 0, 2, 0, 0, 0, 0] + question
            + [0xc0, 0x0c, 0, 5, 0, 1, 0, 0, 0, 60, 0, 2, 0xc0, 0x0c] + [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 93, 184, 216, 34]
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/tls-clienthello.bin")
        let hello = Array([UInt8](try Data(contentsOf: url)).prefix(400))
        let quoted = ipv4(client, server, proto: 17, udp(54824, 18053, [1, 2, 3, 4]))
        let macs: [UInt8] = [0x60, 0x15, 0x6f, 0x8d, 0xcb, 0xd9, 0x94, 0x83, 0xc4, 0xe0, 0x24, 0x64]
        let arp: [UInt8] = macs + [0x08, 0x06, 0, 1, 0x08, 0x00, 6, 4, 0, 2] + Array(macs[6..<12]) + [192, 168, 8, 1] + Array(macs[0..<6]) + [192, 168, 8, 101]
        let wgData = [4, 0, 0, 0, 1, 2, 3, 4, 9, 0, 0, 0, 0, 0, 0, 0] + [UInt8](repeating: 9, count: 16)
        // TCP 머리 40 바이트: MSS 1460 · WS 6 · NOP · TS · NOP 둘
        var tcpOptions = tcp(1, 2, seq: 1, flags: .syn)
        tcpOptions[12] = 0xa0
        tcpOptions += [2, 4, 5, 0xb4, 3, 3, 6, 1, 8, 10, 0, 0, 0, 1, 0, 0, 0, 0, 1, 1]
        let frames: [([UInt8], UInt32)] = [
            (null(ipv4(server, client, proto: 17, udp(53, 53000, dns))), LinkType.null),
            (null(ipv4(server, client, proto: 6, tcp(53, 53000, seq: 1, flags: .ack, payload: [0, UInt8(dns.count)] + dns))), LinkType.null),
            (null(ipv4(client, server, proto: 6, tcp(50443, 443, seq: 2, flags: .ack, payload: hello))), LinkType.null),
            (null(ipv4(server, client, proto: 1, [3, 3, 0, 0, 0, 0, 0, 0] + quoted)), LinkType.null),
            (null(ipv6(next: 0, [44, 0, 0, 0, 0, 0, 0, 0] + [17, 0, 0, 0, 0, 0, 0, 1] + udp(1000, 53, dns)), v6: true), LinkType.null),
            (null(ipv4(client, server, proto: 17, udp(52786, 51820, wgData))), LinkType.null),
            (null(ipv4(client, server, proto: 6, tcpOptions)), LinkType.null),
            (arp, LinkType.ethernet),
            (macs + [0x81, 0x00, 0x00, 0x0a, 0x86, 0xdd] + ipv6(next: 58, [135, 0, 0, 0]), LinkType.ethernet),
            (ipv4(client, server, proto: 17, udp(5353, 5353, dns)), LinkType.rawIP),
        ]
        var checked = 0
        for (frame, linkType) in frames {
            var variants = (0...frame.count).map { Array(frame.prefix($0)) }
            for index in frame.indices { var changed = frame; changed[index] = 0xff; variants.append(changed) }
            var store = CaptureStore()
            store.setLinkType(linkType)
            store.ingest(variants.map { CapturedPacket(time: 0, originalLength: $0.count, data: $0) })
            for other in [LinkType.null, LinkType.loop, LinkType.ethernet, LinkType.rawIP] {
                for bytes in variants { _ = PacketDetails.sections(row(bytes, linkType: other), linkType: other) }
            }
            for stored in store.rows { _ = PacketDetails.sections(stored, linkType: linkType) }
            checked += variants.count
        }
        XCTAssertGreaterThan(checked, 1500)
        // 온전한 것은 제대로 읽힌다 (자르기 전 입력이 엉터리라 통과한 게 아니다)
        XCTAssertEqual(PacketDecoder.decode(frames[0].0, linkType: LinkType.null).info, "Response A example.com → example.com, 93.184.216.34")
        XCTAssertEqual(PacketDecoder.decode(frames[1].0, linkType: LinkType.null).proto, "DNS", "DNS over TCP")
        XCTAssertEqual(PacketDecoder.decode(frames[3].0, linkType: LinkType.null).info, "Destination unreachable (port unreachable) — 192.168.8.103 udp 18053")
        XCTAssertEqual(PacketDecoder.decode(frames[8].0, linkType: LinkType.ethernet).info, "Neighbor solicitation")
        XCTAssertEqual(PacketDetails.sections(row(frames[6].0), linkType: LinkType.null).last?.lines.last, DetailLine("Options", "MSS 1460 · WS ×64 · TS 1"))
    }

    /// pcap 변종: 빅엔디언 · 나노초 매직, 그리고 잡은 길이가 말이 안 되면(깨진 흐름) 끝없이 기다리지 않고 notPcap
    func testPcapBigEndianNanosecondsAndBrokenLength() throws {
        func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        func le(_ v: UInt32) -> [UInt8] { be(v).reversed() }
        /// 전역 머리(버전 2.4 · snaplen 65535) + 레코드 머리 낱말들
        func stream(magic: [UInt8], linkType: UInt32, record: [UInt32], _ order: (UInt32) -> [UInt8]) -> [UInt8] {
            // 버전은 16비트 둘(2 · 4) — 읽는 쪽이 보지 않는 값이라 순서만 맞춰 둔다
            var out = magic + (order(1) == [0, 0, 0, 1] ? [0, 2, 0, 4] : [2, 0, 4, 0])
            let words: [UInt32] = [0, 0, 65535, linkType] + record
            for word in words { out += order(word) }
            return out
        }
        let data: [UInt8] = [1, 2, 3]
        var reader = PcapReader()
        XCTAssertEqual(try reader.feed(stream(magic: [0xa1, 0xb2, 0xc3, 0xd4], linkType: LinkType.rawIP, record: [100, 250_000, 3, 60], be) + data),
                       [CapturedPacket(time: 100.25, originalLength: 60, data: data)])
        XCTAssertEqual(reader.linkType, LinkType.rawIP)

        var nanoReader = PcapReader()
        XCTAssertEqual(try nanoReader.feed(stream(magic: [0x4d, 0x3c, 0xb2, 0xa1], linkType: LinkType.ethernet, record: [100, 500_000_000, 3, 3], le) + data),
                       [CapturedPacket(time: 100.5, originalLength: 3, data: data)])
        var bigNanoReader = PcapReader()
        XCTAssertEqual(try bigNanoReader.feed(stream(magic: [0xa1, 0xb2, 0x3c, 0x4d], linkType: LinkType.null, record: [7, 750_000_000, 0, 0], be)),
                       [CapturedPacket(time: 7.75, originalLength: 0, data: [])])
        XCTAssertEqual(bigNanoReader.linkType, LinkType.null)

        var waiting = PcapReader()
        XCTAssertEqual(try waiting.feed(stream(magic: [0xd4, 0xc3, 0xb2, 0xa1], linkType: LinkType.ethernet, record: [1, 0, 262_144, 262_144], le)), [],
                       "상한까지는 더 올 바이트를 기다린다")
        var tooBig = PcapReader()
        XCTAssertThrowsError(try tooBig.feed(stream(magic: [0xd4, 0xc3, 0xb2, 0xa1], linkType: LinkType.ethernet, record: [1, 0, 262_145, 0], le))) {
            XCTAssertEqual($0 as? PcapReader.ReadError, .notPcap)
        }
    }

    /// 상세의 응용 계층 구역: DNS · WireGuard · TLS(SNI) · HTTP · SSH 배너. 배너 뒤 SSH 암호문은 글자로 풀지 않는다
    func testPacketDetailsApplicationSections() throws {
        let question: [UInt8] = [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0, 0, 1, 0, 1]
        let query: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0] + question
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/tls-clienthello.bin")
        let hello = [UInt8](try Data(contentsOf: url))
        let cipher: [UInt8] = [0x9c, 0x0a, 0xe2, 0x80, 0x0d, 0xff, 0x0a, 0x41, 0xc3, 0x28, 0x0a, 0x99]
        let s = ingest([
            (0, null(ipv4(client, [10, 1, 0, 1], proto: 17, udp(53000, 53, query)))),
            (1, null(ipv4(client, server, proto: 17, udp(52786, 51820, [4, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0] + [UInt8](repeating: 9, count: 16))))),
            (2, null(ipv4(client, server, proto: 6, tcp(50443, 443, seq: 2, flags: [.psh, .ack], payload: hello)))),
            (3, null(ipv4(client, server, proto: 6, tcp(50080, 80, seq: 2, flags: [.psh, .ack], payload: Array("GET /a HTTP/1.1\r\nHost: nexus\r\n\r\n".utf8))))),
            (4, null(ipv4(server, client, proto: 6, tcp(22, 50022, seq: 2, flags: [.psh, .ack], payload: Array("SSH-2.0-OpenSSH_9.6p1\r\n".utf8))))),
            (5, null(ipv4(server, client, proto: 6, tcp(22, 50022, seq: 25, flags: [.psh, .ack], payload: cipher)))),
        ])
        func app(_ index: Int) -> DetailSection? { PacketDetails.sections(s.rows[index], linkType: LinkType.null).last }
        XCTAssertEqual(app(0), DetailSection(title: "DNS", lines: [DetailLine("ID", "0x1234"), DetailLine("Type", "Query"), DetailLine("Question", "A example.com")]))
        XCTAssertEqual(app(1)?.title, "WireGuard")
        XCTAssertEqual(app(1).map { Array($0.lines.prefix(2)) }, [DetailLine("Type", "Transport Data (4)"), DetailLine("Counter", "5")])
        XCTAssertEqual(app(2), DetailSection(title: "TLS", lines: [DetailLine("Record", "Client Hello · SNI test.example"), DetailLine("SNI", "test.example"),
                                                                   DetailLine("Payload", "Encrypted")]))
        XCTAssertEqual(app(3), DetailSection(title: "HTTP", lines: [DetailLine("First line", "GET /a HTTP/1.1"), DetailLine("", "Host: nexus")]))
        XCTAssertEqual(app(4), DetailSection(title: "SSH", lines: [DetailLine("First line", "SSH-2.0-OpenSSH_9.6p1")]))
        XCTAssertEqual(s.rows[5].decoded.info, "Encrypted · Len=12")
        XCTAssertEqual(app(5), DetailSection(title: "SSH", lines: [DetailLine("Payload", "Encrypted")]), "암호문을 줄로 나눠 깨진 글자로 내지 않는다")
        // 바이트로 견주는 판정: 앞부분만 같으면 되고, 모자라거나 한 글자 다르면 아니다
        func proto(_ text: String, port: UInt16 = 9000) -> String {
            PacketDecoder.decode(null(ipv4(client, server, proto: 6, tcp(50000, port, seq: 1, flags: .ack, payload: Array(text.utf8)))), linkType: LinkType.null).proto
        }
        XCTAssertEqual(["GET / HTTP/1.1", "POST /x", "CONNECT a:443", "HTTP/1.1 200 OK", "SSH-2.0-x"].map { proto($0) }, ["HTTP", "HTTP", "HTTP", "HTTP", "SSH"])
        XCTAssertEqual(["GET", "GETX /", "get / ", "HTTP/2 200", "SSH", "XSSH-2.0"].map { proto($0) }, ["TCP", "TCP", "TCP", "TCP", "TCP", "TCP"])
    }

    /// 첫 조각이 아닌 IP 조각은 전송 계층 머리가 없다 — 목록은 "조각", 상세는 IP 구역까지만 (조각 내용을 포트로 읽지 않는다).
    /// loopback 은 머리의 주소 계열로 가른다 — IP 가 아닌 프레임에 IPv4 구역을 지어내지 않는다
    func testFragmentsAndNonIPLoopbackHaveNoTransportSection() {
        var fragment = ipv4(client, server, proto: 17, [UInt8](repeating: 0x41, count: 24))
        fragment[6] = 0x00; fragment[7] = 0xb9   // offset 185 × 8
        let v4 = row(null(fragment))
        XCTAssertEqual(v4.decoded.info, "조각 (offset 1480)")
        XCTAssertEqual(PacketDetails.sections(v4, linkType: LinkType.null).map(\.title), ["Frame", "IPv4"])
        // 첫 조각(offset 0, MF)은 전송 계층까지 그대로
        var first = ipv4(client, server, proto: 17, udp(1000, 2000, [1, 2, 3, 4]))
        first[6] = 0x20
        XCTAssertEqual(PacketDetails.sections(row(null(first)), linkType: LinkType.null).map(\.title), ["Frame", "IPv4", "UDP"])

        // IPv6 fragment 머리: offset 은 앞 13비트
        let later = row(null(ipv6(next: 44, [17, 0, 0x05, 0xc8, 0, 0, 0, 1] + [UInt8](repeating: 0x41, count: 24)), v6: true))
        XCTAssertEqual(later.decoded.proto, "IPv6")
        XCTAssertEqual(later.decoded.info, "조각 (offset 1480)")
        XCTAssertNil(later.decoded.sourcePort)
        XCTAssertEqual(PacketDetails.sections(later, linkType: LinkType.null).map(\.title), ["Frame", "IPv6"])
        let head = row(null(ipv6(next: 44, [17, 0, 0, 1, 0, 0, 0, 1] + udp(1000, 2000, [1, 2, 3, 4])), v6: true))
        XCTAssertEqual(head.decoded.sourceEndpoint, "[fe80::1]:1000")
        XCTAssertEqual(PacketDetails.sections(head, linkType: LinkType.null).map(\.title), ["Frame", "IPv6", "UDP"])

        // 모르는 계열(7) + IP 가 아닌 내용: 목록은 "IP 아님", 상세도 Frame 뿐
        let other = row([7, 0, 0, 0] + [UInt8](repeating: 0x01, count: 40))
        XCTAssertEqual(other.decoded.info, "IP 아님")
        XCTAssertEqual(PacketDetails.sections(other, linkType: LinkType.null).map(\.title), ["Frame"])
        // 계열은 IPv4 인데 내용이 IPv4 가 아니다
        XCTAssertEqual(PacketDetails.sections(row([2, 0, 0, 0] + [UInt8](repeating: 0x61, count: 40)), linkType: LinkType.null).map(\.title), ["Frame"])
        // OpenBSD loopback(네트워크 순서)의 IPv4 는 그대로 읽는다
        let loop = [0, 0, 0, 2] + ipv4(client, server, proto: 17, udp(1000, 2000, [1]))
        XCTAssertEqual(PacketDetails.sections(row(loop, linkType: LinkType.loop), linkType: LinkType.loop).map(\.title), ["Frame", "IPv4", "UDP"])
    }

    /// ClientHello 다음 조각이 helloTimeout 넘게 늦으면 seq 가 맞아도 붙이지 않는다 (기다리는 조각이 끝없이 남지 않게)
    func testClientHelloJoinExpires() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/tls-clienthello.bin")
        let hello = [UInt8](try Data(contentsOf: url))
        func capture(gap: Double) -> CaptureStore {
            ingest([
                (0.0, null(ipv4(client, server, proto: 6, tcp(50447, 443, seq: 1, flags: .syn)))),
                (0.1, null(ipv4(client, server, proto: 6, tcp(50447, 443, seq: 2, flags: .ack, payload: Array(hello[..<1448]))))),
                (0.1 + gap, null(ipv4(client, server, proto: 6, tcp(50447, 443, seq: 1450, flags: [.psh, .ack], payload: Array(hello[1448...]))))),
            ])
        }
        XCTAssertEqual(capture(gap: CaptureStore.helloTimeout - 1).rows[2].decoded.tlsServerName, "test.example")
        let late = capture(gap: CaptureStore.helloTimeout + 1)
        XCTAssertNil(late.rows[2].decoded.tlsServerName)
        XCTAssertEqual(late.topConversations(1).first?.label, "TLS")
    }

    // MARK: tcpdump 인자

    func testCaptureCommand() {
        XCTAssertEqual(CaptureCommand.arguments(device: "en11", filter: " host 192.168.8.103  and port 22 "),
                       ["-i", "en11", "-n", "-U", "-s", "4096", "-w", "-", "host", "192.168.8.103", "and", "port", "22"])
        XCTAssertEqual(CaptureCommand.arguments(device: "utun6", filter: ""), ["-i", "utun6", "-n", "-U", "-s", "4096", "-w", "-"])
        XCTAssertNil(CaptureCommand.arguments(device: "en0; rm -rf /", filter: ""), "장치 이름은 영문·숫자·점만")
        XCTAssertNil(CaptureCommand.arguments(device: "", filter: ""))
        XCTAssertNil(CaptureCommand.arguments(device: "en0", filter: "port 22 -w /etc/hosts"), "필터로 tcpdump 옵션을 넣지 못한다 (root 로 돈다)")
        XCTAssertNil(CaptureCommand.arguments(device: "en0", filter: "-z rm"))
    }

    /// 이 Mac 의 tcpdump -D (2026-11-01) → 연결된 장치만 (끊김·연결 안 됨·[none] 빼기)
    func testParseDevices() {
        let text = """
        1.ap1 [Up, Running, Wireless, Not associated]
        2.en0 [Up, Running, Wireless, Associated]
        3.utun0 [Up, Running]
        11.utun6 [Up, Running]
        12.en11 [Up, Running, Connected]
        17.lo0 [Up, Running, Loopback]
        18.anpi3 [Up, Running, Disconnected]
        28.gif0 [none]
        30.nan0 [Wireless, Not associated]
        """
        XCTAssertEqual(CaptureCommand.parseDevices(text), ["en0", "utun0", "utun6", "en11", "lo0"])
        XCTAssertEqual(CaptureCommand.parseDevices(""), [])
    }

    /// 인증: 지문 단계는 -A 없이, 실패(취소·지문 없음 → 터미널 없음·비밀번호 필요)면 비밀번호 창(-A)으로 다시 (2026-11-02)
    func testSudoTouchIDThenPassword() {
        XCTAssertEqual(CaptureCommand.sudoArguments(["-i", "en11"], askPass: false), ["/usr/sbin/tcpdump", "-i", "en11"])
        XCTAssertEqual(CaptureCommand.sudoArguments(["-i", "en11"], askPass: true), ["-A", "/usr/sbin/tcpdump", "-i", "en11"])
        // 이 Mac 의 sudo 실제 문구 (sudo -n true 2>&1)
        XCTAssertTrue(CaptureCommand.needsPasswordFallback("sudo: a password is required\n"))
        XCTAssertTrue(CaptureCommand.needsPasswordFallback("sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper\n"))
        XCTAssertFalse(CaptureCommand.needsPasswordFallback("tcpdump: can't parse filter expression: syntax error\n"), "tcpdump 오류는 다시 묻지 않는다")
        XCTAssertFalse(CaptureCommand.needsPasswordFallback("sudo: 3 incorrect password attempts\n"), "비밀번호를 틀린 건 다시 띄우지 않는다")
        XCTAssertFalse(CaptureCommand.needsPasswordFallback(""))
    }

    func testFailureReason() {
        XCTAssertEqual(CaptureCommand.failureReason("tcpdump: listening on lo0, link-type NULL (BSD loopback), snapshot length 256 bytes\ntcpdump: forcing exit (name resolution may be stuck; try -n)\n"), nil)
        XCTAssertEqual(CaptureCommand.failureReason("tcpdump: can't parse filter expression: syntax error\n"), "tcpdump: can't parse filter expression: syntax error")
        XCTAssertEqual(CaptureCommand.failureReason("sudo: a password is required\n"), "sudo: a password is required")
    }
}
