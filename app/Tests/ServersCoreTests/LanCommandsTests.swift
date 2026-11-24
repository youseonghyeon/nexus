// LanCommands: 관리자 스크립트(인증 먼저 → 비대화형 실행 · 승인 창 대체)와 결과 갈래. 가짜 sudo·osascript 로 이 Mac 안에서만 돈다.

import Foundation
import XCTest
@testable import ServersCore

final class LanCommandsTests: XCTestCase {
    /// Intranet 지정 때 순서 맨 뒤로: lan.zsh 를 불러 _lan_move_last 하나만. 켜기·끄기·전환·경로는 없다.
    func testMoveLastScript() throws {
        let script = LanCommands.moveLastScript("acme 내부망", libDir: "/x/lib")
        XCTAssertTrue(script.contains("source '/x/lib/lan.zsh' || exit 1\n_lan_move_last 'acme 내부망'"), script)
        XCTAssertFalse(script.contains("setadditionalroutes") || script.contains("setnetworkserviceenabled"), "순서만 바꾼다")
        XCTAssertTrue(script.contains("env -u SUDO_ASKPASS sudo -v"), "Touch ID 시트를 먼저 시도한다")
        XCTAssertEqual(try shellSyntaxStatus("/bin/zsh", script), 0)
    }

    /// 인증이 먼저: askpass 없는 `sudo -v`(Touch ID 시트). 성공하면 같은 셸에서 sudo 는 모두 -n.
    /// 실패하면 macOS 승인 창(osascript … with administrator privileges)으로 본문을 root 로 실행하고, 취소(-128)면 authFailedExitCode.
    func testServiceEnableScriptAuthenticatesFirstThenRunsNonInteractively() throws {
        let dir = tempPath("lan").path
        let bin = dir + "/bin", lib = dir + "/lib", log = dir + "/calls.log"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: lib, withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf 'sudo %s\\n' \"$*${SUDO_ASKPASS:+ askpass=$SUDO_ASKPASS}\" >> \"$FAKE_LOG\"\n[ -n \"$FAKE_SUDO_FAIL\" ] && exit 1\n[ \"$1\" = -n ] && [ -n \"$FAKE_SUDO_NOCACHE\" ] && exit 1\nexit 0\n".write(toFile: bin + "/sudo", atomically: true, encoding: .utf8)
        // 가짜 osascript: 프롬프트를 기록하고, 취소 시늉이면 진짜처럼 "(-128)" 오류, 아니면 진짜 do shell script 처럼 /bin/sh -c 로 본문을 실행한다.
        try "#!/bin/sh\nshift $(($# - 2)); cmd=$1; prompt=$2\nprintf 'osascript prompt=%s\\n' \"$prompt\" >> \"$FAKE_LOG\"\nif [ -n \"$FAKE_OSA_CANCEL\" ]; then echo 'execution error: User canceled. (-128)' >&2; exit 1; fi\nexec /bin/sh -c \"$cmd\"\n".write(toFile: bin + "/osascript", atomically: true, encoding: .utf8)
        try "#!/bin/sh\nprintf 'networksetup %s\\n' \"$*\" >> \"$FAKE_LOG\"\nexit 0\n".write(toFile: bin + "/networksetup", atomically: true, encoding: .utf8)
        for name in ["sudo", "osascript", "networksetup"] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin + "/" + name) }
        // Intranet 켜기도 다른 유선 서비스와 같은 활성화 스크립트 (2026-10-15 단순화)
        let script = LanCommands.serviceEnableScript("acme 내부망", on: true)
        func run(sudoFails: Bool, cancel: Bool = false, noCache: Bool = false) throws -> (Int32, [String], String) {
            try? FileManager.default.removeItem(atPath: log)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-c", script]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = bin + ":" + (env["PATH"] ?? "/usr/bin:/bin")
            env["FAKE_LOG"] = log
            env["SUDO_ASKPASS"] = "/x/askpass"
            if sudoFails { env["FAKE_SUDO_FAIL"] = "1" }
            if cancel { env["FAKE_OSA_CANCEL"] = "1" }
            if noCache { env["FAKE_SUDO_NOCACHE"] = "1" }
            p.environment = env
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            try p.run()
            let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            let lines = ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            return (p.terminationStatus, lines, stdout)
        }
        let (okCode, okLines, _) = try run(sudoFails: false)
        XCTAssertEqual(okCode, 0)
        XCTAssertEqual(okLines.first, "sudo -v", "첫 호출은 askpass 없이 Touch ID 인증만 (askpass 모드면 macOS 27 pam_tid 가 Touch ID 를 건너뛴다)")
        XCTAssertEqual(okLines.dropFirst().first, "sudo -n true askpass=/x/askpass", "캐시 자격이 실제로 남았는지 한 번 본다")
        XCTAssertEqual(okLines.dropFirst(2).first, "sudo -n networksetup -setnetworkserviceenabled acme 내부망 on askpass=/x/askpass", "이후는 캐시 자격으로 비대화형")
        XCTAssertEqual(okLines.count, 3, "Touch ID 로 됐으면 승인 창은 뜨지 않는다")

        // sudoers timestamp_timeout=0 (회사 보안 정책 Mac): sudo -v 는 되지만 자격이 남지 않아 sudo -n 이 실패한다 → 승인 창으로
        let (ncCode, ncLines, _) = try run(sudoFails: false, noCache: true)
        XCTAssertEqual(ncCode, 0)
        XCTAssertEqual(ncLines, ["sudo -v", "sudo -n true askpass=/x/askpass", "osascript prompt=acme 내부망 활성화",
                                 "networksetup -setnetworkserviceenabled acme 내부망 on"])

        let (fbCode, fbLines, _) = try run(sudoFails: true)
        XCTAssertEqual(fbCode, 0)
        XCTAssertEqual(fbLines, ["sudo -v", "osascript prompt=acme 내부망 활성화", "networksetup -setnetworkserviceenabled acme 내부망 on"],
                       "sudo -v 실패 → 승인 창 한 번 → 본문이 root 로 돌며 sudo 접두사는 그대로 통과한다")

        let (cancelCode, cancelLines, _) = try run(sudoFails: true, cancel: true)
        XCTAssertEqual(cancelCode, LanCommands.authFailedExitCode, "승인 창 취소(-128)는 authFailedExitCode")
        XCTAssertEqual(cancelLines.count, 2, "취소면 설정 명령을 실행하지 않는다")
    }

    /// 관리자 스크립트는 한 길로: zsh -c 로, 인증 창을 기다리는 시간까지 넉넉히. 결과는 인증 취소·시간 초과·실패로 가른다
    func testPrivilegedRunAndOutcome() async {
        let runner = FakeRunner()
        _ = await LanCommands.runPrivileged("echo hi", runner: runner)
        XCTAssertEqual(runner.calls.last, FakeRunner.Call(executable: "/bin/zsh", arguments: ["-c", "echo hi"]))
        XCTAssertGreaterThanOrEqual(LanCommands.privilegedTimeout, 180, "Touch ID → 암호 창까지 기다린다")

        XCTAssertEqual(PrivilegedOutcome(CommandResult(exitCode: 0)), .ok)
        XCTAssertEqual(PrivilegedOutcome(CommandResult(exitCode: LanCommands.authFailedExitCode)), .authCancelled)
        XCTAssertEqual(PrivilegedOutcome(CommandResult(exitCode: CommandResult.timedOutExitCode)), .timedOut)
        XCTAssertEqual(PrivilegedOutcome(CommandResult(exitCode: 1)), .failed)
        XCTAssertNil(PrivilegedOutcome.ok.authProblem)
        XCTAssertNil(PrivilegedOutcome.failed.authProblem, "작업 실패 문구는 부르는 쪽이")
        XCTAssertEqual(PrivilegedOutcome.authCancelled.authProblem, "인증을 취소했거나 실패했습니다")
        XCTAssertEqual(PrivilegedOutcome.timedOut.authProblem, "인증·실행이 3분 안에 끝나지 않았습니다")
    }
}
