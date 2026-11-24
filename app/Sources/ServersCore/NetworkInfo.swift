// 망 Dashboard 용 정보. 이 Mac 의 tailscale·networksetup 출력만 읽는다 (서버 접속 없음).
//   TailscaleInfo   백엔드 상태·버전·이 Mac 의 IP·MagicDNS 이름·tailnet·피어 목록
//   LanInfo         서비스 활성 여부·장치·설정 IP/게이트웨이·실제 IP
//   NetworkInfoFetcher  CommandRunner 로 수집. 파서는 static 이라 가짜 출력으로 테스트한다.

import Foundation

public struct TailscaleInfo: Sendable, Equatable {
    public struct Peer: Sendable, Equatable, Identifiable {
        public var id: String { hostName + ips.joined() }
        public let hostName: String
        public let dnsName: String
        /// linux · windows · macOS · iOS …
        public let os: String
        public let ips: [String]
        public let online: Bool
    }
    public let backendState: String
    public let version: String
    public let hostName: String
    public let dnsName: String
    public let ips: [String]
    public let tailnet: String
    public let peers: [Peer]

    /// "1.102.4-t3caf7d9e7-g084ee3b64" → "1.102.4"
    public var shortVersion: String { String(version.split(separator: "-").first ?? Substring(version)) }
    /// 끝의 "." 을 뗀 MagicDNS 이름
    public var shortDNSName: String { dnsName.hasSuffix(".") ? String(dnsName.dropLast()) : dnsName }
    public var ipv4: String? { ips.first { !$0.contains(":") } }
    public var ipv6: String? { ips.first { $0.contains(":") } }
}

public struct LanInfo: Sendable, Equatable {
    public let service: String
    public let enabled: Bool
    public let device: String?
    public let hardwarePort: String?
    public let configuration: String?     // "Manual Configuration" / "DHCP Configuration"
    public let configuredIP: String?
    public let subnetMask: String?
    public let router: String?
    public let actualIP: String?          // ipconfig getifaddr <device>
}

/// networksetup -listnetworkserviceorder 의 한 항목 (내부망으로 고를 수 있는 서비스)
public struct LanServiceEntry: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let hardwarePort: String?
    public let device: String?
    public let enabled: Bool

    public init(name: String, hardwarePort: String?, device: String?, enabled: Bool) {
        self.name = name
        self.hardwarePort = hardwarePort
        self.device = device
        self.enabled = enabled
    }

    /// "Acme Intranet · USB 10/100/1000 LAN (en10)"
    public var label: String {
        var text = name
        if let hardwarePort { text += " · \(hardwarePort)" }
        if let device { text += " (\(device))" }
        return text
    }
}

public enum NetworkInfoFetcher {
    /// "255.255.255.0" → 24. 연속된 1 비트가 아니면 nil.
    public static func prefixLength(mask: String) -> Int? {
        let parts = mask.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 <= 255 }) else { return nil }
        return IPv4.prefixLength(mask: parts.reduce(UInt32(0)) { ($0 << 8) | $1 })
    }

    // MARK: Tailscale

    public static func tailscale(runner: any CommandRunner) async -> TailscaleInfo? {
        guard runner.hasExecutable("tailscale") else { return nil }
        let result = await runner.run("tailscale", ["status", "--json"], timeout: 5)
        guard result.ok else { return nil }
        return parseTailscaleStatus(result.stdout)
    }

    public static func parseTailscaleStatus(_ text: String) -> TailscaleInfo? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let backend = json["BackendState"] as? String else { return nil }   // 상태가 없으면 tailscale 출력이 아니다
        let me = json["Self"] as? [String: Any] ?? [:]
        let tailnet = json["CurrentTailnet"] as? [String: Any] ?? [:]
        var peers: [TailscaleInfo.Peer] = []
        for (_, raw) in json["Peer"] as? [String: [String: Any]] ?? [:] {
            peers.append(TailscaleInfo.Peer(hostName: raw["HostName"] as? String ?? "",
                                            dnsName: raw["DNSName"] as? String ?? "",
                                            os: raw["OS"] as? String ?? "",
                                            ips: raw["TailscaleIPs"] as? [String] ?? [],
                                            online: raw["Online"] as? Bool ?? false))
        }
        peers.sort { ($0.online ? 0 : 1, $0.hostName.lowercased()) < ($1.online ? 0 : 1, $1.hostName.lowercased()) }
        return TailscaleInfo(backendState: backend,
                             version: json["Version"] as? String ?? "",
                             hostName: me["HostName"] as? String ?? "",
                             dnsName: me["DNSName"] as? String ?? "",
                             ips: me["TailscaleIPs"] as? [String] ?? [],
                             tailnet: tailnet["Name"] as? String ?? "",
                             peers: peers)
    }

    // MARK: LAN

    /// 서비스 순서 목록 하나로 활성(비활성은 "(*) 이름")·장치를 보고, 주소는 ifconfig 전체에서 — 유선 스냅숏과 같은 읽기라 갱신 라운드에선 나눠 쓴다 (SharedReads)
    public static func lan(_ lan: LanNetwork, runner: any CommandRunner) async -> LanInfo {
        let order = await runner.run("networksetup", ["-listnetworkserviceorder"], timeout: 5).stdout
        let entry = parseAllServices(order).first { $0.name == lan.service }
        let enabled = entry?.enabled ?? false
        let (port, device) = (entry?.hardwarePort, entry?.device)
        let info = parseGetInfo(await runner.run("networksetup", ["-getinfo", lan.service], timeout: 5).stdout)
        // 실제 주소: 이 서비스의 IP 가 장치에 붙었는가 — ipconfig getifaddr 는 장치의 첫 주소 하나라, 같은 NIC 에 서비스가 둘이면
        // 다른 서비스(iptime Hub NIC 의 172.30.1.149)를 내부망 주소로 보였다 (2026-10-15)
        var actual: String?
        if let device, enabled, let ip = info.ip {
            let r = await runner.run("ifconfig", [], timeout: 5)
            if Ethernet.parseInterfaces(r.stdout)[device]?.addresses.contains(ip) == true { actual = ip }
        }
        return LanInfo(service: lan.service, enabled: enabled, device: device, hardwarePort: port,
                       configuration: info.configuration, configuredIP: info.ip, subnetMask: info.mask, router: info.router,
                       actualIP: actual)
    }

    /// 고를 수 있는 서비스 목록 (비활성 포함, 서비스 순서대로)
    public static func services(runner: any CommandRunner) async -> [LanServiceEntry] {
        parseAllServices(await runner.run("networksetup", ["-listnetworkserviceorder"], timeout: 5).stdout)
    }

    /// -listnetworkserviceorder 전체: "(1) 이름" 또는 "(*) 이름"(비활성) 뒤에 "(Hardware Port: X, Device: Y)".
    public static func parseAllServices(_ text: String) -> [LanServiceEntry] {
        let lines = text.split(separator: "\n").map(String.init)
        var out: [LanServiceEntry] = []
        for (i, line) in lines.enumerated() {
            guard let close = line.firstIndex(of: ")"), line.hasPrefix("("), line.index(after: close) < line.endIndex else { continue }
            let marker = line[line.index(after: line.startIndex)..<close]
            guard marker == "*" || Int(marker) != nil else { continue }
            let name = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            var port: String?, device: String?
            if i + 1 < lines.count, lines[i + 1].hasPrefix("(Hardware Port:") {
                let next = lines[i + 1]
                if let r = next.range(of: "Hardware Port: ") {
                    port = String(next[r.upperBound...]).components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces)
                }
                if let r = next.range(of: "Device: ") {
                    device = String(next[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: ") "))
                }
            }
            out.append(LanServiceEntry(name: name, hardwarePort: port, device: device.flatMap { $0.isEmpty ? nil : $0 }, enabled: marker != "*"))
        }
        return out
    }

    /// 그 장치를 쓰는 서비스 이름 (Wi-Fi 화면의 -getinfo 용). 서비스 이름은 바꾸거나 언어에 따라 다를 수 있어 고정하지 않는다 — 못 찾으면 "Wi-Fi".
    public static func serviceName(forDevice device: String?, in services: [LanServiceEntry]) -> String {
        guard let device else { return "Wi-Fi" }
        let matching = services.filter { $0.device == device }
        return (matching.first(where: \.enabled) ?? matching.first)?.name ?? "Wi-Fi"
    }

    /// networksetup -getinfo 출력. 첫 줄이 구성 방식, 이후 "키: 값".
    public static func parseGetInfo(_ text: String) -> (configuration: String?, ip: String?, mask: String?, router: String?) {
        var configuration: String?, ip: String?, mask: String?, router: String?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if configuration == nil, line.hasSuffix("Configuration") { configuration = line; continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // DHCP 가 아직 못 받았을 때 networksetup 은 "Router: (null)" 을 찍는다 (2026-10-15 Ethernet 화면에 그대로 보였다)
            let v: String? = (value.isEmpty || value == "none" || value == "(null)") ? nil : value
            switch key {
            case "IP address": ip = v
            case "Subnet mask": mask = v
            case "Router": router = v
            default: break
            }
        }
        return (configuration, ip, mask, router)
    }
}
