// 메뉴바(Server·Network) 메뉴 항목. 툴바에는 서버 액션 버튼을 두지 않는다 — 같은 기능이 서버 정보 화면·사이드바 우클릭·메뉴바에 있어 뺐다.

import ServersCore
import SwiftUI

/// Server 메뉴(메뉴바)와 사이드바 우클릭이 공유하는 항목.
struct ServerActionsMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // 서버가 없어도(그룹 머리의 + 가 없음) 늘 추가할 수 있게. 서버를 고른 채면 그 그룹을 채운다
        Button("서버 추가…") { model.promptAddServer(group: model.selectedServer?.group ?? "") }
            .disabled(model.config == nil)
        // 서버 목록 주고받기 (비밀번호는 servers.conf 에 없다) — 가져오기는 이름이 같은 서버를 건너뛴다
        Button("서버 가져오기…") { model.importServers() }.disabled(model.config == nil)
        Button("서버 내보내기…") { model.exportServers() }.disabled(model.config == nil)
        Divider()
        if let server = model.selectedServer {
            let reachable = model.isReachable(server)
            if model.status.remote(server.key).needsAuth {
                Button("Tailscale 로그인") { model.tailscaleLogin(server) }.disabled(model.busyAction != nil)
            }
            Button("SSH") { model.openSSH(server) }.disabled(!reachable)
            Button("Tunnel…") { model.promptTunnel(server) }.disabled(!reachable)
            if let settings = model.config?.settings(for: server.group), settings.dbJump == server.key {
                Button("DB Tunnel") { model.promptDBTunnel(server) }.disabled(!reachable)
            }
            ForEach(server.tunnelPorts, id: \.self) { quick in
                Button("\(quick.label)…") { model.promptTunnelToPort(server, port: quick.port) }.disabled(!reachable)
            }
            if server.type == .windows, model.moonlightInstalled {
                Button("Moonlight") { model.openMoonlight() }.disabled(!reachable)
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
            Button("서버 편집…") { model.editServer(server) }
            Button("액션 편집…") { model.editActions(server) }
            Button("위로 이동") { model.moveServer(server, .up) }.disabled(!model.canMoveServer(server, .up))
            Button("아래로 이동") { model.moveServer(server, .down) }.disabled(!model.canMoveServer(server, .down))
            Button("목록에서 제거…") { model.confirmRemoveServer(server) }.disabled(!model.canRemoveServer(server))
        } else {
            Text("서버를 선택하세요")
        }
    }
}

/// 망 제어 메뉴. 서버 액션과 분리되어 있다.
struct NetworkMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // 사이드바 Network · 메뉴바 패널과 같은 망·같은 조건 (menuBarSwitches) — 설치하지 않은 Tailscale, 설정에 없는 내부망은 나오지 않는다
        ForEach(model.menuBarSwitches, id: \.kind) { row in
            switch row.kind {
            case .wifi: Button(row.menuTitle(name: "Wi-Fi")) { model.toggleWiFi() }.disabled(!row.isEnabled)
            case .tailscale: Button(row.menuTitle(name: model.networkName(.tailscale))) { model.toggleTailscale() }.disabled(!row.isEnabled)
            case .lan: Button(row.menuTitle(name: model.networkName(.lan))) { model.toggleLan() }.disabled(!row.isEnabled)
            }
        }
        // 시스템 설정의 VPN (구성은 각 VPN 앱에서 — 여기선 켜기·끄기만)
        if let vpns = model.vpns, !vpns.isEmpty {
            Divider()
            ForEach(vpns) { vpn in
                Button("\(vpn.name) \(vpn.isOn ? "끄기" : "켜기")") { model.toggleVPN(vpn) }
                    .disabled(!vpn.canToggle || model.vpnBusy.contains(vpn.id))
            }
        }
    }
}
