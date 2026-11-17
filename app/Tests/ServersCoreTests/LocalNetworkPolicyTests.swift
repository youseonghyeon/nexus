import Foundation
@testable import ServersCore
import XCTest

/// this Mac 화면에 더한 값: 방화벽(Ports 카드) · 시스템 프록시(Address) · 도메인별 DNS(Hosts) · 모델(Spec)
final class LocalNetworkPolicyTests: XCTestCase {
    /// 이 Mac 실제 출력(2026-11-01): 켜짐 · Stealth 꺼짐 · 모두 차단 꺼짐 → "켜짐"
    func testFirewallRealOutput() {
        let state = FirewallState.parse(global: "Firewall is enabled. (State = 1)\n", stealth: "Firewall stealth mode is off\n",
                                        blockAll: "Firewall has block all state set to disabled.\n")
        XCTAssertEqual(state, FirewallState(enabled: true))
        XCTAssertEqual(state?.text, "켜짐")
    }

    /// Stealth·모두 차단은 켜져 있을 때만 붙고, 꺼져 있으면 "꺼짐" 하나. State = 2 도 모두 차단. 못 읽으면 nil
    func testFirewallVariants() {
        XCTAssertEqual(FirewallState.parse(global: "Firewall is enabled. (State = 1)", stealth: "Firewall stealth mode is on",
                                           blockAll: "Firewall has block all state set to enabled.")?.text, "켜짐 · Stealth · 들어오는 연결 모두 차단")
        XCTAssertEqual(FirewallState.parse(global: "Firewall is blocking all non-essential incoming connections. (State = 2)", stealth: "", blockAll: "")?.blockAll, true)
        XCTAssertEqual(FirewallState.parse(global: "Firewall is disabled. (State = 0)", stealth: "Firewall stealth mode is on", blockAll: "")?.text, "꺼짐")
        XCTAssertNil(FirewallState.parse(global: "", stealth: "", blockAll: ""))
    }

    /// 이 Mac 실제 출력(프록시 없음: FTPPassive 만) → 빈 배열 (줄 숨김)
    func testProxyNoneOnRealOutput() {
        XCTAssertEqual(SystemProxy.parse("<dictionary> {\n  FTPPassive : 1\n}\n"), [])
        XCTAssertEqual(SystemProxy.parse(""), [])
    }

    /// 켜진 것만, 꺼진(Enable 0) 값·주소 없는 것은 뺀다. __SCOPED__ 안의 값은 읽지 않는다
    func testProxyEnabledOnly() {
        let text = """
        <dictionary> {
          ExceptionsList : <array> {
            0 : *.local
          }
          HTTPEnable : 1
          HTTPPort : 8080
          HTTPProxy : 10.0.0.1
          HTTPSEnable : 0
          HTTPSPort : 8443
          HTTPSProxy : 10.0.0.1
          ProxyAutoConfigEnable : 1
          ProxyAutoConfigURLString : http://wpad/proxy.pac
          ProxyAutoDiscoveryEnable : 1
          SOCKSEnable : 1
          SOCKSProxy :
          __SCOPED__ : <dictionary> {
            en0 : <dictionary> {
              HTTPSEnable : 1
              HTTPSProxy : 9.9.9.9
            }
          }
        }
        """
        XCTAssertEqual(SystemProxy.parse(text), ["HTTP 10.0.0.1:8080", "PAC http://wpad/proxy.pac", "자동 탐지 (WPAD)"])
    }

    /// 도메인별 DNS: 도메인이 있고 이름 서버가 있는 일반 리졸버만 (mDNS local·arpa 는 이름 서버가 없어 빠진다). 기본 리졸버는 그대로
    func testDomainResolvers() {
        let text = """
        DNS configuration

        resolver #1
          nameserver[0] : 10.1.0.1
          if_index : 26 (utun6)
          flags    : Supplemental, Request A records

        resolver #2
          nameserver[0] : 10.1.0.1
          if_index : 26 (utun6)
          flags    : Request A records

        resolver #3
          domain   : local
          options  : mdns

        resolver #4
          domain   : corp.example
          nameserver[0] : 10.20.0.53
          nameserver[1] : 10.20.0.54
          if_index : 26 (utun6)

        resolver #5
          domain   : home.arpa
          nameserver[0] : 192.168.8.1

        DNS configuration (for scoped queries)

        resolver #1
          domain   : scoped.example
          nameserver[0] : 1.1.1.1
          if_index : 14 (en0)
        """
        let config = DNSConfig.parse(text)
        XCTAssertEqual(config.domainResolvers.map(\.domain), ["corp.example", "home.arpa"])
        XCTAssertEqual(config.domainResolvers.first?.nameservers, ["10.20.0.53", "10.20.0.54"])
        XCTAssertEqual(config.domainResolvers.map(\.device), ["utun6", nil])
        XCTAssertEqual(config.primary?.nameservers, ["10.1.0.1"])
    }

    /// Mac 모델 줄 "|MacBook Pro (Mac16,1)" → Spec "모델 MacBook Pro (Mac16,1)" (제조사 칸이 비어 그대로)
    func testMacModelSpec() {
        let items = RemoteInfo.parseSpec(["HOSTNAME     mac", "MODEL        |MacBook Pro (Mac16,1)"])
        XCTAssertEqual(items.first { $0.key == "MODEL" }?.value, "MacBook Pro (Mac16,1)")
        XCTAssertEqual(items.first { $0.key == "MODEL" }?.label, "모델")
    }

    /// fetch: 전체 상태를 못 읽으면 nil, 프록시를 못 읽으면 빈 배열
    func testFetchFailures() async {
        final class Runner: CommandRunner, @unchecked Sendable {
            func hasExecutable(_ name: String) -> Bool { true }
            func run(_ executable: String, _ arguments: [String], stdin: String?, environment: [String: String], timeout: TimeInterval) async -> CommandResult {
                CommandResult(exitCode: 1)
            }
        }
        let firewall = await FirewallState.fetch(runner: Runner())
        XCTAssertNil(firewall)
        let proxies = await SystemProxy.fetch(runner: Runner())
        XCTAssertEqual(proxies, [])
    }
}
