// LOCAL 화면: 이 Mac 의 Spec · 주소 · hosts · 라우팅 테이블 · 리스닝 포트. 서버 화면과 같은 틀이고 정보는 로컬 명령만 읽는다.

import ServersCore
import SwiftUI

struct LocalDashboardView: View {
    @Environment(AppModel.self) private var model
    /// 카드 열 폭 — 넉넉하면 짧은 카드(주소·Hosts)를 나란히
    @State private var width: CGFloat = 0

    var body: some View {
        let info = model.localInfo
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                HeroCard { header(info) } strip: {
                    Group {
                        if let info, !info.spec.isEmpty { SpecGrid(items: info.spec) } else { Text("확인 중…").foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                }
                nameCards(info)
                InfoCard(title: "Routes") { routes(info) }
                InfoCard(title: "Ports") { ports(info) } accessory: {
                    // 리스닝 포트가 밖에서 열려 있는지는 방화벽에 달렸다 — 표 위 제목 줄 오른쪽에
                    HStack(spacing: 6) {
                        Text("Firewall").foregroundStyle(.secondary)
                        Text(info?.firewall?.text ?? "–")
                    }
                    .font(.caption)
                }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
            .padding(EdgeInsets(top: 0, leading: 40, bottom: 20, trailing: 40))   // 위는 툴바가 이미 띄워 준다
            .frame(maxWidth: 1200, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)   // 스크롤 영역은 창 폭 전체 — 툴바 밑 띠가 1200 에서 끊기지 않게
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await model.fetchLocalInfo() }   // 선택(didSet)이 이미 읽는 중이면 그 읽기를 기다린다
    }

    /// 주소(DNS 포함)와 Hosts — 이름 풀이 두 카드. 넓으면 나란히(높이 맞춤), 좁으면 위아래. 넓은 표(Routes·Ports)는 전체 폭 그대로
    @ViewBuilder
    private func nameCards(_ info: LocalInfo?) -> some View {
        let address = InfoCard(title: "Address") { addresses(info) }
        let hostsCard = InfoCard(title: "Hosts") { hosts(info) }
        if width >= 760 {
            HStack(alignment: .top, spacing: Metrics.gap) {
                address.fillingHeight()
                hostsCard.fillingHeight()
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            address
            hostsCard
        }
    }

    private func header(_ info: LocalInfo?) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(value("HOSTNAME", info) ?? "this Mac").font(.screenTitle).tracking(-0.6)
                Text([value("OS", info), value("UPTIME", info).map { "가동 \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    Button { model.openLocalShell() } label: { Label("로컬 셸", systemImage: "terminal") }
                        .help("이 Mac 의 셸 탭 (⌘⇧T)")
                    Button { Task { await model.fetchLocalInfo(force: true) } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("다시 읽기")
                        .help("다시 가져오기")
                }
                .buttonStyle(SecondaryButtonStyle())   // 시스템 기본 버튼은 무채색 tint 아래서 꺼진 것처럼 흐렸다
                if let at = info?.fetchedAt {
                    Text("\(at.formatted(date: .omitted, time: .shortened)) 확인").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func value(_ key: String, _ info: LocalInfo?) -> String? {
        info?.spec.first { $0.key == key }?.value
    }

    @ViewBuilder
    private func addresses(_ info: LocalInfo?) -> some View {
        // 이 Mac 이 실제로 나가는 길은 그 장치의 IP 옆 딱지로 (Wi-Fi·Ethernet 화면은 자기 장치로만 재므로 기본 경로는 여기에만).
        // 기본 경로 장치에 주소 줄이 없을 때만 따로 한 줄
        let routeDevice = model.defaultRoute?.interface
        let addresses = info?.addresses ?? []
        Grid(alignment: .leading, horizontalSpacing: Metrics.labelGap, verticalSpacing: 6) {
            ForEach(addresses) { address in
                GridRow {
                    Text(address.name).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(address.ip).textSelection(.enabled)
                        if address.device == routeDevice { StatusChip(text: "기본 경로") }
                    }
                }
            }
            if routeDevice == nil || !addresses.contains(where: { $0.device == routeDevice }) {
                GridRow {
                    Text("기본 경로").font(.fieldLabel).foregroundStyle(.secondary)
                    Text(model.defaultRouteText).textSelection(.enabled)
                }
            }
            GridRow {
                Text("DNS").font(.fieldLabel).foregroundStyle(.secondary)
                Text(model.dnsConfig?.primary?.nameserverText ?? "–").textSelection(.enabled)
            }
            // 검색 도메인은 있을 때만 (Wi-Fi·Ethernet·Intranet 화면과 같은 규칙)
            if let domains = model.dnsConfig?.primary?.searchDomainText {
                GridRow {
                    Text("검색 도메인").font(.fieldLabel).foregroundStyle(.secondary)
                    Text(domains).textSelection(.enabled)
                }
            }
            // 프록시는 켜져 있을 때만 — 켜져 있으면 앱·브라우저의 길이 Routes 와 다르다
            if let proxies = info?.proxies, !proxies.isEmpty {
                GridRow(alignment: .top) {
                    Text("Proxy").font(.fieldLabel).foregroundStyle(.secondary)
                    Text(proxies.joined(separator: "\n")).textSelection(.enabled)
                }
            }
            GridRow(alignment: .top) {
                Text("공인 IP").font(.fieldLabel).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(model.publicIP[""] ?? (model.publicIPLoading.contains("") ? "확인 중…" : "–")).textSelection(.enabled)
                        if model.publicIPLoading.contains("") { ProgressView().controlSize(.small) }
                        Button { model.fetchPublicIP(force: true) } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("공인 IP 다시 확인")
                            .buttonStyle(.borderless).controlSize(.small).help("다시 확인").disabled(model.publicIPLoading.contains(""))
                    }
                    if let ip = model.publicIP[""], let location = model.publicIPLocation[ip], !location.text.isEmpty {
                        Text(location.text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            .help("IP 로 추정한 위치 — 등록지로 나올 수 있습니다")
                    }
                }
            }
        }
    }

    /// IPv4 라우팅 테이블. 실제로 트래픽이 타는 줄(default 또는 0/1 짝)에 딱지, default 앞엔 순위 번호,
    /// 장치에 묶인 default·0/1 짝에 밀린 default 는 옅게 (그 장치를 지정한 연결만 쓴다)
    @ViewBuilder
    private func routes(_ info: LocalInfo?) -> some View {
        if let table = info?.routes, !table.entries.isEmpty {
            // 경로 그림이 먼저, 표는 그 옆(좁으면 아래) — 그림이 한눈에 읽혀 앞에 둔다 (2026-11-10 사용자 결정)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 32) {
                    RouteGraphView(table: table)
                    routeGrid(table).fixedSize()
                    Spacer(minLength: 0)
                }
                // 좁을 때는 표를 제 폭으로 고정하지 않는다 — 고정하면 카드보다 넓어져 창 전체가 옆으로 밀렸다 (창 최소 폭 900 에서 사이드바가 잘림)
                VStack(alignment: .leading, spacing: 16) {
                    ScrollView(.horizontal) { RouteGraphView(table: table) }.scrollIndicators(.never)
                    routeGrid(table)
                }
            }
        } else {
            Text(info == nil ? "확인 중…" : info?.routes == nil ? "라우팅 테이블을 읽지 못했습니다." : "경로가 없습니다.").foregroundStyle(.secondary)
        }
    }

    private func routeGrid(_ table: RouteTable) -> some View {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                GridRow {
                    Text("#"); Text("Destination"); Text("Gateway"); Text("Interface")
                }
                .font(.caption).foregroundStyle(.secondary)
                Rectangle().fill(Palette.hairline).frame(height: 1).gridCellUnsizedAxes(.horizontal)   // 머리 줄 아래 가는 선
                ForEach(table.entries) { entry in
                    let inUse = table.carriesTraffic(entry)
                    GridRow {
                        Text(entry.rank.map(String.init) ?? "").foregroundStyle(.secondary).monospacedDigit()
                        Text(entry.destination)
                        Text(entry.gateway ?? "On-link")
                        HStack(spacing: 8) {
                            Text(entry.interfaces.joined(separator: ", "))
                            let detail = table.detail(for: entry)
                            if !detail.isEmpty { Text(detail).foregroundStyle(.secondary) }
                            if inUse { StatusChip(text: "기본 경로") }
                        }
                    }
                    .foregroundStyle(entry.kind == .scoped || (entry.kind == .primary && !inUse) ? .secondary : .primary)
                    .textSelection(.enabled)
                }
            }
    }

    /// /etc/hosts 와 도메인별 DNS — 둘 다 "이 이름은 어디서 풀리나" 규칙. 도메인별 DNS 는 있을 때만
    @ViewBuilder
    private func hosts(_ info: LocalInfo?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            hostsEntries(info)
            if let resolvers = model.dnsConfig?.domainResolvers, !resolvers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("도메인별 DNS").font(.caption).foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                        GridRow {
                            Text("Domain"); Text("Nameserver")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        Rectangle().fill(Palette.hairline).frame(height: 1).gridCellUnsizedAxes(.horizontal)   // 머리 줄 아래 가는 선
                        ForEach(Array(resolvers.enumerated()), id: \.offset) { _, resolver in
                            GridRow {
                                Text(resolver.domain ?? "")
                                HStack(spacing: 8) {
                                    Text(resolver.nameservers.joined(separator: ", "))
                                    if let device = resolver.device { Text(device).foregroundStyle(.secondary) }
                                }
                            }
                            .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    /// /etc/hosts — 기본 줄은 빼고 파일 순서대로. 앱의 서버 이름 터널 줄엔 딱지, 앞 줄에 가려 풀리지 않는 이름은 옅게
    @ViewBuilder
    private func hostsEntries(_ info: LocalInfo?) -> some View {
        if let entries = info?.hosts, !entries.isEmpty {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                GridRow {
                    Text("Address"); Text("Hostname")
                }
                .font(.caption).foregroundStyle(.secondary)
                Rectangle().fill(Palette.hairline).frame(height: 1).gridCellUnsizedAxes(.horizontal)   // 머리 줄 아래 가는 선
                ForEach(entries) { entry in
                    let dead = entry.shadowed.count == entry.names.count
                    GridRow {
                        Text(entry.address)
                        HStack(spacing: 8) {
                            Text(entry.names.joined(separator: ", "))
                            if entry.byApp { StatusChip(text: "터널", tone: .muted) }
                            if !entry.shadowed.isEmpty {
                                Text("앞 줄에 가려 쓰이지 않음: \(entry.shadowed.joined(separator: ", "))").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .foregroundStyle(dead ? .secondary : .primary)
                    .textSelection(.enabled)
                }
            }
        } else {
            Text(info == nil ? "확인 중…" : info?.hosts == nil ? "/etc/hosts 를 읽지 못했습니다." : "기본 항목 외에 등록된 이름이 없습니다.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func ports(_ info: LocalInfo?) -> some View {
        if let info, !info.ports.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                // 칸 제목 — Routes 카드와 같은 작은 회색, 폭은 아래 행과 같게
                HStack(spacing: 10) {
                    Text("Port").frame(width: 56, alignment: .trailing)
                    Text("Process").frame(width: 150, alignment: .leading)
                    Text("Address").frame(width: 120, alignment: .leading)
                    Text("Service")
                    Spacer()
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(info.ports) { port in
                    HStack(spacing: 10) {
                        Text(verbatim: "\(port.port)").monospacedDigit().frame(width: 56, alignment: .trailing)
                        Text(port.command).lineLimit(1).truncationMode(.middle).frame(width: 150, alignment: .leading)
                        Text(port.address).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                        // 앱이 연 터널이면 어디로 가는지, 아니면 잘 알려진 포트 이름
                        if let tunnel = port.tunnel(among: model.tunnels.filter { $0.state == .open }.map(\.spec)) {
                            StatusChip(text: "터널 → \(tunnel.server.key)", tone: .good)
                        } else if let label = RemoteInfo.knownPorts[port.port] {
                            Text(label).foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                }
                Text("\(info.portsAt.formatted(date: .omitted, time: .shortened)) 확인 · \(Int(LocalInfoCollector.slowInterval))초 간격").font(.caption).foregroundStyle(.tertiary)
            }
        } else {
            Text(info == nil ? "확인 중…" : "리스닝 중인 TCP 포트가 없습니다.").foregroundStyle(.secondary)
        }
    }
}
