// 글자 단축키(⌘C·⌘V·⌘P·⌘W·⌘F·⌘G) 판정. 한글 입력기에서는 ⌘C 가 "ㅊ" 로 와서 글자로는 못 잡으므로 키 위치(QWERTY 키코드)로 보고,
// 라틴 배열(QWERTY·AZERTY·Dvorak)은 그 키가 찍는 글자로 본다 — 키코드만 보면 AZERTY 에서 ⌘Z 가 탭을 닫았다.

import Foundation

public enum ShortcutKey {
    /// characters: ⌘ 를 반영한 이벤트 글자. ASCII 한 글자면 그 글자로, 아니면(한글·없음) 키 위치로.
    public static func matches(_ letter: Character, keyCode: UInt16, characters: String?) -> Bool {
        if let typed = characters?.lowercased(), typed.count == 1, let ch = typed.first, ch.isASCII { return ch == letter }
        return qwertyKeyCodes[letter] == keyCode
    }

    /// kVK_ANSI_* (QWERTY 자리)
    static let qwertyKeyCodes: [Character: UInt16] = ["c": 8, "v": 9, "p": 35, "w": 13, "f": 3, "g": 5]
}
