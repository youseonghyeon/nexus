// 터미널 안 찾기 칸 (⌘F): 터미널 오른쪽 위에 얹는다. 글자를 치면 바로 찾고(일치하는 곳은 터미널이 강조), Return 다음 · ⇧Return 이전 · esc 닫기.
// ⌘G · ⌘⇧G 는 키 감시(TerminalShortcuts)가 받는다 — 칸에 포커스가 있어도 된다. 판정·동작 이름은 ServersCore TerminalFind.
// 일치한 수는 보이지 않는다 (터미널 래퍼가 앱에 넘기지 않는다 — TerminalFind 머리 주석).

import ServersCore
import SwiftUI

struct TerminalFindBar: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var tab: TerminalTab
    @FocusState private var focused: Bool

    var body: some View {
        TerminalFindBarContent(text: Binding(get: { tab.findText }, set: { model.updateFind(tab, text: $0) }), focused: $focused,
                               previous: { model.stepFind(tab, forward: false) }, next: { model.stepFind(tab, forward: true) },
                               close: { model.closeFind(tab) })
            // 뜨는 그 차례에는 칸이 아직 창에 붙지 않아 포커스가 터미널에 남는다 (처음 ⌘F 에 포커스가 안 가고 한 번 더 눌러야 갔다) — 다음 차례에 옮긴다
            .onAppear { DispatchQueue.main.async { focused = true } }
            .onChange(of: tab.findFocusRequest) { _, _ in focused = true }   // 열려 있을 때 ⌘F 를 다시 누르면 칸으로
    }
}

/// 찾기 칸의 모양 (값만 받는다 — 스크래치에서 비트맵으로 확인)
struct TerminalFindBarContent: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let previous: () -> Void
    let next: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("찾기", text: $text)
                .textFieldStyle(.plain)
                .focused(focused)
                .frame(width: 180)
                // Return 다음 · ⇧Return 이전 (입력기가 글자를 조합 중일 때의 Return 은 입력기가 먼저 받는다)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { previous() } else { next() }
                    return .handled
                }
                .onExitCommand(perform: close)
            Rectangle().fill(Palette.hairline).frame(width: 1, height: 14)
            Button(action: previous) { Image(systemName: "chevron.up") }.accessibilityLabel("이전").help("이전 (⇧Return · ⌘⇧G)")
                .disabled(text.isEmpty)
            Button(action: next) { Image(systemName: "chevron.down") }.accessibilityLabel("다음").help("다음 (Return · ⌘G)")
                .disabled(text.isEmpty)
            Button(action: close) { Image(systemName: "xmark") }.accessibilityLabel("찾기 닫기").help("닫기 (esc)")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 7)
        .modifier(FloatingSurface())
        .tint(Palette.neutralTint)
    }
}
