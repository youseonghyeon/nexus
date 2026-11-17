import Foundation
@testable import ServersCore
import XCTest

/// 브라우저 탭 = 그 서버에서 켠 브라우저: 막는 주소 없이 전부 서버로, 루프백만 별칭으로 바꿔 서버의 루프백으로
final class BrowserPolicyTests: XCTestCase {
    func testRouteSendsEverythingToTheServer() {
        XCTAssertEqual(BrowserPolicy.route(host: "172.21.4.11", port: 9090), .upstream, "서버 IP")
        XCTAssertEqual(BrowserPolicy.route(host: "192.168.112.11", port: 80), .upstream, "다른 내부 서버도 막지 않는다")
        XCTAssertEqual(BrowserPolicy.route(host: "www.example.com", port: 443), .upstream, "이름은 서버가 푼다")
        XCTAssertEqual(BrowserPolicy.route(host: "0:0:0:0:0:0:0:1", port: 9090), .upstream, "중계가 넘기는 IPv6 꼴도 그대로")
        // 루프백 별칭 → 서버의 루프백 (localhost 는 127.0.0.1 로)
        XCTAssertEqual(BrowserPolicy.route(host: "127-0-0-1.server.localhost", port: 9090), .upstreamTo(host: "127.0.0.1"))
        XCTAssertEqual(BrowserPolicy.route(host: "LOCALHOST.server.localhost", port: 3000), .upstreamTo(host: "127.0.0.1"))
        XCTAssertEqual(BrowserPolicy.route(host: "127-0-0-2.server.localhost", port: 80), .upstreamTo(host: "127.0.0.2"))
        // 별칭 꼴이지만 루프백이 아닌 것은 별칭으로 치지 않는다 — 받은 이름 그대로
        XCTAssertEqual(BrowserPolicy.route(host: "10-0-0-1.server.localhost", port: 80), .upstream)
        XCTAssertEqual(BrowserPolicy.route(host: "app.localhost", port: 80), .upstream)
    }

    func testLoopbackURLsOpenAsAliasAndDisplayAsTyped() {
        let rows = [
            ("http://127.0.0.1:9090/login?next=/a#top", "http://127-0-0-1.server.localhost:9090/login?next=/a#top"),
            ("http://localhost:3000/", "http://localhost.server.localhost:3000/"),
            ("https://LOCALHOST/", "https://localhost.server.localhost/"),
            ("ws://127.0.0.2:8080/socket", "ws://127-0-0-2.server.localhost:8080/socket"),
        ]
        for (typed, opened) in rows {
            let url = URL(string: typed)!
            XCTAssertEqual(BrowserPolicy.proxied(url).absoluteString, opened, typed)
            // 주소창은 입력한 주소로 되돌아온다 (호스트는 소문자로)
            XCTAssertEqual(BrowserPolicy.displayed(URL(string: opened)!).absoluteString, typed.replacingOccurrences(of: "LOCALHOST", with: "localhost"), opened)
        }
        // 루프백이 아니면 건드리지 않는다
        for same in ["http://172.21.4.11:9090/", "https://www.example.com/a?b=c", "http://app.localhost:8080/", "http://[::1]:9090/", "about:blank", "data:text/html,hi"] {
            let url = URL(string: same)!
            XCTAssertEqual(BrowserPolicy.proxied(url), url, same)
            XCTAssertEqual(BrowserPolicy.displayed(url), url, same)
        }
        // 두 번 바꿔도 같다
        let once = BrowserPolicy.proxied(URL(string: "http://127.0.0.1:9090/")!)
        XCTAssertEqual(BrowserPolicy.proxied(once), once)
    }

    func testAliasRoundTrip() {
        XCTAssertEqual(BrowserPolicy.alias(forLoopback: "127.0.0.1"), "127-0-0-1.server.localhost")
        XCTAssertEqual(BrowserPolicy.alias(forLoopback: "Localhost"), "localhost.server.localhost")
        XCTAssertNil(BrowserPolicy.alias(forLoopback: "10.0.0.1"))
        XCTAssertEqual(BrowserPolicy.loopback(fromAlias: "127-0-0-1.server.localhost"), "127.0.0.1")
        XCTAssertEqual(BrowserPolicy.loopback(fromAlias: "localhost.server.localhost"), "localhost")
        XCTAssertNil(BrowserPolicy.loopback(fromAlias: "server.localhost"))
        XCTAssertNil(BrowserPolicy.loopback(fromAlias: "127-0-0-256.server.localhost"))
        XCTAssertNil(BrowserPolicy.loopback(fromAlias: "example.com"))
    }

    func testOpenableSchemes() {
        for yes in ["http://a/", "https://a/", "ws://a/", "wss://a/", "about:blank", "data:text/html,hi", "blob:http://a/1"] {
            XCTAssertTrue(BrowserPolicy.isOpenable(URL(string: yes)!), yes)
        }
        for no in ["file:///etc/hosts", "ftp://a/", "ssh://a"] { XCTAssertFalse(BrowserPolicy.isOpenable(URL(string: no)!), no) }
    }

    func testLoopbackDetection() {
        for yes in ["127.0.0.1", "127.0.0.2", "127.1.2.3", "localhost", "LOCALHOST"] { XCTAssertTrue(BrowserPolicy.isLoopback(yes), yes) }
        for no in ["::1", "[::1]", "0:0:0:0:0:0:0:1", "128.0.0.1", "127.0.0", "127.0.0.1.1", "172.21.4.11", "127.a.0.1", "1270.0.0.1", "127.0.0.256", "127.99999999999999999999.0.1", ""] {
            XCTAssertFalse(BrowserPolicy.isLoopback(no), no)
        }
    }
}
