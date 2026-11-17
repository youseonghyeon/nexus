// 진단 카드(Intranet·Wi-Fi·Ethernet·VPN 화면)가 보낼 곳: 망 상태 → 장치 · DNS 서버 · ARP 를 거를 대역.
// 그 화면의 장치로만 보낸다 (기본 경로로 새지 않게). 장치가 없으면 카드의 버튼이 비활성 (ActionAvailability · DiagnosticRun).
// 값은 AppModel 이 옮겨 담고(AppModel+Diagnostics), 판정은 여기 하나 — 상태 표는 DiagnosticTargetsTests.

import Foundation

/// 진단 카드에서 도는 일. ping 이 끝나면 이어서 trace(경로), locate 는 경로의 [주소 검색].
public enum DiagnosticTask: Hashable, Sendable { case ping, trace, locate, http, tcp, dns, arp }

/// 진단 카드가 있는 화면
public enum DiagnosticScreen: Sendable, CaseIterable { case lan, wifi, ethernet, vpn }

/// 진단 카드가 보는 망 상태. 그 화면에 쓰는 값만 채워도 된다
public struct DiagnosticNetwork: Sendable {
    /// Intranet: 지정한 내부망 서비스
    public var lan: LanInfo?
    /// Wi-Fi: 인터페이스 이름(en0)·연결 여부·주소
    public var wifiInterface: String?
    public var wifiAssociated: Bool
    public var wifiIP: String?
    public var wifiSubnet: String?
    /// Ethernet: 대표 어댑터 (인터넷 카드와 같은 것)
    public var ethernet: EthernetAdapter?
    /// VPN: 시스템 VPN 목록(nil = 아직 못 읽음)과 상세 (UUID → 상세)
    public var vpns: [SystemVPN]?
    public var vpnDetails: [String: SystemVPNDetail]
    /// scutil --dns (장치별 리졸버)
    public var dns: DNSConfig?

    public init(lan: LanInfo? = nil, wifiInterface: String? = nil, wifiAssociated: Bool = false, wifiIP: String? = nil, wifiSubnet: String? = nil,
                ethernet: EthernetAdapter? = nil, vpns: [SystemVPN]? = nil, vpnDetails: [String: SystemVPNDetail] = [:], dns: DNSConfig? = nil) {
        self.lan = lan
        self.wifiInterface = wifiInterface; self.wifiAssociated = wifiAssociated; self.wifiIP = wifiIP; self.wifiSubnet = wifiSubnet
        self.ethernet = ethernet
        self.vpns = vpns; self.vpnDetails = vpnDetails
        self.dns = dns
    }

    /// 보낼 장치. Intranet = 켜진 내부망 서비스의 장치 · Wi-Fi = 연결된 Wi-Fi · Ethernet = 연결된 대표 어댑터
    /// VPN = 첫 번째로 연결된 VPN 의 인터페이스(utunN) — 둘 이상 동시에 쓰는 일은 드물다(경로 충돌)
    public func device(_ screen: DiagnosticScreen) -> String? {
        switch screen {
        case .lan: return lan?.enabled == true ? lan?.device : nil
        case .wifi: return wifiAssociated ? wifiInterface : nil
        case .ethernet: return ethernet.flatMap { $0.state == .connected ? $0.device : nil }
        case .vpn: return connectedVPNDetail?.interface
        }
    }

    /// 진단 DNS 가 물을 서버: 그 화면 장치의 DNS (scoped). VPN 은 그 VPN 의 DNS
    public func dnsServer(_ screen: DiagnosticScreen) -> String? {
        if screen == .vpn { return connectedVPNDetail?.dnsServers.first }
        guard let device = device(screen) else { return nil }
        return dns?.scoped[device]?.nameservers.first
    }

    /// 진단 ARP 를 거를 대역: 그 화면 서비스의 IP·서브넷 (VPN 은 nil — 거르지 않음)
    public func subnet(_ screen: DiagnosticScreen) -> (ip: String, mask: String)? {
        switch screen {
        case .lan:
            guard let lan, let ip = lan.configuredIP, let mask = lan.subnetMask else { return nil }
            return (ip, mask)
        case .ethernet:
            guard let ethernet, let ip = ethernet.address, let mask = ethernet.netmask else { return nil }
            return (ip, mask)
        case .wifi:
            guard let ip = wifiIP, let mask = wifiSubnet else { return nil }
            return (ip, mask)
        case .vpn:
            return nil
        }
    }

    /// 첫 번째로 연결된 VPN 의 상세 (상세를 아직 못 읽었으면 nil)
    private var connectedVPNDetail: SystemVPNDetail? {
        vpns?.first { $0.state == .connected }.flatMap { vpnDetails[$0.id] }
    }
}
