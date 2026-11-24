// 원격 정보의 OpenWrt 탭: Network(인터페이스별 경로·포트 · 정책 규칙) · Firewall(존 매트릭스·포트 포워딩·규칙·스크립트) · Clients(DHCP 임대·고정 할당·ARP) · WireGuard(피어) · Services(procd). 파싱은 ServersCore OpenWrt.
// 줄 모양은 Services 표와 같다: 상태 점 · 이름 · 흐린 설명 · 오른쪽 고정 폭 숫자 열. 색은 상태 점에만. 줄·구역 부품은 InfoTableParts.

import ServersCore
import SwiftUI

private enum Column {
    static let uptime: CGFloat = 92
    static let bytes: CGFloat = 150
    static let address: CGFloat = 150
    static let lease: CGFloat = 92
    static let firewallMatch: CGFloat = 200
    static let firewallTarget: CGFloat = 70
    static let chevron: CGFloat = 18
    /// 점 뒤 이름 줄에 맞춘 들여쓰기 (행 여백 6 + 점 8 + 간격 8)
    static let indent: CGFloat = 22
}

// MARK: Network

struct OpenWrtNetworkView: View {
    @Environment(AppModel.self) private var model
    let lines: [String]
    /// 결과를 받을 때 한 번 파싱해 둔 값 (RemoteInfoResult.parsed)
    let network: OpenWrtNetwork?
    /// 펼친 인터페이스. 나란히 비교하도록 여럿 열 수 있다
    @State private var expanded: Set<String> = []

    var body: some View {
        if let network {
            VStack(alignment: .leading, spacing: 16) {
                // 경로 그림 (맨 위 — 2026-11-10 사용자 결정): 장치 옆에 인터페이스 이름과 IP ("wan 203.0.113.7")
                if let routing = network.routing {
                    let details = Dictionary(network.interfaces.compactMap { i -> (String, String)? in
                        guard let device = i.device else { return nil }
                        let ip = i.addresses.first { !$0.contains(":") }.map { String($0.split(separator: "/")[0]) }
                        return (device, [i.name, ip].compactMap { $0 }.joined(separator: " "))
                    }, uniquingKeysWith: { a, _ in a })
                    let graph = RouteGraphView(routing: routing, root: model.selectedServer?.key ?? "router", details: details)
                    if !graph.graph.lanes.isEmpty {
                        infoSection("Routes") { ScrollView(.horizontal) { graph.padding(.top, 4) }.scrollIndicators(.never) }   // 좁은 카드에서는 가로로 민다
                    }
                }
                infoSection("Interfaces \(network.interfaces.count)") {
                    ForEach(network.layout.items) { item in interfaceItem(item, routing: network.routing) }
                    if network.interfaces.isEmpty { Text("인터페이스가 없습니다").foregroundStyle(.secondary) }
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
                if !network.layout.otherPorts.isEmpty {
                    infoSection("Other ports \(network.layout.otherPorts.count)") {
                        ForEach(network.layout.otherPorts) { port in portRow(port) }
                    }
                }
            }
            .font(.callout)
        } else {
            RawLines(lines: lines)
        }
    }

    /// 인터페이스 한 줄 + 행 아래 경로 + 눌러서 펼치는 상세. 펼칠 게 없으면(장치 없는 secondwan 등) 누를 수 없다
    private func interfaceItem(_ item: OpenWrtNetworkLayout.Item, routing: OpenWrtRouting?) -> some View {
        let iface = item.interface
        let isExpanded = expanded.contains(item.id)
        return VStack(alignment: .leading, spacing: 2) {
            OpenWrtRow(dot: iface.state == .up ? .green : (iface.state == .failed ? .red : .secondary), help: item.hasDetail ? "누르면 상세" : nil,
                       action: item.hasDetail ? { toggle(item.id) } : nil) {
                Text(iface.name).lineLimit(1).layoutPriority(1)
                Text((item.descriptors + [OpenWrtPort.summary(item.ports)].compactMap { $0 }).joined(separator: " · "))
                    .foregroundStyle(.tertiary).lineLimit(1)
            } trailing: {
                Text(iface.addresses.first ?? "").frame(width: Column.address, alignment: .trailing).truncationMode(.middle)
                Text(stateText(iface)).frame(width: Column.uptime, alignment: .trailing)
                Text(transferText(iface.rxBytes, iface.txBytes)).frame(width: Column.bytes, alignment: .trailing)
                Group {
                    if item.hasDetail { Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.caption2) }
                }
                .frame(width: Column.chevron, alignment: .trailing)
            }
            ForEach(item.routes) { route in InfoRouteLine(route: route, routing: routing, indent: Column.indent) }
            if isExpanded { interfaceDetail(item).padding(.leading, Column.indent).padding(.vertical, 4) }
        }
    }

    private func toggle(_ id: String) {
        if expanded.remove(id) == nil { expanded.insert(id) }
    }

    private func interfaceDetail(_ item: OpenWrtNetworkLayout.Item) -> some View {
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
            if let gateway = item.detailGateway { infoDetailRow("Gateway") { Text(gateway).textSelection(.enabled) } }
            if !iface.dns.isEmpty { infoDetailRow("DNS") { Text(iface.dns.joined(separator: ", ")).textSelection(.enabled) } }
            if !item.subnetRoutes.isEmpty {
                infoDetailRow("Routes") { InfoSubnetRoutes(routes: item.subnetRoutes) }
            }
            if !item.ports.isEmpty {
                infoDetailRow(item.ports.count > 1 ? "Ports" : "Port") {
                    ForEach(item.ports) { port in
                        HStack(spacing: 8) {
                            Circle().fill(port.carrier ? StatusTone.good.color : Color.secondary).frame(width: 8, height: 8)
                            Text(port.name)
                            Text(port.carrier ? port.speedText : "down").foregroundStyle(.secondary)
                            Text(transferText(port.rxBytes, port.txBytes)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    /// 켜짐이면 가동 시간, 아니면 상태어 (no device · down · netifd 오류 코드)
    private func stateText(_ iface: OpenWrtInterface) -> String {
        switch iface.state {
        case .up: return iface.uptime.map(DurationFormat.compact) ?? ""
        case .unused: return "no device"
        case .down: return "down"
        case .failed: return iface.error ?? "down"
        }
    }

    private func portRow(_ port: OpenWrtPort) -> some View {
        OpenWrtRow(dot: port.carrier ? .green : .secondary) {
            Text(port.name).lineLimit(1)
            // 이 포트를 쓰는 인터페이스 — 인터페이스 줄의 "proto · 장치" 와 같은 흐린 글씨
            Text(port.interfaces.joined(separator: " · ")).foregroundStyle(.tertiary).lineLimit(1)
        } trailing: {
            Text(port.carrier ? port.speedText : "down").frame(width: Column.uptime, alignment: .trailing)
            Text(transferText(port.rxBytes, port.txBytes)).frame(width: Column.bytes, alignment: .trailing)
        }
    }
}

// MARK: Firewall

struct OpenWrtFirewallView: View {
    let lines: [String]
    /// 결과를 받을 때 한 번 파싱해 둔 값 (RemoteInfoResult.parsed)
    let firewall: OpenWrtFirewall?
    @State private var selection = FirewallSelection()
    // 규칙은 칸을 누르면 방향별로 나오니 전체 목록은 접어 둔다. 없는 존을 가리키는 규칙은 어느 칸에도 안 나와 목록을 없애지는 않는다
    @State private var showRules = false
    @State private var showScripts = false

    var body: some View {
        if let firewall {
            VStack(alignment: .leading, spacing: 16) {
                infoSection("Zones \(firewall.zones.count)") {
                    matrix(firewall)
                    legend
                    Text("칸의 허용·차단은 IPv4 새 연결 기준입니다. include 스크립트가 직접 넣는 규칙은 판정에 들어가지 않습니다.")
                        .font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 6).padding(.top, 4)
                }
                if let cell = selection.cell(in: firewall.matrix) { cellDetail(cell) }
                // firewall · port_forward 두 곳을 봤다는 뜻이다. 스크립트가 직접 넣은 것까지 없다고 단정하지 않는다
                infoSection("Port forwards \(firewall.portForwards.count)") {
                    ForEach(firewall.portForwards) { ruleRow($0) }
                    if firewall.portForwards.isEmpty { Text("설정된 포트 포워딩 없음").foregroundStyle(.secondary).padding(.horizontal, 6) }
                }
                if !firewall.rules.isEmpty {
                    foldable("Rules \(firewall.rules.count)", isOpen: $showRules) {
                        ForEach(firewall.rules) { ruleRow($0) }
                    }
                }
                if !firewall.scripts.isEmpty {
                    foldable("Scripts \(firewall.scripts.count)", isOpen: $showScripts) {
                        Text("이 스크립트가 직접 넣는 규칙은 위 목록에 나오지 않습니다.").font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 6).padding(.bottom, 2)
                        ForEach(firewall.scripts) { script in
                            OpenWrtRow(dot: script.enabled ? .green : .secondary) {
                                Text(script.path).foregroundStyle(script.enabled ? .primary : .secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            } trailing: { EmptyView() }
                        }
                    }
                }
            }
            .font(.callout)
        } else {
            RawLines(lines: lines)
        }
    }

    /// 칸 모양 풀이: 채운 면 = 허용 · 빈 면 = 차단 · 노랑 점 = 기본 정책과 반대로 하는 규칙이 있음
    private var legend: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Palette.control)
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Palette.hairline)).frame(width: 14, height: 10)
                Text("허용")
            }
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Palette.fieldBorder).frame(width: 14, height: 10)
                Text("차단")
            }
            HStack(spacing: 5) {
                Circle().fill(StatusTone.warn.color).frame(width: 6, height: 6)
                Text("기본 정책과 다른 규칙 있음")
            }
        }
        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.top, 6)
    }

    /// 제목을 누르면 펼치는 구역. 제목 모양은 infoSection 과 같다
    private func foldable<Content: View>(_ title: String, isOpen: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { isOpen.wrappedValue.toggle() } label: {
                Label(title, systemImage: isOpen.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.caption).foregroundStyle(.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.bottom, 2)
            if isOpen.wrappedValue { content() }
        }
    }

    /// 행 = 출발, 열 = 도착. 칸을 누르면 아래에 그 칸의 정책·규칙이 펼쳐진다
    private func matrix(_ firewall: OpenWrtFirewall) -> some View {
        let matrix = firewall.matrix
        return Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                Text("From ↓   To →")
                ForEach(matrix.columns, id: \.self) { Text($0.title).frame(maxWidth: .infinity).lineLimit(1) }
            }
            .font(.caption).foregroundStyle(.secondary)
            Rectangle().fill(Palette.hairline).frame(height: 1).gridCellUnsizedAxes(.horizontal)   // 머리 줄 아래 가는 선
            ForEach(matrix.rows, id: \.self) { row in
                GridRow {
                    rowLabel(row, firewall)
                    ForEach(matrix.columns, id: \.self) { column in
                        if let cell = matrix.cell(from: row, to: column) {
                            cellButton(cell)
                        } else {
                            Color.clear.frame(height: 40)   // 장비 → 장비
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 6)
    }

    /// 존 이름 아래 소속 네트워크. 다 안 들어가면 마우스를 올리면 보인다
    private func rowLabel(_ row: FirewallMatrix.Endpoint, _ firewall: OpenWrtFirewall) -> some View {
        let zone = firewall.zones.first { FirewallMatrix.Endpoint.zone($0.name) == row }
        let networks = zone?.networks.joined(separator: ", ") ?? ""
        return VStack(alignment: .leading, spacing: 1) {
            Text(row.title).lineLimit(1)
            if !networks.isEmpty { Text(networks).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
        }
        .frame(width: 104, alignment: .leading)
        .help(zone.map { "Networks: \(networks)\nMasquerade: \($0.masq ? "on" : "off")" } ?? "")
    }

    private func cellButton(_ cell: FirewallMatrix.Cell) -> some View {
        Button { selection.tap(cell.key) } label: {
            // 허용·차단은 좋고 나쁨이 아니라 열림·닫힘 — 색 대신 명암으로: 열린 칸은 채운 면, 닫힌 칸은 선만 두른 빈 면.
            // 색(노랑 점)은 기본 정책과 반대로 하는 규칙이 있는 칸에만 — "어디에 예외가 있나"가 먼저 보이게 (2026-11-10).
            // 초록 면은 "전부 정상"으로 읽혔다: wan → lan 이 열려 있어도 초록이었다.
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            let hasException = cell.note != nil   // 예외 규칙이 있거나, 조건 없는 규칙이 기본 정책을 뒤집은 칸
            VStack(spacing: 1) {
                Text(cell.allowed ? "허용" : "차단")
                    .fontWeight(cell.allowed ? .semibold : .regular)
                    .foregroundStyle(cell.allowed ? Color.primary : Color.secondary)
                HStack(spacing: 4) {
                    if hasException { Circle().fill(StatusTone.warn.color).frame(width: 6, height: 6) }
                    Text(cell.note ?? " ").font(.caption2).foregroundStyle(hasException ? .secondary : .tertiary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(cell.allowed ? Palette.control : Color.clear, in: shape)
            .overlay {
                if selection.key == cell.key {
                    shape.strokeBorder(Color.primary.opacity(0.55), lineWidth: 1.5)
                } else {
                    shape.strokeBorder(cell.allowed ? Palette.hairline : Palette.fieldBorder)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func cellDetail(_ cell: FirewallMatrix.Cell) -> some View {
        infoSection("\(cell.key.from.title) → \(cell.key.to.title)") {
            Text("기본 정책 \(cell.policy)  ·  \(cell.policySource)").foregroundStyle(.secondary).padding(.horizontal, 6)
            if let deciding = cell.decidingRule {
                Text("조건 없는 규칙 \(deciding.name) 이 먼저 적용되어 IPv4 새 연결은 \(cell.allowed ? "허용" : "차단")입니다.")
                    .foregroundStyle(.secondary).padding(.horizontal, 6)
            }
            ForEach(cell.rules) { ruleRow($0, shadowed: cell.isShadowed($0)) }.padding(.top, 2)
            if cell.rules.isEmpty { Text("이 방향에 적용되는 규칙 없음").foregroundStyle(.tertiary).padding(.horizontal, 6).padding(.top, 2) }
        }
    }

    private func ruleRow(_ rule: OpenWrtFirewall.Rule, shadowed: Bool = false) -> some View {
        let active = rule.enabled && !shadowed
        return OpenWrtRow(dot: active ? .green : .secondary, help: rule.extras) {
            Text(rule.name).foregroundStyle(active ? .primary : .secondary).lineLimit(1).layoutPriority(1)
            Text(rule.flow).foregroundStyle(.tertiary).lineLimit(1)
            if let source = rule.source { StatusChip(text: source, tone: .muted) }
            if rule.enabled && shadowed { StatusChip(text: "적용 안 됨", tone: .muted) }
        } trailing: {
            Text(rule.match).frame(width: Column.firewallMatch, alignment: .trailing).truncationMode(.middle)
            Text(rule.target).frame(width: Column.firewallTarget, alignment: .trailing)
        }
    }
}

// MARK: Clients

struct OpenWrtClientsView: View {
    @Environment(AppModel.self) private var model
    let lines: [String]
    let clients: [OpenWrtClient]?

    var body: some View {
        if let clients {
            infoSection("장비 \(clients.count) · 활성 \(clients.filter(\.active).count)") {
                // 전부 고정 할당이면 빈 칸을 남기지 않고 IP 를 오른쪽 끝에 붙인다
                let showsLease = clients.contains { $0.visibleLease != nil }
                ForEach(clients) { client in row(client, showsLease: showsLease) }
                if clients.isEmpty { Text("임대·고정 할당·ARP 기록이 없습니다").foregroundStyle(.secondary) }
            }
            .font(.callout)
        } else {
            RawLines(lines: lines)
        }
    }

    private func row(_ client: OpenWrtClient, showsLease: Bool) -> some View {
        // 제조사(MAC 앞자리, 오프라인 IEEE 목록) — 임의 MAC 이면 그렇게. 모르면 MAC 으로 구분한다
        let vendor = DeviceIdentity.isRandomMAC(client.mac) ? "임의 MAC" : AppModel.ouiTable?.vendor(mac: client.mac)
        return OpenWrtRow(dot: client.active ? .green : .secondary, help: help(client),
                          action: client.ip.map { ip in { model.copy(ip) } }) {
            Text(client.name ?? "–").foregroundStyle(client.name == nil ? .tertiary : (client.active ? .primary : .secondary)).lineLimit(1).layoutPriority(1)
            if client.isDynamic { Text("DHCP").font(.caption).foregroundStyle(.secondary) }
            Text(vendor ?? client.mac).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
        } trailing: {
            Text(client.ip ?? "").frame(width: Column.address, alignment: .trailing)
            if showsLease { Text(OpenWrtClient.leaseText(client.visibleLease)).frame(width: Column.lease, alignment: .trailing) }
        }
    }

    /// 행에서 뺀 값(MAC · 임대 시간)과 점의 뜻
    private func help(_ client: OpenWrtClient) -> String {
        [client.mac,
         client.leaseRemaining.map { "임대 남은 시간 \(OpenWrtClient.leaseText($0))" },
         client.active ? "방금 통신 확인됨" : "최근 통신 확인 안 됨 (꺼졌다는 뜻은 아닙니다)",
         client.ip == nil ? nil : "누르면 IP 복사"].compactMap { $0 }.joined(separator: "\n")
    }
}

// MARK: WireGuard

struct WireGuardView: View {
    @Environment(AppModel.self) private var model
    let lines: [String]
    let report: WireGuardReport?

    var body: some View {
        switch report {
        case .notInstalled:
            Text("WireGuard 가 설치돼 있지 않습니다").foregroundStyle(.secondary).font(.callout)
        case .interfaces(let interfaces):
            VStack(alignment: .leading, spacing: 16) {
                ForEach(interfaces) { iface in
                    let active = iface.peers.filter(\.isActive).count
                    infoSection([iface.name, iface.listenPort.map { "port \($0)" }, "피어 \(iface.peers.count) · 연결 \(active)"]
                        .compactMap { $0 }.joined(separator: " · ")) {
                        ForEach(iface.peers) { peer in row(peer) }
                        if iface.peers.isEmpty { Text("피어가 없습니다").foregroundStyle(.secondary) }
                    }
                }
                if interfaces.isEmpty { Text("WireGuard 인터페이스가 없습니다").foregroundStyle(.secondary) }
            }
            .font(.callout)
        case nil:
            RawLines(lines: lines)
        }
    }

    private func row(_ peer: WireGuardPeer) -> some View {
        OpenWrtRow(dot: peer.isActive ? .green : .secondary, help: help(peer), action: { model.copy(peer.publicKey) }) {
            Text(peer.name ?? String(peer.publicKey.prefix(8)) + "…").lineLimit(1).layoutPriority(1)
            Text(peer.allowedIPs.joined(separator: ", ")).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
        } trailing: {
            Text(peer.endpoint ?? "").frame(width: Column.address, alignment: .trailing).truncationMode(.middle)
            Text(transferText(peer.rxBytes, peer.txBytes)).frame(width: Column.bytes, alignment: .trailing)
        }
    }

    /// 핸드셰이크는 약 2분마다 키를 새로 맞추는 시각이라 연결 시작 시간으로 읽히기 쉬워 행에 내지 않는다 (2026-11-06 사용자 지적). 연결 여부는 점으로
    private func help(_ peer: WireGuardPeer) -> String {
        "마지막 핸드셰이크 \(peer.handshakeAgo.map { DurationFormat.compact($0) + " 전" } ?? "없음")\n누르면 공개 키 복사"
    }
}

// MARK: Services

struct OpenWrtServicesView: View {
    @Environment(AppModel.self) private var model
    let server: Server
    let lines: [String]
    let report: OpenWrtServices?
    @State private var showOther = false

    var body: some View {
        if let report {
            VStack(alignment: .leading, spacing: 16) {
                if !report.stopped.isEmpty {
                    infoSection("멈춤 \(report.stopped.count)") {
                        ForEach(report.stopped) { service in
                            row(service, dot: .red) { Text(service.exitCode.map { "exit \($0)" } ?? "") }
                        }
                    }
                }
                infoSection("실행 중 \(report.running.count)") {
                    ForEach(report.running) { service in
                        row(service, dot: .green) {
                            Text(service.instances > 1 ? "\(service.running)/\(service.instances)" : "")
                            Text(service.enabled ? "" : "부팅 시 꺼짐").frame(width: Column.uptime, alignment: .trailing)
                        }
                    }
                    if report.running.isEmpty { Text("실행 중인 서비스가 없습니다").foregroundStyle(.secondary) }
                }
                if !report.other.isEmpty {
                    Button { showOther.toggle() } label: {
                        Label("그 밖 \(report.other.count)개 (한 번 도는 스크립트 · 꺼 둔 서비스)", systemImage: showOther ? "chevron.down" : "chevron.right")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).padding(.leading, 6)
                    if showOther {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(report.other) { service in
                                row(service, dot: .secondary) { Text(service.enabled ? "" : "꺼짐") }
                            }
                        }
                    }
                }
            }
            .font(.callout)
        } else {
            RawLines(lines: lines)
        }
    }

    private func row<Trailing: View>(_ service: OpenWrtService, dot: Color, @ViewBuilder trailing: () -> Trailing) -> some View {
        OpenWrtRow(dot: dot, help: "누르면 최근 로그", action: { model.showServiceLog(server, unit: service.name) }) {
            Text(service.name).lineLimit(1)
        } trailing: {
            trailing()
        }
    }
}
