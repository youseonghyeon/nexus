// TerminalKeys: 터미널이 가져가지 않게 푸는 키 목록. 실제로 풀렸는지는 `make check-shortcuts` 가 libghostty 에 물어 확인한다 —
// 그 점검이 읽는 scripts/terminal-keybinds.conf 가 앱이 쓰는 목록과 같은지를 여기서 본다 (둘이 어긋나면 점검이 다른 것을 확인하게 된다).

import Foundation
import XCTest
@testable import ServersCore

final class TerminalKeysTests: XCTestCase {
    func testCheckScriptReadsTheSameKeybindsAsTheApp() throws {
        let file = TestPaths.appDir.appendingPathComponent("scripts/terminal-keybinds.conf")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), TerminalKeys.configText,
                       "문제: scripts/terminal-keybinds.conf 가 TerminalKeys.unbound 와 다릅니다 · 해결: 두 곳을 같게 고치고 make check-shortcuts 를 돌리세요 · 참조: app/Sources/ServersCore/TerminalKeys.swift")
    }

    func testKeybindShape() {
        XCTAssertEqual(TerminalKeys.keybinds.first, "super+t=unbind")
        XCTAssertEqual(TerminalKeys.keybinds.count, TerminalKeys.unbound.count)
        XCTAssertEqual(Set(TerminalKeys.unbound).count, TerminalKeys.unbound.count, "같은 키를 두 번 적지 않는다")
        // 터미널 안에서 써야 하는 키는 풀지 않는다 (복사 · 붙여 넣기 · 전체 선택 · 글자 크기)
        for key in ["super+c", "super+v", "super+a", "super+equal", "super+minus", "super+zero"] { XCTAssertFalse(TerminalKeys.unbound.contains(key)) }
    }
}
