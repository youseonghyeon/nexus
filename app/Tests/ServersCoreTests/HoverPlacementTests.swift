// HoverPlacement: 설명 팝업 자리 (화면 좌표, y 는 위로).

import XCTest
@testable import ServersCore

final class HoverPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let size = CGSize(width: 300, height: 100)

    func testBelowAnchorLeftAligned() {
        let origin = HoverPlacement.origin(anchor: CGRect(x: 200, y: 500, width: 12, height: 12), size: size, screen: screen)
        XCTAssertEqual(origin, CGPoint(x: 200, y: 500 - 6 - 100), "기준 바로 아래 · 왼쪽 맞춤")
    }

    func testFlipsAboveNearBottom() {
        let origin = HoverPlacement.origin(anchor: CGRect(x: 200, y: 60, width: 12, height: 12), size: size, screen: screen)
        XCTAssertEqual(origin, CGPoint(x: 200, y: 72 + 6), "아래가 모자라면 기준 위로")
        // 딱 들어가는 경계: 아래 틈 8 이 남으면 뒤집지 않는다
        XCTAssertEqual(HoverPlacement.origin(anchor: CGRect(x: 200, y: 114, width: 12, height: 12), size: size, screen: screen).y, 8)
        XCTAssertEqual(HoverPlacement.origin(anchor: CGRect(x: 200, y: 113, width: 12, height: 12), size: size, screen: screen).y, 125 + 6)
    }

    func testStaysInsideHorizontally() {
        XCTAssertEqual(HoverPlacement.origin(anchor: CGRect(x: 900, y: 500, width: 12, height: 12), size: size, screen: screen).x, 1000 - 8 - 300, "오른쪽 끝에서는 왼쪽으로 민다")
        XCTAssertEqual(HoverPlacement.origin(anchor: CGRect(x: -40, y: 500, width: 12, height: 12), size: size, screen: screen).x, 8, "왼쪽 밖이면 화면 안으로")
        // 둘째 화면(원점이 0 이 아님)
        let second = CGRect(x: 1000, y: -200, width: 800, height: 600)
        XCTAssertEqual(HoverPlacement.origin(anchor: CGRect(x: 1700, y: 100, width: 12, height: 12), size: size, screen: second), CGPoint(x: 1800 - 8 - 300, y: -6))
    }

    func testLargerThanScreen() {
        let big = CGSize(width: 1200, height: 900)
        let origin = HoverPlacement.origin(anchor: CGRect(x: 500, y: 400, width: 12, height: 12), size: big, screen: screen)
        XCTAssertEqual(origin, CGPoint(x: 8, y: 8), "화면보다 크면 왼쪽 아래 끝에 (위아래 어디에도 안 들어간다)")
    }
}
