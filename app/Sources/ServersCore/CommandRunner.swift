// 외부 명령 실행 추상화. 앱은 ProcessRunner 를, 테스트는 기록·응답하는 가짜 러너를 쓴다.
// 실제 서버에 닿는 모든 호출(ssh·nc·tailscale·networksetup)은 이 인터페이스를 거친다.

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

/// 연결 시도 정책 (연결 타임아웃·재시도).
public enum ConnectPolicy {
    public static let timeoutSeconds = 3
    public static var sshOptions: [String] {
        ["-o", "ConnectTimeout=\(timeoutSeconds)", "-o", "ConnectionAttempts=1"]
    }
    /// SSH 탭·전송·상태 확인이 이 소켓으로 연결을 공유한다. 이름 srv-%C 는 삭제된 srv TUI 와 함께 쓰던 때 그대로다.
    public static func controlOptions(home: String = NSHomeDirectory()) -> [String] {
        ["-o", "ControlMaster=auto", "-o", "ControlPath=\(home)/.ssh/srv-%C", "-o", "ControlPersist=10m"]
    }
    /// 공유 연결을 쓰지 않는 전용 연결 (터널: 공유 연결을 거치면 ssh -N 이 즉시 끝난다 · Tailscale 로그인: 새 연결이어야 배너가 온다)
    public static let noControlOptions = ["-o", "ControlMaster=no", "-o", "ControlPath=none"]

    /// ssh·scp·sftp 공통 앞부분: 연결 정책 + 포트 + 연결 공유 + 장치 묶기. scp·sftp 는 portFlag "-P".
    public static func sharedArguments(port: Int, portFlag: String = "-p", bindInterface: String?, home: String = NSHomeDirectory(),
                                       identity: String? = nil) -> [String] {
        sshOptions + [portFlag, "\(port)"] + controlOptions(home: home) + bindOptions(bindInterface) + identityOptions(identity)
    }

    /// 서버별 키 파일 (Server.identityFile). 파일이 없으면 붙이지 않는다 — 지워졌어도 지금처럼 기본 키·비밀번호로 접속한다.
    /// IdentitiesOnly: 기본 키·agent 키를 먼저 시도하다 "Too many authentication failures" 로 끊기지 않게 이 키만 (비밀번호 인증은 그대로).
    public static func identityOptions(_ path: String?, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String] {
        guard let path, !path.isEmpty, fileExists(path) else { return [] }
        return ["-i", path, "-o", "IdentitiesOnly=yes"]
    }

    /// 내부망 서버로 가는 연결을 그 서비스의 장치(en10 등)에 묶는다. 시스템 경로 없이 장치의 스코프 기본 경로(내부망 라우터)로 나가고,
    /// 이 옵션이 없는 다른 프로세스는 내부망에 닿지 않는다. 장치를 모르면(nil) 아무 것도 붙이지 않는다.
    public static func bindOptions(_ device: String?) -> [String] {
        guard let device, !device.isEmpty else { return [] }
        return ["-o", "BindInterface=\(device)"]
    }
}

/// 프로세스 트리 종료. 직계 자식만 죽이면 손자(sudo·ssh 가 띄운 servers-askpass 팝업 등)가 파이프를 쥔 채 남아
/// 읽기가 끝나지 않고 다이얼로그가 고아로 남는다. 프로세스 표(sysctl)로 자손을 모아 아래부터 신호를 보낸다.
public enum ProcessTree {
    /// 트리 전체에 SIGTERM, 2초 뒤에도 살아 있으면 SIGKILL (터널·전송의 [끊기]·[취소])
    public static func terminate(_ pid: pid_t, stillRunning: @escaping @Sendable () -> Bool) {
        kill(pid, signal: SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if stillRunning() { kill(pid, signal: SIGKILL) }
        }
    }

    public static func descendants(of pid: pid_t) -> [pid_t] {
        var children: [pid_t: [pid_t]] = [:]
        for (child, parent) in processTable() where child != parent {   // kernel_task 는 pid·ppid 가 모두 0
            children[parent, default: []].append(child)
        }
        var result: [pid_t] = []
        var stack = children[pid] ?? []
        while let next = stack.popLast() {
            result.append(next)
            stack.append(contentsOf: children[next] ?? [])
        }
        return result
    }

    /// 전체 프로세스의 (pid, ppid). `ps` 를 띄우지 않고 커널 표를 한 번에 읽는다 (ps 도 같은 sysctl 을 쓴다) —
    /// MainActor(터널 끊기·전송 취소·앱 종료)에서 불려 자식 실행·파이프 읽기로 막히면 안 된다.
    static func processTable() -> [(pid: pid_t, ppid: pid_t)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        // 크기를 물은 뒤 읽는 사이에 프로세스가 늘면 ENOMEM — 여유를 두고 몇 번 다시 묻는다
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
            size = procs.count * stride
            let rc = procs.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0) }
            if rc != 0 { if errno == ENOMEM { continue }; return [] }
            return procs.prefix(size / stride).map { ($0.kp_proc.p_pid, $0.kp_eproc.e_ppid) }
        }
        return []
    }

    /// 자손 먼저, 그다음 본인. 이미 죽은 pid 는 무시된다.
    /// 먼저 트리를 SIGSTOP 으로 멈춰 새 자식을 못 만들게 한 뒤 자손을 모은다 — 모으는 사이 막 fork 한 자식은 신호를 피해
    /// 고아로 남아 파이프를 쥔다 (sh -c '…; sleep 10' 을 끊어도 10초를 기다렸다). 멈춘 동안 새로 생긴 자손이 없을 때까지 다시 모은다.
    /// 멈춘 pid 는 모두 쌓아 둔다 — 다시 모을 때 중간 부모가 사라져 손자가 launchd 밑으로 가면 목록에서 빠지는데, 그 손자도 신호·SIGCONT 를 받아야
    /// 멈춘 채 고아로 남지 않는다. pid 0 이하는 프로세스 그룹 전체(앱 자신 포함)가 되므로 하지 않는다.
    public static func kill(_ pid: pid_t, signal: Int32) {
        guard pid > 0 else { return }
        Darwin.kill(pid, SIGSTOP)
        var tree: [pid_t] = []
        for _ in 0..<5 {
            let fresh = descendants(of: pid).filter { !tree.contains($0) }
            if fresh.isEmpty { break }
            tree += fresh
            for child in fresh { Darwin.kill(child, SIGSTOP) }
        }
        for child in tree.reversed() { Darwin.kill(child, signal) }
        Darwin.kill(pid, signal)
        // SIGKILL 은 멈춘 채로도 죽는다. 그 밖의 신호(SIGTERM)는 다시 깨워야 받아 처리한다.
        guard signal != SIGKILL else { return }
        for child in tree { Darwin.kill(child, SIGCONT) }
        Darwin.kill(pid, SIGCONT)
    }
}

/// 진행 중인 자식 프로세스 목록. 앱 종료 시 전부(비밀번호 팝업까지) 끝내기 위해 쓴다.
public final class ProcessRegistry: @unchecked Sendable {
    public static let shared = ProcessRegistry()
    private let lock = NSLock()
    private var pids: Set<pid_t> = []
    func add(_ pid: pid_t) { lock.withLock { _ = pids.insert(pid) } }
    func remove(_ pid: pid_t) { lock.withLock { _ = pids.remove(pid) } }
    public var running: [pid_t] { lock.withLock { Array(pids) } }
    /// 등록된 프로세스 트리 전부에 신호
    public func killAll(signal: Int32 = SIGTERM) {
        for pid in running { ProcessTree.kill(pid, signal: signal) }
    }
}

/// 블로킹 읽기는 GCD 풀이 아니라 전용 스레드에서 한다. 글로벌 큐 스레드(64개)를 점유하면 타이머·다른 작업이 굶어
/// 상태 갱신이 통째로 멈춘다.
func blockingThread(_ name: String, _ body: @escaping @Sendable () -> Void) {
    let thread = Thread(block: body)
    thread.name = name
    thread.qualityOfService = .utility
    thread.start()
}

/// 타임아웃 여부를 스레드 안전하게 기록한다. 판정은 "플래그가 섰고 + SIGKILL 로 죽었다" 두 조건으로 한다
/// (플래그만 보면 마감 직전에 정상 종료한 프로세스를 타임아웃으로 잘못 보고할 수 있다).
final class TimedOutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
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

/// N 개 조건이 모두 차면 딱 한 번 실행되는 완료 게이트. force() 는 남은 조건을 모두 채운다.
final class Completion: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var fired = false
    private let action: @Sendable () -> Void
    init(needed: Int, action: @escaping @Sendable () -> Void) { remaining = needed; self.action = action }
    var isDone: Bool { lock.withLock { fired } }
    func step() {
        let fire: Bool = lock.withLock {
            remaining -= 1
            if remaining <= 0, !fired { fired = true; return true }
            return false
        }
        if fire { action() }
    }
    func force() {
        let fire: Bool = lock.withLock { if fired { return false }; fired = true; remaining = 0; return true }
        if fire { action() }
    }
}

final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// 한 번만 울리는 타이머. cancel 하면 핸들러와 그것이 쥔 Process·파이프를 바로 놓는다
/// (asyncAfter·DispatchWorkItem 은 cancel 해도 마감 시각까지 블록을 쥔다).
final class OneShotTimer: @unchecked Sendable {
    /// 살아 있는 타이머 수 — 끝난 명령이 타이머를 남기지 않는지 테스트가 본다
    static let live = LiveCount()
    private let source: DispatchSourceTimer
    init(after seconds: TimeInterval, queue: DispatchQueue, _ handler: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + seconds)
        source.setEventHandler(handler: handler)
        Self.live.add(1)
        source.resume()
    }
    func cancel() { source.cancel() }
    deinit { source.cancel(); Self.live.add(-1) }
}

/// 명령 하나의 타이머 묶음. 완료 뒤에 들어온 타이머는 바로 취소한다.
final class TimerSet: @unchecked Sendable {
    private let lock = NSLock()
    private var timers: [OneShotTimer] = []
    private var cancelled = false
    func add(_ timer: OneShotTimer) {
        let late: Bool = lock.withLock { if cancelled { return true }; timers.append(timer); return false }
        if late { timer.cancel() }
    }
    func cancelAll() {
        let all: [OneShotTimer] = lock.withLock { cancelled = true; defer { timers = [] }; return timers }
        for timer in all { timer.cancel() }
    }
}

final class LiveCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add(_ delta: Int) { lock.withLock { count += delta } }
}
