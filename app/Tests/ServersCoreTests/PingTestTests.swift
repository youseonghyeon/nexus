// ping 테스트: 대상 거르기 · 내부망 장치에 묶는 인자 · traceroute 파싱 (실제 출력 2026-10-14, 이 Mac → 1.1.1.1 — 내부망 아님)

import XCTest
@testable import ServersCore

final class PingTestTests: XCTestCase {
    func testTargetFilter() {
        XCTAssertEqual(PingTest.target("  10.50.10.17 \n"), "10.50.10.17")
        XCTAssertEqual(PingTest.target("db-01.corp.local"), "db-01.corp.local")
        XCTAssertEqual(PingTest.target("fe80::1"), "fe80::1")
        XCTAssertNil(PingTest.target(""))
        XCTAssertNil(PingTest.target("   "))
        XCTAssertNil(PingTest.target("-f 10.0.0.1"), "옵션으로 읽히는 입력")
        XCTAssertNil(PingTest.target("10.0.0.1; rm -rf ~"))
        XCTAssertNil(PingTest.target("호스트"))
    }

    func testCommandsBindIntranetDevice() async {
        let runner = FakeRunner()
        _ = await PingTest.ping("10.50.10.17", device: "en10", runner: runner)
        _ = await PingTest.trace("10.50.10.17", device: "en10", runner: runner)
        XCTAssertEqual(runner.calls.map(\.executable), ["ping", "traceroute"])
        XCTAssertEqual(runner.calls[0].arguments, ["-c", "5", "-i", "0.2", "-W", "1000", "-b", "en10", "10.50.10.17"])
        XCTAssertEqual(runner.calls[1].arguments, ["-I", "-n", "-w", "1", "-q", "1", "-m", "30", "-i", "en10", "10.50.10.17"])
        // 이상한 장치 이름이면 명령을 돌리지 않는다
        let before = runner.calls.count
        let bad = await PingTest.ping("10.0.0.1", device: "en10 -x", runner: runner)
        XCTAssertEqual(bad.summary.lossPercent, 100)
        let badTrace = await PingTest.trace("10.0.0.1", device: "", runner: runner)
        XCTAssertNil(badTrace)
        XCTAssertEqual(runner.calls.count, before)
    }

    func testParseTrace() {
        let text = """
        traceroute to 1.1.1.1 (1.1.1.1), 8 hops max, 48 byte packets
         1  192.168.0.1  13.235 ms
         2  *
         3  *
         4  198.51.100.185  9.686 ms
         5  10.0.0.9  1.2 ms !H
        """
        let hops = PingTest.parseTrace(text)
        XCTAssertEqual(hops.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(hops[0], TraceHop(number: 1, address: "192.168.0.1", ms: 13.235))
        XCTAssertEqual(hops[1], TraceHop(number: 2, address: nil, ms: nil))
        XCTAssertEqual(hops[3].address, "198.51.100.185")
        XCTAssertEqual(hops[4].ms, 1.2)
    }

    func testTraceFailures() async {
        // 실제 오류 출력: 이름 못 풂 · 장치 없음 → nil (stderr 만, 홉 없음)
        let runner = FakeRunner()
        runner.scripted["traceroute -I -n -w 1 -q 1 -m 30 -i en10 nosuchhost.invalid"] =
            CommandResult(exitCode: 1, stderr: "traceroute: unknown host nosuchhost.invalid\n")
        let unknown = await PingTest.trace("nosuchhost.invalid", device: "en10", runner: runner)
        XCTAssertNil(unknown)
        runner.scripted["traceroute -I -n -w 1 -q 1 -m 30 -i en99 10.0.0.1"] =
            CommandResult(exitCode: 1, stderr: "traceroute: Can't find interface en99\n")
        let noDevice = await PingTest.trace("10.0.0.1", device: "en99", runner: runner)
        XCTAssertNil(noDevice)
        XCTAssertTrue(PingTest.parseTrace("").isEmpty)
    }

    func testPingResolveFailed() async {
        let runner = FakeRunner()
        runner.scripted["ping -c 5 -i 0.2 -W 1000 -b en10 nosuchhost.invalid"] =
            CommandResult(exitCode: 68, stderr: "ping: cannot resolve nosuchhost.invalid: Unknown host\n")
        let result = await PingTest.ping("nosuchhost.invalid", device: "en10", runner: runner)
        XCTAssertTrue(result.resolveFailed)
        XCTAssertNil(result.summary.averageMs)
    }

    /// 앞 15홉만 보이고 나머지는 [더보기] — 15홉 이하면 그대로
    func testVisibleHops() {
        let hops = (1...22).map { TraceHop(number: $0, address: "10.0.0.\($0)", ms: 1) }
        let folded = PingTest.visibleHops(hops, expanded: false)
        XCTAssertEqual(folded.shown.map(\.number), Array(1...15))
        XCTAssertEqual(folded.hidden, 7)
        XCTAssertEqual(PingTest.visibleHops(hops, expanded: true).shown.count, 22)
        XCTAssertEqual(PingTest.visibleHops(hops, expanded: true).hidden, 0)
        let short = Array(hops.prefix(15))
        XCTAssertEqual(PingTest.visibleHops(short, expanded: false).hidden, 0)
        XCTAssertEqual(PingTest.visibleHops([], expanded: false).shown, [])
        XCTAssertFalse(PingTest.visibleHops(short, expanded: false).foldable)
        XCTAssertTrue(PingTest.visibleHops(hops, expanded: true).foldable, "펼친 뒤에도 [접기]")
    }

    /// 끝의 * 가 2개 이상이면 한 줄로 — 중간 * 와 끝의 * 하나는 그대로, 묶고 남은 것만 15홉 접기
    func testTrailingSilentHops() {
        let star = { (n: Int) in TraceHop(number: n, address: nil, ms: nil) }
        let hop = { (n: Int) in TraceHop(number: n, address: "10.0.0.\(n)", ms: 1) }
        // 2026-10-15 223.130.x: 1 응답 · 2–3 * · 4 응답 · 5–6 * · 7 응답 · 8–30 *
        let hops = [hop(1), star(2), star(3), hop(4), star(5), star(6), hop(7)] + (8...30).map(star)
        let visible = PingTest.visibleHops(hops, expanded: false)
        XCTAssertEqual(visible.shown.map(\.number), Array(1...7), "중간 * 는 그대로")
        XCTAssertEqual(visible.silent, 8...30)
        XCTAssertEqual(visible.silent?.count, 23)
        XCTAssertEqual(visible.hidden, 0)
        XCTAssertFalse(visible.foldable, "묶고 나면 7홉 — [더보기] 없음")

        let oneStar = PingTest.visibleHops([hop(1), hop(2), star(3)], expanded: false)
        XCTAssertNil(oneStar.silent, "끝의 * 하나는 그대로")
        XCTAssertEqual(oneStar.shown.count, 3)

        let allStars = PingTest.visibleHops((1...30).map(star), expanded: false)
        XCTAssertEqual(allStars.shown, [])
        XCTAssertEqual(allStars.silent, 1...30)

        let long = PingTest.visibleHops((1...20).map(hop) + (21...30).map(star), expanded: false)
        XCTAssertEqual(long.shown.map(\.number), Array(1...15))
        XCTAssertEqual(long.hidden, 5)
        XCTAssertEqual(long.silent, 21...30)
    }

    /// [복사] 텍스트: 대상·장치·응답·경로 전부 (접힌 홉도)
    func testReportText() {
        var result = PingTestResult(target: "1.1.1.1", device: "en0", at: Date(timeIntervalSince1970: 0))
        result.summary = PingSummary(averageMs: 29.9, lossPercent: 0, jitterMs: 25)
        result.hops = (1...17).map { TraceHop(number: $0, address: $0 == 3 ? nil : "10.0.0.\($0)", ms: $0 == 3 ? nil : 1.5) }
        let text = result.reportText
        XCTAssertTrue(text.hasPrefix("ping 1.1.1.1 · en0 · "), text)
        XCTAssertTrue(text.contains("응답: 29.9 ms · Jitter 25.0 ms (5회)"), text)
        XCTAssertTrue(text.contains("  3  *  응답 없음"), text)
        XCTAssertTrue(text.contains(" 17  10.0.0.17  1.5 ms"), text)
        var unknown = PingTestResult(target: "nope", device: "en0")
        unknown.resolveFailed = true
        XCTAssertTrue(unknown.reportText.hasSuffix("응답: 이름을 찾지 못했습니다"))
    }
}
