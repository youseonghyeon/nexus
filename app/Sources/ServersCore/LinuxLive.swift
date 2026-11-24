// 리눅스 서버의 "실시간" 탭: CPU·코어·메모리·스왑·부하·디스크 사용/입출력·온도·상위 프로세스.
// ~/.tools/linux/stats.sh · disk.sh 와 같은 값·같은 계산 (출처는 스크립트 이름으로 주석). 서버에는 아무것도 설치하지 않는다 —
// 그 탭을 보고 있을 때만 ssh 한 번(기존 공유 연결)으로 아래 스크립트를 돌려 /proc 원문을 받고, 계산은 여기서 한다.

import Foundation

public enum LinuxLive {
    /// sh -s 로 보낸다 (POSIX sh · procps 불필요 · root 불필요). 구역마다 @이름 줄로 시작한다.
    public static let script = #"""
    export LC_ALL=C
    echo @INFO
    getconf CLK_TCK 2>/dev/null || echo 100
    getconf PAGESIZE 2>/dev/null || echo 4096
    awk -F': *' '/^(model name|Model name|Hardware|Model)[ \t]*:/ && $2 != "" { print $2; exit }' /proc/cpuinfo 2>/dev/null
    echo @UP; cat /proc/uptime
    # 물리 코어 수: (physical id, core id) 쌍의 가짓수. ARM 처럼 그 줄이 없는 CPU 는 아무것도 내지 않는다
    echo @CORES; awk -F': *' '/^physical id/ { p = $2 } /^core id/ { seen[p "," $2] = 1 } END { n = 0; for (k in seen) n++; if (n) print n }' /proc/cpuinfo 2>/dev/null
    echo @STAT; sed -n '/^cpu/p;/^procs_/p' /proc/stat
    echo @LOAD; cat /proc/loadavg
    echo @MEM; cat /proc/meminfo
    echo @PSI; cat /proc/pressure/memory 2>/dev/null
    echo @DISK; cat /proc/diskstats 2>/dev/null
    echo @BLK
    for d in /sys/block/*; do
      [ -e "$d" ] || continue; b=${d##*/}
      # 디스크가 아닌 것은 읽기 전에 거른다 (snap 이 많은 서버는 loop 가 수십 개) — 값은 내장 read 로, 장치마다 프로세스를 띄우지 않는다
      # mmcblk0boot0·boot1·rpmb 는 eMMC 칩의 부트·보안 영역 (몇 MB) — 디스크가 아니다
      case "$b" in loop*|ram*|zram*|nbd*|fd*|sr*|mmcblk*boot*|mmcblk*rpmb) continue ;; esac
      s=0; for x in "$d"/slaves/*; do [ -e "$x" ] && s=1; break; done
      r=-; z=0; m=
      { read -r r < "$d/queue/rotational"; } 2>/dev/null
      { read -r z < "$d/size"; } 2>/dev/null
      { read -r m < "$d/device/model"; } 2>/dev/null
      echo "$b $s ${r:--} ${z:-0} $m"
    done
    echo @MD; cat /proc/mdstat 2>/dev/null
    echo @FREQ; cat /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq 2>/dev/null
    echo @THROTTLE; cat /sys/devices/system/cpu/cpu[0-9]*/thermal_throttle/core_throttle_count 2>/dev/null
    echo @NET
    for n in /sys/class/net/*; do
      i=${n##*/}; p=0; [ -e "$n/device" ] && p=1
      # 물리 + VPN·본딩만 — veth 가 수백 개인 노드에서 장치마다 읽지 않게 먼저 거른다 (read 는 내장이라 프로세스를 띄우지 않는다)
      case "$i" in lo|tunl*) continue ;; tailscale*|wg*|tun*|bond*|zt*) ;; *) [ "$p" = 1 ] || continue ;; esac
      st=-; sp=-; rx=0; tx=0
      { read -r st < "$n/operstate"; } 2>/dev/null
      { read -r sp < "$n/speed"; } 2>/dev/null || sp=-
      { read -r rx < "$n/statistics/rx_bytes"; } 2>/dev/null
      { read -r tx < "$n/statistics/tx_bytes"; } 2>/dev/null
      echo "$i $p ${st:--} ${sp:--} ${rx:-0} ${tx:-0}"
    done
    echo @DF
    # busybox df(OpenWrt)는 -l 이 없다 — 출력이 비었을 때만 -l 없이 (GNU df 는 읽지 못한 마운트가 하나만 있어도 1 로 끝나지만 출력은 있다)
    if command -v timeout >/dev/null 2>&1; then t="timeout -k 1 3"; else t=""; fi
    out=$($t df -kPTl 2>/dev/null)
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      # 네트워크 마운트는 따로 — 응답 없는 NFS 에 df 가 멈춰도 위의 로컬 볼륨은 남는다 (-t 는 고른 종류만 stat 한다, 머리글 줄은 뺀다)
      $t df -kPT -t nfs -t nfs4 -t cifs -t smb3 -t smbfs -t fuse.sshfs -t ceph -t fuse.ceph -t glusterfs -t fuse.glusterfs -t lustre -t 9p -t afs 2>/dev/null | sed 1d
    else
      $t df -kPT 2>/dev/null
    fi
    echo @TEMP
    for z in /sys/class/thermal/thermal_zone*; do
      [ -r "$z/temp" ] || continue
      case "$(cat "$z/type" 2>/dev/null)" in x86_pkg_temp|cpu*|soc*|*cpu-thermal*|*cpu_thermal*|TCPU|CPU*) cat "$z/temp" 2>/dev/null ;; esac
    done
    for h in /sys/class/hwmon/hwmon*; do
      case "$(cat "$h/name" 2>/dev/null)" in
        coretemp|k10temp|k8temp|zenpower|cpu-thermal|cpu_thermal|soc-thermal|soc_thermal|cpu|acpitz)
          for f in "$h"/temp*_input; do [ -r "$f" ] && cat "$f" 2>/dev/null; done ;;
      esac
    done
    echo @PROC
    cat /proc/[0-9]*/stat 2>/dev/null | awk '{
      i = index($0, "("); j = 0
      for (k = length($0); k > i; k--) if (substr($0, k, 1) == ")") { j = k; break }
      if (!i || !j) next
      n = split(substr($0, j + 2), f, " ")
      printf "%s\t%s\t%.0f\t%s\t%s\t%s\t%s\n", $1, f[1], f[12] + f[13], f[18], f[22], f[20], substr($0, i + 1, j - i - 1)
    }'
    echo @END
    """#

    /// 구역별 줄 (@INFO … @END, 빈 줄은 뺀다). @END 가 없으면 출력이 잘린 것이라 nil.
    public static func sections(_ text: String) -> [String: [String]]? {
        ScriptSections.parse(text, dropEmpty: true)
    }
}

// MARK: 원자료

public struct LinuxCPUTicks: Sendable, Equatable {
    /// user nice system idle iowait irq softirq steal
    public let values: [UInt64]
    public init(_ values: [UInt64]) { self.values = values + Array(repeating: 0, count: max(0, 8 - values.count)) }
    var busy: UInt64 { values[0] + values[1] + values[2] + values[5] + values[6] + values[7] }
    var idleAll: UInt64 { values[3] + values[4] }
    var total: UInt64 { busy + idleAll }
}

public struct LinuxDiskCounter: Sendable, Equatable {
    public let reads, writes, bytesRead, bytesWritten: UInt64
}

public struct LinuxProcessSample: Sendable, Equatable {
    public let pid: Int
    public let state: String
    public let ticks: UInt64
    public let threads: Int
    public let rssPages: UInt64
    public let startTime: UInt64
    public let command: String
}

public struct LinuxInterface: Sendable, Equatable {
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
}

/// 바이트/초
public struct LinuxTraffic: Sendable, Equatable {
    public let rx: Double
    public let tx: Double
}

public struct LinuxInterfaceRate: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let physical: Bool
    public let state: String
    public let speedMbps: Int?
    /// 바이트/초
    public let rx: Double
    public let tx: Double
}

public struct LinuxDiskInfo: Sendable, Equatable {
    /// true HDD · false SSD · nil 모름
    public let rotational: Bool?
    public let size: UInt64
    public let model: String?
    /// 디스크가 스스로 알리는 상태 (Windows 저장소 관리의 HealthStatus). 리눅스는 SMART 가 root 를 요구해 읽지 않는다 — nil
    public var healthy: Bool? = nil
}

/// /proc/mdstat 의 배열 하나. disk.sh 는 구성원의 (F) 로만 손상을 보지만, 빠진 디스크가 [U_] 로만 보이는 경우도 손상으로 잡는다.
public struct LinuxRAID: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let level: String
    public let active: Bool
    public let members: [String]
    public let failedMembers: Int
    /// [2/2] 의 앞·뒤 (전체 · 살아 있는 수)
    public let total: Int?
    public let working: Int?
    /// "복구 12.6%" · "동기화 40.1%" · "검사 3.0%" · "동기화 대기"
    public let progress: String?
    /// 정기 검사(check) — 매달 몇 시간씩 돌아 경고로 치지 않는다
    public let checking: Bool
    /// Intel RST·VROC(IMSM) 같은 외부 메타데이터 컨테이너 — 정상이어도 inactive 로 보인다
    public let external: Bool

    public var degraded: Bool { failedMembers > 0 || (total.flatMap { t in working.map { $0 < t } } ?? false) || (!active && !external) }

    public static func parse(_ lines: [String]) -> [LinuxRAID] {
        var out: [LinuxRAID] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard line.hasPrefix("md"), let colon = line.range(of: " : ") else { index += 1; continue }
            let name = String(line[..<colon.lowerBound])
            let words = line[colon.upperBound...].split(separator: " ").map(String.init)
            let level = words.first { $0.hasPrefix("raid") || $0 == "linear" || $0 == "multipath" } ?? "md"
            let members = words.filter { $0.contains("[") }
            var total: Int?, working: Int?, progress: String?, checking = false, external = false
            var next = index + 1
            while next < lines.count, !lines[next].hasPrefix("md"), !lines[next].hasPrefix("unused"), !lines[next].hasPrefix("Personalities") {
                let detail = lines[next]
                if let r = detail.range(of: #"\[(\d+)/(\d+)\]"#, options: .regularExpression) {
                    let numbers = detail[r].dropFirst().dropLast().split(separator: "/").compactMap { Int($0) }
                    if numbers.count == 2 { total = numbers[0]; working = numbers[1] }
                }
                if detail.contains("super external:") { external = true }
                for (key, label) in [("recovery", "복구"), ("resync", "동기화"), ("reshape", "재구성"), ("check", "검사"), ("repair", "복구 검사")] {
                    if let r = detail.range(of: key + #" *= *[0-9.]+%"#, options: .regularExpression) {
                        let percent = detail[r].split(separator: "=").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                        progress = "\(label) \(percent)"
                        checking = key == "check"
                    } else if detail.range(of: key + #" *= *(PENDING|DELAYED)"#, options: .regularExpression) != nil {
                        progress = "\(label) 대기"
                        checking = key == "check"
                    }
                }
                next += 1
            }
            out.append(LinuxRAID(name: name, level: level, active: words.first == "active", members: members,
                                 failedMembers: members.filter { $0.contains("(F)") }.count, total: total, working: working, progress: progress,
                                 checking: checking, external: external))
            index = next
        }
        return out
    }
}

public struct LinuxVolume: Sendable, Equatable, Identifiable {
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

public struct LinuxRaw: Sendable, Equatable {
    public var clockTicks: Double = 100
    public var pageSize: UInt64 = 4096
    public var model: String?
    public var uptime: Double?
    /// 물리 코어 수 (x86 만 — /proc/cpuinfo 에 core id 가 없으면 nil). cores 는 논리 프로세서
    public var physicalCores: Int?
    public var cpu: LinuxCPUTicks?
    public var cores: [LinuxCPUTicks] = []
    public var load: [Double] = []
    /// kB
    public var memory: [String: UInt64] = [:]
    public var psiSome: Double?
    public var psiFull: Double?
    public var disks: [String: LinuxDiskCounter] = [:]
    public var volumes: [LinuxVolume] = []
    /// °C
    public var temperatures: [Double] = []
    public var processes: [LinuxProcessSample] = []
    /// 통째 디스크의 모델·크기·회전(HDD) — /sys/block (disk.sh 는 lsblk, 같은 값)
    public var diskInfo: [String: LinuxDiskInfo] = [:]
    public var raids: [LinuxRAID] = []
    /// 코어별 현재 클럭 kHz (stats.sh)
    public var frequencies: [Double] = []
    /// 부팅 뒤 열 스로틀 횟수 합 (x86 만, stats.sh)
    public var throttleEvents: Int?
    /// /sys/class/net (net.sh 와 같은 출처). 스크립트가 물리 + VPN·본딩만 보낸다 (LinuxInterface.shown 과 같은 규칙)
    public var interfaces: [LinuxInterface] = []
    public init() {}

    /// disk.sh: 통째 디스크만 — loop·ram·zram·fd·dm·md·nbd·sr 제외, /sys/block 에 있고 slaves 가 없는 것
    static let skippedDiskPrefixes = ["loop", "ram", "zram", "fd", "dm-", "md", "nbd", "sr"]
    /// eMMC 의 부트·보안 영역(mmcblk0boot0·mmcblk0boot1·mmcblk0rpmb)도 디스크로 치지 않는다 — OpenWrt 공유기에서 4 MB 짜리 줄이 둘 보였다
    static func isSkippedDisk(_ name: String) -> Bool {
        skippedDiskPrefixes.contains { name.hasPrefix($0) } || (name.hasPrefix("mmcblk") && (name.contains("boot") || name.hasSuffix("rpmb")))
    }
    /// disk.sh: 숨기는 파일시스템 종류와 마운트 자리
    static let hiddenFileSystems: Set<String> = ["tmpfs", "devtmpfs", "proc", "sysfs", "cgroup", "cgroup2", "squashfs", "devpts", "efivarfs",
        "securityfs", "pstore", "bpf", "hugetlbfs", "debugfs", "tracefs", "mqueue", "fusectl", "configfs", "binfmt_misc", "autofs", "ramfs",
        "rpc_pipefs", "selinuxfs", "fuse.portal", "fuse.gvfsd-fuse", "fuse.lxcfs", "fuse.snapfuse", "nsfs"]
    static let hiddenMountPrefixes = ["/snap/", "/var/lib/snapd/", "/var/snap/docker/", "/run/", "/sys/", "/proc/", "/dev/", "/var/lib/kubelet/",
                                      "/var/lib/docker/", "/var/lib/containerd/", "/run/netns/"]

    public static func parse(_ text: String) -> LinuxRaw? {
        guard let s = LinuxLive.sections(text) else { return nil }
        var raw = LinuxRaw()
        let info = s["INFO"] ?? []
        if let first = info.first.flatMap(Double.init), first > 0 { raw.clockTicks = first }
        if info.count > 1, let page = UInt64(info[1]), page > 0 { raw.pageSize = page }
        if info.count > 2 { raw.model = info[2].trimmingCharacters(in: .whitespaces) }
        raw.uptime = s["UP"]?.first?.split(separator: " ").first.flatMap { Double($0) }
        raw.physicalCores = s["CORES"]?.first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 > 0 ? $0 : nil }

        for line in s["STAT"] ?? [] {
            let fields = line.split(separator: " ")
            guard let name = fields.first else { continue }
            guard name.hasPrefix("cpu") else { continue }
            let ticks = LinuxCPUTicks(fields.dropFirst().prefix(8).compactMap { UInt64($0) })
            if name == "cpu" { raw.cpu = ticks } else { raw.cores.append(ticks) }
        }
        raw.load = (s["LOAD"]?.first?.split(separator: " ").prefix(3).compactMap { Double($0) }) ?? []
        for line in s["MEM"] ?? [] {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let value = parts[1].split(separator: " ").first.flatMap({ UInt64($0) }) else { continue }
            raw.memory[String(parts[0])] = value
        }
        for line in s["PSI"] ?? [] {
            guard let avg = line.split(separator: " ").first(where: { $0.hasPrefix("avg10=") }).flatMap({ Double($0.dropFirst(6)) }) else { continue }
            if line.hasPrefix("some") { raw.psiSome = avg } else if line.hasPrefix("full") { raw.psiFull = avg }
        }

        var wholeDisks: Set<String> = []
        for line in s["BLK"] ?? [] {
            // 이름 slaves여부 회전 크기(섹터) 모델…
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count >= 4, parts[1] == "0" else { continue }
            let name = String(parts[0])
            guard !isSkippedDisk(name) else { continue }
            wholeDisks.insert(name)
            let model = parts.count == 5 ? parts[4].trimmingCharacters(in: .whitespaces) : ""
            raw.diskInfo[name] = LinuxDiskInfo(rotational: parts[2] == "1" ? true : (parts[2] == "0" ? false : nil),
                                               size: (UInt64(parts[3]) ?? 0) * 512, model: model.isEmpty ? nil : model)
        }
        raw.raids = LinuxRAID.parse(s["MD"] ?? [])
        raw.frequencies = (s["FREQ"] ?? []).compactMap { Double($0) }.filter { $0 > 0 }
        let throttles = (s["THROTTLE"] ?? []).compactMap { Int($0) }
        raw.throttleEvents = throttles.isEmpty ? nil : throttles.reduce(0, +)
        for line in s["NET"] ?? [] {
            let f = line.split(separator: " ")
            guard f.count == 6, let rx = UInt64(f[4]), let tx = UInt64(f[5]) else { continue }
            raw.interfaces.append(LinuxInterface(name: String(f[0]), physical: f[1] == "1", state: String(f[2]),
                                                 // 옛 커널은 모를 때 4294967295 를 준다 — 400 Gbps 넘으면 모름
                                                 speedMbps: Int(f[3]).flatMap { $0 > 0 && $0 <= 400_000 ? $0 : nil }, rxBytes: rx, txBytes: tx))
        }
        for line in s["DISK"] ?? [] {
            let f = line.split(separator: " ")
            guard f.count >= 10, wholeDisks.contains(String(f[2])),
                  let reads = UInt64(f[3]), let sectorsRead = UInt64(f[5]), let writes = UInt64(f[7]), let sectorsWritten = UInt64(f[9]) else { continue }
            raw.disks[String(f[2])] = LinuxDiskCounter(reads: reads, writes: writes, bytesRead: sectorsRead * 512, bytesWritten: sectorsWritten * 512)
        }
        for line in (s["DF"] ?? []).dropFirst() {   // 머리글 줄
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 7, let size = UInt64(f[2]), let used = UInt64(f[3]), let available = UInt64(f[4]) else { continue }
            let mount = f[6...].joined(separator: " ")
            let type = String(f[1])
            if hiddenFileSystems.contains(type) || (type == "overlay" && mount != "/") { continue }
            if mount == "/boot/efi" || hiddenMountPrefixes.contains(where: { mount.hasPrefix($0) }) || f[0].contains("[") { continue }
            if raw.volumes.contains(where: { $0.mountPoint == mount }) { continue }
            raw.volumes.append(LinuxVolume(device: String(f[0]), fsType: type, size: size * 1024, used: used * 1024, available: available * 1024, mountPoint: mount))
        }
        raw.temperatures = (s["TEMP"] ?? []).compactMap { Double($0) }.map { $0 / 1000 }.filter { $0 > 0 && $0 <= 150 }
        for line in s["PROC"] ?? [] {
            let f = line.split(separator: "\t", maxSplits: 6, omittingEmptySubsequences: false)
            guard f.count == 7, let pid = Int(f[0]), let ticks = UInt64(f[2]) else { continue }
            raw.processes.append(LinuxProcessSample(pid: pid, state: String(f[1]), ticks: ticks, threads: Int(f[3]) ?? 1,
                                                    rssPages: UInt64(f[4]) ?? 0, startTime: UInt64(f[5]) ?? 0, command: String(f[6])))
        }
        return raw
    }
}

// MARK: 계산

public struct LinuxCPUUsage: Sendable, Equatable {
    /// 0~100. stats.sh: 바쁨 = user+nice+system+irq+softirq+steal, 대기 = idle+iowait
    public let total, user, system, iowait, steal, idle: Double
    public let cores: [Double]

    public static func between(_ old: LinuxCPUTicks, _ new: LinuxCPUTicks, oldCores: [LinuxCPUTicks], newCores: [LinuxCPUTicks]) -> LinuxCPUUsage? {
        func delta(_ a: UInt64, _ b: UInt64) -> Double { b >= a ? Double(b - a) : 0 }
        let total = delta(old.total, new.total)
        guard total > 0 else { return nil }
        func share(_ index: [Int]) -> Double { index.reduce(0) { $0 + delta(old.values[$1], new.values[$1]) } / total * 100 }
        let cores: [Double] = oldCores.count == newCores.count ? zip(oldCores, newCores).map { a, b in
            let t = delta(a.total, b.total)
            return t > 0 ? delta(a.busy, b.busy) / t * 100 : 0
        } : []
        return LinuxCPUUsage(total: delta(old.busy, new.busy) / total * 100, user: share([0, 1]), system: share([2, 5, 6]),
                             iowait: share([4]), steal: share([7]), idle: share([3]), cores: cores)
    }
}

/// htop 방식 (stats.sh). 바이트.
public struct LinuxMemory: Sendable, Equatable {
    public let total, used, shared, buffers, cache, free, available: UInt64
    public let swapTotal, swapUsed: UInt64
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    public static func from(_ kb: [String: UInt64]) -> LinuxMemory? {
        guard let total = kb["MemTotal"], total > 0 else { return nil }
        func v(_ key: String) -> UInt64 { kb[key] ?? 0 }
        let reclaim = v("Buffers") + v("Cached") + v("SReclaimable")
        let used = total > v("MemFree") + reclaim ? total - v("MemFree") - reclaim : 0
        let cacheRaw = v("Cached") + v("SReclaimable")
        return LinuxMemory(total: total * 1024, used: used * 1024, shared: v("Shmem") * 1024, buffers: v("Buffers") * 1024,
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

public struct LinuxProcessRow: Sendable, Equatable, Identifiable {
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
}

public struct LinuxLiveSnapshot: Sendable, Equatable {
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
    public var cpu: LinuxCPUUsage?
    public var memory: LinuxMemory?
    public var pressure: MemoryPressure = .unknown
    public var load: [Double] = []
    public var processCount = 0
    public var running = 0
    public var threads = 0
    public var disk: DiskIO?
    public var perDisk: [String: DiskIO] = [:]
    public var volumes: [LinuxVolume] = []
    public var temperatureMax: Double?
    public var temperatureAverage: Double?
    public var diskInfo: [String: LinuxDiskInfo] = [:]
    public var raids: [LinuxRAID] = []
    /// MHz
    public var frequencyAverage: Double?
    public var frequencyMax: Double?
    public var throttleEvents: Int?
    /// 보여 줄 인터페이스의 초당 속도 (물리 + VPN·본딩). 합계는 물리만 — 브리지·veth 는 같은 트래픽을 한 번 더 센다
    public var interfaces: [LinuxInterfaceRate] = []
    public var networkTotal: LinuxTraffic?
    /// CPU 순 전체 (화면이 정렬·자른다)
    public var processes: [LinuxProcessRow] = []
    public var at: Date
    public init(at: Date) { self.at = at }
}

/// 직전 표본과의 차이로 CPU·디스크 속도·프로세스 %CPU 를 낸다. 첫 표본은 차이가 없어 그 값들이 빈다.
public struct LinuxLiveSampler: Sendable {
    private var last: (raw: LinuxRaw, at: Date)?
    public init() {}

    public mutating func step(_ raw: LinuxRaw, at: Date) -> LinuxLiveSnapshot {
        var snapshot = LinuxLiveSnapshot(at: at)
        snapshot.model = raw.model
        snapshot.cores = raw.cores.count
        snapshot.physicalCores = raw.physicalCores
        snapshot.uptime = raw.uptime
        snapshot.load = raw.load
        snapshot.memory = LinuxMemory.from(raw.memory)
        snapshot.pressure = snapshot.memory?.pressure(psiSome: raw.psiSome, psiFull: raw.psiFull) ?? .unknown
        snapshot.volumes = raw.volumes
        snapshot.diskInfo = raw.diskInfo
        snapshot.raids = raw.raids
        if !raw.frequencies.isEmpty {
            snapshot.frequencyAverage = raw.frequencies.reduce(0, +) / Double(raw.frequencies.count) / 1000
            snapshot.frequencyMax = (raw.frequencies.max() ?? 0) / 1000
        }
        snapshot.throttleEvents = raw.throttleEvents
        snapshot.processCount = raw.processes.count
        // stats.sh: 상태가 R 인 프로세스 수 (procs_running 은 실행 대기 스레드 수라 값이 다르다)
        snapshot.running = raw.processes.filter { $0.state == "R" }.count
        snapshot.threads = raw.processes.reduce(0) { $0 + $1.threads }
        if !raw.temperatures.isEmpty {
            snapshot.temperatureMax = raw.temperatures.max()
            snapshot.temperatureAverage = raw.temperatures.reduce(0, +) / Double(raw.temperatures.count)
        }

        var oldTicks: [String: UInt64] = [:]
        var jiffies: Double = 0
        if let last {
            if let a = last.raw.cpu, let b = raw.cpu {
                snapshot.cpu = LinuxCPUUsage.between(a, b, oldCores: last.raw.cores, newCores: raw.cores)
                jiffies = b.total > a.total ? Double(b.total - a.total) : 0
            }
            // 서버 쪽 시간(uptime 차이)으로 — Mac 이 응답을 받은 시각은 ssh 왕복 편차가 섞인다
            // 한쪽 uptime 만 못 읽었으면 차이가 uptime 전체가 된다 — 둘 다 있을 때만
            let serverSeconds = raw.uptime.flatMap { now in last.raw.uptime.map { now - $0 } } ?? 0
            let seconds = serverSeconds > 0 ? serverSeconds : at.timeIntervalSince(last.at)
            let old = last.raw.disks.mapValues { DiskCounters(bytesRead: $0.bytesRead, bytesWritten: $0.bytesWritten, opsRead: $0.reads, opsWritten: $0.writes) }
            let new = raw.disks.mapValues { DiskCounters(bytesRead: $0.bytesRead, bytesWritten: $0.bytesWritten, opsRead: $0.reads, opsWritten: $0.writes) }
            if let rates = DiskIO.rates(old, new, seconds: seconds) {
                snapshot.disk = rates.total
                snapshot.perDisk = rates.perDisk
            }
            for p in last.raw.processes { oldTicks["\(p.pid):\(p.startTime)"] = p.ticks }
            if seconds > 0 {
                let before = Dictionary(last.raw.interfaces.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
                var totalRx = 0.0, totalTx = 0.0
                for i in raw.interfaces where i.shown {
                    guard let old = before[i.name] else { continue }
                    let rx = i.rxBytes >= old.rxBytes ? Double(i.rxBytes - old.rxBytes) / seconds : 0
                    let tx = i.txBytes >= old.txBytes ? Double(i.txBytes - old.txBytes) / seconds : 0
                    snapshot.interfaces.append(LinuxInterfaceRate(name: i.name, physical: i.physical, state: i.state, speedMbps: i.speedMbps, rx: rx, tx: tx))
                    if i.physical { totalRx += rx; totalTx += tx }
                }
                snapshot.networkTotal = LinuxTraffic(rx: totalRx, tx: totalTx)
            }
        }
        // stats.sh: %CPU = Δticks × 코어 수 / Δ(전체 jiffies) × 100. pid 재사용은 starttime 으로 가른다.
        let cores = Double(max(1, raw.cores.count))
        snapshot.processes = raw.processes.map { p in
            var cpu = 0.0
            if jiffies > 0, let before = oldTicks["\(p.pid):\(p.startTime)"], p.ticks >= before {
                cpu = Double(p.ticks - before) * cores / jiffies * 100
            }
            return LinuxProcessRow(pid: p.pid, cpu: cpu, memory: p.rssPages * raw.pageSize, state: p.state, threads: p.threads,
                                   cpuTime: Double(p.ticks) / raw.clockTicks, command: p.command)
        }.sorted { ($0.cpu, $0.memory, $1.pid) > ($1.cpu, $1.memory, $0.pid) }
        last = (raw, at)
        return snapshot
    }
}

public enum LinuxHealth {
    /// 시스템 화면과 같은 순서: 위험(메모리 압력 위험·CPU 90%+) → 경고(메모리 압력 경고·디스크 90%+ 는 위험, 80%+ 경고)
    /// RAID 손상은 disk.sh 처럼 공간보다 먼저 (SMART 는 root 가 필요해 보지 않는다)
    public static func judge(_ s: LinuxLiveSnapshot) -> (level: SystemHealth.Level, text: String) {
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
