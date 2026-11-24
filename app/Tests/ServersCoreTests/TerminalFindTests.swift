// TerminalFind: ⌘F · ⌘G · ⌘⇧G 판정과 Ghostty 에 넘길 동작 이름.

import XCTest
@testable import ServersCore

final class TerminalFindTests: XCTestCase {
    func testKeysOnlyWhenTerminalIsVisible() {
        for key in [TerminalFind.Key.find, .next, .previous] {
            XCTAssertNil(TerminalFind.command(for: key, terminalVisible: false, finding: false), "Dashboard · 브라우저 탭이면 키를 흘린다")
            XCTAssertNil(TerminalFind.command(for: key, terminalVisible: false, finding: true), "찾기를 열어 둔 채 다른 탭으로 갔어도 흘린다")
        }
    }

    func testFindOpensAndNextPreviousStepWhileFinding() {
        XCTAssertEqual(TerminalFind.command(for: .find, terminalVisible: true, finding: false), .open)
        XCTAssertEqual(TerminalFind.command(for: .find, terminalVisible: true, finding: true), .open, "열려 있으면 칸으로 포커스")
        XCTAssertEqual(TerminalFind.command(for: .next, terminalVisible: true, finding: true), .next)
        XCTAssertEqual(TerminalFind.command(for: .previous, terminalVisible: true, finding: true), .previous)
        XCTAssertEqual(TerminalFind.command(for: .next, terminalVisible: true, finding: false), .open, "찾는 중이 아니면 ⌘G 도 찾기 칸을 연다")
        XCTAssertEqual(TerminalFind.command(for: .previous, terminalVisible: true, finding: false), .open)
    }

    func testSearchAction() {
        XCTAssertEqual(TerminalFind.searchAction("error"), "search:error")
        XCTAssertEqual(TerminalFind.searchAction(""), "end_search", "빈 글자면 찾기를 끝낸다")
        XCTAssertEqual(TerminalFind.searchAction("GET /api: 500"), "search:GET /api: 500", "콜론 · 공백은 그대로")
        XCTAssertEqual(TerminalFind.searchAction(" "), "search: ", "공백 하나도 찾을 글자다")
        XCTAssertEqual(TerminalFind.searchAction("a\nb\r\nc"), "search:a b c", "붙여 넣은 줄바꿈은 공백으로")
        XCTAssertEqual(TerminalFind.searchAction("한글 로그"), "search:한글 로그")
    }
}
