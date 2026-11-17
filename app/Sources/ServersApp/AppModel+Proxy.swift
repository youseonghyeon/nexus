// Chrome 프록시 모드: 서버로 SOCKS 터널(ssh -D)을 열고 그 프록시를 쓰는 Chrome 을 별도 프로필로 띄운다.
// 대상은 servers.conf 에 proxy_port= 가 있는 서버만 (지금은 nexus). 터널은 TUNNELS 목록에 남아 거기서 끊는다 — Chrome 을 닫아도 유지.
// 앱 안 브라우저(AppModel+Browser)와 같은 터널을 나눠 쓴다. Chrome 이 쓰는 터널은 브라우저 탭을 닫아도 내리지 않는다 (openedByBrowser 를 푼다).

import AppKit
import Foundation
import ServersCore

extension AppModel {
    /// 이 서버로 열려 있는(연결 중 포함) SOCKS 터널
    func activeSocksTunnel(_ server: Server) -> TunnelSession? {
        tunnels.first { $0.isActive && $0.spec.server.key == server.key && $0.spec.kind == .socks }
    }

    /// [Chrome]: SOCKS 터널이 없으면 열고, 배너(열림)가 오면 Chrome 을 띄운다. 이미 있으면 그 터널로 창만 하나 더.
    func openChromeProxy(_ server: Server) {
        guard let port = server.proxyPort else { return }
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ChromeProxy.bundleID) else {
            statusMessage = "Chrome 이 설치돼 있지 않습니다."
            return
        }
        let session: TunnelSession
        if let existing = activeSocksTunnel(server) {
            existing.openedByBrowser = false   // 앱 안 브라우저가 연 터널이어도 이제 Chrome 이 쓴다 — 브라우저 탭을 닫아도 남긴다
            session = existing
        } else {
            guard let started = startTunnel(server: server, kind: .socks, preferredLocalPort: port) else { return }
            session = started
        }
        Task {
            guard await waitTunnelOpen(session) else {
                statusMessage = "프록시 터널이 열리지 않아 Chrome 을 띄우지 않았습니다."
                return
            }
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true   // 기본 Chrome 이 떠 있어도 프록시 인자가 먹게 새 인스턴스로
            config.arguments = ChromeProxy.arguments(proxyPort: session.spec.localPort, profileDir: ChromeProxy.profileDir(serverKey: server.key).path)
            NSWorkspace.shared.openApplication(at: chrome, configuration: config) { [weak self] _, error in
                guard let error else { return }
                Task { @MainActor in self?.statusMessage = "Chrome 실행 실패: \(error.localizedDescription)" }
            }
        }
    }
}
