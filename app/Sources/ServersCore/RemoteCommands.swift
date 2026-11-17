// 원격 명령어셋. 서버 종류(linux·windows·openwrt)별 조회·전송 보조 스크립트를 여기 한 곳에서 관리한다.

import Foundation

public enum RemoteCommands {
    public static let linuxSpec = """
    printf '%-12s %s\\n' 'HOSTNAME' "$(hostname)"
    if [[ -r /etc/os-release ]]; then
      . /etc/os-release
      printf '%-12s %s\\n' 'OS' "$PRETTY_NAME"
    fi
    printf '%-12s %s\\n' 'KERNEL' "$(uname -r)"
    printf '%-12s %s\\n' 'ARCH' "$(uname -m)"
    # 모델: 제조사|제품|가상화|컨테이너면 c (RemoteInfo.formatSpec 이 한국어로). DMI 가 없는 보드(라즈베리 파이 등)는 device-tree 모델
    vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null); product=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
    # Lenovo 는 product_name 에 기종 코드(20L5CTO1WW)를, 이름(ThinkPad T480)은 product_version 에 둔다
    [ "$vendor" = LENOVO ] && version=$(cat /sys/class/dmi/id/product_version 2>/dev/null) && [ -n "$version" ] && product="$version"
    [ -z "$product" ] && [ -r /proc/device-tree/model ] && product=$(tr -d '\\0' < /proc/device-tree/model)
    printf '%-12s %s|%s|%s|%s\\n' 'MODEL' "$vendor" "$product" "$(systemd-detect-virt 2>/dev/null)" "$(systemd-detect-virt -c -q 2>/dev/null && echo c)"
    # CPU 모델명 (ARM 가상 머신은 lscpu 가 "-" 를 준다 — 그때는 개수만)
    model=$(LC_ALL=C lscpu 2>/dev/null | sed -n 's/^Model name:[[:space:]]*//p' | head -n 1); [ "$model" = "-" ] && model=""
    threads=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc)
    if [ -n "$model" ]; then printf '%-12s %s (%s threads)\\n' 'CPU' "$model" "$threads"; else printf '%-12s %s threads\\n' 'CPU' "$threads"; fi
    printf '%-12s %s\\n' 'REBOOT' "$([ -f /var/run/reboot-required ] && echo yes || echo no)"
    # Ubuntu 의 apt-check: "전체;보안" 을 stderr 로. 패키지 목록만 보고 네트워크는 안 쓴다 (없으면 줄 없음). 하나라도 있으면 목록도 (UPDATE 줄, apt list 꼴 그대로 — 번역되지 않게 LC_ALL=C)
    if [ -x /usr/lib/update-notifier/apt-check ]; then
      counts=$(timeout 8 /usr/lib/update-notifier/apt-check 2>&1 >/dev/null | tail -n 1)
      printf '%-12s %s\\n' 'UPDATES' "$counts"
      case "$counts" in 0\\;*) ;; [1-9]*)
        LC_ALL=C timeout 8 apt list --upgradable 2>/dev/null | awk '/upgradable from/ {print "UPDATE       " $0}'
        # 지금 실제로 올라갈 패키지 (모의 실행 — 설치 안 함, root 불필요). 목록에는 있는데 여기 없으면 보류: 순차 배포(phased) 차례 전이거나 hold. 모의 실행이 실패하면 줄 없음
        sim=$(LC_ALL=C timeout 8 apt-get -s dist-upgrade 2>/dev/null) && printf '%-12s %s\\n' 'INSTALLS' "$(printf '%s\\n' "$sim" | awk '/^Inst / {printf "%s ", $2}')"
        ;; esac
    fi
    free -h | awk '/^Mem:/ {printf "%-12s %s total, %s available\\n", "MEMORY", $2, $7}'
    df -h / | awk 'NR == 2 {printf "%-12s %s total, %s used, %s available (%s)\\n", "ROOT DISK", $2, $3, $4, $5}'
    printf '%-12s %s\\n' 'UPTIME' "$(cut -d' ' -f1 /proc/uptime | cut -d. -f1)"
    """


    public static let linuxPorts = "ss -lntH 2>/dev/null | awk '{print $4}' | sort -V -u"

    /// Linux Spec 과 같은 "KEY          value" 형식 (RemoteInfo.parseSpec 이 그대로 읽는다). 메모리는 KB, 디스크는 바이트.
    public static let windowsSpec = """
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    # 함수 이름은 PowerShell 기본 별칭과 겹치면 안 된다 — 별칭이 함수보다 먼저 불린다 (예전 Gi 는 gi=Get-Item 에 가려 메모리가 비었다)
    function ToGi($kb) { "$([math]::Round($kb / 1MB, 1))Gi" }
    function ToG($bytes) { "$([math]::Round($bytes / 1GB))G" }
    Write-Output ("{0,-12} {1}" -f "HOSTNAME", $env:COMPUTERNAME)
    Write-Output ("{0,-12} {1} (build {2})" -f "OS", $os.Caption.Trim(), $os.BuildNumber)
    Write-Output ("{0,-12} {1}" -f "KERNEL", $os.Version)
    Write-Output ("{0,-12} {1}" -f "ARCH", $os.OSArchitecture)
    # Lenovo 는 Model 에 기종 코드를, 이름은 Win32_ComputerSystemProduct.Version 에 둔다
    $model = $cs.Model
    if ($cs.Manufacturer -eq "LENOVO") { $v = (Get-CimInstance Win32_ComputerSystemProduct).Version; if ($v) { $model = $v } }
    Write-Output ("{0,-12} {1}|{2}||" -f "MODEL", $cs.Manufacturer, $model)
    Write-Output ("{0,-12} {1} ({2} threads)" -f "CPU", $cpu.Name.Trim(), $cs.NumberOfLogicalProcessors)
    Write-Output ("{0,-12} {1} total, {2} available" -f "MEMORY", (ToGi $os.TotalVisibleMemorySize), (ToGi $os.FreePhysicalMemory))
    # 고정 디스크 전부 (DISK C · DISK D …) — 예전엔 C: 만 읽었다
    Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | Where-Object { $_.Size -gt 0 } | ForEach-Object {
        $used = $_.Size - $_.FreeSpace
        Write-Output ("{0,-12} {1} total, {2} used, {3} available ({4}%)" -f ("DISK " + $_.DeviceID.Substring(0, 1)), (ToG $_.Size), (ToG $used), (ToG $_.FreeSpace), [math]::Round($used * 100 / $_.Size))
    }
    # 물리 디스크 (DRIVE A · B …): 모델|MediaType(3 HDD · 4 SSD)|BusType|바이트|HealthStatus(0 정상). Get-PhysicalDisk 는 모듈을 올리느라 2초 걸려 CIM 으로 바로 읽는다
    $n = 0
    Get-CimInstance -Namespace root/Microsoft/Windows/Storage -ClassName MSFT_PhysicalDisk -ErrorAction SilentlyContinue | Sort-Object DeviceId | ForEach-Object {
        Write-Output ("{0,-12} {1}|{2}|{3}|{4}|{5}" -f ("DRIVE " + [char](65 + $n)), $_.FriendlyName, $_.MediaType, $_.BusType, $_.Size, $_.HealthStatus); $n++
    }
    # GPU (GPU A · B …): 이름|VRAM 바이트. Win32_VideoController.AdapterRAM 은 4GB 에서 잘려 드라이버가 적어 둔 64비트 값을 읽는다. PCI 장치만 (원격·가상 디스플레이 제외)
    $n = 0
    Get-ItemProperty "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Class\\{4d36e968-e325-11ce-bfc1-08002be10318}\\0*" -ErrorAction SilentlyContinue | Where-Object { $_.MatchingDeviceId -like "pci\\*" } | ForEach-Object {
        Write-Output ("{0,-12} {1}|{2}" -f ("GPU " + [char](65 + $n)), $_.DriverDesc, $_.'HardwareInformation.qwMemorySize'); $n++
    }
    # 업데이트 뒤 재부팅 대기: Windows Update · 구성 요소 서비스가 남기는 표시 키
    $reboot = (Test-Path "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\WindowsUpdate\\Auto Update\\RebootRequired") -or (Test-Path "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Component Based Servicing\\RebootPending")
    Write-Output ("{0,-12} {1}" -f "REBOOT", $(if ($reboot) { "yes" } else { "no" }))
    $up = (Get-Date) - $os.LastBootUpTime
    Write-Output ("{0,-12} {1}" -f "UPTIME", [int]$up.TotalSeconds)
    """

    /// "주소:포트|pid|프로세스 이름" (RemoteInfo.parsePorts). 프로세스 이름은 한 번에 읽어 둔다 — 줄마다 Get-Process 를 부르지 않게
    public static let windowsPorts = #"$n = @{}; Get-Process | ForEach-Object { $n[[int]$_.Id] = $_.Name }; Get-NetTCPConnection -State Listen -ErrorAction Stop | Sort-Object LocalPort, LocalAddress | ForEach-Object { "{0}:{1}|{2}|{3}" -f $_.LocalAddress, $_.LocalPort, $_.OwningProcess, $n[[int]$_.OwningProcess] }"#

    public static let windowsShutdown = "shutdown.exe /s /t 3"

    /// 깨워 줄 서버에서 실행할 명령. 인터페이스가 있으면 etherwake(OpenWrt 공유기 등 — 어느 장치로 내보낼지 정해야 함), 없으면 wakeonlan.
    public static func wakeOnLan(mac: String, iface: String? = nil) -> String {
        iface.map { "etherwake -i \($0) \(mac)" } ?? "wakeonlan \(mac)"
    }

    /// PowerShell 스크립트를 SSH 로 넘길 -EncodedCommand 형태로 (UTF-16LE base64). 인용 문제를 피한다.
    public static func powerShellCommand(_ script: String) -> String {
        let full = "[Console]::OutputEncoding = [Text.UTF8Encoding]::new(); " + script
        let data = full.data(using: .utf16LittleEndian) ?? Data()
        return "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + data.base64EncodedString()
    }

    /// ssh 로 보낼 명령 + stdin. 경로가 든 Linux 스크립트는 stdin 으로 보낸다 (command 는 "sh -s" 로 ASCII):
    /// Foundation 의 Process 가 인자의 한글을 NFD(자모 분리)로 바꿔 보내서, "/mnt/새 폴더" 가 서버에선 없는 경로가 됐다.
    /// stdin 은 쓴 바이트 그대로 간다. Windows 는 PowerShell -EncodedCommand(base64, ASCII)라 인자로 충분하다.
    public struct RemoteScript: Sendable, Equatable {
        public let command: String
        public let stdin: String?
    }

    static func linuxScript(_ body: String) -> RemoteScript { RemoteScript(command: "sh -s", stdin: body + "\n") }

    /// 로그인 홈의 절대 경로 (ssh 는 홈에서 시작한다). 출력은 parseHome 으로.
    public static func homeCommand(type: ServerType) -> String {
        switch type {
        case .linux, .openwrt: return "pwd"
        case .windows: return powerShellCommand("(Get-Location).ProviderPath")
        }
    }

    /// homeCommand 출력 → 탐색 창과 같은 SFTP 형식의 절대 경로 ("/home/me", Windows "C:\Users\me" → "/C:/Users/me"). 못 읽으면 nil.
    public static func parseHome(_ output: String, type: ServerType) -> String? {
        guard let last = output.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).last(where: { !$0.isEmpty }) else { return nil }
        switch type {
        case .linux, .openwrt:
            return last.hasPrefix("/") ? last : nil
        case .windows:
            let slashed = last.replacingOccurrences(of: "\\", with: "/")
            return slashed.range(of: #"^[A-Za-z]:/"#, options: .regularExpression) != nil ? "/" + slashed : nil
        }
    }

    /// 다운로드 전체 진행률용: 원격 원본들의 전체 크기(바이트)를 한 줄로 찍는 명령. 경로는 SFTP 와 같게 해석한다 — 상대 경로는 홈 기준.
    /// Linux: GNU find 면 파일 크기 합(폴더 항목 제외 — scp 가 받는 바이트와 같다), 아니면 du -sk×1024 (블록 단위라 조금 크게 나온다).
    /// 둘 다 링크를 따라간다 (-L) — scp -r 도 링크 대상을 받는다. Windows: PowerShell 로 파일 길이 합.
    public static func sizeCommand(paths: [String], type: ServerType) -> RemoteScript {
        switch type {
        case .linux, .openwrt:
            let args = paths.map(linuxPathArgument).joined(separator: " ")
            return linuxScript("if find /dev/null -maxdepth 0 -printf '' >/dev/null 2>&1; then find -L \(args) -type f -printf '%s\\n';"
                + " else du -skL -- \(args) | awk '{print $1*1024}'; fi 2>/dev/null"
                + " | awk '{s+=$1} END{printf \"%.0f\\n\", s}'")
        case .windows:
            return RemoteScript(command: powerShellCommand(windowsSizeScript(paths: paths)), stdin: nil)
        }
    }

    /// ~ 는 셸이 풀게 따옴표 밖에 둔다 ("~/a b" → "$HOME"/'a b'). - 로 시작하면 옵션으로 읽히지 않게 ./ 를 붙인다 (find 엔 -- 가 없다).
    static func linuxPathArgument(_ path: String) -> String {
        if path == "~" { return "\"$HOME\"" }
        if path.hasPrefix("~/") { return "\"$HOME\"/" + shellQuote(String(path.dropFirst(2))) }
        return shellQuote(path.hasPrefix("-") ? "./" + path : path)
    }

    /// PowerShell 작은따옴표 문자열. 탐색 시트가 주는 경로는 SFTP 형식("/C:/Users/…") — PowerShell 은 앞 / 를 떼야 드라이브로 읽는다
    static func windowsPathLiteral(_ path: String) -> String {
        var p = path
        if p.range(of: #"^/[A-Za-z]:"#, options: .regularExpression) != nil { p.removeFirst() }
        return "'" + p.replacingOccurrences(of: "'", with: "''") + "'"
    }

    static func windowsSizeScript(paths: [String]) -> String {
        let quoted = paths.map(windowsPathLiteral)
        return "$s = [long]0; foreach ($p in @(\(quoted.joined(separator: ", ")))) { $i = Get-Item -LiteralPath $p -Force -ErrorAction Stop; "
            + "if ($i.PSIsContainer) { $m = (Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum; "
            + "if ($m) { $s += [long]$m } } else { $s += $i.Length } }; $s"
    }

    /// 업로드 대상 폴더에 쓸 수 있는지. 출력 한 줄: writable | readonly | missing. 빈 경로 = 홈 (ssh 는 홈에서 시작한다).
    /// Linux: test -w (그룹·root 판단은 서버가). Windows: 권한 표시가 없어 빈 임시 파일을 만들었다 바로 지워 본다.
    public static func writableCommand(path: String, type: ServerType) -> RemoteScript {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        switch type {
        case .linux, .openwrt:
            let p = trimmed.isEmpty ? "." : linuxPathArgument(trimmed)
            return linuxScript("if [ -d \(p) ]; then if [ -w \(p) ]; then echo writable; else echo readonly; fi; else echo missing; fi")
        case .windows:
            return RemoteScript(command: powerShellCommand(windowsWritableScript(path: trimmed)), stdin: nil)
        }
    }

    static func windowsWritableScript(path: String) -> String {
        // ~ 는 PowerShell -LiteralPath 가 풀지 않는다 — scp 처럼 홈 기준 상대 경로로 ("~" → 홈, "~/x" → "x")
        var relative = path
        if relative == "~" { relative = "" } else if relative.hasPrefix("~/") { relative = String(relative.dropFirst(2)) }
        let p = relative.isEmpty ? "'.'" : windowsPathLiteral(relative)
        // 판정은 쓰기 성공 여부로만. 지우기는 그 뒤에 따로 (지우기가 막힌 폴더라도 쓸 수는 있다)
        return "$p = \(p); if (-not (Test-Path -LiteralPath $p -PathType Container)) { 'missing' } else { "
            + "$f = Join-Path (Resolve-Path -LiteralPath $p).ProviderPath ('.nexus-write-test-' + [guid]::NewGuid()); "
            + "try { [IO.File]::WriteAllText($f, '') } catch { 'readonly'; return }; 'writable'; "
            + "Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }"
    }

    public enum WriteAccess: String, Sendable { case writable, readonly, missing }

    /// writableCommand 출력 → 결과. 못 읽으면 nil (모름 — 막지 않는다).
    public static func parseWriteAccess(_ output: String) -> WriteAccess? {
        let last = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
        return last.flatMap(WriteAccess.init(rawValue:))
    }

    /// sizeCommand 출력 → 바이트. 0 이거나 못 읽으면 nil (전체 진행률 없이 파일별로 보인다).
    public static func parseSize(_ output: String) -> Int64? {
        let last = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
        guard let last, let value = Int64(last), value > 0 else { return nil }
        return value
    }

    public enum Query: String, CaseIterable, Sendable {
        /// live: 한 번 가져오는 조회가 아니라 그 탭을 보는 동안 계속 읽는다 (LinuxLive · 앱의 ServerLiveMonitor)
        /// network 는 linux·OpenWrt·Windows, firewall · clients · wireguard 는 OpenWrt 만 (OpenWrt)
        /// schedule: systemd 타이머 · cron (linux 만)
        case spec, network, firewall, clients, wireguard, services, ports, schedule, live
        public var title: String { self == .wireguard ? "WireGuard" : rawValue.capitalized }
    }

    /// 서버 종류별 조회 명령. stdin 이 있으면 command(`bash -s` · `sh -s`)에 넘긴다. 지원하지 않으면 nil.
    public static func query(_ query: Query, for type: ServerType) -> (command: String, stdin: String?)? {
        switch (type, query) {
        case (.linux, .spec): return ("bash -s", linuxSpec)
        case (.linux, .services): return ("sh -s", ServicesScript.linux)   // 실패·실행 중·컨테이너 (ServicesReport)
        case (.linux, .ports): return (linuxPorts, nil)
        case (.linux, .live), (.openwrt, .live): return ("sh -s", LinuxLive.script)
        case (.windows, .live): return (powerShellCommand(WindowsLive.script), nil)
        case (.windows, .network): return (powerShellCommand(WindowsNetwork.script), nil)
        case (.windows, .services): return (powerShellCommand(ServicesScript.windows), nil)
        case (.windows, .ports): return (powerShellCommand(windowsPorts), nil)
        case (.windows, .spec): return (powerShellCommand(windowsSpec), nil)
        case (.openwrt, .spec): return ("sh -s", OpenWrt.specScript)
        case (.openwrt, .network): return ("sh -s", OpenWrt.networkScript)
        case (.openwrt, .firewall): return ("sh -s", OpenWrt.firewallScript)
        case (.openwrt, .clients): return ("sh -s", OpenWrt.clientsScript)
        case (.openwrt, .wireguard): return ("sh -s", OpenWrt.wireguardScript)
        case (.openwrt, .services): return ("sh -s", OpenWrt.servicesScript)
        case (.openwrt, .ports): return (OpenWrt.portsCommand, nil)
        case (.linux, .network): return ("sh -s", LinuxInfoScripts.network)
        case (.linux, .schedule): return ("sh -s", LinuxInfoScripts.schedule)
        // firewall · clients · wireguard 는 OpenWrt 만, schedule 은 linux 만
        case (.linux, .firewall), (.linux, .clients), (.linux, .wireguard),
             (.windows, .firewall), (.windows, .clients), (.windows, .wireguard), (.windows, .schedule), (.openwrt, .schedule): return nil
        }
    }

    /// Windows 출력 정리: CRLF, 탭, 제어문자, 비대화형 PowerShell 의 CLIXML 진행 메시지 제거.
    public static func cleanOutput(_ text: String, type: ServerType) -> [String] {
        text.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            var line = String(raw).replacingOccurrences(of: "\t", with: "    ")
            line.removeAll { $0.asciiValue.map { $0 < 32 } ?? false }
            if type == .windows, line.hasPrefix("#< CLIXML") || line.hasPrefix("<Objs ") { return nil }
            return line
        }
    }
}

/// 원격 스크립트 출력의 구역: "@이름"(대문자·숫자) 줄부터 다음 머리줄까지, "@END" 에서 끝. Linux Live · OpenWrt 공용.
public enum ScriptSections {
    /// @END 가 없으면(출력이 중간에 끊김) nil. dropEmpty: 빈 줄을 뺀다 (OpenWrt 는 JSON 을 그대로 잇느라 남긴다).
    public static func parse(_ text: String, dropEmpty: Bool) -> [String: [String]]? {
        var result: [String: [String]] = [:]
        var current: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.count > 1, line.hasPrefix("@"), line.dropFirst().allSatisfy({ $0.isUppercase || $0.isNumber }) {
                let name = String(line.dropFirst())
                if name == "END" { return result }
                current = name
                result[name] = result[name] ?? []
            } else if let current, !(dropEmpty && line.isEmpty) {
                result[current, default: []].append(line)
            }
        }
        return nil
    }
}
