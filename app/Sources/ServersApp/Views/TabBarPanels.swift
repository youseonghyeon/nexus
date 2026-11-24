// 탭 막대 오른쪽 버튼(메모·로그인 · 명령 모음)의 패널. 시스템 팝오버 대신 앱이 본문 위에 그린다 (2026-11-18 시안 A):
// 시스템 팝오버는 화면 위치에 따라 좌우로 밀리고, 기준점을 옮기면 화살표가 버튼이 아닌 곳을 가리켰다.
// 자리는 늘 본문 오른쪽 위 — 오른쪽 끝을 창 여백에 맞추고 왼쪽으로 펼친다. 화살표는 없고, 열린 버튼에 면이 남는다 (TabBarIconButtonStyle).
// 닫기: 패널 밖(본문)을 누르기 · esc · 버튼 다시 누르기(⌘P). 둘 중 하나만 열린다 (AppModel.toggleSnippets·toggleNotes).
// 본창 안에 그리므로 창이 따로 뜨지 않는다 — 닫으면 보고 있던 터미널에 포커스를 돌려준다.

import ServersCore
import SwiftUI

struct TabBarPanels: View {
    @Environment(AppModel.self) private var model
    /// 편집 중인 초안. 패널 밖에 두어 바깥을 눌러 닫혀도 다시 열면 이어서 쓴다.
    @State private var snippetDraft: CommandSnippet?
    @State private var noteDraft: SecretNote?

    /// 명령 모음의 종류: 서버 종류 · 이 Mac 로컬 셸 (버튼이 있는 곳과 같다 — TabBar)
    private var snippetKind: SnippetKind? {
        if let server = model.selectedServer { return SnippetKind(server.type) }
        return model.selectedKey == AppModel.localKey ? .mac : nil
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if model.tabPanelOpen {
                // 패널 밖을 누르면 닫는다 (그 클릭은 아래 터미널·웹 화면으로 넘기지 않는다)
                Color.clear.contentShape(Rectangle()).onTapGesture { close() }
                Group {
                    if model.snippetsShown, let kind = snippetKind {
                        SnippetsPopover(type: kind, editing: $snippetDraft) { model.closeSnippets() }
                    } else if model.notesShown, let server = model.selectedServer {
                        NotesPopover(serverKey: server.key, editing: $noteDraft) { model.closeNotes() }
                    }
                }
                .modifier(FloatingSurface(radius: Metrics.cardRadius))
                .padding(.trailing, 8).padding(.top, 2)
                .onExitCommand { close() }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topTrailing)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .animation(.easeOut(duration: 0.12), value: model.tabPanelOpen)
        // 다른 종류 서버·다른 서버로 옮겼으면 옛 초안은 버린다 (그 서버에 저장되지 않게)
        .onChange(of: snippetKind) { _, kind in if snippetDraft.map({ $0.type != kind }) ?? false { snippetDraft = nil } }
        .onChange(of: model.selectedKey) { _, _ in noteDraft = nil; close() }
        .onChange(of: model.tabPanelOpen) { _, open in if !open { model.visibleTerminal?.requestFocus() } }
    }

    private func close() {
        model.closeSnippets()
        model.closeNotes()
    }
}

// MARK: 두 패널(명령 모음 · 메모)이 같이 쓰는 부품

extension View {
    /// 패널의 한 줄 입력칸: 테두리 없는 칸 + 여백 8 · 5 + 입력칸 면
    func panelField() -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .fieldSurface()
    }

    /// 패널 목록의 한 줄 면: 여백 8 · 6, 마우스를 올렸거나 ↑↓ 로 고른 줄은 옅은 면, 줄 전체가 마우스를 받는다
    func panelRowSurface(highlighted: Bool) -> some View {
        padding(.horizontal, 8).padding(.vertical, 6)
            .background(highlighted ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: Metrics.smallRadius))
            .contentShape(Rectangle())
    }
}

/// 편집 화면 아래 줄: 삭제(편집일 때만 — delete 가 nil 이면 없다) | 취소 · 저장(⌘Return)
struct PanelEditorFooter: View {
    let delete: (() -> Void)?
    let cancel: () -> Void
    let save: () -> Void
    let saveDisabled: Bool

    var body: some View {
        HStack {
            if let delete {
                Button("삭제", action: delete)
                    .buttonStyle(SecondaryButtonStyle())
            }
            Spacer()
            Button("취소", action: cancel)
                .buttonStyle(SecondaryButtonStyle())
            Button("저장", action: save)
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(saveDisabled)
                .help("저장 (⌘Return)")
        }
    }
}
