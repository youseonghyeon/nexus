// 앱 안 브라우저 탭: [Browser] → 그 서버로 SOCKS 터널(없으면 열기) → 탭 추가 → 터널이 열리면 시작 주소 로드.
// 범위(BrowserScope)는 그 서버 IP + 그 서버의 터널 루프백 이름·주소. 터널 목록이 바뀌면 열린 브라우저 탭에 다시 알려 준다.

import Foundation
import ServersCore

extension AppModel {
    /// 그 서버로의 브라우저 탭 허용 범위. 터널 이름 → 루프백 주소(jenkins.acme → 127.0.0.2)는 그 서버의 서버 이름 터널에서 온다.
    func browserScope(for server: Server) -> BrowserScope {
        var names: [String: String] = [:]
        for session in tunnels where session.server.key == server.key {
            if let name = session.spec.hostName, let address = session.spec.bindAddress { names[name] = address }
        }
        return BrowserScope(serverIP: server.ip, loopbackNameAddresses: names)
    }

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
        let browser = BrowserSession(server: server, socksPort: socks.spec.localPort,
                                     scope: { [weak self] in self?.browserScope(for: server) ?? BrowserScope(serverIP: server.ip) },
                                     onStatus: { [weak self] in self?.statusMessage = $0 })
        add(TerminalTab(server: server, browser: browser))
        Task {
            guard await waitTunnelOpen(socks) else {
                browser.fail("프록시 터널이 열리지 않았습니다 · Tunnels 에서 \(socks.title) 터널을 확인하세요")
                return
            }
            browser.start(url: startURL)
        }
    }

    /// 터널이 생기거나 없어졌을 때: 열린 브라우저 탭의 허용 범위(프록시 예외·차단 규칙)를 갱신한다.
    func refreshBrowserScopes() {
        for tab in tabs { tab.browser?.refreshScope() }
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
