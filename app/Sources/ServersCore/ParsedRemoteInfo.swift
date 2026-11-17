// 원격 정보 조회(Spec·Ports·Services·OpenWrt 탭) 결과를 받을 때 한 번 파싱해 두는 값 — 화면이 그리기마다 원문을 다시 파싱하지 않게.

import Foundation

public enum ParsedRemoteInfo: Sendable, Equatable {
    /// updates: apt 패키지 목록 (리눅스 Spec 의 UPDATE 줄 — 업데이트 줄을 누르면 보인다)
    case spec([SpecItem], updates: [UpdateItem])
    case ports([PortItem])
    /// 리눅스·윈도 Services (nil = 형식을 못 알아봄 → 화면은 원문을 보여준다)
    case services(ServicesReport?)
    case openwrtServices(OpenWrtServices?)
    case network(OpenWrtNetwork?)
    /// 리눅스 · Windows (WindowsNetwork 가 같은 모양으로 만든다)
    case linuxNetwork(LinuxNetwork?)
    case schedule(ScheduleReport?)
    case firewall(OpenWrtFirewall?)
    case clients([OpenWrtClient]?)
    case wireguard(WireGuardReport?)
    /// 파싱할 것이 없는 조회(live) · 아직 결과 없음
    case none

    /// 화면이 query 별로 쓰던 파서와 같은 호출 (같은 입력 → 같은 값)
    public static func parse(_ query: RemoteCommands.Query, lines: [String], type: ServerType) -> ParsedRemoteInfo {
        switch query {
        case .spec: return .spec(RemoteInfo.parseSpec(lines), updates: type == .linux ? RemoteInfo.parseUpdates(lines) : [])
        case .ports: return .ports(RemoteInfo.parsePorts(lines))
        case .services:
            return type == .openwrt ? .openwrtServices(OpenWrtServices.parse(lines)) : .services(ServicesParser.parse(lines, type: type))
        case .network:
            switch type {
            case .openwrt: return .network(OpenWrtNetwork.parse(lines))
            case .windows: return .linuxNetwork(WindowsNetwork.parse(lines))   // 화면이 같다 (LinuxNetworkView)
            case .linux: return .linuxNetwork(LinuxNetwork.parse(lines))
            }
        case .schedule: return .schedule(ScheduleReport.parse(lines))
        case .firewall: return .firewall(OpenWrtFirewall.parse(lines))
        case .clients: return .clients(OpenWrtClients.parse(lines))
        case .wireguard: return .wireguard(WireGuardReport.parse(lines))
        case .live: return .none
        }
    }
}
