// 화면의 뼈대: 상태 색(StatusTone) · 화면 모드 적용(ScreenMode.apply) · 바탕 팔레트(Palette) · 치수(Metrics) · 글자 단계(Font) ·
// 카드 면(cardSurface) · 상태 점·알약(StatusDot·StatusPill).

import ServersCore
import SwiftUI

enum StatusTone {
    case good, warn, bad, muted, accent
    /// 상태 색은 시스템 원색 대신 이 앱의 것: 어두운 바탕에서 형광으로 튀지 않게 채도를 한 단계 낮추고, 라이트에선 흰 카드 위 글자로도 읽히게 진하게.
    /// 매 그리기마다 동적 NSColor 를 새로 만들지 않도록 한 번만 만든다 (provider 가 라이트·다크를 그때그때 고른다)
    private static let goodColor = Color(nsColor: Palette.dynamic(dark: 0x3FD68A, light: 0x1F9D57))
    private static let warnColor = Color(nsColor: Palette.dynamic(dark: 0xF2BE4A, light: 0xB8730A))   // 라이트의 노랑은 흰 카드에서 안 읽힌다 — 진한 호박색
    private static let badColor = Color(nsColor: Palette.dynamic(dark: 0xFF6B60, light: 0xD63F36))
    var color: Color {
        switch self {
        case .good: return Self.goodColor
        case .warn: return Self.warnColor
        case .bad: return Self.badColor
        case .muted: return .secondary
        case .accent: return .accentColor
        }
    }
}

/// 화면 모드 (설정 창 · 보기 ▸ 화면 모드): 목록 · 계열 · 면 색의 기운은 ServersCore ScreenMode, 여기는 적용만.
typealias AppearanceMode = ScreenMode

extension ScreenMode {
    static var stored: ScreenMode { resolve(UserDefaults.standard.string(forKey: defaultsKey)) }

    /// 계열(라이트 · 다크)은 앱의 모양(NSApp.appearance)으로, 기운은 팔레트(Palette.shift)로 건다.
    /// 같은 계열 안에서 기운만 바뀌면 macOS 가 모양이 그대로라고 보고 색을 다시 풀지 않는다 — 한 번 같은 계열의 다른 모양(vibrant)을 거쳤다 돌아온다.
    /// 한 차례 안에 왕복하면 소용없고(SwiftUI 가 중간을 못 본다) 화면이 한 번 그려질 틈이 있어야 한다 (2026-11-24 화면 밖 창으로 실험: 0.02초면 됐다).
    @MainActor func apply() {
        let target: NSAppearance? = family == .system ? nil : NSAppearance(named: family == .dark ? .darkAqua : .aqua)
        guard Palette.shift != shift else { NSApp.appearance = target; return }   // 기운이 그대로면(시작 때 · Light ↔ Dark) 모양만
        Palette.shift = shift
        if family == .system { NSApp.appearance = nil }   // macOS 설정이 어느 쪽인지 보려고
        let dark = family == .dark || (family == .system && NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        NSApp.appearance = NSAppearance(named: dark ? .vibrantDark : .vibrantLight)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // 그 사이 다른 모드를 골랐으면 그쪽의 적용에 맡긴다
            if ScreenMode.stored == self { NSApp.appearance = target }
        }
    }
}

/// 화면 바탕 팔레트 (2026-11-10 다시 잡음). 면은 네 단계 — 사이드바 < 본문 < 카드 < 조작부 — 로 깊이를 만들고,
/// 카드·조작부 가장자리는 머리카락 선(hairline)으로 한 번 더 가른다. 순회색 대신 아주 약하게 차가운 회색(파랑 +2)이라 초록·노랑 상태 색이 또렷하다.
/// 라이트는 같은 명암 관계. 시스템 재질 대신 이 색으로 칠한다.
enum Palette {
    /// 화면 모드가 면 색에 더하는 기운 (ScreenMode.shift — Dusk · Midnight · Paper · Mist). 색을 풀 때마다 읽는다; 바꾸는 곳은 ScreenMode.apply 뿐.
    /// 시작 때는 저장된 모드의 값으로 — 창이 처음 그려질 때부터 그 색이게.
    nonisolated(unsafe) static var shift: ScreenMode.Shift = ScreenMode.stored.shift

    /// 면 네 단계의 기준 색 (Dark · Light). 화면 모드 미리 보기(ScreenModeThumbnail)도 이 값에 기운을 더해 그린다
    static let sidebarHex: (dark: UInt32, light: UInt32) = (0x0F1012, 0xEAEAE8)
    static let contentHex: (dark: UInt32, light: UInt32) = (0x141517, 0xF4F4F2)
    static let cardHex: (dark: UInt32, light: UInt32) = (0x1B1C1F, 0xFFFFFF)
    static let controlHex: (dark: UInt32, light: UInt32) = (0x27282C, 0xECECEA)

    static let sidebarNS = dynamic(dark: sidebarHex.dark, light: sidebarHex.light)
    static let contentNS = dynamic(dark: contentHex.dark, light: contentHex.light)
    static let sidebar = Color(nsColor: sidebarNS)
    static let content = Color(nsColor: contentNS)
    /// 카드 · 검색칸
    static let card = Color(nsColor: dynamic(dark: cardHex.dark, light: cardHex.light))
    /// 보조 버튼
    static let control = Color(nsColor: dynamic(dark: controlHex.dark, light: controlHex.light))
    /// 보조 버튼에 마우스를 올렸을 때
    static let controlHover = Color(nsColor: dynamic(dark: 0x303136, light: 0xE3E3E1))
    /// 카드 안 입력칸·탭 바탕 (카드보다 한 단계 깊게)
    static let well = Color(nsColor: dynamic(dark: 0x131416, light: 0xF2F2F0))
    /// 고른 칸·활성 탭처럼 바탕에서 "올라온" 면. 다크는 조작부와 같은 밝은 면, 라이트는 흰색 —
    /// 라이트에서 조작부 회색(E9)을 쓰면 고른 칸이 제 바탕(F0)보다 어두워 눌려 들어간 것처럼 보였다 (다크와 관계가 뒤집힘, 2026-11-10 측정)
    static let raised = Color(nsColor: dynamic(dark: 0x27282C, light: 0xFFFFFF))
    /// 토글·고르개 같은 시스템 조작부에 주는 무채색 (화면 뿌리의 tint). 앱 강조색을 바꾸면 신호등 버튼까지 회색이 돼 이쪽으로 한다
    static let neutralTint = Color(nsColor: dynamic(dark: 0x8E8E93, light: 0x6E6E73))
    /// 사이드바에서 고른 행의 면 — 사이드바 바탕(가장 어두운 면)에서 올라온 면. 다크는 카드보다 한 단계 밝게, 라이트는 흰색
    static let raisedSidebar = Color(nsColor: dynamic(dark: 0x222327, light: 0xFFFFFF))
    /// 입력칸 면. 다크는 우묵한 면 그대로, 라이트는 거의 흰색 — 흰 카드 위의 회색 칸(F0)은 꺼진 칸처럼 보였다
    static let field = Color(nsColor: dynamic(dark: 0x131416, light: 0xFBFBFA))
    /// 입력칸 테두리 (카드 선보다 또렷하게 — 칸의 자리를 선이 알려 준다). 다크 흰 10%, 라이트 검정 14%
    static let fieldBorder = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.14)
    })
    /// 면의 가장자리 선 (카드·조작부·입력칸). 다크는 흰 7%, 라이트는 검정 8%
    static let hairline = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.08)
    })
    /// 라이트의 카드 그림자 (흰 카드가 밝은 바탕에서 뜨게). 다크는 없음
    static let cardShadow = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .clear : NSColor(white: 0, alpha: 0.05)
    })
    /// 막대·게이지의 빈 자리
    static let track = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0, alpha: 0.08)
    })
    /// 라이트의 회색 태그 배지: 옅은 면에 진회색 글자 (secondary 25% 면에 검은 글자는 밝은 사이드바에서 덩어리로 보였다). 다크는 그대로
    static let plainBadgeLight = Color(nsColor: dynamic(dark: 0x3A3A3A, light: 0xDDDDDC))
    static let plainBadgeTextLight = Color(nsColor: dynamic(dark: 0xE6E6E6, light: 0x4A4A49))

    /// 라이트 · 다크에 따라 고르고, 화면 모드의 기운을 더한 면 색
    static func dynamic(dark: UInt32, light: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = ScreenMode.shifted(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light, by: shift)
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }
}

/// 모서리·여백 치수. 화면마다 숫자를 다시 적지 않는다.
enum Metrics {
    // 모서리는 다섯 단계: 카드 14 > 카드 안의 면(목록·입력 폼·드롭 영역) 10 > 조작부(버튼·입력칸·탭·마디) 8 > 작은 조작부(작은 버튼·고른 칸) 6 > 배지 4.
    // 안쪽 면을 감싸는 바깥 면은 안쪽 반경 + 여백(탭 전환 6 + 3 = 9). 막대·범례 같은 그림 조각(1.5~3)은 여기 들지 않는다.
    static let cardRadius: CGFloat = 14
    static let panelRadius: CGFloat = 10
    static let controlRadius: CGFloat = 8
    static let smallRadius: CGFloat = 6
    static let chipRadius: CGFloat = 4
    static let cardPadding: CGFloat = 16
    /// 카드 사이 (모든 화면이 이 값을 쓴다). 카드 안 여백(16)보다 한 단계 좁게 — 같으면 카드 안팎의 거리가 같아 상자가 따로 놀았다.
    /// 카드에 선이 있어 12 로도 충분히 갈린다 (10 은 선끼리 붙어 보인다) — 2026-11-10
    static let gap: CGFloat = 12
    /// 라벨–값 격자의 열 간격
    static let labelGap: CGFloat = 14
    /// 사이드바 행 머리(아이콘·상태 점)의 자리 폭 — 모든 행이 같아야 이름 기둥이 한 줄로 맞는다
    static let sidebarIcon: CGFloat = 20
}

extension Font {
    /// 화면 큰 제목 (서버 이름 · 화면 이름)
    static let screenTitle = Font.system(size: 28, weight: .bold)
    /// 격자의 라벨 (값보다 한 단계 작게 — 값이 먼저 읽힌다)
    static let fieldLabel = Font.system(size: 12)
    /// 카드 제목 · 구역 머리 — 작고 또렷한 회색
    static let cardTitle = Font.system(size: 11.5, weight: .semibold)
    /// 주소·포트·MAC 같은 기술 값
    static let dataValue = Font.system(size: 12.5, design: .monospaced)
    /// 타일의 큰 값. 짧은 수치는 크게, 이름·시간처럼 긴 글은 단계적으로 줄인다 — 긴 글이 26pt 면 타일에서 혼자 떠 보였다 (2026-11-10 사용자 지적)
    static func metricValue(_ text: String) -> Font {
        let size: CGFloat = text.count <= 8 ? 26 : (text.count <= 12 ? 21 : 17)
        return .system(size: size, weight: .semibold)
    }
}

extension View {
    /// 입력칸 면: 채움 + 또렷한 선
    func fieldSurface(radius: CGFloat = Metrics.controlRadius) -> some View {
        background(Palette.field, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.fieldBorder))
    }

    /// 카드 면: 채움 + 머리카락 선
    func cardSurface(radius: CGFloat = Metrics.cardRadius) -> some View {
        // 그림자는 면에만 (내용 글자에 번지지 않게). 다크에선 투명 — 깊이는 면 단계와 선이 만든다
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Palette.card)
                .shadow(color: Palette.cardShadow, radius: 6, y: 2)
        }
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.hairline))
    }
}

/// 상태 점: 또렷한 색 점 하나. 둘레에 번지는 고리는 두지 않는다 — 작은 점이 뿌옇게 보였다 (2026-11-10 사용자 지적).
/// 자리는 예전 크기(14)를 지켜 행 글자 위치가 흔들리지 않게 한다.
struct StatusDot: View {
    let tone: StatusTone
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(tone == .muted ? Color.secondary.opacity(0.45) : tone.color)
            .frame(width: size, height: size)
            .frame(width: size + 6, height: size + 6)
    }
}

private struct SidebarRowSelectedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// 사이드바에서 고른 행 안인가 (sidebarSelection 이 넣는다) — StatusIcon 이 점 둘레를 행 바탕색으로 따낼 때 쓴다
    var sidebarRowSelected: Bool {
        get { self[SidebarRowSelectedKey.self] }
        set { self[SidebarRowSelectedKey.self] = newValue }
    }
}

/// 사이드바 행 머리: 무채색 아이콘 + 오른쪽 아래 모서리의 상태 점 (2026-11-15 시안 C). 색은 점만 갖는다.
/// 점 둘레는 행 바탕색으로 따내 아이콘 획과 떨어뜨린다. tone 이 nil 이면 아이콘만 (this Mac).
struct StatusIcon: View {
    @Environment(\.sidebarRowSelected) private var selected
    let symbol: String
    var tone: StatusTone?
    /// 모서리 점 지름
    private static let dot: CGFloat = 7
    /// SF Symbols 에 없는 블루투스 표지 — 이 이름이면 직접 그린다 (BluetoothGlyph)
    static let bluetooth = "nexus.bluetooth"

    @ViewBuilder private var glyph: some View {
        if symbol == Self.bluetooth {
            BluetoothGlyph().stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)).frame(width: 8, height: 16)
        } else {
            Image(systemName: symbol).font(.system(size: 13.5))
        }
    }

    var body: some View {
        // 기호마다 높이가 달라 자리를 고정한다 — 점이 행마다 같은 높이에 온다
        // 부제목 회색(.secondary)이면 어두운 사이드바에 묻힌다 — 제목과 부제목 사이 밝기
        glyph.foregroundStyle(.primary.opacity(0.8))
            .frame(width: Metrics.sidebarIcon, height: 16)
            .overlay(alignment: .bottomTrailing) {
                if let tone {
                    Circle().fill(tone == .muted ? Color.secondary.opacity(0.45) : tone.color)
                        .frame(width: Self.dot, height: Self.dot)
                        .padding(1.5)
                        .background(selected ? Palette.raisedSidebar : Palette.sidebar, in: Circle())
                        .offset(x: 2, y: 2)
                }
            }
    }
}

/// 블루투스 표지: 세로 기둥 + 위·아래에서 오른쪽으로 꺾여 가운데서 엇갈리는 두 획 (폭 = 높이의 절반이면 45°)
struct BluetoothGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y) }
        var path = Path()
        path.move(to: point(0, 0.25))
        path.addLine(to: point(1, 0.75))
        path.addLine(to: point(0.5, 1))
        path.addLine(to: point(0.5, 0))
        path.addLine(to: point(1, 0.25))
        path.addLine(to: point(0, 0.75))
        return path
    }
}

/// 상태 결론 알약: 점 + 글자를 옅은 색 면에 ("접속 가능" · "꺼짐")
struct StatusPill: View {
    let text: String
    let tone: StatusTone

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tone == .muted ? Color.secondary.opacity(0.6) : tone.color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(tone == .muted ? Color.secondary : tone.color)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background((tone == .muted ? Color.secondary : tone.color).opacity(tone == .muted ? 0.12 : 0.14), in: Capsule())
        .fixedSize()
    }
}

// MARK: 대표 카드

private struct HeroStripKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// 대표 카드의 아래 띠 안인가 — 타일(MetricTile)이 제 카드 면 없이 칸으로 그려진다
    var inHeroStrip: Bool {
        get { self[HeroStripKey.self] }
        set { self[HeroStripKey.self] = newValue }
    }
}

/// 화면 맨 위 대표 카드: 위는 누구인지·지금 어떤지(제목·결론), 아래 띠는 가장 먼저 볼 것(핵심 수치 칸 또는 주 버튼).
/// 모든 상세 화면이 이 한 덩어리로 시작한다 — 서버는 접속 버튼, 망·이 Mac 화면은 수치 칸.
struct HeroCard<Header: View, Strip: View>: View {
    /// 아래 띠가 있는가 (없으면 제목 부분만 — 보여 줄 수치가 아직 없을 때)
    var hasStrip = true
    @ViewBuilder var header: Header
    @ViewBuilder var strip: Strip

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hasStrip {
                Rectangle().fill(Palette.hairline).frame(height: 1)
                strip
                    .environment(\.inHeroStrip, true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.well.opacity(0.6))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .cardSurface()
    }
}
