// 터널(ssh -L): 목록 항목으로 관리한다. 열기·다시 연결·끊기·기록(recent.json).

import Foundation
import ServersCore

extension AppModel {
    // MARK: 터널 (목록 항목으로 관리, 터미널 아님)

    /// 다른 터널이 같은 바인딩 주소에서 쓰는 로컬 포트 (127.0.0.2 의 5432 와 127.0.0.3 의 5432 는 별개)
    private func takenLocalPorts(on address: String) -> Set<Int> {
        Set(tunnels.filter { $0.isActive && $0.spec.localBind == address }.map(\.spec.localPort))
    }
    private var takenLocalPorts: Set<Int> { takenLocalPorts(on: "127.0.0.1") }

    /// 서버 주소 터널의 이름·주소 미리보기 (입력창용, 배정은 열 때 확정)
    func namedTunnelPreview(_ server: Server, kind: TunnelKind) -> (name: String, address: String) {
        let key = HostAliasStore.assignmentKey(server: server, kind: kind)
        return (HostAliasStore.hostName(server: server, kind: kind), HostAliasStore.preview(key, in: hostAliases))
    }

    /// Tunnel… : 빈 입력창
    func promptTunnel(_ server: Server) {
        tunnelPrompt = TunnelPromptRequest(server: server, remotePort: nil, localPort: nil)
    }

    /// Ports 카드의 [터널]: 원격 포트를 채우고 로컬 포트를 제안한 입력창 (특권 포트는 +8000, 쓰이면 다음 빈 포트)
    func promptTunnelToPort(_ server: Server, port: Int, address: String = "*") {
        let local = PortAllocator.nextFree(preferred: port, taken: takenLocalPorts) ?? PortAllocator.suggestedLocalPort(forRemote: port)
        let host = TunnelTarget.fromListenAddress(address)
        tunnelPrompt = TunnelPromptRequest(server: server, remotePort: port, localPort: local, remoteHost: host)
    }

    func openTunnel(_ server: Server, remotePort: Int, localPort: Int, remoteHost: String = "127.0.0.1", named: Bool = false, name: String? = nil) {
        startTunnel(server: server, kind: .port(remotePort: remotePort, remoteHost: remoteHost), preferredLocalPort: localPort, named: named, name: name)
    }

    /// DB Tunnel: 원격(호스트·포트)은 servers.conf 값 그대로, 로컬 포트만 입력창에서 고르게 한다 (설정값이 쓰이는 중이면 다음 빈 포트를 미리 보여준다).
    func promptDBTunnel(_ server: Server) {
        guard let config, let settings = config.settings(for: server.group),
              settings.dbJump == server.key, let host = settings.dbHost, let port = settings.dbPort else {
            statusMessage = "\(server.key) 에는 DB 터널 설정이 없습니다."
            return
        }
        let preferred = settings.dbLocal ?? 15432
        let local = PortAllocator.nextFree(preferred: preferred, taken: takenLocalPorts) ?? preferred
        tunnelPrompt = TunnelPromptRequest(server: server, remotePort: port, localPort: local,
                                           dbTarget: (host: host, port: port, name: settings.dbName))
    }

    func openDBTunnel(_ server: Server, localPort: Int? = nil, named: Bool = false, name: String? = nil) {
        guard let config, let settings = config.settings(for: server.group),
              settings.dbJump == server.key, let host = settings.dbHost, let port = settings.dbPort else {
            statusMessage = "\(server.key) 에는 DB 터널 설정이 없습니다."
            return
        }
        startTunnel(server: server, kind: .db(host: host, port: port, name: settings.dbName),
                    preferredLocalPort: localPort ?? (named ? port : settings.dbLocal ?? 15432), named: named, name: name)
    }

    /// 같은 이름을 다른 주소로 쓰는 터널(닫힌 것 포함)이 있으면 그 이유. hosts 는 이름당 한 줄이라 덮어쓰면 그 터널의 이름이 다른 주소를 가리키게 된다.
    func namedTunnelConflict(name: String, address: String) -> String? {
        guard let other = tunnels.first(where: { $0.spec.hostName == name && $0.spec.bindAddress != address }) else { return nil }
        return "\(name) 이름은 이미 \(other.spec.server.key) 터널(\(other.spec.localBind))이 사용 중이라 고를 수 없습니다. 다른 이름을 고르거나 그 터널을 목록에서 지우세요."
    }

    /// 누를 때마다 새 터널. 로컬 포트가 다른 터널이나 다른 프로그램에 쓰이면 다음 빈 포트를 잡는다.
    /// named: 서버 주소로 — 서버별 고정 루프백 별칭(127.0.0.x)에 바인딩하고 hosts 이름을 붙인다 (로컬 포트 기본값은 원격과 같은 포트).
    /// name: 입력창에서 고른 hosts 이름. nil 이면 기본 이름(<서버키>.<그룹>). 주소는 이름과 무관하게 서버별로 같다.
    /// 별칭·hosts 줄이 아직 없으면 먼저 root 로 준비한다 (인증 한 번; 별칭은 재부팅 뒤 다시).
    /// 돌려주는 세션은 목록에 들어간 것 (연결 중). 못 열면 nil 이고 이유는 statusMessage.
    @discardableResult
    func startTunnel(server: Server, kind: TunnelKind, preferredLocalPort: Int, named: Bool = false, name: String? = nil) -> TunnelSession? {
        guard !vpnBindMissing(server) else { return nil }
        var bindAddress: String?, hostName: String?
        if named {
            let key = HostAliasStore.assignmentKey(server: server, kind: kind)
            let (address, state) = HostAliasStore.assign(key, in: hostAliases)
            let resolvedName = name ?? HostAliasStore.hostName(server: server, kind: kind)
            guard HostAliasStore.isValidHostName(resolvedName) else {
                statusMessage = "터널 이름으로 쓸 수 없습니다: \(resolvedName) · 영문·숫자·하이픈(-)·점(.)만 쓸 수 있습니다 (예: api.acme)."
                return nil
            }
            if let conflict = namedTunnelConflict(name: resolvedName, address: address) { statusMessage = conflict; return nil }
            if state != hostAliases {
                hostAliases = state
                do { try HostAliasStore.save(state) } catch { statusMessage = "주소 배정표 저장 실패: \(error.localizedDescription)"; return nil }
            }
            bindAddress = address
            hostName = resolvedName
        }
        let bind = bindAddress ?? "127.0.0.1"
        if PortAllocator.isPrivileged(preferredLocalPort) {
            statusMessage = "로컬 포트 \(preferredLocalPort) 는 관리자 권한이 필요합니다. \(PortAllocator.suggestedLocalPort(forRemote: preferredLocalPort)) 처럼 1024 이상을 지정하세요."
            return nil
        }
        guard let localPort = PortAllocator.nextFree(preferred: preferredLocalPort, taken: takenLocalPorts(on: bind), address: bind) else {
            statusMessage = "\(preferredLocalPort) 부터 빈 로컬 포트를 찾지 못했습니다."
            return nil
        }
        let spec = TunnelSpec(server: server, kind: kind, localPort: localPort, bindAddress: bindAddress, hostName: hostName,
                              bindInterface: bindInterface(for: server))
        let session = TunnelSession(spec: spec)
        let environment = askPassEnvironment(for: server, title: "\(server.key) · \(server.target) · 터널", always: true) ?? [:]
        let id = session.id
        session.process.onOutputLine = { [weak self] line in
            Task { @MainActor in
                guard let self, let s = self.tunnels.first(where: { $0.id == id }) else { return }
                if s.state == .connecting, line.hasPrefix("✔") { s.state = .open; self.tunnelStateChanged() }
            }
        }
        session.process.onExit = { [weak self] code, message in
            Task { @MainActor in
                guard let self, let s = self.tunnels.first(where: { $0.id == id }) else { return }
                // 사유·문구 갈래는 ServersCore TunnelExit
                let outcome = TunnelExit(stopRequested: s.process.stopRequested, stopReason: s.stopReason, exitCode: code, message: message,
                                         wasConnecting: s.state == .connecting)
                s.state = .closed(exitCode: code, message: outcome.reason)
                self.tunnelStateChanged()   // 활성/닫힘 정렬이 바뀐다
                if let notice = outcome.notice(title: s.title, stopReason: s.stopReason) { self.statusMessage = notice }
            }
        }
        // 같은 터널의 닫힌 항목(이전 실행·끊김)은 새 세션으로 바꾼다
        let record = RecentTunnel(serverKey: server.key, kind: kind, localPort: localPort, bindAddress: bindAddress, hostName: hostName, user: server.user)
        tunnels.removeAll { !$0.isActive && $0.matches(record) }
        tunnels.append(session)
        refreshBrowserScopes()
        if localPort != preferredLocalPort {
            statusMessage = "로컬 포트 \(preferredLocalPort) 는 사용 중이라 \(localPort) 로 열었습니다."
        }
        saveRecent(RecentStore.record(record, in: recent))
        Task {
            if let bindAddress, let hostName, !(await HostAliasCommands.isReady(name: hostName, address: bindAddress, runner: runner)) {
                // 다른 관리자·원격 작업 중이면 그 잠금을 덮지 않는다 — 터널은 닫힌 항목으로 남아 [다시 연결] 로 다시 한다
                guard busyAction == nil else {
                    let reason = "다른 작업 중이라 주소를 준비하지 못했습니다"
                    session.state = .closed(exitCode: 1, message: reason)
                    tunnelStateChanged()
                    statusMessage = "터널 \(hostName): \(reason)"
                    return
                }
                busyAction = BusyAction("터널 주소 준비 · 인증")
                let script = HostAliasCommands.setupScript(name: hostName, address: bindAddress, libDir: libDir)
                let result = await LanCommands.runPrivileged(script, runner: runner)
                busyAction = nil
                guard result.ok else {
                    let reason = PrivilegedOutcome(result).authProblem.map { "\($0) · 주소를 준비하지 않았습니다" }
                        ?? "주소 준비 실패: " + RemoteCommands.cleanOutput(result.stdout + result.stderr, type: .linux).filter { !$0.isEmpty }.suffix(2).joined(separator: " · ")
                    session.state = .closed(exitCode: result.exitCode, message: reason)
                    tunnelStateChanged()
                    statusMessage = "터널 \(hostName): \(reason)"
                    return
                }
            }
            do {
                try session.process.start(executable: "ssh", arguments: spec.arguments, environment: environment)
            } catch {
                session.state = .closed(exitCode: 126, message: "\(error)")
                tunnelStateChanged()
            }
        }
        return session
    }

    /// 터널이 열릴 때까지 기다린다 ([Browser]·[Chrome] 공통): ssh 가 인증을 마치고 배너를 찍을 때까지 최대 60초
    /// (비밀번호 팝업이 뜰 수 있어 넉넉히). 열렸으면 true, 실패로 닫혔거나 시간이 지났으면 false.
    func waitTunnelOpen(_ session: TunnelSession) async -> Bool {
        let deadline = Date().addingTimeInterval(60)
        while session.state == .connecting, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return session.state == .open
    }

    /// 목록 안 터널의 상태(연결 중·열림·닫힘)가 바뀌었다 — tunnels 를 읽는 화면(활성 먼저 정렬·열린 포트의 터널·메뉴)에 알린다.
    /// TunnelSession 의 @Published 는 AppModel 관찰(@Observable)에 잡히지 않는다. 배열은 그대로 두고 tunnels 를 바꾼 것으로만 알린다.
    func tunnelStateChanged() {
        withMutation(keyPath: \.tunnels) {}
    }

    /// 표시 순서: 활성(연결 중·연결됨) 먼저, 그다음 닫힘. 각 묶음 안에서는 연 순서.
    var sortedTunnels: [TunnelSession] {
        tunnels.enumerated().sorted { a, b in
            if a.element.isActive != b.element.isActive { return a.element.isActive }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// 다시 연결: 닫힌(또는 이전 실행의) 터널을 같은 조건으로 다시 연다. 로컬 포트가 쓰이면 다음 빈 포트.
    func reconnectTunnel(_ id: UUID) {
        guard let session = tunnels.first(where: { $0.id == id }), !session.isActive else { return }
        // 지금 설정으로 연다 — 서버 편집으로 주소·그룹이 바뀌었어도 옛 값으로 붙지 않게. 이름을 따로 안 줬으면(기본 <키>.<그룹>) 새 그룹 이름으로.
        // 계정은 그 터널을 연 계정 그대로 (그사이 다른 계정을 골랐어도)
        let current = config?.server(session.spec.server.key)?.account(session.spec.server.user) ?? session.spec.server
        let defaultName = session.spec.hostName == HostAliasStore.hostName(server: session.spec.server, kind: session.spec.kind)
        let fresh = startTunnel(server: current, kind: session.spec.kind, preferredLocalPort: session.spec.localPort, named: session.spec.isNamed,
                                name: defaultName ? nil : session.spec.hostName)
        // 정보 창이 옛 세션을 보고 있으면 새 세션으로 바꾼다 (옛 세션은 목록에서 빠졌거나 끊긴 채라 버튼이 다시 눌린다)
        if let fresh, tunnelInfo?.id == id { tunnelInfo = fresh }
    }

    func saveRecent(_ state: RecentState) {
        recent = state
        do { try RecentStore.save(state) } catch { statusMessage = "최근 기록 저장 실패: \(error.localizedDescription)" }
    }

    func stopTunnel(_ id: UUID) {
        guard let session = tunnels.first(where: { $0.id == id }) else { return }
        session.process.stop()
    }

    /// 앱에서 내부망을 껐을 때: 내부망 서버를 지나는 터널은 확실히 죽었으니 keepalive(15초)를 기다리지 않고 바로 끊는다.
    func stopLanTunnels() {
        for session in tunnels where session.isActive && session.spec.server.network == .lan {
            session.stopReason = "내부망 끔"
            session.process.stop()
        }
    }

    /// 끊긴 항목을 목록에서 지운다. 살아 있으면 먼저 끊는다. 기록(recent.json)에서도 빼서 다음 실행에 다시 안 뜨게.
    /// 서버 주소 터널이면 /etc/hosts 의 그 줄("IP 이름 # servers-app" 과 정확히 같은 줄만)과, 그 주소를 쓰는 터널이 더 없으면 별칭도 지운다 (인증 한 번).
    func removeTunnel(_ id: UUID) {
        guard let session = tunnels.first(where: { $0.id == id }) else { return }
        session.process.stop()
        tunnels.removeAll { $0.id == id }
        refreshBrowserScopes()
        let record = RecentTunnel(serverKey: session.spec.server.key, kind: session.spec.kind, localPort: session.spec.localPort,
                                  bindAddress: session.spec.bindAddress, hostName: session.spec.hostName)
        if tunnels.allSatisfy({ !$0.matches(record) }) { saveRecent(RecentStore.remove(id: record.id, from: recent)) }
        guard let address = session.spec.bindAddress, let name = session.spec.hostName,
              !tunnels.contains(where: { $0.spec.hostName == name }) else { return }
        let dropAlias = !tunnels.contains { $0.spec.bindAddress == address }
        Task {
            guard await HostAliasCommands.needsTeardown(name: name, address: address, runner: runner) else { return }
            // 다른 관리자·원격 작업 중이면 그 잠금을 덮지 않는다
            guard busyAction == nil else {
                statusMessage = "다른 작업 중이라 \(name) 의 hosts 줄을 지우지 못했습니다."
                return
            }
            busyAction = BusyAction("터널 주소 제거 · 인증")
            let script = HostAliasCommands.teardownScript(name: name, address: address, dropAlias: dropAlias, libDir: libDir)
            let result = await LanCommands.runPrivileged(script, runner: runner)
            busyAction = nil
            if let problem = PrivilegedOutcome(result).authProblem {
                statusMessage = "\(problem) · \(name) 의 hosts 줄은 남겨 두었습니다."
            } else if result.ok {
                statusMessage = "\(name) → \(address) 제거\(dropAlias ? " (별칭 포함)" : "")."
            } else {
                statusMessage = "\(name) 제거 실패: " + RemoteCommands.cleanOutput(result.stdout + result.stderr, type: .linux).filter { !$0.isEmpty }.suffix(2).joined(separator: " · ")
            }
        }
    }

    /// 앱 종료: 터널과 진행 중인 자식 프로세스(비밀번호 팝업·sudo·tailscale)를 모두 끝낸다.
    func stopAllTunnels() {
        for t in tunnels { t.process.stop() }
        for t in transfers { t.process.stop() }
        capture.stop()
        ProcessRegistry.shared.killAll(signal: SIGTERM)
    }

    func showTunnelInfo(_ session: TunnelSession) {
        tunnelInfo = session
    }
}
