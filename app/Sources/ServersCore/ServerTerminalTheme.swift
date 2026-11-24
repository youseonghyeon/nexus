// 서버별 터미널 테마 (서버 화면 접속 카드의 "테마" 줄): 그 서버의 터미널 탭 색을 서버마다 따로 고른다 — 운영·시험 서버를 색으로 가르는 용도.
// 고른 테마가 있으면 그것, 없으면 터미널 기본색. 터미널 색을 정하는 곳은 여기 하나다 — 그룹 theme=on(Rosé Pine 탭 · 프롬프트 · vim 주입)과 설정 창의 "터미널 색"은 2026-11-24 에 뺐다.
// 저장은 UserDefaults ({서버 키: 테마 id} — AppPreferences.terminalThemesKey). 서버 이름을 바꾸면 옮기고 지우면 버린다 (renaming · removing).
// 테마는 여기 표에 한 줄씩 보탠다. 고르는 화면은 기본 + 다섯 = 2행 3열로 맞췄다 (TerminalThemePicker) — 더 넣으면 줄이 는다.

import Foundation

/// 터미널 색 한 벌: 바탕·글자·커서·16색. 쓰는 곳은 서버별 테마(ServerTerminalTheme) — 예전 Rosé Pine 두 벌(그룹 테마 · 설정의 터미널 색)은 2026-11-24 에 뺐다.
public struct TerminalPalette: Sendable, Equatable {
    public let background: String
    public let foreground: String
    public let cursor: String
    public let colors: [String]

    public init(background: String, foreground: String, cursor: String, colors: [String]) {
        self.background = background; self.foreground = foreground; self.cursor = cursor; self.colors = colors
    }
}

public struct ServerTerminalTheme: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let palette: TerminalPalette

    /// 앱 화면(무채색 어두운 면)과 이어지는 차가운 회색 — Rosé Pine 의 보랏빛이 없는 어두운 테마
    public static let graphite = ServerTerminalTheme(id: "graphite", title: "Graphite", palette: TerminalPalette(
        background: "#16171a", foreground: "#d7d9de", cursor: "#9aa0aa",
        colors: ["#23252a", "#e0736b", "#7dbf8e", "#d9b36a",
                 "#7aa2d6", "#b08fd0", "#6fbfc4", "#c9ccd2",
                 "#5c616b", "#f08a82", "#93d3a3", "#e8c783",
                 "#92b6e6", "#c3a4e0", "#86d1d6", "#f1f2f4"]))

    /// 따뜻한 종이 바탕에 먹빛 글자 — 밝은 테마. 흰색(7 · 15)은 밝은 바탕에서 읽히게 회색 · 먹빛으로 둔다
    public static let paper = ServerTerminalTheme(id: "paper", title: "Paper", palette: TerminalPalette(
        background: "#f7f5f0", foreground: "#2f3136", cursor: "#6b6f78",
        colors: ["#3a3c42", "#b5403a", "#2f7d4f", "#9a6b12",
                 "#2b62a8", "#7d4ea3", "#1f7a80", "#6e7178",
                 "#8a8d94", "#c9544d", "#3e9461", "#b38220",
                 "#3f78c2", "#9364b9", "#2f9299", "#1e2024"]))

    /// 눈이 편한 색: 따뜻한 갈회색 바탕에 크림색 글자 — 대비를 낮추고 파란 기운과 순백을 뺐다 (오래 보는 화면용)
    public static let dusk = ServerTerminalTheme(id: "dusk", title: "Dusk", palette: TerminalPalette(
        background: "#282420", foreground: "#d4c8b4", cursor: "#b8a88c",
        colors: ["#332e29", "#c9776a", "#9aa97a", "#cfa76a",
                 "#8a9db0", "#b48ea0", "#8fae9f", "#c8bca8",
                 "#6b6258", "#d98c7f", "#adbb8c", "#ddb97f",
                 "#9fb0bf", "#c5a1b2", "#a3c0b1", "#e6dcc8"]))

    /// 스테이징 · 시험 서버: 짙은 남색 바탕 — 태그 배지의 스테이징 파랑과 같은 약속
    public static let harbor = ServerTerminalTheme(id: "harbor", title: "Harbor", palette: TerminalPalette(
        background: "#101b2d", foreground: "#d3dbe8", cursor: "#7fa6d9",
        colors: ["#1a2940", "#e07a7a", "#7fc49a", "#dcb86e",
                 "#6fa8e8", "#a995e0", "#62c2cf", "#c3ccda",
                 "#55657e", "#f09090", "#96d6ae", "#ebcb86",
                 "#8dbcf2", "#beacee", "#7fd4df", "#eef2f8"]))

    /// 운영 서버(위험): 짙은 적갈색 바탕 — 태그 배지의 운영 빨강과 같은 약속. 바탕이 붉어 오류의 빨간 글자가 묻히므로 글자용 빨강(1 · 9)은 밝은 주황 쪽으로
    public static let redline = ServerTerminalTheme(id: "redline", title: "Redline", palette: TerminalPalette(
        background: "#2a1014", foreground: "#f0dcd6", cursor: "#ff8f6b",
        colors: ["#3b181d", "#ff9466", "#9ccf8a", "#f0c36a",
                 "#8ab4e8", "#d79be0", "#7fcdc4", "#e0ccc6",
                 "#7d5a5c", "#ffad85", "#b3e0a2", "#f7d488",
                 "#a5c8f2", "#e5b3ec", "#99ddd5", "#fff3ee"]))

    /// 고르는 화면의 순서 (기본 다음 — 2행 3열): 윗줄은 평소에 쓰는 베이스, 아랫줄은 용도가 있는 색(눈이 편한 · 스테이징 · 운영)
    public static let all: [ServerTerminalTheme] = [graphite, paper, dusk, harbor, redline]

    /// 저장된 id → 테마. 없거나 목록 밖(지운 테마 · 손으로 고친 값)이면 nil = 고르지 않음
    public static func find(_ id: String?) -> ServerTerminalTheme? {
        id.flatMap { id in all.first { $0.id == id } }
    }

    /// 고르기 · 풀기 (id 가 nil 이거나 목록 밖이면 그 서버의 값을 지운다)
    public static func setting(_ id: String?, for server: String, in stored: [String: String]) -> [String: String] {
        var next = stored
        next[server] = find(id)?.id
        return next
    }

    /// 서버 이름 변경: 옛 이름의 값을 새 이름으로. 옛 값이 없으면 새 이름에 남아 있던 값(지운 서버의 것)도 지운다
    public static func renaming(from old: String, to new: String, in stored: [String: String]) -> [String: String] {
        var next = stored
        next[new] = next.removeValue(forKey: old)
        return next
    }

    public static func removing(_ server: String, from stored: [String: String]) -> [String: String] {
        var next = stored
        next[server] = nil
        return next
    }
}
