// 오른쪽: 선택한 서버(또는 로컬)의 터미널 탭. 탭이 없으면 서버 정보와 액션 버튼.
//
// 모든 터미널 뷰는 항상 마운트해 둔다. libghostty 의 surface(PTY 자식 포함)는 NSView 가 소유하므로
// 뷰를 내리면 ssh 세션이 죽는다. 보이지 않는 탭은 opacity 0 + isSurfaceVisible=false 로만 감춘다.

import ServersCore
import SwiftUI

struct DetailView: View {
    @Environment(AppModel.self) private var model
    @Binding var columns: NavigationSplitViewVisibility
    /// 본문 폭 (툴바의 탭 막대 폭을 정한다)
    @State private var width: CGFloat = 600
    /// 툴바 양 끝 여백 — 넘치면 툴바가 항목을 » 메뉴로 접어 탭이 사라지므로 넉넉히
    private static let inset: CGFloat = 32
    /// 사이드바를 접었을 때: 신호등 + 토글·지금 확인 자리까지
    private static let collapsedInset: CGFloat = 170

    var body: some View {
        let visible = model.visibleTab
        let mine = model.tabsForSelected
        ZStack {
            if visible == nil {
                placeholder
            }
            ForEach(model.tabs) { tab in
                TabPane(tab: tab, isVisible: tab.id == visible?.id)
            }
        }
        .background(Palette.content)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        // 본문 칸 툴바: 탭 막대. 사이드바를 접어도 사이드바 칸의 토글·지금 확인은 툴바에 남아 탭 앞에 온다 (여기서 또 넣으면 두 벌).
        .toolbar {
            if !mine.isEmpty {
                ToolbarItem(placement: .navigation) {
                    // 툴바 항목은 내용 크기만큼만 커진다 — 본문 폭을 재서 탭 막대 폭을 준다 (넘치면 막대 안에서 스크롤)
                    TabBar(tabs: mine, activeID: visible?.id)
                        .frame(width: max(width - (columns == .detailOnly ? Self.collapsedInset : Self.inset), 120))
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        // 탭 막대 버튼의 패널 (명령 모음 · 메모·로그인): 본문 오른쪽 위에 앱이 그린다
        .overlay { TabBarPanels() }
        .scrollEdgeEffectHidden(true, for: .top)   // 툴바 밑 색 다른 띠·선(기본 가장자리 효과)을 없앤다 — 안쪽 모든 스크롤 뷰(대시보드·탭줄)에 적용
        // 대신 툴바 높이만큼 본문색 가림판: 평소엔 안 보이고, 스크롤한 내용이 투명한 툴바 밑으로 비쳐 탭 글자와 겹치지 않게 (2026-10-14).
        // 클릭은 통과 — 툴바 빈 곳 끌기(창 이동)를 막지 않는다.
        .overlay(alignment: .top) {
            GeometryReader { proxy in
                Palette.content.frame(height: proxy.safeAreaInsets.top).ignoresSafeArea(edges: .top)
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if model.selectedKey == AppModel.tailscaleKey {
            NetworkDashboardView(kind: .tailscale)
        } else if model.selectedKey == AppModel.vpnKey {
            VPNDashboardView()
        } else if model.selectedKey == AppModel.lanKey {
            NetworkDashboardView(kind: .lan)
        } else if model.selectedKey == AppModel.wifiKey {
            WiFiDashboardView(wifi: model.wifi)
        } else if model.selectedKey == AppModel.ethernetKey {
            EthernetDashboardView()
        } else if model.selectedKey == AppModel.systemKey {
            SystemDashboardView(monitor: model.system)
        } else if model.selectedKey == AppModel.diskKey {
            DiskDashboardView(monitor: model.disk)
        } else if model.selectedKey == AppModel.bluetoothKey {
            BluetoothDashboardView(monitor: model.bluetooth)
        } else if model.selectedKey == AppModel.localKey {
            LocalDashboardView()
        } else if let server = model.selectedServer {
            ServerInfoView(server: server)
        } else if model.config?.servers.isEmpty == true {
            // 새로 만든 servers.conf (ConfigLocation) — 그룹 헤더의 + 가 없으므로 여기서 추가
            ContentUnavailableView {
                Label("등록된 서버가 없습니다", systemImage: "server.rack")
            } description: {
                Text("서버를 추가하면 왼쪽 목록에 그룹별로 나옵니다.")
            } actions: {
                Button("서버 추가") { model.promptAddServer(group: "") }.buttonStyle(PrimaryButtonStyle())
            }
        } else {
            ContentUnavailableView("서버를 선택하세요", systemImage: "server.rack",
                                   description: Text("왼쪽 목록에서 서버를 고르면 정보와 접속 버튼이 나옵니다."))
        }
    }
}
