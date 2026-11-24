// 원격 정보 카드: 서버 종류가 지원하는 탭(RemoteCommands.Query — Spec · Network · Schedule · Firewall · Clients · WireGuard · Services · Ports · Diagnose · Live)과
// Spec 격자(SpecGrid) · 포트 표(PortsTable). 나머지 탭의 표는 OpenWrtViews · LinuxInfoViews · ServicesView · ServerLiveView.

import ServersCore
import SwiftUI

/// 원격 정보 카드: 그 서버가 지원하는 탭만 (canQuery), 구조화된 결과, 새로고침, 조회 시각. 결과는 서버별로 남는다.
struct RemoteInfoCard: View {
    @Environment(AppModel.self) private var model
    let server: Server

    private var available: [RemoteCommands.Query] { RemoteCommands.Query.allCases.filter { model.canQuery(server, $0) } }
    /// 지원하지 않는 탭(Windows 의 Spec)이 기본으로 잡히지 않게 첫 가용 탭으로
    private var tab: RemoteCommands.Query {
        if let t = model.infoTab[server.key], available.contains(t) { return t }
        return available.first ?? .spec
    }

    var body: some View {
        let entry = model.info(server, tab)
        let reachable = model.isReachable(server)
        VStack(alignment: .leading, spacing: 10) {
            let title = Text("원격 정보").font(.cardTitle).foregroundStyle(.secondary)
            // 탭 전환은 보기일 뿐이라 조용히 가져온다 (AppModel.selectInfoTab). 인증이 필요하면 안내만 남고, 새로고침(↻)이 팝업을 띄운다.
            let tabs = PlainSegmented(items: available,
                                      selection: Binding(get: { tab }, set: { model.selectInfoTab($0, for: server) }),
                                      title: \.title)
                .disabled(!RemoteInfoTabs.canSwitch(reachable: reachable, current: tab, currentFetchedAt: entry.fetchedAt))   // 실시간 탭엔 fetchedAt 이 없다 — 꺼져도 다른 탭으로 옮길 수 있게
            let trailing = HStack(spacing: 8) {
                // 실시간 탭은 저절로 갱신된다 — 확인 시각·간격은 탭 안 요약 줄에. Diagnose 는 가져오는 것이 없다
                if tab.fetches {
                    if entry.loading {
                        ProgressView().controlSize(.small)
                    } else if let at = entry.fetchedAt {
                        Text("\(at.formatted(date: .omitted, time: .shortened)) 확인").font(.caption).foregroundStyle(.secondary)
                    }
                    Button { model.fetchInfo(server, tab, allowPrompt: true) } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("다시 가져오기")
                        .buttonStyle(.borderless)
                        .disabled(!reachable || entry.loading)
                        .help("다시 가져오기")
                }
            }
            // 탭이 한 줄에 다 들어가면 제목 옆에, 좁으면(창 최소 폭 · 탭이 많은 OpenWrt) 아랫줄로 내려 가로로 민다
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { title; tabs; Spacer(minLength: 8); trailing }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) { title; Spacer(minLength: 8); trailing }
                    ScrollView(.horizontal) { tabs }.scrollIndicators(.never)
                }
            }
            if tab == .live {
                // 서버를 옮기거나 접속 정보가 바뀌면 화면·수집 루프를 새로 — 안 그러면 루프가 처음 잡은 서버를 계속 읽는다
                ServerLiveView(server: server, monitor: model.liveMonitor(server)).id(server)
            } else if tab == .diagnose {
                ServerDiagnoseView(server: server).id(server.key)   // 입력칸이 다른 서버로 옮겨 가지 않게
            } else {
                if let error = entry.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(StatusTone.warn.color)
                }
                if entry.fetchedAt == nil, entry.error == nil, !entry.loading {
                    Text(reachable ? "새로고침을 누르면 가져옵니다." : "지금은 가져올 수 없습니다.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    switch tab {
                    // 파싱은 결과를 받을 때 한 번 (RemoteInfoResult.parsed) — 그리기마다 다시 하지 않는다
                    case .spec: if case .spec(let items, let updates) = entry.parsed { SpecGrid(items: items, updates: updates).id(server.key) }   // 펼친 업데이트 목록이 다른 서버로 옮겨 가지 않게
                    case .network:
                        // 펼친 인터페이스가 다른 서버로 옮겨 가지 않게 서버마다 새로
                        if case .network(let network) = entry.parsed { OpenWrtNetworkView(lines: entry.lines, network: network).id(server.key) }
                        else if case .linuxNetwork(let network) = entry.parsed { LinuxNetworkView(lines: entry.lines, network: network).id(server.key) }
                    case .schedule: if case .schedule(let report) = entry.parsed { ScheduleView(server: server, lines: entry.lines, report: report).id(server.key) }
                    case .firewall: if case .firewall(let firewall) = entry.parsed { OpenWrtFirewallView(lines: entry.lines, firewall: firewall).id(server.key) }   // 펼친 칸이 다른 공유기로 옮겨 가지 않게
                    case .clients: if case .clients(let clients) = entry.parsed { OpenWrtClientsView(lines: entry.lines, clients: clients) }
                    case .wireguard: if case .wireguard(let report) = entry.parsed { WireGuardView(lines: entry.lines, report: report) }
                    case .services:
                        // 기본 서비스 펼침이 다른 서버로 옮겨 가지 않게 서버마다 새로
                        if case .openwrtServices(let report) = entry.parsed { OpenWrtServicesView(server: server, lines: entry.lines, report: report).id(server.key) }
                        else if case .services(let report) = entry.parsed { ServicesView(server: server, lines: entry.lines, report: report).id(server.key) }
                    case .ports: if case .ports(let items) = entry.parsed { PortsTable(server: server, items: items) }
                    case .live, .diagnose: EmptyView()
                    }
                }
            }
        }
        .padding(Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .cardSurface()
    }
}

struct SpecGrid: View {
    @Environment(AppModel.self) private var model
    let items: [SpecItem]
    /// 리눅스: 올릴 수 있는 apt 패키지. 있으면 "업데이트" 줄을 눌러 아래에 펼친다 (복사 대신)
    var updates: [UpdateItem] = []
    @State private var showUpdates = false

    var body: some View {
        let plain = items.filter { $0.usage == nil }
        let gauges = items.filter { $0.usage != nil }
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(plain) { item in
                    let expandable = item.key == "UPDATES" && !updates.isEmpty
                    HStack(spacing: 8) {
                        Text(item.label).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                        Text(item.value).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(item.warning ? StatusTone.warn.color : Color.primary)   // 재부팅 필요·보안 업데이트만 경고색
                        if expandable { Image(systemName: showUpdates ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if expandable { showUpdates.toggle() } else { model.copy(item.value) } }
                    .help(expandable ? "누르면 패키지 목록" : "클릭하면 복사")
                }
            }
            if showUpdates, !updates.isEmpty { updatesList }
            ForEach(gauges) { item in
                HStack(spacing: 8) {
                    Text(item.label).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                    // 시스템 ProgressView 는 라이트·비활성 창에서 바탕 줄이 사라져 직접 그린다.
                    // 색은 Live 탭·System·Disk 화면의 사용량 막대와 같은 단계 (80 노랑 · 90 빨강), 숫자는 경고 이상만 색
                    let level = SystemHealth.level((item.usage ?? 0) * 100, .usage)
                    MeterBar(level: item.usage ?? 0, tone: level.tone)
                        .frame(width: 120)
                    Text("\(Int(((item.usage ?? 0) * 100).rounded()))%").monospacedDigit()
                        .foregroundStyle(level == .good ? Color.primary : level.tone.color)
                        .frame(width: 40, alignment: .trailing)
                    Text(item.value).foregroundStyle(.secondary).lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture { model.copy(item.value) }
            }
            if items.isEmpty { Text("(출력 없음)").foregroundStyle(.secondary) }
        }
        .font(.callout)
    }

    /// 지금 올라가는 것 먼저, 그 안에서 보안 먼저 (파서가 정렬). 이름 · 설치됨 → 올릴 버전. 보류(순차 배포 차례 전·hold)는 흐리게
    private var updatesList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(updates) { update in
                HStack(spacing: 10) {
                    Text(update.name).lineLimit(1).truncationMode(.middle).frame(width: 200, alignment: .leading)
                        .foregroundStyle(update.deferred ? .tertiary : .primary)
                    Text("\(update.installed) → \(update.version)").foregroundStyle(update.deferred ? .tertiary : .secondary).monospacedDigit().lineLimit(1).truncationMode(.middle)
                    if update.security { StatusChip(text: "보안", tone: .warn) }
                    if update.deferred { Text("보류").font(.caption).foregroundStyle(.tertiary) }
                    Spacer()
                }
                .padding(.horizontal, 6)
                .help(update.deferred ? "지금 apt upgrade 로는 올라가지 않습니다 — 순차 배포 차례 전이거나 hold" : "")
                .textSelection(.enabled)
            }
        }
        .padding(.top, 2)
    }
}

struct PortsTable: View {
    let server: Server
    let items: [PortItem]

    var body: some View {
        // 프로세스 칸은 읽어 온 서버만 (Windows)
        let showsProcess = items.contains { $0.process != nil }
        VStack(alignment: .leading, spacing: 0) {
            // 칸 제목 — this Mac Ports 카드와 같은 작은 회색, 폭·안쪽 여백은 아래 행과 같게
            if !items.isEmpty {
                HStack(spacing: 10) {
                    Text("Port").frame(width: 56, alignment: .trailing)
                    Text("Service").frame(width: 110, alignment: .leading)
                    if showsProcess { Text("Process").frame(width: PortsTableRow.processWidth, alignment: .leading) }
                    Text("Address")
                    // 번호의 딱지가 무엇인지 (열린 포트가 있을 때만)
                    if items.contains(where: \.open) { HoverNote(label: "포트 표시 설명") { PortsLegend() } }
                    Spacer()
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.bottom, 4)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                // TCP 를 다 적은 뒤 UDP — 각 구역의 첫 줄 앞에 작은 머리 "TCP N" · "UDP N" (Services 의 구역 머리와 같은 글씨)
                if index == 0 || item.udp != items[index - 1].udp {
                    Text("\(item.udp ? "UDP" : "TCP")  \(items.filter { $0.udp == item.udp }.count)")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.top, index == 0 ? 4 : 10).padding(.bottom, 4)
                }
                PortsTableRow(server: server, item: item, showsProcess: showsProcess)
                // 오른쪽 끝 [터널…] 이 어느 행인지 보이게 희미한 구분선 (TCP · UDP 사이에는 머리가 가른다)
                if index < items.count - 1, items[index + 1].udp == item.udp { Divider().opacity(0.4) }
            }
            if items.isEmpty { Text("(리스닝 포트 없음)").foregroundStyle(.secondary) }
        }
        .font(.callout)
    }
}

/// 포트 한 줄. 마우스가 올라갔는지는 행이 따로 든다 — 표가 들면 마우스가 행을 넘을 때마다 모든 행을 다시 그렸다
private struct PortsTableRow: View {
    @Environment(AppModel.self) private var model
    let server: Server
    let item: PortItem
    var showsProcess = false
    static let processWidth: CGFloat = 150
    /// [Tunnel…] 은 마우스가 올라간 행에만 보인다 (모든 행에 있으면 오른쪽에 같은 버튼이 수십 개 늘어섰다)
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            // 모든 주소로 듣는 포트는 번호를 딱지로 (바깥에서 닿는다 — Services 의 docker 포트와 같은 표시)
            Group {
                if item.open { PortBadge(text: "\(item.port)") } else { Text(verbatim: "\(item.port)").monospacedDigit() }
            }
            .frame(width: 56, alignment: .trailing)
            Text(item.label ?? "–").foregroundStyle(item.label == nil ? .tertiary : .primary).frame(width: 110, alignment: .leading)
            if showsProcess {
                Text(item.process ?? "–").lineLimit(1).truncationMode(.middle).foregroundStyle(item.process == nil ? .tertiary : .primary)
                    .frame(width: Self.processWidth, alignment: .leading)
            }
            // 같은 포트의 v4·v6 는 한 줄, 장치에 묶였으면 장치 이름을 옅게 (ss 의 %tailscale0)
            HStack(spacing: 6) {
                Text(item.addressText).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                if !item.devices.isEmpty { Text(item.devices.joined(separator: ", ")).font(.caption).foregroundStyle(.tertiary) }
            }
            .frame(maxWidth: 420, alignment: .leading)
            Spacer()
            Button("Tunnel…") { if let address = item.tunnelAddress { model.promptTunnelToPort(server, port: item.port, address: address) } }
                .buttonStyle(CompactButtonStyle())
                .hidden(item.udp)   // ssh 터널은 TCP 만 — UDP 줄에는 버튼을 두지 않는다 (자리는 남긴다)
                .disabled(!model.isReachable(server) || item.tunnelAddress == nil)   // 장치에 묶인 와일드카드뿐이면 닿을 주소를 모른다
                .help("이 포트로 로컬 터널 (로컬 포트는 입력창에서 지정)")
                .opacity(hovering ? 1 : 0)   // 자리는 남겨 둬 행 높이·폭이 바뀌지 않게
                .allowsHitTesting(hovering)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(hovering ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: Metrics.smallRadius))   // Services 표와 같은 행 강조
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.copy(item.primaryAddress.contains(":") ? "[\(item.primaryAddress)]:\(item.port)" : "\(item.primaryAddress):\(item.port)") }
    }
}

/// Address 칸 제목 옆 ⓘ 의 설명: 번호의 딱지가 무엇인지 (올리면 바로 뜬다 — HoverNote)
private struct PortsLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Listening Ports").font(.cardTitle).foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Metrics.labelGap, verticalSpacing: 6) {
                GridRow { PortBadge(text: "443"); Text("외부 공개 (모든 주소)") }
                GridRow { Text(verbatim: "5432").monospacedDigit().foregroundStyle(.secondary); Text("해당 주소 전용") }
            }
        }
        .fixedSize()
    }
}

private extension View {
    /// 조건부로 감춘다 (자리는 남긴다)
    @ViewBuilder func hidden(_ hide: Bool) -> some View {
        if hide { hidden() } else { self }
    }
}
