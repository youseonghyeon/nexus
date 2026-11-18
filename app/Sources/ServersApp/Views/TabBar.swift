// 탭 막대(Dashboard 고정 탭 + 터미널 탭·이름 바꾸기·닫기)와 터미널 표면.
// 모든 터미널 뷰는 항상 마운트해 둔다. libghostty 의 surface(PTY 자식 포함)는 NSView 가 소유하므로
// 뷰를 내리면 ssh 세션이 죽는다. 보이지 않는 탭은 opacity 0 + isSurfaceVisible=false 로만 감춘다.

import GhosttyTerminal
import ServersCore
import SwiftUI

struct TabBar: View {
    @Environment(AppModel.self) private var model
    let tabs: [TerminalTab]
    /// 보이는 탭 (nil 이면 Dashboard). DetailView 가 한 번 계산해 넘긴다 — 버튼마다 visibleTab 을 다시 구하지 않게.
    let activeID: UUID?
    /// 끌고 있는 탭 (순서 변경). 막대 안에서 커서를 따라 좌우로만 움직이고, 이웃 중심을 넘으면 이웃이 비켜난다.
    @State private var drag: (id: UUID, state: ServersCore.TabDrag)?
    /// 탭마다 막대 안 자리 (offset 바깥에서 잰 레이아웃 자리). 끌기 중엔 폭만 쓴다 — 자리 계산은 TabDrag.
    @State private var frames: [UUID: CGRect] = [:]
    /// 탭 막대 크기 (끌기를 놓은 자리가 막대 안인지 — endDrag)
    @State private var stripSize: CGSize = .zero
    /// 스크롤 칸 폭 — 탭이 적을 때 남는 자리까지 창 끌기 영역으로 채운다
    @State private var viewport: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    // 맨 왼쪽 고정: 정보 화면으로 돌아가는 탭 (닫기 없음, 드래그 대상 아님)
                    DashboardTabButton(isActive: activeID == nil)
                    ForEach(tabs) { tab in
                        let dragged = drag?.id == tab.id
                        TabButton(tab: tab, isActive: tab.id == activeID,
                                  onDrag: { dragChanged(tab.id, by: $0) }, onDragEnd: { endDrag(at: $0) })
                            .offset(x: dragged ? dragOffset(tab.id) : 0)
                            // offset 바깥에서 잰다 — 안쪽에서 재면 offset 이 섞여 되먹임(떨림)이 생긴다
                            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.space)) }) { frames[tab.id] = $0 }
                            .zIndex(dragged ? 1 : 0)
                            // 끌리는 탭은 자리가 바뀌어도 애니메이션 없이 커서에 붙어 있고, 이웃만 미끄러진다
                            .transaction { if dragged { $0.animation = nil } }
                            .onDisappear { frames[tab.id] = nil }   // 닫힌 탭 자리는 버린다
                    }
                    newTabButton
                }
                .coordinateSpace(.named(Self.space))
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { stripSize = $0 }
                // 끄는 중 탭이 닫히거나 다른 서버로 바뀌면(onEnded 가 안 온다) 끌기를 버린다 — 돌아왔을 때 탭이 떠 있지 않게
                .onChange(of: tabs.map(\.id)) { _, ids in if let id = drag?.id, !ids.contains(id) { drag = nil } }
                .onHover { WindowTopRow.setMovable(!$0) }   // 탭 위에서만 — 빈 곳은 그대로 창 끌기
                .onDisappear { WindowTopRow.setMovable(true) }
                .padding(.horizontal, 6)
                .frame(minWidth: viewport, maxHeight: .infinity, alignment: .leading)
                .background(WindowDragArea())   // 창 윗줄이라 탭 뒤 빈 곳은 끌면 창 이동
            }
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.containerSize.width }) { _, width in viewport = width }
            // 오른쪽 끝 고정 (탭이 많아도 스크롤에 밀리지 않게): 그 서버의 메모·로그인 · 서버 종류별 · 이 Mac 로컬 셸 명령 모음
            if let server = model.selectedServer {
                NotesButton(serverKey: server.key)
                SnippetsButton()
            } else if model.selectedKey == AppModel.localKey {
                SnippetsButton()
            }
        }
    }

    nonisolated static let space = "tabbar"

    private var widths: [Double] { tabs.map { Double(frames[$0.id]?.width ?? 0) } }

    private func dragOffset(_ id: UUID) -> CGFloat {
        guard let drag, let index = tabs.firstIndex(where: { $0.id == id }) else { return 0 }
        return CGFloat(drag.state.offset(widths: widths, index: index))
    }

    /// location: 놓은 자리 (막대 좌표). 막대 안이면 창 끌기를 끈 채, 밖이면 켠다 — 호버 이벤트에 기대지 않는다.
    private func endDrag(at location: CGPoint) {
        withAnimation(.snappy(duration: 0.18)) { drag = nil }
        let inside = ServersCore.TabDrag.releasedInside(x: Double(location.x), y: Double(location.y),
                                                        width: Double(stripSize.width), height: Double(stripSize.height))
        WindowTopRow.setMovable(!inside)
    }

    private func dragChanged(_ id: UUID, by translation: CGFloat) {
        if drag?.id != id {
            guard let frame = frames[id], let base = tabs.compactMap({ frames[$0.id]?.minX }).min() else { return }
            drag = (id, ServersCore.TabDrag(base: Double(base), startMinX: Double(frame.minX), spacing: 2))   // 2 = 탭 HStack 간격
            model.showTab(id)   // 끄는 탭을 보이게 (브라우저 탭과 같게)
        }
        drag?.state.translation = Double(translation)
        guard let drag, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let target = drag.state.target(widths: widths, index: index)
        if target != index {
            withAnimation(.snappy(duration: 0.18)) { model.moveTab(id, to: target) }
        }
    }

    /// [+]: 서버면 SSH / Browser 중 고른다 (⌘T 는 SSH). 로컬이면 로컬 셸.
    @ViewBuilder
    private var newTabButton: some View {
        if model.selectedKey == AppModel.localKey {
            Button { model.openLocalShell() } label: { Image(systemName: "plus") }.accessibilityLabel("새 로컬 셸 탭")
                .buttonStyle(.borderless)
                .padding(.horizontal, 8)
                .help("새 로컬 셸 탭")
        } else if let server = model.selectedServer {
            Menu {
                // ⌘T 는 메뉴바 File > New SSH Tab 이 이미 갖고 있다 (여기 또 걸면 두 번 열린다)
                Button { model.openSSH(server) } label: { Label("SSH", systemImage: "terminal") }
                Button { model.openBrowser(server) } label: { Label("Browser", systemImage: "globe") }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 8)
            .disabled(!model.isReachable(server))
            .help("새 탭 — SSH 또는 Browser")
            .accessibilityLabel("새 탭")
        }
    }
}

struct DashboardTabButton: View {
    @Environment(AppModel.self) private var model
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.grid.2x2").font(.caption)
            Text("Dashboard").lineLimit(1).font(.callout)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(isActive ? Palette.raised : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(isActive ? Palette.hairline : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { model.showDashboard() }
    }
}

/// 탭 버튼(터미널·브라우저). 두 번 클릭(또는 우클릭 → 이름 변경)으로 이름을 바꾼다. 비우고 확정하면 자동 제목으로 돌아간다.
/// 브라우저 탭의 머리: 보고 있는 페이지의 아이콘(원래 색 그대로), 없으면 지구본. 자리는 같은 크기 — 아이콘이 오고 갈 때 탭 폭이 변하지 않게.
private struct BrowserTabIcon: View {
    @ObservedObject var browser: BrowserSession

    var body: some View {
        Group {
            if let icon = browser.icon {
                Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                Image(systemName: "globe").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 14, height: 14)
    }
}

struct TabButton: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var tab: TerminalTab
    let isActive: Bool
    /// 막대 안 끌기 (TabBar 가 순서·위치를 계산한다). 이름 바꾸는 중엔 끈다 — 글자 끌어 고르기가 탭을 옮기지 않게.
    var onDrag: (CGFloat) -> Void = { _ in }
    var onDragEnd: (CGPoint) -> Void = { _ in }
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var editorFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let browser = tab.browser {
                BrowserTabIcon(browser: browser)
            } else {
                Circle()
                    .fill(tab.isAlive ? StatusTone.good.color : Color.secondary)
                    .frame(width: 6, height: 6)
            }
            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .frame(minWidth: 60, maxWidth: 160)
                    .focused($editorFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { editing = false }
                    .onChange(of: editorFocused) { _, focused in if !focused, editing { commitRename() } }
            } else {
                TabTitle(tab: tab)
            }
            Button {
                model.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.borderless)
            .help("탭 닫기 (⌘W)")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(isActive ? Palette.raised : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(isActive ? Palette.hairline : Color.clear))
        .contentShape(Rectangle())
        // 두 번 클릭 인식은 동시 제스처로: 순차(onTapGesture count:2 → 1)로 두면 한 번 클릭이 두 번째 클릭을 기다리느라 전환이 늦어진다.
        .onTapGesture { model.showTab(tab.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { startRename() })
        .contextMenu {
            Button("이름 변경…") { startRename() }
            if tab.customTitle != nil { Button("자동 이름으로") { tab.customTitle = nil } }
            Divider()
            Button("탭 닫기") { model.closeTab(tab.id) }
        }
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(TabBar.space))
            .onChanged { onDrag($0.translation.width) }
            .onEnded { onDragEnd($0.location) }, isEnabled: !editing)
    }

    private func startRename() {
        guard !editing else { return }   // 편집 중 칸 안을 두 번 클릭(낱말 고르기)해도 쓰던 이름을 덮지 않게
        draft = TabTitle.text(for: tab)
        editing = true
        model.showTab(tab.id)
        DispatchQueue.main.async { editorFocused = true }
    }

    private func commitRename() {
        let name = draft.trimmingCharacters(in: .whitespaces)
        tab.customTitle = name.isEmpty ? nil : name
        editing = false
    }
}

/// 탭 제목: 사용자가 붙인 이름 → 페이지/셸이 보내는 제목 → 기본 제목. 어느 객체가 제목을 내는지에 따라 관찰 대상이 다르다.
struct TabTitle: View {
    @ObservedObject var tab: TerminalTab

    var body: some View {
        switch tab.content {
        case let .terminal(terminal): TerminalTitle(tab: tab, terminal: terminal)
        case let .browser(browser): BrowserTitle(tab: tab, browser: browser)
        }
    }

    static func text(for tab: TerminalTab) -> String {
        if let custom = tab.customTitle { return custom }
        switch tab.content {
        case let .terminal(t): return t.title.isEmpty ? tab.title : t.title
        case let .browser(b): return b.title.isEmpty ? tab.title : b.title
        }
    }

    private struct TerminalTitle: View {
        @ObservedObject var tab: TerminalTab
        @ObservedObject var terminal: TerminalViewState
        var body: some View { Text(TabTitle.text(for: tab)).lineLimit(1).font(.callout) }   // terminal 은 제목이 바뀔 때 다시 그리려고 관찰한다
    }

    private struct BrowserTitle: View {
        @ObservedObject var tab: TerminalTab
        @ObservedObject var browser: BrowserSession
        var body: some View { Text(TabTitle.text(for: tab)).lineLimit(1).font(.callout) }   // browser 도 같다
    }
}

/// 탭 내용. 터미널은 항상 마운트(표면이 PTY 를 소유), 브라우저는 세션이 WKWebView 를 소유하므로 보이는 것만 붙여도 된다.
struct TabPane: View {
    @ObservedObject var tab: TerminalTab
    let isVisible: Bool

    var body: some View {
        switch tab.content {
        case let .terminal(terminal): TerminalPane(terminal: terminal, isVisible: isVisible)
        case let .browser(browser): if isVisible { BrowserPane(browser: browser) }
        }
    }
}

struct TerminalPane: View {
    let terminal: TerminalViewState
    let isVisible: Bool

    var body: some View {
        TerminalSurfaceView(context: terminal)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
            .onAppear { sync() }
            .onChange(of: isVisible) { _, _ in sync() }
    }

    private func sync() {
        terminal.isSurfaceVisible = isVisible
        (terminal.attachedPlatformView as? TerminalDropView)?.acceptsDrops = isVisible
        if isVisible {
            terminal.requestFocus()
        } else if let view = terminal.attachedPlatformView, view.window?.firstResponder === view {
            // 가려진 터미널이 키를 계속 받으면 안 보이는 셸에 입력이 들어간다 (⌘⇧[ ] 로 Dashboard·브라우저 탭으로 옮길 때)
            view.window?.makeFirstResponder(nil)
        }
    }
}
