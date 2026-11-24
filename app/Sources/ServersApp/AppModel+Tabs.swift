// 터미널 탭: 열기(SSH·로컬 셸)·보이기·닫기·소유자별 목록.

import Foundation
import ServersCore

extension AppModel {
    // MARK: 탭

    var tabRefs: [TabRef<UUID>] { tabs.map { TabRef(id: $0.id, owner: $0.owner) } }

    func add(_ tab: TerminalTab) {
        tab.onClosed = { [weak self] closed in self?.closeTab(closed.id) }
        // 끌어 놓기는 보이는 탭만 (TerminalDropView — 가려진 탭에 들어가지 않게)
        tab.canDropFiles = { [weak self] tab in self?.visibleTab === tab }
        tab.onDropFiles = { [weak self] tab, urls in self?.dropIntoTerminal(tab, urls: urls) ?? false }
        tabs.append(tab)
        selectedKey = tab.owner
        showTab(tab.id)
    }

    /// 탭을 앞으로: Dashboard 를 보고 있었으면 해제한다. 그 소유자가 마지막으로 본 탭으로 기억해 둔다.
    func showTab(_ id: UUID) {
        if let owner = tabs.first(where: { $0.id == id })?.owner { activeTabByOwner[owner] = id }
        dashboardOwner = nil
    }

    func showDashboard() {
        dashboardOwner = selectedKey
    }

    /// ⌘⇧[ / ⌘⇧] (TerminalShortcuts): 지금 보는 서버의 탭 막대에서 한 칸 옆으로 (Dashboard 포함, 양 끝에서 돈다).
    func stepTab(forward: Bool) {
        guard let owner = selectedKey else { return }
        switch TabSelection.step(from: visibleTab?.id, owner: owner, forward: forward, in: tabRefs) {
        case .dashboard: showDashboard()
        case .tab(let id): showTab(id)
        case .stay: break
        }
    }

    @discardableResult
    func openSSH(_ server: Server) -> TerminalTab? {
        guard let config, !vpnBindMissing(server) else { return nil }
        // 세션 비밀번호가 있으면 터미널 프롬프트 대신 헬퍼가 대입한다. 없으면 평소처럼 터미널에서 묻는다.
        let tab = TerminalTab(server: server, title: server.accountTitle,
                              command: SessionCommand.ssh(to: server, config: config, bindInterface: bindInterface(for: server)),
                              palette: terminalTheme(for: server.key)?.palette,
                              envVars: askPassEnvironment(for: server, title: "\(server.key) · \(server.target)") ?? [:])
        add(tab)
        return tab
    }

    /// 로컬 셸 탭. command 를 주면 사용자의 로그인·대화형 셸로 실행한다 (zsh 함수·alias 도 된다).
    /// libghostty 는 command 를 `exec -l <command>` 로 실행하므로 명령줄은 셸 -lic 로 감싼다.
    func openLocalShell(command: String? = nil, title: String = "local") {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let wrapped = command.map { "\(shellQuote(shell)) -lic \(shellQuote($0))" }
        add(TerminalTab(server: nil, title: title, command: wrapped, palette: nil))   // 로컬 셸은 터미널 기본색 (테마는 서버별)
    }

    // MARK: 서버별 터미널 테마 (ServerTerminalTheme)

    /// 그 서버에서 고른 테마 (고르지 않았으면 nil — 터미널 기본색)
    func terminalTheme(for serverKey: String) -> ServerTerminalTheme? {
        ServerTerminalTheme.find(terminalThemes[serverKey])
    }

    /// 테마를 고른다 (nil 이면 푼다). 그 서버의 열린 터미널 탭에도 바로.
    func setTerminalTheme(_ id: String?, for server: Server) {
        saveTerminalThemes(ServerTerminalTheme.setting(id, for: server.key, in: terminalThemes))
        for tab in tabs where tab.server?.key == server.key { tab.applyPalette(terminalTheme(for: server.key)?.palette) }
    }

    func saveTerminalThemes(_ next: [String: String]) {
        guard next != terminalThemes else { return }
        terminalThemes = next
        UserDefaults.standard.set(next, forKey: AppPreferences.terminalThemesKey)
    }


    /// `--run <명령>` 으로 실행되면 시작 시 로컬 탭에서 그 명령을 연다 (한 번만).
    func openLaunchCommandIfAny() {
        guard !launchCommandOpened else { return }
        launchCommandOpened = true
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--run"), args.indices.contains(i + 1) else { return }
        openLocalShell(command: args[i + 1], title: args[i + 1])
    }

    func closeTab(_ id: UUID) {
        guard let closing = tabs.first(where: { $0.id == id }) else { return }
        let next = TabSelection.nextActive(after: id, in: tabRefs)
        tabs.removeAll { $0.id == id }
        if activeTabByOwner[closing.owner] == id { activeTabByOwner[closing.owner] = next }
        // 브라우저 탭이면 중계를 내리고, 그 서버의 브라우저 탭이 더 없으면 브라우저만 쓰던 proxy(SOCKS) 터널도 끊는다
        if let browser = closing.browser {
            browser.close()
            if let server = closing.server {
                for tab in tabs where tab.owner == server.key { tab.browser?.reapplyProxy() }
                stopProxyTunnelIfUnused(server)
            }
        }
    }

    /// ⌘W: 보이는 탭(그 셸·브라우저)만 닫는다. Dashboard 를 보고 있으면 false.
    func closeVisibleTab() -> Bool {
        guard let id = visibleTab?.id else { return false }
        closeTab(id)
        return true
    }

    // MARK: 터미널 안 찾기 (TerminalFind)

    /// ⌘F · ⌘G · ⌘⇧G. 받았으면 true (보이는 탭이 터미널이 아니면 false — 키를 흘린다).
    func handleFindKey(_ key: TerminalFind.Key) -> Bool {
        let tab = visibleTab.flatMap { $0.terminal != nil && $0.isAlive ? $0 : nil }
        guard let command = TerminalFind.command(for: key, terminalVisible: tab != nil, finding: tab?.finding ?? false), let tab else { return false }
        switch command {
        case .open:
            tab.finding = true
            tab.findFocusRequest += 1
            // 닫았다 다시 열면 지난 글자가 남아 있다 — 그 글자로 다시 찾는다
            if !tab.findText.isEmpty { tab.terminal?.performBindingAction(TerminalFind.searchAction(tab.findText)) }
        case .next: stepFind(tab, forward: true)
        case .previous: stepFind(tab, forward: false)
        }
        return true
    }

    /// 찾는 글자가 바뀌었다 (찾기 칸)
    func updateFind(_ tab: TerminalTab, text: String) {
        tab.findText = text
        tab.terminal?.performBindingAction(TerminalFind.searchAction(text))
    }

    func stepFind(_ tab: TerminalTab, forward: Bool) {
        guard !tab.findText.isEmpty else { return }
        tab.terminal?.performBindingAction(forward ? TerminalFind.nextAction : TerminalFind.previousAction)
    }

    /// 찾기 칸을 닫는다: 강조를 지우고 키 입력을 터미널로 돌려준다 (글자는 남겨 둔다)
    func closeFind(_ tab: TerminalTab) {
        tab.finding = false
        tab.terminal?.performBindingAction(TerminalFind.endAction)
        tab.terminal?.requestFocus()
    }

    /// 드래그 순서 변경: moving 을 같은 소유자 탭들 안 index 번째로. Dashboard 는 배열 밖이라 항상 맨 앞.
    func moveTab(_ moving: UUID, to index: Int) {
        let order = TabSelection.move(moving, to: index, in: tabRefs).map(\.id)
        guard order != tabs.map(\.id) else { return }
        let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        tabs = order.compactMap { byID[$0] }
    }

    func tabs(for owner: String) -> [TerminalTab] { tabs.filter { $0.owner == owner } }
    var tabsForSelected: [TerminalTab] { tabs(for: selectedKey ?? "") }
    var localTabs: [TerminalTab] { tabs(for: AppModel.localKey) }

    /// 화면에 보이는 탭: 선택한 소유자가 마지막에 본 탭 (없으면 그 소유자의 마지막 탭). Dashboard 를 보고 있으면 nil.
    var visibleTab: TerminalTab? {
        guard dashboardOwner != selectedKey else { return nil }
        guard let id = TabSelection.activeTab(of: selectedKey ?? "", remembered: activeTabByOwner, in: tabRefs) else { return nil }
        return tabs.first(where: { $0.id == id })
    }
}
