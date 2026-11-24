// 서버 화면 접속 카드의 "테마" 줄: 그 서버의 터미널 탭 색 (ServersCore ServerTerminalTheme).
// [선택] 을 누르면 작은 터미널 그림들이 뜨고(기본 + 테마들 — 2~6개를 가정한 세 칸 격자), 누르면 바로 적용하고 닫는다. 열린 탭에도 바로 바뀐다.
// 기본 = 고르지 않음: 터미널 기본색.

import ServersCore
import SwiftUI

/// 접속 카드의 한 줄: 지금 테마 이름 · [선택]
struct TerminalThemeRow: View {
    @Environment(AppModel.self) private var model
    let server: Server
    @State private var picking = false

    var body: some View {
        let current = model.terminalTheme(for: server.key)
        HStack(spacing: 6) {
            Text(current?.title ?? "기본")
            Button("선택") { picking = true }.buttonStyle(.borderless)
                .popover(isPresented: $picking, arrowEdge: .bottom) {
                    TerminalThemePickerContent(selected: current?.id) { id in
                        model.setTerminalTheme(id, for: server)
                        picking = false
                    }
                }
        }
    }
}

/// 고르는 화면 (값만 받는다 — 스크래치에서 비트맵으로 확인)
struct TerminalThemePickerContent: View {
    /// 지금 고른 테마의 id (nil = 기본)
    let selected: String?
    let pick: (String?) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(ThemeThumbnail.width + 12), spacing: 4), count: 3), alignment: .leading, spacing: 4) {
            tile(nil, "기본", nil)
            ForEach(ServerTerminalTheme.all) { theme in tile(theme.id, theme.title, theme.palette) }
        }
        .padding(10)
        .tint(Palette.neutralTint)
    }

    private func tile(_ id: String?, _ title: String, _ palette: TerminalPalette?) -> some View {
        ThemeTile(title: title, palette: palette, selected: selected == id) { pick(id) }
    }
}

/// 테마 하나: 작은 터미널 그림 + 이름. 고른 것은 올라온 면 + 가는 선 (탭 · 사이드바의 선택과 같은 말투) 과 체크
private struct ThemeTile: View {
    let title: String
    let palette: TerminalPalette?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ThemeThumbnail(palette: palette)
                HStack(spacing: 4) {
                    Text(title).font(.callout).fontWeight(selected ? .medium : .regular)
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 2)
            }
            .padding(6)
            .background(selected ? Palette.raised : (hovering ? Palette.controlHover.opacity(0.5) : Color.clear),
                        in: RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous).strokeBorder(selected ? Palette.hairline : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(selected ? "\(title) (선택됨)" : title)
    }
}

/// 작은 터미널 그림: 그 테마의 바탕 · 글자 · ANSI 색으로 몇 줄. palette 가 nil 이면(앱이 색을 정하지 않음) 터미널 기본색에 가까운 무채색.
struct ThemeThumbnail: View {
    static let width: CGFloat = 156
    let palette: TerminalPalette?

    var body: some View {
        let p = Colors(palette)
        VStack(alignment: .leading, spacing: 2) {
            line([("deploy@web", p.ansi(2)), (" ~ ", p.foreground), ("❯ ", p.cursor), ("ls -l", p.foreground)])
            line([("drwxr-xr-x  ", p.ansi(8)), ("logs/", p.ansi(4))])
            line([("-rwxr-xr-x  ", p.ansi(8)), ("deploy.sh", p.ansi(2))])
            line([("error: ", p.ansi(1)), ("exit 1", p.foreground)])
            HStack(spacing: 0) {
                line([("deploy@web", p.ansi(2)), (" ~ ", p.foreground), ("❯ ", p.cursor)])
                Rectangle().fill(p.cursor).frame(width: 5, height: 10)
            }
        }
        .padding(8)
        .frame(width: Self.width, height: 84, alignment: .topLeading)
        .background(p.background, in: RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous).strokeBorder(Palette.hairline))
        .accessibilityHidden(true)
    }

    private func line(_ parts: [(String, Color)]) -> some View {
        parts.reduce(Text(verbatim: "")) { $0 + Text(verbatim: $1.0).foregroundStyle($1.1) }
            .font(.system(size: 9, design: .monospaced)).lineLimit(1).fixedSize()
    }

    /// 팔레트의 "#rrggbb" → 색. 팔레트가 없으면 터미널 기본색에 가까운 값
    private struct Colors {
        let background: Color, foreground: Color, cursor: Color
        private let palette: [Color]

        init(_ p: TerminalPalette?) {
            let fallback = ["#1d1f21", "#cc6666", "#b5bd68", "#f0c674", "#81a2be", "#b294bb", "#8abeb7", "#c5c8c6",
                            "#666666", "#d54e53", "#b9ca4a", "#e7c547", "#7aa6da", "#c397d8", "#70c0b1", "#eaeaea"]
            background = Self.color(p?.background ?? "#1d1f21")
            foreground = Self.color(p?.foreground ?? "#c5c8c6")
            cursor = Self.color(p?.cursor ?? "#c5c8c6")
            palette = (p?.colors ?? fallback).map(Self.color)
        }

        func ansi(_ index: Int) -> Color { palette.indices.contains(index) ? palette[index] : foreground }

        static func color(_ hex: String) -> Color {
            let value = UInt32(hex.dropFirst(), radix: 16) ?? 0x808080
            return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
        }
    }
}
