// 버튼 가능 여부 판정 — 망·접속 상태가 얽힌 조건은 화면·AppModel 에 적지 않고 여기 둔다 (2026-11-09).
// 화면의 한 줄 조건은 테스트가 없어, 값을 채우는 쪽의 전제(vpn 서버가 없으면 VPN 을 읽지 않는다)와 어긋나도 드러나지 않았다 —
// 첫 vpn 서버를 추가하는 창에서 VPN 이 켜져 있어도 Ping 이 꺼져 있었다.
// 상태 표는 ActionAvailabilityTests: 조합마다 한 줄, 빈 상태(그 종류의 첫 항목을 추가할 때)를 꼭 넣는다.

import Foundation

public extension StatusSnapshot {
    /// 이 서버로 연결을 열 수 있는가 (SSH·터널·전송·원격 정보·파일 놓기). 확인 전(pending)은 막지 않는다 —
    /// 단 vpn 서버는 묶을 utun 이 없으면 확인 전이어도 막는다 (묶지 않고 나가면 같은 사설 대역의 다른 장비로 샌다).
    func allowsConnection(to server: Server) -> Bool {
        !remote(server.key).blocksSSH && !lacksVPNBind(server)
    }

    /// Wake: 꺼져 있고(응답 확인이 안 됨) 경유 서버로 연결할 수 있을 때만. idle = 다른 동작·같은 서버의 전원 대기가 없다.
    /// Shutdown 과 동시에 켜지지 않는다 — 하나는 응답이 없을 때, 하나는 있을 때.
    func canWake(_ server: Server, via: Server?, idle: Bool) -> Bool {
        guard let via, idle else { return false }
        return allowsConnection(to: via) && !remote(server.key).isReachable
    }

    /// Shutdown: 켜져 있는(응답 확인된) Windows 만
    func canShutdown(_ server: Server, idle: Bool) -> Bool {
        idle && server.type == .windows && remote(server.key).isReachable
    }

    /// Tailscale 켜기·끄기 (사이드바 행·망 화면·메뉴 막대의 네트워크 메뉴): 이 Mac 에 Tailscale 이 있고 다른 관리자 작업이 없을 때.
    /// 확인 전(unknown)은 막지 않는다
    func canToggleTailscale(idle: Bool) -> Bool {
        idle && tailscale != .missing
    }

    /// Intranet 켜기·끄기 (같은 세 곳): 지정한 서비스가 이 Mac 에 있고 다른 관리자 작업이 없을 때.
    /// 내부망 설정이 없으면(none) 행·메뉴 자체가 보이지 않는다
    func canToggleLan(idle: Bool) -> Bool {
        idle && lan != .missing
    }
}

/// 진단 카드(Intranet·Wi-Fi·Ethernet·VPN 화면)의 [Run]·[Scan]·[Capture…].
/// device = 그 화면의 장치(DiagnosticNetwork.device) — 없으면 모두 꺼진다. running = 그 화면에서 도는 일.
public enum DiagnosticRun {
    public static func canCapture(device: String?) -> Bool {
        device != nil
    }

    /// ping 은 이어서 경로(trace)를 재고, 경로의 [주소 검색](locate)이 같은 결과를 고친다 — 셋 중 하나라도 돌면 꺼진다
    public static func canPing(_ input: String, device: String?, running: Set<DiagnosticTask>) -> Bool {
        device != nil && PingTest.target(input) != nil && running.isDisjoint(with: [.ping, .trace, .locate])
    }

    public static func canHTTP(_ input: String, device: String?, running: Set<DiagnosticTask>) -> Bool {
        device != nil && HTTPTest.url(input) != nil && !running.contains(.http)
    }

    public static func canTCP(_ input: String, device: String?, running: Set<DiagnosticTask>) -> Bool {
        device != nil && TCPPortTest.target(input) != nil && !running.contains(.tcp)
    }

    /// DNS 는 물을 서버(DiagnosticNetwork.dnsServer)까지 있어야 한다
    public static func canDNS(_ input: String, device: String?, server: String?, running: Set<DiagnosticTask>) -> Bool {
        device != nil && server != nil && DNSLookup.name(input) != nil && !running.contains(.dns)
    }

    public static func canScanArp(device: String?, running: Set<DiagnosticTask>) -> Bool {
        device != nil && !running.contains(.arp)
    }
}

/// 서버 정보 화면의 원격 정보 카드
public enum RemoteInfoTabs {
    /// 탭 전환: 서버가 닿지 않아도 지금 탭에 가져온 결과가 있거나 실시간 탭(fetchedAt 이 없다)이면 다른 탭으로 옮길 수 있다
    public static func canSwitch(reachable: Bool, current: RemoteCommands.Query, currentFetchedAt: Date?) -> Bool {
        reachable || currentFetchedAt != nil || !current.fetches
    }

    /// 탭을 고르면 조용히 가져오는가: 아직 가져온 적 없는 탭만. 실시간 탭은 한 번 가져오는 조회가 아니다 (ServerLiveMonitor)
    public static func fetchesOnSelect(_ tab: RemoteCommands.Query, fetchedAt: Date?) -> Bool {
        tab.fetches && fetchedAt == nil
    }
}

/// 원격 정보 카드 Diagnose 탭의 [Run] (ServerDiagnose): 입력이 꼴에 맞고, 서버가 응답 중이고, 그 도구가 돌고 있지 않을 때.
/// 서버에서 재는 것이라 서버가 응답하지 않으면 잴 수 없다 — 이 Mac 에서 재는 것은 망 화면의 진단 카드가 한다.
public enum ServerDiagnoseRun {
    public static func canRun(_ tool: ServerDiagnose.Tool, input: String, reachable: Bool, running: Bool) -> Bool {
        reachable && !running && ServerDiagnose.request(tool, input: input) != nil
    }
}

/// 서버 추가·편집 창의 [Ping]·[포트 확인]
public enum ServerFormCheck {
    /// 묶을 장치. 스냅숏에 있으면 그것, 없으면 창에서 알 수 있는 값으로 —
    ///   vpn  지금 읽는다. 목록에 vpn 서버가 아직 없으면 상태 확인이 VPN 을 읽지 않아(StatusMonitor.collectLocal) 스냅숏만 보면 늘 nil 이다.
    ///   lan  창에서 고른 서비스의 장치(lanServiceDevice). 내부망 설정([network:lan])이 아직 없으면 스냅숏에 장치가 없다 (첫 lan 서버).
    public static func bindDevice(network: ServerNetwork, vpn: String?, lanServiceDevice: String? = nil,
                                  snapshot: StatusSnapshot, runner: any CommandRunner) async -> String? {
        if let bound = snapshot.bindInterface(network: network, vpn: vpn) { return bound }
        switch network {
        case .vpn: return await StatusMonitor.vpnDevice(name: vpn, runner: runner)
        case .lan: return lanServiceDevice.flatMap { $0.isEmpty ? nil : $0 }
        case .direct, .tailscale: return nil
        }
    }

    /// 보낼 수 있는 망 상태인가: lan·vpn 은 묶을 장치가 있어야 한다 — 없이 보내면 시스템 기본 경로로 나가 그 망이 아닌 곳에 묻는다
    /// (같은 사설 대역의 다른 장비가 답할 수 있다). 묶지 않는 망(direct·tailscale)은 막지 않는다.
    public static func canSend(network: ServerNetwork, device: String?) -> Bool {
        switch network {
        case .lan, .vpn: return device != nil
        case .direct, .tailscale: return true
        }
    }

    public static func canPing(ip: String, network: ServerNetwork, device: String?, checking: Bool) -> Bool {
        PingTest.target(ip) != nil && !checking && canSend(network: network, device: device)
    }

    public static func canProbePort(ip: String, port: Int?, network: ServerNetwork, device: String?, checking: Bool) -> Bool {
        !ip.isEmpty && port != nil && !checking && canSend(network: network, device: device)
    }
}
