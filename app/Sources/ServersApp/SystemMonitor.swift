// 시스템 화면(CPU·메모리·GPU·온도·전원·프로세스) 수집기. 계산은 ServersCore SystemStats.
// 화면이 떠 있고 창이 보일 때만 3초마다 전부 읽는다 (SystemDashboardView 의 .task).
// 사이드바 요약(CPU·메모리)은 창이 보일 때 AppModel 의 5초 갱신이 가볍게(full: false) 부른다.

import Foundation
import ServersCore

@MainActor
final class SystemMonitor: ObservableObject {
    enum ProcessSort: Hashable { case cpu, memory }

    static let historyLength = 60
    static let processLimit = 15

    let info = SystemProbe.staticInfo()
    @Published private(set) var snapshot: SystemSnapshot?
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var gpu: GPUStats?
    @Published private(set) var gpuHistory: [Double] = []
    @Published private(set) var temperatures: TemperatureSummary?
    /// AppleSMC 를 못 열었거나 온도 키가 없다
    @Published private(set) var temperaturesUnavailable = false
    @Published private(set) var thermal = ProcessInfo.processInfo.thermalState
    @Published private(set) var power: PowerInfo?
    /// 배터리 최대 용량·충전 사이클 (거의 안 바뀌므로 전원과 같은 주기로)
    @Published private(set) var batteryHealth: BatteryHealth?
    /// 지금 배터리 전력 (W, 충전 + · 방전 −) — 화면 표본마다
    @Published private(set) var batteryWatts: Double?
    /// 팬 RPM (온도와 같이 두 번에 한 번, SMC). nil 이면 못 읽음, 빈 목록이면 팬 없는 Mac.
    @Published private(set) var fans: [FanReading]?
    @Published private(set) var processes: [ProcessRow] = []
    @Published private(set) var processCount = 0
    @Published private(set) var runningCount = 0
    @Published var processSort = ProcessSort.cpu

    private var sampler = SystemSampler()
    /// 마지막 ps 전체 (정렬을 바꾸면 여기서 다시 고른다)
    private var allProcesses: [ProcessRow] = []
    /// 온도 키 목록: nil 이면 아직 안 만듦 (처음 한 번만 전체를 훑는다 — 키 수백 개)
    private var temperatureKeys: [String]?
    private var fullRounds = 0
    private var sampling = false

    /// full: 화면용 전부 (GPU·프로세스·전원, 온도·팬은 두 번에 한 번, 배터리 건강은 다섯 번에 한 번). false 면 사이드바 요약용 CPU·메모리만.
    /// 기다리는 읽기(온도·팬·ps)를 먼저 끝내고 값은 한꺼번에 알린다 — 사이사이 알리면 한 표본에 화면 전체가 서너 번 다시 배치됐다 (2026-11-12 측정).
    func sample(full: Bool, runner: any CommandRunner) async {
        guard !sampling else { return }
        sampling = true
        defer { sampling = false }
        guard full else {
            publishSnapshot(at: Date())
            return
        }
        fullRounds += 1
        let slowRound = fullRounds % 2 == 1
        let readings = slowRound ? await readTemperatures() : nil
        let fansNow = slowRound ? await Task.detached(priority: .utility) { SystemProbe.fans() }.value : nil
        let rows = await SystemProbe.processes(runner: runner)

        // 여기부터는 기다림 없이 — 알림이 한 번의 화면 갱신으로 묶인다
        let next = publishSnapshot(at: Date())
        // 그래프는 화면 표본(3초)만 — 사이드바 요약(5초)이 섞이면 가로축 간격이 고르지 않다
        if let cpu = next.cpu { append(&cpuHistory, cpu.total) }
        if let memory = next.memory { append(&memoryHistory, memory.usedFraction * 100) }
        gpu = SystemProbe.gpu()
        if let device = gpu?.device { append(&gpuHistory, device) }
        if slowRound {
            applyTemperatures(readings)
            fans = fansNow
        }
        // 전원 상태와 전력은 같은 표본에서 — 어댑터를 꽂고 뺀 직후 "배터리 사용 중 · 충전 25W" 처럼 어긋나지 않게 (둘 다 0.1ms 안쪽)
        power = SystemProbe.power()
        batteryWatts = SystemProbe.batteryWatts()
        if batteryHealth == nil || fullRounds % 5 == 0 { batteryHealth = SystemProbe.batteryHealth() }

        guard !rows.isEmpty else { return }   // ps 실패 — 이전 목록을 둔다
        let rated = sampler.processes(rows, at: Date())
        allProcesses = rated
        processCount = rated.count
        runningCount = rated.filter { $0.state.hasPrefix("R") }.count
        processes = Self.top(rated, by: processSort)
    }

    /// CPU·메모리 표본 하나를 읽어 알린다
    @discardableResult
    private func publishSnapshot(at now: Date) -> SystemSnapshot {
        let next = sampler.step(ticks: SystemProbe.cpuTicks(), vm: SystemProbe.vmCounts(), info: info, swap: SystemProbe.swap(),
                                load: SystemProbe.loadAverage(), pressure: SystemProbe.pressure(), freeLevel: SystemProbe.freeLevel(), at: now)
        snapshot = next
        let thermalNow = ProcessInfo.processInfo.thermalState
        if thermal != thermalNow { thermal = thermalNow }
        return next
    }

    /// 정렬을 바꾸면 다음 표본을 기다리지 않고 지금 목록을 다시 줄 세운다
    func resort(_ sort: ProcessSort) {
        processSort = sort
        processes = Self.top(allProcesses, by: sort)
    }

    private static func top(_ rows: [ProcessRow], by sort: ProcessSort) -> [ProcessRow] {
        let sorted = rows.sorted { sort == .cpu ? ($0.cpu, $0.memory) > ($1.cpu, $1.memory) : ($0.memory, $0.cpu) > ($1.memory, $1.cpu) }
        return Array(sorted.prefix(processLimit))
    }

    /// SMC 는 메인 스레드 밖에서 읽는다 (첫 목록 만들기 ~50ms, 이후 ~10ms). nil 이면 못 읽음.
    private func readTemperatures() async -> [String: Double]? {
        let known = temperatureKeys
        return await Task.detached(priority: .utility) {
            if let known { return SystemProbe.temperatures(known) }
            return SystemProbe.temperatureKeys()
        }.value
    }

    private func applyTemperatures(_ readings: [String: Double]?) {
        guard let readings else {
            temperaturesUnavailable = true
            temperatureKeys = []
            return
        }
        if temperatureKeys == nil {
            temperatureKeys = readings.keys.filter { TemperatureSummary.group($0) != nil }.sorted()
        }
        let summary = TemperatureSummary.from(readings)
        temperatures = summary
        temperaturesUnavailable = summary.sensors == 0
    }

    private func append(_ history: inout [Double], _ value: Double) {
        history.append(value)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }

    // MARK: 판정 (사이드바·머리글 공통)

    var health: (level: SystemHealth.Level, text: String) {
        SystemHealth.judge(cpu: snapshot?.cpu?.total, pressure: snapshot?.pressure ?? .unknown, thermal: thermal)
    }

    /// "CPU 12% · 메모리 62%"
    var summary: String {
        guard let snapshot else { return "확인 중…" }
        let cpu = snapshot.cpu.map { "CPU \(Int($0.total.rounded()))%" } ?? "CPU –"
        let memory = snapshot.memory.map { "메모리 \(Int(($0.usedFraction * 100).rounded()))%" } ?? "메모리 –"
        return "\(cpu) · \(memory)"
    }
}
