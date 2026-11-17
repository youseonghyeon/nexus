// ⌘ 를 누르고 있으면 사이드바 서버 행에 1–9 번호, ⌘1–⌘9 로 그 서버를 고른다 (2026-10-26, Claude 앱 최근 항목과 같은 방식).
// 번호는 보이는 서버에만: 사이드바 순서(그룹 순서 → 그룹 안 순서), 접힌 그룹은 건너뛴다. 숫자 키는 위치로 본다(한글 입력기·AZERTY 와 무관).
// 번호는 ⌘ 만 잠깐 누르고 있을 때 뜬다 — ⌘C 처럼 빨리 누르는 조합마다 번쩍이지 않게 (QuickSelectBadges).

import Foundation

public enum QuickSelect {
    public static let limit = 9

    /// 번호를 받을 서버 키 (앞 9개). 검색 중엔 모든 그룹이 펼쳐져 보이므로 접힘을 보지 않는다.
    public static func keys(groups: [(group: String, servers: [String])], collapsed: Set<String>, searching: Bool) -> [String] {
        Array(groups.filter { searching || !collapsed.contains($0.group) }.flatMap(\.servers).prefix(limit))
    }

    /// 번호(1부터) → 서버 키. 번호가 없는 자리면 nil.
    public static func key(for number: Int, in keys: [String]) -> String? {
        keys.indices.contains(number - 1) ? keys[number - 1] : nil
    }

    /// 숫자 키 1–9 (kVK_ANSI_1…9 · 키패드 1…9)
    public static func number(keyCode: UInt16) -> Int? {
        if let index = row.firstIndex(of: keyCode) { return index + 1 }
        if let index = keypad.firstIndex(of: keyCode) { return index + 1 }
        return nil
    }

    /// ⌘ 만 (Shift·Option·Control 이 같이면 아님 — ⌘⇧[ 탭 이동 등). Caps Lock·fn 은 보지 않는다.
    public static func commandOnly(command: Bool, shift: Bool, option: Bool, control: Bool) -> Bool {
        command && !shift && !option && !control
    }

    private static let row: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    private static let keypad: [UInt16] = [83, 84, 85, 86, 87, 88, 89, 91, 92]
}

/// 번호를 보일지: ⌘ 만 delay 동안 누르고 있으면 보인다. 그 사이 숫자 아닌 키를 같이 누르면(⌘C 등) 이번 누름 동안은 안 보인다.
/// ⌘ 를 떼거나 다른 수정 키가 붙으면 바로 숨긴다. reset = 앱이 비활성으로 (⌘Tab — 뗌 이벤트가 이 앱에 오지 않는다).
public struct QuickSelectBadges: Sendable, Equatable {
    public static let delay: TimeInterval = 0.2

    public private(set) var visible = false
    /// ⌘ 만 눌리기 시작한 시각
    private var armedAt: Date?
    /// 이번 누름 동안 막힘 (숫자 아닌 키를 같이 눌렀다) — 수정 키가 바뀌어(⌘⇧ → ⌘) 다시 ⌘ 만 남아도 뜨지 않게
    private var blocked = false

    public init() {}

    public mutating func modifiersChanged(commandOnly: Bool, at now: Date) {
        if commandOnly {
            if armedAt == nil, !visible, !blocked { armedAt = now }
        } else {
            armedAt = nil
            visible = false
            blocked = false
        }
    }

    public mutating func keyDown(isNumber: Bool) {
        guard !isNumber else { return }
        armedAt = nil
        visible = false
        blocked = true
    }

    public mutating func tick(at now: Date) {
        if let armedAt, now.timeIntervalSince(armedAt) >= Self.delay - 0.001 { visible = true }
    }

    public mutating func reset() {
        armedAt = nil
        visible = false
        blocked = false
    }
}
