// 서버 "실시간" 탭의 공용 타입과 계산: 리눅스(LinuxLive) · Windows(WindowsLive) 표본기가 같은 원자료 꼴로 읽어 같은 결과(LiveSnapshot)를 낸다.
// 서버마다 다른 것(스크립트 · 원문 풀이 · 시간 기준 · 합계에 넣는 장치)은 각 파일에, 둘이 같이 쓰는 식은 여기에.

import Foundation

// MARK: 원자료

public struct LiveCPUTicks: Sendable, Equatable {
    /// user nice system idle iowait irq softirq steal
    public let values: [UInt64]
    public init(_ values: [UInt64]) { self.values = values + Array(repeating: 0, count: max(0, 8 - values.count)) }
    var busy: UInt64 { values[0] + values[1] + values[2] + values[5] + values[6] + values[7] }
    var idleAll: UInt64 { values[3] + values[4] }
    var total: UInt64 { busy + idleAll }
}

public struct LiveProcessSample: Sendable, Equatable {
    public let pid: Int
    public let state: String
    public let ticks: UInt64
    public let threads: Int
    /// 바이트 (리눅스는 RSS 페이지 × PAGESIZE, Windows 는 전용 작업 집합)
    public let memory: UInt64
    public let startTime: UInt64
    public let command: String
}

public struct LiveInterface: Sendable, Equatable {
    public let name: String
    /// /sys/class/net/X/device 가 있다 — 실제 랜카드 (브리지·veth·도커는 없다)
    public let physical: Bool
    public let state: String
    public let speedMbps: Int?
    public let rxBytes: UInt64
    public let txBytes: UInt64

    /// 물리 + VPN·본딩만 보인다 (docker0·br-·veth·cni 같은 가상 장치는 숨긴다)
    public var shown: Bool {
        !name.hasPrefix("tunl") && (physical || ["tailscale", "wg", "tun", "bond", "zt"].contains { name.hasPrefix($0) })   // tunl0 은 Calico
    }

    /// 링크 속도(Mbps)로 믿을 값인가 — 옛 커널은 모를 때 4294967295 를 준다. 0 이하 · 400 Gbps 초과는 모름
    static func knownSpeed(_ mbps: Int) -> Int? { mbps > 0 && mbps <= 400_000 ? mbps : nil }
}

/// 바이트/초
public struct LiveTraffic: Sendable, Equatable {
    public let rx: Double
    public let tx: Double
}

public struct LiveInterfaceRate: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let physical: Bool
    public let state: String
    public let speedMbps: Int?
    /// 바이트/초
    public let rx: Double
    public let tx: Double

    /// 직전 표본과의 차이로 낸 장치별 속도(new 의 순서)와 합계. 직전에 없던 장치는 다음 표본부터, 줄어든 카운터(초기화)는 0.
    /// 합계에 넣을 장치는 부르는 쪽이 정한다 (counted — 리눅스는 물리만, Windows 는 전부). seconds 는 0 보다 커야 한다.
    static func rates(from old: [LiveInterface], to new: [LiveInterface], seconds: Double,
                      counted: (LiveInterface) -> Bool) -> (interfaces: [LiveInterfaceRate], total: LiveTraffic) {
        let before = Dictionary(old.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var rates: [LiveInterfaceRate] = []
        var totalRx = 0.0, totalTx = 0.0
        for i in new {
            guard let old = before[i.name] else { continue }
            let rx = i.rxBytes >= old.rxBytes ? Double(i.rxBytes - old.rxBytes) / seconds : 0
            let tx = i.txBytes >= old.txBytes ? Double(i.txBytes - old.txBytes) / seconds : 0
            rates.append(LiveInterfaceRate(name: i.name, physical: i.physical, state: i.state, speedMbps: i.speedMbps, rx: rx, tx: tx))
            if counted(i) { totalRx += rx; totalTx += tx }
        }
        return (rates, LiveTraffic(rx: totalRx, tx: totalTx))
    }
}

public struct LiveDiskInfo: Sendable, Equatable {
    /// true HDD · false SSD · nil 모름
    public let rotational: Bool?
    public let size: UInt64
    public let model: String?
    /// 디스크가 스스로 알리는 상태 (Windows 저장소 관리의 HealthStatus). 리눅스는 SMART 가 root 를 요구해 읽지 않는다 — nil
    public var healthy: Bool? = nil
}

public struct LiveVolume: Sendable, Equatable, Identifiable {
    public var id: String { mountPoint }
    public let device: String
    public let fsType: String
    public let size: UInt64
    public let used: UInt64
    public let available: UInt64
    public let mountPoint: String
    /// df 의 Use% 와 같다: used / (used + available), 올림
    public var percent: Int {
        let denominator = used + available
        guard denominator > 0 else { return 0 }
        return Int((Double(used) * 100 / Double(denominator)).rounded(.up))
    }
}

// MARK: 계산

public struct LiveCPUUsage: Sendable, Equatable {
    /// 0~100. stats.sh: 바쁨 = user+nice+system+irq+softirq+steal, 대기 = idle+iowait
    public let total, user, system, iowait, steal, idle: Double
    public let cores: [Double]

    public static func between(_ old: LiveCPUTicks, _ new: LiveCPUTicks, oldCores: [LiveCPUTicks], newCores: [LiveCPUTicks]) -> LiveCPUUsage? {
        func delta(_ a: UInt64, _ b: UInt64) -> Double { b >= a ? Double(b - a) : 0 }
        let total = delta(old.total, new.total)
        guard total > 0 else { return nil }
        func share(_ index: [Int]) -> Double { index.reduce(0) { $0 + delta(old.values[$1], new.values[$1]) } / total * 100 }
        let cores: [Double] = oldCores.count == newCores.count ? zip(oldCores, newCores).map { a, b in
            let t = delta(a.total, b.total)
            return t > 0 ? delta(a.busy, b.busy) / t * 100 : 0
        } : []
        return LiveCPUUsage(total: delta(old.busy, new.busy) / total * 100, user: share([0, 1]), system: share([2, 5, 6]),
                             iowait: share([4]), steal: share([7]), idle: share([3]), cores: cores)
    }
}

/// htop 방식 (stats.sh). 바이트.
public struct LiveMemory: Sendable, Equatable {
    public let total, used, shared, buffers, cache, free, available: UInt64
    public let swapTotal, swapUsed: UInt64
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    public static func from(_ kb: [String: UInt64]) -> LiveMemory? {
        guard let total = kb["MemTotal"], total > 0 else { return nil }
        func v(_ key: String) -> UInt64 { kb[key] ?? 0 }
        let reclaim = v("Buffers") + v("Cached") + v("SReclaimable")
        let used = total > v("MemFree") + reclaim ? total - v("MemFree") - reclaim : 0
        let cacheRaw = v("Cached") + v("SReclaimable")
        return LiveMemory(total: total * 1024, used: used * 1024, shared: v("Shmem") * 1024, buffers: v("Buffers") * 1024,
                           cache: (cacheRaw > v("Shmem") ? cacheRaw - v("Shmem") : 0) * 1024, free: v("MemFree") * 1024,
                           available: (kb["MemAvailable"] ?? v("MemFree")) * 1024,
                           swapTotal: v("SwapTotal") * 1024, swapUsed: (v("SwapTotal") > v("SwapFree") ? v("SwapTotal") - v("SwapFree") : 0) * 1024)
    }

    /// stats.sh: PSI full ≥ 10 또는 some ≥ 50 → 위험, some ≥ 10 → 경고. PSI 가 없으면 남은 메모리 5%/10% 미만.
    public func pressure(psiSome: Double?, psiFull: Double?) -> MemoryPressure {
        if let some = psiSome {
            if (psiFull ?? 0) >= 10 || some >= 50 { return .critical }
            return some >= 10 ? .warning : .normal
        }
        let ratio = total > 0 ? Double(available) / Double(total) : 1
        return ratio < 0.05 ? .critical : (ratio < 0.10 ? .warning : .normal)
    }
}

public struct LiveProcessRow: Sendable, Equatable, Identifiable {
    public var id: Int { pid }
    public let pid: Int
    /// 코어 하나 = 100
    public let cpu: Double
    public let memory: UInt64
    public let state: String
    public let threads: Int
    /// 누적 CPU 시간(초)
    public let cpuTime: Double
    public let command: String

    /// 표본을 화면 줄로: CPU → 메모리 → pid(작은 것 먼저) 순. pid 재사용은 시작 시각으로 가른다 — 직전 표본에 같은 (pid, 시작 시각)이 있을 때만 뺀다.
    /// percent 는 늘어난 ticks 를 %CPU 로 바꾸는 식 (서버마다 다르다). 구간을 모르면 nil — 전부 0.
    static func rows(_ now: [LiveProcessSample], since before: [LiveProcessSample], ticksPerSecond: Double,
                     percent: ((Double) -> Double)?) -> [LiveProcessRow] {
        var oldTicks: [String: UInt64] = [:]
        for p in before { oldTicks["\(p.pid):\(p.startTime)"] = p.ticks }
        return now.map { p in
            var cpu = 0.0
            if let percent, let before = oldTicks["\(p.pid):\(p.startTime)"], p.ticks >= before {
                cpu = percent(Double(p.ticks - before))
            }
            return LiveProcessRow(pid: p.pid, cpu: cpu, memory: p.memory, state: p.state, threads: p.threads,
                                  cpuTime: Double(p.ticks) / ticksPerSecond, command: p.command)
        }.sorted { ($0.cpu, $0.memory, $1.pid) > ($1.cpu, $1.memory, $0.pid) }
    }
}

public struct LiveSnapshot: Sendable, Equatable {
    /// 어느 쪽 서버의 값인가 — Windows 에는 부하 평균·iowait·버퍼/캐시 구분·프로세스 상태 글자가 없어 화면이 그 줄을 뺀다
    public enum System: Sendable, Equatable { case linux, windows }
    public var system = System.linux
    /// nvidia-smi 가 있는 Windows 만 (WindowsLive)
    public var gpus: [LiveGPU] = []
    public var model: String?
    /// 논리 프로세서 수 (코어 막대의 수)
    public var cores = 0
    /// 물리 코어 수 — 아는 서버만 (Windows · x86 리눅스). 요약 줄이 "8코어 16스레드" 로 적는다
    public var physicalCores: Int?
    /// 요약 줄의 코어 표시: "8코어 16스레드" · 물리 코어를 모르거나 같으면 "코어 16개"
    public var coresText: String? {
        guard cores > 0 else { return nil }
        if let physicalCores, physicalCores != cores { return "\(physicalCores)코어 \(cores)스레드" }
        return "코어 \(cores)개"
    }
    public var uptime: Double?
    public var cpu: LiveCPUUsage?
    public var memory: LiveMemory?
    public var pressure: MemoryPressure = .unknown
    public var load: [Double] = []
    public var processCount = 0
    public var running = 0
    public var threads = 0
    public var disk: DiskIO?
    public var perDisk: [String: DiskIO] = [:]
    public var volumes: [LiveVolume] = []
    public var temperatureMax: Double?
    public var temperatureAverage: Double?
    public var diskInfo: [String: LiveDiskInfo] = [:]
    public var raids: [LinuxRAID] = []
    /// MHz
    public var frequencyAverage: Double?
    public var frequencyMax: Double?
    public var throttleEvents: Int?
    /// 보여 줄 인터페이스의 초당 속도 (물리 + VPN·본딩). 합계는 물리만 — 브리지·veth 는 같은 트래픽을 한 번 더 센다
    public var interfaces: [LiveInterfaceRate] = []
    public var networkTotal: LiveTraffic?
    /// CPU 순 전체 (화면이 정렬·자른다)
    public var processes: [LiveProcessRow] = []
    public var at: Date
    public init(at: Date) { self.at = at }
}

public enum LiveHealth {
    /// 시스템 화면과 같은 순서: 위험(메모리 압력 위험·CPU 90%+) → 경고(메모리 압력 경고·디스크 90%+ 는 위험, 80%+ 경고)
    /// RAID 손상은 disk.sh 처럼 공간보다 먼저 (SMART 는 root 가 필요해 보지 않는다)
    public static func judge(_ s: LiveSnapshot) -> (level: SystemHealth.Level, text: String) {
        let worstDisk = Double(s.volumes.map(\.percent).max() ?? 0)
        if let broken = s.raids.first(where: \.degraded) { return (.bad, "RAID 손상 · \(broken.name)") }
        if let name = s.diskInfo.keys.sorted().first(where: { s.diskInfo[$0]?.healthy == false }) { return (.bad, "디스크 이상 · \(s.diskInfo[name]?.model ?? name)") }
        if s.pressure == .critical { return (.bad, "메모리 압력 위험") }
        if let cpu = s.cpu?.total, SystemHealth.level(cpu, .cpu) == .bad { return (.bad, "CPU 바쁨") }
        if SystemHealth.level(worstDisk, .usage) == .bad { return (.bad, "공간 부족") }
        if let syncing = s.raids.first(where: { $0.progress != nil && !$0.checking }) { return (.warn, "RAID \(syncing.progress ?? "") · \(syncing.name)") }
        if s.pressure == .warning { return (.warn, "메모리 압력 경고") }
        if SystemHealth.level(worstDisk, .usage) == .warn { return (.warn, "공간이 차는 중") }
        return (.good, "정상")
    }
}
