// ServerTerminalTheme: 서버별 터미널 테마 — 우선순위 · 저장 표 · 팔레트 꼴.

import XCTest
@testable import ServersCore

final class ServerTerminalThemeTests: XCTestCase {
    func testFindIgnoresUnknownIDs() {
        XCTAssertEqual(ServerTerminalTheme.find("paper"), .paper)
        XCTAssertNil(ServerTerminalTheme.find(nil))
        XCTAssertNil(ServerTerminalTheme.find(""))
        XCTAssertNil(ServerTerminalTheme.find("solarized"), "목록 밖(지운 테마 · 손으로 고친 값)은 고르지 않은 것")
        XCTAssertEqual(Set(ServerTerminalTheme.all.map(\.id)).count, ServerTerminalTheme.all.count, "id 가 겹치지 않는다")
    }

    func testStoredTable() {
        var stored = ServerTerminalTheme.setting("graphite", for: "web", in: [:])
        XCTAssertEqual(stored, ["web": "graphite"])
        stored = ServerTerminalTheme.setting("paper", for: "db", in: stored)
        XCTAssertEqual(ServerTerminalTheme.setting(nil, for: "web", in: stored), ["db": "paper"], "풀면 그 서버의 값만 지운다")
        XCTAssertEqual(ServerTerminalTheme.setting("nope", for: "web", in: stored), ["db": "paper"], "모르는 id 는 푼 것으로")
        // 이름 변경: 값이 따라간다 · 옛 값이 없으면 새 이름에 남아 있던 값도 지운다 (지운 서버의 것이 살아나지 않게)
        XCTAssertEqual(ServerTerminalTheme.renaming(from: "web", to: "front", in: stored), ["front": "graphite", "db": "paper"])
        XCTAssertEqual(ServerTerminalTheme.renaming(from: "cache", to: "db", in: stored), ["web": "graphite"])
        XCTAssertEqual(ServerTerminalTheme.removing("web", from: stored), ["db": "paper"])
        XCTAssertEqual(ServerTerminalTheme.removing("none", from: stored), stored)
    }

    /// 용도가 색으로 읽혀야 한다: 운영은 붉은 바탕 · 스테이징은 푸른 바탕 · 눈이 편한 색은 대비가 낮고 따뜻하다. 바탕색은 테마마다 다르다.
    func testPurposeThemesReadByColor() {
        func rgb(_ hex: String) -> (r: Int, g: Int, b: Int) {
            let v = Int(hex.dropFirst(), radix: 16) ?? 0
            return ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
        }
        XCTAssertEqual(ServerTerminalTheme.all.map(\.id), ["graphite", "paper", "dusk", "harbor", "redline"], "기본 다음 순서 — 2행 3열 (윗줄 베이스 · 아랫줄 용도)")
        XCTAssertEqual(Set(ServerTerminalTheme.all.map(\.palette.background)).count, ServerTerminalTheme.all.count)
        let red = rgb(ServerTerminalTheme.redline.palette.background), blue = rgb(ServerTerminalTheme.harbor.palette.background)
        XCTAssertGreaterThan(red.r, red.g + 20); XCTAssertGreaterThan(red.r, red.b + 20)
        XCTAssertGreaterThan(blue.b, blue.r + 20); XCTAssertGreaterThan(blue.b, blue.g)
        // 붉은 바탕 위의 오류 글자(ANSI 빨강 1 · 9)는 바탕과 뚜렷이 달라야 한다 — 초록 성분을 올려 주황 쪽으로
        for index in [1, 9] {
            let c = rgb(ServerTerminalTheme.redline.palette.colors[index])
            XCTAssertGreaterThan(c.g, 130, "Redline 의 글자용 빨강 \(index) 은 주황 쪽")
            XCTAssertGreaterThan(c.r - red.r, 150)
        }
        // 눈이 편한 색: 글자가 순백이 아니고(가장 밝은 15 번도), 바탕 · 글자 모두 파랑이 가장 약하다
        let dusk = ServerTerminalTheme.dusk.palette
        for hex in [dusk.background, dusk.foreground, dusk.colors[15]] {
            let c = rgb(hex)
            XCTAssertLessThan(c.b, c.r, hex); XCTAssertLessThan(c.b, c.g, hex); XCTAssertLessThan(c.r, 235, hex)
        }
    }

    /// 팔레트는 터미널 설정에 그대로 들어간다 — 꼴이 틀리면 그 색만 조용히 빠진다
    func testPalettesAreWellFormed() {
        func isHex(_ s: String) -> Bool { s.count == 7 && s.hasPrefix("#") && s.dropFirst().allSatisfy(\.isHexDigit) }
        func luminance(_ hex: String) -> Double {
            let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
            return (0.2126 * Double((v >> 16) & 0xFF) + 0.7152 * Double((v >> 8) & 0xFF) + 0.0722 * Double(v & 0xFF)) / 255
        }
        for theme in ServerTerminalTheme.all {
            let p = theme.palette
            XCTAssertEqual(p.colors.count, 16, theme.id)
            XCTAssertTrue(([p.background, p.foreground, p.cursor] + p.colors).allSatisfy(isHex), theme.id)
            // 바탕과 글자가 충분히 떨어져 있다 (어두운 테마 · 밝은 테마 모두). ANSI 색(1–6 · 9–14)도 바탕에 묻히지 않는다
            XCTAssertGreaterThan(abs(luminance(p.foreground) - luminance(p.background)), 0.5, theme.id)
            for index in Array(1...6) + Array(9...14) {
                XCTAssertGreaterThan(abs(luminance(p.colors[index]) - luminance(p.background)), 0.2, "\(theme.id) 색 \(index)")
            }
        }
        for dark in [ServerTerminalTheme.graphite, .dusk, .harbor, .redline] { XCTAssertLessThan(luminance(dark.palette.background), 0.2, "\(dark.id) 는 어두운 테마") }
        XCTAssertGreaterThan(luminance(ServerTerminalTheme.paper.palette.background), 0.8, "Paper 는 밝은 테마")
        // 밝은 테마의 '밝은 흰색'(15)은 바탕에서 읽혀야 한다 — 굵은 흰 글자를 쓰는 프로그램이 많다
        XCTAssertGreaterThan(abs(luminance(ServerTerminalTheme.paper.palette.colors[15]) - luminance(ServerTerminalTheme.paper.palette.background)), 0.5)
    }
}
