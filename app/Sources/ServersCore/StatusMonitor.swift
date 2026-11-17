// 상태 수집.
//   로컬: Tailscale 백엔드·피어(ip→online/offline), 시스템 VPN, 내부망 서비스 활성 여부 — 함께 읽는다
//   원격: 망 조건이 맞는 서버만 병렬로 확인. check=ssh 는 BatchMode 로그인, check=tcp 는 nc 포트 열림.
//         실패하면 켜져 있는지 가른다 — 리눅스는 ping 한 번(응답하면 실패·빨강, 없으면 꺼짐·회색), Windows 는 ping 을 막는 게 기본이라 바로 꺼짐.

import Foundation

public enum TailscaleState: Sendable, Equatable { case running, stopped(String), missing, unknown }
public enum LanState: Sendable, Equatable { case up, down, missing, none }
public enum PeerState: Sendable, Equatable { case online, offline, missing, unchecked }

public enum RemoteState: Sendable, Equatable {
    case pending                 // 아직 확인 전
    case ok(latencyMs: Int)      // ssh 로그인 성공 / 포트 열림
    case fail(latencyMs: Int)    // ssh 로그인 실패 / 포트 닫힘 — 서버는 켜져 있다(ping 응답)
    case off(latencyMs: Int)     // 응답 없음 — 꺼진 것으로 본다(회색). 리눅스는 ping 도 실패, Windows 는 ssh·포트 실패
    case skip(reason: String)    // 망 조건이 안 맞아 확인 안 함
    /// Tailscale SSH 의 check 모드(기본 12시간)가 만료돼 브라우저 인증이 필요하다. 서버가 배너로 보낸 로그인 URL.
    case needsAuth(url: String?)

    public var isReachable: Bool { if case .ok = self { return true } else { return false } }
    /// 메뉴 비활성 판단: 결과가 fail/off/skip/needsAuth 면 닿지 않는 서버. pending 은 막지 않는다.
    public var blocksSSH: Bool {
        switch self { case .fail, .off, .skip, .needsAuth: return true; default: return false }
    }
    public var needsAuth: Bool { if case .needsAuth = self { return true } else { return false } }

    /// 응답 시간(latencyMs)만 다른가 — 같은 갈래(skip 은 이유, needsAuth 는 URL 까지)면 true. 라운드 도중 게시를 건너뛸지 가른다.
    func sameOutcome(as other: RemoteState) -> Bool {
        switch (self, other) {
        case (.pending, .pending), (.ok, .ok), (.fail, .fail), (.off, .off): return true
        case let (.skip(a), .skip(b)): return a == b
        case let (.needsAuth(a), .needsAuth(b)): return a == b
        default: return false
        }
    }
}

/// Tailscale SSH check: 서버가 "To authenticate, visit: https://login.tailscale.com/a/…" 배너를 보내고 브라우저 확인까지 연결을 잡는다.
public enum TailscaleCheck {
    /// 인증이 필요할 때 다시 확인하는 간격. 5초마다 check 세션을 만들었다 죽이는 걸 막는다.
    public static let recheckInterval: TimeInterval = 60

    public static func url(in text: String) -> String? {
        guard let range = text.range(of: #"https://login\.tailscale\.com/[^\s"'<>]+"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    public static func isCheckRequired(_ text: String) -> Bool {
        url(in: text) != nil || text.contains("Tailscale SSH requires an additional check")
    }
}

public struct StatusSnapshot: Sendable, Equatable {
    public var tailscale: TailscaleState = .unknown
    /// tailscale 을 한 번이라도 확인했는가 — 앱을 켠 직후(.unknown 은 "아직 모름")엔 Tailscale 행을 숨긴다 (2026-11-01).
    /// 확인 뒤의 .unknown(명령은 있는데 status 를 못 읽음)은 설치돼 있다는 뜻이라 보인다.
    public var tailscaleChecked = false
    public var lan: LanState = .none
    /// 내부망 서비스에 매인 어댑터(장치)가 지금 존재하는가. 서비스가 켜져 있어도 어댑터가 없으면 쓸 수 없다.
    public var lanAdapterPresent = true
    /// 내부망 서비스의 장치 이름 (en10 등). lan 서버로 가는 연결을 여기에 묶는다. 서비스 순서 목록에서 이름으로 찾는다.
    public var lanDevice: String?
    /// 시스템 VPN (scutil --nc, Tailscale 제외, 목록 순서) — network=vpn 서버가 있을 때만 읽는다. vpn 서버 연결은 그 utun 에 묶는다.
    public var vpnLinks: [VPNLink] = []
    public var peers: [String: PeerState] = [:]       // key → 상태
    public var remote: [String: RemoteState] = [:]    // key → 상태
    public var checkedAt: [String: Date] = [:]
    public var lastFailAt: [String: Date] = [:]
    public init() {}

    public func peer(_ key: String) -> PeerState { peers[key] ?? .unchecked }
    public func remote(_ key: String) -> RemoteState { remote[key] ?? .pending }

    /// network=vpn 서버가 쓸 VPN: vpn= 이름의 것, 이름이 없으면 연결된 첫 VPN (없으면 첫 VPN — 꺼짐으로 보이게). 목록에 없으면 nil.
    public func vpnLink(name: String?) -> VPNLink? {
        guard let name else { return vpnLinks.first { $0.device != nil } ?? vpnLinks.first }
        return vpnLinks.first { $0.name == name }
    }

    /// 이 서버로 여는 연결(ssh·scp·sftp·터널·상태 확인)을 묶을 장치. 시스템 경로에 맡기지 않는 망만 —
    /// lan 은 내부망 서비스 장치(시스템에 경로가 없다), vpn 은 그 VPN 의 utun(꺼졌을 때 같은 사설 대역의 다른 장비로 새지 않게).
    public func bindInterface(network: ServerNetwork, vpn: String?) -> String? {
        switch network {
        case .lan: return lanDevice
        case .vpn: return vpnLink(name: vpn)?.device
        case .tailscale, .direct: return nil
        }
    }

    public func bindInterface(for server: Server) -> String? { bindInterface(network: server.network, vpn: server.vpn) }

    /// network=vpn 인데 묶을 utun 이 없다 (VPN 꺼짐·첫 확인 전·막 추가한 서버). 이때 연결하면 묶이지 않고 시스템 경로로 나가
    /// 같은 사설 대역의 다른 장비로 샌다 — 상태가 "확인 전"(버튼이 켜지는 상태)이어도 연결하지 않는다.
    public func lacksVPNBind(_ server: Server) -> Bool {
        server.network == .vpn && bindInterface(for: server) == nil
    }
}

/// 시스템 VPN 하나: 이름과, 연결돼 있으면 그 인터페이스 (utun5). 꺼져 있으면 device 가 nil.
public struct VPNLink: Sendable, Equatable {
    public let name: String
    public let device: String?
    public init(name: String, device: String?) { self.name = name; self.device = device }
}

/// TCP 포트 확인 (check=tcp). host·port·타임아웃(초)·묶을 장치 → 연결 성공 여부. 기본은 TCPProbe, 테스트는 가짜를 넣는다.
public typealias TCPProbeFunction = @Sendable (String, Int, TimeInterval, String?) async -> Bool

public struct StatusMonitor: Sendable {
    public let config: ServerConfig
    public let runner: any CommandRunner
    let tcpProbe: TCPProbeFunction

    public init(config: ServerConfig, runner: any CommandRunner, tcpProbe: @escaping TCPProbeFunction = TCPProbe.probe) {
        self.config = config
        self.runner = runner
        self.tcpProbe = tcpProbe
    }

    // MARK: 로컬 상태

    /// Tailscale·시스템 VPN·내부망을 함께 읽는다 (서로 기다리지 않게)
    public func collectLocal(into snapshot: inout StatusSnapshot) async {
        let wantsVPN = config.servers.contains { $0.network == .vpn }
        let previousLinks = snapshot.vpnLinks
        async let tailscaleRead = tailscaleStatus()
        async let linksRead: [VPNLink]? = wantsVPN ? vpnLinks(previous: previousLinks) : []
        async let lanRead = lanStatus()
        let (tailscale, peersByIP) = await tailscaleRead
        snapshot.tailscale = tailscale
        snapshot.tailscaleChecked = true
        for server in config.servers where server.network == .tailscale {
            snapshot.peers[server.key] = snapshot.tailscale == .running ? (peersByIP[server.ip] ?? .missing) : .unchecked
        }
        // vpn 서버가 없으면 빈 목록. 목록을 못 읽으면(일시 실패) 이전 값 유지 — 한 번의 실패로 vpn 서버가 꺼짐으로 깜빡이지 않게
        if let links = await linksRead { snapshot.vpnLinks = links }
        let lan = await lanRead
        snapshot.lan = lan.state
        snapshot.lanDevice = lan.device
        if let present = lan.adapterPresent { snapshot.lanAdapterPresent = present }
    }

    /// 내부망 서비스의 상태·장치·어댑터: 서비스 순서 목록 하나("(3) Acme Intranet" · 비활성은 "(*) …", 다음 줄 "Device: en10")와
    /// ifconfig(그 장치가 이 Mac 에 있는가 — lib/lan.zsh 의 _lan_device_present 가 보는 하드웨어 포트 목록과 같은 답).
    /// 서비스가 없으면 장치 nil, 어댑터는 그대로 둔다(nil).
    func lanStatus() async -> (state: LanState, device: String?, adapterPresent: Bool?) {
        guard let lan = config.lan else { return (.none, nil, nil) }
        // 둘을 함께 시작한다 (매 라운드 — 서로 기다리지 않게)
        async let orderRead = runner.run("networksetup", ["-listnetworkserviceorder"], timeout: 5)
        async let ifconfigRead = runner.run("ifconfig", [], timeout: 5)
        let order = (await orderRead).stdout
        let ifconfig = (await ifconfigRead).stdout
        guard let entry = NetworkInfoFetcher.parseAllServices(order).first(where: { $0.name == lan.service }) else { return (.missing, nil, nil) }
        guard let device = entry.device else { return (entry.enabled ? .up : .down, nil, false) }
        let interfaces = Ethernet.parseInterfaces(ifconfig)
        return (entry.enabled ? .up : .down, device, interfaces[device] != nil)
    }

    /// 시스템 VPN 목록 + 연결된 것의 utun (scutil --nc status). 목록을 못 읽으면 nil.
    /// 연결됨인데 status 만 못 읽었으면 이전 utun 을 쓴다 (한 번의 실패로 꺼짐으로 깜빡이지 않게).
    func vpnLinks(previous: [VPNLink] = []) async -> [VPNLink]? { await Self.vpnLinks(previous: previous, runner: runner) }

    /// vpn= 이름의 VPN(없으면 연결된 첫 VPN)의 utun 을 지금 읽는다 — 서버 추가·편집 창의 Ping·포트 확인용.
    /// 상태 확인은 vpn 서버가 있을 때만 VPN 을 읽어, 첫 vpn 서버를 추가하는 창에서는 스냅숏에 장치가 없다. 고르는 규칙은 스냅숏과 같다 (vpnLink).
    public static func vpnDevice(name: String?, runner: any CommandRunner) async -> String? {
        var snapshot = StatusSnapshot()
        snapshot.vpnLinks = await vpnLinks(runner: runner) ?? []
        return snapshot.bindInterface(network: .vpn, vpn: name)
    }

    static func vpnLinks(previous: [VPNLink] = [], runner: any CommandRunner) async -> [VPNLink]? {
        guard let vpns = await SystemVPNs.list(runner: runner) else { return nil }
        var links: [VPNLink] = []
        for vpn in vpns {
            var device: String?
            if vpn.state == .connected {
                device = await SystemVPNs.interface(vpn, runner: runner) ?? previous.first { $0.name == vpn.name }?.device
            }
            links.append(VPNLink(name: vpn.name, device: device))
        }
        return links
    }

    /// 상태와 피어(IP → online)를 tailscale status --json 한 번으로. 피어는 Running 일 때만.
    func tailscaleStatus() async -> (state: TailscaleState, peers: [String: PeerState]) {
        guard runner.hasExecutable("tailscale") else { return (.missing, [:]) }
        let result = await runner.run("tailscale", ["status", "--json"], timeout: 5)
        guard result.ok, let info = NetworkInfoFetcher.parseTailscaleStatus(result.stdout) else { return (.unknown, [:]) }
        guard info.backendState == "Running" else { return (.stopped(info.backendState), [:]) }
        var peers: [String: PeerState] = [:]
        for peer in info.peers {
            for ip in peer.ips { peers[ip] = peer.online ? .online : .offline }
        }
        return (.running, peers)
    }

    // MARK: 확인 가능 여부

    /// 확인하지 않는 이유. 값(rawValue)이 RemoteState.skip(reason:) 에 그대로 들어간다 — 툴팁은 값 그대로, 머리글은 StatusText.skipReasonText.
    public enum SkipReason: String, Sendable, CaseIterable {
        case noTailscale = "no tailscale"
        case tailscaleUnknown = "tailscale ?"
        case tailscaleDown = "tailscale down"
        case peerOffline = "peer offline"
        case peerMissing = "peer missing"
        case lanDown = "lan down"
        case lanMissing = "lan missing"
        case vpnMissing = "vpn missing"
        case vpnDown = "vpn down"
    }

    public func eligibility(_ server: Server, in snapshot: StatusSnapshot) -> SkipReason? {
        switch server.network {
        case .tailscale:
            switch snapshot.tailscale {
            case .missing: return .noTailscale
            case .unknown: return .tailscaleUnknown
            case .stopped: return .tailscaleDown
            case .running: break
            }
            switch snapshot.peer(server.key) {
            case .online: break
            case .offline: return .peerOffline
            default: return .peerMissing
            }
        case .lan:
            switch snapshot.lan {
            case .up: break
            case .down: return .lanDown
            default: return .lanMissing
            }
        case .vpn:
            guard let link = snapshot.vpnLink(name: server.vpn) else { return .vpnMissing }
            if link.device == nil { return .vpnDown }
        case .direct:
            break   // 망 조건 없음 — 바로 확인
        }
        return nil
    }

    // MARK: 원격 확인

    /// bindInterface: 내부망 서버면 그 서비스의 장치 — 시스템 경로가 없으므로 여기 묶어야 닿는다.
    public func checkRemote(_ selected: Server, bindInterface: String? = nil) async -> RemoteState {
        // 서버가 켜졌는지는 고른 계정과 무관하다 — 키 없는 계정을 골랐다고 빨강이 되지 않게 기본 계정으로 본다
        let server = selected.account(selected.primaryUser)
        let started = Date()
        let ok: Bool
        switch server.check {
        case .tcp:
            ok = await tcpProbe(server.ip, server.port, TimeInterval(ConnectPolicy.timeoutSeconds), bindInterface)
        case .ssh:
            let probe = server.type == .windows ? "exit" : "true"
            let args = ConnectPolicy.sharedArguments(port: server.port, bindInterface: bindInterface, identity: server.identityFile)
                + ["-o", "BatchMode=yes", server.target, probe]
            // Tailscale SSH check 대기 중이면 서버가 연결을 붙들어 타임아웃까지 가므로, 배너(로그인 URL)가 오는 즉시 끊고 판정한다
            let result = await runner.run("ssh", args, stdin: nil, environment: [:], timeout: 8,
                                          abortOnLine: { TailscaleCheck.isCheckRequired($0) })
            ok = result.ok
            if !ok, TailscaleCheck.isCheckRequired(result.stderr + result.stdout) {
                return .needsAuth(url: TailscaleCheck.url(in: result.stderr + result.stdout))
            }
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if ok { return .ok(latencyMs: ms) }
        // 정상일 땐 ping 을 보내지 않는다. ICMP 를 막은 서버(클라우드 보안 그룹 등)도 ssh·포트가 되면 초록이다.
        if server.type == .windows { return .off(latencyMs: ms) }
        return await pingReplies(server.ip, bindInterface: bindInterface) ? .fail(latencyMs: ms) : .off(latencyMs: ms)
    }

    /// ping 한 번 (2초). 내부망 서버는 그 장치에 묶는다 (-b) — 시스템 경로가 없다.
    func pingReplies(_ host: String, bindInterface: String?) async -> Bool {
        let args = ["-c", "1", "-t", "2"] + (bindInterface.map { ["-b", $0] } ?? []) + [host]
        return await runner.run("ping", args, timeout: 4).ok
    }

    /// 갱신 도중의 스냅샷을 받는 곳 — 로컬 상태를 읽은 직후 한 번, 서버 결과가 이전 라운드와 달라질 때마다 한 번.
    /// 결과가 그대로인 서버(응답 시간만 다름)는 도중에 넘기지 않고 돌려주는 스냅샷에만 담는다 — 라운드마다 서버 수만큼 다시 게시하지 않게.
    public typealias Progress = @Sendable (StatusSnapshot) async -> Void

    /// 로컬 상태를 읽고, 확인 가능한 서버를 병렬로 확인해 새 스냅샷을 돌려준다.
    /// onProgress 로 먼저 끝난 서버부터 넘긴다 — 느린 서버(타임아웃)를 기다리지 않고 화면에 반영하게.
    public func refresh(previous: StatusSnapshot, onProgress: Progress? = nil) async -> StatusSnapshot {
        var snapshot = previous
        await collectLocal(into: &snapshot)
        var pending: [Server] = []
        let now = Date()
        for server in config.servers {
            if let reason = eligibility(server, in: snapshot) {
                snapshot.remote[server.key] = .skip(reason: reason.rawValue)
                snapshot.checkedAt[server.key] = now
            } else if previous.remote[server.key]?.needsAuth == true,
                      let at = previous.checkedAt[server.key], now.timeIntervalSince(at) < TailscaleCheck.recheckInterval {
                continue   // 인증 필요 상태는 천천히 재확인 (매번 새 check 세션을 만들지 않게)
            } else {
                pending.append(server)
            }
        }
        await onProgress?(snapshot)   // 로컬 상태·확인 안 하는 서버는 바로
        let base = snapshot
        return await withTaskGroup(of: (String, RemoteState).self) { group in
            for server in pending {
                let bind = base.bindInterface(for: server)
                group.addTask { (server.key, await checkRemote(server, bindInterface: bind)) }
            }
            var current = base
            var unchanged: [String] = []
            for await (key, state) in group {
                current.remote[key] = state
                if case .fail = state { current.lastFailAt[key] = Date() }
                if let before = previous.remote[key], before.sameOutcome(as: state) {
                    unchanged.append(key)   // 확인 시각은 라운드 끝에 한 번에
                    continue
                }
                current.checkedAt[key] = Date()
                await onProgress?(current)
            }
            let finished = Date()
            for key in unchanged { current.checkedAt[key] = finished }
            return current
        }
    }
}
