// 사이드바: 그룹별 서버 목록과 망·피어·SSH 상태.

import ServersCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var columns: NavigationSplitViewVisibility
    /// 맨 위 검색칸 (⌘K). 비어 있지 않으면 망·로컬 섹션을 접고 맞는 서버·터널·전송만 보인다.
    @State private var query = ""
    /// 접은 서버 그룹 이름 (줄바꿈으로 이어 저장 — 재실행해도 유지). 검색 중엔 모두 펼친다.
    @AppStorage("sidebarCollapsedGroups") private var collapsedGroups = ""

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private func groupExpanded(_ group: String) -> Binding<Bool> {
        Binding(
            get: { searching || !collapsedGroups.split(separator: "\n").contains(Substring(group)) },
            set: { expanded in
                var names = collapsedGroups.split(separator: "\n").map(String.init).filter { $0 != group }
                if !expanded { names.append(group) }
                collapsedGroups = names.joined(separator: "\n")
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.configError {
                ConfigErrorView(error: error)
                Divider()
            }
            // ⌘K 는 터미널·브라우저 탭이 보일 땐 그쪽에 양보한다 (터미널 ⌘K = 화면 지우기)
            SidebarSearchField(query: $query, shortcutEnabled: model.visibleTab == nil) {
                // Enter: 첫 서버를 고르고 검색을 비운다
                guard let config = model.config, let first = matchingGroups(config).first?.servers.first else { return }
                model.select(key: first.key)
                query = ""
            }
            if let config = model.config {
                let groups = matchingGroups(config)
                // 접은 그룹은 여기서 한 번만 푼다 (⌘ 번호 · 그룹 머리 요약). 접기 바인딩(groupExpanded)은 누른 직후 값을 읽히므로 저장값을 그대로 본다
                let collapsed = Set(collapsedGroups.split(separator: "\n").map(String.init))
                // ⌘ 번호: 보이는 서버 앞 9개 (접힌 그룹은 건너뜀) — ⌘1–⌘9 가 같은 목록을 쓴다
                let numbered = QuickSelect.keys(groups: groups.map { ($0.group, $0.servers.map(\.key)) },
                                                collapsed: collapsed, searching: searching)
                let tunnels = model.sortedTunnels.filter { ServerSearch.matches("\($0.title) \($0.detail)", query) }
                let transfers = model.transfers.filter { ServerSearch.matches($0.title, query) }
                // 검색으로 선택된 행이 숨겨져도 선택은 지우지 않는다 (지우면 상세 화면·탭이 사라진다)
                List(selection: Binding(get: { model.selectedKey }, set: { if $0 != nil || !searching { model.select(key: $0) } })) {
                    if !searching {
                        Section {
                            WiFiRow(wifi: model.wifi).tag(AppModel.wifiKey).sidebarSelection(model.selectedKey == AppModel.wifiKey)
                            EthernetRow().tag(AppModel.ethernetKey).sidebarSelection(model.selectedKey == AppModel.ethernetKey)
                            // Intranet 은 Ethernet 바로 아래 — 같은 유선 어댑터의 서비스다 (2026-10-15)
                            if config.lan != nil {
                                NetworkRow(kind: .lan).tag(AppModel.lanKey).sidebarSelection(model.selectedKey == AppModel.lanKey)
                            }
                            if config.showsTailscale(model.status.tailscale, checked: model.status.tailscaleChecked) {
                                NetworkRow(kind: .tailscale).tag(AppModel.tailscaleKey).sidebarSelection(model.selectedKey == AppModel.tailscaleKey)
                            }
                            if !(model.vpns ?? []).isEmpty {
                                VPNRow().tag(AppModel.vpnKey).sidebarSelection(model.selectedKey == AppModel.vpnKey)
                            }
                        } header: {
                            SidebarSectionTitle("Network")
                        }
                        Section {
                            LocalRow()
                            .tag(AppModel.localKey).sidebarSelection(model.selectedKey == AppModel.localKey)
                            .contextMenu { Button("New Local Shell") { model.openLocalShell() } }
                            SystemRow(monitor: model.system).tag(AppModel.systemKey).sidebarSelection(model.selectedKey == AppModel.systemKey)
                            DiskRow(monitor: model.disk).tag(AppModel.diskKey).sidebarSelection(model.selectedKey == AppModel.diskKey)
                            BluetoothRow(monitor: model.bluetooth).tag(AppModel.bluetoothKey).sidebarSelection(model.selectedKey == AppModel.bluetoothKey)
                        } header: {
                            SidebarSectionTitle("Local")
                        }
                    }
                    ForEach(groups) { entry in
                        // 오른쪽 끝 > (마우스를 올리면 보임) 로 접고 편다
                        Section(isExpanded: groupExpanded(entry.group)) {
                            ForEach(entry.servers) { server in
                                ServerRow(server: server, number: numbered.firstIndex(of: server.key).map { $0 + 1 })
                                    .tag(server.key).sidebarSelection(model.selectedKey == server.key)
                                    .contextMenu { ServerContextMenu(server: server) }
                                    // Finder 에서 파일을 이 행에 놓으면 그 서버로 업로드
                                    .dropDestination(for: URL.self) { urls, _ in
                                        guard model.isReachable(server) else { return false }
                                        model.promptUpload(server, localPaths: urls.filter(\.isFileURL).map(\.path))
                                        return true
                                    }
                            }
                        } header: {
                            GroupHeader(group: entry.group, servers: entry.servers, collapsed: !searching && collapsed.contains(entry.group))
                        }
                    }
                    // 서버가 하나도 없으면(새 목록) 그룹 머리의 + 도 없다 — 서버가 놓일 자리에 추가 행을 둔다
                    if !searching, config.servers.isEmpty {
                        Section {
                            AddFirstServerRow().selectionDisabled()
                        } header: {
                            SidebarSectionTitle("Servers")
                        }
                    }
                    // 서버 그룹 아래: 열린 터널·전송
                    if !tunnels.isEmpty {
                        Section {
                            ForEach(tunnels) { tunnel in
                                TunnelRow(tunnel: tunnel)
                            }
                        } header: {
                            SidebarSectionTitle("Tunnels")
                        }
                    }
                    if !transfers.isEmpty {
                        Section {
                            ForEach(transfers) { transfer in
                                TransferRow(transfer: transfer)
                            }
                        } header: {
                            SidebarSectionTitle("Transfers")
                        }
                    }
                    if searching, groups.isEmpty, tunnels.isEmpty, transfers.isEmpty {
                        Text("맞는 서버·터널이 없습니다").foregroundStyle(.secondary).selectionDisabled()
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .onChange(of: numbered, initial: true) { QuickSelectState.shared.keys = numbered }
            } else {
                Spacer()
            }
        }
        .background(Palette.sidebar)   // 시스템 재질 대신 — 본문보다 한 단계 어둡게
        // 사이드바 아래 고정 줄: 반투명 사이드바에 녹이고, 목록이 밑으로 스크롤되면 가장자리 효과. (.bar 를 깔면 색 다른 띠가 생긴다)
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 0) {
                if model.appUpdate != .none { UpdateBanner(update: model.appUpdate) { model.installUpdate() } }
                NetworkFooter()
            }
        }
        .toolbar(removing: .sidebarToggle)
        // 사이드바 칸 툴바: 신호등 옆에 토글 · 지금 확인 (유리 캡슐 없이)
        .toolbar {
            ToolbarItem {
                HStack(spacing: 2) {
                    SidebarToggleButton(columns: $columns)
                    RefreshButton()
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }

    /// 사이드바 섹션 하나. 목록 안 식별자는 그룹 이름 그대로가 아니라 "group:<이름>" — 서버 행의 식별자(서버 키)와 글자가 같으면
    /// 목록(NSOutlineView)이 둘을 한 항목으로 섞어 그 그룹의 펼침 상태가 서버 행 값으로 덮이고, > 를 눌러도 접히지 않았다
    /// (2026-11-07 그룹 acme 와 서버 acme — 서버 행이 보이는 동안만 멈춰 "됐다 안 됐다" 로 보였다). 서버 키엔 ':' 가 올 수 없어 겹치지 않는다.
    private struct GroupEntry: Identifiable {
        let group: String
        let servers: [Server]
        var id: String { "group:\(group)" }
    }

    /// 검색어에 맞는 서버가 있는 그룹만 (검색어가 없으면 전부)
    private func matchingGroups(_ config: ServerConfig) -> [GroupEntry] {
        config.groups
            .map { group in GroupEntry(group: group, servers: config.servers(in: group).filter { ServerSearch.matches($0, query) }) }
            .filter { !$0.servers.isEmpty }
    }
}

/// 사이드바 맨 위 검색칸. ⌘K 로 들어오고 Enter 는 첫 결과, Esc 로 비운다.
struct SidebarSearchField: View {
    @Environment(AppModel.self) private var model
    @Binding var query: String
    /// ⌘K 단축키를 받을지 (터미널·브라우저 탭이 보이면 끈다)
    let shortcutEnabled: Bool
    let onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("서버 · 터널 검색", text: $query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { onSubmit(); focused = false }
                .onExitCommand { query = ""; focused = false }
                .onChange(of: focused) { _, now in model.setSidebarSearchFocused(now) }
            ZStack(alignment: .trailing) {
                // ⌘K 안내이자 단축키 — 검색 중에도 단축키는 살아 있게 자리를 지키고 보이기만 끈다
                Button { focused = true } label: {
                    HStack(spacing: 3) {
                        ForEach(["⌘", "K"], id: \.self) { key in
                            Text(key).font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.35)))
                        }
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(shortcutEnabled ? KeyboardShortcut("k", modifiers: .command) : nil)
                .opacity(query.isEmpty && shortcutEnabled ? 1 : 0)
                .help("검색 (⌘K)")
                .accessibilityLabel("검색")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("검색어 지우기")
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("검색 지우기 (Esc)")
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous).strokeBorder(Palette.hairline))
        .padding(.horizontal, 10).padding(.bottom, 6)   // 윗변은 본문 대표 카드의 윗변과 같은 높이
    }
}

struct GroupHeader: View {
    @Environment(AppModel.self) private var model
    let group: String
    let servers: [Server]
    /// 접혔을 때만 서버 상태 요약 — 펼치면 각 행의 점과 겹친다
    let collapsed: Bool

    var body: some View {
        HStack(spacing: 6) {
            // 망 상태 점은 두지 않는다 — 그룹 안 서버가 모두 한 망이라는 보장이 없다 (2026-10-26)
            Text(group).font(.cardTitle).tracking(0.3).foregroundStyle(.secondary)
            if collapsed { summary }
            // 오른쪽 끝은 섹션 접기(>) 자리라 이름 바로 뒤에 둔다
            Button { model.promptAddServer(group: group) } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))   // 이름(12pt)과 획 굵기를 맞춘다 — .caption 은 1px 로 흐려 보였다
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("\(group) 에 서버 추가")
            Spacer()
        }
        .contentShape(Rectangle())
        // 그룹 순서 = servers.conf 에서 첫 서버 블록이 나오는 순서. 옮기면 그 그룹 블록 전부를 이웃 그룹 앞·뒤로.
        .contextMenu {
            Button("위로 이동") { model.moveGroup(group, .up) }.disabled(!model.canMoveGroup(group, .up))
            Button("아래로 이동") { model.moveGroup(group, .down) }.disabled(!model.canMoveGroup(group, .down))
        }
    }

    /// 서버마다 작은 점 (행의 상태 점과 같은 색, 순서대로). 8대 이상이면 길어지므로 "켜짐/전체" 숫자로.
    @ViewBuilder
    private var summary: some View {
        if servers.count >= 8 {
            Text(verbatim: "\(servers.filter { model.remoteTone($0) == .good }.count)/\(servers.count)")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                .help(servers.map { "\($0.key) · \(model.remoteHelp($0))" }.joined(separator: "\n"))
        } else {
            HStack(spacing: 3) {
                ForEach(servers) { server in
                    Circle().fill(model.remoteTone(server).color).frame(width: 6, height: 6)
                        .help("\(server.key) · \(model.remoteHelp(server))")
                }
            }
        }
    }
}

extension View {
    /// 사이드바 행의 선택 표시: 시스템 강조(파랑 — 무채색 강조색은 물 빠진 회색) 대신 이 앱의 올라온 면 + 가는 선.
    /// 탭 전환의 고른 칸과 같은 말투다. 시스템 강조는 SidebarHighlightOff 가 끈다 (2026-11-10 사용자 지적)
    func sidebarSelection(_ selected: Bool) -> some View {
        environment(\.sidebarRowSelected, selected).listRowBackground(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Palette.raisedSidebar : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? Palette.hairline : Color.clear))
                .padding(.horizontal, 10)
        )
    }
}

/// 목록(NSOutlineView)의 시스템 선택 강조를 끈다 — 선택 면은 행마다 sidebarSelection 이 그린다.
/// 목록 안 아무 행에나 배경으로 넣으면 위로 올라가 표를 찾는다. 선택·끌어 놓기·우클릭 동작은 그대로다 (그리기만 끈다).
struct SidebarHighlightOff: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Finder() }
    func updateNSView(_ view: NSView, context: Context) { (view as? Finder)?.apply() }

    private final class Finder: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        func apply() {
            var view: NSView? = superview
            while let current = view {
                if let table = current as? NSTableView {
                    if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
                    return
                }
                view = current.superview
            }
        }
    }
}

/// 사이드바 섹션 머리: 카드 제목과 같은 작은 회색 글씨 (대문자로 바꾸지 않는다)
struct SidebarSectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).font(.cardTitle).tracking(0.3).foregroundStyle(.secondary)
            .background(SidebarHighlightOff())   // 섹션 머리는 늘 목록 안에 있다 — 여기서 표의 시스템 강조를 끈다
    }
}

/// 사이드바 보이기·가리기 (납작한 아이콘). 사이드바 윗줄에 두고, 사이드바를 접으면 본문 윗줄 앞(신호등 옆)으로 온다.
struct SidebarToggleButton: View {
    @Binding var columns: NavigationSplitViewVisibility

    var body: some View {
        Button {
            withAnimation { columns = columns == .detailOnly ? .all : .detailOnly }
        } label: {
            Label(columns == .detailOnly ? "사이드바 보기" : "사이드바 가리기", systemImage: "sidebar.left")
        }
        .buttonStyle(TopRowIconStyle())
        .allowsWindowActivationEvents(true)
        .help(columns == .detailOnly ? "사이드바 보기" : "사이드바 가리기")
    }
}

/// 사이드바 맨 아래 고정 줄: 마지막 확인 시각 · 주기 · 설정(⌘,) 톱니바퀴
struct NetworkFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            if model.isChecking {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(model.lastRefresh == nil ? StatusTone.muted.color : StatusTone.good.color).frame(width: 6, height: 6)
            }
            if let at = model.lastRefresh {
                Text("\(at, style: .time) 확인")
            } else {
                Text("확인 중 …")
            }
            Spacer()
            Text("\(Int(model.checkInterval))초 간격")
            // 간격을 여기서 바로 바꿀 수 있게 설정 창으로 (메뉴 Nexus ▸ 설정… 과 같다)
            SettingsLink {
                Image(systemName: "gearshape").font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("설정 (⌘,)")
            .accessibilityLabel("설정")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

/// 새 버전이 있을 때 사이드바 아래 줄 위에 뜨는 띠: 버전 · 상태 한 줄 · [업데이트]. 받는 동안은 버튼 대신 아랫변에 진행 막대.
/// 글자·버튼·진행률은 ServersCore AppUpdate 가 정한다.
struct UpdateBanner: View {
    let update: AppUpdate
    let install: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle").font(.system(size: 14)).foregroundStyle(.primary.opacity(0.8))
            VStack(alignment: .leading, spacing: 1) {
                Text(update.title(appName: "Nexus") ?? "").fontWeight(.medium).lineLimit(1)
                Text(update.subtitle ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let title = update.buttonTitle {
                Button(title, action: install).buttonStyle(CompactButtonStyle())
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Palette.raisedSidebar, in: shape)
        .overlay(shape.strokeBorder(Palette.hairline))
        .overlay(alignment: .bottomLeading) {
            if let progress = update.progress {
                GeometryReader { proxy in
                    Capsule().fill(StatusTone.good.color).frame(width: max(0, (proxy.size.width - 16) * progress), height: 2)
                }
                .frame(height: 2).padding(.horizontal, 8).padding(.bottom, 3)
            }
        }
        .padding(.horizontal, 10).padding(.top, 6)
        .accessibilityElement(children: .combine)
    }
}

/// 파싱 오류 배너. 이전 설정이 있으면 목록은 그대로 두고 위에만 띄운다.
struct ConfigErrorView: View {
    let error: ConfigError

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("servers.conf 오류 · 이전 설정 유지 중", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text("문제: \(error.problem)")
            Text("해결: \(error.fix)")
            Text("참조: \(error.reference)").foregroundStyle(.secondary)
        }
        .font(.caption)
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(StatusTone.warn.color.opacity(0.15))
    }
}
