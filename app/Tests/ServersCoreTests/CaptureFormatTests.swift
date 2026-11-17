// 패킷 캡처 화면의 판정·글자: 시간 표기 · DNS 결과/실패(2초 문턱) · 대화 끝 순서 · 내용 없는 ACK.
// 기댓값은 옮기기 전 CaptureSummaryCard(result·failed·ends) · PacketListCard.cell · CaptureText.ms 를 따라 적었다.

import XCTest
@testable import ServersCore

final class CaptureFormatTests: XCTestCase {
    func testMs() {
        let rows: [(Double, String)] = [
            (0, "0.00 ms"), (0.00042, "0.42 ms"), (0.000999, "1.00 ms"),
            (0.001, "1.0 ms"), (0.0123, "12.3 ms"), (0.9994, "999.4 ms"),
            (1, "1.00 s"), (1.25, "1.25 s"), (12.5, "12.50 s"),
        ]
        for (seconds, expected) in rows { XCTAssertEqual(CaptureFormat.ms(seconds), expected, "\(seconds)") }
    }

    private func dns(answered: Double? = nil, rcode: Int? = nil, answers: [String] = []) -> DNSTransaction {
        DNSTransaction(id: "1", name: "example.com", type: "A", server: "1.1.1.1", asked: 100, answered: answered, rcode: rcode, answers: answers)
    }

    /// now 는 캡처의 마지막 패킷 시각. 문턱은 물은 뒤 2초 "초과"
    func testDNSResultAndFailure() {
        let rows: [(String, DNSTransaction, Double?, String, Bool)] = [
            ("정상 답 둘까지", dns(answered: 100.0123, rcode: 0, answers: ["1.2.3.4", "5.6.7.8", "9.9.9.9"]), 105,
             "1.2.3.4, 5.6.7.8 · 12.3 ms · 1.1.1.1", false),
            ("NOERROR 인데 답 없음", dns(answered: 100.5, rcode: 0), 105, "답 없음 · 500.0 ms · 1.1.1.1", false),
            ("NXDOMAIN", dns(answered: 100.01, rcode: 3), 105, "NXDOMAIN · 1.1.1.1", true),
            ("SERVFAIL", dns(answered: 100.01, rcode: 2), nil, "SERVFAIL · 1.1.1.1", true),
            ("모르는 코드", dns(answered: 100.01, rcode: 9), nil, "RCODE 9 · 1.1.1.1", true),
            ("답 없음 · 2초 넘음", dns(), 102.01, "응답 없음 · 1.1.1.1", true),
            ("답 없음 · 딱 2초는 아직", dns(), 102, "기다리는 중 · 1.1.1.1", false),
            ("답 없음 · 1초", dns(), 101, "기다리는 중 · 1.1.1.1", false),
            ("답 없음 · now 모름", dns(), nil, "기다리는 중 · 1.1.1.1", false),
            ("답 시각은 있는데 rcode 없음", dns(answered: 100.002), 200, "답 없음 · 2.0 ms · 1.1.1.1", false),
        ]
        for (note, t, now, text, failed) in rows {
            XCTAssertEqual(t.resultText(now: now), text, note)
            XCTAssertEqual(t.isFailed(now: now), failed, "failed: \(note)")
        }
        XCTAssertEqual(DNSTransaction.noResponseAfter, 2)
    }

    func testConversationEnds() {
        let local: Set<String> = ["192.168.8.101", "127.0.0.1", "::1"]
        func conv(_ a: String, _ b: String) -> Conversation { Conversation(id: "", transport: "TCP", a: a, b: b, first: 0, last: 0) }
        let rows: [(String, Conversation, String, String)] = [
            ("a 가 내 쪽 → 뒤로", conv("192.168.8.101:52786", "192.0.2.143:51820"), "192.0.2.143:51820", "192.168.8.101:52786"),
            ("b 가 내 쪽 → 그대로", conv("192.0.2.143:51820", "192.168.8.101:52786"), "192.0.2.143:51820", "192.168.8.101:52786"),
            ("둘 다 내 쪽 → 그대로", conv("127.0.0.1:18080", "127.0.0.1:50000"), "127.0.0.1:18080", "127.0.0.1:50000"),
            ("둘 다 남 → 그대로", conv("1.1.1.1:53", "8.8.8.8:53"), "1.1.1.1:53", "8.8.8.8:53"),
            ("IPv6 대괄호 끝점", conv("[::1]:443", "[fd00::2]:5000"), "[fd00::2]:5000", "[::1]:443"),
            ("포트 없는 끝점", conv("192.168.8.101", "1.1.1.1"), "1.1.1.1", "192.168.8.101"),
        ]
        for (note, c, remote, mine) in rows {
            let ends = c.ends(local: local)
            XCTAssertEqual(ends.remote, remote, note)
            XCTAssertEqual(ends.local, mine, note)
        }
        XCTAssertEqual(conv("192.168.8.101:1", "1.1.1.1:2").ends(local: []).remote, "192.168.8.101:1", "내 주소를 모르면 그대로")
    }

    func testBareACK() {
        func row(_ flags: TCPFlags?, payload: Int = 0, issue: TCPIssue? = nil) -> CaptureRow {
            var decoded = DecodedPacket()
            decoded.tcp = flags.map { TCPSegment(flags: $0, seq: 0, ack: 0, window: 1024, payloadLength: payload) }
            return CaptureRow(id: 0, raw: CapturedPacket(time: 0, originalLength: 0, data: []), decoded: decoded, conversation: "", issue: issue)
        }
        let rows: [(String, CaptureRow, Bool)] = [
            ("ACK 만 · 내용 없음", row([.ack]), true),
            ("ACK + 내용", row([.ack], payload: 1), false),
            ("PSH, ACK", row([.psh, .ack]), false),
            ("SYN, ACK", row([.syn, .ack]), false),
            ("FIN, ACK", row([.fin, .ack]), false),
            ("문제 표시가 붙은 ACK (Win=0)", row([.ack], issue: .zeroWindow), false),
            ("TCP 아님", row(nil), false),
        ]
        for (note, r, expected) in rows { XCTAssertEqual(r.isBareACK, expected, note) }
    }
}
