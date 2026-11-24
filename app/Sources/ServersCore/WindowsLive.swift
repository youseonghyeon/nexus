// Windows 서버의 "실시간" 탭: CPU·코어·메모리·페이지 파일·디스크 사용/입출력·네트워크·GPU·상위 프로세스.
// 리눅스(LinuxLive)와 같은 방식 — 그 탭을 보고 있을 때만 ssh 한 번으로 아래 스크립트를 돌려 누적 카운터 원문을 받고, 사용률은 직전 표본과의 차이로 여기서 낸다.
// 서버에서 기다리지 않는다: 가공된 카운터(Win32_PerfFormattedData)·Win32_Processor.LoadPercentage 는 재는 동안 0.3~1초를 쓰고
// 처음엔 6.5초까지 걸렸다 (2026-11-10 win 실측). 원시 카운터는 구역마다 10~20ms, 전체 0.4초.
// 실제 출력: Tests/ServersCoreTests/Fixtures/windows-live-{1,2}.txt (Windows 11 26100 · PowerShell 5.1, 3초 간격).

import Foundation

public enum WindowsLive {
    /// 값은 탭으로 가른다 (이름이 맨 끝). 함수 이름은 PowerShell 기본 별칭과 겹치면 안 된다 — R 은 r=Invoke-History 에 가려 값 줄이 전부 오류였다.
    /// @INFO  가동 초 · 메모리(kB) 한 줄, CPU 이름, 물리 코어 수(소켓 합)
    /// @CPU   이름(코어 번호 · _Total)  idle  user  privileged  시각        — 100ns 누적. PercentProcessorTime 원시 값은 "쉬는 시간" 이다
    /// @PROC  첫 줄 "T 시각", 이어서 pid  CPU시간  전용 작업 집합  작업 집합  스레드  시작 시각  이름
    /// @DISK  읽은 바이트  쓴 바이트  읽기 횟수  쓰기 횟수  시각  "번호 드라이브…"
    /// @BLK   번호  MediaType(3 HDD · 4 SSD)  BusType  크기  HealthStatus(0 정상)  모델
    /// @NET   받은 바이트  보낸 바이트  링크 속도(bps)  시각  어댑터 설명
    /// @GPU   nvidia-smi: 사용률 %, VRAM 사용 MiB, VRAM 전체 MiB, 온도, 전력 W, 이름 (없으면 빈 구역)
    public static let script = #"""
    $ErrorActionPreference = 'SilentlyContinue'
    function NxRow { $args -join "`t" }
    $os = Get-CimInstance Win32_OperatingSystem
    "@INFO"
    NxRow ([int64]((Get-Date) - $os.LastBootUpTime).TotalSeconds) $os.TotalVisibleMemorySize $os.FreePhysicalMemory $os.TotalVirtualMemorySize $os.FreeVirtualMemory
    $cpus = @(Get-CimInstance -Query "SELECT Name, NumberOfCores FROM Win32_Processor")
    $cpus[0].Name
    ($cpus | Measure-Object NumberOfCores -Sum).Sum
    "@CPU"
    Get-CimInstance -Query "SELECT Name, PercentProcessorTime, PercentUserTime, PercentPrivilegedTime, Timestamp_Sys100NS FROM Win32_PerfRawData_PerfOS_Processor" | ForEach-Object { NxRow $_.Name $_.PercentProcessorTime $_.PercentUserTime $_.PercentPrivilegedTime $_.Timestamp_Sys100NS }
    "@PAGE"
    Get-CimInstance Win32_PageFileUsage | ForEach-Object { NxRow $_.AllocatedBaseSize $_.CurrentUsage }
    "@PROC"
    $p = @(Get-CimInstance -Query "SELECT Name, IDProcess, PercentProcessorTime, WorkingSetPrivate, WorkingSet, ThreadCount, ElapsedTime, Timestamp_Sys100NS FROM Win32_PerfRawData_PerfProc_Process")
    if ($p.Count) { NxRow T $p[0].Timestamp_Sys100NS }
    $p | Where-Object { $_.Name -ne '_Total' } | ForEach-Object { NxRow $_.IDProcess $_.PercentProcessorTime $_.WorkingSetPrivate $_.WorkingSet $_.ThreadCount $_.ElapsedTime $_.Name }
    "@DISK"
    Get-CimInstance -Query "SELECT Name, DiskReadBytesPersec, DiskWriteBytesPersec, DiskReadsPersec, DiskWritesPersec, Timestamp_Sys100NS FROM Win32_PerfRawData_PerfDisk_PhysicalDisk" | ForEach-Object { NxRow $_.DiskReadBytesPersec $_.DiskWriteBytesPersec $_.DiskReadsPersec $_.DiskWritesPersec $_.Timestamp_Sys100NS $_.Name }
    "@BLK"
    Get-CimInstance -Namespace root/Microsoft/Windows/Storage -ClassName MSFT_PhysicalDisk | ForEach-Object { NxRow $_.DeviceId $_.MediaType $_.BusType $_.Size $_.HealthStatus $_.FriendlyName }
    "@VOL"
    Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object { NxRow $_.DeviceID $_.Size $_.FreeSpace $_.FileSystem $_.VolumeName }
    "@NET"
    Get-CimInstance -Query "SELECT Name, BytesReceivedPersec, BytesSentPersec, CurrentBandwidth, Timestamp_Sys100NS FROM Win32_PerfRawData_Tcpip_NetworkInterface" | ForEach-Object { NxRow $_.BytesReceivedPersec $_.BytesSentPersec $_.CurrentBandwidth $_.Timestamp_Sys100NS $_.Name }
    "@GPU"
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) { nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,name --format=csv,noheader,nounits }
    "@END"
    """#
}

/// nvidia-smi 가 주는 GPU 하나. 못 읽은 값("[N/A]")은 nil
public struct LiveGPU: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    /// 0~100
    public let utilization: Double?
    /// 바이트
    public let memoryUsed: UInt64?
    public let memoryTotal: UInt64?
    /// °C
    public let temperature: Double?
    /// W
    public let power: Double?

    /// "3, 1843, 8192, 35, 19.41, NVIDIA GeForce RTX 3070 Ti"
    static func parse(_ line: String) -> LiveGPU? {
        let f = line.split(separator: ",", maxSplits: 5, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard f.count == 6, !f[5].isEmpty else { return nil }
        func mib(_ text: String) -> UInt64? { Double(text).map { UInt64($0 * 1_048_576) } }
        return LiveGPU(name: f[5], utilization: Double(f[0]), memoryUsed: mib(f[1]), memoryTotal: mib(f[2]), temperature: Double(f[3]), power: Double(f[4]))
    }
}

public struct WindowsRaw: Sendable, Equatable {
    /// 100ns — Windows 카운터의 시간 단위
    static let ticksPerSecond = 10_000_000.0

    public var uptime: Double?
    public var model: String?
    /// 물리 코어 수 (@CPU 의 줄 수는 논리 프로세서 — 하이퍼스레딩이면 두 배)
    public var physicalCores: Int?
    /// kB
    public var memoryTotal: UInt64 = 0
    /// kB. FreePhysicalMemory 는 비어 있는 것 + 바로 내줄 수 있는 대기 캐시 — 작업 관리자의 "사용 가능"
    public var memoryAvailable: UInt64 = 0
    /// MB (페이지 파일 전부의 합)
    public var pageTotal: UInt64 = 0
    public var pageUsed: UInt64 = 0
    /// user · system(privileged) · idle 만 채운다 (LinuxCPUTicks 의 0 · 2 · 3 번 자리)
    public var cpu: LinuxCPUTicks?
    /// 코어 번호순
    public var cores: [LinuxCPUTicks] = []
    public var processStamp: UInt64?
    /// ticks = 누적 CPU 시간(100ns), rssPages = 전용 작업 집합(바이트 — 작업 관리자의 "메모리"), startTime = 만든 시각. Idle(pid 0)은 뺀다
    public var processes: [LinuxProcessSample] = []
    /// 키는 화면 이름: 드라이브 글자("C:" · "C: D:"), 없으면 "Disk 번호"
    public var disks: [String: LinuxDiskCounter] = [:]
    public var diskStamp: UInt64?
    public var diskInfo: [String: LinuxDiskInfo] = [:]
    public var volumes: [LinuxVolume] = []
    public var interfaces: [LinuxInterface] = []
    public var networkStamp: UInt64?
    public var gpus: [LiveGPU] = []
    public init() {}

    /// @END 가 없으면(출력이 끊김) nil. 줄 끝 CR 은 뗀다 (PowerShell 은 CRLF 로 낸다).
    public static func parse(_ text: String) -> WindowsRaw? {
        guard let s = ScriptSections.parse(text.replacingOccurrences(of: "\r", with: ""), dropEmpty: true) else { return nil }
        func fields(_ line: String, _ count: Int) -> [String]? {
            let f = line.split(separator: "\t", maxSplits: count - 1, omittingEmptySubsequences: false).map(String.init)
            return f.count == count ? f : nil
        }
        var raw = WindowsRaw()
        let info = s["INFO"] ?? []
        if let f = info.first.flatMap({ fields($0, 5) }) {
            raw.uptime = Double(f[0])
            raw.memoryTotal = UInt64(f[1]) ?? 0
            raw.memoryAvailable = UInt64(f[2]) ?? 0
        }
        if info.count > 1 { raw.model = info[1].trimmingCharacters(in: .whitespaces) }
        if info.count > 2 { raw.physicalCores = Int(info[2].trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil } }

        var cores: [(order: [Int], ticks: LinuxCPUTicks)] = []
        for line in s["CPU"] ?? [] {
            guard let f = fields(line, 5), let idle = UInt64(f[1]), let user = UInt64(f[2]), let system = UInt64(f[3]) else { continue }
            let ticks = LinuxCPUTicks([user, 0, system, idle])
            if f[0] == "_Total" { raw.cpu = ticks; continue }
            // 프로세서 그룹이 여럿이면 "0,3" 꼴 — 숫자 묶음으로 줄 세운다 (글자순이면 0 · 1 · 10 · 11 · 2)
            let order = f[0].split(separator: ",").compactMap { Int($0) }
            guard !order.isEmpty else { continue }
            cores.append((order, ticks))
        }
        raw.cores = cores.sorted { $0.order.lexicographicallyPrecedes($1.order) }.map(\.ticks)

        for line in s["PAGE"] ?? [] {
            guard let f = fields(line, 2), let total = UInt64(f[0]) else { continue }
            raw.pageTotal += total
            raw.pageUsed += UInt64(f[1]) ?? 0
        }

        for line in s["PROC"] ?? [] {
            if line.hasPrefix("T\t") { raw.processStamp = UInt64(line.dropFirst(2)); continue }
            guard let f = fields(line, 7), let pid = Int(f[0]), pid != 0, let ticks = UInt64(f[1]) else { continue }
            // 같은 이름이 여럿이면 "svchost#17" 로 온다 — 번호는 뗀다
            let name = f[6].range(of: #"#\d+$"#, options: .regularExpression).map { String(f[6][..<$0.lowerBound]) } ?? f[6]
            raw.processes.append(LinuxProcessSample(pid: pid, state: "", ticks: ticks, threads: Int(f[4]) ?? 1, rssPages: UInt64(f[2]) ?? 0,
                                                    startTime: UInt64(f[5]) ?? 0, command: name))
        }

        var diskNames: [Int: String] = [:]
        for line in s["DISK"] ?? [] {
            guard let f = fields(line, 6), f[5] != "_Total", let bytesRead = UInt64(f[0]), let bytesWritten = UInt64(f[1]),
                  let reads = UInt64(f[2]), let writes = UInt64(f[3]) else { continue }
            raw.diskStamp = UInt64(f[4])
            // "1 C:" · "0 D: E:" · "2" (드라이브 글자 없는 디스크)
            let parts = f[5].split(separator: " ", maxSplits: 1).map(String.init)
            guard let index = parts.first.flatMap({ Int($0) }) else { continue }
            let name = parts.count > 1 ? parts[1] : "Disk \(index)"
            diskNames[index] = name
            raw.disks[name] = LinuxDiskCounter(reads: reads, writes: writes, bytesRead: bytesRead, bytesWritten: bytesWritten)
        }
        for line in s["BLK"] ?? [] {
            guard let f = fields(line, 6), let index = Int(f[0]) else { continue }
            let model = f[5].trimmingCharacters(in: .whitespaces)
            let health = Int(f[4])
            raw.diskInfo[diskNames[index] ?? "Disk \(index)"] = LinuxDiskInfo(
                rotational: f[1] == "3" ? true : (f[1] == "4" ? false : nil), size: UInt64(f[3]) ?? 0, model: model.isEmpty ? nil : model,
                healthy: health == 0 ? true : (health == 1 || health == 2 ? false : nil))
        }
        for line in s["VOL"] ?? [] {
            guard let f = fields(line, 5), let size = UInt64(f[1]), size > 0, let free = UInt64(f[2]), free <= size else { continue }
            raw.volumes.append(LinuxVolume(device: f[4], fsType: f[3], size: size, used: size - free, available: free, mountPoint: f[0]))
        }
        for line in s["NET"] ?? [] {
            guard let f = fields(line, 5), let rx = UInt64(f[0]), let tx = UInt64(f[1]) else { continue }
            raw.networkStamp = UInt64(f[3])
            // 카운터에 나오는 것은 실제 어댑터뿐이다 (Hyper-V 가상 스위치는 따로 센다)
            raw.interfaces.append(LinuxInterface(name: f[4], physical: true, state: "up",
                                                 speedMbps: UInt64(f[2]).flatMap { $0 > 0 ? Int($0 / 1_000_000) : nil }.flatMap { $0 > 0 && $0 <= 400_000 ? $0 : nil },
                                                 rxBytes: rx, txBytes: tx))
        }
        raw.gpus = (s["GPU"] ?? []).compactMap(LiveGPU.parse)
        return raw
    }
}

/// 직전 표본과의 차이로 CPU·디스크·네트워크 속도·프로세스 %CPU 를 낸다. 첫 표본은 차이가 없어 그 값들이 빈다.
/// 화면이 리눅스와 같아 결과는 LinuxLiveSnapshot (system = .windows — 부하·iowait·캐시처럼 Windows 에 없는 줄은 화면이 뺀다).
public struct WindowsLiveSampler: Sendable {
    private var last: WindowsRaw?
    public init() {}

    public mutating func step(_ raw: WindowsRaw, at: Date) -> LinuxLiveSnapshot {
        var snapshot = LinuxLiveSnapshot(at: at)
        snapshot.system = .windows
        snapshot.model = raw.model
        snapshot.cores = raw.cores.count
        snapshot.physicalCores = raw.physicalCores
        snapshot.uptime = raw.uptime
        if raw.memoryTotal > 0 {
            let total = raw.memoryTotal * 1024, available = min(raw.memoryAvailable, raw.memoryTotal) * 1024
            let memory = LinuxMemory(total: total, used: total - available, shared: 0, buffers: 0, cache: 0, free: available, available: available,
                                     swapTotal: raw.pageTotal * 1_048_576, swapUsed: min(raw.pageUsed, raw.pageTotal) * 1_048_576)
            snapshot.memory = memory
            snapshot.pressure = memory.pressure(psiSome: nil, psiFull: nil)   // PSI 가 없다 — 남은 메모리 5% · 10% 미만
        }
        snapshot.volumes = raw.volumes
        snapshot.diskInfo = raw.diskInfo
        snapshot.gpus = raw.gpus
        snapshot.processCount = raw.processes.count
        snapshot.threads = raw.processes.reduce(0) { $0 + $1.threads }

        /// 두 시각(100ns) 사이의 초. 뒤가 앞보다 이르면(카운터 초기화) 0
        func seconds(_ old: UInt64?, _ new: UInt64?) -> Double {
            guard let old, let new, new > old else { return 0 }
            return Double(new - old) / WindowsRaw.ticksPerSecond
        }
        var oldTicks: [String: UInt64] = [:]
        var processSeconds = 0.0
        if let last {
            if let a = last.cpu, let b = raw.cpu {
                snapshot.cpu = LinuxCPUUsage.between(a, b, oldCores: last.cores, newCores: raw.cores)
            }
            let old = last.disks.mapValues { DiskCounters(bytesRead: $0.bytesRead, bytesWritten: $0.bytesWritten, opsRead: $0.reads, opsWritten: $0.writes) }
            let new = raw.disks.mapValues { DiskCounters(bytesRead: $0.bytesRead, bytesWritten: $0.bytesWritten, opsRead: $0.reads, opsWritten: $0.writes) }
            if let rates = DiskIO.rates(old, new, seconds: seconds(last.diskStamp, raw.diskStamp)) {
                snapshot.disk = rates.total
                snapshot.perDisk = rates.perDisk
            }
            let networkSeconds = seconds(last.networkStamp, raw.networkStamp)
            if networkSeconds > 0 {
                let before = Dictionary(last.interfaces.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
                var totalRx = 0.0, totalTx = 0.0
                for i in raw.interfaces {
                    guard let old = before[i.name] else { continue }
                    let rx = i.rxBytes >= old.rxBytes ? Double(i.rxBytes - old.rxBytes) / networkSeconds : 0
                    let tx = i.txBytes >= old.txBytes ? Double(i.txBytes - old.txBytes) / networkSeconds : 0
                    snapshot.interfaces.append(LinuxInterfaceRate(name: i.name, physical: i.physical, state: i.state, speedMbps: i.speedMbps, rx: rx, tx: tx))
                    totalRx += rx; totalTx += tx
                }
                snapshot.networkTotal = LinuxTraffic(rx: totalRx, tx: totalTx)
            }
            processSeconds = seconds(last.processStamp, raw.processStamp)
            for p in last.processes { oldTicks["\(p.pid):\(p.startTime)"] = p.ticks }
        }
        // %CPU = ΔCPU 시간 / Δ시각 × 100 (코어 하나 = 100). pid 재사용은 만든 시각으로 가른다.
        snapshot.processes = raw.processes.map { p in
            var cpu = 0.0
            if processSeconds > 0, let before = oldTicks["\(p.pid):\(p.startTime)"], p.ticks >= before {
                cpu = Double(p.ticks - before) / WindowsRaw.ticksPerSecond / processSeconds * 100
            }
            return LinuxProcessRow(pid: p.pid, cpu: cpu, memory: p.rssPages, state: p.state, threads: p.threads,
                                   cpuTime: Double(p.ticks) / WindowsRaw.ticksPerSecond, command: p.command)
        }.sorted { ($0.cpu, $0.memory, $1.pid) > ($1.cpu, $1.memory, $0.pid) }
        last = raw
        return snapshot
    }
}
