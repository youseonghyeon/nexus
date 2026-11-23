// 사이드바의 행들: 터널 · 망(Tailscale/LAN) · Wi-Fi · Ethernet · VPN · 서버(+컨텍스트 메뉴).

import ServersCore
import SwiftUI

/// TUNNELS 섹션의 한 행: 상태등 · 설명 · 끊기(×). 클릭하면 접속 정보 시트.
struct TunnelRow: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var tunnel: TunnelSession

    var body: some View {
        HStack(spacing: 8) {
            StatusIcon(symbol: TunnelIcon.symbol(for: tunnel.spec.kind), tone: tunnel.tone)
            VStack(alignment: .leading, spacing: 1) {
                Text(tunnel.title).fontWeight(.medium)
                Text(tunnel.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !tunnel.isActive {
                Button { model.reconnectTunnel(tunnel.id) } label: { Image(systemName: "arrow.clockwise.circle") }.accessibilityLabel("터널 다시 연결")
                    .buttonStyle(.borderless)
                    .disabled(!model.isReachable(tunnel.server))
                    .help("다시 연결")
            }
            Button {
                if tunnel.isActive { model.stopTunnel(tunnel.id) } else { model.removeTunnel(tunnel.id) }
            } label: {
                Image(systemName: tunnel.isActive ? "stop.circle" : "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help(tunnel.isActive ? "터널 끊기" : "목록에서 지우기")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { model.showTunnelInfo(tunnel) }
        .selectionDisabled()
        .contextMenu {
            Button("접속 정보") { model.showTunnelInfo(tunnel) }
            if tunnel.isActive {
                Button("끊기") { model.stopTunnel(tunnel.id) }
            } else {
                Button("다시 연결") { model.reconnectTunnel(tunnel.id) }.disabled(!model.isReachable(tunnel.server))
            }
            Button("지우기") { model.removeTunnel(tunnel.id) }
        }
    }

}

/// NETWORK 섹션의 한 행: 이름 · 상태 · 켜기/끄기. 서버 액션과 분리된 망 제어.
struct NetworkRow: View {
    enum Kind { case tailscale, lan }
    @Environment(AppModel.self) private var model
    let kind: Kind
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            StatusIcon(symbol: symbol, tone: tone)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                // 망 행마다 버튼이 늘 떠 있으면 목록이 시끄럽다. 마우스를 올렸을 때만 (자리는 유지해 흔들리지 않게).
                Button(isUp ? "끄기" : "켜기") { toggle() }
                    .buttonStyle(CompactButtonStyle())
                    .disabled(!canToggle)
                    .help(help)
                    .opacity(hovering ? 1 : 0)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var symbol: String {
        switch kind {
        case .tailscale: return "circle.grid.3x3"
        case .lan: return "building.2"
        }
    }

    private var name: String {
        switch kind {
        case .tailscale: return model.networkName(.tailscale)
        case .lan: return model.networkName(.lan)
        }
    }

    private var isUp: Bool {
        switch kind {
        case .tailscale: return model.tailscaleRunning
        case .lan: return model.status.lan == .up
        }
    }

    private var isBusy: Bool {
        switch kind {
        case .tailscale: return model.busyAction?.kind == .tailscale
        case .lan: return model.busyAction?.kind == .lan
        }
    }

    private var canToggle: Bool {
        switch kind {
        case .tailscale: return model.canToggleTailscale
        case .lan: return model.canToggleLan
        }
    }

    private var tone: StatusTone {
        switch kind {
        case .tailscale: return model.tailscaleTone
        case .lan: return model.lanTone
        }
    }

    private var detail: String {
        switch kind {
        case .tailscale: return model.tailscaleDetail
        case .lan: return model.lanDetail
        }
    }

    private var help: String {
        switch kind {
        case .tailscale: return isUp ? "이 Mac 의 Tailscale 연결 전체를 끕니다 (확인)" : "Tailscale 켜기"
        case .lan: return isUp ? "내부망 서비스를 끄고 추가 경로를 지웁니다 (Touch ID)" : "내부망 서비스를 켜고 경로를 추가합니다 (Touch ID)"
        }
    }

    private func toggle() {
        switch kind {
        case .tailscale: model.toggleTailscale()
        case .lan: model.toggleLan()
        }
    }
}

/// LOCAL 의 이 Mac 모니터 행(시스템·디스크·블루투스): 아이콘+상태 점 · 이름 · 요약. NETWORK 행과 같은 모양이고 버튼은 없다.
struct LocalMonitorRow: View {
    let name: String
    let symbol: String
    let detail: String
    let tone: StatusTone

    var body: some View {
        HStack(spacing: 8) {
            StatusIcon(symbol: symbol, tone: tone)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// LOCAL 의 this Mac 행: 마우스를 올리면 오른쪽 끝에 새 로컬 셸 버튼 (망 행의 켜기·끄기처럼 올렸을 때만).
struct LocalRow: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        LocalRowContent(hasTabs: !model.localTabs.isEmpty, hovering: hovering) { model.openLocalShell() }
            .onHover { hovering = $0 }
    }
}

/// this Mac 행의 모양 (값만 받는다 — 스크래치에서 올린 모습까지 비트맵으로 확인).
/// 다른 행과 같은 아이콘 자리 — 상태가 없어 점만 없다. 버튼은 열린 탭 표시와 같은 자리에 얹어 행 높이가 그대로다.
struct LocalRowContent: View {
    let hasTabs: Bool
    let hovering: Bool
    let openShell: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            StatusIcon(symbol: "laptopcomputer")
            Text("this Mac").fontWeight(.medium)
            Spacer()
            if hasTabs {
                Image(systemName: "terminal.fill").font(.caption).foregroundStyle(.secondary)
                    .opacity(hovering ? 0 : 1)
            }
        }
        .contentShape(Rectangle())
        .overlay(alignment: .trailing) {
            Button(action: openShell) { Image(systemName: "terminal") }
                .accessibilityLabel("새 로컬 셸")
                .buttonStyle(CompactButtonStyle())
                .help("새 로컬 셸")
                .opacity(hovering ? 1 : 0)
        }
    }
}

/// 시스템 행: "CPU 12% · 메모리 62%". 첫 표본 전엔 회색.
struct SystemRow: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        LocalMonitorRow(name: "System", symbol: "cpu", detail: monitor.summary, tone: monitor.snapshot == nil ? .muted : monitor.health.level.tone)
    }
}

/// 디스크 행: "213 GB 남음 · 57% 사용". 첫 표본 전엔 회색.
struct DiskRow: View {
    @ObservedObject var monitor: DiskMonitor

    var body: some View {
        LocalMonitorRow(name: "Disk", symbol: "internaldrive", detail: monitor.summary, tone: monitor.rows.isEmpty ? .muted : monitor.health.level.tone)
    }
}

/// 블루투스 행: "켜짐 · 2개 연결" · 배터리 낮으면 노랑/빨강 · 꺼짐은 회색
struct BluetoothRow: View {
    @ObservedObject var monitor: BluetoothMonitor

    var body: some View {
        LocalMonitorRow(name: "Bluetooth", symbol: StatusIcon.bluetooth, detail: monitor.summary, tone: monitor.health.level?.tone ?? .muted)
    }
}

/// NETWORK 섹션의 Wi-Fi 행: SSID · 신호 · 켜기/끄기 (이 Mac 의 Wi-Fi)
struct WiFiRow: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var wifi: WiFiMonitor
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            StatusIcon(symbol: "wifi", tone: tone)
            VStack(alignment: .leading, spacing: 1) {
                Text("Wi-Fi").fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let info = wifi.info {
                // NetworkRow 와 같은 규칙: 마우스를 올렸을 때만 (자리는 유지)
                Button(info.powerOn ? "끄기" : "켜기") { model.toggleWiFi() }
                    .buttonStyle(CompactButtonStyle())
                    .opacity(hovering ? 1 : 0)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var tone: StatusTone { model.wifiTone(wifi.info) }
    private var detail: String { model.wifiDetail(wifi.info) }
}

/// Ethernet 행 (읽기 전용 — Wi-Fi 행과 달리 켜기·끄기 버튼이 없다)
struct EthernetRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            StatusIcon(symbol: "rectangle.connected.to.line.below", tone: model.ethernetTone)
            VStack(alignment: .leading, spacing: 1) {
                Text("Ethernet").fontWeight(.medium)
                Text(model.ethernetDetail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// 사이드바 행: "VPN" · 요약("MacBook 연결됨") · 켜기/끄기 (Intranet 행처럼 마우스를 올렸을 때만, 자리는 유지).
/// 켜진 게 있으면 끄기(켜진 것 전부), 없으면 켜기 — VPN 이 여럿이면 메뉴로 고른다 (SystemVPNs.rowAction).
struct VPNRow: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let vpns = model.vpns ?? []
        HStack(spacing: 8) {
            LocalMonitorRow(name: "VPN", symbol: "key.horizontal", detail: SystemVPNs.summary(vpns), tone: VPNDashboardView.tone(vpns))
            if !model.vpnBusy.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                button(SystemVPNs.rowAction(vpns))
                    .buttonStyle(CompactButtonStyle())
                    .opacity(hovering ? 1 : 0)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private func button(_ action: SystemVPNs.RowAction) -> some View {
        switch action {
        case .turnOff(let on):
            Button("끄기") { on.forEach(model.toggleVPN) }
        case .turnOn(let vpn):
            Button("켜기") { model.toggleVPN(vpn) }
        case .choose(let candidates):
            Menu("켜기") {
                ForEach(candidates) { vpn in Button("\(vpn.name) · \(vpn.kind)") { model.toggleVPN(vpn) } }
            }
            .menuIndicator(.hidden).fixedSize()
        case .unavailable:
            Button("켜기") {}.disabled(true)
        }
    }
}

struct ServerRow: View {
    @Environment(AppModel.self) private var model
    @ObservedObject private var quickSelect = QuickSelectState.shared
    let server: Server
    /// ⌘ 를 누르고 있을 때 보일 번호 (1–9, 없으면 nil)
    var number: Int?

    var body: some View {
        HStack(spacing: 8) {
            StatusIcon(symbol: server.iconSymbol, tone: model.remoteTone(server))
                .help(model.remoteHelp(server))
                // ⌘ 번호가 뜨는 동안은 아이콘을 감춘다 — 배지(15)가 아이콘을 다 덮지 못해 가장자리가 삐져나온다
                .opacity(quickSelect.visible && number != nil ? 0 : 1)
                // ⌘ 번호: 아이콘 자리 가운데에 (15 — 이름과 틈이 남게). 색·모양은 태그 배지와 같게
                .overlay {
                    if quickSelect.visible, let number {
                        Text(verbatim: "\(number)")
                            .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Palette.plainBadgeTextLight)
                            .frame(width: 15, height: 15)
                            .background(Palette.plainBadgeLight, in: RoundedRectangle(cornerRadius: 4))
                            .fixedSize()
                            .accessibilityHidden(true)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(server.key).fontWeight(.medium)
                    TagBadges(tags: server.tags)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if model.tabs.contains(where: { $0.owner == server.key }) {
                Image(systemName: "terminal.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("열린 터미널 탭")
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts = [server.ip]
        if let role = server.role { parts.append(role) }
        return parts.joined(separator: " · ")
    }

}

struct ServerContextMenu: View {
    @Environment(AppModel.self) private var model
    let server: Server

    var body: some View {
        let reachable = model.isReachable(server)
        if server.extraUsers.isEmpty {
            Button("SSH") { model.openSSH(server) }.disabled(!reachable)
        } else {
            // 고른 계정을 바꾸지 않고 그 계정으로 바로 연다
            Menu("SSH") {
                ForEach(server.accounts, id: \.self) { name in
                    Button(name) { model.openSSH(server.account(name)) }
                }
            }
            .disabled(!reachable)
        }
        Button("Tunnel…") { model.promptTunnel(server) }.disabled(!reachable)
        if let settings = model.config?.settings(for: server.group), settings.dbJump == server.key {
            Button("DB Tunnel") { model.promptDBTunnel(server) }.disabled(!reachable)
        }
        Button("Upload…") { model.chooseUpload(server) }.disabled(!reachable)
        Button("Download…") { model.promptDownload(server) }.disabled(!reachable)
        // Spec·Services·Ports·실시간은 정보 화면 탭에만 둔다
        if model.wakeVia(server) != nil || server.type == .windows { Divider() }
        if let via = model.wakeVia(server) {
            Button("Boot via \(via.key)") { model.wake(server) }.disabled(!model.canWake(server))
        }
        if server.type == .windows {
            Button("Shutdown…") { model.shutdown(server) }.disabled(!model.canShutdown(server))
        }
        Divider()
        Button("주소 복사") { model.copy(server.target) }
        // 소켓이 있을 때만 — 메뉴를 열 때 파일 유무만 본다
        Button("공유 연결 끊기") { model.stopSharedConnections(server) }
            .disabled(!model.hasSharedConnection(server))
        Button("서버 편집…") { model.editServer(server) }
        Button("액션 편집…") { model.editActions(server) }
        Button("위로 이동") { model.moveServer(server, .up) }.disabled(!model.canMoveServer(server, .up))
        Button("아래로 이동") { model.moveServer(server, .down) }.disabled(!model.canMoveServer(server, .down))
        let mergeTargets = model.accountMergeTargets(server)
        if !mergeTargets.isEmpty {
            // 같은 장비를 계정별로 두 항목에 등록해 둔 경우에만 보인다
            Menu("계정으로 합치기") {
                ForEach(mergeTargets) { target in
                    Button("\(target.key) 에 합치기…") { model.confirmMergeAccount(server, into: target) }
                }
            }
        }
        Button("목록에서 제거…") { model.confirmRemoveServer(server) }.disabled(!model.canRemoveServer(server))
    }
}

/// 서버가 없을 때 서버 행 자리에 놓는 추가 행 (점선 테두리 — 비어 있는 자리). 첫 서버가 생기면 그룹 머리의 + 가 대신한다.
struct AddFirstServerRow: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Button { model.promptAddServer(group: "") } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: Metrics.sidebarIcon, height: 16)
                Text("서버 추가").fontWeight(.medium)
                Spacer()
            }
            .foregroundStyle(.primary.opacity(hovering ? 1 : 0.8))
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(hovering ? 0.4 : 0.22), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .padding(.horizontal, 10)
        )
        .accessibilityLabel("서버 추가")
    }
}
