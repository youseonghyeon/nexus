// 유선 서비스 한 번에 읽기 (스냅숏) — Ethernet 화면·서비스 카드·Intranet·사이드바가 모두 이것 하나와 ServiceLink 판정 하나를 쓴다 (2026-10-15 통일).
// 단위는 서비스: NIC(en10)는 서비스 여러 개가 같이 쓰는 물리 장치일 뿐이다.
//   서비스 값(IP·서브넷·게이트웨이·구성)은 그 서비스 것. NIC 값(링크·받기/보내기·인터넷 응답·공인 IP·DNS)은 그 서비스가 연결됨일 때만 그 서비스 값이다.
// 읽기만 한다: networksetup 서비스 순서 · ifconfig 전체 · 활성 유선 서비스마다 -getinfo · 수동 IP 서비스는 게이트웨이 ping(안 되면 ARP, 15초 캐시).

import Foundation

/// networksetup -getinfo 한 서비스
public struct ServiceInfo: Sendable, Equatable {
    public var configuration: String?
    public var ip: String?
    public var mask: String?
    public var router: String?
    public var mac: String?

    public init(configuration: String? = nil, ip: String? = nil, mask: String? = nil, router: String? = nil, mac: String? = nil) {
        self.configuration = configuration; self.ip = ip; self.mask = mask; self.router = router; self.mac = mac
    }

    /// 수동 IP — 어느 선에서든 IP 가 붙으므로 게이트웨이까지 봐야 연결인지 안다
    public var isManual: Bool { configuration?.localizedCaseInsensitiveContains("manual") == true }

    public static func parse(_ getinfo: String) -> ServiceInfo {
        let info = NetworkInfoFetcher.parseGetInfo(getinfo)
        return ServiceInfo(configuration: info.configuration, ip: info.ip, mask: info.mask, router: info.router, mac: Ethernet.parseMAC(getInfo: getinfo))
    }
}

public struct WiredSnapshot: Sendable, Equatable {
    /// 서비스 전부 (서비스 순서, 비활성 포함)
    public var services: [LanServiceEntry]
    /// 장치별 ifconfig 값 (꽂힌 장치만)
    public var interfaces: [String: InterfaceState]
    /// 활성 유선 서비스의 -getinfo
    public var infos: [String: ServiceInfo]
    /// 수동 IP 서비스 중 IP 가 장치에 붙은 것의 게이트웨이 응답
    public var gateways: [String: Bool]

    public init(services: [LanServiceEntry] = [], interfaces: [String: InterfaceState] = [:],
                infos: [String: ServiceInfo] = [:], gateways: [String: Bool] = [:]) {
        self.services = services; self.interfaces = interfaces; self.infos = infos; self.gateways = gateways
    }

    /// 유선 서비스 (서비스 카드·Intranet 지정 후보)
    public var wired: [LanServiceEntry] { services.filter(\.isWiredAdapter) }

    /// 판정 하나: 이 서비스의 연결 상태
    public func link(_ entry: LanServiceEntry) -> ServiceLink {
        .of(entry, interface: entry.device.flatMap { interfaces[$0] }, serviceIP: infos[entry.name]?.ip, gatewayPresent: gateways[entry.name])
    }

    public func link(named name: String) -> ServiceLink? {
        services.first { $0.name == name }.map(link)
    }

    /// Ethernet 어댑터 카드: 활성 유선 서비스 중 Intranet 으로 지정한 서비스만 뺀 것, 어댑터가 꽂힌 것만 (서비스 순서)
    public func adapters(excluding intranet: Set<String>) -> [EthernetAdapter] {
        Ethernet.services(services, intranet: intranet).compactMap { entry in
            guard let device = entry.device, let interface = interfaces[device] else { return nil }
            return EthernetAdapter(service: entry.name, hardwarePort: entry.hardwarePort, device: device, interface: interface,
                                   info: infos[entry.name] ?? ServiceInfo(), gatewayPresent: gateways[entry.name])
        }
    }

    /// 한 번에 읽기 (이 Mac 명령만, 서버 접속 없음). 서비스마다 -getinfo 는 함께 돌린다.
    /// gateways 가 있으면 게이트웨이 응답은 장치·IP·게이트웨이가 같은 동안 그 값을 쓴다 (GatewayCache 15초) — force 면 다시 묻는다 (활성화·지정 뒤)
    public static func fetch(runner: any CommandRunner, gateways cache: GatewayCache? = nil, force: Bool = false, now: Date = Date()) async -> WiredSnapshot {
        let services = NetworkInfoFetcher.parseAllServices(await runner.run("networksetup", ["-listnetworkserviceorder"], timeout: 5).stdout)
        let interfaces = Ethernet.parseInterfaces(await runner.run("ifconfig", [], timeout: 5).stdout)
        let active = services.filter { $0.enabled && $0.isWiredAdapter }
        let infos = await withTaskGroup(of: (String, ServiceInfo).self) { group in
            for entry in active {
                group.addTask { (entry.name, ServiceInfo.parse(await runner.run("networksetup", ["-getinfo", entry.name], timeout: 5).stdout)) }
            }
            var out: [String: ServiceInfo] = [:]
            for await (name, info) in group { out[name] = info }
            return out
        }
        // 수동 IP 이고 그 IP 가 장치에 붙은 서비스만 게이트웨이를 본다
        let probes: [(service: String, device: String, ip: String, router: String)] = active.compactMap { entry in
            guard let info = infos[entry.name], info.isManual, let ip = info.ip, let router = info.router, let device = entry.device,
                  interfaces[device]?.active == true, interfaces[device]?.addresses.contains(ip) == true else { return nil }
            return (entry.name, device, ip, router)
        }
        let gateways = await withTaskGroup(of: (String, Bool).self) { group in
            for probe in probes {
                if !force, let cached = cache?.fresh(service: probe.service, device: probe.device, ip: probe.ip, router: probe.router, now: now) {
                    group.addTask { (probe.service, cached) }
                    continue
                }
                group.addTask {
                    let present = await Arp.gatewayPresent(probe.router, device: probe.device, runner: runner)
                    // 응답 없음은 쥐지 않는다 (GatewayCache.store) — 케이블을 꽂은 직후 첫 확인이 실패해도 다음 라운드가 바로 다시 본다
                    cache?.store(present, service: probe.service, device: probe.device, ip: probe.ip, router: probe.router, at: now)
                    return (probe.service, present)
                }
            }
            var out: [String: Bool] = [:]
            for await (name, present) in group { out[name] = present }
            return out
        }
        return WiredSnapshot(services: services, interfaces: interfaces, infos: infos, gateways: gateways)
    }
}
