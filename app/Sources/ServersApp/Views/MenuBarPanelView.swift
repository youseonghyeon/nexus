// 메뉴바 패널의 화면: Network(망 스위치 · 시스템 VPN) · Servers(상태 점, 누르면 본창의 그 서버) · Tunnels(끊기/다시 연결) · 아래 버튼 줄.
// 패널이 카드 한 장 — 본창과 같은 면·선·상태 점을 쓴다 (Theme). 값(MenuPanelContent)과 동작(MenuPanelActions)만 받아 그린다 — 모델을 모른다
// (스크래치에서 표본 값으로 비트맵을 뽑아 확인할 수 있게).

import SwiftUI

struct MenuPanelContent {
    /// 스위치 한 줄 (망 · VPN)
    struct Switch: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let tone: StatusTone
        let isOn: Bool
        let isEnabled: Bool
    }

    struct Server: Identifiable {
        let key: String
        let tone: StatusTone
        var id: String { key }
    }

    struct ServerGroup: Identifiable {
        let name: String
        let servers: [Server]
        var id: String { name }
    }

    struct Tunnel: Identifiable {
        let id: UUID
        let title: String
        let mapping: String
        let tone: StatusTone
        let isActive: Bool
        /// 닫힌 터널을 다시 열 수 있는가 (서버에 갈 수 있는 망 상태)
        let canReconnect: Bool
    }

    var networks: [Switch] = []
    var vpns: [Switch] = []
    var groups: [ServerGroup] = []
    var tunnels: [Tunnel] = []
}

struct MenuPanelActions {
    var toggleNetwork: (String) -> Void = { _ in }
    var toggleVPN: (String) -> Void = { _ in }
    var openServer: (String) -> Void = { _ in }
    var toggleTunnel: (UUID) -> Void = { _ in }
    var openWindow: () -> Void = {}
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}
}

struct MenuBarPanelView: View {
    static let width: CGFloat = 300
    /// 패널 가장자리 ~ 내용 (본창 카드 안 여백과 같다)
    static let inset = Metrics.cardPadding
    static let radius = Metrics.cardRadius

    let content: MenuPanelContent
    let actions: MenuPanelActions

    /// 패널 전체가 카드 한 장이다 — 구역은 상자로 다시 싸지 않고 머리카락 선으로만 가른다
    /// (상자 안에 상자를 두면 선이 두 겹으로 붙어 300 폭에서 답답했다, 2026-11-14 사용자 지적). 아래 버튼 줄은 대표 카드처럼 우묵한 띠.
    var body: some View {
        VStack(spacing: 0) {
            section("Network") {
                ForEach(content.networks) { row in
                    MenuPanelSwitchRow(row: row) { actions.toggleNetwork(row.id) }
                }
                ForEach(content.vpns) { row in
                    MenuPanelSwitchRow(row: row) { actions.toggleVPN(row.id) }
                }
            }
            if !content.groups.isEmpty {
                divider
                section("Servers") { servers }
            }
            if !content.tunnels.isEmpty {
                divider
                section("Tunnels") {
                    ForEach(content.tunnels) { tunnel in
                        HStack(spacing: 8) {
                            StatusDot(tone: tunnel.tone)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tunnel.title).fontWeight(.medium).lineLimit(1)
                                Text(tunnel.mapping).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Button(tunnel.isActive ? "끊기" : "다시 연결") { actions.toggleTunnel(tunnel.id) }
                                .buttonStyle(CompactButtonStyle())
                                .disabled(!tunnel.isActive && !tunnel.canReconnect)
                        }
                    }
                }
            }
            divider
            HStack(spacing: 8) {
                Button { actions.openWindow() } label: { Text("Open Nexus").frame(maxWidth: .infinity) }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Settings…") { actions.openSettings() }.buttonStyle(SecondaryButtonStyle())
                Button("Quit") { actions.quit() }.buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, Self.inset).padding(.vertical, 12)
            .background(Palette.well.opacity(0.6))
        }
        .font(.system(size: 13))
        .frame(width: Self.width)
    }

    private var divider: some View { Rectangle().fill(Palette.hairline).frame(height: 1) }

    private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.cardTitle).foregroundStyle(.secondary)
            rows()
        }
        .padding(.horizontal, Self.inset).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 서버는 라벨–값 격자: 왼쪽 그룹 이름, 오른쪽에 서버 칸이 흘러 줄바꿈된다
    /// (두 열 격자는 서버가 홀수인 그룹마다 오른쪽 절반이 비고, 그룹 이름 줄이 따로 높이를 먹었다).
    @ViewBuilder private var servers: some View {
        if content.groups.count == 1, let group = content.groups.first {
            serverFlow(group.servers)   // 그룹이 하나뿐이면 이름을 적지 않는다 (구역 제목으로 충분)
        } else {
            Grid(alignment: .topLeading, horizontalSpacing: Metrics.labelGap, verticalSpacing: 6) {
                ForEach(content.groups) { group in
                    GridRow {
                        Text(group.name).font(.fieldLabel).foregroundStyle(.secondary).lineLimit(1)
                            .padding(.top, 4)   // 서버 칸의 글자 줄에 맞춘다
                        serverFlow(group.servers)
                    }
                }
            }
        }
    }

    private func serverFlow(_ servers: [MenuPanelContent.Server]) -> some View {
        FlowLayout(spacing: 2, lineSpacing: 2) {
            ForEach(servers) { server in
                MenuPanelServerButton(server: server) { actions.openServer(server.key) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, -3)   // 마우스를 올린 면의 여백만큼 당겨 점이 줄 머리에 온다
    }
}

/// 상태 점 · 이름과 상태 단어 · 스위치 (사이드바 Network 행과 같은 모양)
private struct MenuPanelSwitchRow: View {
    let row: MenuPanelContent.Switch
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(tone: row.tone)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).fontWeight(.medium).lineLimit(1)
                Text(row.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .opacity(row.isEnabled ? 1 : 0.55)
            Spacer(minLength: 8)
            // 스위치는 모델 값을 그대로 따른다 — 누른다고 먼저 넘어가지 않고, 실제로 바뀌면 움직인다
            Toggle(row.title, isOn: Binding(get: { row.isOn }, set: { _ in toggle() }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!row.isEnabled)
        }
    }
}

/// 서버 한 칸: 상태 점 + 이름. 마우스를 올리면 올라온 면 (누르면 본창의 그 서버 화면).
private struct MenuPanelServerButton: View {
    let server: MenuPanelContent.Server
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 4) {
                StatusDot(tone: server.tone)
                Text(server.key).lineLimit(1)
            }
            .padding(.leading, 3).padding(.trailing, 8).padding(.vertical, 3)
            .background(hovering ? Palette.raised : .clear, in: RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous).strokeBorder(hovering ? Palette.hairline : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

extension View {
    /// 패널의 바깥 면: 카드 면 + 둥근 모서리 + 머리카락 선 (창 바탕은 투명 — 그림자는 이 모양을 따라 진다)
    func menuPanelChrome() -> some View {
        let shape = RoundedRectangle(cornerRadius: MenuBarPanelView.radius, style: .continuous)
        return background(Palette.card)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Palette.hairline))
            .tint(Palette.neutralTint)
    }
}
