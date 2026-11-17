// 진단 TCP 포트 · DNS 조회: 입력 거르기 · dig 출력 읽기(2026-10-15 이 Mac 모양) · 결과 문구 · 명령 인자.

import Foundation
@testable import ServersCore
import XCTest

final class DiagnosticChecksTests: XCTestCase {
    func testTCPTarget() {
        XCTAssertEqual(TCPPortTest.target(" 192.168.112.11:22 ")?.host, "192.168.112.11")
        XCTAssertEqual(TCPPortTest.target(" 192.168.112.11:22 ")?.port, 22)
        XCTAssertEqual(TCPPortTest.target("10.0.0.1 5432")?.port, 5432)
        XCTAssertNil(TCPPortTest.target("db.acme:22"), "IPv4 만 (TCPProbe)")
        XCTAssertNil(TCPPortTest.target("10.0.0.1:0"))
        XCTAssertNil(TCPPortTest.target("10.0.0.1:70000"))
        XCTAssertNil(TCPPortTest.target("10.0.0.1"))
        var r = TCPPortResult(host: "10.0.0.1", port: 22, device: "en10")
        XCTAssertEqual(r.text, "확인 중…")
        r.open = true; r.ms = 4
        XCTAssertEqual(r.text, "열림 · 4 ms")
        r.open = false; r.ms = nil
        XCTAssertEqual(r.text, "응답 없음 (닫힘·막힘)")
        XCTAssertTrue(r.reportText.hasPrefix("TCP 10.0.0.1:22 · en10 · "))
    }

    func testDNSNameFilter() {
        XCTAssertEqual(DNSLookup.name(" www.apple.com "), "www.apple.com")
        XCTAssertEqual(DNSLookup.name("_ldap._tcp.example"), "_ldap._tcp.example")
        XCTAssertNil(DNSLookup.name("-x"), "dig 옵션으로 읽히지 않게")
        XCTAssertNil(DNSLookup.name("a b"))
        XCTAssertNil(DNSLookup.name("a;rm"))
    }

    func testParseAnswersAndStatus() {
        let ok = """
            ;; Got answer:
            ;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1
            www.apple.com.\t\t251\tIN\tCNAME\twww-apple-com.v.aaplimg.com.
            e6858.dsce9.akamaiedge.net. 10\tIN\tA\t23.41.89.203
            ;; Query time: 9 msec
            ;; SERVER: 168.126.63.1#53(168.126.63.1)
            """
        let parsed = DNSLookup.parse(ok)
        XCTAssertEqual(parsed.answers, [DNSAnswer(name: "www.apple.com", type: "CNAME", value: "www-apple-com.v.aaplimg.com", ttl: 251),
                                        DNSAnswer(name: "e6858.dsce9.akamaiedge.net", type: "A", value: "23.41.89.203", ttl: 10)])
        XCTAssertEqual(parsed.status, "NOERROR")
        XCTAssertEqual(parsed.ms, 9)
        XCTAssertFalse(parsed.timedOut)

        var result = DNSLookupResult(name: "www.apple.com", server: "168.126.63.1", device: "en0")
        XCTAssertEqual(result.text, "묻는 중…")
        result.answers = parsed.answers; result.status = parsed.status
        XCTAssertEqual(result.text, "23.41.89.203", "CNAME 을 따라간 최종 주소")

        let nx = DNSLookup.parse(";; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 2\n;; Query time: 10 msec\n")
        result.answers = nx.answers; result.status = nx.status
        XCTAssertEqual(result.text, "이름 없음 (NXDOMAIN)")

        let timeout = DNSLookup.parse(";; connection timed out; no servers could be reached\n")
        XCTAssertTrue(timeout.timedOut)
        var silent = DNSLookupResult(name: "x", server: "10.255.255.1", device: "en10")
        silent.timedOut = true
        XCTAssertEqual(silent.text, "DNS 서버 응답 없음")
    }

    func testQueryArguments() async {
        let runner = FakeRunner()
        runner.scripted["dig +noall +comments +answer +stats +time=2 +tries=1 -b 10.50.10.17 @10.50.10.1 db.acme A"] =
            CommandResult(exitCode: 0, stdout: ";; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 3\ndb.acme.\t60\tIN\tA\t192.168.113.11\n;; Query time: 1 msec\n")
        let result = await DNSLookup.query("db.acme", server: "10.50.10.1", source: "10.50.10.17", device: "en10", runner: runner)
        XCTAssertEqual(result.addresses, ["192.168.113.11"])
        XCTAssertEqual(result.ms, 1)
        XCTAssertTrue(result.reportText.contains("db.acme A 192.168.113.11"))
    }

    /// dig 종료 코드 9 = 서버가 답하지 않음 — 출력에 시간 초과 문구가 없어도(빈 출력) 응답 없음으로
    func testQueryExitNineIsTimedOut() async {
        let runner = FakeRunner()
        runner.scripted["dig +noall +comments +answer +stats +time=2 +tries=1 @10.255.255.1 db.acme A"] = CommandResult(exitCode: 9)
        let silent = await DNSLookup.query("db.acme", server: "10.255.255.1", source: nil, device: "en10", runner: runner)
        XCTAssertTrue(silent.timedOut)
        XCTAssertEqual(silent.text, "DNS 서버 응답 없음")
        // 다른 실패 코드는 응답 없음이 아니다
        runner.scripted["dig +noall +comments +answer +stats +time=2 +tries=1 @10.255.255.1 db.acme A"] = CommandResult(exitCode: 10)
        let other = await DNSLookup.query("db.acme", server: "10.255.255.1", source: nil, device: "en10", runner: runner)
        XCTAssertFalse(other.timedOut)
    }

    // MARK: 네임서버 (2026-11-13 이 Mac 의 dig 출력 모양)

    private func ns(_ name: String) -> String { "dig +noall +comments +answer +authority +time=2 +tries=1 @1.1.1.1 \(name) NS" }
    private let header = ";; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\n"
    private func digCount(_ runner: FakeRunner) -> Int { runner.calls.filter { $0.executable == "dig" }.count }

    /// 하위 이름: SOA 가 가리키는 영역으로 한 번에 올라가 그 NS 를 — 두 번 묻는다
    func testNameserversFollowSOAToZone() async {
        let runner = FakeRunner()
        runner.scripted[ns("a.b.github.com")] = CommandResult(exitCode: 0, stdout: header + "github.com.\t\t900\tIN\tSOA\tns-1707.awsdns-21.co.uk. awsdns-hostmaster.amazon.com. 1 7200 900 1209600 86400\n")
        runner.scripted[ns("github.com")] = CommandResult(exitCode: 0, stdout: header + "github.com.\t900\tIN\tNS\tns-520.awsdns-01.net.\ngithub.com.\t900\tIN\tNS\tNS-1707.awsdns-21.co.uk.\n")
        let found = await DNSLookup.nameservers(for: "A.b.GitHub.com", server: "1.1.1.1", source: nil, runner: runner)
        XCTAssertEqual(found?.zone, "github.com")
        XCTAssertEqual(found?.servers ?? [], ["ns-1707.awsdns-21.co.uk", "ns-520.awsdns-01.net"])
        XCTAssertEqual(DNSProvider.name(for: found?.servers ?? []), "Amazon Route 53")
        XCTAssertEqual(runner.calls.filter { $0.executable == "dig" }.count, 2)
    }

    /// CNAME 이면 SOA 는 건너간 쪽(akamaiedge.net) 것 — 따라가지 않고 앞 낱말을 떼어 apple.com 을 묻는다
    func testNameserversIgnoreSOAOfCNAMETarget() async {
        let runner = FakeRunner()
        runner.scripted[ns("www.apple.com")] = CommandResult(exitCode: 0, stdout: header + """
        www.apple.com.\t\t68\tIN\tCNAME\twww-apple-com.v.aaplimg.com.
        www.apple.com.edgekey.net. 70\tIN\tCNAME\te6858.dsce9.akamaiedge.net.
        dsce9.akamaiedge.net.\t1000\tIN\tSOA\tn0dsce9.akamaiedge.net. hostmaster.akamai.com. 1794550490 1000 1000 1000 1800

        """)
        runner.scripted[ns("apple.com")] = CommandResult(exitCode: 0, stdout: header + "apple.com.\t\t9147\tIN\tNS\tb.ns.apple.com.\napple.com.\t\t9147\tIN\tNS\ta.ns.apple.com.\n")
        let found = await DNSLookup.nameservers(for: "www.apple.com", server: "1.1.1.1", source: nil, runner: runner)
        XCTAssertEqual(found?.zone, "apple.com")
        XCTAssertEqual(found?.servers ?? [], ["a.ns.apple.com", "b.ns.apple.com"])
        XCTAssertNil(DNSProvider.name(for: found?.servers ?? []), "목록에 없는 곳은 서비스 이름 없이")
    }

    func testNameserversEdgeCases() async {
        let runner = FakeRunner()
        var mark = 0
        // 권한 구역에 영역의 NS 를 실어 주는 서버: 한 번에
        runner.scripted[ns("db.corp.example")] = CommandResult(exitCode: 0, stdout: header + "corp.example.\t60\tIN\tNS\tns1.corp.example.\n")
        let referral = await DNSLookup.nameservers(for: "db.corp.example", server: "1.1.1.1", source: nil, runner: runner)
        XCTAssertEqual(referral?.zone, "corp.example")
        // 서버가 답하지 않으면 거기서 그만 (더 묻지 않는다)
        mark = digCount(runner)
        runner.scripted[ns("x.silent.example")] = CommandResult(exitCode: 9)
        let silent = await DNSLookup.nameservers(for: "x.silent.example", server: "1.1.1.1", source: nil, runner: runner)
        XCTAssertNil(silent)
        XCTAssertEqual(digCount(runner) - mark, 1)
        // 아무 답도 없는 내부 이름: 낱말을 떼며 올라가다 끝 (루트 SOA "." 는 영역으로 치지 않는다)
        mark = digCount(runner)
        runner.scripted[ns("db.acme")] = CommandResult(exitCode: 0, stdout: header + ".\t\t10800\tIN\tSOA\ta.root-servers.net. nstld.verisign-grs.com. 1 1800 900 604800 86400\n")
        let none = await DNSLookup.nameservers(for: "db.acme", server: "1.1.1.1", source: nil, runner: runner)
        XCTAssertNil(none)
        XCTAssertLessThanOrEqual(digCount(runner) - mark, 4)
        // 깊은 이름도 4번을 넘지 않는다
        mark = digCount(runner)
        let deep = await DNSLookup.nameservers(for: "a.b.c.d.e.f.example", server: "1.1.1.1", source: nil, runner: runner)
        XCTAssertNil(deep)
        XCTAssertEqual(digCount(runner) - mark, 4)
    }

    /// 조회 전체: A 뒤에 네임서버까지. NXDOMAIN·응답 없음이면 NS 는 묻지 않는다
    func testQueryAddsNameservers() async {
        let runner = FakeRunner()
        var mark = 0
        let a = "dig +noall +comments +answer +stats +time=2 +tries=1 @1.1.1.1 github.com A"
        runner.scripted[a] = CommandResult(exitCode: 0, stdout: header + "github.com.\t60\tIN\tA\t20.200.245.247\n;; Query time: 5 msec\n")
        runner.scripted[ns("github.com")] = CommandResult(exitCode: 0, stdout: header + "github.com.\t900\tIN\tNS\tdns1.p08.nsone.net.\ngithub.com.\t900\tIN\tNS\tns-520.awsdns-01.net.\n")
        let result = await DNSLookup.query("github.com", server: "1.1.1.1", source: nil, device: "en0", runner: runner)
        XCTAssertEqual(result.addresses, ["20.200.245.247"])
        XCTAssertEqual(result.zone, "github.com")
        XCTAssertNil(result.provider, "서비스가 섞여 있으면 하나로 말하지 않는다")
        XCTAssertTrue(result.reportText.contains("네임서버 (github.com):\n  dns1.p08.nsone.net"))

        mark = digCount(runner)
        runner.scripted[a] = CommandResult(exitCode: 0, stdout: ";; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 2\n")
        let nx = await DNSLookup.query("github.com", server: "1.1.1.1", source: nil, device: "en0", runner: runner)
        XCTAssertNil(nx.zone)
        XCTAssertEqual(digCount(runner) - mark, 1)
    }

    func testProviderNames() {
        XCTAssertEqual(DNSProvider.name(for: ["ada.ns.cloudflare.com", "bob.ns.cloudflare.com"]), "Cloudflare")
        XCTAssertEqual(DNSProvider.name(for: ["ns1-07.azure-dns.com", "ns2-07.azure-dns.net"]), "Azure DNS")
        XCTAssertEqual(DNSProvider.name(for: ["ns1.google.com"]), "Google")
        XCTAssertNil(DNSProvider.name(for: ["ns1.notgoogle.com"]), "낱말 경계에서만 맞춘다")
        XCTAssertNil(DNSProvider.name(for: []))
    }

    /// TTL 은 주소(A) 답 가운데 가장 짧은 것, IPv6 는 AAAA 를 따로 물어 — 이름이 없으면 묻지 않는다
    func testQueryAddsTTLAndIPv6() async {
        let runner = FakeRunner()
        let a = "dig +noall +comments +answer +stats +time=2 +tries=1 @1.1.1.1 www.example.com A"
        let aaaa = "dig +noall +answer +time=2 +tries=1 @1.1.1.1 www.example.com AAAA"
        runner.scripted[a] = CommandResult(exitCode: 0, stdout: header + "www.example.com.\t300\tIN\tCNAME\tedge.example.net.\nedge.example.net.\t60\tIN\tA\t192.0.2.10\nedge.example.net.\t20\tIN\tA\t192.0.2.11\n")
        runner.scripted[aaaa] = CommandResult(exitCode: 0, stdout: "www.example.com.\t300\tIN\tCNAME\tedge.example.net.\nedge.example.net.\t60\tIN\tAAAA\t2001:db8::10\n")
        let result = await DNSLookup.query("www.example.com", server: "1.1.1.1", source: nil, device: "en0", runner: runner)
        XCTAssertEqual(result.ttl, 20, "CNAME 의 300 이 아니라 주소 답의 가장 짧은 것")
        XCTAssertEqual(result.addresses, ["192.0.2.10", "192.0.2.11"])
        XCTAssertEqual(result.addresses6, ["2001:db8::10"], "AAAA 답의 CNAME 줄은 주소가 아니다")
        XCTAssertTrue(result.reportText.contains("edge.example.net AAAA 2001:db8::10 (TTL 60)"))

        // IPv4 가 없고 IPv6 만 있는 이름
        runner.scripted[a] = CommandResult(exitCode: 0, stdout: header)
        let only6 = await DNSLookup.query("www.example.com", server: "1.1.1.1", source: nil, device: "en0", runner: runner)
        XCTAssertEqual(only6.text, "IPv4 주소 없음")
        XCTAssertNil(only6.ttl)

        // 응답 없음: AAAA·NS 를 묻지 않는다
        let mark = digCount(runner)
        runner.scripted[a] = CommandResult(exitCode: 9)
        let silent = await DNSLookup.query("www.example.com", server: "1.1.1.1", source: nil, device: "en0", runner: runner)
        XCTAssertTrue(silent.addresses6.isEmpty)
        XCTAssertEqual(digCount(runner) - mark, 1)
    }
}
