// ServerTags: 태그 색 표 (운영 빨강 · 스테이징 파랑 · 그 밖 없음) · 쉼표 여러 개 · 운영 판정 · 프롬프트 색.

import XCTest
@testable import ServersCore

final class ServerTagsTests: XCTestCase {
    func testToneTable() {
        for tag in ["PROD", "PRD", "PRODUCTION", "LIVE", "REAL", "DR", "CANARY"] {
            XCTAssertEqual(ServerTags.tone(tag), .production, tag)
        }
        for tag in ["STG", "STAGE", "STAGING", "PREPROD", "PRE", "QA", "UAT", "SIT", "TEST", "TST", "PERF", "LOAD", "BETA"] {
            XCTAssertEqual(ServerTags.tone(tag), .staging, tag)
        }
        for tag in ["DEV", "LOCAL", "HOST", "PC", "VM", "DB", "WAS"] {
            XCTAssertEqual(ServerTags.tone(tag), .plain, tag)
        }
        XCTAssertEqual(ServerTags.tone("prod"), .production, "대소문자 무시")
        XCTAssertEqual(ServerTags.tone("Stg"), .staging)
    }

    func testParseCommaSeparated() {
        XCTAssertEqual(ServerTags.parse("PROD, db ,,prod"), ["PROD", "db"], "순서·대소문자 그대로, 빈 항목·중복은 뺀다")
        XCTAssertEqual(ServerTags.parse("HOST"), ["HOST"])
        XCTAssertEqual(ServerTags.parse(nil), [])
        XCTAssertEqual(ServerTags.parse(" , "), [])
        XCTAssertEqual(ServerTags.parse("DEV, Forward Proxy"), ["DEV", "Forward Proxy"], "태그 안 공백은 그대로 (2026-10-06 web)")
        XCTAssertEqual(ServerTags.parse("  Forward   Proxy ,dev"), ["Forward Proxy", "dev"], "앞뒤는 떼고 안쪽 여러 칸은 한 칸")
        // 쉼표 없이 "PROD DB" 로 적으면 한 태그지만 색은 낱말마다 본다 — 운영을 놓치지 않게
        XCTAssertEqual(ServerTags.parse("PROD DB"), ["PROD DB"])
        XCTAssertEqual(ServerTags.tone("PROD DB"), .production)
        XCTAssertEqual(ServerTags.tone("db stg"), .staging)
        XCTAssertEqual(ServerTags.tone("Forward Proxy"), .plain)
    }

    func testStrongestAndProd() throws {
        XCTAssertEqual(ServerTags.strongest(["DB", "STG", "PROD"]), .production)
        XCTAssertEqual(ServerTags.strongest(["DB", "qa"]), .staging)
        XCTAssertEqual(ServerTags.strongest([]), .plain)
        let base = "[a]\ngroup=g\nnetwork=tailscale\ntype=linux\nip=1.1.1.1\nuser=u\nport=22\n"
        let live = try XCTUnwrap(ServerConfigParser.parse(base + "env=LIVE, DB\n").server("a"))
        XCTAssertEqual(live.tags, ["LIVE", "DB"])
        XCTAssertTrue(live.isProd, "PROD 가 아니어도 운영 태그면 운영 서버")
        let bare = try XCTUnwrap(ServerConfigParser.parse(base).server("a"))
        XCTAssertFalse(bare.isProd)
    }
}
