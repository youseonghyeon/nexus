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
        Button(model.tailscaleRunning ? "Tailscale 끄기…" : "Tailscale 켜기") { model.toggleTailscale() }
            .disabled(!model.canToggleTailscale)
        if model.config?.lan != nil {
            Button(model.status.lan == .up ? "\(model.networkName(.lan)) 끄기…" : "\(model.networkName(.lan)) 켜기") { model.toggleLan() }
                .disabled(!model.canToggleLan)
        }
        Divider()
        Button("지금 확인") { model.requestRefresh() }
    }
}
