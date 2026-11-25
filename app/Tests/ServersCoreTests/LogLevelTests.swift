import XCTest
@testable import ServersCore

final class LogLevelTests: XCTestCase {
    /// 형식별 줄 표: 레벨이 적히는 자리만 본다
    func testDetectByFormat() {
        let table: [(String, LogLevel?)] = [
            // klog
            ("I1124 19:38:19.931798 maintenance_scanner.go:183 Topology discovery: 1 volume servers", .info),
            ("W1124 19:38:19.931798 volume.go:12 slow heartbeat", .warning),
            ("E1124 19:38:19.931798 volume.go:12 connect failed", .error),
            ("F1124 19:38:19.931798 main.go:1 cannot start", .error),
            // 키-값 · JSON
            (#"ts=2026-11-24T20:08:19Z level=error caller=main.go:12 msg="scrape failed""#, .error),
            (#"time="2026-11-24T20:08:19Z" level=warning msg="retrying""#, .warning),
            (#"{"level":"info","ts":1732450000,"msg":"started"}"#, .info),
            (#"{"ts":1732450000, "severity": "ERROR", "msg":"boom"}"#, .error),
            ("t=2026-11-24 lvl=dbg msg=tick", .debug),
            // 줄 앞쪽 토큰
            ("2026-11-24 20:08:19,123 ERROR [main] com.example.App - failed to bind", .error),
            ("2026-11-24T20:08:19+0900 host app[123]: WARN  pool exhausted", .warning),
            ("2026-11-24 20:08:19.123 UTC [77] LOG:  checkpoint starting", .info),
            ("2026-11-24 20:08:19.123 UTC [77] FATAL:  password authentication failed", .error),
            ("2026/11/24 20:08:19 [error] 31#31: *1 connect() failed", .error),
            ("2026/11/24 20:08:19 [notice] 1#1: start worker processes", .info),
            ("8:08PM DBG polling", .debug),
            ("[WARNING] deprecated option", .warning),
            // 레벨이 아닌 것 — 본문 속 낱말 · 식별자
            ("Maintenance scan completed: no error, 0 errors", nil),
            ("2026-11-24T20:08:19+0900 host app[123]: request finished without warning", nil),
            ("loaded ERROR_CODE table", nil),
            ("GET /api/error 200", nil),
            ("", nil),
        ]
        for (line, expected) in table {
            XCTAssertEqual(LogLevel.detect(line), expected, line)
        }
    }

    /// 먼저 나온 레벨 토큰이 이긴다 — info 줄이 본문의 ERROR 로 빨개지지 않는다
    func testFirstTokenWins() {
        XCTAssertEqual(LogLevel.detect("2026-11-24 20:08:19 INFO upstream returned ERROR 3 times"), .info)
    }

    /// 줄 앞쪽을 지난 자리의 토큰은 보지 않는다
    func testTokenBeyondHeadIsIgnored() {
        let line = String(repeating: "x", count: LogLevel.headLength) + " ERROR late"
        XCTAssertNil(LogLevel.detect(line))
    }

    /// 스택 트레이스: 들여쓴 줄 · Caused by 는 앞줄을 물려받고, 새 줄에서 끊긴다
    func testContinuationInheritsPreviousLevel() {
        let lines = [
            "2026-11-24 20:08:19 INFO started",
            "2026-11-24 20:08:20 ERROR request failed",
            "java.lang.IllegalStateException: boom",
            "\tat com.example.App.run(App.java:12)",
            "Caused by: java.io.IOException: closed",
            "    at com.example.Net.read(Net.java:3)",
            "",
            "2026-11-24 20:08:21 INFO recovered",
            "  indented after info",
        ]
        XCTAssertEqual(LogLevel.resolve(lines), [.info, .error, nil, nil, nil, nil, nil, .info, .info])
    }

    /// 레벨 없는 첫 줄 뒤의 들여쓴 줄은 그대로 없음, 오류 바로 뒤의 들여쓴 줄은 오류
    func testContinuationRightAfterError() {
        XCTAssertEqual(LogLevel.resolve(["  orphan", "E1124 20:08:19.1 a.go:1 x", "  detail", "\t"]), [nil, .error, .error, nil])
    }
}
