// 이 Mac 정보 (LOCAL 화면). 로컬 명령만 읽는다 — Spec(sw_vers·sysctl·system_profiler) · 인터페이스 주소(ifconfig) · 리스닝 포트(lsof).
// Spec 은 Linux Spec 과 같은 "KEY          value" 줄로 만들어 RemoteInfo.parseSpec 을 그대로 쓴다.
// 바뀌지 않는 Spec 은 한 번만 읽고, 메모리·디스크·가동 시간은 앱 안 API(host_statistics64·statfs·sysctl)로 매번 — 5초마다 프로세스 열몇 개를 띄우지 않게 (LocalInfoCollector)

import Foundation

public struct LocalAddress: Sendable, Equatable, Identifiable {
    public var id: String { "\(device) \(ip)" }   // 한 NIC 에 서비스가 둘이면 주소도 둘 (en10: 허브 DHCP + Intranet 수동)
    public let device: String
    public let ip: String
    /// 이 주소를 만든(활성) 네트워크 서비스 이름 (Wi-Fi · Acme Intranet …). 없으면 장치 이름.
    public let name: String

    public init(device: String, ip: String, name: String) {
        self.device = device
        self.ip = ip
        self.name = name
    }
}

public struct LocalPort: Sendable, Equatable, Identifiable {
    public var id: String { "\(address):\(port)" }
    public let port: Int
    public let address: String
    public let command: String
    public let pid: Int

    public init(port: Int, address: String, command: String, pid: Int) {
        self.port = port
        self.address = address
        self.command = command
        self.pid = pid
    }
}

public struct LocalInfo: Sendable, Equatable {
    public var spec: [SpecItem]
    public var addresses: [LocalAddress]
    public var ports: [LocalPort]
    public var fetchedAt: Date
    public var portsAt: Date
    /// IPv4 라우팅 테이블 (netstat). nil 이면 읽지 못함
    public var routes: RouteTable?
    /// /etc/hosts (기본 줄 뺀 것). nil 이면 읽지 못함
    public var hosts: [HostsEntry]?
    /// 애플리케이션 방화벽. nil 이면 읽지 못함
    public var firewall: FirewallState?
    /// 켜진 시스템 프록시 ("HTTP 10.0.0.1:8080" …). 비면 줄을 숨긴다
    public var proxies: [String]

    public init(spec: [SpecItem], addresses: [LocalAddress], ports: [LocalPort], fetchedAt: Date, portsAt: Date, routes: RouteTable? = nil, hosts: [HostsEntry]? = nil,
                firewall: FirewallState? = nil, proxies: [String] = []) {
        self.spec = spec
        self.addresses = addresses
        self.ports = ports
        self.fetchedAt = fetchedAt
        self.portsAt = portsAt
        self.routes = routes
        self.hosts = hosts
        self.firewall = firewall
        self.proxies = proxies
    }
}

public enum LocalCommands {
    /// zsh — 바뀌지 않는 줄만 (앱을 켜고 한 번 · 새로고침 때). 메모리·디스크·가동 시간은 liveSpecLines (매번, 앱 안 값)
    public static let macSpecStatic = """
    printf '%-12s %s\\n' HOSTNAME "$(scutil --get LocalHostName 2>/dev/null || hostname)"
    printf '%-12s %s\\n' OS "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    printf '%-12s %s\\n' KERNEL "$(uname -r)"
    printf '%-12s %s\\n' ARCH "$(uname -m)"
    printf '%-12s %s\\n' CPU "$(sysctl -n machdep.cpu.brand_string) ($(sysctl -n hw.ncpu) threads)"
    # 모델 (맨 끝 — Spec 두 칸 격자의 기존 짝 호스트|OS · Kernel|Arch · CPU|가동 시간을 밀지 않게): "|MacBook Pro (Mac16,1)" — RemoteInfo MODEL 꼴(제조사|제품). 못 읽으면 줄 없음
    system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Model Name/ { n = $2 } /Model Identifier/ { i = $2 } END { if (n != "") printf "%-12s |%s%s\\n", "MODEL", n, (i != "" ? " (" i ")" : "") }'
    """

    /// 바뀌는 Spec 줄 — 예전 zsh 와 같은 글. 메모리 "available" 은 free+inactive+speculative 페이지 (macOS 가 회수할 수 있는 양).
    /// 디스크는 "/" 가 든 APFS 컨테이너 기준 크기 − 여유 (Disk 화면 StorageUsage 와 같은 규칙) — "/" 의 Used 는 봉인된 시스템 볼륨만이라 6% 처럼 나왔다.
    /// 디스크 값은 df -k 처럼 KiB.
    public static func liveSpecLines(memoryTotal: UInt64, memoryAvailable: UInt64, diskTotalKB: UInt64, diskAvailableKB: UInt64, uptime: Int) -> [String] {
        func key(_ name: String) -> String { name.padding(toLength: max(12, name.count), withPad: " ", startingAt: 0) + " " }
        let gib = 1_073_741_824.0
        let total = Double(diskTotalKB) / 1_048_576, available = Double(diskAvailableKB) / 1_048_576, used = total - available
        return [
            key("MEMORY") + String(format: "%.1fGi total, %.1fGi available", Double(memoryTotal) / gib, Double(memoryAvailable) / gib),
            key("ROOT DISK") + String(format: "%.0fGi total, %.0fGi used, %.0fGi available (%.0f%%)", total, used, available, total > 0 ? used * 100 / total : 0),
            key("UPTIME") + String(uptime),
        ]
    }

    /// 예전 한 스크립트의 줄 순서대로: 바뀌지 않는 줄(…CPU) · 바뀌는 줄(MEMORY·ROOT DISK·UPTIME) · MODEL
    public static func mergeSpec(static lines: [String], live: [String]) -> [String] {
        let model = lines.firstIndex { $0.hasPrefix("MODEL") } ?? lines.endIndex
        return Array(lines[..<model]) + live + Array(lines[model...])
    }

    /// lsof 필드 출력(-F pcn): "p<pid>" · "c<command>" · "n<address>:<port>". 같은 주소:포트는 하나로.
    public static func parseListeningPorts(_ text: String) -> [LocalPort] {
        var items: [LocalPort] = []
        var pid = 0, command = ""
        for raw in text.split(separator: "\n") {
            guard let kind = raw.first else { continue }
            let value = String(raw.dropFirst())
            switch kind {
            case "p": pid = Int(value) ?? 0
            case "c": command = value
            case "n":
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                var address = String(value[..<colon]).replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                if address.isEmpty || address == "*" || address == "::" || address == "0.0.0.0" { address = "*" }
                let item = LocalPort(port: port, address: address, command: command, pid: pid)
                if !items.contains(where: { $0.id == item.id }) { items.append(item) }
            default: break
            }
        }
        return items.sorted { ($0.port, $0.address) < ($1.port, $1.address) }
    }

    /// ifconfig 출력에서 (장치, IPv4). lo0 은 뺀다.
    public static func parseInterfaceAddresses(_ text: String) -> [(device: String, ip: String)] {
        var out: [(device: String, ip: String)] = []
        var device = ""
        for raw in text.split(separator: "\n") {
            if let colon = raw.firstIndex(of: ":"), !raw.hasPrefix("\t"), !raw.hasPrefix(" ") {
                device = String(raw[..<colon])
                continue
            }
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("inet "), device != "lo0" else { continue }
            let parts = line.split(separator: " ")
            if parts.count >= 2 { out.append((device, String(parts[1]))) }
        }
        return out
    }
}

public enum LocalInfoFetcher {

    /// 장치별 IPv4 에 서비스 이름을 붙인다. 같은 NIC 에 프리셋이 여럿이면 주소는 활성 서비스의 것이므로 활성 쪽 이름을 쓴다
    /// (비활성 프리셋은 보이지 않는다). 활성 서비스가 둘 이상이면 주소도 서비스마다 붙으므로 -getinfo 의 IP 로 짝짓는다.
    /// Tailscale 은 utun 이라 100.x 주소로 알아본다.
    public static func addresses(runner: any CommandRunner) async -> [LocalAddress] {
        let pairs = LocalCommands.parseInterfaceAddresses(await runner.run("ifconfig", [], timeout: 5).stdout)
        let services = NetworkInfoFetcher.parseAllServices(await runner.run("networksetup", ["-listnetworkserviceorder"], timeout: 5).stdout)
        var serviceIP: [String: String] = [:]
        for device in Set(pairs.map(\.device)) {
            let active = services.filter { $0.device == device && $0.enabled }
            guard active.count > 1 else { continue }
            for entry in active {
                serviceIP[entry.name] = ServiceInfo.parse(await runner.run("networksetup", ["-getinfo", entry.name], timeout: 5).stdout).ip
            }
        }
        return pairs.map { device, ip in
            let active = services.filter { $0.device == device && $0.enabled }
            let owner = active.first { serviceIP[$0.name] == ip } ?? active.first
            let name = owner?.name ?? (device.hasPrefix("utun") && ip.hasPrefix("100.") ? "Tailscale" : device)
            return LocalAddress(device: device, ip: ip, name: name)
        }
    }

    public static func listeningPorts(runner: any CommandRunner) async -> [LocalPort] {
        LocalCommands.parseListeningPorts(await runner.run("lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"], timeout: 10).stdout)
    }
}
