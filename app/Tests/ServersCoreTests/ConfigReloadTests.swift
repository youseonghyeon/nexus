// servers.conf 다시 읽기의 분류 (ConfigReloadChanges) 상태 표. 기댓값은 옮기기 전 AppModel.loadConfig 의 갈래에서 적었다:
//   !sameConnection → 접속 바뀜 · sameConnection 인데 user 가 다름 → 계정만 바뀜 · 새 목록에 없음 → 사라짐 · 접속 바뀜·사라짐이 있으면 도는 갱신을 버린다.
// 빈 상태(첫 읽기 · 첫 서버 추가 · 마지막 서버 제거)를 꼭 넣는다.

import Foundation
import XCTest
@testable import ServersCore

final class ConfigReloadTests: XCTestCase {
    private func block(_ key: String, ip: String = "192.0.2.1", port: Int = 22, network: String = "direct", type: String = "linux",
                       user: String = "u", extra: String? = nil, vpn: String? = nil, more: String = "") -> String {
        var lines = ["[\(key)]", "group=g", "network=\(network)", "type=\(type)", "ip=\(ip)", "user=\(user)", "port=\(port)"]
        if let extra { lines.append("extra_users=\(extra)") }
        if let vpn { lines.append("vpn=\(vpn)") }
        if !more.isEmpty { lines.append(more) }
        return lines.joined(separator: "\n") + "\n"
    }

    private func conf(_ blocks: String...) throws -> ServerConfig {
        try ServerConfigParser.parse(blocks.joined(separator: "\n"))
    }

    func testFirstLoadDiscardsNothing() throws {
        let changes = ConfigReloadChanges.between(old: nil, loaded: try conf(block("a")))
        XCTAssertEqual(changes, ConfigReloadChanges())
        XCTAssertFalse(changes.discardsRunningRefresh)
    }

    func testSingleServerChangeTable() throws {
        let base = block("a")
        // (이름, 새 블록, 접속 바뀜, 계정만 바뀜)
        let rows: [(String, String, Bool, Bool)] = [
            ("그대로", base, false, false),
            ("역할·태그만 (접속과 무관)", block("a", more: "role=web\nenv=PROD"), false, false),
            ("주소", block("a", ip: "192.0.2.2"), true, false),
            ("포트", block("a", port: 2222), true, false),
            ("망", block("a", network: "tailscale"), true, false),
            ("종류", block("a", type: "windows"), true, false),
            ("VPN 으로", block("a", network: "vpn", vpn: "MacBook"), true, false),
            ("기본 계정을 다른 계정으로 바꿈 (옛 계정이 목록에서 빠짐)", block("a", user: "root"), true, false),
            ("계정 추가 (옛 기본 계정은 남음)", block("a", extra: "deploy"), false, false),
            ("기본 계정 맞바꿈 (옛 기본 계정이 추가 계정으로 남음)", block("a", user: "deploy", extra: "u"), false, true),
        ]
        for (name, next, connection, account) in rows {
            let old = try conf(base, block("keep"))
            let changes = ConfigReloadChanges.between(old: old, loaded: try conf(next, block("keep")))
            XCTAssertEqual(changes.connectionChanged.map(\.key), connection ? ["a"] : [], name)
            XCTAssertEqual(changes.accountChanged, account ? ["a"] : [], name)
            XCTAssertEqual(changes.removed, [], name)
            XCTAssertEqual(changes.discardsRunningRefresh, connection, "계정만 바뀐 건 도는 갱신을 버리지 않는다 — \(name)")
        }
    }

    func testConnectionChangedKeepsOldValue() throws {
        // 옛 계정별 캐시(원격 홈·업로드 폴더)를 지우려면 옛 값의 계정 목록이 필요하다
        let old = try conf(block("a", extra: "deploy,ops"))
        let changes = ConfigReloadChanges.between(old: old, loaded: try conf(block("a", ip: "192.0.2.9", user: "root")))
        let before = try XCTUnwrap(changes.connectionChanged.first)
        XCTAssertEqual(before.ip, "192.0.2.1")
        XCTAssertEqual(before.accounts, ["u", "deploy", "ops"])
    }

    func testSelectedAccountDroppedIsAccountOnly() throws {
        // 고른 계정(deploy)이 extra_users 에서 빠져 기본 계정으로 돌아왔다 (loaded 는 고른 계정을 적용한 값)
        let selected = ["a": "deploy"]
        let old = try conf(block("a", extra: "deploy")).applyingAccounts(selected)
        XCTAssertEqual(old.server("a")?.user, "deploy", "전제: 고른 계정")
        let loaded = try conf(block("a")).applyingAccounts(selected)
        let changes = ConfigReloadChanges.between(old: old, loaded: loaded)
        XCTAssertEqual(changes.accountChanged, ["a"])
        XCTAssertTrue(changes.connectionChanged.isEmpty)
        XCTAssertFalse(changes.discardsRunningRefresh)
        // 고른 계정이 남아 있으면 바뀐 것 없음
        let kept = ConfigReloadChanges.between(old: old, loaded: try conf(block("a", extra: "deploy,ops")).applyingAccounts(selected))
        XCTAssertEqual(kept, ConfigReloadChanges())
    }

    func testAddAndRemoveTable() throws {
        // 첫 서버 추가 (빈 목록 → 하나): 새로 생긴 서버는 버릴 옛 값이 없다
        let first = ConfigReloadChanges.between(old: try conf(), loaded: try conf(block("a")))
        XCTAssertEqual(first, ConfigReloadChanges())
        XCTAssertFalse(first.discardsRunningRefresh)
        // 서버 하나 더
        XCTAssertEqual(ConfigReloadChanges.between(old: try conf(block("a")), loaded: try conf(block("a"), block("b"))), ConfigReloadChanges())
        // 하나 지움
        let removed = ConfigReloadChanges.between(old: try conf(block("a"), block("b")), loaded: try conf(block("a")))
        XCTAssertEqual(removed.removed, ["b"])
        XCTAssertTrue(removed.discardsRunningRefresh)
        // 마지막 서버를 지움 (목록이 빈다)
        let emptied = ConfigReloadChanges.between(old: try conf(block("a"), block("b")), loaded: try conf())
        XCTAssertEqual(emptied.removed, ["a", "b"], "옛 목록 순서")
        XCTAssertTrue(emptied.connectionChanged.isEmpty)
        // 빈 목록 → 빈 목록
        XCTAssertEqual(ConfigReloadChanges.between(old: try conf(), loaded: try conf()), ConfigReloadChanges())
    }

    func testMixedChangesFollowListOrder() throws {
        let old = try conf(block("a"), block("b", extra: "deploy"), block("c"), block("d"))
        let loaded = try conf(block("d", ip: "192.0.2.4"), block("b", user: "deploy", extra: "u"), block("a", port: 2200), block("e"))
        let changes = ConfigReloadChanges.between(old: old, loaded: loaded)
        XCTAssertEqual(changes.connectionChanged.map(\.key), ["d", "a"], "새 목록 순서")
        XCTAssertEqual(changes.accountChanged, ["b"])
        XCTAssertEqual(changes.removed, ["c"])
        XCTAssertTrue(changes.discardsRunningRefresh)
    }
}
