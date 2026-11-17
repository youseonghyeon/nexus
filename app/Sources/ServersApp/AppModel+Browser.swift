// 앱 안 브라우저 탭: [Browser] → 그 서버로 SOCKS 터널(없으면 열기) → 탭 추가 → 터널이 열리면 시작 페이지(서버·열린 포트, BrowserStartPage).
// 탭은 그 서버에서 브라우저를 켠 것처럼 동작한다 — 모든 요청이 그 서버로 가고 막는 주소는 없다 (BrowserPolicy).

import Foundation
import ServersCore

extension AppModel {
    /// 시작 페이지의 포트 목록 상태 — 서버 화면 Ports 탭과 같은 값 (remoteInfo)
    private func browserPortsState(_ server: Server) -> BrowserStartPage.PortsState {
        let entry = info(server, .ports)
        if case let .ports(items) = entry.parsed, entry.fetchedAt != nil { return .loaded(items) }
        return entry.error != nil && !entry.loading ? .failed : .loading
    }

    /// 지금 설정의 그 서버 (탭을 연 계정 그대로) — 열어 둔 사이 서버를 편집했어도 새 값으로 그린다
    private func currentServer(_ server: Server) -> Server {
        config?.server(server.key)?.account(server.user) ?? server
    }

    /// 시작 페이지의 포트 부분 (포트 목록·웹 확인 결과가 올 때마다 이 부분만 갈아 끼운다)
    func browserStartPorts(for server: Server) -> String {
        let current = currentServer(server)
        return BrowserStartPage.portsHTML(named: current.tunnelPorts, state: browserPortsState(current),
                                          probes: browserProbes[current.key] ?? [:], probed: browserProbed.contains(current.key))
    }

    /// 시작 페이지 전체: 대표 카드(본창과 같은 상태 판정) + 주소칸 + 포트 부분
    func browserStartPage(for server: Server) -> String {
        let current = currentServer(server)
        let state = status.remote(current.key)
        let hero = BrowserStartPage.Hero(key: current.key, target: current.target, role: current.role, tags: ServerTags.parse(current.env),
                                         status: StatusText.conclusion(state, lanName: networkName(.lan)), level: StatusText.remoteLevel(state))
        return BrowserStartPage.html(hero: hero, portsHTML: browserStartPorts(for: server))
    }

    /// 포트 목록이 새로 왔다 — 그 서버의 시작 페이지를 보고 있는 탭의 포트 부분을 다시 그리고, 아직 안 물었으면 웹 확인을 시작한다
    func refreshBrowserStartPages(_ serverKey: String) {
        for tab in tabs where tab.owner == serverKey { tab.browser?.refreshStartPorts() }
        probeBrowserPorts(serverKey)
    }

    /// 웹 확인: 열린 포트 중 물어볼 것(WebProbe)에 그 서버의 브라우저 탭과 같은 길(중계 → ssh -D)로 HTTP 를 한 번씩. 서버당 한 번 — ↻ 가 다시 묻는다.
    func probeBrowserPorts(_ serverKey: String) {
        guard !browserProbed.contains(serverKey), !browserProbing.contains(serverKey),
              let browser = tabs.first(where: { $0.owner == serverKey && $0.browser?.probePort != nil })?.browser, let relayPort = browser.probePort else { return }
        let server = currentServer(browser.server)
        guard case let .loaded(ports) = browserPortsState(server) else { return }
        let targets = BrowserStartPage.probeTargets(named: server.tunnelPorts, ports: ports)
        browserProbing.insert(serverKey)
        Task {
            let found = await WebProbe.probeAll(targets, proxyPort: relayPort)
            browserProbing.remove(serverKey)
            browserProbes[serverKey] = found
            browserProbed.insert(serverKey)
            for tab in tabs where tab.owner == serverKey { tab.browser?.refreshStartPorts() }
        }
    }

    /// 시작 페이지의 ↻: 포트 목록을 다시 읽고(인증 창 허용) 웹 확인도 다시 한다
    func reloadBrowserStart(_ server: Server) {
        browserProbed.remove(server.key)
        browserProbes[server.key] = nil
        fetchInfo(currentServer(server), .ports, allowPrompt: true)
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
        let browser = BrowserSession(server: server, socksPort: socks.spec.localPort,
                                     startPage: { [weak self] in self?.browserStartPage(for: server) ?? "" },
                                     startPorts: { [weak self] in self?.browserStartPorts(for: server) ?? "" },
                                     onStartShown: { [weak self] in self?.probeBrowserPorts(server.key) },
                                     onStartReload: { [weak self] in self?.reloadBrowserStart(server) },
                                     onStatus: { [weak self] in self?.statusMessage = $0 })
        // 시작 페이지에 보일 열린 포트 — 아직 읽은 적 없으면 조용히 읽는다 (인증이 필요하면 안내만, ↻ 가 창을 띄운다)
        if info(server, .ports).fetchedAt == nil { fetchInfo(server, .ports, allowPrompt: false) }
        add(TerminalTab(server: server, browser: browser))
        Task {
            guard await waitTunnelOpen(socks) else {
                browser.fail("프록시 터널이 열리지 않았습니다 · Tunnels 에서 \(socks.title) 터널을 확인하세요")
                return
            }
            browser.start()
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
