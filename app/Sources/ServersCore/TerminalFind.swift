// 터미널 안 찾기 (⌘F): 스크롤백에서 글자를 찾는 일은 Ghostty 가 한다 — 앱은 찾기 칸을 띄우고 Ghostty 의 동작 이름으로 시킨다.
//   search:<글자>  찾을 글자를 바꾼다 (일치하는 곳을 터미널이 직접 강조)     navigate_search:next · previous  다음 · 이전 일치로
//   end_search     찾기를 끝낸다 (강조를 지운다)
// 일치한 수("3 / 12")는 보이지 못한다: Ghostty 는 알려 주지만(SEARCH_TOTAL · SEARCH_SELECTED) 터미널 래퍼(libghostty-spm 1.5.2)가 앱에 넘기지 않는다.
// ⌘F · ⌘G · ⌘⇧G 는 Ghostty 의 기본 키라 터미널 뷰가 먼저 가져간다(가져가도 래퍼가 찾기 화면을 띄우지 않아 아무 일도 없다) —
// 그래서 키 감시(TerminalShortcuts)가 먼저 받아 이 판정대로 처리한다.

import Foundation

public enum TerminalFind {
    public enum Key: Sendable, Equatable { case find, next, previous }
    public enum Command: Sendable, Equatable {
        /// 찾기 칸을 연다 — 이미 열려 있으면 칸으로 포커스만 옮긴다
        case open
        case next, previous
    }

    /// 누른 키 → 할 일. 본창에 보이는 탭이 터미널일 때만 받는다 (Dashboard · 브라우저 탭이면 nil — 키를 흘린다).
    /// ⌘G · ⌘⇧G 는 찾는 중일 때만 다음 · 이전, 아니면 찾기 칸을 연다 (Safari · 터미널 앱들과 같게).
    public static func command(for key: Key, terminalVisible: Bool, finding: Bool) -> Command? {
        guard terminalVisible else { return nil }
        switch key {
        case .find: return .open
        case .next: return finding ? .next : .open
        case .previous: return finding ? .previous : .open
        }
    }

    public static let nextAction = "navigate_search:next"
    public static let previousAction = "navigate_search:previous"
    public static let endAction = "end_search"

    /// 찾을 글자를 바꾸는 동작. 빈 글자면 찾기를 끝낸다 (강조를 지운다 — 빈 글자로 찾으면 아무것도 지워지지 않는다).
    /// 글자는 그대로 넘긴다: 동작 이름 뒤 첫 ":" 다음이 전부 찾을 글자다 (":" · 공백이 들어 있어도). 줄바꿈은 찾을 수 없어 공백으로 바꾼다.
    public static func searchAction(_ text: String) -> String {
        let needle = text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return needle.isEmpty ? endAction : "search:" + needle
    }
}
