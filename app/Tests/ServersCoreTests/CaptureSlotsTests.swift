import XCTest
@testable import ServersCore

final class CaptureSlotsTests: XCTestCase {
    private func row(_ id: Int) -> CaptureRow {
        CaptureRow(id: id, raw: CapturedPacket(time: 0, originalLength: 0, data: []), decoded: DecodedPacket(), conversation: "", issue: nil)
    }

    /// 최근 것이 위 (번호 내림차순)
    private func slots(_ ids: [Int]) -> CaptureSlots {
        CaptureSlots(ids.map(row))
    }

    func testSlotIDIsPositionNotPacketNumber() {
        let s = slots([9, 8, 7])
        XCTAssertEqual(s.map(\.id), [0, 1, 2])
        XCTAssertEqual(s.map(\.row.id), [9, 8, 7])
    }

    /// 새 패킷이 위에 들어와도 자리 목록은 그대로 — 표가 행을 끼워 넣지 않는다
    func testPositionsStayWhenNewPacketsArrive() {
        let before = slots([9, 8, 7])
        let after = slots([11, 10, 9])   // 두 개 들어오고 두 개 밀려남
        XCTAssertEqual(before.map(\.id), after.map(\.id))
        XCTAssertEqual(after[0].row.id, 11)
    }

    func testRowAtPosition() {
        let s = slots([9, 8, 7])
        XCTAssertEqual(s.row(at: 0)?.id, 9)
        XCTAssertEqual(s.row(at: 2)?.id, 7)
        XCTAssertNil(s.row(at: 3), "끝을 넘은 자리")
        XCTAssertNil(s.row(at: -1))
        XCTAssertNil(s.row(at: nil))
        XCTAssertNil(slots([]).row(at: 0), "빈 목록")
    }

    func testPositionOfPacket() {
        let s = slots([9, 8, 7])
        XCTAssertEqual(s.position(ofPacket: 9), 0)
        XCTAssertEqual(s.position(ofPacket: 8), 1)
        XCTAssertEqual(s.position(ofPacket: 7), 2)
        XCTAssertNil(s.position(ofPacket: 6), "밀려난 패킷")
        XCTAssertNil(s.position(ofPacket: 10), "아직 목록에 없는 패킷")
        XCTAssertNil(s.position(ofPacket: nil))
        XCTAssertNil(slots([]).position(ofPacket: 1), "빈 목록")
    }

    /// 검색·대화로 걸러진 목록은 번호가 띄엄띄엄
    func testPositionOfPacketInFilteredList() {
        let s = slots([40, 31, 30, 12, 3])
        for (position, id) in [40, 31, 30, 12, 3].enumerated() {
            XCTAssertEqual(s.position(ofPacket: id), position)
        }
        XCTAssertNil(s.position(ofPacket: 20), "걸러진 패킷")
        XCTAssertNil(s.position(ofPacket: 2))
        XCTAssertNil(s.position(ofPacket: 41))
    }

    /// 자리 ↔ 번호를 오가도 같은 패킷 (선택을 표에 넘겼다 돌려받을 때)
    func testRoundTrip() {
        let s = slots(Array((1...5000).reversed()))
        for position in [0, 1, 2499, 4998, 4999] {
            XCTAssertEqual(s.position(ofPacket: s.row(at: position)?.id), position)
        }
    }
}
