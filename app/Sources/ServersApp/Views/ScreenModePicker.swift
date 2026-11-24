// 설정 창의 화면 모드 고르기: 모드마다 작은 창 그림(사이드바 · 본문 · 카드 · 조작부를 그 모드의 색으로)을 보이고, 누르면 바로 건다.
// 서버의 터미널 테마 고르기(TerminalThemePicker)와 같은 말투 — 고른 것은 올라온 면 + 가는 선 + 체크.
// 그림의 색은 지금 걸린 모드와 무관하게 그 모드의 값: 기준 면 색(Palette.*Hex)에 그 모드의 기운(ScreenMode.shift)을 더한다.

import ServersCore
import SwiftUI

struct ScreenModePicker: View {
    let selected: ScreenMode
    let pick: (ScreenMode) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(ScreenModeThumbnail.width + 12), spacing: 2), count: 4), alignment: .leading, spacing: 2) {
            ForEach(ScreenMode.allCases, id: \.self) { mode in
                ScreenModeTile(mode: mode, selected: mode == selected) { pick(mode) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ScreenModeTile: View {
    let mode: ScreenMode
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                ScreenModeThumbnail(mode: mode)
                HStack(spacing: 4) {
                    Text(mode.title).font(.callout).fontWeight(selected ? .medium : .regular)
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
        .accessibilityLabel(selected ? "\(mode.title) (선택됨)" : mode.title)
    }
}

/// 작은 창 그림. System 은 왼쪽 위 절반이 밝음 · 오른쪽 아래 절반이 어두움 (macOS 설정을 따른다는 뜻)
struct ScreenModeThumbnail: View {
    static let width: CGFloat = 88
    static let height: CGFloat = 58
    let mode: ScreenMode

    var body: some View {
        Group {
            if mode.family == .system {
                ZStack {
                    MiniWindow(dark: true, shift: .none)
                    MiniWindow(dark: false, shift: .none).mask(Diagonal())
                }
            } else {
                MiniWindow(dark: mode.family == .dark, shift: mode.shift)
            }
        }
        .frame(width: Self.width, height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous).strokeBorder(Palette.hairline))
        .accessibilityHidden(true)
    }

    /// 왼쪽 위 삼각형
    private struct Diagonal: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in p.move(to: rect.origin); p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)); p.closeSubpath() }
        }
    }

    /// 사이드바(행 셋 · 고른 행 하나) + 본문(카드 하나 · 조작부 하나) — 면 네 단계가 다 보이게
    private struct MiniWindow: View {
        let dark: Bool
        let shift: ScreenMode.Shift

        var body: some View {
            let ink = dark ? Color.white : Color.black
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    bar(ink.opacity(0.28), 14)
                    RoundedRectangle(cornerRadius: 2).fill(surface(Palette.controlHex)).frame(width: 22, height: 7)
                        .overlay(alignment: .leading) { bar(ink.opacity(0.55), 12).padding(.leading, 3) }
                    bar(ink.opacity(0.28), 16)
                    bar(ink.opacity(0.28), 11)
                    Spacer(minLength: 0)
                }
                .padding(.top, 9).padding(.leading, 4)
                .frame(width: 30, alignment: .leading).frame(maxHeight: .infinity)
                .background(surface(Palette.sidebarHex))
                VStack(alignment: .leading, spacing: 4) {
                    VStack(alignment: .leading, spacing: 3) {
                        bar(ink.opacity(0.7), 20)
                        bar(ink.opacity(0.3), 34)
                        HStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 2).fill(surface(Palette.controlHex)).frame(width: 14, height: 6)
                            RoundedRectangle(cornerRadius: 2).fill(surface(Palette.controlHex)).frame(width: 14, height: 6)
                        }
                    }
                    .padding(5).frame(maxWidth: .infinity, alignment: .leading)
                    .background(surface(Palette.cardHex), in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(ink.opacity(0.08), lineWidth: 0.5))
                    Spacer(minLength: 0)
                }
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(surface(Palette.contentHex))
            }
        }

        private func bar(_ color: Color, _ width: CGFloat) -> some View {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: width, height: 2.5)
        }

        private func surface(_ hex: (dark: UInt32, light: UInt32)) -> Color {
            let value = ScreenMode.shifted(dark ? hex.dark : hex.light, by: shift)
            return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
        }
    }
}
