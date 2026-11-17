// 패킷 캡처 프로세스: sudo tcpdump -w - 를 띄워 표준출력(pcap 바이트)을 조각째 넘긴다.
// 인증은 sudo 가 한다 — 먼저 -A 없이(지문 pam_tid · 터미널이 없어 비밀번호는 못 물음), 그게 실패하면 호출 쪽이 -A(SUDO_ASKPASS
// 비밀번호 창)로 다시 띄운다. -A 를 처음부터 붙이면 지문 없이 비밀번호 창이 바로 떴다 (2026-11-02). 인증 기억이 꺼져 있으면 시작할 때마다 묻는다.
// 끝내기: sudo 에 SIGTERM (sudo 가 root tcpdump 에 넘긴다). 멈춘 뒤엔 읽기 쪽 파이프를 닫아, sudo 만 죽고 tcpdump 가 남아도
// 다음 쓰기에서 SIGPIPE 로 끝나게 한다. 앱이 죽어도 파이프가 닫혀 같은 길로 끝난다.
// 끝나면 콜백을 비운다 — 콜백이 이 객체를 잡고 있어 생기는 순환을 끊어 파이프 핸들이 새지 않게 (2026-11-01 리뷰).

import Foundation

public final class CaptureProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var stderrText = ""
    private var started = false
    private var stopped = false
    private var callbacksData: (@Sendable ([UInt8]) -> Void)?
    private var callbacksExit: (@Sendable (Int32, String, Bool) -> Void)?

    public init() {}

    /// pcap 조각 (읽기 스레드에서 온다)
    public var onData: (@Sendable ([UInt8]) -> Void)? {
        get { lock.withLock { callbacksData } }
        set { lock.withLock { callbacksData = newValue } }
    }
    /// 끝남: (종료 코드, 표준 오류, 사용자가 멈췄는가) — 한 번만
    public var onExit: (@Sendable (Int32, String, Bool) -> Void)? {
        get { lock.withLock { callbacksExit } }
        set { lock.withLock { callbacksExit = newValue } }
    }
    public var stopRequested: Bool { lock.withLock { stopped } }

    /// sudo 로 tcpdump 를 띄운다. askPassEnvironment 가 nil 이면 지문만(SUDO_ASKPASS 를 뺀다), 있으면 -A 비밀번호 창
    public func start(tcpdumpArguments: [String], askPassEnvironment: [String: String]?) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = CaptureCommand.sudoArguments(tcpdumpArguments, askPass: askPassEnvironment != nil)
        var environment = ProcessLocale.environment(adding: askPassEnvironment ?? [:])
        if askPassEnvironment == nil { environment["SUDO_ASKPASS"] = nil }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let finished = Completion(needed: 3) { [weak self] in
            guard let self else { return }
            let (text, stopped, exit) = self.lock.withLock { () -> (String, Bool, (@Sendable (Int32, String, Bool) -> Void)?) in
                let exit = self.callbacksExit
                self.callbacksExit = nil
                self.callbacksData = nil
                return (self.stderrText, self.stopped, exit)
            }
            exit?(self.process.isRunning ? 128 + SIGTERM : self.process.terminationStatus, text, stopped)
        }
        let output = out.fileHandleForReading
        blockingThread("capture.read") { [weak self] in
            while true {
                let chunk = output.availableData
                if chunk.isEmpty { break }
                // 객체가 사라졌으면(멈춘 뒤 해제) 더 비우지 않고 닫는다 — 남은 tcpdump 가 SIGPIPE 로 끝나게 (2026-11-01 Fable 리뷰)
                guard let self else { break }
                // 멈춘 뒤엔 읽기를 그만두고 닫는다 → 남은 tcpdump 는 다음 쓰기에서 SIGPIPE
                let (stopped, deliver) = self.lock.withLock { (self.stopped, self.callbacksData) }
                if stopped { break }
                deliver?([UInt8](chunk))
            }
            try? output.close()
            finished.step()
        }
        let errors = err.fileHandleForReading
        blockingThread("capture.stderr") { [weak self] in
            while true {
                let chunk = errors.availableData
                if chunk.isEmpty { break }
                guard let self else { continue }
                // 오류 문구만 필요하다 — 끝없이 쌓이지 않게 뒤 4KB 만
                self.lock.withLock {
                    self.stderrText += String(decoding: chunk, as: UTF8.self)
                    if self.stderrText.count > 4096 { self.stderrText = String(self.stderrText.suffix(4096)) }
                }
            }
            try? errors.close()
            finished.step()
        }
        process.terminationHandler = { _ in
            finished.step()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finished.force() }
        }
        do {
            try process.run()
        } catch {
            // 읽기 스레드가 영원히 막히지 않게 쓰기 쪽까지 닫는다
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
            lock.withLock { callbacksExit = nil; callbacksData = nil }
            throw error
        }
        lock.withLock { started = true }
    }

    public var isRunning: Bool { lock.withLock { started } && process.isRunning }

    /// 트리(sudo · 비밀번호 창)에 SIGTERM, 2초 안에 안 끝나면 SIGKILL — sudo 는 받은 신호를 root tcpdump 에 넘긴다
    /// (root 인 tcpdump 에 직접 보내는 것은 EPERM 으로 무시된다). 인증 창이 떠 있을 때 멈춰도 창이 고아로 남지 않게.
    /// 이미 끝났어도 "멈춤" 으로 표시해 끝 알림이 실패로 읽히지 않게
    public func stop() {
        let started = lock.withLock { () -> Bool in stopped = true; return self.started }
        guard started, process.isRunning else { return }
        ProcessTree.terminate(process.processIdentifier) { [process] in process.isRunning }
    }
}
