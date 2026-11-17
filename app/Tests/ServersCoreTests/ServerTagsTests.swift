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
        XCTAssertEqual(live.promptTag, "LIVE,DB")
        let bare = try XCTUnwrap(ServerConfigParser.parse(base).server("a"))
        XCTAssertFalse(bare.isProd)
        XCTAssertEqual(bare.promptTag, "DEV", "태그가 없으면 프롬프트는 DEV")
    }

    func testPromptColorFollowsStrongestTag() {
        XCTAssertTrue(SessionTheme.remoteRC(environment: "PROD,DB").contains(TerminalPalette.rosePine.prodColor))
        XCTAssertTrue(SessionTheme.remoteRC(environment: "DB,stg").contains(TerminalPalette.rosePine.stagingColor))
        XCTAssertTrue(SessionTheme.remoteRC(environment: "DEV").contains(TerminalPalette.rosePine.devColor))
        XCTAssertTrue(SessionTheme.remoteRC(environment: "PROD,DB").contains("PROD,DB"), "프롬프트 글자는 태그 그대로")
        XCTAssertTrue(SessionTheme.remoteRC(environment: "DEV,Forward Proxy").contains("DEV,Forward Proxy"), "공백 든 태그도 붙지 않게")
        XCTAssertFalse(SessionTheme.remoteRC(environment: "a'b").contains("a'b"), "작은따옴표는 여전히 뺀다")
    }

    func testPromptLabelKeepsOnlySafeCharacters() throws {
        let rc = SessionTheme.remoteRC(environment: "PROD,x'$(rm -rf y)`id`\\")
        XCTAssertFalse(rc.contains("$(rm"), "명령 치환이 프롬프트에 들어가지 않는다")
        XCTAssertTrue(rc.contains(TerminalPalette.rosePine.prodColor), "운영 색은 그대로")
        // rcfile 자체가 bash 문법으로 깨지지 않는다 (' 가 PS1 작은따옴표를 닫지 않게)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = ["-n"]
        let pipe = Pipe(); p.standardInput = pipe
        try p.run(); pipe.fileHandleForWriting.write(rc.data(using: .utf8)!); try pipe.fileHandleForWriting.close(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }

    func testMultiTagPromptIsValidBash() throws {
        let full = SessionTheme.remoteShellCommand(environment: "PROD,DB")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = ["-n", "-c", full]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }
}
