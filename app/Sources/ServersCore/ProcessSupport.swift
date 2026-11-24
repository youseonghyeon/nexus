// 자식 프로세스를 다루는 부품: 트리 종료 · 진행 중 목록 · 읽기 스레드 · 완료 게이트 · 타이머. ProcessRunner 와 터널·전송·캡처가 함께 쓴다.

import Foundation

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
