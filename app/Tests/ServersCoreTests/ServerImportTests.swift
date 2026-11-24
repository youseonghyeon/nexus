// 서버 목록 가져오기: 없는 서버만 붙이고(있는 키는 건너뜀), 그 서버들의 그룹 설정·내부망 설정은 없을 때만.

import Foundation
@testable import ServersCore
import XCTest

final class ServerImportTests: XCTestCase {
    private let mine = """
        # 내 목록

        [web]
        group=acme
        network=direct
        type=linux
        ip=10.0.0.1
        user=me
        port=22
        """

    private let theirs = """
        # 팀 목록 (머리 주석은 가져오지 않는다)

        [network:lan]
        service=Acme Intranet
        wait_attempts=40

        [group:acme]
        theme=on
        db_jump=was

        [web]
        group=acme
        network=lan
        type=linux
        ip=192.168.111.11
        user=manager
        port=22

        # was 위 주석
        [was]
        group=acme
        network=lan
        type=linux
        ip=192.168.112.11
        user=manager
        port=22
        role=WAS server   # 뒤 주석은 그대로

        [nexus]
        group=home
        network=tailscale
        type=linux
        ip=100.101.0.1
        user=me
        port=22
        """

    func testMergeAddsOnlyMissing() throws {
        let merge = try ServerConfigEditor.merging(theirs, into: mine)
        XCTAssertEqual(merge.added, ["was", "nexus"])
        XCTAssertEqual(merge.skipped, ["web"])
        let config = try ServerConfigParser.parse(merge.text)
        XCTAssertEqual(config.server("web")?.ip, "10.0.0.1", "있는 서버는 그대로")
        XCTAssertEqual(config.server("was")?.role, "WAS server")
        XCTAssertEqual(config.lan?.service, "Acme Intranet", "내부망 설정이 없었으니 가져온다")
        XCTAssertEqual(config.settings(for: "acme")?.dbJump, "was")
        XCTAssertTrue(merge.text.hasPrefix(mine), "내 파일은 앞에 그대로")
        XCTAssertFalse(merge.text.contains("팀 목록"))
        XCTAssertFalse(merge.text.contains("was 위 주석"))
        XCTAssertTrue(merge.text.contains("role=WAS server   # 뒤 주석은 그대로"))
    }

    func testMergeKeepsMyGroupAndLan() throws {
        let withSettings = mine + "\n\n[network:lan]\nservice=Mine\n\n[group:acme]\ndb_name=mine\n"
        let merge = try ServerConfigEditor.merging(theirs, into: withSettings)
        let config = try ServerConfigParser.parse(merge.text)
        XCTAssertEqual(config.lan?.service, "Mine")
        XCTAssertEqual(config.settings(for: "acme")?.dbName, "mine")
        XCTAssertEqual(merge.text.components(separatedBy: "[group:acme]").count, 2, "그룹 블록이 둘이 되지 않는다")
    }

    func testMergeNothingNewAndBadFile() throws {
        let same = try ServerConfigEditor.merging(mine, into: mine)
        XCTAssertEqual(same, .init(text: mine, added: [], skipped: ["web"]))
        XCTAssertThrowsError(try ServerConfigEditor.merging("[Bad Key]\n", into: mine)) { error in
            XCTAssertEqual((error as? ConfigError)?.reference, "가져온 파일")
        }
        // 빈 목록(새 사용자)에 전부
        let fresh = try ServerConfigEditor.merging(theirs, into: ConfigLocation.header)
        XCTAssertEqual(fresh.added, ["web", "was", "nexus"])
    }
}
