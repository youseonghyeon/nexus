import CoreGraphics
@testable import ServersCore
import XCTest

final class TileColumnsTests: XCTestCase {
    // 본문 폭 1120pt (창 최대 1200 - 좌우 여백 40·40), 간격 12, 최소 150

    func testFiveTilesFillTheRow() {
        let r = TileColumns.layout(width: 1120, count: 5, minimum: 150, spacing: 12)
        XCTAssertEqual(r.slots, 5)
        XCTAssertEqual(r.tile, (1120 - 48) / 5, accuracy: 0.01)
    }

    func testFourTilesFillTheRow() {
        // 옛 적응형 격자는 7칸을 만들어 4개면 오른쪽 3칸이 비었다
        let r = TileColumns.layout(width: 1120, count: 4, minimum: 150, spacing: 12)
        XCTAssertEqual(r.slots, 4)
        XCTAssertEqual(r.tile * 4 + 36, 1120, accuracy: 0.01)
    }

    func testFewTilesKeepFourSlots() {
        // 3개·2개는 4칸 크기 그대로 (타일이 화면마다 들쭉날쭉 커지지 않게)
        XCTAssertEqual(TileColumns.layout(width: 1120, count: 3, minimum: 150, spacing: 12).slots, 4)
        XCTAssertEqual(TileColumns.layout(width: 1120, count: 2, minimum: 170, spacing: 12).slots, 4)
        XCTAssertEqual(TileColumns.layout(width: 1120, count: 1, minimum: 150, spacing: 12).slots, 4)
    }

    func testManyTilesSplitEvenlyWhileTheyFit() {
        // 7개는 1120 에 안 들어간다 (7 × 150 + 6 × 12 = 1122 > 1120 → 두 줄, 고르게 4+3). 1122 면 한 줄
        XCTAssertEqual(TileColumns.layout(width: 1120, count: 7, minimum: 150, spacing: 12).slots, 4)
        XCTAssertEqual(TileColumns.layout(width: 1122, count: 7, minimum: 150, spacing: 12).slots, 7)
    }

    func testNarrowWidthWraps() {
        // 좁은 창: 들어가는 칸 수(2)로 줄을 바꾸고, 4칸을 고집하지 않는다
        let r = TileColumns.layout(width: 340, count: 5, minimum: 150, spacing: 12)
        XCTAssertEqual(r.slots, 2)
        XCTAssertEqual(r.tile, 164, accuracy: 0.01)
        XCTAssertEqual(TileColumns.layout(width: 340, count: 1, minimum: 150, spacing: 12).slots, 2)
    }

    /// 줄을 바꿀 때는 줄마다 고르게: 3칸이 들어가는 폭에서 4개는 2+2 (3+1 로 하나만 떨어지지 않게), 5개는 3+2, 6개는 3+3
    func testWrappedRowsAreBalanced() {
        let width: CGFloat = 3 * 150 + 2 * 12   // 딱 3칸
        let cases: [(count: Int, slots: Int)] = [(3, 3), (4, 2), (5, 3), (6, 3), (7, 3), (9, 3), (10, 3)]
        for (count, slots) in cases {
            XCTAssertEqual(TileColumns.layout(width: width, count: count, minimum: 150, spacing: 12, minimumSlots: 3).slots, slots, "\(count)개")
        }
        // 4칸이 들어가는 폭에서 5개는 3+2 (4+1 아님)
        XCTAssertEqual(TileColumns.layout(width: 4 * 150 + 3 * 12, count: 5, minimum: 150, spacing: 12).slots, 3)
    }

    func testTooNarrowForOneTile() {
        let r = TileColumns.layout(width: 100, count: 3, minimum: 150, spacing: 12)
        XCTAssertEqual(r.slots, 1)
        XCTAssertEqual(r.tile, 100, accuracy: 0.01)
        XCTAssertEqual(TileColumns.layout(width: 0, count: 3, minimum: 150, spacing: 12).tile, 0)
    }

    /// 폭을 모르는 제안(무한대)·NaN 은 Int 로 못 바꿔 크래시했다 — 최소 칸·최소 폭
    func testNonFiniteWidthDoesNotCrash() {
        for width in [CGFloat.infinity, .nan] {
            let r = TileColumns.layout(width: width, count: 5, minimum: 150, spacing: 12)
            XCTAssertEqual(r.slots, 4)
            XCTAssertEqual(r.tile, 150)
        }
    }
}
