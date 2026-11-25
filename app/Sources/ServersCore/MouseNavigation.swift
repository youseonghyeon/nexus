// 브라우저 탭의 뒤로 · 앞으로를 마우스 옆 버튼과 ⌘[ · ⌘] 로: 브라우저 탭이 보일 때 본창에서 누르면 그 탭의 뒤로 · 앞으로 (툴바의 ‹ › 와 같은 동작).
// 웹 뷰(WKWebView)는 옆 버튼도 ⌘[ · ⌘] 도 스스로 처리하지 않는다 — 감시(MouseShortcuts)가 창에 가기 전에 받아 이 판정대로 한다.
// macOS 의 버튼 번호: 0 왼쪽 · 1 오른쪽 · 2 가운데 · 3 뒤로 · 4 앞으로. 마우스 드라이버(Logitech 등)는 옆 버튼을 ⌘[ · ⌘] 키로 바꿔 보내기도 한다.

public enum MouseNavigation {
    public static let backButton = 3
    public static let forwardButton = 4
    public static let backKeyCode: UInt16 = 33      // kVK_ANSI_LeftBracket
    public static let forwardKeyCode: UInt16 = 30   // kVK_ANSI_RightBracket

    public enum Direction: Sendable, Equatable {
        case back, forward
    }

    public enum Action: Sendable, Equatable {
        case back
        case forward
        case swallow   // 갈 곳이 없다 — 꺼진 ‹ › 버튼처럼 아무 일도 없게 (페이지로 흘리지 않는다)
    }

    public static func direction(button: Int) -> Direction? {
        switch button {
        case backButton: return .back
        case forwardButton: return .forward
        default: return nil
        }
    }

    /// ⌘[ · ⌘] — ⌘ 만 누른 것 (⌘⇧[ · ⌘⇧] 는 탭 이동). 키는 자리로 본다 (입력기 · 배열과 무관)
    public static func direction(keyCode: UInt16, command: Bool, shift: Bool, option: Bool, control: Bool) -> Direction? {
        guard command, !shift, !option, !control else { return nil }
        switch keyCode {
        case backKeyCode: return .back
        case forwardKeyCode: return .forward
        default: return nil
        }
    }

    /// nil 이면 건드리지 않고 흘린다 (뒤로 · 앞으로 입력이 아님 · 본창이 아님 · 시트가 떠 있음 · 보이는 탭이 브라우저가 아님 — 터미널 탭의 ⌘[ 는 터미널이 받는다)
    public static func action(_ direction: Direction?, mainWindow: Bool, sheetOpen: Bool, browserVisible: Bool, canGoBack: Bool, canGoForward: Bool) -> Action? {
        guard let direction, mainWindow, !sheetOpen, browserVisible else { return nil }
        switch direction {
        case .back: return canGoBack ? .back : .swallow
        case .forward: return canGoForward ? .forward : .swallow
        }
    }
}
