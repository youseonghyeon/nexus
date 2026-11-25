import XCTest
@testable import ServersCore

final class BrowserHistoryTests: XCTestCase {
    func testCanGoBackTable() {
        // (started, showingStart, historyHasBack) → 뒤로 가능
        let table: [(Bool, Bool, Bool, Bool, String)] = [
            (false, false, false, false, "연결 중 — 시작 페이지를 못 띄웠다"),
            (false, false, true, false, "연결 중에는 기록이 있어도 안 간다"),
            (true, true, false, false, "첫 시작 페이지 — 앞이 없다"),
            (true, true, true, true, "집 버튼으로 온 시작 페이지 — 보던 페이지로 돌아간다"),
            (true, false, true, true, "웹 페이지 — 앞 항목으로"),
            (true, false, false, true, "기록 없이 뜬 화면(오류 페이지) — 시작 페이지로"),
        ]
        for (started, start, back, expected, note) in table {
            XCTAssertEqual(BrowserHistory.canGoBack(started: started, showingStart: start, historyHasBack: back), expected, note)
        }
    }
}
