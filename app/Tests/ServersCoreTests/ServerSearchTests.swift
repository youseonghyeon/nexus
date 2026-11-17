// ServerSearch(사이드바 검색): 서버는 이름·IP·역할·태그·그룹, 터널·전송 행은 보이는 글자.

import XCTest
@testable import ServersCore

final class ServerSearchTests: XCTestCase {
    func testServerSearch() throws {
        let config = try ServerConfigParser.parse("""
        [jenkins]
        group=acme
        network=tailscale
        type=linux
        ip=172.21.4.11
        user=u
        port=22
        role=CI/CD
        env=PROD, DB
        """)
        let jenkins = try XCTUnwrap(config.server("jenkins"))
        for query in ["", "jen", "JEN", "172.21", "ci/cd", "prod", "db", "acme", "  jenkins "] {
            XCTAssertTrue(ServerSearch.matches(jenkins, query), query)
        }
        XCTAssertFalse(ServerSearch.matches(jenkins, "nexus"))
        XCTAssertTrue(ServerSearch.matches("db.acme:5432 → was", "DB.ACME"))
        XCTAssertFalse(ServerSearch.matches("db.acme:5432 → was", "nexus"))
    }
}
