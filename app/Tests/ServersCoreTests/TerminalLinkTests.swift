import Foundation
@testable import ServersCore
import XCTest

/// 터미널 ⌘+클릭: 보이는 화면 글자에서 누른 칸의 URL 찾기 (꺾인 줄 잇기 포함)
final class TerminalLinkTests: XCTestCase {
    private func url(_ rows: [String], columns: Int = 40, row: Int = 0, column: Int) -> String? {
        TerminalLink.url(rows: rows, columns: columns, row: row, column: column)
    }

    // MARK: 한 줄

    func testClickAnywhereOnURL() {
        let rows = ["open https://a.com/x now"]   // URL 은 5…21 칸
        XCTAssertEqual(url(rows, column: 5), "https://a.com/x", "첫 글자")
        XCTAssertEqual(url(rows, column: 12), "https://a.com/x")
        XCTAssertEqual(url(rows, column: 19), "https://a.com/x", "마지막 글자")
    }

    func testClickOutsideURLIsNil() {
        let rows = ["open https://a.com/x now"]
        XCTAssertNil(url(rows, column: 4), "URL 앞 공백")
        XCTAssertNil(url(rows, column: 20), "URL 뒤 공백")
        XCTAssertNil(url(rows, column: 1), "URL 아닌 낱말")
        XCTAssertNil(url(rows, column: 35), "글자 없는 칸")
    }

    func testOutOfRangeIsNil() {
        XCTAssertNil(url([], column: 0), "빈 화면")
        XCTAssertNil(url(["https://a.com"], row: 3, column: 0), "없는 줄")
        XCTAssertNil(url(["https://a.com"], column: 40), "칸 수 밖")
        XCTAssertNil(url(["https://a.com"], column: -1))
        XCTAssertNil(TerminalLink.url(rows: ["https://a.com"], columns: 0, row: 0, column: 0), "크기를 아직 모르는 화면")
        XCTAssertNil(url([""], column: 0), "빈 줄")
    }

    func testPicksTheClickedOneOfTwo() {
        let rows = ["http://a.com https://b.com/y"]
        XCTAssertEqual(url(rows, column: 3), "http://a.com")
        XCTAssertEqual(url(rows, column: 20), "https://b.com/y")
    }

    func testTrailingPunctuationIsNotPartOfURL() {
        XCTAssertEqual(url(["see https://a.com/x."], column: 10), "https://a.com/x")
        XCTAssertNil(url(["see https://a.com/x."], column: 19), "마침표를 누르면 링크가 아니다")
        XCTAssertEqual(url(["(https://a.com/x), next"], column: 5), "https://a.com/x", "감싼 괄호·쉼표는 뺀다")
        XCTAssertNil(url(["(https://a.com/x)"], column: 0), "여는 괄호를 누르면 링크가 아니다")
        XCTAssertEqual(url(["https://en.wikipedia.org/wiki/A_(b)"], column: 5), "https://en.wikipedia.org/wiki/A_(b)", "짝이 맞는 괄호는 URL 의 일부")
        XCTAssertEqual(url(["\"https://a.com/x\""], column: 5), "https://a.com/x", "따옴표에서 끊긴다")
    }

    func testQueryWithNestedURLStaysWhole() {
        let link = "https://a.com/cb?next=https://b.com/z"
        XCTAssertEqual(url([link], column: 30), link, "뒤쪽 스킴에서 새 URL 로 자르지 않는다")
    }

    func testOnlyHTTPSchemes() {
        XCTAssertNil(url(["file:///etc/passwd"], column: 3), "서버가 찍은 다른 스킴은 열지 않는다")
        XCTAssertNil(url(["ssh://root@host"], column: 3))
        XCTAssertNil(url(["https://"], column: 3), "호스트 없는 주소")
    }

    func testNonASCIIEndsURL() {
        XCTAssertEqual(url(["│https://a.com/x│"], column: 5), "https://a.com/x", "선 문자에 붙어 있어도")
        XCTAssertEqual(url(["주소https://a.com/x입니다"], column: 8), "https://a.com/x", "한글은 두 칸 — 주소(4칸) 뒤 4…18 칸이 URL")
        XCTAssertNil(url(["주소https://a.com/x입니다"], column: 3), "한글의 둘째 칸")
        XCTAssertNil(url(["주소https://a.com/x입니다"], column: 19), "URL 뒤 한글")
    }

    // MARK: 꺾인 줄

    /// Claude Code 로그인 화면 모양: 안내는 들여 쓰고 URL 은 첫 칸부터 폭을 꽉 채워 네 줄 (2026-11-15 안 열린 화면)
    private let wrapped = [
        "  Browser didn't open? Use the url below",
        "",
        "https://claude.com/cai/oauth/authorize?c",
        "ode=true&client_id=0a1b2c3d&redirect_uri",
        "=https%3A%2F%2Fplatform.claude.com&state",
        "=AbCd1234",
        "",
        "  Hold Shift while selecting",
    ]
    private let whole = "https://claude.com/cai/oauth/authorize?code=true&client_id=0a1b2c3d&redirect_uri=https%3A%2F%2Fplatform.claude.com&state=AbCd1234"

    func testWrappedURLFromEveryRow() {
        for row in 2...5 {
            XCTAssertEqual(url(wrapped, row: row, column: 3), whole, "\(row)번째 줄 어디를 눌러도 전체 주소")
        }
        XCTAssertEqual(url(wrapped, row: 2, column: 39), whole, "줄의 마지막 칸")
        XCTAssertEqual(url(wrapped, row: 3, column: 0), whole, "이어진 줄의 첫 칸")
    }

    func testWrappedURLDoesNotSwallowNeighbours() {
        XCTAssertNil(url(wrapped, row: 5, column: 20), "마지막 줄의 URL 뒤 빈 칸")
        XCTAssertNil(url(wrapped, row: 0, column: 10), "위 안내 줄")
        XCTAssertNil(url(wrapped, row: 7, column: 10), "아래 안내 줄(들여 쓴 줄은 잇지 않는다)")
        XCTAssertNil(url(wrapped, row: 1, column: 0), "빈 줄")
    }

    func testFullRowFollowedByIndentedRowIsNotJoined() {
        let rows = ["https://a.com/" + String(repeating: "a", count: 26), "  next line"]
        XCTAssertEqual(url(rows, column: 3), rows[0], "다음 줄이 공백으로 시작하면 거기서 끝")
    }

    func testShortRowIsNotJoined() {
        let rows = ["https://a.com/x", "tail"]
        XCTAssertEqual(url(rows, column: 3), "https://a.com/x", "마지막 칸까지 차지 않은 줄은 잇지 않는다")
        XCTAssertNil(url(rows, row: 1, column: 1))
    }

    func testFullRowOfTextBeforeURLRow() {
        let rows = [String(repeating: "x", count: 40), "https://a.com/x"]
        XCTAssertEqual(url(rows, row: 1, column: 3), "https://a.com/x", "앞줄에서 이어 붙은 글자는 URL 에 넣지 않는다")
        XCTAssertNil(url(rows, row: 0, column: 3), "앞줄(스킴 앞)을 누르면 링크가 아니다")
    }

    func testWideCharactersKeepColumns() {
        // "한글 " = 5칸, URL 이 5…39 칸을 채우고 다음 줄로 이어짐
        let rows = ["한글 https://a.com/" + String(repeating: "b", count: 21), "cc"]
        XCTAssertEqual(url(rows, column: 5), "https://a.com/" + String(repeating: "b", count: 21) + "cc")
        XCTAssertEqual(url(rows, row: 1, column: 1), "https://a.com/" + String(repeating: "b", count: 21) + "cc")
    }

    // MARK: 점 → 칸

    func testCellFromPoint() {
        func cell(_ x: Double, _ y: Double) -> [Int]? {
            TerminalLink.cell(x: x, y: y, paddingX: 8, paddingY: 6, cellWidth: 8, cellHeight: 17, columns: 85, rows: 22).map { [$0.row, $0.column] }
        }
        XCTAssertEqual(cell(8, 6), [0, 0], "여백 바로 안")
        XCTAssertEqual(cell(15.9, 22.9), [0, 0])
        XCTAssertEqual(cell(16, 23), [1, 1], "칸 경계는 다음 칸")
        XCTAssertEqual(cell(8 + 85 * 8 - 0.1, 6 + 22 * 17 - 0.1), [21, 84], "마지막 칸")
        XCTAssertNil(cell(7.9, 10), "왼쪽 여백")
        XCTAssertNil(cell(10, 5.9), "위 여백")
        XCTAssertNil(cell(8 + 85 * 8, 10), "오른쪽 남는 자리")
        XCTAssertNil(cell(10, 6 + 22 * 17), "아래 남는 자리")
        XCTAssertNil(TerminalLink.cell(x: 10, y: 10, paddingX: 8, paddingY: 6, cellWidth: 0, cellHeight: 0, columns: 85, rows: 22), "크기를 아직 모르는 화면")
    }
}
