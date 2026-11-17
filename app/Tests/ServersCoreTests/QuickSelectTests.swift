import Foundation
@testable import ServersCore
import XCTest

/// ⌘ 를 누르고 있으면 서버 행에 1–9 번호, ⌘1–⌘9 로 그 서버를 고른다 (Claude 앱 최근 항목과 같은 방식)
final class QuickSelectTests: XCTestCase {
    private let groups: [(group: String, servers: [String])] = [
        ("acme", ["web", "was", "db", "jenkins"]), ("gateway", ["brume3"]), ("home", ["nexus", "win"]),
    ]

    // MARK: 번호 매기기

    func testNumbersFollowSidebarOrderAcrossGroups() {
        XCTAssertEqual(QuickSelect.keys(groups: groups, collapsed: [], searching: false),
                       ["web", "was", "db", "jenkins", "brume3", "nexus", "win"])
    }

    func testCollapsedGroupIsSkipped() {
        XCTAssertEqual(QuickSelect.keys(groups: groups, collapsed: ["acme"], searching: false), ["brume3", "nexus", "win"],
                       "접힌 그룹의 서버는 보이지 않으니 번호도 없다 — 다음 그룹이 1번부터")
    }

    func testSearchingIgnoresCollapsed() {
        XCTAssertEqual(QuickSelect.keys(groups: [("acme", ["web"]), ("home", ["win"])], collapsed: ["acme"], searching: true), ["web", "win"],
                       "검색 중엔 모든 그룹이 펼쳐져 보인다")
    }

    func testOnlyFirstNine() {
        let many = [("g", (1...12).map { "s\($0)" })]
        let keys = QuickSelect.keys(groups: many, collapsed: [], searching: false)
        XCTAssertEqual(keys.count, 9)
        XCTAssertEqual(keys.last, "s9")
    }

    func testNumberToKey() {
        let keys = ["web", "was"]
        XCTAssertEqual(QuickSelect.key(for: 1, in: keys), "web")
        XCTAssertEqual(QuickSelect.key(for: 2, in: keys), "was")
        XCTAssertNil(QuickSelect.key(for: 3, in: keys), "번호가 없는 자리는 그냥 흘린다")
        XCTAssertNil(QuickSelect.key(for: 0, in: keys))
        XCTAssertNil(QuickSelect.key(for: 1, in: []))
    }

    // MARK: 숫자 키 (키 위치 — 한글 입력기·AZERTY 와 무관)

    func testNumberKeysByPosition() {
        let row: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]   // kVK_ANSI_1 … 9
        XCTAssertEqual(row.map { QuickSelect.number(keyCode: $0) }, (1...9).map { Optional($0) })
        let keypad: [UInt16] = [83, 84, 85, 86, 87, 88, 89, 91, 92]
        XCTAssertEqual(keypad.map { QuickSelect.number(keyCode: $0) }, (1...9).map { Optional($0) })
        XCTAssertNil(QuickSelect.number(keyCode: 29), "0 은 번호가 없다")
        XCTAssertNil(QuickSelect.number(keyCode: 8), "C")
    }

    func testCommandOnly() {
        XCTAssertTrue(QuickSelect.commandOnly(command: true, shift: false, option: false, control: false))
        XCTAssertFalse(QuickSelect.commandOnly(command: true, shift: true, option: false, control: false), "⌘⇧[ 탭 이동 등")
        XCTAssertFalse(QuickSelect.commandOnly(command: true, shift: false, option: true, control: false))
        XCTAssertFalse(QuickSelect.commandOnly(command: false, shift: false, option: false, control: false))
    }

    // MARK: 번호 보이기 — 과정을 순서대로

    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    func testHoldCommandShowsAfterDelayAndReleaseHides() {
        var b = QuickSelectBadges()
        b.modifiersChanged(commandOnly: true, at: at(0))
        b.tick(at: at(0.05))
        XCTAssertFalse(b.visible, "바로 뜨지 않는다 — ⌘C 처럼 빨리 누르는 조합마다 번호가 번쩍이지 않게")
        b.tick(at: at(QuickSelectBadges.delay))
        XCTAssertTrue(b.visible)
        b.modifiersChanged(commandOnly: false, at: at(1))
        XCTAssertFalse(b.visible, "⌘ 를 떼면 바로 숨김")
        b.tick(at: at(2))
        XCTAssertFalse(b.visible, "뗀 뒤 tick 이 와도 다시 뜨지 않는다")
    }

    func testQuickCommandComboNeverShows() {
        var b = QuickSelectBadges()
        b.modifiersChanged(commandOnly: true, at: at(0))
        b.keyDown(isNumber: false)   // ⌘C
        b.tick(at: at(1))
        XCTAssertFalse(b.visible, "⌘ 와 다른 키를 같이 누른 이번 누름 동안은 뜨지 않는다 (⌘C 를 누른 채 오래 있어도)")
        b.modifiersChanged(commandOnly: false, at: at(1.1))
        b.modifiersChanged(commandOnly: true, at: at(2))
        b.tick(at: at(2 + QuickSelectBadges.delay))
        XCTAssertTrue(b.visible, "⌘ 를 떼고 다시 누르면 다시 뜬다")
    }

    func testShiftTabMoveKeepsBlockedWhileCommandHeld() {
        var b = QuickSelectBadges()
        b.modifiersChanged(commandOnly: true, at: at(0))      // ⌘
        b.modifiersChanged(commandOnly: false, at: at(0.05))  // ⌘⇧
        b.keyDown(isNumber: false)                            // [ — 탭 이동
        b.modifiersChanged(commandOnly: true, at: at(0.1))    // ⇧ 뗌, ⌘ 는 아직
        b.tick(at: at(1))
        XCTAssertFalse(b.visible, "⌘⇧[ 뒤 ⌘ 만 남아도 이번 누름엔 뜨지 않는다")
    }

    func testNumberKeyKeepsBadges() {
        var b = QuickSelectBadges()
        b.modifiersChanged(commandOnly: true, at: at(0))
        b.tick(at: at(0.5))
        b.keyDown(isNumber: true)   // ⌘1
        XCTAssertTrue(b.visible, "누른 채로 ⌘1 → ⌘2 처럼 옮겨 다닐 수 있게 그대로")
    }

    func testCommandOneBeforeDelayStillAllowsLaterShow() {
        var b = QuickSelectBadges()
        b.modifiersChanged(commandOnly: true, at: at(0))
        b.keyDown(isNumber: true)   // 번호를 외워 바로 ⌘1
        b.tick(at: at(0.5))
        XCTAssertTrue(b.visible, "숫자 키는 막지 않는다")
    }

    func testAddingShiftHides() {
        var b = QuickSelectBadges()
        b.modifiersChanged(commandOnly: true, at: at(0))
        b.tick(at: at(0.5))
        b.modifiersChanged(commandOnly: false, at: at(0.6))   // ⌘⇧
        XCTAssertFalse(b.visible)
        b.modifiersChanged(commandOnly: true, at: at(0.7))    // ⇧ 만 뗌 — ⌘ 는 계속
        b.tick(at: at(0.7 + QuickSelectBadges.delay))
        XCTAssertTrue(b.visible, "다시 ⌘ 만 남으면 처음부터 기다렸다 뜬다")
    }

    func testResetHidesAndForgetsPress() {
        var b = QuickSelectBadges()
        b.modifiersChanged(commandOnly: true, at: at(0))
        b.tick(at: at(0.5))
        b.reset()   // ⌘Tab 으로 다른 앱 — 뗌 이벤트가 이 앱에 오지 않는다
        XCTAssertFalse(b.visible)
        b.tick(at: at(5))
        XCTAssertFalse(b.visible, "돌아와서 ⌘ 를 새로 누르기 전엔 뜨지 않는다")
    }
}
