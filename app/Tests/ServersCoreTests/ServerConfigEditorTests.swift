// servers.conf 블록 추가·제거 (텍스트 편집). 실제 파일은 건드리지 않는다.

import Foundation
import XCTest
@testable import ServersCore

final class ServerConfigEditorTests: XCTestCase {
    private let text = """
    # 상단 설명 주석
    #   [키] 형식 …

    [group:acme]
    db_jump=was

    [nexus]
    group=home
    network=tailscale
    type=linux
    ip=100.101.0.1
    user=alice
    port=22

    [sandbox]
    group=home
    network=tailscale
    type=linux
    ip=100.101.0.2
    user=alice
    port=22
    role=Hyper-V

    # win 은 nexus 로 깨운다
    [win]
    group=home
    network=tailscale
    type=windows
    ip=100.101.1.3
    user=bob
    port=22
    wol_mac=D8:BB:C1:A1:B2:E6
    wol_via=nexus

    [network:lan]
    service=Test

    [was]
    group=acme
    network=lan
    type=linux
    ip=192.168.112.11
    user=manager
    port=22

    """

    private func sample(_ key: String = "vm2") -> NewServer {
        NewServer(key: key, group: "home", type: .linux, ip: "100.101.0.9", user: "alice", role: "Test VM", env: "VM")
    }

    func testAppendKeepsEverythingAndParses() throws {
        let result = try ServerConfigEditor.appending(sample(), to: text)
        XCTAssertTrue(result.hasPrefix(text.trimmingCharacters(in: .newlines)), "기존 내용·주석은 그대로")
        XCTAssertTrue(result.hasSuffix("[vm2]\ngroup=home\nnetwork=tailscale\ntype=linux\nip=100.101.0.9\nuser=alice\nport=22\nrole=Test VM\nenv=VM\n"))
        let config = try ServerConfigParser.parse(result)
        XCTAssertEqual(config.servers.map(\.key), ["nexus", "sandbox", "win", "was", "vm2"])
        XCTAssertEqual(config.server("vm2")?.check, .ssh)
    }

    func testAppendWithNotify() throws {
        let on = try ServerConfigEditor.appending(sample(), notify: true, to: text)
        XCTAssertTrue(on.hasSuffix("role=Test VM\nenv=VM\nnotify=on\n"), on)
        XCTAssertEqual(try ServerConfigParser.parse(on).server("vm2")?.notify, true)
        let off = try ServerConfigEditor.appending(sample(), to: text)
        XCTAssertFalse(off.contains("notify="), "끄면 줄을 쓰지 않는다 (기본 off)")
    }

    func testAppendToNewGroupAndWithoutOptionals() throws {
        var s = sample(); s.group = "lab"; s.role = "  "; s.env = nil; s.type = .windows; s.port = 2222
        let config = try ServerConfigParser.parse(try ServerConfigEditor.appending(s, to: text))
        let vm = try XCTUnwrap(config.server("vm2"))
        XCTAssertEqual(config.groups.last, "lab")
        XCTAssertNil(vm.role); XCTAssertNil(vm.env)
        XCTAssertEqual(vm.port, 2222); XCTAssertEqual(vm.check, .tcp)
    }

    func testAppendRejectsDuplicate() {
        XCTAssertThrowsError(try ServerConfigEditor.appending(sample("sandbox"), to: text)) { error in
            XCTAssertTrue("\(error)".contains("이미 있는 이름"))
        }
    }

    /// 추가도 편집과 같은 줄을 쓴다 (basicFields) — 추가 계정을 넘기면 버리지 않고 user= 다음 줄에
    func testAppendWritesExtraUsers() throws {
        var s = sample(); s.extraUsers = ["deploy", "ops"]
        let result = try ServerConfigEditor.appending(s, to: text)
        XCTAssertTrue(result.contains("user=alice\nextra_users=deploy,ops\nport=22\n"), result)
        XCTAssertEqual(try ServerConfigParser.parse(result).server("vm2")?.accounts, ["alice", "deploy", "ops"])
    }

    /// "\r\n" 은 한 글자라 "\n" 검사로는 안 잡힌다 — 통과하면 파서가 줄을 나눠 ip= 줄이 하나 더 생긴다 (마지막 값이 이김)
    func testNewlineInValuesRejectedIncludingCRLF() {
        for bad in ["a\r\nip=9.9.9.9", "a\nip=9.9.9.9", "a\rb"] {
            var s = sample(); s.role = bad; XCTAssertNotNil(ServerConfigEditor.problem(s), bad.debugDescription)
            s = sample(); s.env = bad; XCTAssertNotNil(ServerConfigEditor.problem(s), bad.debugDescription)
            s = sample(); s.network = .vpn; s.vpn = bad; XCTAssertNotNil(ServerConfigEditor.problem(s), bad.debugDescription)
            XCTAssertThrowsError(try ServerConfigEditor.addingLanService(bad, to: ""), bad.debugDescription)
        }
        var s = sample(); s.role = "x\r\nip=9.9.9.9"
        XCTAssertThrowsError(try ServerConfigEditor.appending(s, to: text))
    }

    func testInputProblems() {
        var s = sample()
        s.key = "VM2"; XCTAssertNotNil(ServerConfigEditor.problem(s))
        s.key = "2vm"; XCTAssertNotNil(ServerConfigEditor.problem(s))
        s = sample(); s.ip = ""; XCTAssertNotNil(ServerConfigEditor.problem(s))
        s = sample(); s.ip = "1.2.3.4 # x"; XCTAssertNotNil(ServerConfigEditor.problem(s))
        s = sample(); s.user = "a b"; XCTAssertNotNil(ServerConfigEditor.problem(s))
        s = sample(); s.port = 0; XCTAssertNotNil(ServerConfigEditor.problem(s))
        s = sample(); s.role = "a # b"; XCTAssertNotNil(ServerConfigEditor.problem(s))
        s = sample(); s.group = "Home"; XCTAssertNotNil(ServerConfigEditor.problem(s))
        s = sample(); s.ip = "vm2.tail1234.ts.net"; XCTAssertNil(ServerConfigEditor.problem(s), "MagicDNS 이름도 허용")
        XCTAssertNil(ServerConfigEditor.problem(sample()))
    }

    func testRemoveMiddleBlockKeepsNextBlockComment() throws {
        let result = try ServerConfigEditor.removing(key: "sandbox", from: text)
        XCTAssertFalse(result.contains("[sandbox]"))
        XCTAssertFalse(result.contains("Hyper-V"))
        XCTAssertTrue(result.contains("port=22\n\n# win 은 nexus 로 깨운다\n[win]"), "다음 블록 위 주석은 남고 빈 줄은 하나")
        XCTAssertFalse(result.contains("\n\n\n"))
        XCTAssertEqual(try ServerConfigParser.parse(result).servers.map(\.key), ["nexus", "win", "was"])
    }

    func testRemoveThenAppendRoundTrip() throws {
        let removed = try ServerConfigEditor.removing(key: "sandbox", from: text)
        var s = sample("sandbox"); s.ip = "100.101.0.2"; s.role = "Hyper-V"; s.env = nil
        let back = try ServerConfigEditor.appending(s, to: removed)
        XCTAssertEqual(try ServerConfigParser.parse(back).server("sandbox")?.ip, "100.101.0.2")
    }

    func testRemoveLastBlock() throws {
        let added = try ServerConfigEditor.appending(sample(), to: text)
        let result = try ServerConfigEditor.removing(key: "vm2", from: added)
        XCTAssertEqual(result, text.trimmingCharacters(in: .newlines) + "\n")
    }

    /// 다른 설정이 가리키는 서버도 지울 수 있다 — 가리키던 줄을 함께 정리한다
    func testRemoveCleansReferences() throws {
        let config = try ServerConfigParser.parse(text)
        XCTAssertEqual(ServerConfigEditor.references(to: "nexus", in: config), ["win 의 wol_via"])
        XCTAssertEqual(ServerConfigEditor.references(to: "was", in: config), ["[group:acme] 의 db_jump"])

        let noNexus = try ServerConfigEditor.removing(key: "nexus", from: text)
        let win = try XCTUnwrap(try ServerConfigParser.parse(noNexus).server("win"))
        XCTAssertEqual(win.wolRoutes, [], "경로가 다 빠지면")
        XCTAssertNil(win.wolMac, "MAC 도 함께 (wol_mac 만 남으면 설정 오류)")
        XCTAssertFalse(noNexus.contains("wol_"))
        XCTAssertTrue(noNexus.contains("# win 은 nexus 로 깨운다\n[win]"), "주석은 손대지 않는다")

        let noWas = try ServerConfigEditor.removing(key: "was", from: text)
        XCTAssertNil(try ServerConfigParser.parse(noWas).settings(for: "acme")?.dbJump)
        XCTAssertFalse(noWas.contains("db_jump"))
        XCTAssertFalse(noWas.contains("\n\n\n"))

        XCTAssertThrowsError(try ServerConfigEditor.removing(key: "ghost", from: text))
    }

    /// 파서의 그룹 목록엔 서버가 있는 그룹만 있다 — 서버 없는 그룹의 db_jump 도 지워야 나중에 그 그룹에 서버를 넣을 수 있다
    func testRemoveCleansDbJumpOfGroupWithoutServers() throws {
        let extra = text + "\n[group:empty]\ndb_jump=sandbox # 메모\ndb_host=10.0.0.9\n\n[group:other]\ndb_jump=nexus\n"
        let result = try ServerConfigEditor.removing(key: "sandbox", from: extra)
        XCTAssertTrue(result.contains("[group:empty]\ndb_host=10.0.0.9\n"), result)
        XCTAssertTrue(result.contains("[group:other]\ndb_jump=nexus"), "다른 서버를 가리키는 값은 그대로")
        XCTAssertNoThrow(try ServerConfigEditor.appending(NewServer(key: "fresh", group: "empty", network: .direct, type: .linux, ip: "1.1.1.1", user: "a"), to: result))
    }

    /// 첫 블록 바로 위에 붙은 주석은 그 블록의 것 — 사이에 끼워 넣어 [network:lan] 의 주석으로 만들지 않는다
    func testAddingLanServiceKeepsCommentAttachedToFirstBlock() throws {
        let body = "[web]\ngroup=g\ntype=linux\nip=1.1.1.1\nuser=u\nport=22\n"
        XCTAssertEqual(try ServerConfigEditor.addingLanService("LAN", to: "# 머리\n\n# web 서버\n" + body),
                       "# 머리\n\n[network:lan]\nservice=LAN\n\n# web 서버\n" + body)
        // 파일 처음부터 이어진 주석은 머리 주석 — 그 뒤(첫 블록 앞)에
        XCTAssertEqual(try ServerConfigEditor.addingLanService("LAN", to: "# 머리\n" + body), "# 머리\n[network:lan]\nservice=LAN\n\n" + body)
    }

    /// 첫 Intranet 서버: 빈 목록(형식 설명만)·서버만 있는 목록에 [network:lan] 을 넣고, 그 위에 lan 서버를 붙일 수 있다
    func testAddingLanServiceThenLanServer() throws {
        let lanServer = NewServer(key: "web", group: "acme", network: .lan, type: .linux, ip: "192.168.111.11", user: "manager")
        XCTAssertThrowsError(try ServerConfigEditor.appending(lanServer, to: ConfigLocation.header)) { error in
            XCTAssertTrue("\(error)".contains("[network:lan]"))
        }

        let withLan = try ServerConfigEditor.addingLanService("acme ethernet", to: ConfigLocation.header)
        XCTAssertTrue(withLan.hasPrefix(ConfigLocation.header), "머리 주석은 그대로")
        let added = try ServerConfigEditor.appending(lanServer, to: withLan)
        let config = try ServerConfigParser.parse(added)
        XCTAssertEqual(config.lan?.service, "acme ethernet")
        XCTAssertEqual(config.server("web")?.network, .lan)

        // 서버가 있으면 첫 블록 앞에 (머리 주석 뒤)
        let one = "# 주석\n\n[a]\ngroup=g\ntype=linux\nip=1.1.1.1\nuser=u\nport=22\n"
        let inserted = try ServerConfigEditor.addingLanService(" Office LAN ", to: one)
        XCTAssertEqual(inserted, "# 주석\n\n[network:lan]\nservice=Office LAN\n\n[a]\ngroup=g\ntype=linux\nip=1.1.1.1\nuser=u\nport=22\n")
    }

    func testAddingLanServiceRejects() throws {
        let withLan = try ServerConfigEditor.addingLanService("LAN", to: "")
        XCTAssertEqual(withLan, "[network:lan]\nservice=LAN\n")
        XCTAssertThrowsError(try ServerConfigEditor.addingLanService("Other", to: withLan)) { error in
            XCTAssertTrue("\(error)".contains("이미 있습니다"))
        }
        // service= 가 빈 블록은 그 블록을 채운다 — 두 번째 [network:lan] 을 만들지 않는다
        let filled = try ServerConfigEditor.addingLanService("LAN", to: "# c\n[network:lan]\nservice=\nwait_attempts=10\n\n[group:g]\ntheme=on\n")
        XCTAssertEqual(filled, "# c\n[network:lan]\nservice=LAN\nwait_attempts=10\n\n[group:g]\ntheme=on\n")
        XCTAssertEqual(try ServerConfigParser.parse(filled).lan?.service, "LAN")
        for bad in ["", "  ", "a # b", "a[1]"] {
            XCTAssertThrowsError(try ServerConfigEditor.addingLanService(bad, to: ""), bad)
        }
    }

    func testRemoveOnlyServerLeavesEmptyList() throws {
        let one = "# 주석\n\n[a]\ngroup=g\nnetwork=tailscale\ntype=linux\nip=1.1.1.1\nuser=u\nport=22\n"
        let empty = try ServerConfigEditor.removing(key: "a", from: one)
        XCTAssertTrue(try ServerConfigParser.parse(empty).servers.isEmpty)
        XCTAssertTrue(empty.hasPrefix("# 주석"))
    }

    func testCRLFInput() throws {
        let crlf = text.replacingOccurrences(of: "\n", with: "\r\n")
        let result = try ServerConfigEditor.removing(key: "sandbox", from: crlf)
        XCTAssertEqual(try ServerConfigParser.parse(result).servers.map(\.key), ["nexus", "win", "was"])
    }

    func testWriteKeepsPermissions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("servers.conf").path
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        try ServerConfigEditor.write(try ServerConfigEditor.appending(sample(), to: text), to: path)
        XCTAssertNotNil(try ServerConfigParser.load(path: path).server("vm2"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testAppendAndRemoveLanServer() throws {
        let s = NewServer(key: "api", group: "acme", network: .lan, type: .linux, ip: "192.168.112.12", user: "manager", env: "PROD")
        let added = try ServerConfigEditor.appending(s, to: text)
        XCTAssertTrue(added.contains("[api]\ngroup=acme\nnetwork=lan\n"))
        let api = try XCTUnwrap(try ServerConfigParser.parse(added).server("api"))
        XCTAssertEqual(api.network, .lan); XCTAssertEqual(api.check, .tcp); XCTAssertTrue(api.isProd)
        XCTAssertEqual(try ServerConfigEditor.removing(key: "api", from: added), text.trimmingCharacters(in: .newlines) + "\n")
    }

    func testAppendLanWithoutLanSectionFails() {
        let noLan = "[a]\ngroup=g\nnetwork=tailscale\ntype=linux\nip=1.1.1.1\nuser=u\nport=22\n"
        let s = NewServer(key: "b", group: "g", network: .lan, type: .linux, ip: "10.0.0.1", user: "u")
        XCTAssertThrowsError(try ServerConfigEditor.appending(s, to: noLan)) { error in
            XCTAssertTrue("\(error)".contains("[network:lan] service="))
        }
    }

    // MARK: 그룹 안 순서 (Move Up / Move Down)

    func testMoveUpSwapsWithPreviousInGroupAndCarriesAttachedComment() throws {
        XCTAssertEqual(ServerConfigEditor.neighbor(of: "win", .up, in: try ServerConfigParser.parse(text)), "sandbox")
        let moved = try ServerConfigEditor.moving(key: "win", .up, in: text)
        XCTAssertEqual(try ServerConfigParser.parse(moved).servers.map(\.key), ["nexus", "win", "sandbox", "was"])
        // 바로 위에 붙은 주석은 그 블록과 함께, 빈 줄 자리는 그대로
        XCTAssertTrue(moved.contains("""
            port=22

            # win 은 nexus 로 깨운다
            [win]
            """), moved)
        XCTAssertTrue(moved.contains("role=Hyper-V\n\n[network:lan]"), moved)
        XCTAssertTrue(moved.hasPrefix("# 상단 설명 주석\n#   [키] 형식 …\n\n[group:acme]"), "파일 머리 주석은 움직이지 않는다")
        XCTAssertEqual(try ServerConfigEditor.moving(key: "win", .down, in: moved), text, "되돌리면 원문 그대로")
    }

    func testMoveAtGroupEdgeHasNoNeighbor() throws {
        let config = try ServerConfigParser.parse(text)
        XCTAssertNil(ServerConfigEditor.neighbor(of: "nexus", .up, in: config), "그룹 맨 위")
        XCTAssertNil(ServerConfigEditor.neighbor(of: "win", .down, in: config), "다음 블록(was)은 다른 그룹")
        XCTAssertNil(ServerConfigEditor.neighbor(of: "was", .up, in: config), "그룹에 혼자")
        XCTAssertNil(ServerConfigEditor.neighbor(of: "ghost", .up, in: config))
        XCTAssertThrowsError(try ServerConfigEditor.moving(key: "nexus", .up, in: text))
        XCTAssertThrowsError(try ServerConfigEditor.moving(key: "ghost", .down, in: text))
    }

    /// 같은 그룹 서버 사이에 다른 블록이 있어도 두 블록만 자리를 바꾸고 사이 블록은 그대로
    func testMoveAcrossOtherBlocks() throws {
        let withTail = text + "\n[vm2]  # 뒤 주석\ngroup=home\nnetwork=tailscale\ntype=linux\nip=100.101.0.9\nuser=alice\nport=22\n"
        let moved = try ServerConfigEditor.moving(key: "win", .down, in: withTail)
        let config = try ServerConfigParser.parse(moved)
        XCTAssertEqual(config.servers.map(\.key), ["nexus", "sandbox", "vm2", "was", "win"])
        XCTAssertEqual(config.lan?.service, "Test")
        XCTAssertTrue(moved.contains("role=Hyper-V\n\n[vm2]  # 뒤 주석\n"), moved)
        XCTAssertTrue(moved.hasSuffix("port=22\n\n[network:lan]\nservice=Test\n\n[was]\ngroup=acme\nnetwork=lan\ntype=linux\nip=192.168.112.11\nuser=manager\nport=22\n\n# win 은 nexus 로 깨운다\n[win]\ngroup=home\nnetwork=tailscale\ntype=windows\nip=100.101.1.3\nuser=bob\nport=22\nwol_mac=D8:BB:C1:A1:B2:E6\nwol_via=nexus\n"), moved)
        XCTAssertEqual(try ServerConfigEditor.moving(key: "win", .up, in: moved), withTail)
    }

    // MARK: 그룹 순서 — 그룹의 서버 블록을 앞 그룹의 첫 서버 블록 앞으로

    func testMoveGroupUpMovesAllItsBlocksBeforePreviousGroup() throws {
        let config = try ServerConfigParser.parse(text)
        XCTAssertEqual(config.groups, ["home", "acme"])
        XCTAssertEqual(ServerConfigEditor.groupNeighbor(of: "acme", .up, in: config), "home")
        XCTAssertNil(ServerConfigEditor.groupNeighbor(of: "home", .up, in: config), "맨 위")
        XCTAssertNil(ServerConfigEditor.groupNeighbor(of: "acme", .down, in: config), "맨 아래")
        XCTAssertNil(ServerConfigEditor.groupNeighbor(of: "ghost", .up, in: config))

        let moved = try ServerConfigEditor.movingGroup("acme", .up, in: text)
        let after = try ServerConfigParser.parse(moved)
        XCTAssertEqual(after.groups, ["acme", "home"])
        XCTAssertEqual(after.servers.map(\.key), ["was", "nexus", "sandbox", "win"])
        XCTAssertTrue(moved.hasPrefix("# 상단 설명 주석\n#   [키] 형식 …\n\n[group:acme]\ndb_jump=was\n\n[was]\n"), moved)
        XCTAssertTrue(moved.contains("port=22\n\n[nexus]\n"), moved)
        XCTAssertTrue(moved.contains("# win 은 nexus 로 깨운다\n[win]\n"), "붙은 주석은 제자리 블록과 함께")
        XCTAssertTrue(moved.hasSuffix("wol_via=nexus\n\n[network:lan]\nservice=Test\n"), moved)
        XCTAssertFalse(moved.contains("\n\n\n"), "빠진 자리에 빈 줄이 겹치지 않는다")
        XCTAssertEqual(after.lan?.service, "Test")
        XCTAssertEqual(after.settings(for: "acme")?.dbJump, "was")
    }

    /// 흩어진 그룹: 아래로 옮기면 다음 그룹의 블록 전부가 이 그룹의 첫 블록 앞으로 온다. 그룹 안 순서는 그대로.
    func testMoveGroupDownWithScatteredBlocks() throws {
        let scattered = text + "\n[vm2]\ngroup=home\nnetwork=tailscale\ntype=linux\nip=100.101.0.9\nuser=alice\nport=22\n"
        let moved = try ServerConfigEditor.movingGroup("home", .down, in: scattered)
        let after = try ServerConfigParser.parse(moved)
        XCTAssertEqual(after.groups, ["acme", "home"])
        XCTAssertEqual(after.servers(in: "home").map(\.key), ["nexus", "sandbox", "win", "vm2"])
        XCTAssertFalse(moved.contains("\n\n\n"))
        XCTAssertThrowsError(try ServerConfigEditor.movingGroup("acme", .down, in: text))
        XCTAssertThrowsError(try ServerConfigEditor.movingGroup("ghost", .up, in: text))
        // 블록 사이에 빈 줄이 없는 파일도 붙지 않게 띄운다
        let tight = "[a]\ngroup=x\nnetwork=direct\ntype=linux\nip=10.0.0.1\nuser=u\nport=22\n[b]\ngroup=y\nnetwork=direct\ntype=linux\nip=10.0.0.2\nuser=u\nport=22\n"
        XCTAssertEqual(try ServerConfigEditor.movingGroup("y", .up, in: tight),
                       "[b]\ngroup=y\nnetwork=direct\ntype=linux\nip=10.0.0.2\nuser=u\nport=22\n\n[a]\ngroup=x\nnetwork=direct\ntype=linux\nip=10.0.0.1\nuser=u\nport=22\n")
        // 다시 올리면 그룹 순서가 돌아온다
        XCTAssertEqual(try ServerConfigParser.parse(try ServerConfigEditor.movingGroup("home", .up, in: moved)).groups, ["home", "acme"])
    }

    // MARK: 서버별 액션 (tunnel_ports · proxy_port · wol_*)

    func testActionsAddedAfterLastSettingLine() throws {
        var a = ServerConfigEditor.Actions()
        a.tunnelPorts = [QuickTunnel(name: "Grafana", port: 3000), QuickTunnel(name: nil, port: 8080)]
        a.proxyPort = 1081
        let result = try ServerConfigEditor.updating(a, for: "sandbox", in: text)
        XCTAssertTrue(result.contains("role=Hyper-V\ntunnel_ports=Grafana:3000,8080\nproxy_port=1081\n\n# win 은"), "블록 끝, 다음 블록 주석 앞")
        let sandbox = try XCTUnwrap(try ServerConfigParser.parse(result).server("sandbox"))
        XCTAssertEqual(sandbox.tunnelPorts.map(\.label), ["Grafana Tunnel", "Tunnel 8080"])
        XCTAssertEqual(sandbox.proxyPort, 1081)
    }

    func testActionsReplaceInPlaceAndRemove() throws {
        var a = ServerConfigEditor.Actions(try XCTUnwrap(try ServerConfigParser.parse(text).server("win")))
        a.wolMac = "AA:BB:CC:DD:EE:FF"
        let replaced = try ServerConfigEditor.updating(a, for: "win", in: text)
        XCTAssertTrue(replaced.contains("port=22\nwol_mac=AA:BB:CC:DD:EE:FF\nwol_via=nexus\n"), "같은 자리에서 바뀐다")
        a.wolMac = nil; a.wolRoutes = []
        let removed = try ServerConfigEditor.updating(a, for: "win", in: text)
        XCTAssertFalse(removed.contains("wol_"))
        XCTAssertEqual(try ServerConfigParser.parse(removed).server("win")?.wolRoutes, [])
        // 경로를 더하면 같은 wol_via 줄에 쉼표로 붙고, 그 서버도 지울 수 없게 된다
        a = ServerConfigEditor.Actions(try XCTUnwrap(try ServerConfigParser.parse(text).server("win")))
        a.wolRoutes.insert(WakeRoute(via: "sandbox", iface: "br-lan"), at: 0)
        let two = try ServerConfigEditor.updating(a, for: "win", in: text)
        XCTAssertTrue(two.contains("wol_mac=D8:BB:C1:A1:B2:E6\nwol_via=sandbox:br-lan,nexus\n"), two)
        XCTAssertEqual(try ServerConfigParser.parse(two).server("win")?.wolRoutes, a.wolRoutes)
        // 경로 하나를 지우면 나머지 경로와 MAC 은 남는다
        let noSandbox = try ServerConfigEditor.removing(key: "sandbox", from: two)
        XCTAssertTrue(noSandbox.contains("wol_mac=D8:BB:C1:A1:B2:E6\nwol_via=nexus\n"), noSandbox)
    }

    func testUnchangedActionsLeaveTextIdentical() throws {
        let withComment = text.replacingOccurrences(of: "wol_via=nexus", with: "wol_via=nexus # 홈서버로 깨움")
        let win = try XCTUnwrap(try ServerConfigParser.parse(withComment).server("win"))
        XCTAssertEqual(try ServerConfigEditor.updating(.init(win), for: "win", in: withComment), withComment)
    }

    func testActionsOnLastBlockAndDuplicateLines() throws {
        let dup = text + "proxy_port=1\nproxy_port=2\n"
        var a = ServerConfigEditor.Actions(); a.proxyPort = 1090
        let result = try ServerConfigEditor.updating(a, for: "was", in: dup)
        XCTAssertEqual(result.components(separatedBy: "proxy_port=").count - 1, 1, "중복 줄은 하나로")
        XCTAssertEqual(try ServerConfigParser.parse(result).server("was")?.proxyPort, 1090)
    }

    func testActionProblems() throws {
        let config = try ServerConfigParser.parse(text)
        func p(_ a: ServerConfigEditor.Actions) -> String? { ServerConfigEditor.problem(a, for: "sandbox", in: config) }
        XCTAssertNil(p(.init()))
        XCTAssertNotNil(p(.init(tunnelPorts: [QuickTunnel(name: nil, port: 0)])))
        XCTAssertNotNil(p(.init(tunnelPorts: [QuickTunnel(name: nil, port: 80), QuickTunnel(name: "a", port: 80)])))
        XCTAssertNotNil(p(.init(tunnelPorts: [QuickTunnel(name: "a,b", port: 80)])))
        XCTAssertNotNil(p(.init(tunnelPorts: [QuickTunnel(name: "a:b", port: 80)])))
        XCTAssertNotNil(p(.init(proxyPort: 70000)))
        XCTAssertNotNil(p(.init(wolMac: "AA:BB:CC:DD:EE:FF")))
        XCTAssertNotNil(p(.init(wolMac: "zz", wolRoutes: [WakeRoute(via: "nexus")])))
        XCTAssertNotNil(p(.init(wolMac: "AA:BB:CC:DD:EE:FF", wolRoutes: [WakeRoute(via: "sandbox")])), "자기 자신은 안 된다")
        XCTAssertNotNil(p(.init(wolMac: "AA:BB:CC:DD:EE:FF", wolRoutes: [WakeRoute(via: "ghost")])))
        XCTAssertNotNil(p(.init(wolRoutes: [WakeRoute(via: "nexus")])), "MAC 없이 경로만은 안 된다")
        XCTAssertNotNil(p(.init(wolMac: "AA:BB:CC:DD:EE:FF", wolRoutes: [WakeRoute(via: "nexus"), WakeRoute(via: "nexus", iface: "eth0")])), "같은 경로 두 번")
        XCTAssertNotNil(p(.init(wolMac: "AA:BB:CC:DD:EE:FF", wolRoutes: [WakeRoute(via: "nexus", iface: "br lan")])))
        XCTAssertNotNil(p(.init(wolMac: "AA:BB:CC:DD:EE:FF", wolRoutes: [WakeRoute(via: "nexus", iface: "a-very-long-iface-name")])))
        XCTAssertNil(p(.init(wolMac: "AA:BB:CC:DD:EE:FF", wolRoutes: [WakeRoute(via: "win", iface: "br-lan"), WakeRoute(via: "nexus")])))
        XCTAssertNil(p(.init(tunnelPorts: [QuickTunnel(name: "Jenkins UI", port: 9090)], proxyPort: 1080, wolMac: "aa:bb:cc:dd:ee:ff", wolRoutes: [WakeRoute(via: "nexus")])))
        XCTAssertThrowsError(try ServerConfigEditor.updating(.init(proxyPort: 0), for: "sandbox", in: text))
        XCTAssertThrowsError(try ServerConfigEditor.updating(.init(), for: "ghost", in: text))
    }

    func testChangeAppliesToFileValuesNotStaleMemory() throws {
        // 앱이 읽은 뒤 파일에서 직접 tunnel_ports 를 넣었다 (Reload 전). 프록시만 추가해도 그 줄은 남아야 한다.
        let edited = text.replacingOccurrences(of: "role=Hyper-V", with: "role=Hyper-V\ntunnel_ports=Jenkins:9090")
        let result = try ServerConfigEditor.updating(for: "sandbox", in: edited) { $0.proxyPort = 1080 }
        let sandbox = try XCTUnwrap(try ServerConfigParser.parse(result).server("sandbox"))
        XCTAssertEqual(sandbox.tunnelPorts, [QuickTunnel(name: "Jenkins", port: 9090)])
        XCTAssertEqual(sandbox.proxyPort, 1080)
        XCTAssertThrowsError(try ServerConfigEditor.updating(for: "ghost", in: text) { $0.proxyPort = 1 })
    }

    // MARK: 기본 항목 편집 (이름 제외)

    func testEditChangesOnlyEditedLinesInPlace() throws {
        let withComment = text.replacingOccurrences(of: "role=Hyper-V", with: "role=Hyper-V # 가상머신")
        let original = try XCTUnwrap(try ServerConfigParser.parse(withComment).server("sandbox"))
        var edited = NewServer(original)
        edited.ip = "100.101.0.7"
        edited.env = "PROD, DB"
        let result = try ServerConfigEditor.updating(edited, notify: true, from: original, in: withComment)
        XCTAssertTrue(result.contains("type=linux\nip=100.101.0.7\nuser=alice\n"), "제자리에서 바뀐다")
        XCTAssertTrue(result.contains("role=Hyper-V # 가상머신\nenv=PROD, DB\nnotify=on\n\n# win 은"), "안 바꾼 줄은 주석까지 그대로, 새 줄은 블록 끝")
        let sandbox = try XCTUnwrap(try ServerConfigParser.parse(result).server("sandbox"))
        XCTAssertEqual(sandbox.ip, "100.101.0.7")
        XCTAssertEqual(sandbox.tags, ["PROD", "DB"])
        XCTAssertTrue(sandbox.notify)
        XCTAssertEqual(try ServerConfigParser.parse(result).server("win")?.ip, "100.101.1.3", "다른 블록은 그대로")
    }

    func testEditUnchangedLeavesTextIdentical() throws {
        let original = try XCTUnwrap(try ServerConfigParser.parse(text).server("win"))
        XCTAssertEqual(try ServerConfigEditor.updating(NewServer(original), notify: false, from: original, in: text), text)
    }

    func testEditClearsOptionalLines() throws {
        let on = text.replacingOccurrences(of: "role=Hyper-V", with: "role=Hyper-V\nenv=VM\nnotify=on")
        let original = try XCTUnwrap(try ServerConfigParser.parse(on).server("sandbox"))
        var edited = NewServer(original)
        edited.role = "  "
        edited.env = ""
        let result = try ServerConfigEditor.updating(edited, notify: false, from: original, in: on)
        let sandbox = try XCTUnwrap(try ServerConfigParser.parse(result).server("sandbox"))
        XCTAssertNil(sandbox.role, "비우면 줄을 지운다")
        XCTAssertNil(sandbox.env)
        XCTAssertFalse(sandbox.notify)
        XCTAssertFalse(result.contains("role=") || result.contains("notify="))
    }

    func testEditDoesNotOverwriteExternalChanges() throws {
        // 창을 연 뒤 파일에서 user 를 직접 바꿨다 (Reload 전). 창에서는 포트만 바꿨으니 user 는 파일 값이 남아야 한다.
        let original = try XCTUnwrap(try ServerConfigParser.parse(text).server("nexus"))
        let external = text.replacingOccurrences(of: "ip=100.101.0.1\nuser=alice", with: "ip=100.101.0.1\nuser=root")
        var edited = NewServer(original)
        edited.port = 2222
        let nexus = try XCTUnwrap(try ServerConfigParser.parse(try ServerConfigEditor.updating(edited, notify: false, from: original, in: external)).server("nexus"))
        XCTAssertEqual(nexus.user, "root")
        XCTAssertEqual(nexus.port, 2222)
    }

    /// 망 설정 없음으로 옮기면 network=direct 를 적고, network= 줄이 없는 서버는 다른 칸을 고쳐도 그 줄을 새로 쓰지 않는다
    func testEditToDirectAndKeepsMissingNetworkLine() throws {
        let original = try XCTUnwrap(try ServerConfigParser.parse(text).server("sandbox"))
        var edited = NewServer(original)
        edited.network = .direct
        let moved = try ServerConfigEditor.updating(edited, notify: false, from: original, in: text)
        XCTAssertTrue(moved.contains("[sandbox]\ngroup=home\nnetwork=direct\n"), moved)
        XCTAssertEqual(try ServerConfigParser.parse(moved).server("sandbox")?.network, .direct)

        let bare = text.replacingOccurrences(of: "[sandbox]\ngroup=home\nnetwork=tailscale\n", with: "[sandbox]\ngroup=home\n")
        let bareServer = try XCTUnwrap(try ServerConfigParser.parse(bare).server("sandbox"))
        XCTAssertEqual(bareServer.network, .direct)
        var roleOnly = NewServer(bareServer)
        roleOnly.role = "Lab"
        let updated = try ServerConfigEditor.updating(roleOnly, notify: false, from: bareServer, in: bare)
        XCTAssertEqual(updated, bare.replacingOccurrences(of: "role=Hyper-V", with: "role=Lab"), "역할 줄만 바뀐다")

        let added = try ServerConfigEditor.appending(NewServer(key: "ext", group: "ext", network: .direct, type: .linux, ip: "10.1.0.20", user: "u"), to: text)
        XCTAssertEqual(try ServerConfigParser.parse(added).server("ext")?.network, .direct)
    }

    func testEditMovesGroupAndNetwork() throws {
        let original = try XCTUnwrap(try ServerConfigParser.parse(text).server("sandbox"))
        var edited = NewServer(original)
        edited.group = "acme"
        edited.network = .lan
        edited.type = .windows
        let config = try ServerConfigParser.parse(try ServerConfigEditor.updating(edited, notify: false, from: original, in: text))
        let sandbox = try XCTUnwrap(config.server("sandbox"))
        XCTAssertEqual(sandbox.group, "acme")
        XCTAssertEqual(sandbox.network, .lan)
        XCTAssertEqual(sandbox.check, .tcp, "check= 를 안 적었으면 종류·망에 따른 기본값을 다시 따른다")
    }

    func testEditRejectsBadInput() throws {
        let original = try XCTUnwrap(try ServerConfigParser.parse(text).server("sandbox"))
        func edit(_ change: (inout NewServer) -> Void, in body: String? = nil) throws -> String {
            var edited = NewServer(original)
            change(&edited)
            return try ServerConfigEditor.updating(edited, notify: false, from: original, in: body ?? text)
        }
        XCTAssertThrowsError(try edit { $0.ip = "" })
        XCTAssertThrowsError(try edit { $0.port = 0 })
        XCTAssertThrowsError(try edit { $0.env = "PROD # 운영" }, "# 는 주석이 된다")
        XCTAssertThrowsError(try edit { $0.key = "other" }, "이름은 바꾸지 않는다")
        XCTAssertThrowsError(try edit({ _ in }, in: text.replacingOccurrences(of: "[sandbox]", with: "[sandbox_old]")), "파일에서 사라진 서버")
        let noLan = text.replacingOccurrences(of: "[network:lan]\nservice=Test\n", with: "")
            .replacingOccurrences(of: "network=lan", with: "network=tailscale")
        XCTAssertThrowsError(try edit({ $0.network = .lan }, in: noLan), "[network:lan] 없이 lan 으로는 못 바꾼다")
    }

    func testEditValidatesOnlyChangedFields() throws {
        // 파일에 이미 있는(파서가 받아 준) 값은 추가 때 규칙보다 느슨할 수 있다 — 안 바꾼 칸 때문에 저장이 막히지 않는다
        let loose = text.replacingOccurrences(of: "ip=100.101.0.2\nuser=alice", with: "ip=100.101.0.2\nuser=admin@corp")
        let original = try XCTUnwrap(try ServerConfigParser.parse(loose).server("sandbox"))
        XCTAssertNoThrow(try ServerConfigEditor.updating(NewServer(original), notify: true, from: original, in: loose), "알림만 켜기")
        var edited = NewServer(original)
        edited.user = "admin@other"
        XCTAssertThrowsError(try ServerConfigEditor.updating(edited, notify: false, from: original, in: loose), "바꾼 칸은 검사한다")
    }

    func testEditRefusesMovingDbJumpServerOutOfGroup() throws {
        let config = try ServerConfigParser.parse(text)
        let was = try XCTUnwrap(config.server("was"))   // [group:acme] db_jump=was
        var moved = NewServer(was)
        moved.group = "home"
        XCTAssertNotNil(ServerConfigEditor.problem(editing: moved, from: was, in: config))
        XCTAssertThrowsError(try ServerConfigEditor.updating(moved, notify: false, from: was, in: text))
        var retagged = NewServer(was)
        retagged.env = "PROD"
        XCTAssertNil(ServerConfigEditor.problem(editing: retagged, from: was, in: config), "그룹 말고 다른 칸은 바꿀 수 있다")
    }

    func testLeadingDashRejected() {
        var s = sample(); s.user = "-oProxyCommand"; XCTAssertNotNil(ServerConfigEditor.problem(s))
        s = sample(); s.ip = "-v"; XCTAssertNotNil(ServerConfigEditor.problem(s))
        s = sample(); s.user = "_svc"; XCTAssertNil(ServerConfigEditor.problem(s))
    }
}
