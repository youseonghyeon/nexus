// DNS: scutil --dns 파싱 — 장치별(scoped) 값과 이 Mac 이 실제로 쓰는 값

import XCTest
@testable import ServersCore

final class DNSConfigTests: XCTestCase {
    /// 이 Mac 에서 실제로 받은 scutil --dns (2026-10-14, 유선 en11 + Wi-Fi en0, mDNS 리졸버 일부 생략)
    let text = """
    DNS configuration

    resolver #1
      search domain[0] : tail1234.ts.net
      nameserver[0] : 192.168.8.1
      if_index : 28 (en11)
      flags    : Request A records
      reach    : 0x00020002 (Reachable,Directly Reachable Address)

    resolver #2
      domain   : local
      options  : mdns
      timeout  : 5
      flags    : Request A records
      reach    : 0x00000000 (Not Reachable)
      order    : 300000

    resolver #3
      domain   : 254.169.in-addr.arpa
      options  : mdns
      timeout  : 5
      flags    : Request A records
      reach    : 0x00000000 (Not Reachable)
      order    : 300200

    DNS configuration (for scoped queries)

    resolver #1
      search domain[0] : tail1234.ts.net
      nameserver[0] : 192.168.8.1
      if_index : 28 (en11)
      flags    : Scoped, Request A records
      reach    : 0x00020002 (Reachable,Directly Reachable Address)

    resolver #2
      nameserver[0] : 168.126.63.1
      nameserver[1] : 168.126.63.2
      if_index : 15 (en0)
      flags    : Scoped, Request A records
      reach    : 0x00000002 (Reachable)
    """

    func testScopedPerDevice() {
        let config = DNSConfig.parse(text)
        XCTAssertEqual(config.scoped["en0"]?.nameserverText, "168.126.63.1, 168.126.63.2")
        XCTAssertNil(config.scoped["en0"]?.searchDomainText)
        XCTAssertEqual(config.scoped["en11"]?.nameserverText, "192.168.8.1")
        XCTAssertEqual(config.scoped["en11"]?.searchDomainText, "tail1234.ts.net")
        XCTAssertNil(config.scoped["en8"], "안 꽂힌 장치는 없다")
    }

    func testPrimaryIsFirstGeneralResolverWithServers() {
        let config = DNSConfig.parse(text)
        XCTAssertEqual(config.primary?.nameserverText, "192.168.8.1")
        XCTAssertEqual(config.primary?.device, "en11")
        // 첫 리졸버가 도메인 한정(mDNS)이면 건너뛴다
        let mdnsFirst = """
        DNS configuration

        resolver #1
          domain   : local
          options  : mdns

        resolver #2
          nameserver[0] : 1.1.1.1
        """
        XCTAssertEqual(DNSConfig.parse(mdnsFirst).primary?.nameserverText, "1.1.1.1")
    }

    func testEmptyOrFailed() {
        // 망이 없을 때 scutil 은 "No DNS configuration available" 만 낸다
        let none = DNSConfig.parse("No DNS configuration available\n")
        XCTAssertNil(none.primary)
        XCTAssertTrue(none.scoped.isEmpty)
        XCTAssertNil(DNSConfig.parse("").primary)
    }

    func testFetchRunsScutilOnly() async {
        let runner = FakeRunner()
        runner.scripted["scutil --dns"] = CommandResult(exitCode: 0, stdout: text)
        let config = await DNSConfig.fetch(runner: runner)
        XCTAssertEqual(config.scoped["en0"]?.nameservers.count, 2)
        XCTAssertEqual(runner.calls.map(\.executable), ["scutil"])
    }
}
