// 원격 정보의 리눅스 탭: Network(인터페이스별 주소·경로 · 정책 규칙 · DNS) · Schedule(systemd 타이머 · cron). 파싱은 ServersCore LinuxInfo.
// 줄 모양은 OpenWrt·Services 표와 같다: 상태 점 · 이름 · 흐린 설명 · 오른쪽 고정 폭 열 (부품은 InfoTableParts). 읽기만 — 조치 버튼은 없다 (2026-11-07).

import ServersCore
import SwiftUI

private enum LinuxColumn {
    static let address: CGFloat = 150
    static let state: CGFloat = 50
    static let bytes: CGFloat = 150
    static let chevron: CGFloat = 18
    /// 점 뒤 이름 줄에 맞춘 들여쓰기 (행 여백 6 + 점 8 + 간격 8)
    static let indent: CGFloat = 22
    static let when: CGFloat = 110
    static let schedule: CGFloat = 130
    static let user: CGFloat = 70
}

// MARK: Network

struct LinuxNetworkView: View {
    @Environment(AppModel.self) private var model
    let lines: [String]
    /// 결과를 받을 때 한 번 파싱해 둔 값 (RemoteInfoResult.parsed)
    let network: LinuxNetwork?
    /// 펼친 인터페이스. 나란히 비교하도록 여럿 열 수 있다
    @State private var expanded: Set<String> = []
    /// 컨테이너 배선(veth · 브리지) 묶음을 펼쳤는가 (기본 접힘 — docker 서버는 veth 가 대부분이다)
    @State private var showFolded = false

    var body: some View {
        if let network {
            VStack(alignment: .leading, spacing: 16) {
                // 경로 그림 (맨 위 — 2026-11-10 사용자 결정): 컨테이너 배선(veth · 브리지)은 뺀다 — docker 서버는 수십 개라 그림이 쓸모없어진다
                if let routing = network.routing {
                    let folded = Set(network.interfaces.filter(\.isFolded).map(\.name))
                    let details = Dictionary(network.interfaces.compactMap { i in i.ipv4.first.map { (i.name, String($0.split(separator: "/")[0])) } }, uniquingKeysWith: { a, _ in a })
                    let graph = RouteGraphView(routing: routing, root: model.selectedServer?.key ?? "server", details: details, excluding: folded)
                    if !graph.graph.lanes.isEmpty {
                        infoSection("Routes") { ScrollView(.horizontal) { graph.padding(.top, 4) }.scrollIndicators(.never) }   // 좁은 카드에서는 가로로 민다
                    }
                }
                infoSection("Interfaces \(network.interfaces.count)") {
                    ForEach(network.layout.visibleItems) { item in interfaceItem(item, routing: network.routing) }
                    if network.interfaces.isEmpty { Text("인터페이스가 없습니다").foregroundStyle(.secondary) }
                    let folded = network.layout.foldedItems
                    if !folded.isEmpty {
                        Button { showFolded.toggle() } label: {
                            Label("\(network.foldedTitle) \(folded.count)개", systemImage: showFolded ? "chevron.down" : "chevron.right")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain).padding(.leading, 6).padding(.top, 4)
                        if showFolded { ForEach(folded) { item in interfaceItem(item, routing: network.routing) } }
                    }
                    if network.routing == nil {
                        Text("경로를 읽지 못했습니다.").foregroundStyle(.secondary).padding(.horizontal, 6).padding(.top, 4)
                    } else if network.routing?.defaultRoutes.isEmpty == true {
                        StatusChip(text: "기본 경로 없음", tone: .warn).padding(.horizontal, 6).padding(.top, 4)
                    }
                }
                if let routing = network.routing, !network.layout.otherRoutes.isEmpty {
                    infoSection("Other routes \(network.layout.otherRoutes.count)") { OtherRoutesGrid(routes: network.layout.otherRoutes, routing: routing) }
                }
                if let routing = network.routing, !routing.policyRules.isEmpty {
                    infoSection("Policy rules \(routing.policyRules.count)") { PolicyRulesView(routing: routing) }
                }
                infoSection("DNS") {
                    Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 4) {
                        GridRow {
                            Text("Servers").font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                            if network.dns.isEmpty {
                                Text("없음").foregroundStyle(.secondary)
                            } else {
                                HStack(spacing: 10) {
                                    ForEach(network.dns, id: \.self) { server in
                                        Button(server) { model.copy(server) }.buttonStyle(.plain).help("누르면 주소 복사")
                                    }
                                }
                            }
                        }
                        if !network.searchDomains.isEmpty {
                            GridRow {
                                Text("Search").font(.caption).foregroundStyle(.secondary)
                                Text(network.searchDomains.joined(separator: " ")).textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }
            .font(.callout)
        } else {
            RawLines(lines: lines)
        }
    }

    /// 인터페이스 한 줄 + 행 아래 경로 + 눌러서 펼치는 상세 (주소 전부 · MAC · MTU · 자기 대역 경로)
    private func interfaceItem(_ item: LinuxNetworkLayout.Item, routing: OpenWrtRouting?) -> some View {
        let iface = item.interface
        let isExpanded = expanded.contains(item.id)
        return VStack(alignment: .leading, spacing: 2) {
            OpenWrtRow(dot: iface.up ? .green : .secondary, help: item.hasDetail ? "누르면 상세" : nil,
                       action: item.hasDetail ? { toggle(item.id) } : nil) {
                Text(iface.name).lineLimit(1).layoutPriority(1)
                Text(iface.descriptors.joined(separator: " · ")).foregroundStyle(.tertiary).lineLimit(1)
            } trailing: {
                Text(iface.ipv4.first ?? iface.addresses.first ?? "").frame(width: LinuxColumn.address, alignment: .trailing).truncationMode(.middle)
                Text(iface.up ? "up" : "down").frame(width: LinuxColumn.state, alignment: .trailing)
                Text(transferText(iface.rxBytes, iface.txBytes)).frame(width: LinuxColumn.bytes, alignment: .trailing)
                Group {
                    if item.hasDetail { Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.caption2) }
                }
                .frame(width: LinuxColumn.chevron, alignment: .trailing)
            }
            ForEach(item.routes) { route in InfoRouteLine(route: route, routing: routing, indent: LinuxColumn.indent) }
            if isExpanded { interfaceDetail(item).padding(.leading, LinuxColumn.indent).padding(.vertical, 4) }
        }
    }

    private func toggle(_ id: String) {
        if expanded.remove(id) == nil { expanded.insert(id) }
    }

    private func interfaceDetail(_ item: LinuxNetworkLayout.Item) -> some View {
        let iface = item.interface
        return Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 4) {
            if !iface.addresses.isEmpty {
                infoDetailRow("Address") {
                    ForEach(iface.addresses, id: \.self) { address in
                        Button(address) { model.copy(String(address.split(separator: "/").first ?? Substring(address))) }
                            .buttonStyle(.plain).help("누르면 주소 복사")
                    }
                }
            }
            if let mac = iface.mac { infoDetailRow("MAC") { Text(mac).textSelection(.enabled) } }
            if let mtu = iface.mtu { infoDetailRow("MTU") { Text(String(mtu)).monospacedDigit() } }
            if !item.subnetRoutes.isEmpty {
                infoDetailRow("Routes") { InfoSubnetRoutes(routes: item.subnetRoutes) }
            }
        }
    }
}

// MARK: Schedule

struct ScheduleView: View {
    let server: Server
    let lines: [String]
    let report: ScheduleReport?

    var body: some View {
        if let report {
            VStack(alignment: .leading, spacing: 16) {
                infoSection("Timers\(report.timers.map { " \($0.count)" } ?? "")") {
                    if let timers = report.timers {
                        ForEach(timers) { timer in timerRow(timer, now: report.now) }
                        if timers.isEmpty { Text("타이머가 없습니다").foregroundStyle(.secondary) }
                    } else {
                        Text("타이머 목록을 읽지 못했습니다").foregroundStyle(.secondary)
                    }
                }
                ForEach(report.cronBySource, id: \.source) { group in
                    // 내 crontab 은 접속 계정 하나라 사용자 칸이 없고, 시스템 crontab(/etc/crontab · cron.d)은 줄마다 실행 사용자가 있다
                    infoSection(sourceTitle(group.source, count: group.entries.count)) {
                        ForEach(group.entries) { entry in cronRow(entry, showUser: group.source != "crontab") }
                    }
                }
                if report.cron.isEmpty {
                    infoSection("Cron") { Text("cron 작업이 없습니다").foregroundStyle(.secondary) }
                }
                if !report.periodic.isEmpty {
                    infoSection("Periodic") {
                        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 4) {
                            ForEach(report.periodic) { jobs in
                                GridRow {
                                    Text(jobs.period).font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                                    Text(jobs.jobs.joined(separator: " · ")).textSelection(.enabled)
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                }
            }
            .font(.callout)
        } else {
            RawLines(lines: lines)
        }
    }

    /// 다음 실행이 있으면 초록. 오른쪽: 다음 "14분 뒤" · 지난 "2시간 전"
    private func timerRow(_ timer: SystemdTimer, now: Date) -> some View {
        OpenWrtRow(dot: timer.next != nil ? .green : .secondary) {
            Text(timer.name).lineLimit(1).layoutPriority(1)
            if let activates = timer.activatesIfDifferent { Text(activates).foregroundStyle(.tertiary).lineLimit(1) }
        } trailing: {
            Text(timer.nextText(now: now))
                .frame(width: LinuxColumn.when, alignment: .trailing)
            Text(timer.lastText(now: now))
                .frame(width: LinuxColumn.when, alignment: .trailing)
        }
        .help(timer.unit + " → " + timer.activates)
    }

    /// 주기(읽는 말 · 원문) · 명령 · 실행 사용자
    private func cronRow(_ entry: CronEntry, showUser: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.description ?? entry.schedule).lineLimit(1)
                if entry.description != nil { Text(entry.schedule).font(.caption.monospaced()).foregroundStyle(.tertiary) }
            }
            .frame(width: LinuxColumn.schedule, alignment: .leading)
            Text(entry.command).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 8)
            if showUser { Text(entry.user ?? "").foregroundStyle(.secondary).frame(width: LinuxColumn.user, alignment: .trailing).lineLimit(1) }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .help(entry.schedule + "  " + entry.command)
    }

    /// 묶음 제목: 내 crontab 은 접속 계정, 파일은 경로
    private func sourceTitle(_ source: String, count: Int) -> String {
        source == "crontab" ? "crontab · \(server.user) \(count)" : "\(source) \(count)"
    }
}
