import Foundation
@testable import ServersCore
import XCTest

final class HostAliasTests: XCTestCase {
    private let db = Server(key: "db", group: "acme", network: .lan, type: .linux, ip: "192.168.113.11", user: "manager", port: 22,
                            check: .tcp, role: nil, env: nil, wolMac: nil)

    func testAssignIsStableAndFillsNextFree() {
        var state = HostAliasState()
        let a = HostAliasStore.assign("db", in: state); state = a.state
        let b = HostAliasStore.assign("was", in: state); state = b.state
        XCTAssertEqual([a.address, b.address], ["127.0.0.2", "127.0.0.3"])
        XCTAssertEqual(HostAliasStore.assign("db", in: state).address, "127.0.0.2", "한 번 배정한 번호는 유지")
        XCTAssertEqual(HostAliasStore.preview("web", in: state), "127.0.0.4")
        XCTAssertEqual(state.assignments.count, 2, "미리보기는 저장하지 않는다")
    }

    /// 127.0.0.2…254 가 다 차면 127.0.1.x 로 — 이미 쓰는 127.0.0.2 를 다시 주면 안 된다
    func testAssignMovesToNextRangeWhenFull() {
        var state = HostAliasState(assignments: Dictionary(uniqueKeysWithValues: (2...254).map { ("s\($0)", "127.0.0.\($0)") }))
        let first = HostAliasStore.assign("new", in: state); state = first.state
        XCTAssertEqual(first.address, "127.0.1.2")
        XCTAssertEqual(HostAliasStore.assign("next", in: state).address, "127.0.1.3")
        XCTAssertEqual(Set(state.assignments.values).count, state.assignments.count, "주소가 겹치지 않는다")
    }

    func testNamesAndKeys() {
        XCTAssertEqual(HostAliasStore.hostName(server: db, kind: .port(remotePort: 8080)), "db.acme")
        XCTAssertEqual(HostAliasStore.hostName(server: db, kind: .db(host: "192.168.113.6", port: 5432, name: "acme")), "db-db.acme")
        XCTAssertEqual(HostAliasStore.assignmentKey(server: db, kind: .db(host: "x", port: 1, name: nil)), "db-db")
    }

    func testHostNameValidation() {
        for ok in ["db.acme", "api", "a-b.c-d.internal", "x1.y2", "DB.ACME", String(repeating: "a", count: 63) + ".acme"] {
            XCTAssertTrue(HostAliasStore.isValidHostName(ok), ok)
        }
        for bad in ["", " ", "db acme", "db..acme", ".acme", "acme.", "-db.acme", "db-.acme", "db_x.acme", "한글.acme", "db.acme:80",
                    "localhost", "LocalHost", "broadcasthost", String(repeating: "a", count: 64) + ".acme"] {
            XCTAssertFalse(HostAliasStore.isValidHostName(bad), "\"\(bad)\" 은 거부해야 한다")
        }
    }

    func testPresenceChecks() {
        let hosts = "127.0.0.1\tlocalhost\n127.0.0.2\tdb.acme\t# servers-app\n127.0.0.3 was.acme\n"
        XCTAssertTrue(HostAliasStore.hostsEntryPresent(name: "db.acme", address: "127.0.0.2", hostsText: hosts))
        XCTAssertFalse(HostAliasStore.hostsEntryPresent(name: "db.acme", address: "127.0.0.9", hostsText: hosts), "주소가 다르면 다시 써야 한다")
        XCTAssertFalse(HostAliasStore.hostsEntryPresent(name: "was.acme", address: "127.0.0.3", hostsText: hosts), "표식 없는 줄은 앱 것이 아니다")
        let ifconfig = "lo0: flags=8049<UP,LOOPBACK> mtu 16384\n\tinet 127.0.0.1 netmask 0xff000000\n\tinet 127.0.0.2 netmask 0xffffffff\n"
        XCTAssertTrue(HostAliasStore.aliasPresent(address: "127.0.0.2", ifconfigText: ifconfig))
        XCTAssertFalse(HostAliasStore.aliasPresent(address: "127.0.0.3", ifconfigText: ifconfig))
    }

    func testSetupScriptUsesPrivilegedWrapper() throws {
        let script = HostAliasCommands.setupScript(name: "db.acme", address: "127.0.0.2", libDir: "/x/lib")
        XCTAssertTrue(script.contains("_hosts_alias '127.0.0.2'"), script)
        XCTAssertTrue(script.contains("_hosts_set 'db.acme' '127.0.0.2'"), script)
        XCTAssertTrue(script.contains("env -u SUDO_ASKPASS sudo -v"), "인트라넷과 같은 인증 경로")
        XCTAssertEqual(try shellSyntaxStatus("/bin/zsh", script), 0)
    }

    /// lib/hosts.zsh 를 임시 hosts 파일·가짜 ifconfig 로 실제 실행: 표식 줄만 바꾸고 다른 줄은 그대로.
    func testHostsScriptEditsOnlyMarkedLines() throws {
        let dir = tempPath("hosts")
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let hosts = dir.appendingPathComponent("hosts")
        try "127.0.0.1\tlocalhost\n127.0.0.2\tdb.acme\t# servers-app\n10.0.0.5\tmine   # keep\n".write(to: hosts, atomically: true, encoding: .utf8)
        for name in ["ifconfig", "dscacheutil", "killall"] {
            try "#!/bin/sh\nprintf '%s %s\\n' \"$0\" \"$*\" >> \"$FAKE_LOG\"\n[ \"$1\" = lo0 ] && [ $# = 1 ] && printf 'lo0: flags\\n\\tinet 127.0.0.1 netmask 0xff000000\\n'\nexit 0\n"
                .write(to: bin.appendingPathComponent(name), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent(name).path)
        }
        let lib = TestPaths.repoRoot.appendingPathComponent("lib/hosts.zsh").path
        func run(_ body: String) throws -> Int32 {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-c", "sudo() { \"$@\"; }; source \(shellQuote(lib)) || exit 1; \(body)"]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = bin.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
            env["HOSTS_FILE"] = hosts.path
            env["FAKE_LOG"] = dir.appendingPathComponent("calls.log").path
            p.environment = env
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit(); return p.terminationStatus
        }
        XCTAssertEqual(try run("_hosts_alias 127.0.0.3"), 0)
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("calls.log"), encoding: .utf8).contains("lo0 alias 127.0.0.3 255.255.255.255"))
        XCTAssertEqual(try run("_hosts_set db.acme 127.0.0.9; _hosts_set was.acme 127.0.0.3"), 0)
        XCTAssertEqual(try String(contentsOf: hosts, encoding: .utf8),
                       "127.0.0.1\tlocalhost\n10.0.0.5\tmine   # keep\n127.0.0.9\tdb.acme\t# servers-app\n127.0.0.3\twas.acme\t# servers-app\n")
        XCTAssertEqual(try run("_hosts_remove db.acme 127.0.0.2"), 0)
        XCTAssertTrue(try String(contentsOf: hosts, encoding: .utf8).contains("127.0.0.9\tdb.acme\t# servers-app"), "IP 가 다르면 지우지 않는다")
        XCTAssertEqual(try run("_hosts_remove db.acme 127.0.0.9"), 0)
        XCTAssertEqual(try String(contentsOf: hosts, encoding: .utf8), "127.0.0.1\tlocalhost\n10.0.0.5\tmine   # keep\n127.0.0.3\twas.acme\t# servers-app\n")
        XCTAssertNotEqual(try run("_hosts_remove db.acme"), 0, "IP 없이는 지우지 않는다")
        // 빈 인자·못 읽는 파일: 실패로 끝나고 파일을 덮지 않는다 (awk 가 실패해도 새 줄 하나로 덮어 쓰던 것)
        let before = try String(contentsOf: hosts, encoding: .utf8)
        XCTAssertNotEqual(try run("_hosts_set '' 127.0.0.5"), 0)
        XCTAssertNotEqual(try run("_hosts_set x.acme ''"), 0)
        XCTAssertEqual(try String(contentsOf: hosts, encoding: .utf8), before)
        let gone = dir.appendingPathComponent("gone").path
        XCTAssertNotEqual(try run("HOSTS_FILE=\(shellQuote(gone)); _hosts_set x.acme 127.0.0.5"), 0)
        XCTAssertNotEqual(try run("HOSTS_FILE=\(shellQuote(gone)); _hosts_remove x.acme 127.0.0.5"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone), "읽지 못한 파일을 새로 만들어 덮지 않는다")
        XCTAssertEqual(try run("_hosts_unalias 127.0.0.9"), 0, "없는 별칭은 그대로 0")
        let script = HostAliasCommands.teardownScript(name: "db.acme", address: "127.0.0.2", dropAlias: true, libDir: "/x/lib")
        XCTAssertTrue(script.contains("_hosts_remove 'db.acme' '127.0.0.2'") && script.contains("_hosts_unalias '127.0.0.2'"), script)
        XCTAssertFalse(HostAliasCommands.teardownScript(name: "db.acme", address: "127.0.0.2", dropAlias: false, libDir: "/x/lib").contains("_hosts_unalias"))
    }
}
