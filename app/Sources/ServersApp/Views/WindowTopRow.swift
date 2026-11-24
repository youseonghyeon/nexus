// 창 윗줄 부품. 윗줄 자체는 툴바다 (2026-10-12) — 사이드바 칸: 토글 · 지금 확인, 본문 칸: 탭 막대 (SidebarView·DetailView 의 .toolbar).
// 툴바여야 전체 화면에서 내려오는 신호등 줄이 클릭을 받는다 (그 줄은 툴바 영역만 클릭 영역으로 잡는다).

import AppKit
import SwiftUI

enum WindowTopRow {
    /// 탭 위에선 창 끌기를 끈다 — 제목줄 자리라 AppKit 이 탭 드래그(순서 바꾸기)와 함께 창까지 끌었다 (누르는 순간의 값을 본다)
    @MainActor static func setMovable(_ movable: Bool) {
        for window in NSApp.windows where window.delegate is AppDelegate { window.isMovable = movable }
    }
}

/// 윗줄의 빈 곳: 끌면 창이 움직이고 두 번 클릭하면 제목줄처럼(시스템 설정의 확대·최소화·안 함). 탭·버튼 뒤에 깐다.
struct WindowDragArea: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .simultaneousGesture(TapGesture(count: 2).onEnded { Self.doubleClick() })
            .allowsWindowActivationEvents(true)
    }

    private static func doubleClick() {
        guard let window = NSApp.keyWindow else { return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }
}

/// 지금 확인 (⌘R). 사이드바 줄 오른쪽 끝, 사이드바를 접으면 본문 줄 토글 옆.
struct RefreshButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.requestRefresh() } label: { Label("지금 확인", systemImage: "arrow.clockwise") }
            .buttonStyle(TopRowIconStyle())
            .allowsWindowActivationEvents(true)   // 창이 비활성이어도 첫 클릭에 눌린다 (툴바 버튼과 같게)
            .help("지금 상태 확인 (⌘R)")
    }
}

/// 윗줄 아이콘 버튼: 유리·테두리 없이 납작하게, 올리면 옅은 면
struct TopRowIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButton(configuration: configuration)
    }

    private struct IconButton: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .labelStyle(.iconOnly)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 24)
                .background(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: Metrics.smallRadius))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
