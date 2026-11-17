// Ethernet 화면의 서비스 관리: 유선 서비스 켜기·끄기, 내부망용 서비스 추가(수동 IP).
// 판정·입력 검사·명령 조립만 여기. 실행은 관리자 권한 스크립트(LanCommands.privilegedScript)로 앱이 한다.

import Foundation

/// networksetup -listallhardwareports 의 한 항목
public struct HardwarePort: Sendable, Equatable, Identifiable {
    public var id: String { device }
    public let name: String
    public let device: String

    public init(name: String, device: String) {
        self.name = name; self.device = device
    }

    /// 유선 어댑터인가 (LanServiceEntry.isWiredAdapter 와 같은 규칙)
    public var isWired: Bool {
        LanServiceEntry(name: name, hardwarePort: name, device: device, enabled: true).isWiredAdapter
    }

    /// "Hardware Port: USB 10/100/1000 LAN\nDevice: en10\nEthernet Address: …" 블록들
    public static func parse(_ text: String) -> [HardwarePort] {
        var ports: [HardwarePort] = []
        var name: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Hardware Port: ") {
                name = String(line.dropFirst("Hardware Port: ".count))
            } else if line.hasPrefix("Device: "), let current = name {
                let device = String(line.dropFirst("Device: ".count))
                if !device.isEmpty { ports.append(HardwarePort(name: current, device: device)) }
                name = nil
            }
        }
        return ports
    }
}

/// Ethernet 화면 서비스 카드의 상태: 활성(서비스 켜짐)과 연결됨은 다르다 — 켜져 있어도 어댑터·케이블·주소가 없을 수 있다
public enum ServiceLink: Sendable, Equatable {
    case disabled
    /// 켜져 있는데 장치가 없다 (어댑터를 뽑음 — macOS 는 서비스를 남겨 둔다)
    case noAdapter
    /// 장치는 있는데 케이블 링크가 없다
    case noLink
    /// 링크는 있는데 이 서비스의 IP 가 장치에 없다 (DHCP 실패·169.254, 수동 IP 적용 전)
    case noAddress
    /// IP 는 붙었는데 그 서비스의 게이트웨이가 응답하지 않는다 — 수동 IP 는 어느 선에서든 붙어서(인터넷 선에 꽂아도) IP 만으로는 모른다
    case noGateway(ip: String)
    case connected(ip: String)

    /// interface: 그 장치의 ifconfig 값 (nil = 장치 없음). serviceIP: networksetup -getinfo 의 IP address.
    /// gatewayPresent: 수동 IP 서비스의 게이트웨이 확인 (ping 또는 ARP) — nil 이면 보지 않음 (DHCP 는 맞는 망에서만 주소를 받는다)
    public static func of(_ entry: LanServiceEntry, interface: InterfaceState?, serviceIP: String?, gatewayPresent: Bool? = nil) -> ServiceLink {
        guard entry.enabled else { return .disabled }
        guard let interface else { return .noAdapter }
        guard interface.active else { return .noLink }
        guard let ip = serviceIP, !ip.hasPrefix("169.254."), interface.addresses.contains(ip) else { return .noAddress }
        if gatewayPresent == false { return .noGateway(ip: ip) }
        return .connected(ip: ip)
    }

    public var text: String {
        switch self {
        case .disabled: return "비활성"
        case .noAdapter: return "활성 · 어댑터 없음"
        case .noLink: return "활성 · 링크 없음"
        case .noAddress: return "활성 · 주소 없음"
        case .noGateway: return "활성 · 게이트웨이 응답 없음"
        case .connected(let ip): return "연결됨 · \(ip)"
        }
    }

    /// text 에서 "활성 · " 머리를 뗀 것 — 활성인 줄 이미 아는 자리(Ethernet 행·결론)용: "주소 없음", "게이트웨이 응답 없음"
    public var shortText: String {
        let head = "활성 · "
        return text.hasPrefix(head) ? String(text.dropFirst(head.count)) : text
    }

    public var isConnected: Bool { if case .connected = self { return true } else { return false } }
}

/// [서비스 추가] 입력: 어댑터(하드웨어 포트) 위에 수동 IP 서비스 하나
public struct NetworkServiceDraft: Sendable, Equatable {
    public var name: String
    public var port: String
    public var ip: String
    public var mask: String
    public var router: String
    /// DNS 서버 (쉼표·공백으로 여러 개, 비우면 설정하지 않음)
    public var dns: String

    public init(name: String, port: String, ip: String, mask: String = "255.255.255.0", router: String, dns: String = "") {
        self.name = name; self.port = port; self.ip = ip; self.mask = mask; self.router = router; self.dns = dns
    }

    /// DNS 칸을 나눈 주소들
    public var dnsServers: [String] {
        dns.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
    }

    /// 앞뒤 공백을 뗀 값
    public var trimmed: NetworkServiceDraft {
        let t = { (s: String) in s.trimmingCharacters(in: .whitespaces) }
        return NetworkServiceDraft(name: t(name), port: port, ip: t(ip), mask: t(mask), router: t(router), dns: t(dns))
    }

    /// 입력 문제 한 줄. nil 이면 만들 수 있다. existing: 이미 있는 서비스 이름
    public func problem(existing: [String]) -> String? {
        let d = trimmed
        if d.name.isEmpty { return "이름을 입력하세요" }
        // servers.conf·lan.json·명령 인자로 쓰인다 — 줄바꿈·# [ 와 * (networksetup 의 꺼짐 표시) 는 막는다
        if d.name.contains(where: { $0.isNewline }) || d.name.contains("#") || d.name.contains("[") || d.name.hasPrefix("*") {
            return "이름에 # [ 줄바꿈, 맨 앞 * 는 쓸 수 없습니다"
        }
        if existing.contains(where: { $0.caseInsensitiveCompare(d.name) == .orderedSame }) { return "이미 있는 서비스 이름입니다 (\(d.name))" }
        if d.port.isEmpty { return "어댑터를 고르세요" }
        guard let ip = Self.ipv4(d.ip) else { return "IP 가 IPv4 형식이 아닙니다 (예: 10.50.10.17)" }
        guard let mask = Self.ipv4(d.mask), NetworkInfoFetcher.prefixLength(mask: d.mask).map({ $0 > 0 && $0 < 32 }) == true else {
            return "서브넷이 올바르지 않습니다 (예: 255.255.255.0)"
        }
        guard let router = Self.ipv4(d.router) else { return "게이트웨이가 IPv4 형식이 아닙니다 (예: 10.50.10.254)" }
        if ip & mask != router & mask { return "게이트웨이가 IP 와 같은 대역이 아닙니다" }
        if ip == router { return "IP 와 게이트웨이가 같습니다" }
        if d.dnsServers.contains(where: { Self.ipv4($0) == nil }) { return "DNS 가 IPv4 형식이 아닙니다 (쉼표로 여러 개, 예: 10.50.10.1, 8.8.8.8)" }
        // 대역의 첫 주소(네트워크)·끝 주소(브로드캐스트)는 장치에 붙일 수 없다
        for (label, value) in [("IP 가", ip), ("게이트웨이가", router)] where value & ~mask == 0 || value | mask == .max {
            return "\(label) 대역의 네트워크·브로드캐스트 주소입니다"
        }
        return nil
    }

    /// 32비트 값 → "10.50.10.17" (ipv4 의 반대)
    public static func dotted(_ value: UInt32) -> String {
        (0..<4).map { String((value >> (24 - 8 * UInt32($0))) & 0xFF) }.joined(separator: ".")
    }

    /// "10.50.10.17" → 32비트 값. 형식이 틀리면 nil (앞자리 0 거부)
    public static func ipv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            // 앞자리 0(010) 은 받지 않는다 — inet_aton 계열은 8진수로 읽어 다른 주소가 된다
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), part.count == 1 || part.first != "0",
                  let n = UInt32(part), n <= 255 else { return nil }
            value = value << 8 | n
        }
        return value
    }
}

extension LanCommands {
    /// 유선 서비스 하나 켜기·끄기 (Ethernet 화면). 내부망 서비스는 Intranet 스위치로만 — 앱이 막는다.
    public static func serviceEnableScript(_ service: String, on: Bool) -> String {
        privilegedScript(body: "sudo networksetup -setnetworkserviceenabled \(shellQuote(service)) \(on ? "on" : "off")",
                         prompt: "\(service) \(on ? "활성화" : "비활성화")")
    }

    /// 서비스 추가: 만들고 → 바로 끄고(인터넷 경로를 가로채지 않게) → 수동 IP → 순서 맨 뒤. 중간에 실패하면 만든 서비스를 지운다.
    public static func createServiceScript(_ draft: NetworkServiceDraft, libDir: String) -> String {
        let d = draft.trimmed
        let name = shellQuote(d.name)
        let body = """
        source \(shellQuote(libDir + "/lan.zsh")) || exit 1
        sudo networksetup -createnetworkservice \(name) \(shellQuote(d.port)) || exit 1
        if ! sudo networksetup -setnetworkserviceenabled \(name) off || ! sudo networksetup -setmanual \(name) \(shellQuote(d.ip)) \(shellQuote(d.mask)) \(shellQuote(d.router)); then
          sudo networksetup -removenetworkservice \(name)
          printf '서비스를 설정하지 못해 지웠습니다.\\n' >&2
          exit 1
        fi
        \(d.dnsServers.isEmpty ? "" : "sudo networksetup -setdnsservers \(name) \(d.dnsServers.map(shellQuote).joined(separator: " ")) || printf '주의: DNS 를 설정하지 못했습니다.\\n' >&2")
        _lan_move_last \(name) >/dev/null || printf '주의: 서비스 순서를 뒤로 보내지 못했습니다.\\n' >&2
        printf '서비스 추가: %s\\n' \(name)
        """
        return privilegedScript(body: body, prompt: "\(d.name) 서비스 추가")
    }
}
