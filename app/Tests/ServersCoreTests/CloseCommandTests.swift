// ⌘W 판정: 본창은 탭 → 창 순, 시트·팝오버는 무시(뒤 탭을 닫지 않음), 설정 창은 그 창만.

import XCTest
@testable import ServersCore

final class CloseCommandTests: XCTestCase {
    func testMainWindowClosesTabThenHides() {
        XCTAssertEqual(CloseCommand.action(window: .main, hasVisibleTab: true), .closeTab)
        // 2026-10-07 버그: Dashboard(탭 없음)에서 ⌘W 가 아무 것도 안 했다
        XCTAssertEqual(CloseCommand.action(window: .main, hasVisibleTab: false), .hideMain)
    }

    /// 전체 화면에서 숨기면 빈 Space 가 남는다 — 탭만 닫고 창은 그대로
    func testFullScreenMainNeverHides() {
        XCTAssertEqual(CloseCommand.action(window: .mainFullScreen, hasVisibleTab: true), .closeTab)
        XCTAssertEqual(CloseCommand.action(window: .mainFullScreen, hasVisibleTab: false), .ignore)
    }

    /// 2026-10-07 버그: 시트가 떠 있으면 ⌘W 가 메뉴로 흘러 시트 뒤의 터미널 탭(셸)을 닫았다
    func testSheetNeverClosesTabBehindIt() {
        XCTAssertEqual(CloseCommand.action(window: .sheet, hasVisibleTab: true), .ignore)
        XCTAssertEqual(CloseCommand.action(window: .sheet, hasVisibleTab: false), .ignore)
    }

    /// 2026-10-07 버그: 설정 창에서 ⌘W 가 본창 탭을 닫거나(탭 있음) 아무 것도 안 했다(탭 없음)
    func testOtherClosableWindowClosesItselfOnly() {
        XCTAssertEqual(CloseCommand.action(window: .closable, hasVisibleTab: true), .closeWindow)
        XCTAssertEqual(CloseCommand.action(window: .closable, hasVisibleTab: false), .closeWindow)
    }

    func testPopoverAndNoKeyWindowIgnore() {
        for hasTab in [true, false] {
            XCTAssertEqual(CloseCommand.action(window: .other, hasVisibleTab: hasTab), .ignore)
            XCTAssertEqual(CloseCommand.action(window: .none, hasVisibleTab: hasTab), .ignore)
        }
    }
}
