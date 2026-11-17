// 서버 이름 바꾸기: 파일의 머리·참조와, 이름에 묶인 저장 값(비밀번호·키 파일·터널 기록·hosts 주소)이 함께 옮겨 간다. 실제 파일·서버는 건드리지 않는다.

import Foundation
import XCTest
@testable import ServersCore

final class ServerRenameTests: XCTestCase {
    private let text = """
    # 머리 주석
    [group:office]
    theme=on
    db_jump=acme
    db_host=10.9.9.9
    db_port=5432

    # 사무실 장비
    [acme] # 뒤 주석
    group=office
    network=direct
    type=linux
    ip=203.0.113.17
    user=k3s-master
    port=22
    extra_users=manager

    [acme2]
    group=office
    network=direct
    type=linux
    ip=10.0.0.2
    user=root
    port=22

    [win]
    group=office
    network=direct
    type=windows
    ip=10.0.0.3
    user=me
    port=22
    wol_mac=AA:BB:CC:DD:EE:01
    wol_via=acme:br-lan,acme2

    """

    private func renamed(_ new: String = "office") throws -> ServerConfig {
        try ServerConfigParser.parse(try ServerConfigEditor.renaming(key: "acme", to: new, in: text))
    }

    // MARK: 파일

    func testRenameMovesBlockAndKeepsEverythingInIt() throws {
        let config = try renamed()
        XCTAssertNil(config.server("acme"))
        let s = try XCTUnwrap(config.server("office"))
        XCTAssertEqual(s.accounts, ["k3s-master", "manager"])
        XCTAssertEqual(s.ip, "203.0.113.17")
        XCTAssertEqual(config.servers.map(\.key), ["office", "acme2", "win"], "자리도 그대로 (사이드바 순서)")
    }

    func testRenameKeepsCommentsAndOtherLinesCharacterForCharacter() throws {
        let result = try ServerConfigEditor.renaming(key: "acme", to: "office", in: text)
        XCTAssertTrue(result.contains("[office] # 뒤 주석"), result)
        XCTAssertTrue(result.contains("# 머리 주석") && result.contains("# 사무실 장비"))
        // 고칠 곳만 다르다
        let expected = text.replacingOccurrences(of: "[acme] # 뒤 주석", with: "[office] # 뒤 주석")
            .replacingOccurrences(of: "db_jump=acme", with: "db_jump=office")
            .replacingOccurrences(of: "wol_via=acme:br-lan,acme2", with: "wol_via=office:br-lan,acme2")
        XCTAssertEqual(result, expected)
    }

    func testRenameRepointsReferencesButNotLookalikes() throws {
        let config = try renamed()
        XCTAssertEqual(config.settings(for: "office")?.dbJump, "office")
        XCTAssertEqual(config.server("win")?.wolRoutes, [WakeRoute(via: "office", iface: "br-lan"), WakeRoute(via: "acme2")], "이름이 비슷한 acme2 는 그대로")
    }

    func testRenameThereAndBackRestoresFile() throws {
        let there = try ServerConfigEditor.renaming(key: "acme", to: "office", in: text)
        XCTAssertEqual(try ServerConfigEditor.renaming(key: "office", to: "acme", in: there), text)
    }

    func testSameNameChangesNothing() throws {
        XCTAssertEqual(try ServerConfigEditor.renaming(key: "acme", to: "acme", in: text), text)
    }

    func testRenameRejectsBadNames() throws {
        let config = try ServerConfigParser.parse(text)
        for bad in ["acme2", "win", "Office", "1abc", "a-b", "a b", "a@b", "group:office", ""] {
            XCTAssertNotNil(ServerConfigEditor.renameProblem(bad, for: "acme", in: config), bad)
            XCTAssertThrowsError(try ServerConfigEditor.renaming(key: "acme", to: bad, in: text), bad)
        }
        XCTAssertNil(ServerConfigEditor.renameProblem("office_2", for: "acme", in: config))
        XCTAssertNil(ServerConfigEditor.renameProblem("acme", for: "acme", in: config), "그대로면 문제 없음")
        XCTAssertThrowsError(try ServerConfigEditor.renaming(key: "ghost", to: "office", in: text), "없는 서버")
    }

    func testOtherEditAndRenameTogether() throws {
        let original = try XCTUnwrap(try ServerConfigParser.parse(text).server("acme"))
        var edited = NewServer(original)
        edited.role = "사무실"
        let updated = try ServerConfigEditor.updating(edited, notify: false, from: original, in: text)
        let config = try ServerConfigParser.parse(try ServerConfigEditor.renaming(key: "acme", to: "office", in: updated))
        XCTAssertEqual(config.server("office")?.role, "사무실")
    }

    // MARK: 비밀번호·키 파일

    func testCredentialsFollowAllAccountsNotLookalikes() {
        let before = ["acme": "a", "acme@manager": "b", "acme2": "c", "acme2@x": "d", "win": "e"]
        XCTAssertEqual(ServerConfigEditor.renamingCredentials(before, from: "acme", to: "office"),
                       ["office": "a", "office@manager": "b", "acme2": "c", "acme2@x": "d", "win": "e"])
    }

    /// 목록을 다시 읽을 때 옮긴 값이 지워지면 복구할 수 없다.
    func testMovedCredentialsSurviveReloadAndReachTheRightAccount() throws {
        let passwords = ServerConfigEditor.renamingCredentials(["acme@manager": "pw"], from: "acme", to: "office")
        let identities = ServerConfigEditor.renamingCredentials(["acme": "/k/k3s.pem"], from: "acme", to: "office")
        let config = try renamed().applyingIdentities(identities)
        XCTAssertEqual(passwords.filter { config.ownsCredential($0.key) }, passwords)
        XCTAssertEqual(identities.filter { config.ownsCredential($0.key) }, identities)
        let s = try XCTUnwrap(config.server("office"))
        XCTAssertEqual(passwords[s.credentialKey(for: "manager")], "pw")
        XCTAssertEqual(s.identityFile, "/k/k3s.pem", "기본 계정의 키")
        XCTAssertNil(s.account("manager").identityFile)
    }

    /// 파일을 쓰기 전에 새 자리에도 넣어 저장한다 — 쓰다 죽거나 저장이 실패해도 다음 실행의 정리에 값이 사라지지 않게.
    func testStagingKeepsBothUntilReloadPrunes() throws {
        let known = try ServerConfigParser.parse(text)
        let staged = ServerConfigEditor.stagingRename(["acme": "a", "acme@manager": "b", "win": "c"], known: known, onDisk: known, from: "acme", to: "office")
        XCTAssertEqual(staged, ["acme": "a", "acme@manager": "b", "office": "a", "office@manager": "b", "win": "c"], "옛 자리도 남아 파일을 못 썼어도 그대로")
        // 파일을 쓴 뒤 loadConfig 의 정리: 옛 자리만 빠진다
        let after = try renamed()
        XCTAssertEqual(staged.filter { after.ownsCredential($0.key) }, ["office": "a", "office@manager": "b", "win": "c"])
        // 쓰기 전에 죽었으면: 새 자리만 빠지고 옛 값 그대로
        XCTAssertEqual(staged.filter { known.ownsCredential($0.key) }, ["acme": "a", "acme@manager": "b", "win": "c"])
    }

    /// 파일을 직접 고쳐 계정을 맞바꾸고 다시 읽기 전에 이름을 바꿨다 — 접두사만 바꾸면 값이 다른 계정으로 간다.
    func testStagingFollowsAccountsSwappedInFileBeforeRename() throws {
        let known = try ServerConfigParser.parse(text)
        let swapped = text.replacingOccurrences(of: "user=k3s-master\nport=22\nextra_users=manager", with: "user=manager\nport=22\nextra_users=k3s-master")
        let onDisk = try ServerConfigParser.parse(swapped)
        let staged = ServerConfigEditor.stagingRename(["acme": "k3s-pw", "acme@manager": "manager-pw"], known: known, onDisk: onDisk, from: "acme", to: "office")
        let after = try ServerConfigParser.parse(try ServerConfigEditor.renaming(key: "acme", to: "office", in: swapped))
        let kept = staged.filter { after.ownsCredential($0.key) }
        let s = try XCTUnwrap(after.server("office"))
        XCTAssertEqual(kept[s.credentialKey(for: "manager")], "manager-pw")
        XCTAssertEqual(kept[s.credentialKey(for: "k3s-master")], "k3s-pw")
        XCTAssertEqual(kept.count, 2)
    }

    /// 계정별 캐시(원격 홈·업로드 폴더)도 같은 꼴(`키@계정`)이라 같은 함수로 옮긴다.
    func testAccountCachesFollowRename() throws {
        let s = try XCTUnwrap(try ServerConfigParser.parse(text).server("acme"))
        let moved = ServerConfigEditor.renamingCredentials([s.accountID: "/home/k3s", s.accountID(for: "manager"): "/home/m", "acme2@root": "/root"], from: "acme", to: "office")
        let after = try XCTUnwrap(try renamed().server("office"))
        XCTAssertEqual(moved[after.accountID], "/home/k3s")
        XCTAssertEqual(moved[after.accountID(for: "manager")], "/home/m")
        XCTAssertEqual(moved["acme2@root"], "/root")
    }

    /// 이미 저장된 쿠키 저장소 ID 를 그대로 찾아야 한다 (예전 코드가 쓰던 키)
    func testBrowserStoreKeyKeepsExistingFormat() {
        XCTAssertEqual(AppPreferences.browserStoreKey(for: "acme"), "browserStore.acme")
    }

    // MARK: 서버 없는 그룹

    /// 파서의 그룹 목록엔 서버가 있는 그룹만 있다. 안 고치면 나중에 그 그룹에 서버를 넣을 때 "등록되지 않은 서버 키" 로 저장이 막힌다.
    func testRenameFixesDbJumpOfGroupWithoutServers() throws {
        let extra = text + "\n[group:empty]\ndb_jump=acme # 메모\n\n[group:other]\ndb_jump=acme2\n"
        let result = try ServerConfigEditor.renaming(key: "acme", to: "office", in: extra)
        XCTAssertTrue(result.contains("[group:empty]\ndb_jump=office"), result)
        XCTAssertTrue(result.contains("[group:other]\ndb_jump=acme2"), "이름이 비슷한 값은 그대로")
        _ = try ServerConfigParser.parse(result + "\n[new]\ngroup=empty\ntype=linux\nip=1.1.1.1\nuser=a\nport=22\n")
    }

    // MARK: 터널 기록 · hosts 주소

    func testRecentTunnelsFollowRenameWithDefaultHostName() throws {
        let old = try XCTUnwrap(try ServerConfigParser.parse(text).server("acme"))
        let new = try XCTUnwrap(try renamed().server("office"))
        let state = RecentState(tunnels: [
            RecentTunnel(serverKey: "acme", kind: .port(remotePort: 80, remoteHost: "127.0.0.1"), localPort: 80, bindAddress: "127.0.0.2", hostName: "acme.office", user: "manager"),
            RecentTunnel(serverKey: "acme", kind: .port(remotePort: 90, remoteHost: "127.0.0.1"), localPort: 90, bindAddress: "127.0.0.2", hostName: "mine.local"),
            RecentTunnel(serverKey: "acme", kind: .socks, localPort: 1080),
            RecentTunnel(serverKey: "acme2", kind: .socks, localPort: 1081),
        ])
        let after = RecentStore.renamingServer(old, to: new, in: state).tunnels
        XCTAssertEqual(after.map(\.serverKey), ["office", "office", "office", "acme2"])
        XCTAssertEqual(after[0].hostName, "office.office", "기본 이름은 새 이름을 따라간다")
        XCTAssertEqual(after[0].user, "manager", "연 계정 그대로")
        XCTAssertEqual(after[0].bindAddress, "127.0.0.2")
        XCTAssertEqual(after[1].hostName, "mine.local", "직접 지은 이름은 그대로")
        XCTAssertNil(after[2].hostName)
        XCTAssertEqual(after[0].lastUsed, state.tunnels[0].lastUsed)
        XCTAssertEqual(after[0].id, "office|port|127.0.0.1:80", "새 이름으로 같은 터널을 찾는다")
    }

    /// 서버 이름은 밑줄을 받지만 hosts 이름은 안 받는다 — 따라 바꾸면 잘 되던 터널을 다시 못 연다.
    func testDefaultHostNameStaysWhenNewNameIsNotAValidHostName() throws {
        let old = try XCTUnwrap(try ServerConfigParser.parse(text).server("acme"))
        let new = try XCTUnwrap(try renamed("office_2").server("office_2"))
        let state = RecentState(tunnels: [RecentTunnel(serverKey: "acme", kind: .socks, localPort: 80, bindAddress: "127.0.0.2", hostName: "acme.office")])
        let after = RecentStore.renamingServer(old, to: new, in: state).tunnels[0]
        XCTAssertEqual(after.hostName, "acme.office")
        XCTAssertEqual(after.serverKey, "office_2")
        XCTAssertTrue(HostAliasStore.isValidHostName(try XCTUnwrap(after.hostName)))
    }

    func testDBTunnelDefaultHostNameFollowsToo() throws {
        let old = try XCTUnwrap(try ServerConfigParser.parse(text).server("acme"))
        let new = try XCTUnwrap(try renamed().server("office"))
        let kind = TunnelKind.db(host: "10.9.9.9", port: 5432, name: "x")
        let state = RecentState(tunnels: [RecentTunnel(serverKey: "acme", kind: kind, localPort: 5432, bindAddress: "127.0.0.3", hostName: "acme-db.office")])
        XCTAssertEqual(RecentStore.renamingServer(old, to: new, in: state).tunnels[0].hostName, "office-db.office")
    }

    func testHostAliasAddressesFollowRename() {
        let state = HostAliasState(assignments: ["acme": "127.0.0.2", "acme-db": "127.0.0.3", "acme2": "127.0.0.4", "acme2-db": "127.0.0.5"])
        XCTAssertEqual(HostAliasStore.renaming(from: "acme", to: "office", in: state).assignments,
                       ["office": "127.0.0.2", "office-db": "127.0.0.3", "acme2": "127.0.0.4", "acme2-db": "127.0.0.5"])
        XCTAssertEqual(HostAliasStore.renaming(from: "ghost", to: "office", in: state), state, "배정이 없으면 그대로")
    }

    /// 지운 서버가 남긴 배정이 새 이름에 있어도 이 서버의 주소가 이긴다 (이미 그 주소에 hosts·별칭이 있다).
    func testHostAliasKeepsThisServersAddressOverLeftover() {
        let state = HostAliasState(assignments: ["acme": "127.0.0.2", "office": "127.0.0.9"])
        XCTAssertEqual(HostAliasStore.renaming(from: "acme", to: "office", in: state).assignments, ["office": "127.0.0.2"])
    }
}
