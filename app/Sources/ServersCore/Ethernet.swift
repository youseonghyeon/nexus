// Ethernet 행·화면의 어댑터 카드·타일: 이 Mac 의 유선 서비스 상태 (읽기만 — 활성화·비활성화는 화면의 서비스 카드에서).
// 고르는 규칙 — 서비스 기준 (2026-10-15, 그 전엔 장치 기준이라 같은 NIC 의 서비스 둘이 엉켰다):
//   유선 서비스(Wi-Fi·브리지·테더링·VPN 제외) 중 활성인 것에서 Intranet 으로 지정한 서비스 하나만 뺀다.
//   en10 처럼 한 장치에 서비스가 둘(iptime Hub NIC · acme ethernet)이면 둘째 주소가 이 서비스 것일 수 있어 주소는 그 서비스의 IP(getinfo)로 본다.
//   그중 어댑터가 꽂힌(ifconfig 에 장치가 있는) 것만 (2026-10-13) — macOS 는 한 번 꽂았던 어댑터의 서비스를 뽑은 뒤에도 남겨 둬서,
//   빈 "어댑터 없음" 카드가 지나간 허브 수만큼 쌓였다.
//   대표(사이드바 행·타일): 인터넷이 나가는 서비스 → 기본 경로 장치의 연결된 서비스 → 주소 있음 → 링크 있음 → 첫 번째.
//   링크 속도·받기/보내기는 물리 NIC 값이라 같은 장치의 서비스끼리 같다.

import Foundation

extension LanServiceEntry {
    /// 유선 어댑터 서비스인가: 장치가 있고 Wi-Fi·Bluetooth·브리지·테더링·VPN(utun) 이 아님
    public var isWiredAdapter: Bool {
        guard let device, !device.isEmpty else { return false }
        let port = hardwarePort ?? ""
        if ["Wi-Fi", "AirPort", "Bluetooth", "Thunderbolt Bridge", "iPhone USB"].contains(where: { port.localizedCaseInsensitiveContains($0) }) { return false }
        if device.hasPrefix("bridge") || device.hasPrefix("utun") { return false }
        return true
    }
}

/// ifconfig 한 장치 블록에서 읽은 값
public struct InterfaceState: Sendable, Equatable {
    public var mac: String?
    public var ipv4: String?
    /// "255.255.255.0" (ifconfig 의 0xffffff00 을 바꾼 값)
    public var netmask: String?
    /// LinkMedia.media 와 같은 형태 ("1000baseT <full-duplex>")
    public var media: String?
    /// status: active
    public var active = false
    /// 장치에 붙은 IPv4 전부 (한 장치에 서비스가 둘 켜지면 둘 다 — en10 의 DHCP + 수동 IP)
    public var addresses: [String] = []

    public init(mac: String? = nil, ipv4: String? = nil, netmask: String? = nil, media: String? = nil, active: Bool = false, addresses: [String] = []) {
        self.mac = mac; self.ipv4 = ipv4; self.netmask = netmask; self.media = media; self.active = active
        self.addresses = addresses.isEmpty ? (ipv4.map { [$0] } ?? []) : addresses   // 첫 주소만 줬으면 그것 하나
    }
}

public struct EthernetAdapter: Sendable, Equatable, Identifiable {
    /// 화면 분기용 요약 (자세한 상태는 link)
    public enum State: Sendable, Equatable {
        /// 연결됨 (링크 + 이 서비스의 IP, 수동 IP 면 게이트웨이 응답까지)
        case connected
        /// 링크는 있는데 이 서비스가 연결이 아님 (주소 없음 · 게이트웨이 응답 없음)
        case noAddress
        /// 어댑터는 있는데 케이블 링크가 없음
        case noLink
    }

    public var id: String { service }
    public let service: String
    public let hardwarePort: String?
    public let device: String
    public let interface: InterfaceState
    /// 이 서비스의 -getinfo. 운영(WiredSnapshot.adapters)은 늘 값을 넘긴다 — 못 읽었으면 빈 ServiceInfo 라 주소 없음.
    /// nil 은 getinfo 없이 직접 만들 때만: 장치의 첫 주소를 이 서비스 것으로 본다
    public let info: ServiceInfo?
    /// 판정 (WiredSnapshot.link 와 같은 ServiceLink.of)
    public let link: ServiceLink

    public init(service: String, hardwarePort: String?, device: String, interface: InterfaceState,
                info: ServiceInfo? = nil, gatewayPresent: Bool? = nil) {
        self.service = service; self.hardwarePort = hardwarePort; self.device = device; self.interface = interface; self.info = info
        link = .of(LanServiceEntry(name: service, hardwarePort: hardwarePort, device: device, enabled: true), interface: interface,
                   serviceIP: info.map(\.ip) ?? interface.ipv4, gatewayPresent: gatewayPresent)
    }

    /// 이 서비스의 주소 (장치에 실제로 붙은 것만 — 같은 NIC 의 다른 서비스 주소를 끌어오지 않는다)
    public var address: String? {
        switch link {
        case .connected(let ip), .noGateway(let ip): return ip
        default: return nil
        }
    }

    public var netmask: String? { address == nil ? nil : (info?.mask ?? interface.netmask) }

    public var state: State {
        switch link {
        case .connected: return .connected
        case .noLink, .noAdapter: return .noLink
        case .noAddress, .noGateway, .disabled: return .noAddress
        }
    }

    public var linkActive: Bool { interface.active }
}

public enum Ethernet {
    /// Ethernet 에 보일 서비스: 켜진 유선 서비스 중 Intranet 으로 지정한 서비스만 뺀 것 (서비스 순서 그대로).
    /// 서비스 기준 — 같은 장치(en10)의 다른 서비스는 남는다 (2026-10-15: 예전엔 내부망이 켜진 장치째 빼서 같은 NIC 의 인터넷 서비스까지 사라졌다)
    public static func services(_ all: [LanServiceEntry], intranet: Set<String>) -> [LanServiceEntry] {
        all.filter { $0.enabled && $0.isWiredAdapter && !intranet.contains($0.name) }
    }

    /// 사이드바 행·타일에 보일 하나: 인터넷이 나가는 서비스 → (못 알면) 기본 경로 장치의 연결된 서비스 → 주소 있음 → 링크 있음 → 첫 번째
    public static func primary(_ adapters: [EthernetAdapter], internetService: String? = nil, defaultRoute: String?) -> EthernetAdapter? {
        if let internetService, let hit = adapters.first(where: { $0.service == internetService && $0.linkActive }) { return hit }
        if let route = defaultRoute, let hit = adapters.first(where: { $0.device == route && $0.state == .connected }) { return hit }
        return adapters.first { $0.state == .connected }
            ?? adapters.first { $0.linkActive }
            ?? adapters.first
    }

    // MARK: 파서

    /// `ifconfig` 전체 출력 → 장치별 값. 장치 줄은 들여쓰기 없이 "en8: flags=…".
    public static func parseInterfaces(_ text: String) -> [String: InterfaceState] {
        var out: [String: InterfaceState] = [:]
        var device: String?
        for raw in text.split(separator: "\n") {
            if !raw.hasPrefix("\t"), !raw.hasPrefix(" "), let colon = raw.firstIndex(of: ":") {
                device = String(raw[..<colon])
                if let device { out[device] = InterfaceState() }
                continue
            }
            guard let device else { continue }
            let line = raw.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: " ").map(String.init)
            if line.hasPrefix("ether "), parts.count >= 2 {
                out[device]?.mac = parts[1]
            } else if line.hasPrefix("inet "), parts.count >= 2 {
                out[device]?.addresses.append(parts[1])
                guard out[device]?.ipv4 == nil else { continue }
                out[device]?.ipv4 = parts[1]
                if let i = parts.firstIndex(of: "netmask"), i + 1 < parts.count { out[device]?.netmask = dottedMask(hex: parts[i + 1]) }
            } else if line.hasPrefix("media:") || line.hasPrefix("status:") {
                let link = NetworkProbe.parseLinkMedia(line)
                if line.hasPrefix("media:") { out[device]?.media = link.media }
                else { out[device]?.active = link.status == "active" }
            }
        }
        return out
    }

    /// "0xffffff00" → "255.255.255.0"
    public static func dottedMask(hex: String) -> String? {
        guard hex.hasPrefix("0x"), let value = UInt32(hex.dropFirst(2), radix: 16) else { return nil }
        return NetworkServiceDraft.dotted(value)
    }

    /// 링크 속도 Mbps: "1000baseT <full-duplex>" → 1000, "2500Base-T" → 2500, "10GBase-T" → 10000, "100baseTX" → 100
    public static func speedMbps(media: String?) -> Int? {
        guard let media else { return nil }
        let digits = media.prefix { $0.isNumber }
        guard let number = Int(digits), number > 0 else { return nil }
        let rest = media.dropFirst(digits.count)
        return rest.first.map { $0 == "G" || $0 == "g" } == true ? number * 1000 : number
    }

    /// 타일 값·단위: 1000 → ("1", "Gbps"), 2500 → ("2.5", "Gbps"), 100 → ("100", "Mbps")
    public static func speedText(mbps: Int) -> (value: String, unit: String) {
        guard mbps >= 1000 else { return (String(mbps), "Mbps") }
        let gbps = Double(mbps) / 1000
        return (gbps == gbps.rounded() ? String(Int(gbps)) : String(format: "%.1f", gbps), "Gbps")
    }

    /// 한 줄 글: 2500 → "2.5 Gbps" (서버 Live·공유기 포트 표)
    public static func speedLabel(mbps: Int) -> String {
        let s = speedText(mbps: mbps)
        return "\(s.value) \(s.unit)"
    }

    /// 링크 타일 경고: 1 Gbps 미만·half-duplex (기가비트 장비에서 100 Mbps 로 붙으면 대개 케이블·포트 문제). duplex: Ethernet.duplex(media:) 값
    public static func linkWarns(mbps: Int, duplex: String?) -> Bool {
        mbps < 1000 || duplex == "half-duplex"
    }

    /// 실제 MAC 만: 앱 안에서 돈 ifconfig 는 MAC 을 02:00:00:00:00:00 으로 가려 받는다(2026-10-11 화면에서 확인 — 셸에서는 실제 값).
    /// networksetup -getinfo 의 "(null)"(어댑터 없음)도 nil.
    public static func realMAC(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty,
              text != "02:00:00:00:00:00", text != "00:00:00:00:00:00", text != "(null)" else { return nil }
        return text
    }

    /// networksetup -getinfo 의 "Ethernet Address: 6c:6e:07:a2:b1:4c"
    public static func parseMAC(getInfo text: String) -> String? {
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("Ethernet Address:") else { continue }
            return realMAC(String(line.dropFirst("Ethernet Address:".count)))
        }
        return nil
    }

    /// "<full-duplex,flow-control>" → "full-duplex", "<half-duplex>" → "half-duplex", 없으면 nil (ifconfig 표기 그대로)
    public static func duplex(media: String?) -> String? {
        guard let media else { return nil }
        if media.contains("full-duplex") { return "full-duplex" }
        if media.contains("half-duplex") { return "half-duplex" }
        return nil
    }
}
