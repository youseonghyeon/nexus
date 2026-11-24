// servers-askpass 헬퍼: 프롬프트 응답·취소·호스트 키·세션 비밀번호 1회 사용.

import Foundation
import XCTest
@testable import ServersCore

final class AskPassTests: XCTestCase {
    /// 빌드된 servers-askpass (테스트 번들 옆). 디버그 훅 SERVERS_ASKPASS_TEST_RESPONSE 로 창 없이 답을 정한다.
    private var helper: String {
        Bundle(for: AskPassTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("servers-askpass").path
    }

    private func runHelper(prompt: String, response: String) throws -> (Int32, String) {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper), "servers-askpass 가 빌드되지 않았습니다: \(helper)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: helper)
        p.arguments = [prompt]
        p.environment = ["PATH": "/usr/bin:/bin", "SERVERS_ASKPASS_TEST_RESPONSE": response]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func testPasswordEntered() throws {
        let (rc, out) = try runHelper(prompt: "tester@192.0.2.22's password: ", response: "p@ss w\"ord")
        XCTAssertEqual(rc, 0)
        XCTAssertEqual(out, "p@ss w\"ord\n")
    }

    func testCancelFails() throws {
        // 부모가 ssh 가 아니면(여기서는 테스트 러너) 그냥 1 로 끝난다
        let (rc, out) = try runHelper(prompt: "password: ", response: "cancel")
        XCTAssertEqual(rc, 1)
        XCTAssertEqual(out, "")
    }

    func testCancelTerminatesParentSSH() throws {
        // 부모 이름이 ssh 이면 취소 시 부모를 SIGTERM 으로 끝낸다 → 다음 프롬프트로 넘어가지 않는다
        let dir = tempPath("askpass-parent")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 가짜 "ssh": 헬퍼를 두 번 부른다. 첫 취소에서 자기 자신이 죽어야 하므로 두 번째 프롬프트는 나오지 않는다.
        let fakeSSH = dir.appendingPathComponent("ssh")
        try "#!/bin/sh\n\"\(helper)\" 'password: '; echo prompt-2; \"\(helper)\" 'password: '; echo survived\n".write(to: fakeSSH, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSSH.path)
        let p = Process()
        p.executableURL = fakeSSH
        p.environment = ["PATH": "/usr/bin:/bin", "SERVERS_ASKPASS_TEST_RESPONSE": "cancel"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(p.terminationReason, .uncaughtSignal)
        XCTAssertEqual(p.terminationStatus, SIGTERM)
        XCTAssertFalse(text.contains("prompt-2"), text)
    }

    func testHostKeyPromptAnswersYesNo() throws {
        let prompt = "The authenticity of host 'x' can't be established. Are you sure you want to continue connecting (yes/no/[fingerprint])? "
        XCTAssertEqual(AskPassHelper.kind(of: prompt), .yesNo)
        XCTAssertEqual(AskPassHelper.kind(of: "password: "), .secret)
        let (rc, out) = try runHelper(prompt: prompt, response: "yes")
        XCTAssertEqual(rc, 0); XCTAssertEqual(out, "yes\n")
        let (rc2, out2) = try runHelper(prompt: prompt, response: "no")
        XCTAssertEqual(rc2, 0); XCTAssertEqual(out2, "no\n")
    }

    /// 세션 비밀번호: 같은 부모(ssh)의 첫 호출은 창 없이 대입, 두 번째(틀림)는 창. 부모가 다르면 다시 첫 호출.
    func testSessionPasswordUsedOnceThenPrompts() throws {
        let dir = tempPath("askpass-session")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fakeSSH = dir.appendingPathComponent("ssh")
        try "#!/bin/sh\n\"\(helper)\" 'password: '; \"\(helper)\" 'password: '; \"\(helper)\" 'password: '\n".write(to: fakeSSH, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSSH.path)
        func run() throws -> String {
            let p = Process()
            p.executableURL = fakeSSH
            p.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": dir.path, "SERVERS_ASKPASS_PASSWORD": "s3cret",
                             "SERVERS_ASKPASS_TEST_RESPONSE": "typed"]
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        XCTAssertEqual(try run(), "s3cret\ntyped\ntyped\n", "첫 물음만 세션 비밀번호, 이후는 창(훅 답). 세 번째에 틀린 비밀번호를 다시 대입하지 않는다")
        XCTAssertEqual(try run(), "s3cret\ntyped\ntyped\n", "새 ssh(다른 pid)는 다시 첫 호출부터")
        // 호스트 키 확인은 세션 비밀번호와 무관
        let (rc, out) = try runHelperWithEnv(prompt: "Are you sure you want to continue connecting (yes/no)? ", response: "yes", extra: ["SERVERS_ASKPASS_PASSWORD": "s3cret", "TMPDIR": dir.path])
        XCTAssertEqual(rc, 0); XCTAssertEqual(out, "yes\n")
    }

    /// 암호 걸린 키 파일의 암호 물음에는 서버 비밀번호를 대입하지 않는다 — 넣으면 틀린 암호가 되고, 뒤따르는 진짜 비밀번호 물음엔 대입되지 않는다
    func testPassphrasePromptDoesNotGetSessionPassword() throws {
        XCTAssertTrue(AskPassHelper.usesSessionPassword(for: "tester@192.0.2.22's password: "))
        XCTAssertTrue(AskPassHelper.usesSessionPassword(for: "(tester@192.0.2.22) Password: "))
        XCTAssertFalse(AskPassHelper.usesSessionPassword(for: "Enter passphrase for key '/Users/me/.ssh/aws.pem': "))
        XCTAssertFalse(AskPassHelper.usesSessionPassword(for: "Are you sure you want to continue connecting (yes/no/[fingerprint])? "))

        let dir = tempPath("askpass-passphrase")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 가짜 "ssh": 키 암호 → 비밀번호 순서로 묻는다. 암호 물음은 창(훅 답), 비밀번호 물음은 첫 호출이라 세션 비밀번호
        let fakeSSH = dir.appendingPathComponent("ssh")
        try "#!/bin/sh\n\"\(helper)\" \"Enter passphrase for key '/k/aws.pem': \"; \"\(helper)\" 'password: '\n".write(to: fakeSSH, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSSH.path)
        let p = Process()
        p.executableURL = fakeSSH
        p.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": dir.path, "SERVERS_ASKPASS_PASSWORD": "s3cret", "SERVERS_ASKPASS_TEST_RESPONSE": "typed"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "typed\ns3cret\n")
    }

    private func runHelperWithEnv(prompt: String, response: String, extra: [String: String]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: helper)
        p.arguments = [prompt]
        p.environment = ["PATH": "/usr/bin:/bin", "SERVERS_ASKPASS_TEST_RESPONSE": response].merging(extra) { _, new in new }
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func testClaimFirstUseMarker() throws {
        let dir = tempPath("askpass-marker")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let marker = AskPassHelper.markerURL(parent: 4242, directory: dir)
        XCTAssertEqual(marker.lastPathComponent, "servers-askpass-4242")
        XCTAssertTrue(AskPassHelper.claimFirstUse(marker: marker))
        XCTAssertFalse(AskPassHelper.claimFirstUse(marker: marker))
        XCTAssertTrue(AskPassHelper.claimFirstUse(marker: marker, now: Date().addingTimeInterval(200)), "오래된 마커는 무시하고 다시 첫 호출로")
        let perms = try FileManager.default.attributesOfItem(atPath: marker.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func testParentDetection() {
        XCTAssertTrue(AskPassHelper.isSSH(comm: "/usr/bin/ssh", args: "ssh -N host"))
        XCTAssertTrue(AskPassHelper.isSSH(comm: "/bin/sh", args: "/bin/sh /tmp/x/ssh 'password: '"), "테스트의 가짜 ssh 스크립트")
        XCTAssertFalse(AskPassHelper.isSSH(comm: "sudo", args: "sudo -A -v"))
        XCTAssertFalse(AskPassHelper.isSSH(comm: "/bin/sh", args: "/bin/sh /tmp/sshd"))
        XCTAssertFalse(AskPassHelper.parentIsSSH(pid: getpid()), "테스트 러너는 ssh 가 아니다")
    }

    func testAskPassEnvironmentAndOptions() {
        let env = AskPass.environment(helper: "/x/servers-askpass", title: "win · bob@100.64.0.2")
        XCTAssertEqual(env["SSH_ASKPASS"], "/x/servers-askpass")
        XCTAssertEqual(env["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertEqual(AskPass.options, ["-o", "NumberOfPasswordPrompts=2"])
        XCTAssertNil(env["SERVERS_ASKPASS_PASSWORD"])
        XCTAssertEqual(AskPass.environment(helper: "/x", title: "t", password: "pw")["SERVERS_ASKPASS_PASSWORD"], "pw")
        XCTAssertNil(AskPass.environment(helper: "/x", title: "t", password: "")["SERVERS_ASKPASS_PASSWORD"], "빈 비밀번호는 넘기지 않는다")
        XCTAssertEqual(AskPass.singleAttempt, ["-o", "NumberOfPasswordPrompts=1"])
    }

    func testProcessRunnerPassesEnvironment() async {
        let r = await ProcessRunner().run("/bin/sh", ["-c", "printf '%s' \"$SSH_ASKPASS\""], stdin: nil,
                                          environment: ["SSH_ASKPASS": "/tmp/helper"], timeout: 5)
        XCTAssertEqual(r.stdout, "/tmp/helper")
    }
}
