import Foundation
@testable import ServersCore
import XCTest

final class TabSelectionMoveTests: XCTestCase {
    private let tabs = [TabRef(id: "a1", owner: "a"), TabRef(id: "a2", owner: "a"), TabRef(id: "b1", owner: "b"), TabRef(id: "a3", owner: "a")]

    // 막대 안에서 끌기: 같은 서버 탭들 안 n 번째로, 다른 서버 탭 자리는 그대로
    func testMoveToIndex() {
        XCTAssertEqual(TabSelection.move("a1", to: 2, in: tabs).map(\.id), ["a2", "a3", "b1", "a1"], "맨 뒤로 — b1 자리는 그대로")
        XCTAssertEqual(TabSelection.move("a3", to: 0, in: tabs).map(\.id), ["a3", "a1", "b1", "a2"])
        XCTAssertEqual(TabSelection.move("a2", to: 1, in: tabs), tabs, "제자리")
        XCTAssertEqual(TabSelection.move("a1", to: 99, in: tabs).map(\.id), ["a2", "a3", "b1", "a1"], "넘치면 끝")
        XCTAssertEqual(TabSelection.move("a3", to: -1, in: tabs).map(\.id), ["a3", "a1", "b1", "a2"], "모자라면 앞")
        XCTAssertEqual(TabSelection.move("zz", to: 0, in: tabs), tabs)
        XCTAssertEqual(TabSelection.move("b1", to: 0, in: tabs), tabs, "혼자인 서버")
    }

    // MARK: 막대 안 끌기 — 끄는 과정을 순서대로 흉내 낸다 (화면과 같은 계산: 자리를 바꾸면 순서·폭 배열이 바뀐다)

    /// 이름·폭 탭들에서 `name` 을 끌어 translation 을 차례로 지나간다. 매 단계 자리 바꾸기를 적용하고,
    /// 보이는 위치가 커서(시작 + 끈 거리, 끝 제한)와 어긋나지 않는지·같은 값에서 또 바뀌지 않는지 확인. 끝난 뒤 순서를 돌려준다.
    private func simulate(_ tabs: [(String, Double)], drag name: String, through steps: [Double],
                          file: StaticString = #filePath, line: UInt = #line) -> [String] {
        var order = tabs
        let start = TabDrag.layout(widths: order.map(\.1), base: 0, spacing: 2)
        let startIndex = order.firstIndex(where: { $0.0 == name })!
        var drag = TabDrag(base: 0, startMinX: start[startIndex].lowerBound, spacing: 2)
        for t in steps {
            drag.translation = t
            var index = order.firstIndex(where: { $0.0 == name })!
            let before = drag.visualMinX(widths: order.map(\.1), index: index)
            let target = drag.target(widths: order.map(\.1), index: index)
            if target != index {
                order.insert(order.remove(at: index), at: target)
                index = target
            }
            let widths = order.map(\.1)
            let spans = TabDrag.layout(widths: widths, base: 0, spacing: 2)
            // 자리를 바꿔도 보이는 위치(레이아웃 자리 + offset)는 그대로 — 튀지 않음
            XCTAssertEqual(spans[index].lowerBound + drag.offset(widths: widths, index: index), before, accuracy: 0.001, "t=\(t) 튐", file: file, line: line)
            // 같은 값이면 또 바뀌지 않음 — 왔다 갔다 없음
            XCTAssertEqual(drag.target(widths: widths, index: index), index, "t=\(t) 왔다 갔다", file: file, line: line)
        }
        return order.map(\.0)
    }

    private func ramp(_ from: Double, _ to: Double) -> [Double] {
        stride(from: from, through: to, by: from < to ? 3 : -3).map { $0 }
    }

    func testDragWideTabPastNarrow() {
        // 넓은 A(200) 를 작은 B(60) 너머로 — 중심 비교로는 못 넘던 경우
        XCTAssertEqual(simulate([("A", 200), ("B", 60)], drag: "A", through: ramp(0, 120)), ["B", "A"])
        // 넓은 탭을 왼쪽 작은 탭 너머로
        XCTAssertEqual(simulate([("B", 60), ("A", 200)], drag: "A", through: ramp(0, -120)), ["A", "B"])
    }

    func testDragNarrowTabPastWide() {
        XCTAssertEqual(simulate([("B", 60), ("A", 200)], drag: "B", through: ramp(0, 300)), ["A", "B"])
        XCTAssertEqual(simulate([("A", 200), ("B", 60)], drag: "B", through: ramp(0, -300)), ["B", "A"])
    }

    func testDragAcrossSeveralAndBack() {
        let tabs: [(String, Double)] = [("A", 80), ("B", 200), ("C", 60), ("D", 140)]
        XCTAssertEqual(simulate(tabs, drag: "A", through: ramp(0, 500)), ["B", "C", "D", "A"], "끝까지")
        XCTAssertEqual(simulate(tabs, drag: "A", through: ramp(0, 500) + ramp(500, 0)), ["A", "B", "C", "D"], "갔다가 제자리로")
        XCTAssertEqual(simulate(tabs, drag: "D", through: ramp(0, -600)), ["D", "A", "B", "C"])
        XCTAssertEqual(simulate(tabs, drag: "C", through: ramp(0, 160)), ["A", "B", "D", "C"])
    }

    func testDragSmallMovesDoNotReorder() {
        let tabs: [(String, Double)] = [("A", 200), ("B", 60), ("C", 120)]
        XCTAssertEqual(simulate(tabs, drag: "B", through: ramp(0, 20) + ramp(20, -20) + ramp(-20, 0)), ["A", "B", "C"], "이웃 중심 전까지는 그대로")
        // 경계 근처에서 손이 떨려도(±1) 한 번 바뀐 뒤 왔다 갔다 하지 않음 — simulate 가 매 단계 확인
        _ = simulate(tabs, drag: "A", through: [30, 31, 32, 33, 32, 31, 30, 31, 32, 33, 34])
    }

    func testDragClampsAtEnds() {
        let widths: [Double] = [200, 60]
        var drag = TabDrag(base: 10, startMinX: 10, spacing: 2)
        drag.translation = -500
        XCTAssertEqual(drag.visualMinX(widths: widths, index: 0), 10, "첫 탭 앞으로 안 나감")
        drag.translation = 500
        XCTAssertEqual(drag.visualMinX(widths: widths, index: 0), 10 + 262 - 200, "마지막 탭 끝 뒤로 안 나감")
        var single = TabDrag(base: 0, startMinX: 0, spacing: 2)
        single.translation = 80
        XCTAssertEqual(single.target(widths: [120], index: 0), 0, "탭 하나")
        XCTAssertEqual(single.offset(widths: [120], index: 0), 0)
    }

    // 놓은 자리가 막대 안이면 창 끌기를 끈 채 둔다 (커서가 탭 위 — 다음 끌기에 창이 움직이던 것)
    func testReleasedInside() {
        XCTAssertTrue(TabDrag.releasedInside(x: 120, y: 14, width: 400, height: 28))
        XCTAssertTrue(TabDrag.releasedInside(x: 0, y: 0, width: 400, height: 28), "모서리 포함")
        XCTAssertTrue(TabDrag.releasedInside(x: 400, y: 28, width: 400, height: 28))
        XCTAssertFalse(TabDrag.releasedInside(x: 120, y: 60, width: 400, height: 28), "아래 본문으로 끌고 나가 놓음")
        XCTAssertFalse(TabDrag.releasedInside(x: -5, y: 14, width: 400, height: 28))
        XCTAssertFalse(TabDrag.releasedInside(x: 401, y: 14, width: 400, height: 28))
        XCTAssertFalse(TabDrag.releasedInside(x: 10, y: 10, width: 0, height: 0), "크기를 아직 못 잼 → 밖으로 (창 끌기 켬)")
    }
}
