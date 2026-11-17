import Foundation
@testable import ServersCore
import XCTest

final class ChromeProxyTests: XCTestCase {
    func testArguments() {
        let args = ChromeProxy.arguments(proxyPort: 1080, profileDir: "/tmp/p")
        XCTAssertEqual(args[0], "--proxy-server=socks5://127.0.0.1:1080", "socks5 스킴이라 이름 풀이도 프록시 쪽")
        XCTAssertFalse(args.contains { $0.hasPrefix("--host-resolver-rules") }, "Chrome 이 '지원되지 않는 플래그' 배너를 띄우는 플래그는 쓰지 않는다")
        XCTAssertTrue(args.contains("--user-data-dir=/tmp/p"), "별도 프로필이 없으면 떠 있는 Chrome 이 인자를 무시한다")
        XCTAssertTrue(args.contains("--no-first-run"))
    }

    func testProfileDirIsPerServer() {
        let base = URL(fileURLWithPath: "/base")
        XCTAssertEqual(ChromeProxy.profileDir(serverKey: "nexus", base: base).path, "/base/chrome-proxy/nexus")
        XCTAssertNotEqual(ChromeProxy.profileDir(serverKey: "nexus", base: base), ChromeProxy.profileDir(serverKey: "web", base: base))
    }
}
