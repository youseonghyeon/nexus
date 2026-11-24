// servers.conf 파서를 나눠도 그대로여야 하는 것을 고정한다: 문제가 여럿일 때 먼저 알리는 순서와 그 문구(사용자에게 보이는 글),
// 파서와 편집기가 같이 따르는 줄 문법(뒤 주석 · 머리 줄 · 주석 줄 · 쓸 수 없는 글자).

import Foundation
import XCTest
@testable import ServersCore

final class ConfigPinTests: XCTestCase {
    private func problem(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        do {
            _ = try ServerConfigParser.parse(text, reference: "t.conf")
            return nil
        } catch let error as ConfigError {
            XCTAssertEqual(error.reference, "t.conf", file: file, line: line)
            return error.problem
        } catch {
            XCTFail("\(error)", file: file, line: line)
            return nil
        }
    }

    /// 한 블록에 문제를 전부 넣고 하나씩 고쳐 가며, 그때마다 알리는 문제가 정해진 순서로 넘어가는지 본다
    func testServerErrorsAreReportedInOrder() {
        var fields: [(String, String)] = [("network", "bogus"), ("extra_users", "-x"), ("check", "bogus"), ("wol_mac", "ZZ"), ("proxy_port", "0"),
                                          ("tunnel_ports", "x"), ("notify", "maybe"), ("vpn", "office")]
        var tail = "[group:g]\ndb_port=0\ndb_local=x\ndb_jump=nope\n"
        func set(_ name: String, _ value: String?) {
            fields.removeAll { $0.0 == name }
            if let value { fields.append((name, value)) }
        }
        func text() -> String { "[a]\n" + fields.map { "\($0.0)=\($0.1)\n" }.joined() + tail }
        let steps: [(expected: String, fix: () -> Void)] = [
            ("서버 'a'에 group= 가 없습니다.", { set("group", "g") }),
            ("서버 'a'에 type= 가 없습니다.", { set("type", "bogus") }),
            ("서버 'a'에 ip= 가 없습니다.", { set("ip", "-1") }),
            ("서버 'a'에 user= 가 없습니다.", { set("user", "-u") }),
            ("서버 'a'에 port= 가 없습니다.", { set("port", "0") }),
            ("서버 'a'의 network='bogus'는 지원하지 않습니다.", { set("network", "lan") }),
            ("서버 'a'의 type='bogus'는 지원하지 않습니다.", { set("type", "linux") }),
            ("서버 'a'의 ip='-1'는 '-' 로 시작해 쓸 수 없습니다.", { set("ip", "192.0.2.1") }),
            ("서버 'a'의 user='-u'는 '-' 로 시작해 쓸 수 없습니다.", { set("user", "u") }),
            ("서버 'a'의 extra_users= 의 '-x'는 '-' 로 시작해 쓸 수 없습니다.", { set("extra_users", "v, u") }),
            ("서버 'a'의 extra_users= 의 'u'는 user= 와 같습니다.", { set("extra_users", "v,,w , v") }),
            ("서버 'a'의 extra_users= 에 'v'가 두 번 있습니다.", { set("extra_users", "v,,w") }),
            ("서버 'a'의 check='bogus'는 지원하지 않습니다.", { set("check", "tcp") }),
            ("서버 'a'의 port='0'가 1~65535 범위가 아닙니다.", { set("port", "+22") }),
            ("서버 'a'의 port='+22'가 1~65535 범위가 아닙니다.", { set("port", "22") }),
            ("서버 'a'는 network=lan 인데 [network:lan] service= 가 없습니다.", { set("network", "tailscale") }),
            ("서버 'a'의 wol_mac= 과 wol_via= 는 함께 있어야 합니다.", { set("wol_via", "nope") }),
            ("서버 'a'의 wol_mac='ZZ'가 MAC 주소 형식(AA:BB:CC:DD:EE:FF)이 아닙니다.", { set("wol_mac", "02:00:00:aa:bb:01") }),
            ("서버 'a'의 wol_via= 의 'nope'는 등록되지 않은 서버 키입니다.", { set("wol_via", "a:bad iface!") }),
            ("서버 'a'의 wol_via= 의 인터페이스 'bad iface!'가 이름 형식(영문·숫자·._- 15자 이내)이 아닙니다.", { set("wol_via", "a:br-lan, a") }),
            ("서버 'a'의 wol_via= 에 'a'가 두 번 있습니다.", { set("wol_via", "a:br-lan,") }),
            ("서버 'a'의 wol_via= 의 ''는 등록되지 않은 서버 키입니다.", { set("wol_via", "a:br-lan") }),
            ("서버 'a'의 proxy_port='0'가 1~65535 범위가 아닙니다.", { set("proxy_port", "1080") }),
            ("서버 'a'의 tunnel_ports='x'에 잘못된 항목이 있습니다: 'x'", { set("tunnel_ports", "9090, :80") }),
            ("서버 'a'의 tunnel_ports='9090, :80'에 잘못된 항목이 있습니다: ':80'", { set("tunnel_ports", "Jenkins:9090,,9090, 80") }),
            ("서버 'a'의 notify='maybe'는 지원하지 않습니다.", { set("notify", "on") }),
            ("서버 'a'에 vpn= 이 있는데 network=tailscale 입니다.", { set("vpn", nil) }),
            ("[group:g] db_port='0'가 1~65535 범위가 아닙니다.", { tail = "[group:g]\ndb_port=5432\ndb_local=x\ndb_jump=nope\n" }),
            ("[group:g] db_local='x'가 1~65535 범위가 아닙니다.", { tail = "[group:g]\ndb_port=5432\ndb_local=15432\ndb_jump=nope\n" }),
            ("[group:g] db_jump='nope'는 등록되지 않은 서버 키입니다.", { tail = "[group:g]\ndb_port=5432\ndb_local=15432\ndb_jump=a\n" }),
        ]
        for (index, step) in steps.enumerated() {
            XCTAssertEqual(problem(text()), step.expected, "\(index)번째")
            step.fix()
        }
        XCTAssertNil(problem(text()), "다 고치면 읽힌다")
        let server = try? ServerConfigParser.parse(text()).servers.first
        XCTAssertEqual(server?.extraUsers, ["v", "w"])
        XCTAssertEqual(server?.wolRoutes, [WakeRoute(via: "a", iface: "br-lan")])
        XCTAssertEqual(server?.tunnelPorts, [QuickTunnel(name: "Jenkins", port: 9090), QuickTunnel(name: nil, port: 80)], "같은 포트는 처음 것만")
        XCTAssertEqual(server?.check, .tcp)
        XCTAssertEqual(server?.notify, true)
        XCTAssertEqual(server?.proxyPort, 1080)
    }

    /// 줄 문법 오류는 값 검사보다 먼저, 서버는 파일에 나온 순서로, 그룹 설정은 서버를 다 본 뒤
    func testErrorsAcrossBlocks() {
        let good = "group=g\ntype=linux\nip=192.0.2.1\nuser=u\nport=22\n"
        XCTAssertEqual(problem("[a]\ntype=bogus\n[b]\nnonsense\n"), "형식 오류: 'nonsense' (t.conf:4)")
        XCTAssertEqual(problem("x=1\n[A]\n"), "섹션 밖의 설정: 'x=1' (t.conf:1)")
        XCTAssertEqual(problem("[a]\n\(good)[A]\n"), "서버 키 'A'는 소문자 영문·숫자·밑줄만 쓸 수 있습니다 (t.conf:7).")
        XCTAssertEqual(problem("[a]\n[b]\n[a]\n"), "서버 키 'a'가 두 번 정의됐습니다 (t.conf:3).")
        XCTAssertEqual(problem("[a]\n\(good)port=x\n[b]\n"), "서버 'a'의 port='x'가 1~65535 범위가 아닙니다.", "같은 줄이 두 번이면 마지막 값")
        XCTAssertEqual(problem("[b]\n\(good)notify=x\n[a]\n"), "서버 'b'의 notify='x'는 지원하지 않습니다.", "키 이름순이 아니라 나온 순서")
        XCTAssertEqual(problem("[group:g]\ndb_port=x\n[a]\n\(good)[b]\n"), "서버 'b'에 group= 가 없습니다.", "그룹 설정이 파일 앞에 있어도 서버 먼저")
        XCTAssertNil(problem("[group:other]\ndb_port=x\ndb_jump=nope\n[a]\n\(good)"), "서버가 없는 그룹의 설정은 보지 않는다")
        // check 를 적지 않았을 때: tailscale 의 linux 만 ssh
        func check(_ extra: String) -> CheckMethod? { try? ServerConfigParser.parse("[a]\n\(good)\(extra)").servers.first?.check }
        XCTAssertEqual(check(""), .tcp)
        XCTAssertEqual(check("network=tailscale\n"), .ssh)
        XCTAssertEqual(check("network=tailscale\ntype=windows\n"), .tcp)
        XCTAssertEqual(check("network=tailscale\ntype=openwrt\n"), .tcp)
        XCTAssertEqual(check("network=tailscale\ncheck=tcp\n"), .tcp)
        XCTAssertEqual(check("check=ssh\n"), .ssh)
    }

    // MARK: 줄 문법

    /// 뒤 주석은 공백 뒤의 # 부터 (공백 없는 # 은 값), 머리 줄은 주석을 떼고 [ 로 시작해 ] 로 끝나는 줄 — 파서와 편집기가 같게 읽는다
    func testLineSyntaxIsSharedByParserAndEditor() throws {
        let text = """
        # 머리 주석 [x]
        [a]   # 주석 [b]
          group = g \t# 뒤 주석
        type=linux
        ip=192.0.2.1
        user=u
        port=22 #x
        role=a#b # c
        env=  # 빈 값
        \t# 들여 쓴 주석 = 값
        [group:g] # 그룹

        db_name=x=y

        """
        let config = try ServerConfigParser.parse(text)
        XCTAssertEqual(config.servers.map(\.key), ["a"])
        let server = try XCTUnwrap(config.servers.first)
        XCTAssertEqual(server.group, "g")
        XCTAssertEqual(server.port, 22)
        XCTAssertEqual(server.role, "a#b")
        XCTAssertNil(server.env)
        XCTAssertEqual(config.settings(for: "g")?.dbName, "x=y")

        let lines = ServerConfigEditor.lines(of: text)
        XCTAssertEqual(ServerConfigEditor.headerLines(in: lines).map(\.name), ["a", "group:g"])
        XCTAssertEqual(ServerConfigEditor.headerLines(in: lines).map(\.line), [1, 10])
        XCTAssertEqual(ServerConfigEditor.fieldValue("group", key: "a", in: lines), "g")
        XCTAssertEqual(ServerConfigEditor.fieldValue("port", key: "a", in: lines), "22")
        XCTAssertEqual(ServerConfigEditor.fieldValue("role", key: "a", in: lines), "a#b")
        XCTAssertEqual(ServerConfigEditor.fieldValue("env", key: "a", in: lines), "")
        XCTAssertEqual(ServerConfigEditor.fieldValue("db_name", key: "group:g", in: lines), "x=y")
        XCTAssertNil(ServerConfigEditor.fieldValue("들여 쓴 주석", key: "a", in: lines), "주석 줄은 설정이 아니다")
        XCTAssertEqual(lines.map(ServerConfigEditor.fieldName), [nil, nil, "group", "type", "ip", "user", "port", "role", "env", nil, nil, nil, "db_name"])
        XCTAssertEqual(lines.map(ServerConfigEditor.isBlankOrComment), [true, false, false, false, false, false, false, false, false, true, false, true, false])
        let span = try XCTUnwrap(ServerConfigEditor.blockSpan("a", in: lines))
        XCTAssertEqual([span.header, span.last, span.next], [1, 8, 10], "마지막 설정 줄 뒤의 주석 · 빈 줄은 블록 끝에서 뺀다")
        // 머리 꼴이 아닌 줄: 닫는 ] 뒤에 글이 있으면 머리가 아니다 (파서는 설정 줄로 읽는다)
        XCTAssertEqual(ServerConfigEditor.headerLines(in: ["[a]x", " [b] ", "[c", "[] # 빈 이름", "#[d]"]).map(\.name), ["b", ""])
        XCTAssertEqual(problem("[a]x\n"), "형식 오류: '[a]x' (t.conf:1)")
    }

    /// 값에 # [ 줄바꿈을 쓰면 줄 문법이 깨진다 — 편집기가 막는다 (역할 · 태그 · VPN 이름 · 내부망 서비스 이름)
    func testEditorRejectsCharactersThatBreakLines() {
        func server(role: String? = nil, env: String? = nil, vpn: String? = nil) -> NewServer {
            NewServer(key: "a", group: "g", network: vpn == nil ? .direct : .vpn, type: .linux, ip: "192.0.2.1", user: "u", port: 22, role: role, env: env, vpn: vpn)
        }
        XCTAssertNil(ServerConfigEditor.problem(server(role: "web 1", env: "prod,eu", vpn: "Office VPN")))
        XCTAssertEqual(ServerConfigEditor.problem(server(role: "a#b")), "역할에 # [ 줄바꿈은 쓸 수 없습니다")
        XCTAssertEqual(ServerConfigEditor.problem(server(env: "[x")), "태그에 # [ 줄바꿈은 쓸 수 없습니다")
        XCTAssertEqual(ServerConfigEditor.problem(server(vpn: "a\r\nb")), "VPN 이름에 # [ 줄바꿈은 쓸 수 없습니다")
        XCTAssertEqual(ServerConfigEditor.problem(server(role: "a\u{2028}b")), "역할에 # [ 줄바꿈은 쓸 수 없습니다")
        XCTAssertNil(ServerConfigEditor.problem(server(role: "a]b")), "닫는 ] 는 된다")
        for bad in ["", "  ", "Eth#1", "Eth[1", "Eth\n1"] {
            XCTAssertThrowsError(try ServerConfigEditor.addingLanService(bad, to: "")) { error in
                XCTAssertEqual((error as? ConfigError)?.problem, "내부망 서비스 이름을 쓸 수 없습니다: '\(bad)'")
            }
        }
        XCTAssertEqual(try ServerConfigEditor.addingLanService(" USB 10/100 LAN ] ", to: ""), "[network:lan]\nservice=USB 10/100 LAN ]\n")
    }

    /// 블록 바로 위에 붙은 주석(빈 줄 없이, 들여 써도)은 그 블록의 것
    func testCommentsAttachedToBlocks() throws {
        let block = "group=g\ntype=linux\nip=192.0.2.1\nuser=u\nport=22\n"
        let text = "# 머리\n\n  # a 의 주석\n[a]\n\(block)\n# b 의 주석\n\t# 둘째 줄\n[b]\n\(block)"
        XCTAssertEqual(try ServerConfigEditor.addingLanService("Ethernet", to: text),
                       "# 머리\n\n[network:lan]\nservice=Ethernet\n\n  # a 의 주석\n[a]\n\(block)\n# b 의 주석\n\t# 둘째 줄\n[b]\n\(block)")
        XCTAssertEqual(try ServerConfigEditor.addingLanService("Ethernet", to: "# 머리\n[a]\n\(block)"), "# 머리\n[network:lan]\nservice=Ethernet\n\n[a]\n\(block)",
                       "파일 처음부터 이어진 주석은 머리 주석 — 그 뒤에")
    }
}
