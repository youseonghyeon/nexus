// 서버 목록 편집: 서버를 servers.conf 에 붙이거나 빼거나 고친다. 파일 편집은 ServerConfigEditor, 반영은 loadConfig. 목록 가져오기·내보내기(파일 선택 창)도 여기.

import AppKit
import Foundation
import ServersCore
import UniformTypeIdentifiers

extension AppModel {
    /// 그룹 헤더의 + : 그 그룹과, 그 그룹 첫 서버의 망을 미리 채운다. 빈 목록의 [서버 추가]는 그룹 없이 Direct 로.
    func promptAddServer(group: String) {
        let network = config?.servers(in: group).first?.network ?? .direct
        addServerPrompt = AddServerRequest(group: group, network: network)
    }

    /// 성공하면 nil, 실패하면 입력창에 보일 오류. 쓰기 전 현재 파일을 다시 읽어 그 위에 붙인다 (외부 편집을 덮지 않게).
    /// lanService: 내부망 설정이 없을 때 첫 Intranet 서버와 함께 [network:lan] 을 만든다 (한 번에 씀).
    func addServer(_ server: NewServer, notify: Bool, lanService: String? = nil) -> ConfigError? {
        if let error = editConfig({ text in
            let text = try lanService.map { try ServerConfigEditor.addingLanService($0, to: text, reference: configPath) } ?? text
            return try ServerConfigEditor.appending(server, notify: notify, to: text, reference: configPath)
        }) { return error }
        if let lanService { adoptLanService(lanService) }
        loadConfig()
        selectedKey = server.key
        statusMessage = "\(server.key) 서버를 추가했습니다."
        requestRefresh()
        return nil
    }

    /// Intranet 지정 기록: lan.json 을 그 서비스로 + 서비스 순서 맨 뒤로(필요할 때만 인증). 첫 Intranet 서버 추가·Ethernet 서비스 카드의 지정이 같이 쓴다.
    func adoptLanService(_ service: String) {
        lanSettings = LanSettings(service: service)
        if let error = saveLanSettings() { statusMessage = error }
        moveIntranetLastIfNeeded(service)
    }

    /// 목록을 읽었으면 어느 서버든 지울 수 있다 (마지막 서버도 — 빈 목록이 된다). 다른 서버가 가리키던 설정은 지울 때 함께 정리한다 (confirmRemoveServer).
    func canRemoveServer(_ server: Server) -> Bool {
        config != nil
    }

    func confirmRemoveServer(_ server: Server) {
        guard canRemoveServer(server), let config else { return }
        let refs = ServerConfigEditor.references(to: server.key, in: config)
        pendingConfirm = PendingConfirm(
            title: "\(server.key) 목록에서 지우기",
            message: (server.isProd ? server.tags.filter { ServerTags.tone($0) == .production }.joined(separator: ", ") + " 서버입니다. " : "") + "servers.conf 에서 [\(server.key)] 블록을 지웁니다. "
                + (refs.isEmpty ? "" : "이 서버를 가리키던 설정도 함께 뺍니다: \(refs.joined(separator: ", ")). ")
                + "열린 탭·터널은 닫히고 저장한 비밀번호도 지워집니다. 서버 자체는 건드리지 않습니다.") { [weak self] in
            self?.removeServer(server)
        }
    }

    private func removeServer(_ server: Server) {
        if let error = editConfig({ try ServerConfigEditor.removing(key: server.key, from: $0, reference: configPath) }) {
            statusMessage = "\(server.key) 지우기 실패: \(error.problem)"
            return
        }
        dropTunnels(of: server)
        remoteInfo[server.key] = nil
        loadConfig()
        statusMessage = "\(server.key) 서버를 목록에서 지웠습니다."
    }

    /// 그 서버(account 를 주면 그 계정으로 연 것만)의 터널은 끊고 목록·기록(recent.json)에서 뺀다. 탭·비밀번호는 loadConfig 가 정리한다.
    /// hosts 줄·루프백 별칭은 남긴다 (지우려면 root 인증이 필요하고, 남아도 다른 터널에 해가 없다).
    func dropTunnels(of server: Server, account: String? = nil) {
        let matches: (Server) -> Bool = { $0.key == server.key && (account == nil || $0.user == account) }
        for session in tunnels where matches(session.spec.server) { session.process.stop() }
        tunnels.removeAll { matches($0.spec.server) }
        let kept = RecentState(tunnels: recent.tunnels.filter { !($0.serverKey == server.key && (account == nil || $0.user == account)) })
        if kept != recent { saveRecent(kept) }
    }

    // MARK: 두 항목을 한 서버의 계정으로 합치기

    /// 서버 우클릭 메뉴: 같은 장비(주소·포트·종류·망·그룹)이고 사용자가 겹치지 않는 서버들
    func accountMergeTargets(_ server: Server) -> [Server] {
        config.map { ServerConfigEditor.accountMergeTargets(for: server.key, in: $0) } ?? []
    }

    func confirmMergeAccount(_ source: Server, into target: Server) {
        // 다른 서버를 깨우는 경로·DB Tunnel 은 target 쪽으로 돌아간다 — 깨우기는 경유 서버의 기본 계정으로 실행되므로 권한이 달라질 수 있다
        let refs = config.map { ServerConfigEditor.references(to: source.key, in: $0) } ?? []
        pendingConfirm = PendingConfirm(
            title: "\(source.key) 를 \(target.key) 에 합치기",
            message: "\(source.accounts.joined(separator: "·")) 계정을 \(target.key) 로 옮기고 [\(source.key)] 블록을 지웁니다. 저장한 비밀번호·키 파일도 함께 옮깁니다. "
                + "태그·터널 바로가기는 더하고, \(target.key) 에 없는 역할·알림·액션은 가져오며, 있는 값은 \(target.key) 것을 씁니다. "
                + (refs.isEmpty ? "" : "\(refs.joined(separator: ", ")) 는 \(target.key) 로 바뀝니다 (깨우기는 기본 계정 \(target.primaryUser) 로 실행). ")
                + "\(source.key) 의 열린 탭·터널은 닫힙니다. 서버 자체는 건드리지 않습니다.") { [weak self] in
            self?.mergeAccount(source, into: target)
        }
    }

    private func mergeAccount(_ source: Server, into target: Server) {
        // 옮길 계정은 지금 파일 기준 — 파일을 직접 고친 뒤 다시 읽지 않았어도 파일에 합쳐지는 계정과 같게
        var current = source
        if let error = editConfig({ text in
            current = try ServerConfigParser.parse(text, reference: configPath).server(source.key) ?? source
            return try ServerConfigEditor.mergingAccount(from: source.key, into: target.key, in: text, reference: configPath)
        }) {
            statusMessage = "\(source.key) 합치기 실패: \(error.problem)"
            return
        }
        // loadConfig 는 목록에 없는 저장 키를 지운다 — 그 전에 새 자리로 옮겨 저장한다
        passwords = ServerConfigEditor.movingCredentials(passwords, from: current, into: target.key)
        savePasswords()
        identities = ServerConfigEditor.movingCredentials(identities, from: current, into: target.key)
        saveIdentities()
        // 다른 서버의 깨우기 경로로 source 를 골라 뒀으면 target 으로 (안 돌리면 조용히 첫 경로로 바뀐다)
        for server in config?.servers ?? [] where UserDefaults.standard.string(forKey: AppPreferences.wakeRouteKey(for: server.key)) == source.key {
            setWakeRoute(target.key, for: server)
        }
        dropTunnels(of: source)
        remoteInfo[source.key] = nil
        loadConfig()
        selectedKey = target.key
        statusMessage = "\(source.key) 를 \(target.key) 의 계정으로 합쳤습니다."
        requestRefresh()
    }

    func editServer(_ server: Server) { serverEditor = server }

    func canMoveGroup(_ group: String, _ direction: ServerConfigEditor.MoveDirection) -> Bool {
        guard let config else { return false }
        return ServerConfigEditor.groupNeighbor(of: group, direction, in: config) != nil
    }

    func moveGroup(_ group: String, _ direction: ServerConfigEditor.MoveDirection) {
        guard canMoveGroup(group, direction) else { return }
        if let error = editConfig({ try ServerConfigEditor.movingGroup(group, direction, in: $0, reference: configPath) }) {
            statusMessage = "\(group) 그룹 옮기기 실패: \(error.problem)"
            return
        }
        loadConfig()
    }

    /// 서버 추가 창의 [피어에서 고르기]: 아직 등록하지 않은 Tailscale 피어 (이 Mac 의 tailscaled 에 묻기만 — 서버 접속 없음)
    func unregisteredTailscalePeers() async -> [TailscalePeer] {
        let result = await runner.run("tailscale", ["status", "--json"], timeout: 5)
        guard result.ok else { return [] }
        let registered = Set(config?.servers.map(\.ip) ?? [])
        return TailscalePeers.parse(result.stdout).filter { !registered.contains($0.ip) }
    }

    /// 서버 추가·편집 창이 Ping·포트 확인을 묶을 장치 (ServerFormCheck.bindDevice — 스냅숏에 없는 VPN 은 지금 읽고,
    /// 내부망 설정이 아직 없으면 창에서 고른 서비스 lanService 의 장치)
    func formBindDevice(network: ServerNetwork, vpn: String?, lanService: String? = nil) async -> String? {
        let chosen = lanService.flatMap { name in lanServiceCandidates.first { $0.name == name }?.device }
        return await ServerFormCheck.bindDevice(network: network, vpn: vpn, lanServiceDevice: chosen, snapshot: status, runner: runner)
    }

    /// 서버 추가·편집 창의 [포트 확인]: 사용자가 누를 때만 TCP 연결 한 번 (상태 확인과 같은 방식 — 내부망은 그 장치에 묶는다)
    func probePort(ip: String, port: Int, network: ServerNetwork, vpn: String? = nil, lanService: String? = nil) async -> Bool {
        let bind = await formBindDevice(network: network, vpn: vpn, lanService: lanService)
        guard ServerFormCheck.canSend(network: network, device: bind) else { return false }   // lan·vpn 인데 묶을 장치가 없다 — 시스템 경로로 새지 않게
        return await TCPProbe.probe(ip, port, TimeInterval(ConnectPolicy.timeoutSeconds), bind)
    }

    /// 서버 추가·편집 창의 [Ping]: 사용자가 누를 때만 ping 5회 (진단 카드와 같은 PingTest — 대상 검사·장치 묶기). 포트 확인과 같은 장치에 묶는다.
    /// 대상이 IP·이름 꼴이 아니거나 VPN 이 꺼져 있으면 보내지 않고 nil.
    func pingHost(ip: String, network: ServerNetwork, vpn: String? = nil, lanService: String? = nil) async -> PingSummary? {
        guard let target = PingTest.target(ip) else { return nil }
        let bind = await formBindDevice(network: network, vpn: vpn, lanService: lanService)
        guard ServerFormCheck.canSend(network: network, device: bind) else { return nil }
        return await PingTest.ping(target, device: bind, runner: runner).summary
    }

    /// 그룹 안에서 한 칸 위·아래로 (servers.conf 의 블록 순서를 바꾼다). 그룹 끝이면 비활성.
    func canMoveServer(_ server: Server, _ direction: ServerConfigEditor.MoveDirection) -> Bool {
        guard let config else { return false }
        return ServerConfigEditor.neighbor(of: server.key, direction, in: config) != nil
    }

    func moveServer(_ server: Server, _ direction: ServerConfigEditor.MoveDirection) {
        guard canMoveServer(server, direction) else { return }
        if let error = editConfig({ try ServerConfigEditor.moving(key: server.key, direction, in: $0, reference: configPath) }) {
            statusMessage = "\(server.key) 옮기기 실패: \(error.problem)"
            return
        }
        loadConfig()
    }

    /// 성공하면 nil, 실패하면 창에 보일 오류. 창에서 바꾼 항목만 지금 파일 위에 쓴다 (창을 연 뒤 파일을 직접 고친 줄은 덮지 않게).
    /// newKey: 창의 이름 칸 — 다르면 같은 쓰기에서 이름도 바꾼다 (한 번에 쓰므로 일부만 저장되는 일이 없다).
    func updateServer(_ original: Server, to edited: NewServer, notify: Bool, lanService: String? = nil, newKey: String? = nil) -> ConfigError? {
        let renamed = newKey.flatMap { $0 == original.key ? nil : $0 }
        statusMessage = nil
        // 저장한 비밀번호는 키에 묶여 있다 — 다른 기기로 옮겼거나 계정이 사라졌으면 옛 비밀번호를 새 곳으로 보내지 않게 지운다 (창에서 미리 알림).
        // 파일을 쓰기 전에 지우고 새 이름 자리에 복사해 저장한다: 쓰기 뒤 죽거나 저장이 실패해도 값이 사라지지 않게. 못 쓰면 되돌린다.
        let savedPasswords = passwords, savedIdentities = identities
        let cleared = ServerConfigEditor.clearedCredentials(original, edited).filter { passwords[$0] != nil }
        let passwordCleared = !cleared.isEmpty
        for key in cleared { passwords[key] = nil }
        if let renamed { stageRename(from: original.key, to: renamed) }
        if passwords != savedPasswords { savePasswords() }
        if identities != savedIdentities { saveIdentities() }
        if let error = editConfig({ text in
            let text = try lanService.map { try ServerConfigEditor.addingLanService($0, to: text, reference: configPath) } ?? text
            let updated = try ServerConfigEditor.updating(edited, notify: notify, from: original, in: text, reference: configPath)
            return try renamed.map { try ServerConfigEditor.renaming(key: original.key, to: $0, in: updated, reference: configPath) } ?? updated
        }) {
            if passwords != savedPasswords { passwords = savedPasswords; savePasswords() }
            if identities != savedIdentities { identities = savedIdentities; saveIdentities() }
            return error
        }
        if let lanService { adoptLanService(lanService) }
        if let renamed { moveServerState(from: original.key, to: renamed) }
        loadConfig()   // 접속 정보가 바뀌었으면 옛 주소의 상태·캐시·터널도 여기서 정리한다
        if let renamed, let fresh = config?.server(renamed) {
            // 터널 기록의 기본 hosts 이름은 새 그룹·이름을 알아야 한다 — 목록을 읽은 뒤에. 닫힌 터널은 목록에 다시 올라와 [다시 연결] 할 수 있다
            saveRecent(RecentStore.renamingServer(original, to: fresh, in: recent))
            restoreRecentTunnels()
        }
        // 비밀번호 저장 실패 등을 덮지 않는다
        if statusMessage == nil {
            statusMessage = (renamed.map { "\(original.key) 이름을 \($0) 로 바꿨습니다." } ?? "\(original.key) 서버를 저장했습니다.")
                + (passwordCleared ? " IP·사용자가 바뀌어 저장한 비밀번호를 지웠습니다." : "")
        }
        requestRefresh()
        return nil
    }

    /// 비밀번호·키 파일을 새 이름 자리에도 넣는다 (파일을 쓰기 전). 옛 자리의 값은 목록을 다시 읽을 때 주인이 없어져 빠진다.
    private func stageRename(from old: String, to new: String) {
        guard let known = config else { return }
        // 파일을 직접 고치고 다시 읽기 전이면 계정 순서가 다를 수 있다 — 지금 파일 기준으로 맞춘다
        let onDisk = (try? ServerConfigParser.parse(try readConfigText(), reference: configPath)) ?? known
        passwords = ServerConfigEditor.stagingRename(passwords, known: known, onDisk: onDisk, from: old, to: new)
        identities = ServerConfigEditor.stagingRename(identities, known: known, onDisk: onDisk, from: old, to: new)
    }

    /// 이름에 묶인 나머지 값을 옮긴다. 파일을 쓴 뒤, 목록을 다시 읽기 전에 부른다.
    /// 열린 탭은 loadConfig 가 닫고, 터널은 여기서 끊는다 (옛 이름을 들고 있다). 기록(recent.json)은 남겨 새 이름으로 옮긴다.
    private func moveServerState(from old: String, to new: String) {
        remoteHomes = ServerConfigEditor.renamingCredentials(remoteHomes, from: old, to: new)
        lastUploadPath = ServerConfigEditor.renamingCredentials(lastUploadPath, from: old, to: new)
        if let account = activeAccounts.removeValue(forKey: old) { activeAccounts[new] = account; saveActiveAccounts() }
        // 이름별 설정: 고른 깨우기 경로 · 앱 안 브라우저 쿠키 저장소(로그인). 옛 값이 없으면 새 이름에 남은 값(지운 서버의 것)도 지운다 — 다른 서버의 것이 살아나지 않게
        let defaults = UserDefaults.standard
        for name in [AppPreferences.wakeRouteKey(for:), AppPreferences.browserStoreKey(for:)] {
            defaults.set(defaults.string(forKey: name(old)), forKey: name(new))
            defaults.removeObject(forKey: name(old))
        }
        // 이 서버를 경유로 고른 다른 서버의 값
        for server in config?.servers ?? [] where defaults.string(forKey: AppPreferences.wakeRouteKey(for: server.key)) == old {
            setWakeRoute(new, for: server)
        }
        let aliases = HostAliasStore.renaming(from: old, to: new, in: hostAliases)
        if aliases != hostAliases {
            hostAliases = aliases
            do { try HostAliasStore.save(aliases) } catch { statusMessage = "주소 배정표 저장 실패: \(error.localizedDescription)" }
        }
        // Chrome 프록시 프로필 (로그인·방문 기록). 프록시가 떠 있으면 Chrome 이 쓰는 중일 수 있고, 새 이름에 이미 있으면 덮지 않는다 — 옛 이름에 남기고 알린다
        let profile = ChromeProxy.profileDir(serverKey: old), target = ChromeProxy.profileDir(serverKey: new)
        if FileManager.default.fileExists(atPath: profile.path) {
            let inUse = tunnels.contains { $0.isActive && $0.spec.server.key == old && $0.spec.kind == .socks }
            if inUse || FileManager.default.fileExists(atPath: target.path) {
                statusMessage = "Chrome 프로필을 옮기지 못했습니다 — chrome-proxy/\(old) 에 그대로 있습니다."
            } else {
                do { try FileManager.default.moveItem(at: profile, to: target) } catch { statusMessage = "Chrome 프로필 옮기기 실패: \(error.localizedDescription)" }
            }
        }
        for session in tunnels where session.spec.server.key == old { session.process.stop() }
        tunnels.removeAll { $0.spec.server.key == old }
        // 먼저 옮겨 둔다 — 보고 있던 서버가 목록에서 사라졌다고 첫 서버로 옮겨 가지 않게
        if selectedKey == old { selectedKey = new }
    }

    /// 이름을 바꾸면 닫히는 것의 개수 (창에 미리 알린다). 터널은 끊겨도 목록에 남는다.
    func openSessionCount(_ server: Server) -> (tabs: Int, tunnels: Int) {
        (tabs(for: server.key).count, tunnels.filter { $0.isActive && $0.spec.server.key == server.key }.count)
    }

    func editActions(_ server: Server) { actionsEditor = server }

    /// 성공하면 nil, 실패하면 시트에 보일 오류
    /// 변경 하나만 넘긴다 — 파일에서 새로 읽은 값에 적용해 쓴다 (앱이 기억하는 값으로 다른 줄을 덮지 않게)
    func updateActions(for server: Server, _ change: (inout ServerConfigEditor.Actions) -> Void) -> ConfigError? {
        if let error = editConfig({ try ServerConfigEditor.updating(for: server.key, in: $0, reference: configPath, change) }) { return error }
        loadConfig()
        statusMessage = "\(server.key) 액션을 저장했습니다."
        return nil
    }

    /// servers.conf 고치기 한 번: 지금 파일을 다시 읽어(외부 편집을 덮지 않게) edit 결과를 쓴다. 성공하면 nil, 실패는 [문제/해결/참조].
    func editConfig(_ edit: (String) throws -> String) -> ConfigError? {
        do {
            try ServerConfigEditor.write(try edit(try readConfigText()), to: configPath)
            return nil
        } catch let error as ConfigError {
            return error
        } catch {
            return ConfigError(problem: "servers.conf 쓰기 실패: \(error.localizedDescription)", fix: "파일 권한을 확인하세요.", reference: configPath)
        }
    }

    func readConfigText() throws -> String {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            throw ConfigError(problem: "servers.conf 를 읽을 수 없습니다: \(configPath)", fix: "파일이 있는지 확인하세요.", reference: configPath)
        }
        return text
    }

    // MARK: 서버 목록 가져오기·내보내기

    /// 지금 servers.conf 를 그대로 파일로 (비밀번호는 이 파일에 없다 — passwords.bin 은 따로)
    func exportServers() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "servers.conf"
        panel.allowedContentTypes = [.plainText]
        panel.message = "서버 목록을 내보냅니다 (비밀번호는 들어가지 않습니다)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try readConfigText().write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "서버 \(config?.servers.count ?? 0)대를 내보냈습니다 · \(url.lastPathComponent)"
        } catch {
            statusMessage = "내보내지 못했습니다: \((error as? ConfigError)?.problem ?? error.localizedDescription)"
        }
    }

    /// 다른 사람이 내보낸 목록에서 없는 서버만 붙인다 (이름이 같으면 건너뜀)
    func importServers() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "가져올 서버 목록(servers.conf)을 고르세요 — 이름이 같은 서버는 건너뜁니다"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let imported = try? String(contentsOf: url, encoding: .utf8) else {
                throw ConfigError(problem: "파일을 읽지 못했습니다: \(url.lastPathComponent)", fix: "텍스트 파일인지 확인하세요.", reference: url.path)
            }
            let merge = try ServerConfigEditor.merging(imported, into: try readConfigText(), importedReference: url.lastPathComponent, reference: configPath)
            if !merge.added.isEmpty { try ServerConfigEditor.write(merge.text, to: configPath) }
            loadConfig()
            requestRefresh()
            statusMessage = merge.added.isEmpty
                ? "가져올 새 서버가 없습니다" + (merge.skipped.isEmpty ? "" : " · 이미 있음: \(merge.skipped.joined(separator: ", "))")
                : "서버 \(merge.added.count)대를 가져왔습니다: \(merge.added.joined(separator: ", "))" + (merge.skipped.isEmpty ? "" : " · 건너뜀(이미 있음): \(merge.skipped.joined(separator: ", "))")
        } catch let error as ConfigError {
            statusMessage = "가져오지 못했습니다: \(error.problem) · \(error.fix)"
        } catch {
            statusMessage = "가져오지 못했습니다: \(error.localizedDescription)"
        }
    }
}
