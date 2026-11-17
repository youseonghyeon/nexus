// 앱 설정 창(⌘,)의 값: 저장 키 · 고를 수 있는 값 · 기본값. 저장된 값이 목록 밖(손으로 고친 defaults 등)이면 기본값을 쓴다.
// 저장은 UserDefaults (앱 쪽 AppSettings). 여기는 키와 판정만.

import Foundation

public struct IntervalPreference: Sendable, Equatable {
    public let key: String
    public let choices: [Double]
    public let defaultValue: Double

    /// 고를 수 있는 값이면 그대로, 아니면 기본값
    public func resolve(_ stored: Double?) -> Double {
        guard let stored, choices.contains(stored) else { return defaultValue }
        return stored
    }
}

public enum AppPreferences {
    /// 서버 상태 확인 갱신 루프 (기본 5초) — 사이드바 요약도 이 간격
    public static let statusInterval = IntervalPreference(key: "statusCheckInterval", choices: [3, 5, 10, 30], defaultValue: 5)
    /// LOCAL 화면 갱신 (그 화면을 보고 있을 때만). System·Disk 는 1초도 — 한 번에 커널 값·IOKit·ps 하나(~10ms)뿐이고
    /// diskutil 목록은 간격과 따로 30초. 서버 상태 확인·Live(ssh)·Bluetooth(system_profiler)는 1초가 무거워 넣지 않는다 (2026-11-01)
    public static let systemInterval = IntervalPreference(key: "systemRefreshInterval", choices: [1, 2, 3, 5, 10], defaultValue: 3)
    public static let diskInterval = IntervalPreference(key: "diskRefreshInterval", choices: [1, 2, 3, 5, 10], defaultValue: 2)
    public static let bluetoothInterval = IntervalPreference(key: "bluetoothRefreshInterval", choices: [5, 10, 30], defaultValue: 5)
    /// 서버 정보의 "실시간" 탭 (리눅스 · Windows 서버, 그 탭을 보고 있을 때만 ssh 한 번)
    public static let serverLiveInterval = IntervalPreference(key: "serverLiveInterval", choices: [3, 5, 10, 30], defaultValue: 5)

    /// 시스템 화면 코어 막대가 값 사이를 이어 움직이는가 (기본 켬)
    public static let coreAnimationKey = "coreBarAnimation"
    /// 터널을 localhost 대신 서버 이름(루프백 별칭)으로 열기 — 터널 입력창 체크박스와 같은 값 (기본 켬)
    public static let namedTunnelsKey = "namedTunnels"
    /// 원격 파일 탐색에서 숨김 파일 보기 — 탐색 창 체크박스와 같은 값 (기본 끔)
    public static let remoteShowHiddenKey = "remoteBrowserShowHidden"

    /// 앱 안 브라우저의 쿠키 저장소 ID (서버별 — 로그인이 여기 남는다)
    public static func browserStoreKey(for server: String) -> String { "browserStore.\(server)" }
    /// 서버별로 고른 계정 ({서버 키: 계정}) — 서버 정보의 사용자 칸 (ServerConfig.applyingAccounts)
    public static let activeAccountsKey = "activeAccounts"
    /// 서버별 깨우기 경로 (설정 창). 값은 wol_via 의 서버 키
    public static func wakeRouteKey(for server: String) -> String { "wakeRoute.\(server)" }
    /// 고른 경로가 목록에 있으면 그것, 없으면(처음·servers.conf 에서 빠짐) 첫 경로
    public static func wakeRoute(_ routes: [WakeRoute], stored: String?) -> WakeRoute? {
        routes.first { $0.via == stored } ?? routes.first
    }
}

/// 설정 창의 "터미널 색" — 이 앱의 터미널 탭에만 (Ghostty 앱·macOS 터미널 설정과 무관).
/// 미적용: 지금처럼 — theme=on 그룹의 SSH 탭만 Rosé Pine, 나머지는 터미널 기본색. 밝음·어두움: 모든 탭을 그 팔레트로.
public enum TerminalColorMode: String, CaseIterable, Sendable {
    case none, light, dark

    public static let key = "terminalColorMode"

    public var title: String {
        switch self {
        case .none: return "미적용"
        case .light: return "밝음"
        case .dark: return "어두움"
        }
    }

    /// 저장된 값이 목록 밖이면 미적용
    public static func resolve(_ stored: String?) -> TerminalColorMode {
        stored.flatMap(TerminalColorMode.init(rawValue:)) ?? .none
    }

    /// 탭 색. themed: theme=on 그룹의 SSH 탭. nil 이면 앱이 색을 정하지 않는다(터미널 기본색).
    public func palette(themed: Bool) -> TerminalPalette? {
        switch self {
        case .none: return themed ? .rosePine : nil
        case .light: return .rosePineDawn
        case .dark: return .rosePine
        }
    }

    /// theme=on 그룹에 주입하는 원격 프롬프트·vim 색 — 탭 바탕에 맞춘다
    public var promptPalette: TerminalPalette { palette(themed: true) ?? .rosePine }
}
