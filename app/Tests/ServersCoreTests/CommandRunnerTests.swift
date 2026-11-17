// ProcessRunner·ProcessRegistry: 타임아웃·손자 프로세스·동시 호출·stdin. 로컬 명령(sh/cat/sleep)만 실행한다.

import Foundation
import XCTest
@testable import ServersCore

final class CommandRunnerTests: XCTestCase {

    /// 실행 파일 찾기는 한 곳 — 짧은 명령(ProcessRunner)·터널·전송이 같은 PATH(+ homebrew·Tailscale.app)를 본다
    func testResolveExecutable() {
        XCTAssertEqual(ProcessRunner.resolve("sh"), "/bin/sh")
        XCTAssertEqual(ProcessRunner.resolve("/bin/sh"), "/bin/sh")
        XCTAssertNil(ProcessRunner.resolve("/bin/no-such-tool-xyz"))
        XCTAssertNil(ProcessRunner.resolve("no-such-tool-xyz"))
    }

    /// Tailscale.app 안의 CLI 는 파일 이름이 Tailscale — 대소문자 구분 볼륨이나 ~/Applications 설치에서도 찾는다
    func testResolveTailscaleInsideAppBundle() {
        func resolve(_ files: Set<String>) -> String? {
            ProcessRunner.resolve("tailscale", path: "/usr/bin:/bin", home: "/Users/u", isExecutable: { files.contains($0) })
        }
        XCTAssertEqual(resolve(["/Applications/Tailscale.app/Contents/MacOS/Tailscale"]), "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
        XCTAssertEqual(resolve(["/Users/u/Applications/Tailscale.app/Contents/MacOS/Tailscale"]), "/Users/u/Applications/Tailscale.app/Contents/MacOS/Tailscale")
        XCTAssertEqual(resolve(["/opt/homebrew/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]), "/opt/homebrew/bin/tailscale",
                       "PATH·homebrew 의 CLI 가 먼저")
        XCTAssertNil(resolve([]))
        XCTAssertNil(ProcessRunner.resolve("ssh", path: "", home: "/Users/u", isExecutable: { $0.hasSuffix("/Tailscale") }), "앱 번들 경로는 tailscale 에만")
    }

    // 리뷰 #6·#7·#10: ProcessRunner 는 큰 stderr 에 데드락하지 않고, 타임아웃은 124, stdin 은 자식이 안 읽어도 안전.
    func testProcessRunnerLargeStderr() async {
        let r = await ProcessRunner().run("/bin/sh", ["-c", "head -c 300000 /dev/zero | tr '\\0' 'e' >&2; echo out"], timeout: 5)
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertEqual(r.stdout, "out\n")
        XCTAssertEqual(r.stderr.count, 300000)
    }

    func testProcessRunnerTimeout() async {
        let started = Date()
        let r = await ProcessRunner().run("/bin/sh", ["-c", "sleep 5"], timeout: 0.5)
        XCTAssertEqual(r.exitCode, CommandResult.timedOutExitCode)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    // 리뷰 2차 #3: 손자가 파이프를 쥐고 있어도 타임아웃이 트리 전체를 죽여 바로 돌아온다
    func testProcessRunnerTimeoutKillsGrandchildren() async {
        let started = Date()
        let r = await ProcessRunner().run("/bin/sh", ["-c", "sleep 6 & exec sleep 6"], timeout: 0.5)
        XCTAssertEqual(r.exitCode, CommandResult.timedOutExitCode)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "손자 sleep 이 stdout 을 쥐고 있어도 EOF 가 와야 한다")
    }

    func testProcessRunnerStdinNotReadByChild() async {
        // 자식이 stdin 을 읽지 않고 즉시 종료해도 크래시·데드락 없이 결과가 온다 (SIGPIPE 무시, 별도 큐 쓰기)
        let big = String(repeating: "x", count: 200_000)
        let r = await ProcessRunner().run("/bin/sh", ["-c", "exit 3"], stdin: big, timeout: 5)
        XCTAssertEqual(r.exitCode, 3)
        let r2 = await ProcessRunner().run("/bin/sh", ["-s"], stdin: "echo from-stdin\n", timeout: 5)
        XCTAssertEqual(r2.stdout, "from-stdin\n")
    }

    // 상태 갱신 루프가 멈췄던 회귀: 많은 명령을 동시에(성공·실패·타임아웃 섞어) 돌려도 전부 돌아온다
    func testProcessRunnerManyConcurrentCallsAllReturn() async {
        let started = Date()
        let results = await withTaskGroup(of: Int32.self) { group in
            for i in 0..<40 {
                group.addTask {
                    switch i % 4 {
                    case 0: return await ProcessRunner().run("/bin/sh", ["-c", "exit 0"], timeout: 5).exitCode
                    case 1: return await ProcessRunner().run("/bin/sh", ["-c", "echo x; exit 3"], timeout: 5).exitCode
                    case 2: return await ProcessRunner().run("/bin/sh", ["-c", "sleep 3"], timeout: 0.3).exitCode
                    default: return await ProcessRunner().run("/bin/sh", ["-c", "head -c 100000 /dev/zero >&2; exit 0"], timeout: 5).exitCode
                    }
                }
            }
            var out: [Int32] = []
            for await code in group { out.append(code) }
            return out
        }
        XCTAssertEqual(results.count, 40)
        XCTAssertEqual(results.filter { $0 == 0 }.count, 20)
        XCTAssertEqual(results.filter { $0 == 3 }.count, 10)
        XCTAssertEqual(results.filter { $0 == CommandResult.timedOutExitCode }.count, 10)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    // 리뷰 3차: 진행 중인 자식은 레지스트리에 있고, killAll 로 전부 끝나 run 이 돌아온다 (⌘Q 때 팝업 정리 경로)
    func testProcessRegistryKillAll() async {
        async let r = ProcessRunner().run("/bin/sh", ["-c", "sleep 20"], timeout: 30)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(ProcessRegistry.shared.running.isEmpty)
        ProcessRegistry.shared.killAll(signal: SIGTERM)
        let result = await r
        XCTAssertEqual(result.exitCode, SIGTERM)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(ProcessRegistry.shared.running.isEmpty)
    }

    // 블로킹 읽기가 GCD 풀을 쓰지 않으므로 64개를 넘는 동시 실행도 전부 돌아온다
    func testProcessRunnerBeyondGCDPoolStillReturns() async {
        let started = Date()
        let results = await withTaskGroup(of: Int32.self) { group in
            for _ in 0..<80 {
                group.addTask { await ProcessRunner().run("/bin/sh", ["-c", "sleep 0.5; exit 0"], timeout: 10).exitCode }
            }
            var out: [Int32] = []
            for await code in group { out.append(code) }
            return out
        }
        XCTAssertEqual(results.count, 80)
        XCTAssertTrue(results.allSatisfy { $0 == 0 })
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }

    func testProcessRunnerMissingExecutable() async {
        let r = await ProcessRunner().run("definitely-not-a-command-xyz", [], timeout: 1)
        XCTAssertEqual(r.exitCode, 127)
    }

    /// abortOnLine: 조건에 맞는 stderr 줄이 오면 타임아웃(10초)을 기다리지 않고 바로 끝내고, 그때까지의 출력을 돌려준다.
    func testAbortOnLineStopsEarly() async {
        let runner = ProcessRunner()
        let started = Date()
        let result = await runner.run("/bin/sh", ["-c", "echo 'To authenticate, visit: https://login.tailscale.com/a/abc' >&2; sleep 10; echo late"],
                                      stdin: nil, environment: [:], timeout: 10, abortOnLine: { $0.contains("login.tailscale.com") })
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "배너 직후 끊어야 한다")
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.stderr.contains("https://login.tailscale.com/a/abc"))
        XCTAssertFalse(result.stdout.contains("late"))
    }

    /// stdin 이 없으면 파이프 대신 /dev/null (쓰기 스레드 없음), 있으면 파이프로 그대로 전달한다
    func testNilStdinUsesNullDeviceAndStdinStillPipes() async {
        let probe = "if [ -p /dev/stdin ]; then echo pipe; else echo null; fi; cat; exit 5"
        let none = await ProcessRunner().run("/bin/sh", ["-c", probe], timeout: 5)
        XCTAssertEqual(none.exitCode, 5)
        XCTAssertEqual(none.stdout, "null\n", "stdin 이 없으면 /dev/null — cat 은 바로 EOF")
        let piped = await ProcessRunner().run("/bin/sh", ["-c", probe], stdin: "abc\n", timeout: 5)
        XCTAssertEqual(piped.exitCode, 5)
        XCTAssertEqual(piped.stdout, "pipe\nabc\n")
        let cat = await ProcessRunner().run("cat", [], stdin: "line1\nline2", timeout: 5)
        XCTAssertEqual(cat, CommandResult(exitCode: 0, stdout: "line1\nline2"))
    }

    /// 끝난 명령은 타이머(타임아웃·안전망)를 남기지 않는다 — 예전엔 타임아웃 + 5초 동안 Process·파이프 fd 를 쥐고 있었다
    func testCompletedRunsReleaseTimersAndPipes() async {
        func openFDs() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1 }
        let timersBefore = OneShotTimer.live.value, fdsBefore = openFDs()
        for _ in 0..<30 {
            let r = await ProcessRunner().run("/bin/sh", ["-c", "echo x; echo y >&2"], timeout: 120)
            XCTAssertEqual(r, CommandResult(exitCode: 0, stdout: "x\n", stderr: "y\n"))
        }
        // 타이머 취소는 큐에서 비동기로 마무리된다 — 잠깐 기다린다
        for _ in 0..<40 where OneShotTimer.live.value > timersBefore { try? await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(OneShotTimer.live.value, timersBefore, "완료된 명령의 타이머가 남아 있다")
        XCTAssertLessThanOrEqual(openFDs(), fdsBefore + 2, "완료된 명령의 파이프 fd 가 남아 있다")
    }

    /// 프로세스 트리 종료는 손자까지 (ps 대신 커널 표)
    func testProcessTreeKillReachesGrandchildren() throws {
        // 바깥 sh → 안쪽 sh → 백그라운드 sleep(손자). 안쪽 sh 가 손자 pid 를 알려 준다.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "/bin/sh -c 'sleep 30 & echo $!; sleep 30'; true"]
        let out = Pipe()
        process.standardOutput = out
        process.standardInput = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }
        var line = Data()
        while !line.contains(0x0A) {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            line.append(chunk)
        }
        let grandchild = try XCTUnwrap(pid_t(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let me = getpid()
        XCTAssertTrue(ProcessTree.processTable().contains { $0.pid == me && $0.ppid == getppid() })
        XCTAssertTrue(ProcessTree.descendants(of: process.processIdentifier).contains(grandchild))
        XCTAssertGreaterThanOrEqual(ProcessTree.descendants(of: process.processIdentifier).count, 2, "안쪽 sh(또는 exec 된 sleep)·손자")

        ProcessTree.kill(process.processIdentifier, signal: SIGKILL)
        // 고아가 된 손자는 launchd 가 거둔다 — 사라질 때까지 잠깐 기다린다
        var gone = false
        for _ in 0..<40 {
            if Darwin.kill(grandchild, 0) == -1, errno == ESRCH { gone = true; break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(gone, "손자 sleep(\(grandchild)) 이 살아 있다")
    }
}
