import XCTest
@testable import ServersCore

/// 조회 결과 창의 줄 고르기 — 마우스 과정을 순서대로 흉내 낸다 (누름 → 끌기 → 놓음).
final class LineSelectionTests: XCTestCase {
    private let lines = (0..<10).map { "line \($0)" }

    /// 줄 높이 20, 세 번째 줄(2)만 접혀 40 — 화면에는 2…6 번 줄만 그려져 있다
    private let rows = [LineHit.Row(line: 2, minY: 40, maxY: 80), LineHit.Row(line: 3, minY: 80, maxY: 100), LineHit.Row(line: 4, minY: 100, maxY: 120),
                        LineHit.Row(line: 5, minY: 120, maxY: 140), LineHit.Row(line: 6, minY: 140, maxY: 160)]

    private func copied(_ selection: inout LineSelection, shown: (Int) -> Bool = { _ in true }) -> String? {
        selection.release().map { LineSelection.text(lines: lines, range: $0, shown: shown) }
    }

    func testClickCopiesOneLine() {
        var s = LineSelection()
        s.press(3)
        XCTAssertTrue(s.pressing)
        XCTAssertEqual(copied(&s), "line 3", "끌지 않고 누르기만 하면 전처럼 그 줄")
        XCTAssertFalse(s.pressing)
        XCTAssertEqual(s.range, 3...3, "복사한 줄의 표시는 남는다")
        XCTAssertNil(s.release(), "놓음이 두 번 와도 다시 복사하지 않는다")
    }

    func testDragDownSelectsLinesBetween() {
        var s = LineSelection()
        s.press(2)
        s.drag(to: 3); XCTAssertEqual(s.range, 2...3)
        s.drag(to: 5); XCTAssertEqual(s.range, 2...5)
        XCTAssertTrue([2, 3, 4, 5].allSatisfy(s.contains) && !s.contains(1) && !s.contains(6))
        XCTAssertEqual(copied(&s), "line 2\nline 3\nline 4\nline 5")
    }

    func testDragUpAndBackAcrossTheAnchor() {
        var s = LineSelection()
        s.press(5)
        s.drag(to: 3); XCTAssertEqual(s.range, 3...5, "위로 끌어도 같은 범위")
        s.drag(to: 5); XCTAssertEqual(s.range, 5...5, "되돌아오면 줄어든다")
        s.drag(to: 7); XCTAssertEqual(s.range, 5...7, "처음 누른 줄을 넘어 반대쪽으로")
        s.drag(to: 4)
        XCTAssertEqual(copied(&s), "line 4\nline 5", "순서는 늘 위에서 아래")
    }

    func testDragWithoutPressDoesNothing() {
        var s = LineSelection()
        s.drag(to: 4)
        XCTAssertNil(s.range)
        XCTAssertNil(s.release())
        s.press(1); _ = s.release()
        s.drag(to: 6)
        XCTAssertEqual(s.range, 1...1, "놓은 뒤의 움직임은 범위를 바꾸지 않는다")
    }

    func testShiftClickExtendsFromTheLastPressedLine() {
        var s = LineSelection()
        s.press(2); XCTAssertEqual(copied(&s), "line 2")
        s.press(6, extend: true)
        XCTAssertEqual(copied(&s), "line 2\nline 3\nline 4\nline 5\nline 6", "앞서 누른 줄부터")
        s.press(0, extend: true)
        XCTAssertEqual(copied(&s), "line 0\nline 1\nline 2", "시작 줄은 그대로 — 반대쪽으로 다시")
        s.press(8)
        XCTAssertEqual(copied(&s), "line 8", "그냥 누르면 새로 시작")
        // 끌어 고른 뒤의 Shift 누름도 끌기를 시작한 줄부터
        s.press(4); s.drag(to: 5); _ = s.release()
        s.press(7, extend: true)
        XCTAssertEqual(s.range, 4...7)
        // 앞서 누른 줄이 없으면 그냥 누름
        var fresh = LineSelection()
        fresh.press(3, extend: true)
        XCTAssertEqual(copied(&fresh), "line 3")
    }

    func testFilteredLinesAreSkippedAndClearForgets() {
        var s = LineSelection()
        s.press(1); s.drag(to: 7)
        XCTAssertEqual(copied(&s) { $0 % 3 == 1 }, "line 1\nline 4\nline 7", "걸러 보는 중이면 보이는 줄만")
        s.clear()
        XCTAssertNil(s.range)
        s.press(5, extend: true)
        XCTAssertEqual(s.range, 5...5, "지운 뒤에는 Shift 누름의 시작 줄도 없다")
        XCTAssertEqual(LineSelection.text(lines: lines, range: 8...20), "line 8\nline 9", "결과를 벗어난 범위는 있는 줄까지")
        XCTAssertEqual(LineSelection.text(lines: [], range: 0...3), "")
        XCTAssertEqual(LineSelection.text(lines: ["a", "", "b"], range: 0...2), "a\n\nb", "빈 줄도 줄이다")
    }

    func testHitFindsTheLineUnderThePointer() {
        XCTAssertEqual(LineHit.line(atY: 40, rows: rows), 2)
        XCTAssertEqual(LineHit.line(atY: 79.9, rows: rows), 2, "접혀 높은 줄은 그 높이 전부")
        XCTAssertEqual(LineHit.line(atY: 80, rows: rows), 3, "경계는 아래 줄 것 — 경계에서 두 줄 사이를 오가지 않는다")
        XCTAssertEqual(LineHit.line(atY: 159, rows: rows), 6)
        XCTAssertEqual(LineHit.line(atY: 10, rows: rows), 2, "그려진 줄 위로 벗어나면 맨 위 줄")
        XCTAssertEqual(LineHit.line(atY: -500, rows: rows), 2)
        XCTAssertEqual(LineHit.line(atY: 160, rows: rows), 6, "아래로 벗어나면 맨 아래 줄")
        XCTAssertEqual(LineHit.line(atY: 9000, rows: rows), 6)
        XCTAssertNil(LineHit.line(atY: 50, rows: []), "그려진 줄이 없으면 아무것도 아니다")
        XCTAssertEqual(LineHit.line(atY: 90, rows: rows.reversed()), 3, "받은 순서와 무관")
        // 걸러 보는 중에는 번호가 건너뛴다 · 틈(자리를 아직 못 받은 줄)에서는 가까운 줄
        let sparse = [LineHit.Row(line: 1, minY: 0, maxY: 20), LineHit.Row(line: 7, minY: 60, maxY: 80)]
        XCTAssertEqual(LineHit.line(atY: 25, rows: sparse), 1)
        XCTAssertEqual(LineHit.line(atY: 55, rows: sparse), 7)
    }

    /// 화면이 하는 대로: 자리 → 줄 → 고르기 → 글. 2 번 줄에서 눌러 화면 아래 밖까지 끌었다 놓는다
    func testDragPastTheDrawnRowsStopsAtTheEdge() {
        var s = LineSelection()
        func move(_ y: Double) { if let line = LineHit.line(atY: y, rows: rows) { s.pressing ? s.drag(to: line) : s.press(line) } }
        move(50); move(95); move(130); move(400)
        XCTAssertEqual(s.range, 2...6, "그려진 맨 아래 줄에서 멈춘다")
        move(-30)
        XCTAssertEqual(s.range, 2...2, "위로 벗어나면 맨 위 줄 — 여기서는 처음 누른 줄")
        move(101)
        XCTAssertEqual(copied(&s), "line 2\nline 3\nline 4")
    }
}
