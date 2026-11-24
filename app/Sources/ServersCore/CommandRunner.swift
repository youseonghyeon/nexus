// 외부 명령 실행 추상화. 앱은 ProcessRunner 를, 테스트는 기록·응답하는 가짜 러너를 쓴다.
// 한 번 돌리고 결과를 받는 호출(ssh·tailscale·networksetup)은 이 인터페이스를 거친다.
// 거치지 않는 것: TCP 확인(TCPProbe — 소켓) · 오래 도는 프로세스(터널·전송·패킷 캡처 — Process 를 직접 띄운다).

import Foundation

public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
    public var ok: Bool { exitCode == 0 }
    /// 타임아웃으로 강제 종료됐을 때의 종료 코드 (GNU timeout 과 같은 값)
    public static let timedOutExitCode: Int32 = 124
}

public protocol CommandRunner: Sendable {
    /// PATH 에서 찾은 실행 파일을 인자와 함께 실행한다. 타임아웃(초)이 지나면 SIGKILL 하고 exitCode 124 를 돌려준다.
    /// environment 는 현재 환경에 덧씌운다 (SSH_ASKPASS 같은 훅 전달용).
    func run(_ executable: String, _ arguments: [String], stdin: String?, environment: [String: String], timeout: TimeInterval) async -> CommandResult
    /// 같되, stderr 에 abortOnLine 이 true 인 줄이 오면 그 즉시 프로세스를 끝낸다 (출력은 그때까지 모은 것).
    /// 서버가 응답을 붙들고 기다리는 경우(Tailscale SSH check 배너)에 타임아웃까지 안 기다리려고.
    func run(_ executable: String, _ arguments: [String], stdin: String?, environment: [String: String], timeout: TimeInterval,
             abortOnLine: (@Sendable (String) -> Bool)?) async -> CommandResult
    func hasExecutable(_ name: String) -> Bool
}

public extension CommandRunner {
    func run(_ executable: String, _ arguments: [String], stdin: String? = nil, timeout: TimeInterval = 10) async -> CommandResult {
        await run(executable, arguments, stdin: stdin, environment: [:], timeout: timeout)
    }

    /// 기본 구현: 조기 중단 없이 그냥 실행 (가짜 러너는 출력이 한 번에 오므로 충분하다)
    func run(_ executable: String, _ arguments: [String], stdin: String?, environment: [String: String], timeout: TimeInterval,
             abortOnLine: (@Sendable (String) -> Bool)?) async -> CommandResult {
        await run(executable, arguments, stdin: stdin, environment: environment, timeout: timeout)
    }
}

public struct ProcessRunner: CommandRunner {
    public init() {
        // 자식이 stdin 을 읽기 전에 죽으면 write 가 SIGPIPE 를 받는다. 앱 전체가 죽지 않도록 무시하고 EPIPE 로 받는다.
        signal(SIGPIPE, SIG_IGN)
    }

    public func hasExecutable(_ name: String) -> Bool {
        Self.resolve(name) != nil
    }

    /// 실행 파일 경로: 절대 경로는 실행 가능할 때만, 이름은 PATH + homebrew·Tailscale.app (앱은 로그인 셸 PATH 를 못 받는다). 터널·전송도 이걸 쓴다.
    public static func resolve(_ name: String) -> String? {
        resolve(name, path: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin", home: NSHomeDirectory(),
                isExecutable: FileManager.default.isExecutableFile(atPath:))
    }

    static func resolve(_ name: String, path: String, home: String, isExecutable: (String) -> Bool) -> String? {
        if name.hasPrefix("/") { return isExecutable(name) ? name : nil }
        for dir in path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"] {
            let candidate = "\(dir)/\(name)"
            if isExecutable(candidate) { return candidate }
        }
        // Tailscale.app 안의 CLI: 파일 이름은 Tailscale (대소문자 구분 볼륨에선 tailscale 로 못 찾는다) · ~/Applications 에 둔 Mac 도
        if name == "tailscale" {
            for apps in ["/Applications", home + "/Applications"] {
                let candidate = apps + "/Tailscale.app/Contents/MacOS/Tailscale"
                if isExecutable(candidate) { return candidate }
            }
        }
        return nil
    }

    public func run(_ executable: String, _ arguments: [String], stdin: String?, environment: [String: String], timeout: TimeInterval) async -> CommandResult {
        await run(executable, arguments, stdin: stdin, environment: environment, timeout: timeout, abortOnLine: nil)
    }

    public func run(_ executable: String, _ arguments: [String], stdin: String?, environment: [String: String], timeout: TimeInterval,
                    abortOnLine: (@Sendable (String) -> Bool)?) async -> CommandResult {
        guard let path = Self.resolve(executable) else {
            return CommandResult(exitCode: 127, stderr: "\(executable): command not found")
        }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            if !environment.isEmpty || ProcessInfo.processInfo.environment["LANG"] == nil {
                process.environment = ProcessLocale.environment(adding: environment)
            }
            let outPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            // 줄 입력이 없으면 파이프·쓰기 스레드 없이 /dev/null (상태 갱신의 대부분). 비워 두면 앱의 stdin 을 물려받는다.
            let inPipe: Pipe? = stdin == nil ? nil : Pipe()
            process.standardInput = inPipe ?? FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                continuation.resume(returning: CommandResult(exitCode: 126, stderr: "\(error)"))
                return
            }
            let pid = process.processIdentifier
            ProcessRegistry.shared.add(pid)
            let timedOut = TimedOutFlag()
            let queue = DispatchQueue.global(qos: .userInitiated)
            let outBox = DataBox(), errBox = DataBox()
            let timers = TimerSet()
            // 완료 조건 셋(stdout EOF, stderr EOF, 종료 통지)이 모두 차면 한 번만 resume 한다.
            // waitUntilExit 는 쓰지 않는다: 자식이 이미 끝났는데도 돌아오지 않는 경우가 있어 상태 갱신 전체가 멈췄다.
            let done = Completion(needed: 3) {
                ProcessRegistry.shared.remove(pid)
                // 끝난 명령의 타이머를 걷는다 — 두면 Process·파이프를 타임아웃 + 5초(프롬프트 실행은 185초)까지 쥐고 있다.
                timers.cancelAll()
                // 안전망으로 강제 완료된 경우 아직 살아 있을 수 있다. 그때 terminationStatus 를 읽으면 예외로 죽는다.
                guard !process.isRunning else {
                    continuation.resume(returning: CommandResult(exitCode: CommandResult.timedOutExitCode,
                                                                 stdout: String(decoding: outBox.data, as: UTF8.self),
                                                                 stderr: String(decoding: errBox.data, as: UTF8.self)))
                    return
                }
                let killedByUs = timedOut.value && process.terminationReason == .uncaughtSignal
                    && process.terminationStatus == SIGKILL
                continuation.resume(returning: CommandResult(
                    exitCode: killedByUs ? CommandResult.timedOutExitCode : process.terminationStatus,
                    stdout: String(decoding: outBox.data, as: UTF8.self),
                    stderr: String(decoding: errBox.data, as: UTF8.self)))
            }
            process.terminationHandler = { _ in done.step() }

            // stdin 은 별도 스레드에서 쓴다: 자식이 안 읽으면(즉시 실패) 파이프 버퍼(64 KiB)에 막히지 않게.
            if let inPipe, let stdin {
                blockingThread("run.stdin") {
                    if let data = stdin.data(using: .utf8) {
                        try? inPipe.fileHandleForWriting.write(contentsOf: data)
                    }
                    try? inPipe.fileHandleForWriting.close()
                }
            }
            timers.add(OneShotTimer(after: timeout, queue: queue) {
                if process.isRunning {
                    timedOut.set()
                    ProcessTree.kill(pid, signal: SIGKILL)
                }
            })
            // 안전망: 종료 통지가 끝내 안 오면 타임아웃 + 5초 뒤 강제 완료 (남은 조건을 모두 채운다)
            timers.add(OneShotTimer(after: timeout + 5, queue: queue) {
                if !done.isDone {
                    timedOut.set()
                    ProcessTree.kill(pid, signal: SIGKILL)
                    done.force()
                }
            })
            // stdout 과 stderr 를 동시에 비운다. 순서대로 읽으면 한쪽이 64 KiB 를 넘길 때 자식이 막혀 데드락이 된다.
            // 읽은 쪽이 EOF 뒤 바로 닫는다 (Process 가 풀리길 기다리지 않는다). 안전망으로 먼저 완료돼도 읽던 스레드가 끝날 때 닫는다.
            blockingThread("run.stdout") {
                let handle = outPipe.fileHandleForReading
                outBox.data = handle.readDataToEndOfFile()
                try? handle.close()
                done.step()
            }
            blockingThread("run.stderr") {
                if let abortOnLine {
                    // 줄 단위로 읽다가 조건에 맞는 줄이 오면 즉시 끝낸다. 나머지는 EOF 까지 마저 모은다.
                    let handle = errPipe.fileHandleForReading
                    var data = Data(), scanned = 0, aborted = false
                    while true {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }
                        data.append(chunk)
                        if !aborted, let nl = data[scanned...].lastIndex(of: 0x0A) {
                            let lines = String(decoding: data[scanned...nl], as: UTF8.self).split(separator: "\n").map(String.init)
                            scanned = nl + 1
                            if lines.contains(where: abortOnLine) { aborted = true; ProcessTree.kill(pid, signal: SIGKILL) }
                        }
                    }
                    errBox.data = data
                } else {
                    errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
                }
                try? errPipe.fileHandleForReading.close()
                done.step()
            }
        }
    }
}
