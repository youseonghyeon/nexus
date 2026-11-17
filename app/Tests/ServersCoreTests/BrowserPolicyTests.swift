import Foundation
@testable import ServersCore
import XCTest

final class BrowserPolicyTests: XCTestCase {
    private let scope = BrowserScope(serverIP: "172.21.4.11", loopbackNameAddresses: ["Jenkins.acme": "127.0.0.2"])

    func testRouteDecidesUpstreamDirectOrDeny() {
        XCTAssertEqual(BrowserPolicy.route(host: "172.21.4.11", port: 9090, scope: scope), .upstream, "서버 IP 는 ssh -D 로")
        XCTAssertEqual(BrowserPolicy.route(host: "JENKINS.acme", port: 9090, scope: scope), .direct(host: "127.0.0.2", port: 9090), "터널 이름은 앱이 직접 푼다")
        XCTAssertEqual(BrowserPolicy.route(host: "127.0.0.2", port: 9090, scope: scope), .direct(host: "127.0.0.2", port: 9090))
        XCTAssertEqual(BrowserPolicy.route(host: "localhost", port: 15432, scope: scope), .direct(host: "127.0.0.1", port: 15432))
        XCTAssertEqual(BrowserPolicy.route(host: "192.168.112.11", port: 80, scope: scope), .deny)
        XCTAssertEqual(BrowserPolicy.route(host: "www.google.com", port: 443, scope: scope), .deny)
        XCTAssertEqual(BrowserPolicy.route(host: "db.acme", port: 5432, scope: scope), .deny, "다른 서버의 터널 이름")
    }

    func testAllowedHostsAreServerIPAndLoopbackOnly() {
        XCTAssertTrue(BrowserPolicy.isAllowed(URL(string: "http://172.21.4.11:9090/login")!, scope: scope))
        XCTAssertTrue(BrowserPolicy.isAllowed(URL(string: "http://172.21.4.11/")!, scope: scope), "포트 무관")
        XCTAssertTrue(BrowserPolicy.isAllowed(URL(string: "https://172.21.4.11:8443/")!, scope: scope))
        XCTAssertTrue(BrowserPolicy.isAllowed(URL(string: "ws://172.21.4.11:9090/wsagents/")!, scope: scope), "웹소켓")
        XCTAssertTrue(BrowserPolicy.isAllowed(URL(string: "http://127.0.0.2:9090/")!, scope: scope), "루프백(터널 리스너)은 예외")
        XCTAssertTrue(BrowserPolicy.isAllowed(URL(string: "http://localhost:15432/")!, scope: scope))
        XCTAssertTrue(BrowserPolicy.isAllowed(URL(string: "http://JENKINS.acme:9090/")!, scope: scope), "그 서버의 터널 이름 (대소문자 무시)")
        XCTAssertTrue(BrowserPolicy.isAllowed(URL(string: "about:blank")!, scope: scope))
        XCTAssertTrue(BrowserPolicy.isAllowed(URL(string: "data:text/html,hi")!, scope: scope))

        XCTAssertFalse(BrowserPolicy.isAllowed(URL(string: "http://192.168.112.11/")!, scope: scope), "다른 내부 서버")
        XCTAssertFalse(BrowserPolicy.isAllowed(URL(string: "https://www.google.com/")!, scope: scope), "인터넷")
        XCTAssertFalse(BrowserPolicy.isAllowed(URL(string: "http://db.acme:5432/")!, scope: scope), "다른 서버의 터널 이름")
        XCTAssertFalse(BrowserPolicy.isAllowed(URL(string: "http://127.0.0.256/")!, scope: scope))
        XCTAssertFalse(BrowserPolicy.isAllowed(URL(string: "file:///etc/hosts")!, scope: scope))
    }

    /// IPv6 루프백은 페이지 이동(isAllowed)과 중계(route)가 같은 답 — 예전엔 이동은 허용되고 중계가 거절했다
    func testIPv6LoopbackIsDeniedConsistently() {
        XCTAssertFalse(BrowserPolicy.isAllowed(URL(string: "http://[::1]:9090/")!, scope: scope))
        XCTAssertEqual(BrowserPolicy.route(host: "::1", port: 9090, scope: scope), .deny)
        XCTAssertEqual(BrowserPolicy.route(host: "0:0:0:0:0:0:0:1", port: 9090, scope: scope), .deny, "중계가 넘기는 IPv6 꼴")
    }

    /// 대소문자만 다른 터널 이름 둘이 와도 죽지 않는다 (예전 uniqueKeysWithValues 는 크래시)
    func testScopeToleratesNamesDifferingOnlyInCase() {
        let both = BrowserScope(serverIP: "172.21.4.11", loopbackNameAddresses: ["Jenkins.acme": "127.0.0.2", "jenkins.acme": "127.0.0.2"])
        XCTAssertEqual(both.loopbackNames, ["jenkins.acme"])
        XCTAssertEqual(BrowserPolicy.route(host: "jenkins.acme", port: 9090, scope: both), .direct(host: "127.0.0.2", port: 9090))
    }

    func testLoopbackDetection() {
        for yes in ["127.0.0.1", "127.0.0.2", "127.1.2.3", "localhost", "LOCALHOST"] { XCTAssertTrue(BrowserPolicy.isLoopback(yes), yes) }
        for no in ["::1", "[::1]", "0:0:0:0:0:0:0:1", "128.0.0.1", "127.0.0", "127.0.0.1.1", "172.21.4.11", "127.a.0.1", "1270.0.0.1", "127.0.0.256", "127.99999999999999999999.0.1", "127.٣.0.1", "127.+1.0.1"] { XCTAssertFalse(BrowserPolicy.isLoopback(no), no) }
    }

    func testStartURLIsTheFirstTunnelLocalAddress() {
        let was = try! ServerConfigParser.parse(fixture).server("was")!
        let named = TunnelSpec(server: was, kind: .port(remotePort: 9090), localPort: 9090, bindAddress: "127.0.0.2", hostName: "jenkins.acme")
        XCTAssertEqual(BrowserPolicy.startURL(firstTunnel: named)?.absoluteString, "http://jenkins.acme:9090/", "서버 이름 터널은 그 이름으로")
        let plain = TunnelSpec(server: was, kind: .port(remotePort: 9090), localPort: 19090)
        XCTAssertEqual(BrowserPolicy.startURL(firstTunnel: plain)?.absoluteString, "http://localhost:19090/")
        XCTAssertNil(BrowserPolicy.startURL(firstTunnel: nil), "터널이 없으면 빈 탭 — 서버 IP 로 시작하지 않는다")
        XCTAssertNil(BrowserPolicy.startURL(firstTunnel: TunnelSpec(server: was, kind: .socks, localPort: 1080)), "proxy 터널은 웹 주소가 아니다")
        XCTAssertNil(BrowserPolicy.startURL(firstTunnel: TunnelSpec(server: was, kind: .db(host: "h", port: 5432, name: nil), localPort: 15432)), "DB 터널도 웹 주소가 아니다")
    }

    func testContentRules() throws {
        let json = BrowserPolicy.contentRulesJSON(scope: scope)
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        XCTAssertEqual((rules[0]["action"] as? [String: Any])?["type"] as? String, "block", "첫 규칙은 전부 차단")
        let filters = rules.dropFirst().compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
        XCTAssertTrue(filters.contains("^https?://172\\.21\\.4\\.11:[0-9]+/"), filters.joined(separator: " "))
        XCTAssertTrue(filters.contains("^https?://172\\.21\\.4\\.11/"))
        XCTAssertTrue(filters.contains("^wss?://127\\.[0-9]+\\.[0-9]+\\.[0-9]+:[0-9]+/"), "루프백 대역")
        XCTAssertTrue(filters.contains("^https?://jenkins\\.acme:[0-9]+/"))
        XCTAssertTrue(rules.dropFirst().allSatisfy { ($0["action"] as? [String: Any])?["type"] as? String == "ignore-previous-rules" })
        XCTAssertFalse(filters.contains { $0.contains("|") || $0.contains("{") }, "WebKit url-filter 가 지원하지 않는 문법은 쓰지 않는다")
    }
}
