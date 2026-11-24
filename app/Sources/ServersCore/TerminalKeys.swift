// 터미널(Ghostty)이 가져가지 않게 푸는 키. Ghostty 터미널 뷰는 자기 기본 키와 겹치는 ⌘ 키를 메뉴보다 먼저 가져가는데,
// 가져간 동작(새 탭 · 설정 · 종료 …)을 터미널 래퍼가 앱에 넘기지 않아 그 키는 눌러도 아무 일도 없었다 (2026-11-24 — 영문 배열에서 ⌘T 가 안 됐다).
// 여기 적은 키는 터미널 설정에 "keybind = <키>=unbind" 로 넣어(Sessions.swift) 메뉴로 가게 한다.
// 같은 목록을 app/scripts/terminal-keybinds.conf 에도 둔다 — `make check-shortcuts` 가 그 파일을 실제 libghostty 에 읽혀 풀렸는지 확인한다 (테스트가 두 곳이 같은지 본다).
// 터미널 안에서도 써야 하는 키(복사 · 붙여 넣기 · 글자 크기 · 전체 선택)는 풀지 않는다.

import Foundation

public enum TerminalKeys {
    /// Ghostty 의 키 이름 (super = ⌘). 쉼표는 글자 그대로 "," — "comma" 로 적으면 다른 키로 읽혀 풀리지 않는다 (make check-shortcuts 가 잡았다).
    /// 앱 메뉴: ⌘T 새 SSH 탭 · ⌘⇧T 새 로컬 셸 · ⌘K 서버 검색 · ⌘, 설정 · ⌘Q 종료 · ⌘⌃F 전체 화면
    public static let unbound = ["super+t", "super+shift+t", "super+k", "super+,", "super+q", "super+ctrl+f"]

    /// 터미널 설정의 keybind 값들 ("super+t=unbind")
    public static var keybinds: [String] { unbound.map { $0 + "=unbind" } }

    /// 설정 파일 꼴 (scripts/terminal-keybinds.conf 의 내용)
    public static var configText: String { keybinds.map { "keybind = \($0)\n" }.joined() }
}
