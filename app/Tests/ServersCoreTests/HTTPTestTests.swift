// HTTP 확인: URL 거르기 · 내부망 장치에 묶는 인자 · curl -w 출력 해석.
// Fixtures/http-curl-*.txt 는 이 Mac 에서 공개 주소·로컬 주소로 돌린 실제 출력이다 (2026-10-14 — 내부망 아님):
// ok = https://example.com · redirect = http://github.com · cert = https://self-signed.badssl.com ·
// resolve = http://nosuchhost.invalid · refused = http://127.0.0.1:1 · timeout = http://10.255.255.1 (--connect-timeout 3) ·
// tls-stall = 127.0.0.1 임시 서버가 TCP 만 받고 아무것도 안 보냄(https) · body-timeout = 같은 임시 서버가 헤더 + 본문 3바이트만 보냄(--max-time 4)

import XCTest
@testable import ServersCore

final class HTTPTestTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        try fixtureText("http-curl-\(name)")
    }

    private func parsed(_ name: String) throws -> HTTPCheck {
        try XCTUnwrap(HTTPTest.parse(try fixture(name)))
    }

    func testURLFilter() {
        XCTAssertEqual(HTTPTest.url(" 10.50.10.17:8080/health \n"), "http://10.50.10.17:8080/health", "스킴이 없으면 http")
        XCTAssertEqual(HTTPTest.url("https://jenkins.corp.local/login?x=1"), "https://jenkins.corp.local/login?x=1")
        XCTAssertEqual(HTTPTest.url("HTTPS://10.0.0.1"), "HTTPS://10.0.0.1")
        XCTAssertEqual(HTTPTest.url("http://[fe80::1]:8080/"), "http://[fe80::1]:8080/")
        XCTAssertNil(HTTPTest.url(""))
        XCTAssertNil(HTTPTest.url("   "))
        XCTAssertNil(HTTPTest.url("http://"), "호스트 없음")
        XCTAssertNil(HTTPTest.url("ftp://10.0.0.1/"), "http·https 만")
        XCTAssertNil(HTTPTest.url("file:///etc/passwd"))
        XCTAssertNil(HTTPTest.url("http://a b"), "공백")
        XCTAssertNil(HTTPTest.url("10.0.0.1 -o /tmp/x"))
        XCTAssertNil(HTTPTest.url("http:/host"), "깨진 스킴")
        XCTAssertNil(HTTPTest.url("javascript:alert(1)"))
        XCTAssertNil(HTTPTest.url("ho\u{200B}st"), "가운데 섞인 폭 없는 문자 (앞뒤는 공백 정리에서 지워진다)")
        XCTAssertNil(HTTPTest.url("한글.com"), "macOS curl 은 한글 도메인을 못 푼다")
        XCTAssertNil(HTTPTest.url("http://admin:secret@10.0.0.1/"), "비밀번호가 대상 줄에 보인다")
        XCTAssertNil(HTTPTest.url("admin@10.0.0.1"))
        XCTAssertEqual(HTTPTest.url("10.0.0.1/p?u=http://y"), "http://10.0.0.1/p?u=http://y", "스킴은 맨 앞에서만 본다")
        XCTAssertEqual(HTTPTest.url("localhost:8080"), "http://localhost:8080")
    }

    func testCommandBindsIntranetDevice() async {
        let runner = FakeRunner()
        _ = await HTTPTest.check("https://10.50.10.17/", device: "en10", runner: runner)
        XCTAssertEqual(runner.calls.map(\.executable), ["curl"])
        let args = runner.calls[0].arguments
        XCTAssertEqual(Array(args.prefix(14)), ["-sS", "-g", "-o", "/dev/null", "--proto", "=http,https", "--noproxy", "*",
                                                "--connect-timeout", "3", "--max-time", "10", "--interface", "en10"])
        XCTAssertEqual(args.last, "https://10.50.10.17/", "URL 은 맨 끝 인자 하나")
        XCTAssertFalse(args.contains("-k") || args.contains("--insecure"), "인증서 검사는 끄지 않는다")
        XCTAssertFalse(args.contains("-L"), "리다이렉트는 따라가지 않는다")

        // 이상한 장치 이름이면 명령을 돌리지 않는다
        let before = runner.calls.count
        let bad = await HTTPTest.check("http://10.0.0.1", device: "en10 -x", runner: runner)
        XCTAssertEqual(bad.failureText, "장치에 묶지 못했습니다")
        XCTAssertEqual(runner.calls.count, before)
    }

    func testOK() throws {
        let check = try parsed("ok")
        XCTAssertEqual(check.exitCode, 0)
        XCTAssertEqual(check.status, 200)
        XCTAssertNil(check.failureText)
        XCTAssertEqual(check.remotePort, 443)
        XCTAssertNotNil(check.endpoint)
        XCTAssertNil(check.redirect)
        XCTAssertNil(check.error)
        let stages = try XCTUnwrap(check.stages)
        XCTAssertNotNil(stages.tlsMs, "https 는 TLS 단계가 있다")
        for value in [stages.dnsMs, stages.connectMs, stages.tlsMs, stages.waitMs].compactMap({ $0 }) {
            XCTAssertGreaterThanOrEqual(value, 0)
        }
    }

    func testRedirectIsResultNotFollowed() throws {
        let check = try parsed("redirect")
        XCTAssertEqual(check.status, 301)
        XCTAssertNil(check.failureText, "3xx 도 응답을 받은 것")
        XCTAssertEqual(check.redirect, "https://github.com/")
        XCTAssertEqual(check.remotePort, 80)
        XCTAssertNil(check.stages?.tlsMs, "http 는 TLS 단계 없음")
    }

    func testCertificateFailure() throws {
        let check = try parsed("cert")
        XCTAssertEqual(check.exitCode, 60)
        XCTAssertNil(check.status, "000 → 상태 없음")
        XCTAssertEqual(check.failureText, "인증서 확인 실패")
        XCTAssertEqual(check.error, "SSL certificate problem: self signed certificate")
        XCTAssertNotNil(check.endpoint, "연결은 됐으니 붙은 IP 는 있다")
    }

    func testConnectionFailures() throws {
        let resolve = try parsed("resolve")
        XCTAssertEqual(resolve.failureText, "이름을 찾지 못했습니다")
        XCTAssertNil(resolve.endpoint)
        XCTAssertNil(resolve.remotePort, "포트 0 → 없음")

        XCTAssertEqual(try parsed("refused").failureText, "연결 실패", "7 은 거부·경로 없음이 섞여 있어 원인은 상세 줄로")

        let timeout = try parsed("timeout")
        XCTAssertEqual(timeout.exitCode, 28)
        XCTAssertEqual(timeout.failureText, "연결 실패 (시간 초과)", "연결 전에 시간이 다 됐다")
    }

    /// TLS 핸드셰이크에서 멈춤 — --connect-timeout(3초)에 걸렸으니 10초 문구가 아니다
    func testTLSStall() throws {
        let check = try parsed("tls-stall")
        XCTAssertEqual(check.exitCode, 28)
        XCTAssertTrue(check.https)
        XCTAssertEqual(check.failureText, "TLS 연결 실패 (시간 초과)")
        XCTAssertNil(check.bodyNote)
    }

    /// 헤더(200)는 받았는데 본문을 받다 시간이 다 됨 — 상태 코드는 보이고 본문 쪽 한 줄만 붙는다
    func testBodyTimeoutKeepsStatus() throws {
        let check = try parsed("body-timeout")
        XCTAssertEqual(check.exitCode, 28)
        XCTAssertEqual(check.status, 200)
        XCTAssertNil(check.failureText)
        XCTAssertEqual(check.bodyNote, "본문 받는 중 시간 초과 (10초)")
        XCTAssertNil(try parsed("ok").bodyNote)
    }

    /// 연결된 뒤 응답을 기다리다 시간이 다 된 경우 (서버가 느림) — 연결 실패와 가른다
    func testTimeoutAfterConnect() {
        let check = HTTPTest.parse("exit=28\ncode=000\nip=10.50.10.17\nport=8080\ndns=0.001\nconnect=0.004\ntls=0\nfirst=0\ntotal=10.0\nredirect=\nerror=Operation timed out\n")
        XCTAssertEqual(check?.failureText, "응답 없음 (10초 초과)")
    }

    func testStagesAreDurationsNotCumulative() {
        let stages = HTTPStages(dns: 0.002, connect: 0.027, tls: 0.063, firstByte: 0.106, total: 0.110)
        XCTAssertEqual(stages.dnsMs!, 2, accuracy: 0.001)
        XCTAssertEqual(stages.connectMs!, 25, accuracy: 0.001)
        XCTAssertEqual(stages.tlsMs!, 36, accuracy: 0.001)
        XCTAssertEqual(stages.waitMs!, 43, accuracy: 0.001)
        XCTAssertEqual(stages.downloadMs!, 4, accuracy: 0.001)
        XCTAssertEqual(stages.text, "DNS 2.0 ms · TCP 25 ms · TLS 36 ms · TTFB 43 ms · Download 4.0 ms · Total 110 ms")
        // http: TLS 없음 → 응답 대기는 연결 뒤부터
        let plain = HTTPStages(dns: 0.001, connect: 0.005, tls: 0, firstByte: 0.009, total: 0.010)
        XCTAssertNil(plain.tlsMs)
        XCTAssertEqual(plain.waitMs!, 4, accuracy: 0.001)
        XCTAssertEqual(plain.downloadMs!, 1, accuracy: 0.001)
        // 첫 바이트 전에 끝났으면 (연결 실패 등) TTFB·Download 없음
        let failed = HTTPStages(dns: 0.001, connect: 0, tls: 0, firstByte: 0, total: 3.0)
        XCTAssertNil(failed.waitMs)
        XCTAssertNil(failed.downloadMs)
        XCTAssertEqual(failed.text, "DNS 1.0 ms · Total 3000 ms")
    }

    func testMissingWriteOutFallsBackToExitCode() async {
        let runner = FakeRunner()
        let url = "http://10.0.0.1"
        runner.scripted["curl -sS -g -o /dev/null --proto =http,https --noproxy * --connect-timeout 3 --max-time 10 --interface en10 -w \(HTTPTest.format) \(url)"] =
            CommandResult(exitCode: 127, stderr: "curl: command not found\n")
        let check = await HTTPTest.check(url, device: "en10", runner: runner)
        XCTAssertEqual(check.exitCode, 127)
        XCTAssertEqual(check.failureText, "curl 을 실행하지 못했습니다 (종료 코드 127)", "curl 종료 코드가 아니다")
        XCTAssertEqual(check.error, "curl: command not found")
        XCTAssertNil(check.bodyNote)
        XCTAssertNil(HTTPTest.parse(""))

        // 앱 쪽 시간 초과 (124) 도 curl 코드가 아니다
        let slow = "http://10.0.0.2"
        runner.scripted["curl -sS -g -o /dev/null --proto =http,https --noproxy * --connect-timeout 3 --max-time 10 --interface en10 -w \(HTTPTest.format) \(slow)"] =
            CommandResult(exitCode: CommandResult.timedOutExitCode)
        let timedOut = await HTTPTest.check(slow, device: "en10", runner: runner)
        XCTAssertEqual(timedOut.failureText, "응답 없음 (앱 시간 초과)")
    }

    func testStatusKind() {
        XCTAssertEqual(HTTPTest.statusKind(200), "성공")
        XCTAssertEqual(HTTPTest.statusKind(301), "이동")
        // 자주 보는 코드는 뜻을 따로 — 404 는 거부가 아니라 없음
        let cases: [(Int, String)] = [(400, "잘못된 요청"), (401, "인증 필요"), (403, "거부"), (404, "없음"), (410, "없음"), (405, "허용 안 된 메서드"),
                                      (408, "요청 시간 초과"), (429, "요청 과다"), (418, "요청 오류"), (499, "요청 오류"),
                                      (500, "서버 오류"), (502, "게이트웨이 오류"), (503, "서비스 불가"), (504, "게이트웨이 시간 초과"), (599, "서버 오류"), (101, "정보")]
        for (code, kind) in cases { XCTAssertEqual(HTTPTest.statusKind(code), kind, "\(code)") }
        XCTAssertNil(HTTPTest.statusKind(999))
        XCTAssertNil(HTTPTest.statusKind(0))
    }

    /// 시간 막대의 단계: 잰 것만 순서대로, 합은 Total 과 맞는다 (2026-11-10 실제: DNS 1.5 · TCP 5.6 · TLS 8.5 · TTFB 265 · Download 28 = 308)
    func testStageSegments() {
        let https = HTTPStages(dns: 0.0015, connect: 0.0071, tls: 0.0156, firstByte: 0.2806, total: 0.3086)
        XCTAssertEqual(https.segments.map(\.name), ["DNS", "TCP", "TLS", "TTFB", "Download"])
        XCTAssertEqual(https.segments.map(\.text), ["1.5 ms", "5.6 ms", "8.5 ms", "265 ms", "28 ms"])
        XCTAssertEqual(https.segments.map(\.ms).reduce(0, +), https.totalMs, accuracy: 0.001)
        XCTAssertEqual(https.totalText, "309 ms")
        // 막대에 마우스를 올리면 뜨는 풀이: 이름 · 시간 · 무슨 처리인지
        XCTAssertEqual(https.segments[3].help, "TTFB 265 ms — 요청을 보낸 뒤 첫 응답까지 (서버가 답을 만드는 시간)")
        XCTAssertEqual(https.segments[0].help, "DNS 1.5 ms — 이름을 IP 로 바꾸는 시간")
        XCTAssertTrue(https.segments.allSatisfy { $0.help.contains(" — ") })
        XCTAssertEqual(https.text, "DNS 1.5 ms · TCP 5.6 ms · TLS 8.5 ms · TTFB 265 ms · Download 28 ms · Total 309 ms")
        // http 는 TLS 없음, IP 로 바로 가면 DNS 도 없음
        let plain = HTTPStages(dns: 0, connect: 0.004, tls: 0, firstByte: 0.020, total: 0.021)
        XCTAssertEqual(plain.segments.map(\.name), ["TCP", "TTFB", "Download"])
        // 연결 전에 실패: 단계 없음. 시계 오차로 뒤집힌 값은 0
        XCTAssertEqual(HTTPStages(dns: 0, connect: 0, tls: 0, firstByte: 0, total: 3).segments, [])
        XCTAssertEqual(HTTPStages(dns: 0.010, connect: 0.009, tls: 0, firstByte: 0.02, total: 0.02).segments.first { $0.name == "TCP" }?.ms, 0)
    }

    func testIPv6Endpoint() {
        XCTAssertEqual(HTTPCheck(exitCode: 0, status: 200, remoteIP: "fe80::1", remotePort: 8080).endpoint, "[fe80::1]:8080")
    }
}
