// 이 Mac 의 CPU·메모리·스왑·GPU·온도·전원·프로세스 (시스템 화면). ~/.tools/stats.zsh 와 같은 값·계산.
//   읽기(SystemProbe): 앱 안 API — host_processor_info · host_statistics64 · sysctl · IOKit(IOAccelerator·AppleSMC·전원).
//                      남의 uid 프로세스는 앱 안에서 못 읽어 프로세스 목록만 ps 를 쓴다.
//   계산(CPUUsage·MemoryBreakdown·…): 원자료 → 화면 값. 순수 함수라 테스트한다.

import CSMC
import Darwin
import Foundation
import IOKit
import IOKit.ps

// MARK: 원자료

/// 코어 하나의 부팅 뒤 누적 틱 (32비트라 넘어가면 0 부터 다시 센다)
public struct CoreTicks: Sendable, Equatable {
    public let user, system, idle, nice: UInt32
    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }
}

/// host_statistics64(HOST_VM_INFO64) 에서 쓰는 페이지 수와 누적 카운터
public struct VMCounts: Sendable, Equatable {
    public var wired: UInt64 = 0
    public var purgeable: UInt64 = 0
    public var compressor: UInt64 = 0                 // 압축된 페이지가 차지한 자리
    public var uncompressedInCompressor: UInt64 = 0   // 압축 전 원래 크기
    public var external: UInt64 = 0                   // 파일 캐시
    public var `internal`: UInt64 = 0                 // 익명(앱) 메모리
    public var pageins: UInt64 = 0
    public var pageouts: UInt64 = 0
    public var swapins: UInt64 = 0
    public var swapouts: UInt64 = 0
    public var compressions: UInt64 = 0
    public var decompressions: UInt64 = 0
    public init() {}
}

public struct SwapUsage: Sendable, Equatable {
    public let total: UInt64
    public let used: UInt64
    public let encrypted: Bool
    public init(total: UInt64, used: UInt64, encrypted: Bool) {
        self.total = total; self.used = used; self.encrypted = encrypted
    }
}

/// kern.memorystatus_vm_pressure_level: 1 정상 · 2 경고 · 4 위험
public enum MemoryPressure: Sendable, Equatable {
    case normal, warning, critical, unknown
    public init(level: Int) {
        switch level {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: self = .unknown
        }
    }
}

/// 한 번 읽으면 바뀌지 않는 값
public struct SystemStatic: Sendable, Equatable {
    public let chip: String
    public let cores: Int
    public let performanceCores: Int   // 0 이면 P/E 구분 없음 (Intel)
    public let efficiencyCores: Int
    public let memory: UInt64
    public let pageSize: UInt64
    public let osVersion: String
    public let bootTime: Date?
    public init(chip: String, cores: Int, performanceCores: Int, efficiencyCores: Int, memory: UInt64, pageSize: UInt64, osVersion: String, bootTime: Date?) {
        self.chip = chip; self.cores = cores; self.performanceCores = performanceCores; self.efficiencyCores = efficiencyCores
        self.memory = memory; self.pageSize = pageSize; self.osVersion = osVersion; self.bootTime = bootTime
    }

    /// 코어 번호 → "P0"·"E3"·"C2". 커널은 효율 코어를 먼저 센다 (M4 에서 6~9 번이 P — stats.zsh core_kind 와 같다).
    public func coreName(_ index: Int) -> String {
        guard performanceCores > 0, performanceCores + efficiencyCores == cores else { return "C\(index)" }
        let firstP = cores - performanceCores
        return index >= firstP ? "P\(index - firstP)" : "E\(index)"
    }
}

// MARK: 계산

public struct CPUUsage: Sendable, Equatable {
    /// 모두 0~100
    public let total: Double
    public let user: Double
    public let system: Double
    public let idle: Double
    public let cores: [Double]

    /// 두 표본의 차이. 코어 수가 다르거나 시간이 흐르지 않았으면 nil. 카운터가 넘어간 것은 32비트 뺄셈(&-)이 맞게 센다.
    public static func between(_ old: [CoreTicks], _ new: [CoreTicks]) -> CPUUsage? {
        guard !old.isEmpty, old.count == new.count else { return nil }
        var sumUser = 0.0, sumSystem = 0.0, sumBusy = 0.0, sumAll = 0.0
        var cores: [Double] = []
        for (a, b) in zip(old, new) {
            let user = Double(b.user &- a.user) + Double(b.nice &- a.nice)
            let system = Double(b.system &- a.system)
            let idle = Double(b.idle &- a.idle)
            let all = user + system + idle
            cores.append(all > 0 ? (user + system) / all * 100 : 0)
            sumUser += user; sumSystem += system; sumBusy += user + system; sumAll += all
        }
        guard sumAll > 0 else { return nil }
        return CPUUsage(total: sumBusy / sumAll * 100, user: sumUser / sumAll * 100, system: sumSystem / sumAll * 100,
                        idle: (sumAll - sumBusy) / sumAll * 100, cores: cores)
    }
}

/// 활성 상태 보기와 같은 나눔 (stats.zsh). 바이트 단위.
public struct MemoryBreakdown: Sendable, Equatable {
    public let total: UInt64
    public let app: UInt64
    public let wired: UInt64
    public let compressed: UInt64
    /// 압축된 내용의 원래 크기 (압축률 = stored / compressed)
    public let stored: UInt64
    public let cached: UInt64

    public var used: UInt64 { app + wired + compressed }
    /// 전체 − 사용 − 캐시 (vm_stat 의 Pages free 가 아니다)
    public var free: UInt64 { total > used + cached ? total - used - cached : 0 }
    public var usedFraction: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }
    public var compressionRatio: Double? { compressed > 0 ? Double(stored) / Double(compressed) : nil }

    public init(total: UInt64, app: UInt64, wired: UInt64, compressed: UInt64, stored: UInt64, cached: UInt64) {
        self.total = total; self.app = app; self.wired = wired; self.compressed = compressed; self.stored = stored; self.cached = cached
    }

    /// 앱 = 익명 − 비울 수 있는(purgeable) 페이지 · 와이어드 · 압축(차지한 자리) · 캐시 = 파일 페이지
    public static func from(_ vm: VMCounts, pageSize: UInt64, total: UInt64) -> MemoryBreakdown {
        let app = vm.internal > vm.purgeable ? vm.internal - vm.purgeable : 0
        func bytes(_ pages: UInt64) -> UInt64 { min(total, pages * pageSize) }
        return MemoryBreakdown(total: total, app: bytes(app), wired: bytes(vm.wired), compressed: bytes(vm.compressor),
                               stored: vm.uncompressedInCompressor * pageSize, cached: bytes(vm.external))
    }
}

/// 초당 페이지 수
public struct PagingRates: Sendable, Equatable {
    public let pageins, pageouts, swapins, swapouts, compressions, decompressions: Double

    public static func between(_ old: VMCounts, _ new: VMCounts, seconds: Double) -> PagingRates? {
        guard seconds > 0 else { return nil }
        func rate(_ a: UInt64, _ b: UInt64) -> Double { b >= a ? Double(b - a) / seconds : 0 }
        return PagingRates(pageins: rate(old.pageins, new.pageins), pageouts: rate(old.pageouts, new.pageouts),
                           swapins: rate(old.swapins, new.swapins), swapouts: rate(old.swapouts, new.swapouts),
                           compressions: rate(old.compressions, new.compressions), decompressions: rate(old.decompressions, new.decompressions))
    }
}

/// SMC 온도 → 묶음별 최고값. Tp=P 코어 · Te=E 코어 · TC0..=Intel CPU · Tg/TG0..=GPU (stats.zsh classify_temp_keys).
public struct TemperatureSummary: Sendable, Equatable {
    public let cpuMax: Double?
    public let cpuAverage: Double?
    public let performanceMax: Double?
    public let efficiencyMax: Double?
    public let gpuMax: Double?
    public let sensors: Int

    public enum Group { case performance, efficiency, cpu, gpu }

    public static func group(_ key: String) -> Group? {
        guard key.count == 4 else { return nil }
        if key.hasPrefix("Tp") { return .performance }
        if key.hasPrefix("Te") { return .efficiency }
        if key.hasPrefix("Tg") { return .gpu }
        let third = key[key.index(key.startIndex, offsetBy: 2)]
        if key.hasPrefix("TC"), third.isNumber { return .cpu }
        if key.hasPrefix("TG"), third.isNumber { return .gpu }
        return nil
    }

    /// 묶음에 드는 키만. NaN(못 읽은 키)·0 이하(쉬는 센서 — stats.zsh temp_group_max 도 버린다)는 뺀다.
    public static func from(_ readings: [String: Double]) -> TemperatureSummary {
        var p: [Double] = [], e: [Double] = [], c: [Double] = [], g: [Double] = []
        for (key, value) in readings where !value.isNaN && value > 0 {
            switch group(key) {
            case .performance: p.append(value)
            case .efficiency: e.append(value)
            case .cpu: c.append(value)
            case .gpu: g.append(value)
            case nil: break
            }
        }
        let cpu = p + e + c
        return TemperatureSummary(cpuMax: cpu.max(), cpuAverage: cpu.isEmpty ? nil : cpu.reduce(0, +) / Double(cpu.count),
                                  performanceMax: p.max(), efficiencyMax: e.max(), gpuMax: g.max(), sensors: cpu.count + g.count)
    }
}

public struct GPUStats: Sendable, Equatable {
    public let model: String?
    public let cores: Int?
    /// 0~100
    public let device: Double?
    public let renderer: Double?
    public let tiler: Double?
    public let memoryInUse: UInt64?
    public let memoryAllocated: UInt64?

    /// IOAccelerator 의 PerformanceStatistics 사전
    public static func parse(_ stats: [String: Any], model: String?, cores: Int?) -> GPUStats {
        func number(_ key: String) -> Double? { (stats[key] as? NSNumber)?.doubleValue }
        return GPUStats(model: model, cores: cores, device: number("Device Utilization %"), renderer: number("Renderer Utilization %"),
                        tiler: number("Tiler Utilization %"), memoryInUse: number("In use system memory").map { UInt64($0) },
                        memoryAllocated: number("Alloc system memory").map { UInt64($0) })
    }
}

public struct PowerInfo: Sendable, Equatable {
    /// 전원 어댑터에서 받는 중
    public let onAC: Bool
    /// 배터리가 없으면 nil
    public let batteryPercent: Int?
    public let charging: Bool
    public let charged: Bool

    /// IOPSGetPowerSourceDescription 사전들 + 지금 전원(IOPSGetProvidingPowerSourceType)
    public static func parse(_ sources: [[String: Any]], providing: String?) -> PowerInfo {
        let battery = sources.first { ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType }
        var percent: Int?
        if let battery, let current = battery[kIOPSCurrentCapacityKey] as? Int, let maximum = battery[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
            percent = Int((Double(current) / Double(maximum) * 100).rounded())
        }
        return PowerInfo(onAC: (providing ?? (battery?[kIOPSPowerSourceStateKey] as? String)) == kIOPSACPowerValue,
                         batteryPercent: percent,
                         charging: battery?[kIOPSIsChargingKey] as? Bool ?? false,
                         charged: battery?[kIOPSIsChargedKey] as? Bool ?? false)
    }

    /// 전원 줄: "배터리 사용 중 · 71% · 방전 7.7W" · "전원 어댑터 · 배터리 80% · 충전 25.3W" (충전 중인데 전력이 0.1W 미만이면 "충전 중")
    public func text(watts: Double?) -> String {
        guard let percent = batteryPercent else { return onAC ? "전원 어댑터" : "–" }
        let flow = BatteryFlow.text(watts)
        if !onAC { return ["배터리 사용 중 · \(percent)%", flow].compactMap { $0 }.joined(separator: " · ") }
        let charge = charging ? (flow ?? "충전 중") : (charged ? "충전 완료" : "충전 안 함")
        return "전원 어댑터 · 배터리 \(percent)% · \(charge)"
    }
}

/// 배터리 건강 (AppleSmartBattery 레지스트리, 권한 없이 읽힌다). 배터리 없는 Mac 이면 nil.
/// 최대 용량 = 공칭 완충 용량 / 설계 용량 (100 상한) — 2026-10-05 이 Mac 6319/6249 → 100%, system_profiler 의 Maximum Capacity 와 같다.
public struct BatteryHealth: Sendable, Equatable {
    public let maxCapacityPercent: Int?
    public let cycleCount: Int?
    /// 설계 충전 사이클 (Apple Silicon 노트북은 1000)
    public let designCycles: Int?

    /// Apple 기준: 최대 용량 80% 미만이면 교체 권장
    public var needsService: Bool { (maxCapacityPercent ?? 100) < 80 }

    public static func parse(_ props: [String: Any]) -> BatteryHealth? {
        func int(_ dict: [String: Any], _ key: String) -> Int? { (dict[key] as? NSNumber)?.intValue }
        let data = props["BatteryData"] as? [String: Any] ?? [:]
        // 용량은 BatteryData 안에 있고, 옛 기종은 바깥에 둔다
        let nominal = int(data, "NominalChargeCapacity") ?? int(props, "NominalChargeCapacity") ?? int(props, "AppleRawMaxCapacity")
        let design = int(data, "DesignCapacity") ?? int(props, "DesignCapacity")
        var percent: Int?
        if let nominal, let design, design > 0 { percent = min(100, Int((Double(nominal) / Double(design) * 100).rounded())) }
        let health = BatteryHealth(maxCapacityPercent: percent, cycleCount: int(props, "CycleCount"), designCycles: int(props, "DesignCycleCount9C"))
        return health.maxCapacityPercent == nil && health.cycleCount == nil ? nil : health
    }
}

/// 배터리로 드나드는 전력 (AppleSmartBattery Voltage mV × Amperage mA). 충전이면 +, 방전이면 −.
/// 2026-10-05 이 Mac: 11857mV × −653mA = −7.7W (SMC 배터리 전력 PPBR 7.6W 와 맞음).
public enum BatteryFlow {
    /// Amperage 는 부호 있는 값이 UInt64 로 온다 (18446744073709550963 = −653)
    public static func watts(voltage: Any?, amperage: Any?) -> Double? {
        guard let mv = (voltage as? NSNumber)?.int64Value, mv > 0, let ma = (amperage as? NSNumber)?.int64Value else { return nil }
        return Double(mv) * Double(ma) / 1_000_000
    }

    /// "방전 7.7W" · "충전 25.3W". 0.1W 미만이면 nil (충전 완료·어댑터 유지)
    public static func text(_ watts: Double?) -> String? {
        guard let watts, abs(watts) >= 0.1 else { return nil }
        return String(format: "%@ %.1fW", watts > 0 ? "충전" : "방전", abs(watts))
    }
}

/// 팬 (SMC F<n>Ac·F<n>Mx). 팬 없는 Mac 은 빈 목록.
public struct FanReading: Sendable, Equatable {
    public let rpm: Double?
    public let maxRPM: Double?
    public init(rpm: Double?, maxRPM: Double?) { self.rpm = rpm; self.maxRPM = maxRPM }

    /// "정지 · 최대 6,550 RPM" · "2,400 RPM (37%)" · 둘이면 "1번 2,400 RPM (37%) · 2번 정지 · 최대 6,550 RPM". 팬이 없으면 nil.
    public static func text(_ fans: [FanReading]) -> String? {
        guard !fans.isEmpty else { return nil }
        func rpm(_ v: Double) -> String { Int(v.rounded()).formatted(.number.grouping(.automatic)) }
        func one(_ fan: FanReading) -> String {
            // SMC 가 무한대 같은 이상값을 주면 Int 변환이 멈추므로 유한한 값만
            guard let current = fan.rpm, current.isFinite, current >= 0 else { return "읽지 못했습니다" }
            let maximum = fan.maxRPM.flatMap { $0.isFinite && $0 >= 1 ? $0 : nil }
            if current < 1 { return "정지" + (maximum.map { " · 최대 \(rpm($0)) RPM" } ?? "") }
            let share = maximum.map { " (\(Int((current / $0 * 100).rounded()))%)" } ?? ""
            return "\(rpm(current)) RPM\(share)"
        }
        if fans.count == 1 { return one(fans[0]) }
        return fans.enumerated().map { "\($0.offset + 1)번 \(one($0.element))" }.joined(separator: " · ")
    }
}

// MARK: 프로세스 (ps)

public struct ProcessRow: Sendable, Equatable, Identifiable {
    public var id: Int { pid }
    public let pid: Int
    /// 코어 하나 = 100. 직전 표본과의 CPU 시간 차이로 계산 (첫 표본은 ps 의 %CPU)
    public var cpu: Double
    /// 누적 CPU 시간(초)
    public let cpuTime: Double
    /// 실제 메모리(RSS) 바이트
    public let memory: UInt64
    public let state: String
    public let command: String

    /// 경로를 뺀 실행 파일 이름
    public var name: String { (command as NSString).lastPathComponent }

    public init(pid: Int, cpu: Double, cpuTime: Double, memory: UInt64, state: String, command: String) {
        self.pid = pid; self.cpu = cpu; self.cpuTime = cpuTime; self.memory = memory; self.state = state; self.command = command
    }
}

public enum ProcessList {
    /// pid · %cpu · cputime · rss(KiB) · state · 명령(공백 가능 — 끝까지)
    public static let psArguments = ["-axo", "pid=,pcpu=,time=,rss=,state=,comm="]

    /// "11:43.18" · "161:33.89"(분이 60 을 넘는다) · "1:02:03" · "2-01:02:03" → 초
    public static func seconds(_ text: String) -> Double? {
        var rest = Substring(text)
        var days = 0.0
        if let dash = rest.firstIndex(of: "-") {
            guard let d = Double(rest[..<dash]) else { return nil }
            days = d
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        let total = parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        return days * 86400 + total
    }

    public static func parse(_ text: String) -> [ProcessRow] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count == 6, let pid = Int(fields[0]), let cpu = Double(fields[1]),
                  let time = seconds(String(fields[2])), let rss = UInt64(fields[3]) else { return nil }
            return ProcessRow(pid: pid, cpu: cpu, cpuTime: time, memory: rss * 1024, state: String(fields[4]),
                              command: String(fields[5]).trimmingCharacters(in: .whitespaces))
        }
    }

    /// 직전 표본(pid → 누적 CPU 초)과 경과 시간으로 %CPU 를 다시 계산한다. 새 프로세스·첫 표본은 ps 값 그대로.
    /// pid 가 재사용돼 누적 시간이 줄었으면 ps 값을 쓴다.
    public static func applyRates(_ rows: [ProcessRow], previous: [Int: Double], seconds: Double) -> [ProcessRow] {
        guard seconds > 0 else { return rows }
        return rows.map { row in
            var row = row
            if let before = previous[row.pid], row.cpuTime >= before {
                row.cpu = (row.cpuTime - before) / seconds * 100
            }
            return row
        }
    }
}

// MARK: 표본 (직전 값과의 차이)

/// 시스템 화면 한 번의 계산 결과
public struct SystemSnapshot: Sendable, Equatable {
    public var cpu: CPUUsage?
    public var memory: MemoryBreakdown?
    public var paging: PagingRates?
    public var pressure: MemoryPressure = .unknown
    /// kern.memorystatus_level — 커널이 보는 여유 메모리 %
    public var freeLevel: Int?
    public var swap: SwapUsage?
    public var load: [Double] = []
    public var at: Date
    public init(at: Date) { self.at = at }
}

/// 직전 틱·VM 카운터를 쥐고 다음 표본과의 차이로 CPU·페이징을 낸다.
public struct SystemSampler: Sendable {
    private var lastTicks: [CoreTicks]?
    private var lastVM: (counts: VMCounts, at: Date)?
    private var lastProcesses: (cpu: [Int: Double], at: Date)?
    public init() {}

    public mutating func step(ticks: [CoreTicks]?, vm: VMCounts?, info: SystemStatic, swap: SwapUsage?, load: [Double],
                              pressure: MemoryPressure, freeLevel: Int?, at: Date) -> SystemSnapshot {
        var snapshot = SystemSnapshot(at: at)
        if let ticks {
            if let lastTicks { snapshot.cpu = CPUUsage.between(lastTicks, ticks) }
            lastTicks = ticks
        }
        if let vm {
            snapshot.memory = MemoryBreakdown.from(vm, pageSize: info.pageSize, total: info.memory)
            if let lastVM { snapshot.paging = PagingRates.between(lastVM.counts, vm, seconds: at.timeIntervalSince(lastVM.at)) }
            lastVM = (vm, at)
        }
        snapshot.swap = swap
        snapshot.load = load
        snapshot.pressure = pressure
        snapshot.freeLevel = freeLevel
        return snapshot
    }

    public mutating func processes(_ rows: [ProcessRow], at: Date) -> [ProcessRow] {
        let rated = lastProcesses.map { ProcessList.applyRates(rows, previous: $0.cpu, seconds: at.timeIntervalSince($0.at)) } ?? rows
        lastProcesses = (Dictionary(rows.map { ($0.pid, $0.cpuTime) }, uniquingKeysWith: { a, _ in a }), at)
        return rated
    }
}

// MARK: 읽기 (앱 안 API)

public enum SystemProbe {
    private static let host = mach_host_self()

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func sysctlValue<T>(_ name: String, _ type: T.Type) -> T? {
        var value = [UInt8](repeating: 0, count: MemoryLayout<T>.size)
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<T>.size else { return nil }
        return value.withUnsafeBytes { $0.loadUnaligned(as: T.self) }
    }

    public static func staticInfo() -> SystemStatic {
        let cores = sysctlValue("hw.ncpu", Int32.self).map(Int.init) ?? ProcessInfo.processInfo.processorCount
        var bootTime: Date?
        if let boot = sysctlValue("kern.boottime", timeval.self) {
            bootTime = Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return SystemStatic(chip: sysctlString("machdep.cpu.brand_string") ?? "Mac",
                            cores: cores,
                            performanceCores: sysctlValue("hw.perflevel0.logicalcpu", Int32.self).map(Int.init) ?? 0,
                            efficiencyCores: sysctlValue("hw.perflevel1.logicalcpu", Int32.self).map(Int.init) ?? 0,
                            memory: sysctlValue("hw.memsize", UInt64.self) ?? ProcessInfo.processInfo.physicalMemory,
                            pageSize: UInt64(sysctlValue("hw.pagesize", Int64.self) ?? Int64(getpagesize())),
                            osVersion: "macOS \(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : ""),
                            bootTime: bootTime)
    }

    /// 코어별 누적 틱 (percore 헬퍼와 같은 host_processor_info)
    public static func cpuTicks() -> [CoreTicks]? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS, let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        return (0..<Int(count)).map { core in
            let base = core * Int(CPU_STATE_MAX)
            func tick(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[base + Int(state)]) }
            return CoreTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM), idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE))
        }
    }

    public static func vmCounts() -> VMCounts? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        var vm = VMCounts()
        vm.wired = UInt64(stats.wire_count)
        vm.purgeable = UInt64(stats.purgeable_count)
        vm.compressor = UInt64(stats.compressor_page_count)
        vm.uncompressedInCompressor = stats.total_uncompressed_pages_in_compressor
        vm.external = UInt64(stats.external_page_count)
        vm.internal = UInt64(stats.internal_page_count)
        vm.pageins = stats.pageins
        vm.pageouts = stats.pageouts
        vm.swapins = stats.swapins
        vm.swapouts = stats.swapouts
        vm.compressions = stats.compressions
        vm.decompressions = stats.decompressions
        return vm
    }

    public static func swap() -> SwapUsage? {
        guard let usage = sysctlValue("vm.swapusage", xsw_usage.self) else { return nil }
        return SwapUsage(total: usage.xsu_total, used: usage.xsu_used, encrypted: usage.xsu_encrypted != 0)
    }

    public static func loadAverage() -> [Double] {
        var load = [Double](repeating: 0, count: 3)
        return getloadavg(&load, 3) == 3 ? load : []
    }

    public static func pressure() -> MemoryPressure {
        MemoryPressure(level: sysctlValue("kern.memorystatus_vm_pressure_level", Int32.self).map(Int.init) ?? 0)
    }

    public static func freeLevel() -> Int? {
        sysctlValue("kern.memorystatus_level", Int32.self).map(Int.init)
    }

    /// 첫 GPU (IOAccelerator) 의 사용률·메모리
    public static func gpu() -> GPUStats? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        func property(_ key: String) -> Any? { IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
        guard let stats = property("PerformanceStatistics") as? [String: Any] else { return nil }
        return GPUStats.parse(stats, model: property("model") as? String, cores: (property("gpu-core-count") as? NSNumber)?.intValue)
    }

    public static func power() -> PowerInfo {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return PowerInfo(onAC: true, batteryPercent: nil, charging: false, charged: false)
        }
        let sources = list.compactMap { IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        return PowerInfo.parse(sources, providing: providing)
    }

    public static func batteryHealth() -> BatteryHealth? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        return BatteryHealth.parse(dict)
    }

    /// 지금 배터리 전력 (W, 충전 + · 방전 −). 배터리가 없으면 nil. 두 값만 읽어 가볍다 (화면 표본마다).
    public static func batteryWatts() -> Double? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        func property(_ key: String) -> Any? { IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
        return BatteryFlow.watts(voltage: property("Voltage"), amperage: property("Amperage"))
    }

    /// 팬 RPM. AppleSMC 를 못 열면 nil, 팬 없는 Mac 은 빈 목록.
    public static func fans() -> [FanReading]? {
        var actual = [Double](repeating: .nan, count: 4)
        var maximum = [Double](repeating: .nan, count: 4)
        let count = csmc_read_fans(&actual, &maximum, 4)
        guard count >= 0 else { return nil }
        return (0..<Int(count)).map { i in
            FanReading(rpm: actual[i].isNaN ? nil : actual[i], maxRPM: maximum[i].isNaN ? nil : maximum[i])
        }
    }

    /// 온도 센서 목록 (키·값). 무거워서(키 수백 개) 한 번만 부르고 키를 기억해 둔다. AppleSMC 를 못 열면 nil.
    public static func temperatureKeys() -> [String: Double]? {
        let max = 512
        var keys = [CChar](repeating: 0, count: max * 5)
        var values = [Double](repeating: 0, count: max)
        let count = csmc_list_temperatures(&keys, &values, Int32(max))
        guard count >= 0 else { return nil }
        var out: [String: Double] = [:]
        for i in 0..<Int(count) {
            let name = keys[(i * 5)..<(i * 5 + 4)].map { Character(UnicodeScalar(UInt8(bitPattern: $0))) }
            out[String(name)] = values[i]
        }
        return out
    }

    /// 기억해 둔 키만 다시 읽는다. 못 읽은 키는 NaN.
    public static func temperatures(_ keys: [String]) -> [String: Double] {
        let valid = keys.filter { $0.utf8.count == 4 }
        guard !valid.isEmpty else { return [:] }
        var joined = Array(valid.joined().utf8CString)
        var values = [Double](repeating: .nan, count: valid.count)
        guard csmc_read_temperatures(&joined, Int32(valid.count), &values) >= 0 else { return [:] }
        return Dictionary(zip(valid, values), uniquingKeysWith: { a, _ in a })
    }

    public static func processes(runner: any CommandRunner) async -> [ProcessRow] {
        ProcessList.parse(await runner.run("ps", ProcessList.psArguments, timeout: 5).stdout)
    }
}

// MARK: 판정 · 표시

/// 시스템 화면 머리글·사이드바 점의 결론. 기준은 stats.zsh 와 같다 (CPU 70/90 · 메모리 80/90 · 온도 80/95).
public enum SystemHealth {
    public enum Level: Sendable, Equatable { case good, warn, bad }

    /// 빨강(위험)이 노랑보다 먼저. CPU 90% 이상은 타일 색(70/90)과 같이 빨강.
    public static func judge(cpu: Double?, pressure: MemoryPressure, thermal: ProcessInfo.ThermalState) -> (level: Level, text: String) {
        if pressure == .critical { return (.bad, "메모리 압력 위험") }
        if thermal == .critical { return (.bad, "열 제한 (위험)") }
        if let cpu, level(cpu, .cpu) == .bad { return (.bad, "CPU 바쁨") }
        if pressure == .warning { return (.warn, "메모리 압력 경고") }
        if thermal == .serious { return (.warn, "열 제한") }
        return (.good, "정상")
    }

    /// 값 → 단계 (warn 이상만 색을 칠한다)
    public static func level(_ value: Double, warn: Double, bad: Double) -> Level {
        value >= bad ? .bad : (value >= warn ? .warn : .good)
    }

    /// 막대·타일 색 기준 (%·°C). 결론(judge · LinuxHealth.judge)도 이 숫자를 쓴다.
    public enum Gauge: Sendable {
        /// CPU 전체·코어
        case cpu
        /// 메모리·디스크·볼륨 사용률
        case usage
        /// CPU 온도
        case temperature

        public var warn: Double {
            switch self {
            case .cpu: return 70
            case .usage, .temperature: return 80
            }
        }
        public var bad: Double {
            switch self {
            case .cpu, .usage: return 90
            case .temperature: return 95
            }
        }
    }

    public static func level(_ value: Double, _ gauge: Gauge) -> Level {
        level(value, warn: gauge.warn, bad: gauge.bad)
    }

    public static func thermalText(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "정상"
        case .fair: return "약간 높음"
        case .serious: return "높음 · 성능 제한"
        case .critical: return "위험 · 성능 제한"
        @unknown default: return "알 수 없음"
        }
    }
}

public enum SystemFormat {
    /// 2진 단위 (stats.zsh 와 같다): GiB·TiB 는 소수 한 자리, MiB·KiB 는 정수
    public static func bytes(_ value: UInt64) -> String {
        let v = Double(value)
        switch value {
        case (1 << 40)...: return String(format: "%.1f TiB", v / 1_099_511_627_776)
        case (1 << 30)...: return String(format: "%.1f GiB", v / 1_073_741_824)
        case (1 << 20)...: return String(format: "%.0f MiB", v / 1_048_576)
        case (1 << 10)...: return String(format: "%.0f KiB", v / 1024)
        default: return "\(value) B"
        }
    }

    /// "2일 3시간 4분" · "3시간 4분" · "4분"
    public static func uptime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86400, hours = total % 86400 / 3600, minutes = total % 3600 / 60
        if days > 0 { return "\(days)일 \(hours)시간 \(minutes)분" }
        if hours > 0 { return "\(hours)시간 \(minutes)분" }
        return "\(minutes)분"
    }

    /// "1:02:03" (CPU 누적 시간)
    public static func cpuTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600, minutes = total % 3600 / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}
