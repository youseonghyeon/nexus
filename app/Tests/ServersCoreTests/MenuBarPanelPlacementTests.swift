// 메뉴바 패널 자리: 아이콘 아래 · 화면 오른쪽/왼쪽 끝 · 내용이 화면보다 길 때 · 원점이 음수인 바깥 화면.

import XCTest
@testable import ServersCore

final class MenuBarPanelPlacementTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 70, width: 1512, height: 878)          // 메뉴바 아래 ~ Dock 위
    private let size = CGSize(width: 300, height: 400)

    func testBelowIconLeftAligned() {
        let anchor = CGRect(x: 900, y: 948, width: 30, height: 34)
        let frame = MenuBarPanelPlacement.frame(anchor: anchor, content: size, visible: visible)
        XCTAssertEqual(frame, CGRect(x: 900, y: 948 - 6 - 400, width: 300, height: 400))
    }

    /// 아이콘이 오른쪽 끝에 있으면 패널을 왼쪽으로 밀어 화면 안에 둔다
    func testClampsToRightEdge() {
        let anchor = CGRect(x: 1470, y: 948, width: 30, height: 34)
        let frame = MenuBarPanelPlacement.frame(anchor: anchor, content: size, visible: visible)
        XCTAssertEqual(frame.maxX, 1512 - 8)
        XCTAssertEqual(frame.width, 300)
    }

    func testClampsToLeftEdge() {
        let anchor = CGRect(x: 2, y: 948, width: 30, height: 34)
        XCTAssertEqual(MenuBarPanelPlacement.frame(anchor: anchor, content: size, visible: visible).minX, 8)
    }

    /// 내용이 화면보다 길면 위는 그대로 두고 아래를 화면 안에서 끊는다 (패널 안에서 스크롤)
    func testTallContentIsCappedKeepingTop() {
        let anchor = CGRect(x: 900, y: 948, width: 30, height: 34)
        let frame = MenuBarPanelPlacement.frame(anchor: anchor, content: CGSize(width: 300, height: 2000), visible: visible)
        XCTAssertEqual(frame.maxY, 942)
        XCTAssertEqual(frame.minY, 78)
    }

    /// 왼쪽·아래에 붙은 바깥 화면은 원점이 음수다
    func testSecondScreenWithNegativeOrigin() {
        let second = CGRect(x: -1920, y: -200, width: 1920, height: 1055)
        let anchor = CGRect(x: -40, y: 855, width: 30, height: 25)
        let frame = MenuBarPanelPlacement.frame(anchor: anchor, content: size, visible: second)
        XCTAssertEqual(frame.maxX, -8)
        XCTAssertEqual(frame.maxY, 849)
        XCTAssertTrue(second.contains(frame))
    }

    /// 전체 화면에서 내려온 메뉴바: 쓸 수 있는 영역이 화면 전체라 아이콘이 그 안에 있다 — 그래도 아이콘 아래
    func testIconInsideVisibleArea() {
        let full = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let anchor = CGRect(x: 900, y: 948, width: 30, height: 34)
        XCTAssertEqual(MenuBarPanelPlacement.frame(anchor: anchor, content: size, visible: full).maxY, 942)
    }

    /// 화면이 패널보다 좁거나 자리가 없어도 음수 크기가 나오지 않는다
    func testNoRoom() {
        let tiny = CGRect(x: 0, y: 0, width: 200, height: 10)
        let frame = MenuBarPanelPlacement.frame(anchor: CGRect(x: 50, y: 10, width: 30, height: 24), content: size, visible: tiny)
        XCTAssertEqual(frame.height, 0)
        XCTAssertEqual(frame.width, 184)
    }
}
