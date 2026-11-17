// servers.conf 파싱.

import Foundation
import XCTest
@testable import ServersCore

final class ConfigTests: XCTestCase {
    func testParsesFixture() throws {
        let config = try ServerConfigParser.parse(fixture)
        XCTAssertEqual(config.servers.map(\.key), ["nexus", "win", "ghost", "was"])
        XCTAssertEqual(config.groups, ["home", "acme"])
        let nexus = try XCTUnwrap(config.server("nexus"))
        XCTAssertEqual(nexus.role, "Home server")          // 값 뒤 주석 제거
        XCTAssertEqual(nexus.check, .ssh)                   // linux+tailscale 기본
        XCTAssertEqual(config.server("win")?.check, .tcp)   // windows 기본
        XCTAssertEqual(config.server("was")?.check, .tcp)   // lan 기본
        XCTAssertEqual(config.server("ghost")?.check, .ssh) // 명시
        XCTAssertEqual(config.server("win")?.wolRoutes, [WakeRoute(via: "nexus")])
        XCTAssertEqual(config.lan, LanNetwork(service: "Test Ethernet"), "routes=·wait_*= 는 예전 키라 있어도 무시한다")
        let acme = try XCTUnwrap(config.settings(for: "acme"))
        XCTAssertTrue(acme.theme)
        XCTAssertEqual(acme.dbJump, "was"); XCTAssertEqual(acme.dbPort, 5432); XCTAssertEqual(acme.dbName, "testdb")
        XCTAssertTrue(config.server("was")!.isProd)
    }

    func testCRLFAndNoTrailingNewline() throws {
        let text = "[a]\r\ngroup=g\r\nnetwork=tailscale\r\ntype=linux\r\nip=1.1.1.1\r\nuser=u\r\nport=22"
        XCTAssertEqual(try ServerConfigParser.parse(text).server("a")?.port, 22)
    }

    func testProxyPortIsOptional() throws {
        let base = "[a]\ngroup=g\nnetwork=tailscale\ntype=linux\nip=1.1.1.1\nuser=u\nport=22\n"
        XCTAssertNil(try ServerConfigParser.parse(base).server("a")?.proxyPort)
        XCTAssertEqual(try ServerConfigParser.parse(base + "proxy_port=1080\n").server("a")?.proxyPort, 1080)
        XCTAssertThrowsError(try ServerConfigParser.parse(base + "proxy_port=+1080\n"), "port= 처럼 부호 없는 숫자만")
    }

    func testTunnelPortsList() throws {
        let base = "[a]\ngroup=g\nnetwork=tailscale\ntype=linux\nip=1.1.1.1\nuser=u\nport=22\n"
        XCTAssertEqual(try ServerConfigParser.parse(base).server("a")?.tunnelPorts, [])
        let list = try ServerConfigParser.parse(base + "tunnel_ports=Jenkins:9090, 8080,9090\n").server("a")?.tunnelPorts
        XCTAssertEqual(list, [QuickTunnel(name: "Jenkins", port: 9090), QuickTunnel(name: nil, port: 8080)], "이름:포트 또는 포트만 · 공백 허용 · 중복 제거")
        XCTAssertEqual(list?.map(\.label), ["Jenkins Tunnel", "Tunnel 8080"])
        XCTAssertThrowsError(try ServerConfigParser.parse(base + "tunnel_ports=9090,abc\n"))
        XCTAssertThrowsError(try ServerConfigParser.parse(base + "tunnel_ports=70000\n"))
        XCTAssertThrowsError(try ServerConfigParser.parse(base + "tunnel_ports=:9090\n"), "빈 이름")
        XCTAssertThrowsError(try ServerConfigParser.parse(base + "tunnel_ports=Web:+8080\n"), "port= 처럼 부호 없는 숫자만")
    }

    /// 머리 뒤 주석 · = 양옆 공백 · 값 안의 = (첫 = 에서만 나눈다)
    func testHeaderCommentSpacesAroundEqualsAndEqualsInValue() throws {
        let a = try XCTUnwrap(try ServerConfigParser.parse("[a] # 집 서버\ngroup = g\ntype=linux\nip =1.1.1.1\nuser= u\nport = 22\nrole=k=v 설명\n").server("a"))
        XCTAssertEqual(a.group, "g"); XCTAssertEqual(a.ip, "1.1.1.1"); XCTAssertEqual(a.user, "u"); XCTAssertEqual(a.port, 22)
        XCTAssertEqual(a.role, "k=v 설명")
    }

    func testNotifyFlag() throws {
        let base = "[a]\ngroup=g\nnetwork=tailscale\ntype=linux\nip=1.1.1.1\nuser=u\nport=22\n"
        XCTAssertEqual(try ServerConfigParser.parse(base).server("a")?.notify, false, "기본은 끔")
        XCTAssertEqual(try ServerConfigParser.parse(base + "notify=on\n").server("a")?.notify, true)
        XCTAssertEqual(try ServerConfigParser.parse(base + "notify=off\n").server("a")?.notify, false)
        XCTAssertThrowsError(try ServerConfigParser.parse(base + "notify=yes\n"), "오타는 조용히 꺼 두지 않고 알린다")
    }

    /// Direct(망 설정 없음): network=direct 이거나 network= 줄이 없으면. 확인 방식 기본값은 tcp (내부망과 같다)
    func testDirectNetwork() throws {
        let config = try ServerConfigParser.parse("""
            [a]
            group=g
            network=direct
            type=linux
            ip=10.1.0.20
            user=u
            port=22

            [b]
            group=g
            type=windows
            ip=203.0.113.5
            user=u
            port=22

            [c]
            group=g
            network=
            type=linux
            ip=10.1.0.21
            user=u
            port=22
            """)
        XCTAssertEqual(config.server("a")?.network, .direct)
        XCTAssertEqual(config.server("b")?.network, .direct, "network= 줄이 없으면 망 설정 없음")
        XCTAssertEqual(config.server("c")?.network, .direct, "빈 값도 같다")
        XCTAssertEqual(config.server("a")?.check, .tcp, "Linux 도 tcp — VPN 너머는 비밀번호 서버가 많아 ssh(키 로그인) 확인이 늘 실패한다")
        XCTAssertEqual(config.server("b")?.check, .tcp)
        XCTAssertNil(config.lan, "내부망 설정이 없어도 된다")
    }

    func testErrors() {
        func expect(_ text: String, _ needle: String, line: UInt = #line) {
            XCTAssertThrowsError(try ServerConfigParser.parse(text), "should fail", line: line) { error in
                let d = "\(error)"
                XCTAssertTrue(d.hasPrefix("문제: ") && d.contains("\n해결: ") && d.contains("\n참조: "), d, line: line)
                XCTAssertTrue(d.contains(needle), d, line: line)
            }
        }
        expect("[a]\ngroup=g\nnetwork=tailscale\ntype=linux\nuser=u\nport=22\n", "ip=")
        expect("[a]\ngroup=g\nnetwork=wifi\ntype=linux\nip=1.1.1.1\nuser=u\nport=22\n", "network='wifi'")
        expect("[a]\ngroup=g\nnetwork=wifi\ntype=linux\nip=1.1.1.1\nuser=u\nport=22\n", "direct(망 설정 없음)")
        expect("[a]\ngroup=g\nnetwork=lan\ntype=linux\nip=1.1.1.1\nuser=u\nport=22\n", "[network:lan]")
        expect("[a]\ngroup=g\nnetwork=tailscale\ntype=linux\nip=1.1.1.1\nuser=u\nport=22\nwol_mac=aa\n", "wol_via")
        expect("[a]\ngroup=g\nnetwork=tailscale\ntype=linux\nip=1.1.1.1\nuser=u\nport=22\nwol_mac=zz:zz\nwol_via=a\n", "MAC 주소 형식")
        expect("[a]\ngroup=g\nnetwork=tailscale\ntype=linux\nip=1.1.1.1\nuser=u\nport=22\nwol_mac=AA:BB:CC:DD:EE:FF\nwol_via=a:br-lan;reboot\n", "인터페이스 'br-lan;reboot'")
        expect("[a]\ngroup=g\nnetwork=tailscale\ntype=linux\nip=1.1.1.1\nuser=u\nport=22\nwol_mac=AA:BB:CC:DD:EE:FF\nwol_via=a:\n", "인터페이스 ''")
        expect("[a]\ngroup=g\nnetwork=tailscale\ntype=linux\nip=1.1.1.1\nuser=u\nport=22\nwol_mac=AA:BB:CC:DD:EE:FF\nwol_via=a,ghost\n", "'ghost'는 등록되지 않은")
        expect("[a]\ngroup=g\nnetwork=tailscale\ntype=linux\nip=1.1.1.1\nuser=u\nport=22\nwol_mac=AA:BB:CC:DD:EE:FF\nwol_via=a,,a\n", "''는 등록되지 않은")
        expect("[a]\ngroup=g\nnetwork=tailscale\ntype=linux\nip=1.1.1.1\nuser=u\nport=22\nwol_mac=AA:BB:CC:DD:EE:FF\nwol_via=a:eth0, a\n", "두 번")
        expect("[a]\ngroup=g\nnetwork=tailscale\ntype=linux\nip=1.1.1.1\nuser=u\nport=22\ncheck=ping\n", "check='ping'")
        expect("[a]\ngroup=g\nnetwork=tailscale\ntype=linux\nip=1.1.1.1\nuser=u\nport=99999\n", "port='99999'")
        expect("[group:g]\ndb_port=99999\n[a]\ngroup=g\nnetwork=tailscale\ntype=linux\nip=1.1.1.1\nuser=u\nport=22\n", "db_port='99999'")
        expect("[a]\ngroup=g\nnetwork=tailscale\ntype=linux\nip=1.1.1.1\nuser=u\nport=22\nproxy_port=0\n", "proxy_port='0'")
        expect("[Bad-Key]\n", "'Bad-Key'")
        expect("[a]\ngroup=g\n[a]\n", "두 번")
        expect("group=g\n", "섹션 밖")
    }

    /// 가져온 파일의 ip·user 가 '-' 로 시작하면 ssh 가 옵션으로 읽어 이 Mac 에서 명령이 돈다 — 나머지 형식은 느슨하게 받는다
    func testRejectsOptionLikeIPAndUser() {
        func parse(ip: String = "1.1.1.1", user: String = "u") throws {
            _ = try ServerConfigParser.parse("[a]\ngroup=g\nnetwork=tailscale\ntype=linux\nip=\(ip)\nuser=\(user)\nport=22\n")
        }
        for (ip, user) in [("1.1.1.1", "-oProxyCommand=touch /tmp/x"), ("-oProxyCommand=x", "u"), ("1.1.1.1", "-l")] {
            XCTAssertThrowsError(try parse(ip: ip, user: user), "\(ip) \(user)") { error in
                XCTAssertTrue("\(error)".contains("서버 'a'"), "\(error)")
            }
        }
        XCTAssertNoThrow(try parse(ip: "nexus.tail1234.ts.net", user: "admin@corp"))
    }

    /// 서버가 없는 목록(빈 파일 · 형식 설명만)도 읽힌다
    func testEmptyConfigParses() throws {
        XCTAssertTrue(try ServerConfigParser.parse("").servers.isEmpty)
        XCTAssertTrue(try ServerConfigParser.parse(ConfigLocation.header).servers.isEmpty)
    }

    /// 새 목록은 형식 설명만 — 기본 서버를 넣지 않는다 (공개 배포본에 특정 환경의 주소가 실리지 않게)
    func testTemplateHasNoServers() throws {
        XCTAssertEqual(ConfigLocation.template, ConfigLocation.header)
        XCTAssertFalse(ConfigLocation.template.split(separator: "\n").contains { !$0.hasPrefix("#") }, "주석 아닌 줄이 없다")
    }

    /// 저장소 servers.conf 는 형식을 보여 주는 예시 — 설명한 키들이 실제로 읽히는지 여기서 본다
    func testRepoExampleParses() throws {
        let config = try ServerConfigParser.load(path: TestPaths.repoRoot.appendingPathComponent("servers.conf").path)
        XCTAssertEqual(config.servers.map(\.key), ["web", "was", "jenkins", "router", "homelab", "desktop"])
        XCTAssertEqual(config.groups, ["work", "home"])
        XCTAssertEqual(config.lan?.service, "Office LAN")
        XCTAssertEqual(config.settings(for: "work")?.dbJump, "was")
        XCTAssertTrue(config.server("jenkins")?.isProd == true)
        XCTAssertEqual(config.server("router")?.type, .openwrt)
        XCTAssertEqual(config.server("homelab")?.accounts, ["alice", "deploy"])
        XCTAssertEqual(config.server("desktop")?.wolRoutes.map(\.via), ["router", "homelab"])
    }

    func testWakeRoutesListInOrder() throws {
        let text = "[a]\ngroup=g\nnetwork=tailscale\ntype=linux\nip=1.1.1.1\nuser=u\nport=22\n"
            + "[b]\ngroup=g\nnetwork=direct\ntype=linux\nip=192.168.8.1\nuser=root\nport=22\n"
            + "[w]\ngroup=g\nnetwork=tailscale\ntype=windows\nip=1.1.1.2\nuser=u\nport=22\nwol_mac=AA:BB:CC:DD:EE:FF\nwol_via=b:br-lan , a\n"
        let w = try XCTUnwrap(try ServerConfigParser.parse(text).server("w"))
        XCTAssertEqual(w.wolRoutes, [WakeRoute(via: "b", iface: "br-lan"), WakeRoute(via: "a")], "적은 순서, 공백은 무시")
        XCTAssertEqual(w.wolRoutes.map(\.label), ["b (br-lan)", "a"])
        XCTAssertEqual(w.wolRoutes.map(\.text).joined(separator: ","), "b:br-lan,a")
    }

    // 리뷰 #9: 빈 값은 미설정으로, 포트는 순수 숫자만
    func testEmptyValuesAreUnset() throws {
        let text = """
        [a]
        group=g
        network=tailscale
        type=linux
        ip=1.1.1.1
        user=u
        port=22
        check=
        env=
        wol_mac=
        wol_via=
        """
        let a = try ServerConfigParser.parse(text).server("a")!
        XCTAssertEqual(a.check, .ssh)
        XCTAssertNil(a.env); XCTAssertNil(a.wolMac); XCTAssertEqual(a.wolRoutes, [])
        XCTAssertThrowsError(try ServerConfigParser.parse(text.replacingOccurrences(of: "port=22", with: "port=+22")))
        XCTAssertEqual(try ServerConfigParser.parse(text.replacingOccurrences(of: "port=22", with: "port= 22 ")).server("a")?.port, 22)
    }
}
