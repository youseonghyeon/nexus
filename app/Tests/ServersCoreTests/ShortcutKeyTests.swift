import Foundation
@testable import ServersCore
import XCTest

/// ⌘C·⌘V·⌘P·⌘W: 라틴 배열은 찍히는 글자로, 한글 입력기는 키 위치로 (키코드만 보면 AZERTY 의 ⌘Z 가 탭을 닫았다)
final class ShortcutKeyTests: XCTestCase {
    func testHangulInputUsesKeyPosition() {
        XCTAssertTrue(ShortcutKey.matches("w", keyCode: 13, characters: "ㅈ"))
        XCTAssertTrue(ShortcutKey.matches("c", keyCode: 8, characters: "ㅊ"))
        XCTAssertTrue(ShortcutKey.matches("w", keyCode: 13, characters: nil))
        XCTAssertTrue(ShortcutKey.matches("w", keyCode: 13, characters: ""))
    }

    func testLatinLayoutsUseTypedCharacter() {
        XCTAssertTrue(ShortcutKey.matches("w", keyCode: 13, characters: "w"), "QWERTY")
        XCTAssertFalse(ShortcutKey.matches("w", keyCode: 13, characters: "z"), "AZERTY 의 W 자리는 Z — 실행 취소가 탭을 닫으면 안 된다")
        XCTAssertTrue(ShortcutKey.matches("w", keyCode: 6, characters: "w"), "AZERTY 의 W 키")
        XCTAssertFalse(ShortcutKey.matches("w", keyCode: 13, characters: ","), "Dvorak 의 W 자리는 쉼표")
        XCTAssertTrue(ShortcutKey.matches("v", keyCode: 47, characters: "V"), "대문자(Caps Lock)도 같은 글자")
    }
}
