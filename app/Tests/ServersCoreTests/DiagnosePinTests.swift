// 진단(이 Mac 의 진단 카드 · 서버 Diagnose 탭)이 같이 쓰는 부품을 한 곳으로 모아도 만들어지는 글이 그대로인지 고정한다:
// 서버로 보내는 스크립트 전문 · HTTP 결과 줄과 덧붙는 줄(양쪽이 같은 말 · 같은 순서) · 대상 입력 검사 · ping 인자.
// 실제 명령은 돌리지 않는다 (FakeRunner · 픽스처).

import Foundation
import XCTest
@testable import ServersCore

final class DiagnosePinTests: XCTestCase {
    private func request(_ tool: ServerDiagnose.Tool, _ input: String) throws -> ServerDiagnose.Request {
        try XCTUnwrap(ServerDiagnose.request(tool, input: input), input)
    }

    // MARK: 서버 스크립트 전문

    func testLinuxScriptsAreExactText() throws {
        XCTAssertEqual(ServerDiagnose.script(try request(.ping, "db.internal")), """
            command -v ping >/dev/null 2>&1 || { echo "@MISSING ping"; exit 0; }
            LC_ALL=C ping -c 5 -i 0.2 -W 1 'db.internal' 2>&1
            echo "@RC $?"
            """)
        XCTAssertEqual(ServerDiagnose.script(try request(.tcp, "192.0.2.10:5432")), """
            command -v bash >/dev/null 2>&1 || { echo "@MISSING bash"; exit 0; }
            command -v timeout >/dev/null 2>&1 || { echo "@MISSING timeout"; exit 0; }
            s=$(date +%s%N)
            timeout 3 bash -c 'exec 3<>/dev/tcp/192.0.2.10/5432' 2>/dev/null
            rc=$?
            e=$(date +%s%N)
            echo "@RC $rc"
            case "$s$e" in *[!0-9]*) ;; *) echo "@MS $(( (e - s) / 1000000 ))" ;; esac
            """)
        XCTAssertEqual(ServerDiagnose.script(try request(.http, "https://a.example/it's")), """
            command -v curl >/dev/null 2>&1 || { echo "@MISSING curl"; exit 0; }
            curl -sS -g -o /dev/null --proto =http,https --noproxy '*' --connect-timeout 3 --max-time 10 -w 'exit=%{exitcode}\\ncode=%{http_code}\\nscheme=%{scheme}\\nip=%{remote_ip}\\nport=%{remote_port}\\ndns=%{time_namelookup}\\nconnect=%{time_connect}\\ntls=%{time_appconnect}\\nfirst=%{time_starttransfer}\\ntotal=%{time_total}\\nredirect=%{redirect_url}\\nerror=%{errormsg}\\n' 'https://a.example/it'\\''s' 2>&1
            echo "@RC $?"
            """)
        XCTAssertEqual(ServerDiagnose.script(try request(.dns, "db.internal")), """
            command -v getent >/dev/null 2>&1 || { echo "@MISSING getent"; exit 0; }
            s=$(date +%s%N)
            getent ahosts 'db.internal' 2>/dev/null
            rc=$?
            e=$(date +%s%N)
            echo "@RC $rc"
            case "$s$e" in *[!0-9]*) ;; *) echo "@MS $(( (e - s) / 1000000 ))" ;; esac
            """)
    }

    func testOpenWrtScriptsAreExactText() throws {
        XCTAssertEqual(ServerDiagnose.script(try request(.ping, "db.internal"), type: .openwrt), """
            command -v ping >/dev/null 2>&1 || { echo "@MISSING ping"; exit 0; }
            LC_ALL=C ping -c 5 -W 1 'db.internal' 2>&1
            echo "@RC $?"
            """)
        XCTAssertEqual(ServerDiagnose.script(try request(.tcp, "192.0.2.10:5432"), type: .openwrt), """
            command -v nc >/dev/null 2>&1 || { echo "@MISSING nc"; exit 0; }
            nc 192.0.2.10 5432 </dev/null >/dev/null 2>&1 &
            p=$!
            if sleep 0.1 2>/dev/null; then step=0.1; max=30; else step=1; max=3; fi
            i=0
            while kill -0 $p 2>/dev/null && [ $i -lt $max ]; do sleep $step; i=$((i + 1)); done
            if kill -0 $p 2>/dev/null; then
              rc=124
              netstat -tn 2>/dev/null | grep -q "[ :]192.0.2.10:5432 .*ESTABLISHED" && rc=0
              kill $p 2>/dev/null
            else
              wait $p; rc=$?
            fi
            echo "@RC $rc"
            """)
        let http = try request(.http, "https://a.example/it's")
        XCTAssertEqual(ServerDiagnose.script(http, type: .openwrt), ServerDiagnose.script(http))
        XCTAssertEqual(ServerDiagnose.script(try request(.dns, "db.internal"), type: .openwrt), """
            command -v nslookup >/dev/null 2>&1 || { echo "@MISSING nslookup"; exit 0; }
            nslookup 'db.internal' 2>&1
            echo "@RC $?"
            """)
    }

    // MARK: HTTP 결과 줄

    /// 이 Mac 의 [복사] 텍스트(HTTPTestResult.reportText)와 서버 쪽 결과(ServerDiagnose.http)가 내는 줄
    private func both(_ check: HTTPCheck) -> (report: [String], state: ServerDiagnose.Outcome.State, headline: String, lines: [String]) {
        var result = HTTPTestResult(url: "http://a.example/", device: "en0", at: Date(timeIntervalSince1970: 0))
        result.check = check
        let outcome = ServerDiagnose.http(check)
        return (Array(result.reportText.split(separator: "\n").map(String.init).dropFirst()), outcome.state, outcome.headline, outcome.lines)
    }

    func testHTTPLinesFromRealOutput() throws {
        let expected: [String: [String]] = [
            "ok": ["결과: 200 성공", "연결: @", "시간: DNS 42 ms · TCP 32 ms · TLS 38 ms · TTFB 41 ms · Download 0.3 ms · Total 153 ms"],
            "redirect": ["결과: 301 이동", "이동: https://github.com/", "연결: @", "시간: DNS 46 ms · TCP 5.9 ms · TTFB 3.9 ms · Download 0.0 ms · Total 56 ms"],
            "cert": ["결과: 인증서 확인 실패", "상세: SSL certificate problem: self signed certificate", "연결: @", "시간: DNS 101 ms · TCP 176 ms · Total 587 ms"],
            "refused": ["결과: 연결 실패", "상세: Failed to connect to 127.0.0.1 port 1 after 0 ms: Couldn't connect to server", "시간: DNS 0.1 ms · Total 0.2 ms"],
            "resolve": ["결과: 이름을 찾지 못했습니다", "상세: Could not resolve host: nosuchhost.invalid"],
            "timeout": ["결과: 연결 실패 (시간 초과)", "상세: Failed to connect to 10.255.255.1 port 80 after 3006 ms: Timeout was reached", "시간: DNS 1.4 ms · Total 3007 ms"],
            "tls-stall": ["결과: TLS 연결 실패 (시간 초과)", "상세: SSL connection timeout", "연결: 127.0.0.1:18443", "시간: DNS 0.1 ms · TCP 0.1 ms · Total 3007 ms"],
            "body-timeout": ["결과: 200 성공 · 본문 받는 중 시간 초과 (10초)", "상세: Operation timed out after 4006 milliseconds with 3 out of 100000 bytes received",
                             "연결: 127.0.0.1:18080", "시간: DNS 0.1 ms · TCP 0.2 ms · TTFB 0.2 ms · Download 4006 ms · Total 4006 ms"],
        ]
        for name in ["ok", "redirect", "cert", "refused", "resolve", "timeout", "tls-stall", "body-timeout"] {
            let check = try XCTUnwrap(HTTPTest.parse(try fixtureText("http-curl-\(name)")), name)
            let (report, state, headline, lines) = both(check)
            // 공개 주소로 잰 픽스처의 연결 줄은 @ 로 적어 둔다 (주소를 테스트에 다시 적지 않는다)
            XCTAssertEqual(report, expected[name]?.map { $0 == "연결: @" ? "연결: \(check.endpoint ?? "")" : $0 }, name)
            XCTAssertEqual(["결과: \(headline)"] + lines, report, "\(name): 서버 쪽도 같은 말 · 같은 순서")
            XCTAssertEqual(state, check.status != nil ? .ok : .failed, name)
        }
    }

    func testHTTPLinesEdgeCases() {
        let stages = HTTPStages(dns: 0.001, connect: 0.002, tls: 0, firstByte: 0.010, total: 0.020)
        // curl 이 끝나지 못했다 — 상태 코드가 있어도 실패 한 줄이 먼저
        let stuck = both(HTTPCheck(exitCode: 124, status: 200, error: "boom", runFailure: "응답 없음 (앱 시간 초과)"))
        XCTAssertEqual(stuck.report, ["결과: 응답 없음 (앱 시간 초과)", "상세: boom"])
        XCTAssertEqual(stuck.state, .failed)
        XCTAssertEqual([stuck.headline] + stuck.lines, ["응답 없음 (앱 시간 초과)", "상세: boom"])
        // 본문을 덜 받았다 — 상태 코드 뒤에 덧붙이고 상세 줄도
        let short = both(HTTPCheck(exitCode: 18, status: 206, remoteIP: "2001:db8::1", remotePort: 443, stages: stages, redirect: "https://b.example/", error: "transfer closed"))
        XCTAssertEqual(short.report, ["결과: 206 성공 · 본문이 덜 왔습니다", "상세: transfer closed", "이동: https://b.example/", "연결: [2001:db8::1]:443",
                                      "시간: DNS 1.0 ms · TCP 1.0 ms · TTFB 8.0 ms · Download 10 ms · Total 20 ms"])
        XCTAssertEqual(short.state, .ok)
        XCTAssertEqual(["결과: \(short.headline)"] + short.lines, short.report)
        // 뜻을 모르는 상태 코드 · 오류 문장은 실패 · 본문 문제가 없으면 적지 않는다 · DNS 시간이 없으면 시간 줄도 없다
        let odd = both(HTTPCheck(exitCode: 0, status: 999, stages: HTTPStages(dns: 0, connect: 0.002, tls: 0, firstByte: 0.010, total: 0.020), error: "ignored"))
        XCTAssertEqual(odd.report, ["결과: 999"])
        XCTAssertEqual([odd.headline] + odd.lines, ["999"])
        // 실패도 상태 코드도 없는 값은 만들 수 없다(상태가 없으면 종료 코드가 실패 문구가 된다) — 종료 코드 0 도 "실패 (curl 종료 코드 0)"
        let none = both(HTTPCheck(exitCode: 0))
        XCTAssertEqual(none.report, ["결과: 실패 (curl 종료 코드 0)"])
        XCTAssertEqual(none.state, .failed)
        XCTAssertEqual(none.headline, "실패 (curl 종료 코드 0)")
        // 요청 중
        XCTAssertEqual(HTTPTestResult(url: "http://a.example/", device: "en0", at: Date(timeIntervalSince1970: 0)).reportText.split(separator: "\n").last, "결과: 요청 중")
    }

    /// 이름을 못 찾았을 때의 글은 어디서나 같다 (ping · HTTP · 서버 쪽 ping · dns)
    func testUnresolvedTextIsTheSameEverywhere() throws {
        let text = "이름을 찾지 못했습니다"
        XCTAssertEqual(ServerDiagnose.unresolvedText, text)
        XCTAssertEqual(HTTPCheck(exitCode: 6).failureText, text)
        var ping = PingTestResult(target: "nosuch.invalid", device: "en0", at: Date(timeIntervalSince1970: 0))
        ping.resolveFailed = true
        XCTAssertEqual(ping.reportText.split(separator: "\n").last, "응답: \(text)")
        XCTAssertEqual(ServerDiagnose.ping("ping: nosuch.invalid: Name or service not known").headline, text)
        XCTAssertEqual(ServerDiagnose.dns(addresses: [], ms: nil).headline, text)
    }

    // MARK: 대상 입력

    /// ping 대상과 DNS 이름은 같은 검사에 허용 글자 하나만 다르다 (ping 은 IPv6 의 ":", DNS 는 "_")
    func testHostInputRules() {
        for (input, ping, dns) in [
            ("  db-1.internal \n", "db-1.internal", "db-1.internal"), ("2001:db8::1", "2001:db8::1", nil), ("_ldap._tcp.example", nil, "_ldap._tcp.example"),
            ("", nil, nil), ("   ", nil, nil), ("-c", nil, nil), ("a b", nil, nil), ("a;rm", nil, nil), ("한글.kr", nil, nil), ("ａ.example", nil, nil),
            ("a/b", nil, nil), ("a.b-", "a.b-", "a.b-"), (" -x", nil, nil),
            (String(repeating: "a", count: 253), String(repeating: "a", count: 253), String(repeating: "a", count: 253)),
            (String(repeating: "a", count: 254), nil, nil),
        ] as [(String, String?, String?)] {
            XCTAssertEqual(PingTest.target(input), ping, "ping \(input.prefix(20))")
            XCTAssertEqual(DNSLookup.name(input), dns, "dns \(input.prefix(20))")
        }
    }

    // MARK: ping 실행

    /// 진단 카드(5회 · 장치 없이도)와 게이트웨이 확인(3회)이 같은 꼴의 인자를 쓴다. 장치 이름이 이상하면 돌리지 않고 "응답 없음"
    func testPingArgumentsAndBadDevice() async {
        let runner = FakeRunner()
        _ = await PingTest.ping("10.0.0.1", device: "en10", runner: runner)
        _ = await PingTest.ping("10.0.0.1", device: nil, runner: runner)
        _ = await NetworkProbe.ping("10.0.0.1", device: "en10", runner: runner)
        _ = await NetworkProbe.ping("10.0.0.1", device: "en10", count: 7, runner: runner)
        XCTAssertEqual(runner.calls.map(\.executable), ["ping", "ping", "ping", "ping"])
        XCTAssertEqual(runner.calls.map(\.arguments), [["-c", "5", "-i", "0.2", "-W", "1000", "-b", "en10", "10.0.0.1"], ["-c", "5", "-i", "0.2", "-W", "1000", "10.0.0.1"],
                                                       ["-c", "3", "-i", "0.2", "-W", "1000", "-b", "en10", "10.0.0.1"], ["-c", "7", "-i", "0.2", "-W", "1000", "-b", "en10", "10.0.0.1"]])
        let silent = PingSummary(averageMs: nil, lossPercent: 100, jitterMs: nil)
        let bad = await PingTest.ping("10.0.0.1", device: "en10 -x", runner: runner)
        XCTAssertEqual(bad.summary, silent)
        XCTAssertFalse(bad.resolveFailed)
        let badProbe = await NetworkProbe.ping("10.0.0.1", device: "", runner: runner)
        XCTAssertEqual(badProbe, silent)
        let badInternet = await NetworkProbe.internetProbe(device: "en0;x", runner: runner)
        XCTAssertEqual(badInternet, silent)
        XCTAssertEqual(runner.calls.count, 4, "이상한 장치 이름이면 명령을 돌리지 않는다")
        XCTAssertEqual(NetworkProbe.parseProbe("", count: 5), silent)
        XCTAssertEqual(NetworkProbe.parseProbe("500 0.1\n", count: 5), silent)
        // 출력은 stdout 과 stderr 를 이어 읽는다
        runner.scripted["ping -c 5 -i 0.2 -W 1000 nosuch.invalid"] = CommandResult(exitCode: 68, stderr: "ping: cannot resolve nosuch.invalid: Unknown host\n")
        let unknown = await PingTest.ping("nosuch.invalid", device: nil, runner: runner)
        XCTAssertTrue(unknown.resolveFailed)
        XCTAssertEqual(unknown.summary, silent)
    }
}
