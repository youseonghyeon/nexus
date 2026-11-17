// 앱 안 브라우저 탭: [Browser] → 그 서버로 SOCKS 터널(없으면 열기) → 탭 추가 → 터널이 열리면 시작 주소 로드.
// 탭은 그 서버에서 브라우저를 켠 것처럼 동작한다 — 모든 요청이 그 서버로 가고 막는 주소는 없다 (BrowserPolicy).

import Foundation
import ServersCore

extension AppModel {
    /// 시작 주소의 근거: 그 서버에 열어 둔 첫 활성 포트 터널 (대시보드 터널 카드 순서 = sortedTunnels). proxy·DB 터널은 웹 주소가 아니라 건너뛴다.
    private func firstPortTunnel(for server: Server) -> TunnelSession? {
        sortedTunnels.first { $0.server.key == server.key && $0.isActive && { if case .port = $0.spec.kind { return true } else { return false } }($0) }
    }

    func openBrowser(_ server: Server) {
        let socks: TunnelSession
        if let existing = activeSocksTunnel(server) {
            socks = existing
        } else {
            guard let started = startTunnel(server: server, kind: .socks, preferredLocalPort: server.proxyPort ?? 1080) else { return }
            started.openedByBrowser = true   // 브라우저 탭이 다 닫히면 함께 내린다 — [Chrome] 이 먼저 연 터널은 건드리지 않는다
            socks = started
        }
        let startURL = BrowserPolicy.startURL(firstTunnel: firstPortTunnel(for: server)?.spec)   // 없으면 빈 탭
        let browser = BrowserSession(server: server, socksPort: socks.spec.localPort, onStatus: { [weak self] in self?.statusMessage = $0 })
        add(TerminalTab(server: server, browser: browser))
        Task {
            guard await waitTunnelOpen(socks) else {
                browser.fail("프록시 터널이 열리지 않았습니다 · Tunnels 에서 \(socks.title) 터널을 확인하세요")
                return
            }
            browser.start(url: startURL)
        }
    }

    /// 그 서버의 브라우저 탭이 0개가 되면 브라우저가 직접 연 proxy(SOCKS) 터널(openedByBrowser)을 끊고 목록에서도 지운다 — 브라우저와 함께 사라진다.
    /// [Chrome] 이 열었거나 같이 쓰는 터널은 그대로 둔다 (AppModel+Proxy — Chrome 을 닫아도 유지).
    func stopProxyTunnelIfUnused(_ server: Server) {
        guard !tabs.contains(where: { $0.owner == server.key && $0.browser != nil }) else { return }
        for session in tunnels where session.server.key == server.key && session.spec.kind == .socks && session.openedByBrowser {
            session.stopReason = "브라우저 닫음"
            removeTunnel(session.id)
        }
    }
}
