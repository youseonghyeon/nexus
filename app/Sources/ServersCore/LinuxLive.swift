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

public struct LinuxRaw: Sendable, Equatable {
    public var clockTicks: Double = 100
    public var pageSize: UInt64 = 4096
    public var model: String?
    public var uptime: Double?
    /// 물리 코어 수 (x86 만 — /proc/cpuinfo 에 core id 가 없으면 nil). cores 는 논리 프로세서
    public var physicalCores: Int?
    public var cpu: LiveCPUTicks?
    public var cores: [LiveCPUTicks] = []
    public var load: [Double] = []
    /// kB
    public var memory: [String: UInt64] = [:]
    public var psiSome: Double?
    public var psiFull: Double?
    public var disks: [String: DiskCounters] = [:]
    public var volumes: [LiveVolume] = []
    /// °C
    public var temperatures: [Double] = []
    public var processes: [LiveProcessSample] = []
    /// 통째 디스크의 모델·크기·회전(HDD) — /sys/block (disk.sh 는 lsblk, 같은 값)
    public var diskInfo: [String: LiveDiskInfo] = [:]
    public var raids: [LinuxRAID] = []
    /// 코어별 현재 클럭 kHz (stats.sh)
    public var frequencies: [Double] = []
    /// 부팅 뒤 열 스로틀 횟수 합 (x86 만, stats.sh)
    public var throttleEvents: Int?
    /// /sys/class/net (net.sh 와 같은 출처). 스크립트가 물리 + VPN·본딩만 보낸다 (LiveInterface.shown 과 같은 규칙)
    public var interfaces: [LiveInterface] = []
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
            let ticks = LiveCPUTicks(fields.dropFirst().prefix(8).compactMap { UInt64($0) })
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
            raw.diskInfo[name] = LiveDiskInfo(rotational: parts[2] == "1" ? true : (parts[2] == "0" ? false : nil),
                                               size: (UInt64(parts[3]) ?? 0) * 512, model: model.isEmpty ? nil : model)
        }
        raw.raids = LinuxRAID.parse(s["MD"] ?? [])
        raw.frequencies = (s["FREQ"] ?? []).compactMap { Double($0) }.filter { $0 > 0 }
        let throttles = (s["THROTTLE"] ?? []).compactMap { Int($0) }
        raw.throttleEvents = throttles.isEmpty ? nil : throttles.reduce(0, +)
        for line in s["NET"] ?? [] {
            let f = line.split(separator: " ")
            guard f.count == 6, let rx = UInt64(f[4]), let tx = UInt64(f[5]) else { continue }
            raw.interfaces.append(LiveInterface(name: String(f[0]), physical: f[1] == "1", state: String(f[2]),
                                                speedMbps: Int(f[3]).flatMap(LiveInterface.knownSpeed), rxBytes: rx, txBytes: tx))
        }
        for line in s["DISK"] ?? [] {
            let f = line.split(separator: " ")
            guard f.count >= 10, wholeDisks.contains(String(f[2])),
                  let reads = UInt64(f[3]), let sectorsRead = UInt64(f[5]), let writes = UInt64(f[7]), let sectorsWritten = UInt64(f[9]) else { continue }
            raw.disks[String(f[2])] = DiskCounters(bytesRead: sectorsRead * 512, bytesWritten: sectorsWritten * 512, opsRead: reads, opsWritten: writes)
        }
        for line in (s["DF"] ?? []).dropFirst() {   // 머리글 줄
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 7, let size = UInt64(f[2]), let used = UInt64(f[3]), let available = UInt64(f[4]) else { continue }
            let mount = f[6...].joined(separator: " ")
            let type = String(f[1])
            if hiddenFileSystems.contains(type) || (type == "overlay" && mount != "/") { continue }
            if mount == "/boot/efi" || hiddenMountPrefixes.contains(where: { mount.hasPrefix($0) }) || f[0].contains("[") { continue }
            if raw.volumes.contains(where: { $0.mountPoint == mount }) { continue }
            raw.volumes.append(LiveVolume(device: String(f[0]), fsType: type, size: size * 1024, used: used * 1024, available: available * 1024, mountPoint: mount))
        }
        raw.temperatures = (s["TEMP"] ?? []).compactMap { Double($0) }.map { $0 / 1000 }.filter { $0 > 0 && $0 <= 150 }
        for line in s["PROC"] ?? [] {
            let f = line.split(separator: "\t", maxSplits: 6, omittingEmptySubsequences: false)
            guard f.count == 7, let pid = Int(f[0]), let ticks = UInt64(f[2]) else { continue }
            raw.processes.append(LiveProcessSample(pid: pid, state: String(f[1]), ticks: ticks, threads: Int(f[3]) ?? 1,
                                                   memory: (UInt64(f[4]) ?? 0) * raw.pageSize, startTime: UInt64(f[5]) ?? 0, command: String(f[6])))
        }
        return raw
    }
}

// MARK: 계산

/// 직전 표본과의 차이로 CPU·디스크 속도·프로세스 %CPU 를 낸다. 첫 표본은 차이가 없어 그 값들이 빈다.
public struct LinuxLiveSampler: Sendable {
    private var last: (raw: LinuxRaw, at: Date)?
    public init() {}

    public mutating func step(_ raw: LinuxRaw, at: Date) -> LiveSnapshot {
        var snapshot = LiveSnapshot(at: at)
        snapshot.model = raw.model
        snapshot.cores = raw.cores.count
        snapshot.physicalCores = raw.physicalCores
        snapshot.uptime = raw.uptime
        snapshot.load = raw.load
        snapshot.memory = LiveMemory.from(raw.memory)
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

        var jiffies: Double = 0
        if let last {
            if let a = last.raw.cpu, let b = raw.cpu {
                snapshot.cpu = LiveCPUUsage.between(a, b, oldCores: last.raw.cores, newCores: raw.cores)
                jiffies = b.total > a.total ? Double(b.total - a.total) : 0
            }
            // 서버 쪽 시간(uptime 차이)으로 — Mac 이 응답을 받은 시각은 ssh 왕복 편차가 섞인다
            // 한쪽 uptime 만 못 읽었으면 차이가 uptime 전체가 된다 — 둘 다 있을 때만
            let serverSeconds = raw.uptime.flatMap { now in last.raw.uptime.map { now - $0 } } ?? 0
            let seconds = serverSeconds > 0 ? serverSeconds : at.timeIntervalSince(last.at)
            if let rates = DiskIO.rates(last.raw.disks, raw.disks, seconds: seconds) {
                snapshot.disk = rates.total
                snapshot.perDisk = rates.perDisk
            }
            if seconds > 0 {
                // 보이는 장치만 싣고 합계는 물리만 — 브리지·veth 는 같은 트래픽을 한 번 더 센다
                let network = LiveInterfaceRate.rates(from: last.raw.interfaces, to: raw.interfaces.filter(\.shown), seconds: seconds, counted: \.physical)
                snapshot.interfaces = network.interfaces
                snapshot.networkTotal = network.total
            }
        }
        // stats.sh: %CPU = Δticks × 코어 수 / Δ(전체 jiffies) × 100. pid 재사용은 starttime 으로 가른다.
        let cores = Double(max(1, raw.cores.count))
        snapshot.processes = LiveProcessRow.rows(raw.processes, since: last?.raw.processes ?? [], ticksPerSecond: raw.clockTicks,
                                                 percent: jiffies > 0 ? { $0 * cores / jiffies * 100 } : nil)
        last = (raw, at)
        return snapshot
    }
}
