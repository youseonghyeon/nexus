// 자격 증명: 세션 비밀번호(passwords.bin)·계정 고르기/추가/제거/기본 계정(extra_users)·키 파일 등록(identities.json).
// 원격 실행(runRemote)·비밀번호 팝업 환경은 AppModel+Remote.

import AppKit
import Foundation
import ServersCore

extension AppModel {
    // MARK: 세션 비밀번호

    /// 그 계정의 지금 저장 키. 열린 탭·터널의 값은 기본 계정이 바뀌기 전 것일 수 있다 — 옛 키로 찾으면 다른 계정의 비밀번호를 보낸다.
    func credentialKey(_ server: Server) -> String {
        config?.credentialKey(of: server) ?? server.credentialKey
    }

    func setPassword(_ password: String, for server: Server) {
        passwords[credentialKey(server)] = password.isEmpty ? nil : password
        savePasswords()
    }

    func clearPassword(for server: Server) {
        passwords[credentialKey(server)] = nil
        savePasswords()
    }

    func savePasswords() {
        do { try PasswordVault.save(passwords, key: vaultKey) } catch {
            statusMessage = "비밀번호 저장 실패: \((error as? ConfigError)?.problem ?? error.localizedDescription)"
        }
    }

    /// 설정의 [키 새로 만들기]: 새 키를 키체인에 두고 저장한 비밀번호를 모두 지운다 (다음 접속 때 다시 묻는다).
    /// 같은 키로 잠근 메모·로그인(notes.bin)도 지운다 — 새 키로는 못 푼다.
    func rotatePasswordKey() {
        do {
            vaultKey = try PasswordVault.rotateKey(store: vaultKeyStore)
            passwords = [:]
            clearNotes()
            statusMessage = "새 키를 만들고 저장한 비밀번호와 메모·로그인을 지웠습니다."
        } catch {
            statusMessage = "키를 새로 만들지 못했습니다: \(error.localizedDescription)"
        }
    }

    func hasPassword(_ server: Server) -> Bool { passwords[credentialKey(server)] != nil }

    // MARK: 계정 (extra_users)

    /// 서버 정보의 사용자 칸: 이제부터 여는 SSH·전송·터널·원격 정보가 쓸 계정. 열려 있는 탭·터널은 연 계정 그대로 둔다.
    func selectAccount(_ name: String, of server: Server) {
        guard server.accounts.contains(name), name != server.user else { return }
        activeAccounts[server.key] = name == server.primaryUser ? nil : name
        saveActiveAccounts()
        applyActiveAccounts()
        // 원격 정보는 계정마다 보이는 게 다를 수 있다 (권한) — 새 계정으로 다시 읽는다
        remoteInfo[server.key] = nil
        liveMonitors[server.key] = nil
        autoFetchSpecIfNeeded()
    }

    func saveActiveAccounts() {
        UserDefaults.standard.set(activeAccounts, forKey: AppPreferences.activeAccountsKey)
    }

    /// 사용자 칸 [+]: 성공하면 nil, 실패하면 입력창에 보일 오류. 새 계정을 바로 골라 아래 칸에 비밀번호·키 파일을 넣게 한다.
    func addAccount(_ name: String, to server: Server) -> ConfigError? {
        if let error = editConfig({ try ServerConfigEditor.addingAccount(name, to: server.key, in: $0, reference: configPath) }) { return error }
        loadConfig()
        if let fresh = config?.server(server.key) { selectAccount(name, of: fresh) }
        statusMessage = "\(server.key) 에 \(name) 계정을 추가했습니다."
        return nil
    }

    func confirmRemoveAccount(_ name: String, of server: Server) {
        pendingConfirm = PendingConfirm(
            title: "\(name) 계정 제거",
            message: "\(server.key) 에서 \(name) 계정을 뺍니다. 이 계정의 저장한 비밀번호·키 파일 등록도 지워지고, 이 계정으로 연 터널은 끊겨 목록에서 빠집니다. 열린 터미널 탭은 그대로 두고, 서버의 계정은 건드리지 않습니다.") { [weak self] in
            guard let self else { return }
            if let error = editConfig({ try ServerConfigEditor.removingAccount(name, from: server.key, in: $0, reference: self.configPath) }) {
                statusMessage = "\(name) 계정 제거 실패: \(error.problem)"
                return
            }
            dropTunnels(of: server, account: name)
            if activeAccounts[server.key] == name { activeAccounts[server.key] = nil; saveActiveAccounts() }
            loadConfig()   // 비밀번호·키 파일 정리, 고른 계정이면 기본 계정으로
            statusMessage = "\(server.key) 에서 \(name) 계정을 뺐습니다."
        }
    }

    /// 기본 계정을 맞바꾼다. 상태 확인이 실패할 수 있으면 먼저 묻는다.
    func promoteAccount(_ name: String, of server: Server) {
        guard server.statusCheckMayFail(as: name) else { return applyPromotion(name, of: server) }
        pendingConfirm = PendingConfirm(
            title: "\(name) 을 기본 계정으로",
            message: "상태 확인은 기본 계정의 키 로그인으로 합니다. \(name) 에 등록한 키 파일이 없어 확인이 실패하면 \(server.key) 가 실패로 보이고 SSH·터널이 비활성될 수 있습니다.") { [weak self] in
            self?.applyPromotion(name, of: server)
        }
    }

    /// 비밀번호·키 파일은 loadConfig 가 계정을 따라 옮기고, 지금 고른 계정은 그대로 둔다.
    private func applyPromotion(_ name: String, of server: Server) {
        if let error = editConfig({ try ServerConfigEditor.promotingAccount(name, of: server.key, in: $0, reference: configPath) }) {
            statusMessage = "\(name) 기본 계정 지정 실패: \(error.problem)"
            return
        }
        activeAccounts[server.key] = server.user == name ? nil : server.user
        saveActiveAccounts()
        statusMessage = nil
        loadConfig()
        // 비밀번호 저장 실패를 덮지 않는다 — 재시작하면 옛 값이 읽혀 다른 계정의 비밀번호가 나간다
        if statusMessage == nil { statusMessage = "\(server.key) 의 기본 계정을 \(name) 로 바꿨습니다." }
        requestRefresh()   // 상태 확인이 새 기본 계정으로
    }

    // MARK: 키 파일 (IdentityFile)

    /// 서버 정보 [파일 선택…]·[변경]: ~/.ssh 에서 연다 (숨김 파일도 보이게 — 키는 대개 ~/.ssh 안에 있다)
    func chooseIdentity(for server: Server) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        panel.prompt = "선택"
        panel.message = "\(server.accountTitle) 접속에 쓸 개인키 (.pem · id_ed25519 등)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setIdentity(url.path, for: server)
    }

    /// 개인키인지 보고 등록한다. ~/.ssh 밖(다운로드 폴더 등)이면 ~/.ssh 로 옮길지 묻고(옮기면 600 도),
    /// 그 자리 그대로여도 권한이 열려 있으면(ssh 가 거부) 600 으로 바꿀지 묻는다. 묻는 창은 한 번만.
    func setIdentity(_ path: String, for server: Server) {
        let name = (path as NSString).lastPathComponent
        let problem = IdentityFile.check(path: path)
        switch problem {
        case .missing:
            statusMessage = "키 파일을 찾지 못했습니다: \(path)"
            return
        case .notPrivateKey:
            statusMessage = "\(name) 은 키 파일로 쓸 수 없습니다 — OpenSSH 개인키(.pem · id_ed25519 등)가 아닙니다."
            return
        case .tooOpen, nil:
            break
        }
        let tooOpen = problem == .tooOpen
        // 그 자리에 두고 등록 (권한이 열려 있으면 600 으로 바꾼 뒤)
        let keepInPlace: @MainActor () -> Void = { [weak self] in
            if tooOpen {
                do { try IdentityFile.restrict(path: path) } catch {
                    self?.statusMessage = "\(name) 권한을 바꾸지 못했습니다: \(error.localizedDescription)"
                    return
                }
            }
            self?.storeIdentity(path, for: server)
        }
        if !IdentityFile.isInSSHDirectory(path) {
            let folder = ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
            pendingConfirm = PendingConfirm(
                title: "~/.ssh 로 옮겨 등록",
                message: "\(name) 이 ~/.ssh 밖(\(folder))에 있습니다. 그 폴더를 정리하다 지우면 \(server.key) 에 접속할 수 없습니다. "
                    + "~/.ssh 로 옮기고 권한을 600(나만 읽기·쓰기)으로 맞춘 뒤 등록할까요? 복사가 아니라 옮기기라 키는 한 벌만 남습니다.",
                alternative: (tooOpen ? "이 자리에 두고 권한만 600 으로" : "이 자리 그대로", keepInPlace)) { [weak self] in
                do {
                    let moved = try IdentityFile.moveIntoSSH(path)
                    self?.storeIdentity(moved, for: server)
                } catch let error as ConfigError {
                    self?.statusMessage = "\(error.problem) — \(error.fix)"
                } catch {
                    self?.statusMessage = "\(name) 을 ~/.ssh 로 옮기지 못했습니다: \(error.localizedDescription)"
                }
            }
        } else if tooOpen {
            pendingConfirm = PendingConfirm(
                title: "\(name) 권한 바꾸기",
                message: "다른 사용자도 읽을 수 있는 키라 ssh 가 쓰지 않습니다. 권한을 600(나만 읽기·쓰기)으로 바꾸고 \(server.key) 에 등록할까요?",
                action: keepInPlace)
        } else {
            storeIdentity(path, for: server)
        }
    }

    func clearIdentity(for server: Server) {
        identities[credentialKey(server)] = nil
        saveIdentities()
        applyIdentities()
    }

    /// 화면용: 등록한 키 파일의 지금 상태 (nil = 쓸 수 있음). 등록하지 않았으면 nil.
    /// 파일 검사는 refreshIdentityProblems 가 해 둔 값을 읽는다 (그리기마다 파일을 열지 않게).
    func identityProblem(_ server: Server) -> IdentityFile.Problem? {
        server.identityFile == nil ? nil : identityProblems[server.key]
    }

    private func storeIdentity(_ path: String, for server: Server) {
        identities[credentialKey(server)] = path
        saveIdentities()
        applyIdentities()
        statusMessage = "\(server.accountTitle) 는 이제 \((path as NSString).lastPathComponent) 키로 접속합니다."
    }

    func saveIdentities() {
        do { try IdentityStore.save(identities) } catch {
            statusMessage = "키 파일 설정 저장 실패: \(error.localizedDescription)"
        }
    }
}
