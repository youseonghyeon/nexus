// TabSelection: 탭 닫은 뒤 다음 활성 탭 고르기.

import Foundation
import XCTest
@testable import ServersCore

final class TabSelectionTests: XCTestCase {

    // 리뷰 #5: 탭을 닫으면 같은 소유자 안에서 다음 탭을 고른다
    func testTabSelection() {
        let tabs = [TabRef(id: 1, owner: "nexus"), TabRef(id: 2, owner: "was"), TabRef(id: 3, owner: "nexus"), TabRef(id: 4, owner: "was")]
        XCTAssertEqual(TabSelection.nextActive(after: 1, in: tabs), 3)       // 오른쪽 이웃(같은 서버)
        XCTAssertEqual(TabSelection.nextActive(after: 3, in: tabs), 1)       // 왼쪽 이웃
        XCTAssertEqual(TabSelection.nextActive(after: 4, in: tabs), 2)
        XCTAssertNil(TabSelection.nextActive(after: 9, in: tabs))
        XCTAssertNil(TabSelection.nextActive(after: 1, in: [TabRef(id: 1, owner: "nexus")]))
        XCTAssertEqual(TabSelection.lastTab(of: "was", in: tabs), 4)
        XCTAssertNil(TabSelection.lastTab(of: "ghost", in: tabs))
    }

    // 다른 서버에 갔다 돌아오면 떠날 때 보던 탭 그대로 (마지막 탭으로 튀지 않는다)
    func testActiveTabRemembersPerOwner() {
        let tabs = [TabRef(id: 1, owner: "nexus"), TabRef(id: 2, owner: "was"), TabRef(id: 3, owner: "nexus"), TabRef(id: 4, owner: "was")]
        XCTAssertEqual(TabSelection.activeTab(of: "nexus", remembered: ["nexus": 1], in: tabs), 1)
        XCTAssertEqual(TabSelection.activeTab(of: "was", remembered: ["nexus": 1, "was": 2], in: tabs), 2)
        // 기억이 없으면 그 소유자의 마지막 탭
        XCTAssertEqual(TabSelection.activeTab(of: "nexus", remembered: [:], in: tabs), 3)
        // 기억한 탭이 이미 닫혔으면 마지막 탭
        XCTAssertEqual(TabSelection.activeTab(of: "nexus", remembered: ["nexus": 9], in: tabs), 3)
        // 남의 소유자 탭이 적혀 있어도 따라가지 않는다
        XCTAssertEqual(TabSelection.activeTab(of: "nexus", remembered: ["nexus": 2], in: tabs), 3)
        // 탭이 하나도 없는 소유자는 nil (Dashboard)
        XCTAssertNil(TabSelection.activeTab(of: "ghost", remembered: ["ghost": 1], in: tabs))
    }

    // ⌘⇧[ / ⌘⇧] : Dashboard → 그 소유자의 탭 순서로 한 칸씩, 양 끝에서 돈다. 다른 소유자 탭은 건너뛴다
    func testStepCyclesWithinOwnerIncludingDashboard() {
        let tabs = [TabRef(id: 1, owner: "nexus"), TabRef(id: 2, owner: "was"), TabRef(id: 3, owner: "nexus")]
        XCTAssertEqual(TabSelection.step(from: nil, owner: "nexus", forward: true, in: tabs), .tab(1))
        XCTAssertEqual(TabSelection.step(from: 1, owner: "nexus", forward: true, in: tabs), .tab(3))   // was 의 2 는 건너뜀
        XCTAssertEqual(TabSelection.step(from: 3, owner: "nexus", forward: true, in: tabs), .dashboard) // 끝 → 처음(Dashboard)
        XCTAssertEqual(TabSelection.step(from: nil, owner: "nexus", forward: false, in: tabs), .tab(3)) // 처음 → 끝
        XCTAssertEqual(TabSelection.step(from: 1, owner: "nexus", forward: false, in: tabs), .dashboard)
        XCTAssertEqual(TabSelection.step(from: 3, owner: "nexus", forward: false, in: tabs), .tab(1))
        // 탭 하나: Dashboard ↔ 그 탭
        XCTAssertEqual(TabSelection.step(from: 2, owner: "was", forward: true, in: tabs), .dashboard)
        XCTAssertEqual(TabSelection.step(from: nil, owner: "was", forward: false, in: tabs), .tab(2))
    }

    // 탭 막대가 없는 소유자(탭 0개)는 옮기지 않는다. 남의 탭 id 가 오면 Dashboard 에 있는 것으로 본다
    func testStepWithoutTabsOrUnknownCurrent() {
        let tabs = [TabRef(id: 1, owner: "nexus"), TabRef(id: 2, owner: "was")]
        XCTAssertEqual(TabSelection.step(from: nil, owner: "ghost", forward: true, in: tabs), .stay)
        XCTAssertEqual(TabSelection.step(from: nil, owner: "ghost", forward: false, in: [TabRef<Int>]()), .stay)
        XCTAssertEqual(TabSelection.step(from: 2, owner: "nexus", forward: true, in: tabs), .tab(1))
        XCTAssertEqual(TabSelection.step(from: 9, owner: "nexus", forward: false, in: tabs), .tab(1))
    }
}
