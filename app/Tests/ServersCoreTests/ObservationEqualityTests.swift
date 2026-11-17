// @Observable 이 같은 값을 다시 넣을 때 알림을 건너뛰는가 (이 툴체인 기준). AppModel 에 `if new != old` 막이를 둘지 정하는 근거.
// 결과: 통째로 대입할 때 Equatable 값이 같거나 같은 인스턴스(===)면 알리지 않는다(매크로의 shouldNotifyObservers).
// 다른 값·Equatable 아닌 값은 알리고, 제자리 고침(첨자 대입·+=·append)은 값 비교 없이 늘 알린다.

import Foundation
import Observation
import XCTest

@Observable
private final class Probe {
    var number = 0
    var text = "a"
    var list: [Int] = [1, 2]
    var optional: Int?
    /// Equatable 이 아닌 값
    var tuple: (Int, Int) = (0, 0)
    /// 클래스 참조 (Equatable 아님) — 같은 인스턴스를 다시 넣는 경우
    var object = Box()
    /// 바꾼 횟수 (값 비교와 상관없이 늘 바뀐다)
    var revision = 0
    /// didSet 이 붙은 속성 — AppModel.statusMessage 처럼 같은 값을 다시 넣을 때도 didSet 이 돌아야 한다 (토스트 ×N)
    var message: String? {
        didSet { didSetCount += 1 }
    }
    var didSetCount = 0
}

private final class Box {}

private final class Flag: @unchecked Sendable {
    var fired = 0
}

final class ObservationEqualityTests: XCTestCase {
    /// read 를 지켜보다가 write 를 했을 때 onChange 가 불렸는가
    private func fires(_ probe: Probe, read: (Probe) -> Void, write: (Probe) -> Void) -> Bool {
        let flag = Flag()
        withObservationTracking { read(probe) } onChange: { flag.fired += 1 }
        write(probe)
        return flag.fired > 0
    }

    func testEqualEquatableValueDoesNotNotify() {
        let probe = Probe()
        XCTAssertFalse(fires(probe, read: { _ = $0.number }, write: { $0.number = 0 }))
        XCTAssertFalse(fires(probe, read: { _ = $0.text }, write: { $0.text = "a" }))
        XCTAssertFalse(fires(probe, read: { _ = $0.list }, write: { $0.list = [1, 2] }))
        XCTAssertFalse(fires(probe, read: { _ = $0.optional }, write: { $0.optional = nil }))
    }

    func testDifferentValueNotifies() {
        let probe = Probe()
        XCTAssertTrue(fires(probe, read: { _ = $0.number }, write: { $0.number = 1 }))
        XCTAssertTrue(fires(probe, read: { _ = $0.list }, write: { $0.list.append(3) }))
        XCTAssertTrue(fires(probe, read: { _ = $0.revision }, write: { $0.revision += 1 }))
    }

    /// 같은 인스턴스(===)를 다시 넣으면 알리지 않는다. 다른 인스턴스는 알린다.
    func testSameObjectReferenceDoesNotNotify() {
        let probe = Probe()
        let same = probe.object
        XCTAssertFalse(fires(probe, read: { _ = $0.object }, write: { $0.object = same }))
        XCTAssertTrue(fires(probe, read: { _ = $0.object }, write: { $0.object = Box() }))
    }

    /// Equatable 이 아닌 값(튜플)은 비교하지 못하므로 같은 값이어도 알린다.
    func testNonEquatableValueAlwaysNotifies() {
        let probe = Probe()
        XCTAssertTrue(fires(probe, read: { _ = $0.tuple }, write: { $0.tuple = (0, 0) }))
    }

    /// 제자리 고침(첨자 대입·+=·append)은 _modify 를 거쳐 값 비교 없이 알린다 — 같은 값이어도
    func testInPlaceMutationAlwaysNotifies() {
        let probe = Probe()
        XCTAssertTrue(fires(probe, read: { _ = $0.list }, write: { $0.list[0] = 1 }))
        XCTAssertTrue(fires(probe, read: { _ = $0.number }, write: { $0.number += 0 }))
    }

    /// didSet 은 같은 값을 넣어도 돈다 (알림만 건너뛴다). didSet 안에서 바꾼 다른 속성은 따로 알린다.
    func testDidSetRunsOnEqualAssignment() {
        let probe = Probe()
        probe.message = "x"
        XCTAssertEqual(probe.didSetCount, 1)
        XCTAssertFalse(fires(probe, read: { _ = $0.message }, write: { $0.message = "x" }))
        XCTAssertEqual(probe.didSetCount, 2)
        XCTAssertTrue(fires(probe, read: { _ = $0.didSetCount }, write: { $0.message = "x" }))
    }

    /// 읽지 않은 속성이 바뀌면 알리지 않는다 (속성 단위 추적)
    func testUnreadPropertyDoesNotNotify() {
        let probe = Probe()
        XCTAssertFalse(fires(probe, read: { _ = $0.number }, write: { $0.text = "b" }))
    }
}
