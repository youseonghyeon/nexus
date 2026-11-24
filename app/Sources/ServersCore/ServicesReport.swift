// 원격 정보의 Services 탭: 정해 둔 서비스 대신 서버가 실제로 돌리는 것을 보여 준다.
//   실패한 서비스(맨 위 — 죽었다 살아나기를 되풀이하는 auto-restart 포함) · 실행 중인 서비스 전체(재시작 횟수·가동 시간, 기본 서비스는 접음) · 컨테이너(docker 는 compose 프로젝트별 · 내놓은 포트, k3s 파드).
//   리눅스는 서비스 줄을 누르면 최근 로그(journalctl). Windows 는 로그 없음.
// 스크립트 출력은 "## 구역" 머리 + systemctl show 꼴 "키=값" 블록(빈 줄로 나눔) + 컨테이너 "C|…"·"P|…" 줄. 탭은 cleanOutput 이 공백으로 바꾸므로 쓰지 않는다.
// 리눅스는 실패·재시작 대기·실행 중 유닛을 한 번의 show 로 읽고(## UNITS) SubState 로 나눈다 — 목록과 값을 따로 읽으면 그 사이 상태가 바뀌어
// 재시작을 되풀이하는 서비스가 두 구역에 같이 뜬다. Windows 는 ## FAILED · ## RUNNING 으로 나눠 보낸다.

import Foundation

public struct ServiceUnit: Sendable, Equatable, Identifiable {
    public var id: String { name }
    /// ".service" 를 뗀 이름 (Windows 는 서비스 이름)
    public let name: String
    public let description: String
    /// 켜진 지 (초). 모르면 nil
    public let uptime: TimeInterval?
    public let restarts: Int?
    /// 실패: 상태(SubState)·결과(Result)와 바뀐 지 (초)
    public let state: String?
    public let result: String?
    public let changedAgo: TimeInterval?
    /// OS 기본 서비스 (목록에서 접어 둔다)
    public let basic: Bool
    /// 유닛 파일이 없다 (패키지를 지웠는데 systemd 가 실패 기록만 쥐고 있음 — reset-failed 로 지워진다)
    public var removed = false
}

public struct ContainerItem: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case docker, pod }
    public enum Tone: Sendable { case good, warn, bad, muted }
    public var id: String { "\(kind.rawValue)|\(name)" }
    public let kind: Kind
    public let name: String
    /// "Up 3 days (healthy)" · "Exited (1) 2 hours ago" · "Running" · "CrashLoopBackOff"
    public let status: String
    /// docker 는 이미지 (파드는 빈 값)
    public let detail: String
    /// 파드 나이 (kubectl 꼴 "3d1h") — docker 는 상태 글에 들어 있다
    public let age: String?
    /// 파드: 준비 "1/1" · 재시작 횟수
    public let ready: String?
    public let restarts: Int?
    /// docker: 호스트로 내놓은 포트 (docker ps 의 Ports 원문 — 화면 꼴은 ServicesFormat.dockerPortList · dockerPortsShown) · compose 프로젝트 (없으면 nil)
    public let ports: String
    public let project: String?

    public init(kind: Kind, name: String, status: String, detail: String = "", age: String? = nil, ready: String? = nil, restarts: Int? = nil,
                ports: String = "", project: String? = nil) {
        self.kind = kind; self.name = name; self.status = status; self.detail = detail; self.age = age; self.ready = ready; self.restarts = restarts
        self.ports = ports; self.project = project
    }

    /// 파드 네임스페이스 ("app/calapp-…" 의 app). docker 는 nil
    public var namespace: String? {
        guard kind == .pod, let slash = name.firstIndex(of: "/") else { return nil }
        return String(name[..<slash])
    }

    /// 화면용 이름: 네임스페이스를 떼고, 쿠버네티스가 붙인 꼬리(해시)를 따로 — ("calapp-server", "-f6cdff6d5-mt2v2")
    public var displayName: (base: String, hash: String) {
        let plain = kind == .pod ? String(name[(name.firstIndex(of: "/").map { name.index(after: $0) } ?? name.startIndex)...]) : name
        guard kind == .pod else { return (plain, "") }
        return PodName.split(plain)
    }

    /// 끝난 것 (접어 둔다): 파드 Completed·Succeeded, docker 정상 종료(Exited (0))·만들기만 한 것
    public var finished: Bool {
        let s = status.lowercased()
        switch kind {
        case .pod: return s == "completed" || s == "succeeded"
        case .docker: return s.hasPrefix("exited (0)") || s.hasPrefix("created")
        }
    }

    /// 상태 글을 따로 적을지: 파드 Running 은 점으로 충분하다
    public var statusWorthShowing: Bool { !(kind == .pod && status == "Running") }

    /// 준비 "0/1" 처럼 앞 숫자가 작다 (readiness 실패)
    public var notReady: Bool {
        guard let ready, let slash = ready.firstIndex(of: "/"), let have = Int(ready[..<slash]),
              let want = Int(ready[ready.index(after: slash)...]) else { return false }
        return have < want
    }

    /// 누르면 복사할 이름: 파드는 네임스페이스를 뗀 이름 (kubectl 은 "ns/이름" 을 종류/이름으로 읽는다)
    public var copyName: String {
        guard kind == .pod, let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }

    public var tone: Tone {
        let s = status.lowercased()
        switch kind {
        case .docker:
            if s.hasPrefix("up") { return s.contains("unhealthy") ? .bad : (s.contains("starting") ? .warn : .good) }
            if s.hasPrefix("restarting") || s.hasPrefix("dead") { return .bad }
            if s.hasPrefix("exited (0)") || s.hasPrefix("created") { return .muted }
            if s.hasPrefix("exited") { return .bad }
            return .muted
        case .pod:
            if s == "running" { return notReady ? .warn : .good }   // 떠 있어도 readiness 실패(0/1)면 노랑
            if s == "completed" || s == "succeeded" { return .muted }
            // 초기화 진행 중(Init:0/1)·배포 중(Terminating)은 노랑, Init:CrashLoopBackOff 같은 초기화 실패는 빨강
            if s == "pending" || s == "terminating" || s.hasPrefix("containercreating") || s.hasPrefix("podinitializing")
                || s.range(of: #"^init:\d+/\d+$"#, options: .regularExpression) != nil { return .warn }
            return .bad   // CrashLoopBackOff · Error · ImagePullBackOff · OOMKilled …
        }
    }
}

/// 쿠버네티스 파드 이름의 자동 꼬리. 디플로이먼트 "이름-<RS 해시>-<5글자>", 데몬셋 "이름-<5글자>", 크론잡 "이름-<시각 숫자>-<5글자>".
/// 꼬리 글자는 모음 없는 영숫자(k8s SafeEncodeString)라 "nginx-proxy" 같은 사람이 지은 낱말은 떼지 않는다. 스테이트풀셋 "-0" 은 그대로.
public enum PodName {
    static let safe = Set("bcdfghjklmnpqrstvwxz2456789")

    public static func split(_ name: String) -> (base: String, hash: String) {
        var segments = name.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        var tail: [String] = []
        if segments.count > 1, let last = segments.last, last.count == 5, last.allSatisfy(safe.contains) {
            tail.insert(segments.removeLast(), at: 0)
            if segments.count > 1, let prev = segments.last,
               (6...10).contains(prev.count) && prev.allSatisfy(safe.contains) || (prev.count >= 6 && prev.allSatisfy(\.isNumber)) {
                tail.insert(segments.removeLast(), at: 0)
            }
        }
        return (segments.joined(separator: "-"), tail.isEmpty ? "" : "-" + tail.joined(separator: "-"))
    }
}

public struct ServicesReport: Sendable, Equatable {
    public enum ContainerSource: Sendable, Equatable {
        case ok
        /// 권한이 없어 못 읽음 (docker 그룹 아님 · kubeconfig 못 읽음 — sudo 는 쓰지 않는다)
        case denied
        /// 명령은 있는데 데몬이 꺼져 있음 (Windows Docker Desktop)
        case off
    }
    public var failed: [ServiceUnit] = []
    public var running: [ServiceUnit] = []
    public var containers: [ContainerItem] = []
    /// "docker"·"k3s" → 읽은 결과. 명령이 없는 서버는 들어 있지 않다.
    public var sources: [String: ContainerSource] = [:]
    /// systemctl 이 없는 리눅스 (서비스 목록을 못 만든다)
    public var noSystemd = false
    /// 너무 많아 앞 200개만 보낸 출처 → 전체 개수
    public var truncated: [String: Int] = [:]

    public var mainRunning: [ServiceUnit] { running.filter { !$0.basic } }
    public var basicRunning: [ServiceUnit] { running.filter(\.basic) }
}

/// docker 컨테이너를 compose 프로젝트별로 묶는다 (파드의 네임스페이스처럼). 프로젝트는 처음 나온 순서, 프로젝트 없는 것은 맨 뒤 "기타".
/// compose 를 하나도 안 쓰는 서버는 묶음 하나 · 제목 없음 (지금까지처럼 한 줄기).
public struct ContainerGroup: Sendable, Equatable, Identifiable {
    public var id: String { title ?? "" }
    /// 묶음 머리에 적을 이름. nil 이면 머리를 두지 않는다
    public let title: String?
    public let items: [ContainerItem]

    public static let otherTitle = "기타"

    public static func byProject(_ items: [ContainerItem]) -> [ContainerGroup] {
        guard items.contains(where: { $0.project != nil }) else { return items.isEmpty ? [] : [ContainerGroup(title: nil, items: items)] }
        var order: [String] = []
        for project in items.compactMap(\.project) where !order.contains(project) { order.append(project) }
        var groups = order.map { name in ContainerGroup(title: name, items: items.filter { $0.project == name }) }
        let loose = items.filter { $0.project == nil }
        if !loose.isEmpty { groups.append(ContainerGroup(title: order.contains(otherTitle) ? otherTitle + " (compose 밖)" : otherTitle, items: loose)) }
        return groups
    }
}

public enum ServicesScript {
    /// 리눅스 (`sh -s` 로 stdin). 시각은 부팅 후 µs(…Monotonic)로 받아 /proc/uptime 과 빼서 경과로 — systemd 버전마다 시각 글꼴이 달라서.
    /// docker·k3s 는 그 계정의 권한으로만 — 권한 거부면 denied. sudo 는 쓰지 않는다 (2026-11-24).
    public static let linux = #"""
    export LC_ALL=C
    echo "UPTIME=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
    # 멈춘 docker·k3s 가 조회 전체(20초 제한)를 잡아먹지 않게 5초
    T=""; command -v timeout >/dev/null 2>&1 && T="timeout 5"
    echo "## UNITS"
    if command -v systemctl >/dev/null 2>&1; then
      units=$(systemctl list-units --type=service --state=failed,auto-restart,running --no-legend --plain --no-pager 2>/dev/null | awk '{print $1}')
      [ -n "$units" ] && systemctl show --no-pager -p Id,Description,LoadState,ActiveState,SubState,Result,NRestarts,ActiveEnterTimestampMonotonic,StateChangeTimestampMonotonic $units 2>/dev/null
    else
      echo "SYSTEMD=off"
    fi
    echo "## CONTAINERS"
    # 그 계정의 권한으로만 — 권한 거부면 denied. 권한 말고 다른 실패(데몬 꺼짐·설정 없음)는 off.
    # 오류 문구는 mktemp 파일로 받는다 (/tmp 의 짐작되는 이름은 다른 사용자가 미리 만들어 둘 수 있다). mktemp 가 없으면 버리고 off 로 본다.
    E=$(mktemp 2>/dev/null) || E=""
    if command -v docker >/dev/null 2>&1; then
      # 포트·compose 프로젝트는 뒤에 붙인다 (없으면 빈 칸) — 이름|상태|이미지|포트|프로젝트
      fmt='{{.Names}}|{{.Status}}|{{.Image}}|{{.Ports}}|{{.Label "com.docker.compose.project"}}'
      if out=$($T docker ps -a --format "$fmt" 2>"${E:-/dev/null}"); then state=ok
      elif [ -n "$E" ] && grep -qi "permission denied" "$E" 2>/dev/null; then state=denied
      else state=off; fi
      echo "SOURCE|docker|$state"
      if [ "$state" = ok ] && [ -n "$out" ]; then
        n=$(printf '%s\n' "$out" | wc -l); [ "$n" -gt 200 ] && echo "MORE|docker|$n"
        printf '%s\n' "$out" | head -n 200 | sed 's/^/C|/'
      fi
    fi
    if command -v k3s >/dev/null 2>&1; then
      if out=$($T k3s kubectl get pods -A --no-headers --request-timeout=5s 2>"${E:-/dev/null}"); then state=ok
      elif [ -n "$E" ] && grep -qi "permission denied" "$E" 2>/dev/null; then
        # 기본 설정 파일을 못 읽는 계정이면 그 계정의 ~/.kube/config 로 한 번 (파드 줄 PodInspect 와 같은 길) —
        # 터미널의 KUBECONFIG 는 ~/.zshrc · ~/.bashrc 에 있어 ssh 로 보낸 스크립트에는 없다
        if [ -r "$HOME/.kube/config" ] && out=$(KUBECONFIG="$HOME/.kube/config" $T k3s kubectl get pods -A --no-headers --request-timeout=5s 2>/dev/null); then state=ok
        else state=denied; fi
      else state=off; fi
      echo "SOURCE|k3s|$state"
      if [ "$state" = ok ] && [ -n "$out" ]; then
        n=$(printf '%s\n' "$out" | wc -l); [ "$n" -gt 200 ] && echo "MORE|k3s|$n"
        printf '%s\n' "$out" | head -n 200 | awk '{print "P|" $1 "/" $2 "|" $4 "|" $3 "|" $5 "|" $NF}'
      fi
    fi
    [ -n "$E" ] && rm -f "$E"
    echo "## END"
    """#

    /// Windows (PowerShell). 실패 = 자동 시작인데 오류 코드로 멈춘 것 (1077 = 부팅 뒤 시작한 적 없음 — 지연·트리거 시작이라 실패 아님).
    /// 실행 중은 실행 파일 경로를 같이 보내 Windows 기본 서비스를 가린다.
    public static let windows = #"""
    Write-Output "## FAILED"
    Get-CimInstance Win32_Service -Filter "StartMode='Auto' AND State<>'Running'" -ErrorAction SilentlyContinue |
      Where-Object { $_.ExitCode -ne 0 -and $_.ExitCode -ne 1077 } | ForEach-Object {
        "Id=$($_.Name)"; "Description=$($_.DisplayName)"; "SubState=$($_.State)"; "Result=exit-code $($_.ExitCode)"; "" }
    Write-Output "## RUNNING"
    Get-CimInstance Win32_Service -Filter "State='Running'" -ErrorAction SilentlyContinue | ForEach-Object {
        "Id=$($_.Name)"; "Description=$($_.DisplayName)"; "Path=$($_.PathName)"; "" }
    Write-Output "## CONTAINERS"
    if (Get-Command docker -ErrorAction SilentlyContinue) {
      $out = docker ps -a --format '{{.Names}}|{{.Status}}|{{.Image}}' 2>$null
      if ($LASTEXITCODE -eq 0) {
        "SOURCE|docker|ok"
        if (@($out).Count -gt 200) { "MORE|docker|$(@($out).Count)" }
        $out | Select-Object -First 200 | ForEach-Object { "C|$_" }
      } else { "SOURCE|docker|off" }
    }
    Write-Output "## END"
    """#
}

public enum ServicesParser {
    /// 리눅스 기본 서비스 (접어 두는 것). 앞부분이 맞으면 기본.
    static let linuxBasicPrefixes = [
        "systemd-", "getty@", "serial-getty@", "user@", "dbus", "polkit", "rsyslog", "cron", "atd", "ModemManager",
        "networkd-dispatcher", "NetworkManager", "wpa_supplicant", "udisks2", "unattended-upgrades", "snapd", "multipathd",
        "irqbalance", "accounts-daemon", "packagekit", "upower", "thermald", "lvm2-", "avahi-daemon", "cups", "colord",
        "rtkit-daemon", "switcheroo-control", "power-profiles-daemon", "fwupd", "qemu-guest-agent", "open-vm-tools",
        "vgauth", "chrony", "ntp", "haveged", "uuidd", "smartmontools", "acpid", "kerneloops", "whoopsie", "bluetooth",
        "gdm", "lightdm", "sssd", "nscd", "iscsid", "open-iscsi", "mdmonitor", "auditd", "rngd", "tuned",
        "firewalld", "gssproxy", "dnsmasq",
    ]

    /// 스크립트 출력 → 보고서. 구역 머리가 하나도 없으면 nil (예전 형식·엉뚱한 출력).
    public static func parse(_ lines: [String], type: ServerType) -> ServicesReport? {
        guard lines.contains(where: { $0.hasPrefix("## ") }) else { return nil }
        var report = ServicesReport()
        var uptime: TimeInterval?
        var section = ""
        var block: [String: String] = [:]

        func flush() {
            defer { block = [:] }
            guard let id = block["Id"], !id.isEmpty else { return }
            let name = id.hasSuffix(".service") ? String(id.dropLast(".service".count)) : id
            func since(_ key: String) -> TimeInterval? {
                guard let uptime, let raw = block[key], let micros = Double(raw), micros > 0 else { return nil }
                let elapsed = uptime - micros / 1_000_000
                return elapsed >= 0 ? elapsed : nil   // 컨테이너(lxcfs)처럼 /proc/uptime 이 짧으면 모름

            }
            var unit = ServiceUnit(name: name, description: block["Description"] ?? "",
                                   uptime: since("ActiveEnterTimestampMonotonic"),
                                   restarts: block["NRestarts"].flatMap(Int.init),
                                   state: block["SubState"], result: block["Result"], changedAgo: since("StateChangeTimestampMonotonic"),
                                   basic: isBasic(name: name, path: block["Path"], type: type))
            unit.removed = block["LoadState"] == "not-found"
            switch section {
            case "FAILED": report.failed.append(unit)
            case "RUNNING": report.running.append(unit)
            case "UNITS":
                // 한 번에 읽은 값으로 나눈다: 실패·재시작 대기는 실패, 실행 중은 실행 중, 그 사이 바뀐 것(멈춤 등)은 뺀다
                if block["ActiveState"] == "failed" || unit.state == "failed" || unit.state == "auto-restart" { report.failed.append(unit) }
                else if unit.state == "running" { report.running.append(unit) }
            default: break
            }
        }

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                flush()
                section = String(line.dropFirst(3))
                continue
            }
            if line.isEmpty { flush(); continue }
            if section.isEmpty, line.hasPrefix("UPTIME=") { uptime = Double(line.dropFirst("UPTIME=".count)); continue }
            if line == "SYSTEMD=off" { report.noSystemd = true; continue }
            if section == "CONTAINERS" {
                let parts = line.split(separator: "|", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
                switch parts.first {
                case "MORE" where parts.count >= 3:
                    report.truncated[parts[1]] = Int(parts[2])
                case "SOURCE" where parts.count >= 3:
                    report.sources[parts[1]] = parts[2] == "ok" ? .ok : (parts[2] == "off" ? .off : .denied)
                case "C" where parts.count >= 3:   // C|이름|상태|이미지[|포트|compose 프로젝트] — 뒤 둘은 리눅스만 (Windows 는 이미지까지)
                    report.containers.append(ContainerItem(kind: .docker, name: parts[1], status: parts[2],
                                                           detail: parts.count > 3 ? parts[3] : "", age: nil,
                                                           ports: parts.count > 4 ? parts[4] : "",
                                                           project: parts.count > 5 && !parts[5].isEmpty ? parts[5] : nil))
                case "P" where parts.count >= 6:   // P|ns/이름|상태|준비|재시작|나이
                    report.containers.append(ContainerItem(kind: .pod, name: parts[1], status: parts[2], age: parts[5],
                                                           ready: parts[3], restarts: Int(parts[4])))
                default: break
                }
                continue
            }
            if section == "FAILED" || section == "RUNNING" || section == "UNITS", let eq = line.firstIndex(of: "=") {
                let key = String(line[..<eq])
                // 같은 키가 다시 나오면 빈 줄 없이 다음 블록이 시작된 것
                if block[key] != nil { flush() }
                block[key] = String(line[line.index(after: eq)...])
            }
        }
        flush()
        // 같은 이름이 두 번 나오면(Windows 가 실패·실행 중을 따로 읽는 사이 바뀜) 실패 쪽만 둔다
        let failedNames = Set(report.failed.map(\.name))
        report.running.removeAll { failedNames.contains($0.name) }
        report.running.sort { ($0.basic ? 1 : 0, $0.name.lowercased()) < ($1.basic ? 1 : 0, $1.name.lowercased()) }
        return report
    }

    static func isBasic(name: String, path: String?, type: ServerType) -> Bool {
        switch type {
        case .linux:
            return linuxBasicPrefixes.contains { name.hasPrefix($0) }
        case .windows:
            // Windows 폴더 안 실행 파일이면 기본 — OpenSSH(sshd)는 System32 안에 있어도 사용자가 켠 것
            guard let path = path?.lowercased() else { return false }
            if path.contains("openssh") { return false }
            // Windows 폴더 · Microsoft 제품(Defender·Edge 업데이트·Office ClickToRun) 폴더
            return path.contains("\\windows\\") || path.contains("\\microsoft") || path.contains("\\windows defender")
        case .openwrt:
            return false   // OpenWrt 는 이 보고서를 쓰지 않는다 (OpenWrtServices)
        }
    }
}

public enum ServiceLog {
    /// 유닛 이름은 systemd 가 허용하는 글자만 (명령에 그대로 넣으므로)
    public static func isValidUnit(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 256 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "@._:-\\".contains($0)) }
    }

    /// 최근 로그 50줄. 그 계정의 권한으로만 (adm·systemd-journal 그룹이면 보인다) — sudo 는 쓰지 않는다.
    public static func command(unit: String) -> String? {
        guard isValidUnit(unit) else { return nil }
        let u = unit.hasSuffix(".service") ? unit : unit + ".service"
        let args = "-u '\(u)' -n 50 --no-pager -o short-iso"
        return "journalctl \(args) 2>&1"
    }

    /// docker 컨테이너 이름: 영숫자로 시작, 영숫자·_·.·- 만 (docker 가 허용하는 글자 — 명령에 그대로 넣으므로)
    public static func isValidContainer(_ name: String) -> Bool {
        guard let first = name.first, first.isASCII, first.isLetter || first.isNumber, name.count <= 255 else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }
    }

    /// docker 컨테이너의 최근 로그 50줄 (stdout·stderr 를 섞어 시간 순서대로). 그 계정의 권한으로만 — sudo 는 쓰지 않는다.
    /// 안 되면 docker 의 오류 글(권한 없음 등)을 그대로 보인다. 멈춘 docker 가 붙잡지 않게 8초.
    public static func dockerCommand(container: String) -> String? {
        guard isValidContainer(container) else { return nil }
        return #"T=""; command -v timeout >/dev/null 2>&1 && T="timeout 8"; "#
            + "$T docker logs --tail 50 '\(container)' 2>&1"
    }

    /// 터미널 색·커서 제어 글(ESC [ … 글자)을 뺀다 — 컨테이너 로그는 색을 넣는 것이 많다
    public static func stripANSI(_ text: String) -> String {
        text.replacing(#/\u{1B}\[[0-9;?]*[ -\/]*[@-~]/#, with: "")
    }
}

public enum ServicesFormat {
    /// 큰 단위 둘까지: "220일" · "3일 1시간" · "1일 14시간" · "5분" · "10초"
    public static func duration(_ seconds: TimeInterval) -> String { DurationFormat.compact(seconds) }

    /// kubectl 나이 "3d1h" · "38h" · "220d" · "5m10s" · "2y45d" → 초. 못 읽으면 nil
    public static func kubeAge(_ text: String) -> TimeInterval? {
        let units: [Character: Double] = ["y": 365 * 86400, "d": 86400, "h": 3600, "m": 60, "s": 1]
        var total = 0.0, number = ""
        for ch in text {
            if ch.isNumber { number.append(ch); continue }
            guard let unit = units[ch], let n = Double(number) else { return nil }
            total += n * unit
            number = ""
        }
        return number.isEmpty && !text.isEmpty ? total : nil
    }

    /// 파드 나이를 서비스 가동 시간과 같은 꼴로 ("38h" → "1일 14시간"). 못 읽으면 원문
    public static func podAge(_ text: String?) -> String {
        guard let text else { return "" }
        return kubeAge(text).map(duration) ?? text
    }

    /// "방금" · "3시간 4분 전"
    static func ago(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "방금" : "\(duration(seconds)) 전"
    }

    /// 실행 중 줄 오른쪽: "3일 2시간 · 재시작 2" (모르는 것은 뺀다, 재시작 0 은 안 적는다)
    public static func detail(_ unit: ServiceUnit) -> String {
        [unit.uptime.map(duration), unit.restarts.flatMap { $0 > 0 ? "재시작 \($0)" : nil }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// docker 상태 글 → 가동 시간 열에 둘 글과 따로 적을 상태.
    /// 떠 있으면 가동 시간을 서비스 줄과 같은 꼴로("Up 5 days (healthy)" → "5일") — healthy 는 점이 말하므로 적지 않고, unhealthy · starting · paused 만 적는다.
    /// 떠 있지 않으면 가동 시간은 없고 상태 글 그대로("Exited (1) 2 hours ago").
    public static func dockerStatus(_ status: String) -> (uptime: String?, note: String?) {
        guard status.lowercased().hasPrefix("up ") else { return (nil, status) }
        var rest = String(status.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        var note: String?
        if rest.hasSuffix(")"), let open = rest.lastIndex(of: "(") {
            let inside = rest[rest.index(after: open)...].dropLast().lowercased()
            rest = rest[..<open].trimmingCharacters(in: .whitespaces)
            switch inside {
            case "healthy": note = nil
            case "health: starting": note = "starting"
            default: note = inside   // unhealthy · paused
            }
        }
        return (dockerDuration(rest), note)
    }

    /// docker 의 경과 글("5 days" · "About an hour" · "Less than a second")을 이 앱의 꼴로. 모르는 꼴은 원문
    static func dockerDuration(_ text: String) -> String {
        let t = text.lowercased()
        if t == "less than a second" { return "방금" }
        if t == "about a minute" { return "1분" }
        if t == "about an hour" { return "1시간" }
        let units = ["second": "초", "minute": "분", "hour": "시간", "day": "일", "week": "주", "month": "개월", "year": "년"]
        let words = t.split(separator: " ")
        guard words.count == 2, let n = Int(words[0]) else { return text }
        let word = words[1].hasSuffix("s") ? String(words[1].dropLast()) : String(words[1])
        return units[word].map { "\(n)\($0)" } ?? text
    }

    /// 컨테이너 줄에 적는 포트 하나. open 은 모든 주소(0.0.0.0 · ::)에 내놓아 바깥에서 닿는 것 — 화면에서 딱지로.
    public struct DockerPort: Sendable, Equatable {
        /// 어디에 묶였나: 모든 주소 · 루프백 · 그 밖의 특정 주소
        public enum Scope: Sendable { case open, loopback, address }
        public let text: String
        public let scope: Scope
        public var open: Bool { scope == .open }
    }

    /// docker ps 의 Ports → 호스트로 내놓은 것만 짧게: "0.0.0.0:8080->80/tcp, [::]:8080->80/tcp" → "8080→80".
    /// 호스트·컨테이너 포트가 같으면 한 번만("5432"), udp 는 "/udp". 루프백에 묶인 것은 주소 없이 번호만
    /// (줄마다 "127.0.0.1:" 이 되풀이돼 번호가 묻혔다 — 2026-11-24), 모든 주소에 내놓은 것은 open 으로 표시한다. 그 밖의 특정 주소에 묶였으면 주소를 붙인다("192.0.2.10:53").
    /// IPv4·IPv6 로 두 번 나오는 것은 하나로, 한 칸씩 이어지는 포트는 범위로("18100-18102→8100-8102"). 내놓지 않은 포트("9000/tcp")는 뺀다.
    public static func dockerPortList(_ raw: String) -> [DockerPort] {
        struct Mapping { var host: String; var from: Int; var to: Int; var count: Int; var proto: String }
        var list: [Mapping] = []
        for entry in raw.split(separator: ",") {
            let text = entry.trimmingCharacters(in: .whitespaces)
            guard let arrow = text.range(of: "->"), let slash = text.lastIndex(of: "/"), slash > arrow.upperBound else { continue }
            let left = text[..<arrow.lowerBound], right = text[arrow.upperBound..<slash]
            let proto = String(text[text.index(after: slash)...])
            guard let colon = left.lastIndex(of: ":") else { continue }
            var host = String(left[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if host == "0.0.0.0" || host == "::" || host.isEmpty { host = "" }   // 모든 주소
            if host == "::1" { host = "127.0.0.1" }                               // 루프백은 한 가지로
            func range(_ s: Substring) -> (Int, Int)? {
                let ends = s.split(separator: "-").compactMap { Int($0) }
                return ends.count == 1 ? (ends[0], ends[0]) : (ends.count == 2 && ends[1] >= ends[0] ? (ends[0], ends[1]) : nil)
            }
            guard let h = range(left[left.index(after: colon)...]), let c = range(right), h.1 - h.0 == c.1 - c.0 else { continue }
            let mapping = Mapping(host: host, from: h.0, to: c.0, count: h.1 - h.0 + 1, proto: proto)
            if list.contains(where: { $0.host == mapping.host && $0.proto == mapping.proto && $0.from <= mapping.from
                && mapping.from + mapping.count <= $0.from + $0.count && $0.to - $0.from == mapping.to - mapping.from }) { continue }   // IPv4·IPv6 겹침
            // 바로 앞 것에 한 칸 이어지면 범위로 늘린다
            if let i = list.lastIndex(where: { $0.host == mapping.host && $0.proto == mapping.proto
                && $0.from + $0.count == mapping.from && $0.to + $0.count == mapping.to }) {
                list[i].count += mapping.count
            } else {
                list.append(mapping)
            }
        }
        return list.map { m in
            func span(_ start: Int) -> String { m.count > 1 ? "\(start)-\(start + m.count - 1)" : "\(start)" }
            let ports = (m.from == m.to ? span(m.from) : span(m.from) + "→" + span(m.to)) + (m.proto == "tcp" ? "" : "/" + m.proto)
            let scope: DockerPort.Scope = m.host.isEmpty ? .open : (isLoopback(m.host) ? .loopback : .address)
            return DockerPort(text: (scope == .address ? m.host + ":" : "") + ports, scope: scope)
        }
    }

    /// 127.0.0.0/8
    private static func isLoopback(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { UInt8($0) != nil }
    }

    /// 줄에 보일 포트(앞 limit 개)와 남은 수 — 넷 이상이면 앞 셋 + "+N"
    public static func dockerPortsShown(_ raw: String, limit: Int = 3) -> (shown: [DockerPort], more: Int) {
        let all = dockerPortList(raw)
        return all.count > limit ? (Array(all.prefix(limit)), all.count - limit) : (all, 0)
    }

    /// 실패 줄 오른쪽: "exit-code · 3시간 4분 전" · 재시작을 되풀이하면 "재시작 반복 5회 · exit-code"
    public static func failure(_ unit: ServiceUnit) -> String {
        if unit.removed { return "삭제된 서비스의 실패 기록" }
        let looping = unit.state == "auto-restart"
        return [looping ? "재시작 반복" + (unit.restarts.map { " \($0)회" } ?? "") : nil,
                unit.result.flatMap { $0 == "success" ? nil : $0 } ?? (looping ? nil : unit.state),
                looping ? nil : unit.changedAgo.map(ago)]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

extension ServiceLog {
    /// 로그 창에 보일 줄. 실패하면 오류 출력까지 붙여 보이고, 아무것도 못 받았으면 "로그 없음" 이 아니라 실패로 (인증 취소 · 접속 실패).
    /// stripANSI: docker 로그처럼 색 코드가 섞여 오는 출력
    public static func displayLines(_ result: CommandResult, stripANSI strip: Bool) -> [String] {
        let text = result.ok ? result.stdout : result.stdout + result.stderr
        let lines = RemoteCommands.outputLines(strip ? stripANSI(text) : text, type: .linux)
        let empty = result.ok ? "(로그가 없습니다)" : "로그를 가져오지 못했습니다 (exit \(result.exitCode))"
        return lines.isEmpty ? [empty] : lines
    }
}
