// 한 서버의 여러 계정 (extra_users=): 파싱 · 계정 고르기 · 계정별 비밀번호·키 파일 · 편집 · 두 항목 합치기. 실제 파일·서버는 건드리지 않는다.

import Foundation
import XCTest
@testable import ServersCore

final class ServerAccountsTests: XCTestCase {
    /// 같은 장비를 계정별로 두 항목에 등록해 둔 목록 (사용자의 실제 구성과 같은 꼴)
    private let split = """
    # 머리 주석
    [nexus]
    group=home
    network=direct
    type=linux
    ip=192.168.8.103
    user=alice
    port=22

    # 사무실 장비
    [acmeoffice]
    group=office
    network=direct
    type=linux
    ip=203.0.113.17
    user=manager
    port=22

    [acmek3s]
    group=office
    network=direct
    type=linux
    ip=203.0.113.17
    user=k3s-master
    port=22

    """

    private let merged = """
    [acme]
    group=office
    network=direct
    type=linux
    ip=203.0.113.17
    user=manager
    extra_users=k3s-master, deploy
    port=22
    """

    private func server(_ text: String, _ key: String = "acme") throws -> Server {
        try XCTUnwrap(try ServerConfigParser.parse(text).server(key))
    }

    private func problem(_ text: String) -> String? {
        do { _ = try ServerConfigParser.parse(text); return nil } catch { return (error as? ConfigError)?.problem }
    }

    // MARK: 파싱

    func testParsesExtraUsersPrimaryFirst() throws {
        let s = try server(merged)
        XCTAssertEqual(s.accounts, ["manager", "k3s-master", "deploy"])
        XCTAssertEqual(s.primaryUser, "manager")
        XCTAssertEqual(s.user, "manager", "처음엔 기본 계정")
        XCTAssertEqual(s.target, "manager@203.0.113.17")
    }

    func testSingleAccountServerStaysAsBefore() throws {
        let s = try server(split, "nexus")
        XCTAssertEqual(s.accounts, ["alice"])
        XCTAssertEqual(s.credentialKey, "nexus", "계정 하나인 서버의 비밀번호·키 저장 키는 예전과 같다 — 옛 passwords.bin 을 그대로 읽는다")
        XCTAssertEqual(s.accountTitle, "nexus", "탭 이름도 그대로")
    }

    func testRejectsBadExtraUsers() {
        let base = merged.replacingOccurrences(of: "extra_users=k3s-master, deploy", with: "extra_users=%@")
        for (value, expected) in [("manager", "user="), ("a,a", "두 번"), ("-oProxyCommand=x", "'-'")] {
            let message = problem(String(format: base, value))
            XCTAssertNotNil(message, value)
            XCTAssertTrue(message?.contains(expected) == true, "\(value): \(message ?? "")")
        }
    }

    func testEmptyExtraUsersLineMeansNone() throws {
        let s = try server(merged.replacingOccurrences(of: "extra_users=k3s-master, deploy", with: "extra_users="))
        XCTAssertEqual(s.accounts, ["manager"])
    }

    // MARK: 계정 고르기

    func testAccountSwitchesOnlyUserAndCredentials() throws {
        let s = try server(merged)
        let other = s.account("k3s-master")
        XCTAssertEqual(other.target, "k3s-master@203.0.113.17")
        XCTAssertEqual(other.key, "acme", "탭·상태·터널은 같은 서버 키에 그대로")
        XCTAssertEqual(other.primaryUser, "manager")
        XCTAssertEqual(other.credentialKey, "acme@k3s-master")
        XCTAssertEqual(s.credentialKey, "acme", "기본 계정은 서버 키 그대로")
        XCTAssertEqual(other.accountTitle, "acme · k3s-master")
        XCTAssertEqual(s.accountTitle, "acme · manager", "계정이 여럿이면 기본 계정 탭도 어느 계정인지 보인다")
    }

    func testAccountOutsideListIsIgnored() throws {
        let s = try server(merged).account("deploy")
        XCTAssertEqual(s.account("ghost").user, "deploy")
        XCTAssertEqual(s.account(nil).user, "deploy", "기록에 계정이 없는 옛 터널")
    }

    func testApplyingAccounts() throws {
        let config = try ServerConfigParser.parse(merged + "\n\n" + split)
        let applied = config.applyingAccounts(["acme": "deploy", "nexus": "ghost"])
        XCTAssertEqual(applied.server("acme")?.user, "deploy")
        XCTAssertEqual(applied.server("nexus")?.user, "alice", "목록에 없는 계정이면 기본 계정")
        XCTAssertEqual(applied.applyingAccounts([:]).server("acme")?.user, "manager", "선택을 지우면 기본 계정으로 돌아온다")
        XCTAssertEqual(applied.server("acme")?.primaryUser, "manager", "고른 계정이 기본 계정을 바꾸지 않는다")
    }

    func testKeyFileIsPerAccountAndFollowsSwitch() throws {
        let config = try ServerConfigParser.parse(merged).applyingIdentities(["acme@k3s-master": "/k/k3s.pem"])
        let s = try XCTUnwrap(config.server("acme"))
        XCTAssertNil(s.identityFile, "기본 계정엔 등록한 키가 없다")
        XCTAssertEqual(s.account("k3s-master").identityFile, "/k/k3s.pem")
        XCTAssertNil(s.account("deploy").identityFile, "다른 계정의 키를 빌려 쓰지 않는다")
        let selected = config.applyingAccounts(["acme": "k3s-master"]).server("acme")
        XCTAssertEqual(selected?.identityFile, "/k/k3s.pem", "고르는 순서와 무관하게 그 계정의 키")
        XCTAssertNil(config.applyingIdentities([:]).server("acme")?.account("k3s-master").identityFile)
    }

    /// passwords.bin·identities.json 은 목록을 읽을 때 없는 서버의 값을 지운다 — 추가 계정의 값이 여기서 지워지면 복구할 수 없다.
    func testOwnsCredentialKeepsExtraAccountsOnReload() throws {
        let config = try ServerConfigParser.parse(merged)
        XCTAssertTrue(config.ownsCredential("acme"))
        XCTAssertTrue(config.ownsCredential("acme@k3s-master"))
        XCTAssertTrue(config.ownsCredential("acme@deploy"))
        XCTAssertFalse(config.ownsCredential("acme@ghost"), "목록에서 뺀 계정")
        XCTAssertFalse(config.ownsCredential("gone"))
        XCTAssertFalse(config.ownsCredential("gone@manager"))
        XCTAssertTrue(config.applyingAccounts(["acme": "deploy"]).ownsCredential("acme"), "기본 계정의 값은 고른 계정과 무관")
    }

    /// 상태 확인은 고른 계정을 따라가지 않는다 — 키가 없는 계정을 골랐다고 서버가 빨강이 되면 안 된다.
    func testStatusCheckUsesPrimaryAccount() async throws {
        let text = merged.replacingOccurrences(of: "port=22", with: "port=22\ncheck=ssh")
        let config = try ServerConfigParser.parse(text)
            .applyingIdentities(["acme": "/k/manager.pem", "acme@deploy": "/k/deploy.pem"])
            .applyingAccounts(["acme": "deploy"])
        let runner = FakeRunner()
        let monitor = StatusMonitor(config: config, runner: runner, tcpProbe: runner.tcpProbe)
        _ = await monitor.checkRemote(try XCTUnwrap(config.server("acme")))
        let args = try XCTUnwrap(runner.calls.first { $0.executable == "ssh" }).arguments
        XCTAssertTrue(args.contains("manager@203.0.113.17"), "\(args)")
        XCTAssertFalse(args.contains("deploy@203.0.113.17"), "\(args)")
    }

    // MARK: 추가·편집

    func testProblemChecksExtraUsers() {
        func check(_ extras: [String]) -> String? {
            ServerConfigEditor.problem(NewServer(key: "a", group: "a", type: .linux, ip: "1.1.1.1", user: "root", extraUsers: extras))
        }
        XCTAssertNil(check(["k3s-master", "de.ploy_1"]))
        XCTAssertNotNil(check(["bad user"]))
        XCTAssertNotNil(check(["-oProxy"]))
        XCTAssertNotNil(check(["root"]), "기본 계정과 같다")
        XCTAssertNotNil(check(["x", "x"]), "두 번")
    }

    /// 다른 계정을 골라 둔 채 편집 창을 열어도 user= 는 기본 계정 — 고른 계정이 파일에 쓰이면 계정이 뒤섞인다.
    func testEditWhileOtherAccountSelectedKeepsPrimaryUser() throws {
        let selected = try server(merged).account("k3s-master")
        var edited = NewServer(selected)
        XCTAssertEqual(edited.user, "manager")
        XCTAssertEqual(edited.extraUsers, ["k3s-master", "deploy"])
        edited.role = "사무실"
        let text = try ServerConfigEditor.updating(edited, notify: false, from: selected, in: merged)
        XCTAssertTrue(text.contains("user=manager\n"), text)
        XCTAssertTrue(text.contains("extra_users=k3s-master, deploy\n"), "안 바꾼 줄은 글자 그대로")
        XCTAssertFalse(text.contains("user=k3s-master"), text)
        XCTAssertEqual(try server(text).role, "사무실")
    }

    func testEditAddsAndRemovesAccounts() throws {
        let original = try server(split, "acmeoffice")
        var edited = NewServer(original)
        edited.extraUsers = ["k3s-master"]
        let added = try ServerConfigEditor.updating(edited, notify: false, from: original, in: split)
        XCTAssertEqual(try server(added, "acmeoffice").accounts, ["manager", "k3s-master"])

        let now = try server(added, "acmeoffice")
        var removed = NewServer(now)
        removed.extraUsers = []
        let back = try ServerConfigEditor.updating(removed, notify: false, from: now, in: added)
        XCTAssertEqual(back, split, "다 빼면 extra_users 줄이 사라져 원래대로")
    }

    func testEditRejectsNewAccountEqualToPrimary() throws {
        let original = try server(merged)
        var edited = NewServer(original)
        edited.user = "deploy"   // deploy 는 이미 추가 계정
        XCTAssertNotNil(ServerConfigEditor.problem(editing: edited, from: original, in: try ServerConfigParser.parse(merged)))
        edited = NewServer(original)
        edited.extraUsers = ["manager"]
        XCTAssertNotNil(ServerConfigEditor.problem(editing: edited, from: original, in: try ServerConfigParser.parse(merged)))
    }

    func testClearedCredentials() throws {
        let original = try server(merged).account("deploy")
        var edited = NewServer(original)
        XCTAssertEqual(ServerConfigEditor.clearedCredentials(original, edited), [], "역할만 바꾸면 그대로")
        edited.user = "root"
        XCTAssertEqual(ServerConfigEditor.clearedCredentials(original, edited), ["acme"], "사라진 계정(manager)의 값만")
        edited = NewServer(original)
        edited.user = "deploy"; edited.extraUsers = ["manager", "k3s-master"]
        XCTAssertEqual(ServerConfigEditor.clearedCredentials(original, edited), [], "맞바꾸면 계정이 다 남아 있다 — 지우지 않고 옮긴다 (rekeying)")
        edited = NewServer(original)
        edited.user = "root"; edited.extraUsers = ["manager", "k3s-master", "deploy"]
        XCTAssertEqual(ServerConfigEditor.clearedCredentials(original, edited), [], "기본 계정을 추가 계정으로 내려도 값은 남는다")
        edited = NewServer(original)
        edited.extraUsers = ["deploy"]
        XCTAssertEqual(ServerConfigEditor.clearedCredentials(original, edited), ["acme@k3s-master"], "뺀 계정의 값")
        edited = NewServer(original)
        edited.ip = "10.0.0.1"
        XCTAssertEqual(Set(ServerConfigEditor.clearedCredentials(original, edited)), ["acme", "acme@k3s-master", "acme@deploy"],
                       "다른 장비로 옮기면 어느 계정의 비밀번호도 보내지 않는다")
    }

    // MARK: 사용자 칸의 계정 추가·제거·기본 계정

    func testAccountProblem() throws {
        let s = try server(merged)
        XCTAssertNil(ServerConfigEditor.accountProblem("ops.1_a", for: s))
        XCTAssertNotNil(ServerConfigEditor.accountProblem("manager", for: s), "기본 계정")
        XCTAssertNotNil(ServerConfigEditor.accountProblem("deploy", for: s), "이미 있는 계정")
        XCTAssertNotNil(ServerConfigEditor.accountProblem("bad user", for: s))
        XCTAssertNotNil(ServerConfigEditor.accountProblem("-oProxyCommand=x", for: s))
    }

    func testAddAccountToSingleAccountServer() throws {
        let text = try ServerConfigEditor.addingAccount("deploy", to: "nexus", in: split)
        XCTAssertEqual(try server(text, "nexus").accounts, ["alice", "deploy"])
        XCTAssertEqual(try server(text, "acmeoffice").accounts, ["manager"], "다른 서버는 그대로")
        XCTAssertTrue(text.contains("# 머리 주석") && text.contains("# 사무실 장비"))
        XCTAssertThrowsError(try ServerConfigEditor.addingAccount("alice", to: "nexus", in: split), "기본 계정과 같다")
        XCTAssertThrowsError(try ServerConfigEditor.addingAccount("deploy", to: "ghost", in: split))
    }

    func testAddAccountIsUnlimitedAndKeepsOrder() throws {
        var text = split
        for name in ["a", "b", "c", "d", "e"] { text = try ServerConfigEditor.addingAccount(name, to: "nexus", in: text) }
        XCTAssertEqual(try server(text, "nexus").accounts, ["alice", "a", "b", "c", "d", "e"])
    }

    func testRemoveAccount() throws {
        let text = try ServerConfigEditor.removingAccount("k3s-master", from: "acme", in: merged)
        XCTAssertEqual(try server(text).accounts, ["manager", "deploy"])
        XCTAssertThrowsError(try ServerConfigEditor.removingAccount("manager", from: "acme", in: merged), "기본 계정은 뺄 수 없다")
        XCTAssertThrowsError(try ServerConfigEditor.removingAccount("ghost", from: "acme", in: merged))
    }

    /// 넣었다 빼면 파일이 글자까지 원래대로
    func testAddThenRemoveRestoresFile() throws {
        let added = try ServerConfigEditor.addingAccount("deploy", to: "acmeoffice", in: split)
        XCTAssertEqual(try ServerConfigEditor.removingAccount("deploy", from: "acmeoffice", in: added), split)
    }

    func testPromoteSwapsWithPrimaryInPlace() throws {
        let text = try ServerConfigEditor.promotingAccount("deploy", of: "acme", in: merged)
        let s = try server(text)
        XCTAssertEqual(s.primaryUser, "deploy")
        XCTAssertEqual(s.accounts, ["deploy", "k3s-master", "manager"], "옛 기본 계정이 그 자리로")
        XCTAssertThrowsError(try ServerConfigEditor.promotingAccount("manager", of: "acme", in: merged), "이미 기본 계정")
        XCTAssertThrowsError(try ServerConfigEditor.promotingAccount("ghost", of: "acme", in: merged))
    }

    /// 화면에서 하는 순서 그대로: 추가 → 비밀번호 저장 → 기본 계정으로 → 제거. 값은 늘 그 계정을 따라간다.
    func testPasswordsFollowAccountsThroughWholeFlow() throws {
        var text = split, passwords = ["acmeoffice": "manager-pw"], identities = ["acmeoffice": "/k/manager.pem"]
        func apply(_ next: String) throws {
            let old = try ServerConfigParser.parse(text), new = try ServerConfigParser.parse(next)
            passwords = ServerConfigEditor.rekeyingCredentials(passwords, from: old, to: new).filter { new.ownsCredential($0.key) }
            identities = ServerConfigEditor.rekeyingCredentials(identities, from: old, to: new).filter { new.ownsCredential($0.key) }
            text = next
        }
        func password(_ user: String) throws -> String? { passwords[try server(text, "acmeoffice").credentialKey(for: user)] }

        try apply(try ServerConfigEditor.addingAccount("deploy", to: "acmeoffice", in: text))
        passwords[try server(text, "acmeoffice").credentialKey(for: "deploy")] = "deploy-pw"
        XCTAssertEqual(try password("manager"), "manager-pw")
        XCTAssertEqual(try password("deploy"), "deploy-pw")

        try apply(try ServerConfigEditor.promotingAccount("deploy", of: "acmeoffice", in: text))
        XCTAssertEqual(try password("manager"), "manager-pw", "내려간 계정도 자기 비밀번호")
        XCTAssertEqual(try password("deploy"), "deploy-pw", "올라간 계정도 자기 비밀번호")
        XCTAssertEqual(identities["acmeoffice@manager"], "/k/manager.pem")
        XCTAssertNil(try server(text, "acmeoffice").identityFiles["deploy"])

        try apply(try ServerConfigEditor.removingAccount("manager", from: "acmeoffice", in: text))
        XCTAssertNil(try password("manager"))
        XCTAssertEqual(try password("deploy"), "deploy-pw")
        XCTAssertEqual(passwords.count, 1, "뺀 계정의 비밀번호는 남지 않는다")
        XCTAssertEqual(identities, [:])
    }

    /// 열린 탭·터널은 옛 값을 들고 있다 — 기본 계정이 바뀐 뒤 옛 값의 저장 키로 찾으면 다른 계정의 비밀번호를 보낸다 (서버에 fail2ban).
    func testOpenTabResolvesCredentialThroughCurrentConfig() throws {
        let before = try ServerConfigParser.parse(merged)
        let managerTab = try XCTUnwrap(before.server("acme"))
        let deployTab = managerTab.account("deploy")
        let after = try ServerConfigParser.parse(try ServerConfigEditor.promotingAccount("deploy", of: "acme", in: merged))
        XCTAssertEqual(after.credentialKey(of: managerTab), "acme@manager")
        XCTAssertEqual(after.credentialKey(of: deployTab), "acme")
        let removed = try ServerConfigParser.parse(try ServerConfigEditor.removingAccount("deploy", from: "acme", in: merged))
        XCTAssertEqual(removed.credentialKey(of: deployTab), "acme@deploy", "목록에서 빠진 계정은 주인 없는 키 — 다른 계정의 값을 받지 않는다")
        XCTAssertEqual(try ServerConfigParser.parse(split).credentialKey(of: deployTab), "acme@deploy", "서버째 사라져도 옛 값 그대로")
    }

    /// 홈·업로드 폴더 캐시의 키는 기본 계정이 바뀌어도 같은 계정을 가리킨다.
    func testAccountIDIsStableAcrossPromotion() throws {
        let after = try server(try ServerConfigEditor.promotingAccount("deploy", of: "acme", in: merged))
        let before = try server(merged)
        XCTAssertEqual(before.account("deploy").accountID, after.account("deploy").accountID)
        XCTAssertEqual(before.accountID, after.account("manager").accountID)
        XCTAssertNotEqual(before.accountID, after.accountID)
    }

    /// 기본 계정을 바꿔도 같은 장비·같은 계정이다 — 다른 계정으로 연 터널까지 끊으면 안 된다. 사용자를 새 이름으로 바꾸면 다른 연결.
    func testSameConnection() throws {
        let base = try server(merged)
        XCTAssertTrue(try server(try ServerConfigEditor.promotingAccount("deploy", of: "acme", in: merged)).sameConnection(as: base))
        XCTAssertTrue(base.account("deploy").sameConnection(as: base), "고른 계정은 상관없다")
        XCTAssertTrue(try server(try ServerConfigEditor.addingAccount("ops", to: "acme", in: merged)).sameConnection(as: base))
        XCTAssertTrue(try server(try ServerConfigEditor.removingAccount("deploy", from: "acme", in: merged)).sameConnection(as: base))
        XCTAssertFalse(try server(merged.replacingOccurrences(of: "user=manager", with: "user=root")).sameConnection(as: base))
        XCTAssertFalse(try server(merged.replacingOccurrences(of: "ip=203.0.113.17", with: "ip=10.0.0.1")).sameConnection(as: base))
        XCTAssertFalse(try server(merged.replacingOccurrences(of: "port=22", with: "port=2222")).sameConnection(as: base))
    }

    /// [+] 로 막 넣은 계정(오타일 수도)으로 로그인을 시도하면 서버에 실패 기록이 남는다 (fail2ban). 값을 넣으면 그때부터.
    func testAutoFetchWaitsForCredentialsOnExtraAccounts() throws {
        let config = try ServerConfigParser.parse(merged).applyingIdentities(["acme@deploy": "/k/deploy.pem"])
        let s = try XCTUnwrap(config.server("acme"))
        XCTAssertTrue(s.autoFetches(hasPassword: false), "기본 계정은 예전처럼 (기본 키로 될 수 있다)")
        XCTAssertFalse(s.account("k3s-master").autoFetches(hasPassword: false), "비밀번호도 키도 없는 추가 계정")
        XCTAssertTrue(s.account("k3s-master").autoFetches(hasPassword: true))
        XCTAssertTrue(s.account("deploy").autoFetches(hasPassword: false), "키 파일이 있다")
        XCTAssertTrue(try server(split, "nexus").autoFetches(hasPassword: false), "계정 하나인 서버는 그대로")
    }

    /// check=ssh 는 기본 계정의 BatchMode 로그인이라, 키 없는 계정을 올리면 상태가 실패로 바뀔 수 있다 — 확인 창으로 알린다.
    func testPromotionWarnsOnlyWhenStatusCheckMayFail() throws {
        let ssh = merged.replacingOccurrences(of: "port=22", with: "port=22\ncheck=ssh")
        let keyed = try XCTUnwrap(try ServerConfigParser.parse(ssh).applyingIdentities(["acme@deploy": "/k/deploy.pem"]).server("acme"))
        XCTAssertTrue(keyed.statusCheckMayFail(as: "k3s-master"))
        XCTAssertFalse(keyed.statusCheckMayFail(as: "deploy"), "키가 있다")
        XCTAssertFalse(try server(merged).statusCheckMayFail(as: "deploy"), "check=tcp 는 포트만 본다")
        let tailscale = ssh.replacingOccurrences(of: "network=direct", with: "network=tailscale")
        XCTAssertFalse(try server(tailscale).statusCheckMayFail(as: "deploy"), "Tailscale SSH 는 키 없이 로그인된다")
    }

    /// 파서는 받아 주지만 편집 규칙엔 안 맞는 계정(admin@corp) — 편집 창에 고칠 칸이 없으니 그것 때문에 저장이 막히면 안 된다.
    func testEditKeepsLooseExtraUserWithoutBlocking() throws {
        let text = merged.replacingOccurrences(of: "extra_users=k3s-master, deploy", with: "extra_users=admin@corp")
        let config = try ServerConfigParser.parse(text)
        let original = try XCTUnwrap(config.server("acme"))
        var edited = NewServer(original)
        edited.user = "root"
        XCTAssertNil(ServerConfigEditor.problem(editing: edited, from: original, in: config))
        edited.user = "admin@corp"
        XCTAssertNotNil(ServerConfigEditor.problem(editing: edited, from: original, in: config), "user= 형식 검사")
        edited = NewServer(original)
        edited.user = "deploy"; edited.extraUsers = ["deploy"]
        XCTAssertNotNil(ServerConfigEditor.problem(editing: edited, from: original, in: config), "겹침은 여전히 막는다")
    }

    // MARK: 계정 순서가 바뀔 때 — 비밀번호·키 파일이 다른 계정으로 가거나 사라지면 안 된다

    private func rekey(_ values: [String: String], from before: String, to after: String) throws -> [String: String] {
        ServerConfigEditor.rekeyingCredentials(values, from: try ServerConfigParser.parse(before), to: try ServerConfigParser.parse(after))
    }
    private func accounts(user: String, extras: String) -> String {
        merged.replacingOccurrences(of: "user=manager\nextra_users=k3s-master, deploy", with: "user=\(user)\nextra_users=\(extras)")
    }

    func testRekeySwapFollowsAccounts() throws {
        let after = try rekey(["acme": "m", "acme@deploy": "d", "nexus": "x"],
                              from: accounts(user: "manager", extras: "deploy"), to: accounts(user: "deploy", extras: "manager"))
        XCTAssertEqual(after, ["acme": "d", "acme@manager": "m", "nexus": "x"])
    }

    func testRekeyDemotedPrimaryKeepsValue() throws {
        let after = try rekey(["acme": "m"], from: accounts(user: "manager", extras: ""), to: accounts(user: "root", extras: "manager"))
        XCTAssertEqual(after, ["acme@manager": "m"], "새 기본 계정(root)이 manager 의 값을 쓰면 안 된다")
    }

    func testRekeyPromotedExtraReplacesGonePrimary() throws {
        let after = try rekey(["acme": "m", "acme@deploy": "d"], from: accounts(user: "manager", extras: "deploy"), to: accounts(user: "deploy", extras: ""))
        XCTAssertEqual(after, ["acme": "d"])
        let none = try rekey(["acme": "m"], from: accounts(user: "manager", extras: "deploy"), to: accounts(user: "deploy", extras: ""))
        XCTAssertEqual(none, [:], "값이 없던 deploy 가 사라진 manager 의 값을 물려받지 않는다")
    }

    func testRekeyLeavesEverythingElseAlone() throws {
        let values = ["acme": "m", "acme@deploy": "d", "gone": "g"]
        let base = accounts(user: "manager", extras: "deploy")
        XCTAssertEqual(try rekey(values, from: base, to: base), values)
        XCTAssertEqual(try rekey(values, from: base, to: accounts(user: "manager", extras: "deploy, ops")), values, "계정만 더하면 그대로")
        XCTAssertEqual(try rekey(["acme": "m"], from: accounts(user: "manager", extras: ""), to: accounts(user: "root", extras: "")), ["acme": "m"],
                       "계정 하나인 서버의 사용자 변경은 예전과 같다 — 비밀번호는 편집이 clearedCredentials 로 지운다")
        XCTAssertEqual(try rekey(values, from: base, to: split), ["gone": "g", "acme": "m", "acme@deploy": "d"], "사라진 서버는 여기서 건드리지 않는다 (ownsCredential 이 정리)")
    }

    /// 고른 계정과 무관하게 파일의 계정만 본다
    func testRekeyIgnoresSelectedAccount() throws {
        let before = try ServerConfigParser.parse(accounts(user: "manager", extras: "deploy")).applyingAccounts(["acme": "deploy"])
        let after = try ServerConfigParser.parse(accounts(user: "manager", extras: "deploy")).applyingAccounts(["acme": "manager"])
        XCTAssertEqual(ServerConfigEditor.rekeyingCredentials(["acme": "m", "acme@deploy": "d"], from: before, to: after), ["acme": "m", "acme@deploy": "d"])
    }

    // MARK: 두 항목 합치기

    func testMergeTargetsAreSameMachineOnly() throws {
        let config = try ServerConfigParser.parse(split)
        XCTAssertEqual(ServerConfigEditor.accountMergeTargets(for: "acmek3s", in: config).map(\.key), ["acmeoffice"])
        XCTAssertEqual(ServerConfigEditor.accountMergeTargets(for: "acmeoffice", in: config).map(\.key), ["acmek3s"])
        XCTAssertEqual(ServerConfigEditor.accountMergeTargets(for: "nexus", in: config).map(\.key), [], "같은 장비가 없으면 메뉴도 없다")
    }

    func testMergeProblems() throws {
        func problem(editing replace: (String, String)) throws -> String? {
            let config = try ServerConfigParser.parse(split.replacingOccurrences(of: replace.0, with: replace.1))
            return ServerConfigEditor.accountMergeProblem(from: try XCTUnwrap(config.server("acmek3s")), into: try XCTUnwrap(config.server("acmeoffice")))
        }
        XCTAssertNil(try problem(editing: ("zzz", "zzz")))
        XCTAssertNotNil(try problem(editing: ("user=k3s-master", "user=manager")), "같은 계정이면 합칠 게 없다")
        XCTAssertNotNil(try problem(editing: ("user=k3s-master\nport=22", "user=k3s-master\nport=2222")), "포트가 다르면 다른 서비스")
        XCTAssertNotNil(try problem(editing: ("user=k3s-master\nport=22", "user=k3s-master\nport=22\ngroup=other")), "그룹이 다르면 db_jump 가 끊길 수 있다")
        let other = try ServerConfigParser.parse(split)
        XCTAssertNotNil(ServerConfigEditor.accountMergeProblem(from: try XCTUnwrap(other.server("nexus")), into: try XCTUnwrap(other.server("acmeoffice"))), "다른 장비")
    }

    func testMergeMovesAccountAndRemovesBlock() throws {
        let text = try ServerConfigEditor.mergingAccount(from: "acmek3s", into: "acmeoffice", in: split)
        let config = try ServerConfigParser.parse(text)
        XCTAssertNil(config.server("acmek3s"))
        XCTAssertEqual(config.server("acmeoffice")?.accounts, ["manager", "k3s-master"])
        XCTAssertEqual(config.servers.map(\.key), ["nexus", "acmeoffice"])
        XCTAssertTrue(text.contains("# 머리 주석") && text.contains("# 사무실 장비"), "다른 주석은 그대로")
        XCTAssertEqual(text.components(separatedBy: "[acmek3s]").count, 1)
    }

    func testMergeBringsSourceExtrasAndKeepsOrder() throws {
        let source = split.replacingOccurrences(of: "user=k3s-master\n", with: "user=k3s-master\nextra_users=ops\n")
        let target = source.replacingOccurrences(of: "user=manager\n", with: "user=manager\nextra_users=audit\n")
        let text = try ServerConfigEditor.mergingAccount(from: "acmek3s", into: "acmeoffice", in: target)
        XCTAssertEqual(try server(text, "acmeoffice").accounts, ["manager", "audit", "k3s-master", "ops"])
    }

    func testMergeInheritsWhatTargetLacksAndKeepsWhatItHas() throws {
        let text = """
        [gw]
        group=office
        network=direct
        type=linux
        ip=10.0.0.1
        user=root
        port=22

        [a]
        group=office
        network=direct
        type=linux
        ip=10.0.0.2
        user=manager
        port=22
        role=Target role
        tunnel_ports=Web:8080

        [b]
        group=office
        network=direct
        type=linux
        ip=10.0.0.2
        user=k3s
        port=22
        role=Source role
        env=PROD
        notify=on
        proxy_port=1080
        tunnel_ports=Web:8080,K8s:6443
        wol_mac=AA:BB:CC:DD:EE:FF
        wol_via=gw:br-lan
        """
        let s = try server(try ServerConfigEditor.mergingAccount(from: "b", into: "a", in: text), "a")
        XCTAssertEqual(s.role, "Target role", "합쳐 받는 쪽 값 우선")
        XCTAssertEqual(s.env, "PROD", "없으면 가져온다")
        XCTAssertTrue(s.notify)
        XCTAssertEqual(s.proxyPort, 1080)
        XCTAssertEqual(s.tunnelPorts.map(\.port), [8080, 6443])
        XCTAssertEqual(s.wolMac, "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(s.wolRoutes, [WakeRoute(via: "gw", iface: "br-lan")])
    }

    func testMergeUnionsTagsSoProdIsNotLost() throws {
        let tagged = split.replacingOccurrences(of: "user=manager\nport=22", with: "user=manager\nport=22\nenv=internal, DB")
            .replacingOccurrences(of: "user=k3s-master\nport=22", with: "user=k3s-master\nport=22\nenv=PROD, db")
        let s = try server(try ServerConfigEditor.mergingAccount(from: "acmek3s", into: "acmeoffice", in: tagged), "acmeoffice")
        XCTAssertEqual(s.tags, ["internal", "DB", "PROD"], "대소문자만 다른 태그는 한 번")
        XCTAssertTrue(s.isProd)
    }

    func testMergeKeepsCommentsOnUnchangedLines() throws {
        let commented = split.replacingOccurrences(of: "user=manager\nport=22", with: "user=manager\nport=22\ntunnel_ports=Web:8080 # 포털\nproxy_port=1080 # 프록시\nrole=WAS # 역할")
        let text = try ServerConfigEditor.mergingAccount(from: "acmek3s", into: "acmeoffice", in: commented)
        for line in ["tunnel_ports=Web:8080 # 포털", "proxy_port=1080 # 프록시", "role=WAS # 역할"] {
            XCTAssertTrue(text.contains(line), "값이 그대로면 줄도 그대로: \(line)\n\(text)")
        }
    }

    func testMergeRepointsReferences() throws {
        let text = """
        [group:office]
        db_jump=b
        db_host=10.9.9.9
        db_port=5432

        [a]
        group=office
        network=direct
        type=linux
        ip=10.0.0.2
        user=manager
        port=22

        [b]
        group=office
        network=direct
        type=linux
        ip=10.0.0.2
        user=k3s
        port=22

        [w1]
        group=office
        network=direct
        type=windows
        ip=10.0.0.3
        user=me
        port=22
        wol_mac=AA:BB:CC:DD:EE:01
        wol_via=b:br-lan

        [w2]
        group=office
        network=direct
        type=windows
        ip=10.0.0.4
        user=me
        port=22
        wol_mac=AA:BB:CC:DD:EE:02
        wol_via=a,b
        """
        let config = try ServerConfigParser.parse(try ServerConfigEditor.mergingAccount(from: "b", into: "a", in: text))
        XCTAssertEqual(config.settings(for: "office")?.dbJump, "a", "지워지지 않고 합친 서버로")
        XCTAssertEqual(config.server("w1")?.wolRoutes, [WakeRoute(via: "a", iface: "br-lan")])
        XCTAssertEqual(config.server("w2")?.wolRoutes, [WakeRoute(via: "a")], "이미 있으면 두 번 쓰지 않는다")
    }

    /// 서버 없는 그룹의 db_jump 도 합친 서버로 돌린다 (파서의 그룹 목록엔 서버가 있는 그룹만 있다)
    func testMergeRepointsDbJumpOfGroupWithoutServers() throws {
        let text = split + "\n[group:empty]\ndb_jump=acmek3s\n"
        let result = try ServerConfigEditor.mergingAccount(from: "acmek3s", into: "acmeoffice", in: text)
        XCTAssertTrue(result.contains("[group:empty]\ndb_jump=acmeoffice"), result)
    }

    func testMergeDropsRouteThatWouldWakeItself() throws {
        let text = """
        [a]
        group=office
        network=direct
        type=linux
        ip=10.0.0.2
        user=manager
        port=22
        wol_mac=AA:BB:CC:DD:EE:01
        wol_via=b

        [b]
        group=office
        network=direct
        type=linux
        ip=10.0.0.2
        user=k3s
        port=22
        """
        let s = try server(try ServerConfigEditor.mergingAccount(from: "b", into: "a", in: text), "a")
        XCTAssertNil(s.wolMac, "같은 장비가 자기를 깨울 수 없다 — 경로가 다 빠지면 MAC 도")
        XCTAssertEqual(s.wolRoutes, [])
    }

    func testMergeRejectsOtherMachineWithoutChangingText() {
        XCTAssertThrowsError(try ServerConfigEditor.mergingAccount(from: "nexus", into: "acmeoffice", in: split))
        XCTAssertThrowsError(try ServerConfigEditor.mergingAccount(from: "ghost", into: "acmeoffice", in: split))
        XCTAssertThrowsError(try ServerConfigEditor.mergingAccount(from: "acmeoffice", into: "acmeoffice", in: split))
    }

    /// 합친 뒤 비밀번호·키 파일이 새 계정 자리에 있어야 목록을 다시 읽을 때 살아남는다.
    func testMergeCredentialsMoveAndSurviveReload() throws {
        let config = try ServerConfigParser.parse(split)
        let source = try XCTUnwrap(config.server("acmek3s"))
        let before = ["acmek3s": "s3cret", "acmeoffice": "keep", "nexus": "other"]
        let after = ServerConfigEditor.movingCredentials(before, from: source, into: "acmeoffice")
        XCTAssertEqual(after, ["acmeoffice@k3s-master": "s3cret", "acmeoffice": "keep", "nexus": "other"])

        // 파일을 합친 뒤 AppModel.loadConfig 가 하는 그대로
        let reloaded = try ServerConfigParser.parse(try ServerConfigEditor.mergingAccount(from: "acmek3s", into: "acmeoffice", in: split))
        XCTAssertEqual(after.filter { reloaded.ownsCredential($0.key) }, after, "하나도 지워지지 않는다")
        let target = try XCTUnwrap(reloaded.applyingIdentities(ServerConfigEditor.movingCredentials(["acmek3s": "/k/k3s.pem"], from: source, into: "acmeoffice")).server("acmeoffice"))
        XCTAssertEqual(target.account("k3s-master").identityFile, "/k/k3s.pem")
        XCTAssertNil(target.identityFile)
    }

    func testMergeCredentialsMoveSourceExtras() throws {
        let text = split.replacingOccurrences(of: "user=k3s-master\n", with: "user=k3s-master\nextra_users=ops\n")
        let source = try server(text, "acmek3s")
        XCTAssertEqual(ServerConfigEditor.movingCredentials(["acmek3s": "a", "acmek3s@ops": "b"], from: source, into: "acmeoffice"),
                       ["acmeoffice@k3s-master": "a", "acmeoffice@ops": "b"])
        XCTAssertEqual(ServerConfigEditor.movingCredentials(["nexus": "x"], from: source, into: "acmeoffice"), ["nexus": "x"], "값이 없으면 만들지 않는다")
    }

    // MARK: 터널 기록

    func testRecentTunnelRemembersAccountAndReadsOldFiles() throws {
        let old = #"{"serverKey":"acme","kind":{"socks":{}},"localPort":1080,"lastUsed":0}"#
        let decoded = try JSONDecoder().decode(RecentTunnel.self, from: Data(old.utf8))
        XCTAssertNil(decoded.user, "계정 기록이 없는 옛 recent.json")
        let record = RecentTunnel(serverKey: "acme", kind: .socks, localPort: 1080, user: "deploy")
        let back = try JSONDecoder().decode(RecentTunnel.self, from: try JSONEncoder().encode(record))
        XCTAssertEqual(back.user, "deploy")
        XCTAssertEqual(try server(merged).account(back.user).user, "deploy")
    }
}
