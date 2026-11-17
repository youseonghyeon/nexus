// Nexus.app 진입점. 사이드바(그룹별 서버 + 상태) · 오른쪽 정보·터미널 탭 · 메뉴바 명령(Server·Network).

import GhosttyTerminal
import ServersCore
import SwiftUI

@main
struct ServersApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @AppStorage(AppearanceMode.defaultsKey) private var appearance = AppearanceMode.system

    init() {
        // GUI 로 뜨면 LANG 이 없어 자식(ssh·scp·sftp·터미널)이 C 로케일로 돈다 — 한글이 8진수로 깨진다. 무엇보다 먼저 채운다.
        ProcessLocale.install()
        // 앱 강조색을 Graphite 로 바꾸지 않는다 — 창의 신호등 버튼까지 회색이 된다 (2026-11-10 사용자 지적, 한 번 넣었다 뺌).
        // 그때 앱 설정 영역에 적어 둔 값을 지운다. 토글·고르개의 색은 화면 뿌리의 tint 로 무채색을 준다 (포커스 고리는 시스템 색 그대로).
        UserDefaults.standard.removeObject(forKey: "AppleAccentColor")
        UserDefaults.standard.removeObject(forKey: "AppleHighlightColor")
    }

    var body: some Scene {
        WindowGroup("Nexus") {
            ContentView()
                .environment(model)
                .background(WindowHook(delegate: appDelegate))
                .background(SettingsOpenerHook(delegate: appDelegate))
                .frame(minWidth: 900, minHeight: 520)
                .tint(Palette.neutralTint)
                .onAppear {
                    model.startMonitoring()
                    model.openLaunchCommandIfAny()
                    TerminalShortcuts.install(stepTab: { model.stepTab(forward: $0) }, toggleSnippets: { model.toggleSnippets() }, snippetsOpen: { model.snippetsShown },
                                              hasVisibleTab: { model.visibleTab != nil }, closeTab: { _ = model.closeVisibleTab() },
                                              pasteFiles: { model.pasteIntoTerminal($0) },
                                              selectNumber: { number in
                                                  guard let key = QuickSelect.key(for: number, in: QuickSelectState.shared.keys) else { return false }
                                                  model.selectedKey = key
                                                  return true
                                              })
                    // 메뉴바: 창을 닫아 둔 채로 망·서버·터널 상태를 보고 망 스위치·터널을 조작한다 (MenuBarController — 아이콘 아래 패널)
                    appDelegate.installMenuBar(model: model)
                    appDelegate.installNotificationHandler(model: model)
                    model.startUpdater()
                }
                // 앱을 끄면 터널 프로세스도 함께 끊는다 (GUI 앱의 자식은 저절로 죽지 않는다)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.stopAllTunnels()
                }
        }
        // 윗줄은 툴바 (2026-10-12): 전체 화면에서 내려오는 신호등 줄은 툴바 영역만 클릭을 받는다 — 툴바가 없으면 클릭이 본창으로 빠졌다.
        // 창 모드는 띠 없이(toolbarBackgroundVisibility hidden), 전체 화면은 macOS 가 그리는 회색 띠를 받아들인다.
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                // this Mac 을 골랐으면 ⌘T 도 로컬 셸 (서버가 아니라 꺼져 있었다)
                let localSelected = model.selectedKey == AppModel.localKey
                Button(localSelected ? "새 로컬 셸" : "새 SSH 탭") {
                    if localSelected { model.openLocalShell() } else if let server = model.selectedServer { model.openSSH(server) }
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!localSelected && (model.selectedServer.map { !model.isReachable($0) } ?? true))
                Button("새 로컬 셸") { model.openLocalShell() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                // ⌘W 키는 TerminalShortcuts 가 모든 창에서 먼저 받아 CloseCommand 로 처리한다 — 여기엔 메뉴 클릭만 온다
                Button("탭 닫기") {
                    if let id = model.visibleTab?.id { model.closeTab(id) }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(model.visibleTab == nil)
            }
            // Nexus ▸ 업데이트 확인… (설정… 위)
            CommandGroup(after: .appInfo) {
                Button("업데이트 확인…") { model.checkForUpdates() }
            }
            // .commands 는 WindowGroup 콘텐츠 밖이라 environment 가 전달되지 않는다. 명시적으로 넘긴다.
            // 메뉴 이름은 옆의 시스템 메뉴(파일·편집·보기…)처럼 한국어. 항목 안의 기능 이름(SSH·Tunnel·Intranet…)은 화면의 버튼·행과 같은 글자 그대로
            CommandMenu("서버") {
                ServerActionsMenu().environment(model)
            }
            CommandMenu("네트워크") {
                NetworkMenu().environment(model)
            }
            // 도움말: 도움말 책이 없어 기본 항목은 "사용할 수 없습니다"만 띄운다 — 저장소 문서로 보낸다
            CommandGroup(replacing: .help) {
                Link("Nexus 사용 안내", destination: AppLinks.readme)
                Link("변경 기록", destination: AppLinks.changelog)
                Divider()
                Link("문제 신고…", destination: AppLinks.issues)
            }
            CommandGroup(after: .windowArrangement) {
                OpenCaptureButton(model: model)
            }
            CommandGroup(after: .toolbar) {
                Button("지금 확인") { model.requestRefresh() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("servers.conf 다시 읽기") { model.loadConfig() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                // 키는 TerminalShortcuts 가 창에 가기 전에 먼저 받는다 (터미널에 포커스가 있어도) — 여기엔 메뉴 클릭만 오고, 단축키를 찾아볼 수 있게 적어 둔다
                Button("명령 모음") { model.toggleSnippets() }
                    .keyboardShortcut("p", modifiers: .command)
                Button("이전 탭") { model.stepTab(forward: false) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Button("다음 탭") { model.stepTab(forward: true) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Divider()
                // 창을 닫아 둔 채(메뉴바만)여도 바로 걸리게 고를 때 적용한다
                Picker("화면 모드", selection: Binding(get: { appearance }, set: { appearance = $0; $0.apply() })) {
                    ForEach(AppearanceMode.allCases, id: \.self) { Text($0.title) }
                }
            }
        }
        // 패킷 캡처 창 (윈도우 ▸ Packet Capture ⌥⌘P · 망 화면 진단 카드 [Capture…]) — 하나만, 열면 시작 닫으면 끝
        Window("Packet Capture", id: PacketCaptureView.windowID) {
            PacketCaptureView(capture: model.capture).environment(model)
        }
        .defaultSize(width: 1100, height: 760)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))   // 본창처럼 윗줄이 툴바 (장치·필터·버튼)
        .commandsRemoved()   // 윈도우 메뉴에 저절로 생기는 항목 — 장치 준비를 하는 OpenCaptureButton(⌥⌘P) 하나만 둔다
        // 설정 창 (⌘, · 앱 메뉴 ▸ 설정…)
        Settings {
            SettingsView().environment(model).tint(Palette.neutralTint)
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    /// 사이드바 보이기 — 시스템 토글(둥근 유리 버튼) 대신 납작한 토글이 쓴다
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model   // 시트·확인 창 바인딩($model.x)용
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(columns: $columns)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            DetailView(columns: $columns)
        }
        .toolbar(removing: .sidebarToggle)   // 시스템 토글(둥근 유리) 대신 납작한 토글을 툴바에 직접 둔다
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)   // 창 모드 윗줄 띠 없이 — 사이드바·본문 색이 그대로 올라간다
        // 탭 위에서 ⌘Tab 등으로 떠나면 호버 나감이 안 올 수 있다 — 창 끌기를 되살린다 (WindowTopRow.setMovable)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in WindowTopRow.setMovable(true) }
        .overlay(alignment: .bottomTrailing) {
            if let message = model.statusMessage {
                StatusToast(message: message, count: model.statusRepeat) { model.statusMessage = nil }
                    .padding(16)
                    // 같은 글이 또 오면(×N) 5초를 다시 센다. 새 글·횟수로 바뀌어 취소된 대기는 지우지 않는다.
                    .task(id: "\(message)#\(model.statusRepeat)") {
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                        if model.statusMessage == message { model.statusMessage = nil }
                    }
            }
        }
        // 조회 결과(로그·명령 오류)는 시트가 아니라 독립 창으로 — 크기·위치를 자유롭게 (QueryResultWindow)
        .onChange(of: model.queryResult?.id) { QueryResultWindow.shared.sync(model) }
        .sheet(item: $model.tunnelInfo) { session in
            TunnelInfoSheet(session: session).environment(model)
        }
        .sheet(item: $model.transferInfo) { session in
            TransferInfoSheet(session: session).environment(model)
        }
        .sheet(item: $model.tunnelPrompt) { request in
            TunnelPromptSheet(request: request).environment(model)
        }
        .sheet(item: $model.uploadPrompt) { request in
            UploadPromptSheet(request: request).environment(model)
        }
        .sheet(item: $model.downloadPrompt) { request in
            DownloadPromptSheet(request: request).environment(model)
        }
        .sheet(item: $model.addServerPrompt) { request in
            ServerFormSheet(mode: .add(request)).environment(model)
        }
        .sheet(item: $model.serverEditor) { server in
            ServerFormSheet(mode: .edit(server)).environment(model)
        }
        .sheet(item: $model.actionsEditor) { server in
            ActionsEditSheet(server: server).environment(model)
        }
        .sheet(isPresented: $model.serviceAddPrompt) {
            ServiceAddSheet().environment(model)
        }
        .confirmationDialog(model.pendingConfirm?.title ?? "", isPresented: Binding(
            get: { model.pendingConfirm != nil },
            set: { if !$0 { model.pendingConfirm = nil } }
        ), titleVisibility: .visible) {
            Button(model.pendingConfirm?.title ?? "확인", role: .destructive) {
                let action = model.pendingConfirm?.action
                model.pendingConfirm = nil
                action?()
            }
            if let alternative = model.pendingConfirm?.alternative {
                Button(alternative.title) {
                    model.pendingConfirm = nil
                    alternative.action()
                }
            }
            Button("취소", role: .cancel) { model.pendingConfirm = nil }
        } message: {
            Text(model.pendingConfirm?.message ?? "")
        }
    }
}

/// 도움말 메뉴가 여는 곳 (공개 저장소)
enum AppLinks {
    static let readme = URL(string: "https://github.com/youseonghyeon/nexus#readme")!
    static let changelog = URL(string: "https://github.com/youseonghyeon/nexus/blob/main/CHANGELOG.md")!
    static let issues = URL(string: "https://github.com/youseonghyeon/nexus/issues")!
}
