// 원격 실행: Moonlight 열기·비밀번호 팝업(servers-askpass)·원격 명령(runRemote)·공유 연결 끊기·원격 정보 조회(spec/services/ports)·Wake/Shutdown·Tailscale 로그인.
// 비밀번호·계정·키 파일은 AppModel+Credentials.

import AppKit
import Foundation
import ServersCore

extension AppModel {
    // MARK: 액션 (메뉴 막대의 서버 메뉴·우클릭·정보 화면이 같은 규칙)

    static let moonlightBundleID = "com.moonlight-stream.Moonlight"

    /// Moonlight 앱을 연다(이미 떠 있으면 앞으로). 스트리밍 시작은 Moonlight 안에서 고른다 — `stream` 인자로 바로 시작하면 곧장 전체화면이 뜬다.
    func openMoonlight() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.moonlightBundleID) else {
            statusMessage = "Moonlight 가 설치돼 있지 않습니다."
            return
        }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.statusMessage = "Moonlight 실행 실패: \(error.localizedDescription)" }
        }
    }

    /// 비밀번호 팝업 헬퍼(servers-askpass) 경로. 번들 Contents/MacOS 에 있고, 개발 중(swift run)에는 빌드 산출물을 쓴다.
    var askPassHelper: String? {
        let candidates: [String?] = [
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("servers-askpass").path,
            (configPath as NSString).deletingLastPathComponent + "/app/.build/debug/servers-askpass",
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 헬퍼 환경변수. 세션 비밀번호가 있으면 함께 넘긴다. always=false 면 비밀번호가 없을 때 nil (터미널 프롬프트 유지).
    func askPassEnvironment(for server: Server, title: String, always: Bool = false) -> [String: String]? {
        guard let helper = askPassHelper else { return nil }
        let password = passwords[credentialKey(server)]
        guard always || password != nil else { return nil }
        return AskPass.environment(helper: helper, title: title, password: password)
    }

    /// 원격 실행. 먼저 공유 연결·키 인증으로 조용히 시도하고(BatchMode), 인증이 필요하면(255)
    /// 비밀번호 팝업(SSH_ASKPASS)으로 한 번 더 시도한다. 취소하면 실패로 끝난다.
    /// 세션 비밀번호가 있으면 조용한 시도를 건너뛰고 바로 대입한다. 팝업 불가(allowPrompt=false)면 한 번만 시도해 틀려도 창이 안 뜬다.
    func runRemote(_ server: Server, command: String, stdin: String? = nil, timeout: TimeInterval = 20, allowPrompt: Bool = true) async -> CommandResult {
        // vpn 서버인데 묶을 utun 이 없으면 보내지 않는다 (창 없는 호출이 많아 상태줄 문구 없이 실패로)
        if status.lacksVPNBind(server) { return CommandResult(exitCode: 255, stderr: "VPN 이 연결돼 있지 않습니다") }
        let base = ConnectPolicy.sharedArguments(port: server.port, bindInterface: bindInterface(for: server), identity: server.identityFile)
        if hasPassword(server), let environment = askPassEnvironment(for: server, title: "\(server.key) · \(server.target)") {
            // 창 없는 호출: 처음 보는 호스트 키면 askpass 가 yes/no 창을 띄우고 시간 초과 뒤 창만 남는다 — 확인 없이 실패하게
            let attempts = allowPrompt ? AskPass.options : AskPass.singleAttempt + ["-o", "StrictHostKeyChecking=yes"]
            return await runner.run("ssh", base + attempts + [server.target, command], stdin: stdin, environment: environment,
                                    timeout: allowPrompt ? 180 : timeout)
        }
        let quiet = await runner.run("ssh", base + ["-o", "BatchMode=yes", server.target, command], stdin: stdin, timeout: timeout)
        // 255 라도 인증 문제일 때만 팝업으로 재시도한다. 망 불통·끊김이면 재시도해도 소용없고, 명령이 두 번 실행될 수 있다.
        guard allowPrompt, SSHOutcome(quiet) == .needsAuth, let helper = askPassHelper else { return quiet }
        return await runner.run("ssh", base + AskPass.options + [server.target, command], stdin: stdin,
                                environment: AskPass.environment(helper: helper, title: "\(server.key) · \(server.target)"),
                                timeout: 180)
    }

    /// 이 서버의 공유 연결 소켓이 남아 있는가 ([공유 연결 끊기] — 메뉴를 열 때 파일 유무만 본다)
    func hasSharedConnection(_ server: Server) -> Bool {
        !SharedConnection.activeAccounts(of: server).isEmpty
    }

    /// 남아 있는 공유 연결(ControlPersist)을 바로 내린다 — 다음 접속은 새로 인증한다. 소켓에 요청만 보내 망에 나가지 않는다.
    func stopSharedConnections(_ server: Server) {
        let accounts = SharedConnection.activeAccounts(of: server)
        guard !accounts.isEmpty else { return }
        Task {
            var failed: [String] = []
            for name in accounts {
                let result = await runner.run("ssh", SharedConnection.stopArguments(for: server.account(name)), timeout: 5)
                if !result.ok { failed.append("\(name): " + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            statusMessage = failed.isEmpty
                ? "\(server.key) 공유 연결을 끊었습니다 (\(accounts.joined(separator: ", ")))."
                : "\(server.key) 공유 연결을 끊지 못했습니다 — \(failed.joined(separator: " · "))"
        }
    }

    /// 실패 결과를 한 줄로 (문구는 ServersCore RemoteFailure)
    private func failureText(_ result: CommandResult, server: Server) -> String {
        RemoteFailure.text(result, serverKey: server.key)
    }

    func info(_ server: Server, _ query: RemoteCommands.Query) -> RemoteInfoResult {
        remoteInfo[server.key]?[query] ?? RemoteInfoResult()
    }

    /// 원격 정보 카드에서 탭을 고른다. 탭 전환은 보기일 뿐이라 아직 가져온 적 없는 탭만 조용히 가져온다 (선택 시 자동 spec 조회와 같은 규칙) —
    /// 인증이 필요하면 안내만 남고, 새로고침(↻)이 팝업을 띄운다
    func selectInfoTab(_ tab: RemoteCommands.Query, for server: Server) {
        infoTab[server.key] = tab
        if RemoteInfoTabs.fetchesOnSelect(tab, fetchedAt: info(server, tab).fetchedAt) { fetchInfo(server, tab, allowPrompt: false) }
    }

    /// 원격 정보 조회. allowPrompt=false 면 조용히만 시도하고(자동 조회용) 인증 필요 시 안내만 남긴다.
    func fetchInfo(_ server: Server, _ query: RemoteCommands.Query, allowPrompt: Bool) {
        // 실시간 탭은 한 번 가져오는 조회가 아니다 — 그 탭이 보이는 동안 ServerLiveMonitor 가 읽는다
        guard query.fetches, let q = RemoteCommands.query(query, for: server.type) else { return }
        if info(server, query).loading { return }
        remoteInfo[server.key, default: [:]][query, default: RemoteInfoResult()].loading = true
        Task {
            let result = await runRemote(server, command: q.command, stdin: q.stdin, allowPrompt: allowPrompt)
            // 조회 중에 servers.conf 가 바뀌어 같은 키가 다른 서버를 가리키면 결과를 버린다
            guard config?.server(server.key) == server else {
                // 그새 다른 계정을 골랐으면 그쪽 조회의 표시를 끄지 않는다 (꺼지면 로그인을 한 번 더 시도한다)
                if config?.server(server.key)?.accountID == server.accountID { remoteInfo[server.key]?[query]?.loading = false }
                return
            }
            var entry = info(server, query)
            entry.loading = false
            if result.ok {
                let lines = RemoteCommands.outputLines(result.stdout, type: server.type)
                entry.lines = lines
                entry.parsed = ParsedRemoteInfo.parse(query, lines: lines, type: server.type)
                entry.fetchedAt = Date()
                entry.error = nil
                recordHistory(server, entry.parsed)   // 지난번과 달라진 것을 변경 이력에 (ServerHistory)
            } else {
                entry.error = RemoteFailure.infoError(result, serverKey: server.key, type: server.type, allowPrompt: allowPrompt)
            }
            remoteInfo[server.key, default: [:]][query] = entry
            if query == .ports { refreshBrowserStartPages(server.key) }   // 브라우저 시작 페이지의 포트 목록
        }
    }

    /// Services 탭에서 서비스 줄을 누르면: 최근 로그 50줄을 결과 창으로 (리눅스 journalctl, ServiceLog · OpenWrt logread)
    func showServiceLog(_ server: Server, unit: String) {
        let key = "\(server.key)|\(unit)"
        let command: String?
        switch server.type {
        case .linux: command = ServiceLog.command(unit: unit)
        case .openwrt: command = OpenWrt.serviceLogCommand(name: unit)
        case .windows: command = nil
        }
        guard let command else { return }
        showRecentLog(server, key: key, name: unit, command: command, stripANSI: false)
    }

    /// Services 탭에서 docker 컨테이너 줄을 누르면: 최근 로그 50줄을 결과 창으로 (리눅스만 — ServiceLog.dockerCommand)
    func showContainerLog(_ server: Server, container: String) {
        let key = "\(server.key)|docker|\(container)"
        guard server.type == .linux, let command = ServiceLog.dockerCommand(container: container) else { return }
        // 명령이 stderr 를 stdout 에 섞으므로(2>&1) 실패해도 stdout 에 이유가 있다. stderr 는 ssh 자체 오류
        showRecentLog(server, key: key, name: container, command: command, stripANSI: true)
    }

    /// 서비스 · 컨테이너의 최근 로그를 결과 창으로 (두 곳 공통 틀): 같은 것을 가져오는 중이면 건너뛰고, 안내 → 실행 → 안내 지우기 → 창.
    /// 줄 · 빈 결과 문구는 ServiceLog.displayLines
    private func showRecentLog(_ server: Server, key: String, name: String, command: String, stripANSI: Bool) {
        guard !serviceLogLoading.contains(key) else { return }
        serviceLogLoading.insert(key)
        statusMessage = "\(server.key) · \(name) 로그를 가져옵니다…"
        Task {
            let result = await runRemote(server, command: command, allowPrompt: true)
            serviceLogLoading.remove(key)
            if statusMessage?.hasSuffix("로그를 가져옵니다…") == true { statusMessage = nil }
            queryResult = QueryResult(title: "\(server.key) · \(name) 최근 로그", lines: ServiceLog.displayLines(result, stripANSI: stripANSI), failed: !result.ok, startsAtEnd: result.ok)
        }
    }

    /// 관리자 스크립트 하나를 잠금(busyAction) 안에서: 잠금 → 실행(Touch ID · 승인 창은 이때 뜬다) → 해제. 결과는 PrivilegedOutcome 으로 가른다.
    /// 다른 작업 중인지(busyAction == nil)는 부르는 쪽이 먼저 본다 — 못 했을 때의 문구 · 뒤처리가 곳마다 다르다.
    /// 잠금을 미리 잡거나(setServiceEnabled) 잠그지 않는 곳(Wi-Fi 상세 · ARP)은 이 틀을 쓰지 않는다
    func runPrivileged(_ script: String, busy: BusyAction) async -> CommandResult {
        busyAction = busy
        let result = await LanCommands.runPrivileged(script, runner: runner)
        busyAction = nil
        return result
    }

    /// Services 탭에서 k3s 파드 줄을 누르면: 왜 그 상태인지(컨테이너 상태 · 직전 종료 · 배치 실패 · 최근 이벤트)와 최근 로그를 결과 창으로 (리눅스만 — PodInspect).
    /// name 은 목록의 "네임스페이스/파드".
    func showPodLog(_ server: Server, name: String) {
        let parts = name.split(separator: "/", maxSplits: 1).map(String.init)
        let key = "\(server.key)|pod|\(name)"
        guard server.type == .linux, parts.count == 2, let script = PodInspect.script(namespace: parts[0], pod: parts[1]),
              !serviceLogLoading.contains(key) else { return }
        serviceLogLoading.insert(key)
        statusMessage = "\(server.key) · \(parts[1]) 상태 · 로그를 가져옵니다…"
        Task {
            // sh 의 stdin 으로 — 서버의 로그인 셸(zsh 등)에 그대로 넘기면 스크립트가 깨진다 (PodInspect 머리 주석)
            let result = await runRemote(server, command: "sh -s", stdin: script, allowPrompt: true)
            serviceLogLoading.remove(key)
            if statusMessage?.hasSuffix("로그를 가져옵니다…") == true { statusMessage = nil }
            let lines = RemoteCommands.cleanOutput(ServiceLog.stripANSI(result.stdout), type: .linux)
            let report = result.ok ? PodInspect.parse(lines) : nil
            // 접속 실패 · 인증 취소면 구역이 없다 — "로그 없음" 이 아니라 실패로
            let shown = report.map(PodInspect.displayLines) ?? ["상태 · 로그를 가져오지 못했습니다 (exit \(result.exitCode))"]
            queryResult = QueryResult(title: "\(server.key) · \(parts[1])", lines: shown, failed: report == nil || report?.failure != nil)
        }
    }

    /// 선택한 서버가 닿으면 Spec 을 한 번 자동으로 가져온다 (조용히, 팝업 없음).
    func autoFetchSpecIfNeeded() {
        guard let server = selectedServer, status.remote(server.key).isReachable, server.autoFetches(hasPassword: hasPassword(server)) else { return }
        let query: RemoteCommands.Query
        // 보고 있는 탭을 — 계정을 바꾸면 그 탭이 비어 있다. Live 는 수집기가 따로 읽는다
        if let tab = infoTab[server.key], tab.fetches, RemoteCommands.query(tab, for: server.type) != nil {
            query = tab
        } else {
            query = RemoteCommands.query(.spec, for: server.type) != nil ? .spec : .services
        }
        let entry = info(server, query)
        guard entry.fetchedAt == nil, entry.error == nil, !entry.loading else { return }
        fetchInfo(server, query, allowPrompt: false)
    }

    func wake(_ server: Server) {
        guard let mac = server.wolMac, let route = wakeRoute(server), let via = wakeVia(server) else {
            statusMessage = "\(server.key) 에는 wol_mac/wol_via 가 없습니다."
            return
        }
        guard busyAction == nil else { return }
        busyAction = BusyAction("wake \(server.key)")
        Task {
            let result = await runRemote(via, command: RemoteCommands.wakeOnLan(mac: mac, iface: route.iface))
            busyAction = nil
            if result.ok {
                statusMessage = "\(server.key) 부팅 요청을 \(via.key) 에서 보냈습니다."
                startPowerPending(server.key, .boot)
            } else if [.needsAuth, .unreachable, .cancelled].contains(SSHOutcome(result)) {
                statusMessage = failureText(result, server: via)
            } else {
                queryResult = QueryResult(title: "wake \(server.key) · error", lines: RemoteCommands.cleanOutput(result.stdout + result.stderr, type: .linux), failed: true)
            }
            requestRefresh()
        }
    }

    /// Tailscale SSH check 인증이 필요한 서버 중 첫 번째 (Dashboard 의 [Tailscale 로그인] 대상)
    var tailscaleAuthNeededServer: Server? {
        config?.servers.first { $0.network == .tailscale && status.remote($0.key).needsAuth }
    }

    /// Tailscale SSH check 인증: ssh 를 하나 열어 배너의 로그인 URL 을 브라우저로 열고, 브라우저 확인이 끝나 그 ssh 가 성공할 때까지
    /// 연결을 쥔다 (URL 은 연결마다 새로 나오고 그 연결이 살아 있어야 확인이 완료된다). 끝나면 상태를 다시 확인해 12시간 동안 SSH 가 된다.
    func tailscaleLogin(_ server: Server) {
        guard tailscaleLoginProcess == nil, busyAction == nil else { return }
        let process = TunnelProcess()
        tailscaleLoginProcess = process
        busyAction = BusyAction("\(server.key) Tailscale 로그인")
        statusMessage = "\(server.key) 에 연결해 로그인 링크를 기다립니다…"
        let opened = OnceFlag()
        process.onOutputLine = { [weak self] line in
            guard let url = TailscaleCheck.url(in: line).flatMap(URL.init(string:)), opened.claim() else { return }
            Task { @MainActor in
                NSWorkspace.shared.open(url)
                self?.statusMessage = "브라우저에서 Tailscale 인증을 마치면 자동으로 이어집니다."
            }
        }
        process.onExit = { [weak self] code, message in
            Task { @MainActor in
                guard let self else { return }
                self.tailscaleLoginProcess = nil
                self.busyAction = nil
                if code == 0 {
                    self.statusMessage = "Tailscale 인증 완료 · 12시간 동안 모든 Tailscale 서버에 SSH 가 됩니다."
                    self.clearAuthNeeded()
                    return
                } else if !opened.claimed {
                    self.statusMessage = "\(server.key): 로그인 링크를 받지 못했습니다 (exit \(code)) \(message.split(separator: "\n").last ?? "")"
                } else {
                    self.statusMessage = "\(server.key) Tailscale 인증이 끝나지 않았습니다 (exit \(code))."
                }
                self.requestRefresh()
            }
        }
        // 공유 연결을 쓰지 않는다: 새 연결이어야 배너가 오고, 확인이 끝난 뒤 공유 연결은 다음 상태 확인이 새로 만든다.
        let args = ConnectPolicy.sshOptions + ["-p", "\(server.port)"] + ConnectPolicy.noControlOptions + ["-o", "BatchMode=yes", server.account(server.primaryUser).target, "true"]   // 상태 확인과 같은 기본 계정
        do {
            try process.start(executable: "ssh", arguments: args, environment: [:], watchdog: false)
        } catch {
            tailscaleLoginProcess = nil
            busyAction = nil
            statusMessage = "ssh 실행 실패: \(error.localizedDescription)"
            return
        }
        // 5분 안에 인증이 안 끝나면 정리
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            if self?.tailscaleLoginProcess === process { process.stop() }
        }
    }

    func shutdown(_ server: Server) {
        guard server.type == .windows else {
            statusMessage = "windows 서버가 아니면 shutdown 을 할 수 없습니다."
            return
        }
        pendingConfirm = PendingConfirm(
            title: "\(server.key) 종료",
            message: "\(server.key) 서버를 지금 종료합니다. 저장하지 않은 작업이 있으면 사라집니다.") { [weak self] in
            guard let self else { return }
            // 확인 창이 떠 있는 사이 다른 작업이 시작됐으면 그 잠금을 덮지 않는다
            guard busyAction == nil else {
                statusMessage = "다른 작업 중이라 \(server.key) 종료 요청을 보내지 못했습니다."
                return
            }
            busyAction = BusyAction("shutdown \(server.key)")
            Task {
                let result = await self.runRemote(server, command: RemoteCommands.windowsShutdown)
                self.busyAction = nil
                self.statusMessage = result.ok ? "\(server.key) 종료 요청을 보냈습니다." : "\(server.key) 종료 요청: " + self.failureText(result, server: server)
                if result.ok { self.startPowerPending(server.key, .shutdown) }
                self.requestRefresh()
            }
        }
    }
}

/// 여러 스레드에서 오는 출력 줄 중 첫 번째만 처리하기 위한 표시
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var claimed: Bool { lock.withLock { flag } }
    /// 처음 호출에서만 true
    func claim() -> Bool { lock.withLock { if flag { return false }; flag = true; return true } }
}
