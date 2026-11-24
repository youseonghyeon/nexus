// 서버 정보의 "실시간" 탭 수집기 (서버 하나). 계산은 ServersCore LinuxLive (stats.sh · disk.sh 와 같은 식) · Windows 는 WindowsLive.
// 그 탭이 보이고 창이 보일 때만 설정 간격(기본 5초)마다 ssh 한 번 — 기존 공유 연결(ControlMaster)·키 인증으로, 비밀번호 창은 띄우지 않는다.

import Foundation
import ServersCore

@MainActor
final class ServerLiveMonitor: ObservableObject {
    enum ProcessSort: Hashable { case cpu, memory }
    static let historyLength = 60
    static let processLimit = 12

    @Published private(set) var snapshot: LiveSnapshot?
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var error: String?
    /// 인증에 실패해 멈춘 상태 — 틀린 비밀번호로 매 간격 로그인을 시도하면 운영 서버의 계정 잠금(fail2ban·faillock)에 걸릴 수 있다.
    /// [다시 시도](retry)로만 푼다.
    @Published private(set) var authBlocked = false
    @Published var processSort = ProcessSort.cpu

    private var sampler = LinuxLiveSampler()
    private var windowsSampler = WindowsLiveSampler()
    private var sampling = false
    private var lastSampleAt: Date?

    var processes: [LiveProcessRow] {
        guard let all = snapshot?.processes else { return [] }
        let sorted = processSort == .cpu ? all : all.sorted { ($0.memory, $0.cpu) > ($1.memory, $1.cpu) }
        return Array(sorted.prefix(Self.processLimit))
    }

    func sample(_ server: Server, model: AppModel, allowPrompt: Bool = false) async {
        guard !sampling, !authBlocked || allowPrompt else { return }
        sampling = true
        defer { sampling = false }
        var first = lastSampleAt == nil || snapshot?.cpu == nil
        // 탭을 오래 떠났다 오면 직전 표본이 낡았다 — 그 긴 구간의 평균을 지금 값처럼 보이지 않게 새로 시작
        if let last = lastSampleAt, Date().timeIntervalSince(last) > 60 {
            sampler = LinuxLiveSampler()
            windowsSampler = WindowsLiveSampler()
            cpuHistory = []
            first = true
        }
        guard await readOnce(server, model: model, allowPrompt: allowPrompt) else { return }
        // 첫 표본은 차이가 없어 CPU·디스크 속도가 빈다 — 1초 뒤 한 번 더 읽어 바로 채운다 (그새 탭을 떠났으면 읽지 않는다)
        if first {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            _ = await readOnce(server, model: model, allowPrompt: false)
        }
    }

    /// 인증 실패로 멈춘 뒤: 비밀번호 창을 허용해 한 번 읽는다. 되면 다시 간격마다 읽는다.
    func retry(_ server: Server, model: AppModel) async {
        authBlocked = false
        await sample(server, model: model, allowPrompt: true)
    }

    private func readOnce(_ server: Server, model: AppModel, allowPrompt: Bool) async -> Bool {
        guard let query = RemoteCommands.query(.live, for: server.type) else { return false }
        let result = await model.runRemote(server, command: query.command, stdin: query.stdin, timeout: 10, allowPrompt: allowPrompt)
        guard result.ok else {
            error = model.liveFailureText(result, server: server)
            if SSHOutcome(result) == .needsAuth { authBlocked = true }
            return false
        }
        let now = Date()
        let next: LiveSnapshot
        if server.type == .windows, let raw = WindowsRaw.parse(result.stdout) {
            next = windowsSampler.step(raw, at: now)
        } else if server.type != .windows, let raw = LinuxRaw.parse(result.stdout) {
            next = sampler.step(raw, at: now)
        } else {
            error = "\(server.key) 의 출력을 읽지 못했습니다 · 다음 갱신에서 다시 시도합니다"
            return false
        }
        snapshot = next
        lastSampleAt = now
        error = nil
        if let cpu = next.cpu?.total {
            cpuHistory.append(cpu)
            if cpuHistory.count > Self.historyLength { cpuHistory.removeFirst(cpuHistory.count - Self.historyLength) }
        }
        return true
    }
}
