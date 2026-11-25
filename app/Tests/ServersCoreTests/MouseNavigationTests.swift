import XCTest
@testable import ServersCore

final class MouseNavigationTests: XCTestCase {
    private func action(_ button: Int, main: Bool = true, sheet: Bool = false, browser: Bool = true, back: Bool = true, forward: Bool = true) -> MouseNavigation.Action? {
        MouseNavigation.action(MouseNavigation.direction(button: button), mainWindow: main, sheetOpen: sheet, browserVisible: browser, canGoBack: back, canGoForward: forward)
    }

    func testSideButtonsOnBrowserTab() {
        XCTAssertEqual(action(3), .back)
        XCTAssertEqual(action(4), .forward)
    }

    /// 갈 곳이 없으면 삼킨다 (꺼진 버튼처럼) — 반대쪽 가능 여부와 섞이지 않는다
    func testNowhereToGoSwallows() {
        XCTAssertEqual(action(3, back: false, forward: true), .swallow)
        XCTAssertEqual(action(4, back: true, forward: false), .swallow)
    }

    /// 왼쪽 · 오른쪽 · 가운데 · 그 밖의 버튼은 건드리지 않는다
    func testOtherButtonsPassThrough() {
        for button in [0, 1, 2, 5, 6] { XCTAssertNil(action(button), "\(button)") }
    }

    /// 브라우저 탭이 아니거나(터미널 · Dashboard) · 본창이 아니거나 · 시트가 떠 있으면 흘린다
    func testPassThroughOutsideBrowser() {
        for button in [3, 4] {
            XCTAssertNil(action(button, browser: false))
            XCTAssertNil(action(button, main: false))
            XCTAssertNil(action(button, sheet: true))
        }
    }

    /// ⌘[ · ⌘] 만 — ⌘⇧[ · ⌘⇧](탭 이동)나 다른 조합 · 다른 키는 아니다
    func testCommandBrackets() {
        func direction(_ keyCode: UInt16, command: Bool = true, shift: Bool = false, option: Bool = false, control: Bool = false) -> MouseNavigation.Direction? {
            MouseNavigation.direction(keyCode: keyCode, command: command, shift: shift, option: option, control: control)
        }
        XCTAssertEqual(direction(33), .back)
        XCTAssertEqual(direction(30), .forward)
        for keyCode: UInt16 in [33, 30] {
            XCTAssertNil(direction(keyCode, command: false))
            XCTAssertNil(direction(keyCode, shift: true))
            XCTAssertNil(direction(keyCode, option: true))
            XCTAssertNil(direction(keyCode, control: true))
        }
        XCTAssertNil(direction(35))   // ⌘P
    }

    /// 키로 와도 판정은 같다: 브라우저 탭에서만, 갈 곳이 없으면 삼킨다, 터미널 탭이면 흘린다(터미널이 받는다)
    func testKeyUsesSameJudgement() {
        let back = MouseNavigation.direction(keyCode: 33, command: true, shift: false, option: false, control: false)
        XCTAssertEqual(MouseNavigation.action(back, mainWindow: true, sheetOpen: false, browserVisible: true, canGoBack: true, canGoForward: false), .back)
        XCTAssertEqual(MouseNavigation.action(back, mainWindow: true, sheetOpen: false, browserVisible: true, canGoBack: false, canGoForward: true), .swallow)
        XCTAssertNil(MouseNavigation.action(back, mainWindow: true, sheetOpen: false, browserVisible: false, canGoBack: true, canGoForward: true))
    }

    /// 쓸어 넘기기(Logi Options+ 의 옆 버튼 · 트랙패드): +1 뒤로 · −1 앞으로, 누를 때마다 먼저 오는 0 은 아무것도 아니다 — 한 번 누름에 한 번만 움직인다
    func testSwipe() {
        XCTAssertEqual(MouseNavigation.direction(swipeDeltaX: 1), .back)
        XCTAssertEqual(MouseNavigation.direction(swipeDeltaX: -1), .forward)
        XCTAssertNil(MouseNavigation.direction(swipeDeltaX: 0))
        // 찍힌 순서 그대로: 0, +1, 0, −1 → 뒤로 한 번 · 앞으로 한 번
        let actions = [0.0, 1, 0, -1].compactMap { MouseNavigation.action(MouseNavigation.direction(swipeDeltaX: $0), mainWindow: true, sheetOpen: false, browserVisible: true, canGoBack: true, canGoForward: true) }
        XCTAssertEqual(actions, [.back, .forward])
    }
}
