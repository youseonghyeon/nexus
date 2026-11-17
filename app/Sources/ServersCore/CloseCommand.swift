// ⌘W 판정: 어느 창이 앞에 있고 본창에 보이는 탭이 있는가 → 무엇을 닫나.
// ⌘W 는 키 감시(TerminalShortcuts)가 모든 창에서 먼저 받아 이 판정대로만 처리한다 — 메뉴 [Close Tab] 의 ⌘W 까지 가지 않는다.
// 예전엔 키 감시(본창만)와 메뉴(어느 창이든, 탭 없으면 비활성)가 나눠 맡아 틈이 생겼다:
// Dashboard 에서 창이 안 닫힘 · 시트 뒤의 터미널 탭이 닫힘 · 설정 창에서 본창 탭이 닫힘 (2026-10-07).

public enum CloseCommand {
    /// 키 창의 종류
    public enum Window: Sendable, Equatable {
        case main       // 본창 (AppDelegate)
        case mainFullScreen  // 전체 화면 본창 — 숨기면 빈 Space 가 남으므로 탭만 닫는다
        case sheet      // 본창에 붙은 시트 — 뒤에 있는 탭을 건드리지 않는다
        case closable   // 닫기 버튼이 있는 다른 창 (설정 창)
        case other      // 팝오버·모달 패널(열기·저장) 등 — 닫으면 안 되거나 닫기 버튼이 없는 창
        case none       // 키 창 없음
    }

    public enum Action: Sendable, Equatable {
        case closeTab   // 본창의 보이는 탭(그 셸)만
        case hideMain   // 본창 닫기 = 숨기기 (터미널 세션·터널 유지)
        case closeWindow
        case ignore
    }

    public static func action(window: Window, hasVisibleTab: Bool) -> Action {
        switch window {
        case .main: return hasVisibleTab ? .closeTab : .hideMain
        case .mainFullScreen: return hasVisibleTab ? .closeTab : .ignore
        case .closable: return .closeWindow
        case .sheet, .other, .none: return .ignore
        }
    }
}
