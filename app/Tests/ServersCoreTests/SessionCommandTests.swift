// SessionCommand: ssh·로컬 명령줄 조립.

import Foundation
import XCTest
@testable import ServersCore

final class SessionCommandTests: XCTestCase {
    func testSSHCommands() throws {
        let config = try ServerConfigParser.parse(fixture)
        let nexus = SessionCommand.sshCommandLine(to: config.server("nexus")!, config: config, home: "/h")
        XCTAssertEqual(nexus, "'ssh' '-o' 'ConnectTimeout=3' '-o' 'ConnectionAttempts=1' '-p' '2222' '-o' 'ControlMaster=auto' '-o' 'ControlPath=/h/.ssh/srv-%C' '-o' 'ControlPersist=10m' 'tester@100.64.0.1'")
        let win = SessionCommand.sshCommandLine(to: config.server("win")!, config: config, home: "/h")
        XCTAssertTrue(win.hasSuffix("'-t' 'tester@100.64.0.2' 'powershell.exe' '-NoLogo'"), win)
        // 리눅스는 일반 로그인 셸 — 원격 셸에 아무것도 주입하지 않는다 (예전 theme=on 그룹의 프롬프트·vim 주입은 뺐다. 설정에 theme=on 이 남아 있어도)
        let was = SessionCommand.sshCommandLine(to: config.server("was")!, config: config, home: "/h")
        XCTAssertTrue(was.hasSuffix("'-o' 'ControlPersist=10m' 'tester@192.0.2.22'"), was)
        XCTAssertFalse(was.contains("bash") || was.contains("'-t'") || was.contains("PS1") || was.contains("vim"), was)
        // 내부망 서버는 그 서비스의 장치에 묶는다 (시스템 경로 없이 장치의 스코프 기본 경로로). 옵션은 서버 이름 앞에.
        let bound = SessionCommand.sshCommandLine(to: config.server("was")!, config: config, home: "/h", bindInterface: "en10")
        XCTAssertTrue(bound.hasSuffix("'-o' 'BindInterface=en10' 'tester@192.0.2.22'"), bound)
        XCTAssertFalse(was.contains("BindInterface"), "장치를 모르면 붙이지 않는다")
        // OpenWrt 도 일반 로그인 셸 (ash)
        let router = Server(key: "gw", group: "acme", network: .lan, type: .openwrt, ip: "192.0.2.1", user: "root", port: 22,
                            check: .tcp, role: nil, env: nil, wolMac: nil)
        let openwrt = SessionCommand.sshCommandLine(to: router, config: config, home: "/h")
        XCTAssertTrue(openwrt.hasSuffix("'-o' 'ControlPersist=10m' 'root@192.0.2.1'"), openwrt)
        XCTAssertFalse(openwrt.contains("bash") || openwrt.contains("'-t'"), openwrt)
    }

    /// ssh·scp·sftp 공통 앞부분은 한 함수로 — 옵션을 바꿀 때 한 곳만 고친다 (scp·sftp 는 포트 플래그가 -P)
    func testSharedConnectionArguments() {
        XCTAssertEqual(ConnectPolicy.sharedArguments(port: 2222, bindInterface: "en10", home: "/h"),
                       ["-o", "ConnectTimeout=3", "-o", "ConnectionAttempts=1", "-p", "2222",
                        "-o", "ControlMaster=auto", "-o", "ControlPath=/h/.ssh/srv-%C", "-o", "ControlPersist=10m", "-o", "BindInterface=en10"])
        XCTAssertEqual(ConnectPolicy.sharedArguments(port: 22, portFlag: "-P", bindInterface: nil, home: "/h").prefix(6),
                       ["-o", "ConnectTimeout=3", "-o", "ConnectionAttempts=1", "-P", "22"])
        XCTAssertEqual(ConnectPolicy.noControlOptions, ["-o", "ControlMaster=no", "-o", "ControlPath=none"])
    }

    func testTunnels() throws {
        let config = try ServerConfigParser.parse(fixture)
        let was = config.server("was")!
        let t = SessionCommand.tunnelArguments(to: was, remotePort: 8080, localPort: 18080, banner: "up")
        XCTAssertEqual(Array(t.prefix(6)), ["-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ConnectTimeout=3"], "\(t)")
        XCTAssertTrue(t.contains("-N"), "\(t)")
        XCTAssertEqual(t.firstIndex(of: "-L").map { t[$0 + 1] }, "127.0.0.1:18080:127.0.0.1:8080", "\(t)")
        XCTAssertTrue(t.contains("tester@192.0.2.22"), "\(t)")
        XCTAssertFalse(t.contains("ControlMaster=auto"))
        let db = SessionCommand.dbTunnelArguments(via: was, host: "db.example.test", port: 5432, localPort: 15432, banner: "x")
        XCTAssertEqual(db.firstIndex(of: "-L").map { db[$0 + 1] }, "127.0.0.1:15432:db.example.test:5432", "\(db)")
        let banner = SessionCommand.dbBanner(server: was, host: "db.example.test", port: 5432, localPort: 15432, name: "testdb")
        XCTAssertTrue(banner.contains("jdbc:postgresql://localhost:15432/testdb"))
    }

    func testShellQuote() {
        XCTAssertEqual(shellQuote("it's"), "'it'\\''s'")
        XCTAssertEqual(shellQuote("a b"), "'a b'")
    }

    // 리뷰 #2: ssh 는 LocalCommand 의 % 토큰을 접속 후 확장한다(man ssh_config TOKENS: "LocalCommand accepts all tokens",
    // %% 만 리터럴). 모르는 토큰(%s)은 fatal 이라 배너에 % 가 들어가면 안 된다. 확장 자체는 접속 시에만 일어나
    // 오프라인으로는 옵션 문자열의 모양과 `ssh -G` 가 옵션을 받아들이는지까지만 확인한다.
    func testLocalCommandEscapesPercent() throws {
        let banner = "100% done · %h must stay literal"
        let option = SessionCommand.localCommandBanner(banner)
        XCTAssertEqual(option, "LocalCommand=printf '%%s\\n' '100%% done · %%h must stay literal'")
        // 이스케이프 뒤 남는 % 는 모두 %% 쌍이어야 한다 (홀수 개 % 가 남으면 토큰으로 해석된다)
        let payload = option.dropFirst("LocalCommand=".count)
        XCTAssertFalse(payload.replacingOccurrences(of: "%%", with: "").contains("%"), option)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-G", "-F", "/dev/null", "-o", option, "-o", "PermitLocalCommand=yes", "invalid.invalid"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }

    // 래퍼: ssh 가 0 이 아니면 안내를 찍고 키를 기다린 뒤 0 으로 끝난다 (bash -n 으로 문법만 확인)
    func testHoldOnFailureWrapper() throws {
        let wrapped = SessionCommand.holdOnFailure("'ssh' '-p' '22' 'u@h'")
        XCTAssertTrue(wrapped.hasPrefix("/bin/bash -c '"), wrapped)
        XCTAssertTrue(wrapped.contains("read -r -n 1"), wrapped)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = ["-n", "-c", "exec " + wrapped]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        // ssh 자체 실패(255)만 붙잡는다: 'exit 255' → 안내를 찍고 stdin(EOF)에서 read 가 끝난 뒤 0
        func runWrapped(_ cmd: String) throws -> (Int32, String) {
            let run = Process(); run.executableURL = URL(fileURLWithPath: "/bin/bash")
            run.arguments = ["-c", SessionCommand.holdOnFailure(cmd)]
            run.terminationHandler = { _ in }
            let out = Pipe(); run.standardOutput = out; run.standardInput = FileHandle.nullDevice
            try run.run()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            while run.isRunning { usleep(10_000) }
            return (run.terminationStatus, text)
        }
        let (rc255, t255) = try runWrapped("(exit 255)")   // ssh 처럼 255 를 "돌려주는" 명령
        XCTAssertTrue(t255.contains("[ssh 연결 실패 (255)]"), t255)
        XCTAssertEqual(rc255, 0)
        // 원격 셸의 마지막 명령 실패(exit 1)는 정상 로그아웃 → 대기 없이 그대로 끝난다
        let (rc1, t1) = try runWrapped("(exit 1)")
        XCTAssertFalse(t1.contains("아무 키나"), t1)
        XCTAssertEqual(rc1, 1)
    }

}
