// 화면 모드 (설정 창 · 보기 메뉴): 이 앱만의 라이트 · 다크와, 그 위에 면 색의 기운만 바꾼 변형 넷.
//   System · Light · Dark      macOS 설정 / 밝음 / 어두움 (원래 있던 셋 — 기운 없음)
//   Dusk · Midnight            어두운 계열: 따뜻한 갈회색 · 남색 기운
//   Paper · Mist               밝은 계열: 크림색 · 푸른 회색
// 변형은 팔레트를 새로 잡지 않는다: 기준 면 색(사이드바 < 본문 < 카드 < 조작부)의 각 성분에 같은 값(shift)을 더할 뿐이라 면 단계의 명암 관계가 그대로다.
// 상태 색(초록 · 노랑 · 빨강) · 글자 색 · 선은 건드리지 않는다 — 색은 여전히 의미에만 쓴다.
// 저장은 UserDefaults "appearance" (원래 키 · 원래 값 system/light/dark 그대로 읽힌다). 적용은 앱 쪽(Theme.swift).

import Foundation

public enum ScreenMode: String, CaseIterable, Sendable {
    case system, light, dark, dusk, midnight, paper, mist

    public static let defaultsKey = "appearance"

    /// 저장된 값 → 모드. 없거나 목록 밖이면 System
    public static func resolve(_ stored: String?) -> ScreenMode {
        stored.flatMap(ScreenMode.init(rawValue:)) ?? .system
    }

    public var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        case .dusk: return "Dusk"
        case .midnight: return "Midnight"
        case .paper: return "Paper"
        case .mist: return "Mist"
        }
    }

    /// 바탕이 되는 계열 — macOS 의 라이트 · 다크 중 어느 쪽 위에 그리나 (system 은 macOS 설정을 따른다)
    public enum Family: Sendable, Equatable { case system, light, dark }

    public var family: Family {
        switch self {
        case .system: return .system
        case .light, .paper, .mist: return .light
        case .dark, .dusk, .midnight: return .dark
        }
    }

    /// 면 색에 더하는 기운 (빨강 · 초록 · 파랑, 0–255 눈금)
    public struct Shift: Sendable, Equatable {
        public let r: Int, g: Int, b: Int
        public init(_ r: Int, _ g: Int, _ b: Int) { self.r = r; self.g = g; self.b = b }
        public static let none = Shift(0, 0, 0)
    }

    public var shift: Shift {
        switch self {
        case .system, .light, .dark: return .none
        case .dusk: return Shift(9, 5, -2)
        case .midnight: return Shift(-5, 1, 11)
        case .paper: return Shift(1, -3, -14)
        case .mist: return Shift(-9, -3, 4)
        }
    }

    /// 0xRRGGBB 에 기운을 더한 색 (성분마다 0–255 로 자른다 — 흰 카드에 더하면 흰색에 머문다)
    public static func shifted(_ hex: UInt32, by shift: Shift) -> UInt32 {
        func channel(_ value: UInt32, _ delta: Int) -> UInt32 { UInt32(max(0, min(255, Int(value) + delta))) }
        return channel((hex >> 16) & 0xFF, shift.r) << 16 | channel((hex >> 8) & 0xFF, shift.g) << 8 | channel(hex & 0xFF, shift.b)
    }
}
