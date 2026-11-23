// Transfer: scp 인자·진행률 파싱·프로세스 종료 보고.

import Foundation
import XCTest
@testable import ServersCore

final class TransferTests: XCTestCase {
    private var server: Server { try! ServerConfigParser.parse(fixture).server("nexus")! }

    func testArgumentsAndTitles() {
        let up = TransferSpec(server: server, direction: .upload, localPaths: ["/tmp/a b.zip", "/tmp/dir"], remotePath: "")
        let args = up.arguments(home: "/h")
        XCTAssertEqual(Array(args.suffix(3)), ["/tmp/a b.zip", "/tmp/dir", "tester@100.64.0.1:"], "빈 원격 경로 = 홈")
        XCTAssertTrue(args.contains("-r")); XCTAssertTrue(args.contains("ControlPath=/h/.ssh/srv-%C"))
        XCTAssertEqual(args[args.firstIndex(of: "-P")! + 1], "2222")
        XCTAssertEqual(up.title, "↑ a b.zip, dir → nexus")
        let down = TransferSpec(server: server, direction: .download, localPaths: ["/Users/me/Downloads"], remotePath: "/var/log/syslog")
        XCTAssertEqual(Array(down.arguments(home: "/h").suffix(2)), ["tester@100.64.0.1:/var/log/syslog", "/Users/me/Downloads"])
        XCTAssertEqual(down.title, "↓ nexus:/var/log/syslog")
        XCTAssertEqual(up.name, "a b.zip, dir → nexus", "사이드바 행은 화살표 없이 — 방향은 기호로")
        XCTAssertEqual(down.name, "nexus:/var/log/syslog")
        let many = TransferSpec(server: server, direction: .upload, localPaths: ["/a", "/b", "/c"], remotePath: "x")
        XCTAssertEqual(many.title, "↑ a 외 2개 → nexus")
    }

    func testNoticeOnFinish() {
        let spec = TransferSpec(server: server, direction: .upload, localPaths: ["/tmp/big.iso"], remotePath: "")
        let long = TransferNotice.minimumDuration + 1
        XCTAssertEqual(TransferNotice.content(for: .done, spec: spec, elapsed: long)?.title, "전송 완료")
        XCTAssertEqual(TransferNotice.content(for: .done, spec: spec, elapsed: long)?.body, "↑ big.iso → nexus")
        XCTAssertNil(TransferNotice.content(for: .done, spec: spec, elapsed: 3), "몇 초짜리 완료는 상태줄로 충분")
        let failed = TransferNotice.content(for: .failed(exitCode: 1, message: "scp: connecting\nscp: /x: Permission denied"), spec: spec, elapsed: 2)
        XCTAssertEqual(failed?.title, "전송 실패", "실패는 짧아도 알린다")
        XCTAssertEqual(failed?.body, "↑ big.iso → nexus\nscp: /x: Permission denied", "마지막 줄이 이유")
        XCTAssertEqual(TransferNotice.content(for: .failed(exitCode: 255, message: ""), spec: spec, elapsed: 2)?.body, "↑ big.iso → nexus\nexit 255")
        XCTAssertNil(TransferNotice.content(for: .cancelled, spec: spec, elapsed: long), "취소는 직접 한 일")
        XCTAssertNil(TransferNotice.content(for: .running(nil), spec: spec, elapsed: long))
    }

    func testProgressParsing() {
        let p = TransferProgress.parse("report.zip                                    45%  123MB  10.1MB/s   00:12 ETA")!
        XCTAssertEqual(p.file, "report.zip"); XCTAssertEqual(p.percent, 45); XCTAssertEqual(p.transferred, "123MB")
        XCTAssertEqual(p.rate, "10.1MB/s"); XCTAssertEqual(p.eta, "00:12")
        let done = TransferProgress.parse("a b.txt   100%   12KB   1.2MB/s   00:00")!
        XCTAssertEqual(done.file, "a b.txt"); XCTAssertEqual(done.percent, 100); XCTAssertEqual(done.eta, "00:00")
        XCTAssertNil(TransferProgress.parse("scp: /nope: No such file or directory"))
        // 로케일 없이 돌린 scp 의 8진수 이름 (실측: NFD 한글) → 되돌려서 NFC 로
        let octal = TransferProgress.parse("\\341\\204\\211\\341\\205\\265\\341\\206\\267.mp4   49%  1040MB  45.9MB/s   00:22 ETA")!
        XCTAssertEqual(octal.file, "심.mp4")
        XCTAssertEqual(octal.file.unicodeScalars.count, 5, "NFC 로 합쳐져 있어야 한다 (심 = 1 스칼라)")
        XCTAssertNil(TransferProgress.parse("bob@100.64.0.1: Permission denied (publickey,password)."))
    }

    /// 가짜 scp: 진행률을 \r 로 찍고 끝난다. 진행률 콜백 순서와 종료 코드, 취소 시 SIGTERM 을 확인한다.
    func testProcessReportsProgressAndExit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("scp").path
        try """
        #!/bin/sh
        printf 'file.bin    10%%   1MB   1.0MB/s   00:09 ETA\r'
        printf 'file.bin    60%%   6MB   1.0MB/s   00:04 ETA\r'
        printf 'file.bin   100%%  10MB   1.0MB/s   00:10\r\n'
        if [ "$FAKE_SCP_FAIL" = 1 ]; then echo 'scp: /nope: No such file or directory' >&2; exit 1; fi
        if [ "$FAKE_SCP_HANG" = 1 ]; then sleep 30; fi
        exit 0
        """.write(toFile: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)

        func run(env: [String: String], stopAfterFirstProgress: Bool = false) throws -> (Int32, String, [Int]) {
            let process = TransferProcess()
            let box = DataBox()
            let exited = expectation(description: "exit")
            let holder = ExitHolder()
            process.onProgress = { p in
                box.lock.withLock { box.percents.append(p.percent) }
                if stopAfterFirstProgress { process.stop() }
            }
            process.onExit = { code, message in holder.set(code, message); exited.fulfill() }
            try process.start(executable: fake, arguments: [], environment: env)
            wait(for: [exited], timeout: 10)
            return (holder.code, holder.message, box.lock.withLock { box.percents })
        }
        let ok = try run(env: [:])
        XCTAssertEqual(ok.0, 0); XCTAssertEqual(ok.2, [10, 60, 100])
        let fail = try run(env: ["FAKE_SCP_FAIL": "1"])
        XCTAssertEqual(fail.0, 1); XCTAssertTrue(fail.1.contains("No such file"), fail.1)
        let cancelled = try run(env: ["FAKE_SCP_HANG": "1"], stopAfterFirstProgress: true)
        XCTAssertEqual(cancelled.0, 128 + SIGTERM, "취소는 SIGTERM")
    }

    /// 진짜 scp(SFTP 모드)가 진행률을 찍는지 — 로컬 sftp-server 를 ssh 대신 붙여(-S) 네트워크 없이 돈다.
    /// 회귀: Process 로 pty 만 붙였을 때는 scp 가 전경 프로세스 그룹이 아니라 진행률을 한 줄도 안 찍었다 (연결 중 → 완료로만 보이던 것).
    func testRealScpEmitsProgressUnderScriptWrapper() throws {
        let sftpServer = "/usr/libexec/sftp-server"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: sftpServer), "sftp-server 없음")
        let root = NSTemporaryDirectory() + "scp-progress-\(UUID().uuidString)"
        let home = root + "/home", src = root + "/src"
        try FileManager.default.createDirectory(atPath: home + "/dest", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
        for i in 0..<5 { try Data(count: 200_000).write(to: URL(fileURLWithPath: "\(src)/f\(i).bin")) }
        // scp 가 "ssh -s host sftp" 대신 부를 것: 홈으로 이동해 sftp-server 를 stdin/stdout 에 직접 붙인다
        let fakeSSH = root + "/fake-ssh"
        try "#!/bin/sh\ncd '\(home)' && exec \(sftpServer)\n".write(toFile: fakeSSH, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSSH)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let process = TransferProcess()
        let box = DataBox()
        let exited = expectation(description: "exit")
        let holder = ExitHolder()
        process.onProgress = { p in box.lock.withLock { box.percents.append(p.percent) } }
        process.onExit = { code, message in holder.set(code, message); exited.fulfill() }
        try process.start(executable: "scp", arguments: ["-S", fakeSSH, "-r", src, "u@h:dest/"], environment: [:])
        wait(for: [exited], timeout: 30)
        XCTAssertEqual(holder.code, 0, holder.message)
        let uploaded = try FileManager.default.contentsOfDirectory(atPath: home + "/dest/src")
        XCTAssertEqual(uploaded.count, 5)
        let percents = box.lock.withLock { box.percents }
        XCTAssertFalse(percents.isEmpty, "진행률이 한 번도 안 왔다 — scp 가 전경 프로세스 그룹이 아닌 것")
        XCTAssertTrue(percents.contains(100), "\(percents)")
    }

    /// 내부망 서버 전송은 그 서비스의 장치에 묶는다 (시스템 경로가 없으므로).
    func testArgumentsBindInterfaceForLanServer() {
        let spec = TransferSpec(server: server, direction: .download, localPaths: ["/tmp/out"], remotePath: "a.zip", bindInterface: "en10")
        let args = spec.arguments(home: "/h")
        XCTAssertTrue(args.contains("BindInterface=en10"), args.joined(separator: " "))
        XCTAssertEqual(args.suffix(2), ["\(server.target):a.zip", "/tmp/out"])
        XCTAssertFalse(TransferSpec(server: server, direction: .download, localPaths: ["/tmp/out"], remotePath: "a.zip").arguments(home: "/h").contains("BindInterface=en10"))
    }

    /// Foundation Process 는 arguments 를 NFD 로 바꿔 넘긴다 (한글 자모 분리). 전송 경로는 바이트 그대로 가야 한다 —
    /// Windows(NTFS)는 NFC 파일을 못 찾고 Linux 엔 중복 폴더가 생겼던 회귀.
    func testArgumentsKeepNFCBytes() throws {
        let dir = NSTemporaryDirectory() + "nfc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let dump = dir + "/dump.sh"
        try "#!/bin/sh\nprintf '%s' \"$2\" | xxd -p\n".write(toFile: dump, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dump)
        let process = TransferProcess()
        let lines = LineBox()
        let exited = expectation(description: "exit")
        process.onLine = { l in lines.lock.withLock { lines.lines.append(l) } }
        process.onExit = { _, _ in exited.fulfill() }
        let nfc = "신병"   // EC 8B A0 EB B3 91
        XCTAssertEqual(Array(nfc.utf8).count, 6)
        try process.start(executable: dump, arguments: ["-r", "u@h:/D:/\(nfc)/x"], environment: [:])
        wait(for: [exited], timeout: 10)
        let hex = lines.lock.withLock { lines.lines.joined() }.replacingOccurrences(of: "\n", with: "")
        XCTAssertTrue(hex.contains("ec8ba0ebb391"), "NFC 그대로여야 한다 (NFD 면 e18489…): \(hex)")
        XCTAssertFalse(hex.contains("e18489"), hex)
    }

    private final class LineBox: @unchecked Sendable { let lock = NSLock(); var lines: [String] = [] }
    private final class DataBox: @unchecked Sendable { let lock = NSLock(); var percents: [Int] = [] }
    private final class ExitHolder: @unchecked Sendable {
        private let lock = NSLock(); private(set) var code: Int32 = -1; private(set) var message = ""
        func set(_ c: Int32, _ m: String) { lock.withLock { code = c; message = m } }
    }

    /// 실행에 실패하면(래퍼 없음) pty 양쪽 fd 를 닫고 던진다 — 예전엔 시도마다 fd 둘과 임시 스크립트가 남았다
    func testFailedStartReleasesPtyDescriptors() {
        func openFDs() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1 }
        let before = openFDs()
        for _ in 0..<10 {
            let process = TransferProcess()
            process.wrapper = "/nonexistent/script-wrapper"
            XCTAssertThrowsError(try process.start(executable: "/bin/echo", arguments: ["x"], environment: [:]))
            XCTAssertFalse(process.isRunning)
        }
        XCTAssertLessThanOrEqual(openFDs(), before + 2, "실패한 시작이 pty fd 를 남겼다 (10번이면 20개)")
    }

    // 빠른 줄 폭주: 예약(true)은 한 번뿐이고, drain 은 모든 줄을 순서대로 돌려주며, 마지막 값이 빠지지 않는다
    func testCoalescerSchedulesOnceAndKeepsEveryLine() {
        let c = ProgressCoalescer()
        func line(_ n: Int) -> TransferProgress { TransferProgress(file: "f", percent: n, transferred: "\(n)KB", rate: "1KB/s", eta: "00:01") }
        var schedules = 0
        for n in 1...100 where c.push(line(n)) { schedules += 1 }
        XCTAssertEqual(schedules, 1, "100줄이 와도 갱신 예약은 한 번")
        let batch = c.drain()
        XCTAssertEqual(batch.map(\.percent), Array(1...100), "meter 가 모든 줄을 보게")
        XCTAssertEqual(batch.last?.percent, 100)
        XCTAssertTrue(c.drain().isEmpty)
        XCTAssertTrue(c.push(line(1)), "비운 뒤 첫 줄은 다시 예약")
    }
}
