// 진단 카드 (Intranet·Wi-Fi·Ethernet·VPN 화면): ping·경로·HTTP·TCP·DNS·ARP. 그 화면의 장치로만 보낸다 (diagnosticDevice).
// 결과·실행 중은 화면별 DiagnosticState 하나 (AppModel.diagnostics).

import Foundation
import ServersCore

/// 한 화면의 진단 결과와 실행 중인 일
struct DiagnosticState {
    var ping: PingTestResult?
    var http: HTTPTestResult?
    var tcp: TCPPortResult?
    var dns: DNSLookupResult?
    var arp: ArpTableResult?
    var running: Set<DiagnosticTask> = []
}

extension AppModel {
    func isDiagnosticRunning(_ task: DiagnosticTask, _ screen: String) -> Bool {
        diagnosticRunning(screen).contains(task)
    }

    /// 그 화면에서 도는 일 (카드의 버튼 판정 DiagnosticRun 에 넘긴다)
    func diagnosticRunning(_ screen: String) -> Set<DiagnosticTask> {
        diagnostics[screen]?.running ?? []
    }

    /// 화면 키 → 진단 화면 (진단 카드가 없는 화면이면 nil)
    static func diagnosticScreen(_ key: String) -> DiagnosticScreen? {
        switch key {
        case AppModel.lanKey: return .lan
        case AppModel.wifiKey: return .wifi
        case AppModel.ethernetKey: return .ethernet
        case AppModel.vpnKey: return .vpn
        default: return nil
        }
    }

    /// 판정(ServersCore DiagnosticNetwork)에 넘길 망 상태 — 그 화면에 쓰는 값만 읽는다 (다른 화면 값의 변화로 카드를 다시 그리지 않게)
    private func diagnosticNetwork(_ screen: DiagnosticScreen) -> DiagnosticNetwork {
        switch screen {
        case .lan: return DiagnosticNetwork(lan: lanInfo, dns: dnsConfig)
        case .wifi: return DiagnosticNetwork(wifiInterface: wifi.info?.interface, wifiAssociated: wifi.info?.associated == true,
                                             wifiIP: wifiAddress.ip, wifiSubnet: wifiAddress.subnet, dns: dnsConfig)
        case .ethernet: return DiagnosticNetwork(ethernet: ethernetPrimary, dns: dnsConfig)
        case .vpn: return DiagnosticNetwork(vpns: vpns, vpnDetails: vpnDetails)
        }
    }

    /// 진단 카드가 보낼 장치 (그 화면의 장치로만 — 기본 경로로 새지 않게). 없으면 카드의 버튼이 비활성. 판정은 DiagnosticNetwork.device
    func diagnosticDevice(_ screen: String) -> String? {
        AppModel.diagnosticScreen(screen).flatMap { diagnosticNetwork($0).device($0) }
    }

    /// 진단 ping: 그 화면의 장치로만 ping 5회 → 이름을 풀었으면 경로(traceroute ICMP, 최대 15홉).
    func runDiagnosticPing(_ input: String, screen: String) {
        guard !isDiagnosticRunning(.ping, screen), !isDiagnosticRunning(.trace, screen),
              let target = PingTest.target(input), let device = diagnosticDevice(screen) else { return }
        diagnostics[screen, default: DiagnosticState()].running.insert(.ping)
        diagnostics[screen, default: DiagnosticState()].ping = PingTestResult(target: target, device: device)
        Task {
            let ping = await PingTest.ping(target, device: device, runner: runner)
            diagnostics[screen]?.ping?.summary = ping.summary
            diagnostics[screen]?.ping?.resolveFailed = ping.resolveFailed
            guard !ping.resolveFailed else { diagnostics[screen]?.running.remove(.ping); return }
            // ping 이 채운 ARP 캐시를 본다 (이름이면 ping 이 푼 주소를 모르니 IPv4 로 넣었을 때만)
            if NetworkServiceDraft.ipv4(target) != nil { diagnostics[screen]?.ping?.arp = await Arp.lookup(target, device: device, runner: runner) }
            diagnostics[screen]?.running.remove(.ping)
            diagnostics[screen, default: DiagnosticState()].running.insert(.trace)
            let hops = await PingTest.trace(target, device: device, runner: runner)
            diagnostics[screen]?.ping?.hops = hops ?? []
            diagnostics[screen]?.running.remove(.trace)
        }
    }

    /// 진단 경로 [주소 검색]: 공인 IP 홉의 위치를 ip-api.com 에 한 번에 묻는다 (그 화면 장치로)
    func locateDiagnosticHops(screen: String) {
        guard !isDiagnosticRunning(.locate, screen), !isDiagnosticRunning(.trace, screen),
              let result = diagnostics[screen]?.ping, let hops = result.hops else { return }
        let ips = IPLocate.targets(hops)
        guard !ips.isEmpty else { return }
        diagnostics[screen, default: DiagnosticState()].running.insert(.locate)
        Task {
            let found = await IPLocate.lookup(ips, device: result.device, runner: runner)
            // 그 사이 다시 실행·초기화했으면 버린다
            if diagnostics[screen]?.ping?.at == result.at {
                if let found { diagnostics[screen]?.ping?.locations = found } else { statusMessage = "위치를 가져오지 못했습니다." }
            }
            diagnostics[screen]?.running.remove(.locate)
        }
    }

    /// 진단 ARP 표: 그 화면의 장치의 이웃(IP ↔ MAC). privileged 면 관리자 권한으로 (앱 안에서 표가 가려졌을 때)
    func runDiagnosticArp(screen: String, privileged: Bool = false) {
        guard !isDiagnosticRunning(.arp, screen), let device = diagnosticDevice(screen) else { return }
        // 대역을 알면 병렬로 ping 을 한 번씩 보내 ARP 표를 채운 뒤 읽는다 (표는 최근 통신한 상대만 기억한다). 모르면(VPN·너무 넓음) 표만
        let targets = diagnosticSubnet(screen).flatMap { Arp.sweepTargets(ip: $0.0, mask: $0.1) }
        diagnostics[screen, default: DiagnosticState()].running.insert(.arp)
        diagnostics[screen, default: DiagnosticState()].arp = ArpTableResult(device: device, privileged: privileged)
        Task {
            if let targets {
                await Arp.sweep(targets, device: device, runner: runner)
                diagnostics[screen]?.arp?.checked = targets.count
            }
            var entries: [ArpEntry]?
            if privileged {
                let result = await LanCommands.runPrivileged(Arp.privilegedTableScript(device: device), runner: runner)
                if let problem = PrivilegedOutcome(result).authProblem {
                    statusMessage = "\(problem) · ARP 표를 읽지 않았습니다."
                } else if result.ok {
                    entries = Arp.parse(result.stdout).filter { !$0.permanent && $0.device == device }
                }
            } else {
                entries = await Arp.table(device: device, runner: runner)
            }
            if entries == nil, !privileged { statusMessage = "ARP 표를 읽지 못했습니다." }
            // 그 화면 서비스의 대역만 (같은 NIC 의 다른 서비스 망 이웃이 섞이지 않게)
            if let read = entries, let (ip, mask) = diagnosticSubnet(screen), let filtered = Arp.inSubnet(read, ip: ip, mask: mask) {
                entries = filtered.entries
                diagnostics[screen]?.arp?.subnet = filtered.subnet
            }
            diagnostics[screen]?.arp?.entries = entries ?? (privileged ? nil : [])
            // 어떤 장비인지: 제조사(IEEE 목록) · 임의 MAC · DNS·Windows·UPnP 이름 — 응답한 장비만, 병렬. 답이 없으면 빈칸
            if let found = diagnostics[screen]?.arp?.found, !found.isEmpty {
                let source = diagnosticSubnet(screen)?.0
                let dns = diagnosticDNSServer(screen).map { DeviceIdentity.DNSTarget(server: $0, source: source) }
                diagnostics[screen]?.arp?.identities = await DeviceIdentity.identifyAll(found, table: AppModel.ouiTable, dns: dns, ssdpSource: source,
                                                                                    device: device, runner: runner)
            }
            diagnostics[screen]?.running.remove(.arp)
        }
    }

    enum DiagnosticItem { case ping, http, tcp, dns, arp }

    /// 진단 항목 [초기화]: 그 화면의 그 결과를 지운다 (실행 중이면 버튼이 꺼져 있다)
    func clearDiagnostic(_ item: DiagnosticItem, screen: String) {
        switch item {
        case .ping: diagnostics[screen, default: DiagnosticState()].ping = nil
        case .http: diagnostics[screen, default: DiagnosticState()].http = nil
        case .tcp: diagnostics[screen, default: DiagnosticState()].tcp = nil
        case .dns: diagnostics[screen, default: DiagnosticState()].dns = nil
        case .arp: clearArpCache(screen: screen)
        }
    }

    /// ARP [초기화]: 이 Mac 의 ARP 캐시를 비우고(관리자 인증) 결과를 지운다 — 방금 떠난 장비가 20분(max_age)까지 "응답"으로 남지 않게.
    /// 인증을 취소하거나 실패하면 결과도 그대로 둔다
    private func clearArpCache(screen: String) {
        guard !isDiagnosticRunning(.arp, screen) else { return }
        diagnostics[screen, default: DiagnosticState()].running.insert(.arp)
        Task {
            let result = await LanCommands.runPrivileged(Arp.clearCacheScript(), runner: runner)
            if let problem = PrivilegedOutcome(result).authProblem {
                statusMessage = "\(problem) · ARP 캐시를 비우지 않았습니다."
            } else if !result.ok {
                statusMessage = "ARP 캐시를 비우지 못했습니다."
            } else {
                diagnostics[screen, default: DiagnosticState()].arp = nil
                statusMessage = "ARP 캐시를 비웠습니다."
            }
            diagnostics[screen]?.running.remove(.arp)
        }
    }

    /// 진단 TCP: 그 화면의 장치로만 IPv4:포트에 연결을 한 번 (3초)
    func runDiagnosticTCP(_ input: String, screen: String) {
        guard !isDiagnosticRunning(.tcp, screen), let target = TCPPortTest.target(input), let device = diagnosticDevice(screen) else { return }
        diagnostics[screen, default: DiagnosticState()].running.insert(.tcp)
        diagnostics[screen, default: DiagnosticState()].tcp = TCPPortResult(host: target.host, port: target.port, device: device)
        Task {
            let started = Date()
            let open = await TCPProbe.connect(host: target.host, port: target.port, timeout: TCPPortTest.timeout, device: device)
            diagnostics[screen]?.tcp?.open = open
            if open { diagnostics[screen]?.tcp?.ms = Int(Date().timeIntervalSince(started) * 1000) }
            diagnostics[screen]?.running.remove(.tcp)
        }
    }

    /// 진단 DNS 가 물을 서버: 그 화면 장치의 DNS (scoped). VPN 은 그 VPN 의 DNS. 판정은 DiagnosticNetwork.dnsServer
    func diagnosticDNSServer(_ screen: String) -> String? {
        AppModel.diagnosticScreen(screen).flatMap { diagnosticNetwork($0).dnsServer($0) }
    }

    /// 진단 DNS: 그 화면의 DNS 서버에 이름 하나를 묻는다 (그 화면 서비스의 주소에서 보낸다)
    func runDiagnosticDNS(_ input: String, screen: String) {
        guard !isDiagnosticRunning(.dns, screen), let name = DNSLookup.name(input), let device = diagnosticDevice(screen),
              let server = diagnosticDNSServer(screen) else { return }
        let source = screen == AppModel.vpnKey
            ? vpns?.first { $0.state == .connected }.flatMap { vpnDetails[$0.id]?.ipv4.first }.map { String($0.split(separator: "/").first ?? "") }
            : diagnosticSubnet(screen)?.0
        diagnostics[screen, default: DiagnosticState()].running.insert(.dns)
        diagnostics[screen, default: DiagnosticState()].dns = DNSLookupResult(name: name, server: server, device: device)
        Task {
            diagnostics[screen, default: DiagnosticState()].dns = await DNSLookup.query(name, server: server, source: source, device: device, runner: runner)
            diagnostics[screen]?.running.remove(.dns)
        }
    }

    /// 진단 ARP 를 거를 대역: 그 화면 서비스의 IP·서브넷 (VPN 은 nil — 거르지 않음). 판정은 DiagnosticNetwork.subnet
    private func diagnosticSubnet(_ screen: String) -> (ip: String, mask: String)? {
        AppModel.diagnosticScreen(screen).flatMap { diagnosticNetwork($0).subnet($0) }
    }

    /// 진단 HTTP: 그 화면의 장치로만 요청 한 번 → 상태 코드·리다이렉트·단계별 시간.
    func runDiagnosticHTTP(_ input: String, screen: String) {
        guard !isDiagnosticRunning(.http, screen), let url = HTTPTest.url(input),
              let device = diagnosticDevice(screen) else { return }
        diagnostics[screen, default: DiagnosticState()].running.insert(.http)
        diagnostics[screen, default: DiagnosticState()].http = HTTPTestResult(url: url, device: device)
        Task {
            let check = await HTTPTest.check(url, device: device, runner: runner)
            diagnostics[screen]?.http?.check = check
            diagnostics[screen]?.running.remove(.http)
        }
    }

    // MARK: 서버 시점 진단 (원격 정보의 Diagnose 탭 — ServerDiagnose)

    func serverDiagnose(_ server: Server, _ tool: ServerDiagnose.Tool) -> ServerDiagnose.Run? {
        serverDiagnoses[server.key]?[tool]
    }

    /// 같은 대상을 이 Mac(기본 경로)과 그 서버(ssh)에서 함께 잰다. 먼저 끝난 쪽부터 채운다.
    /// 서버 쪽은 인증이 필요하면 비밀번호 창을 띄운다 (버튼을 누른 것이라) — 취소·실패는 "재지 못함"으로 남는다.
    func runServerDiagnose(_ tool: ServerDiagnose.Tool, input: String, on server: Server) {
        guard ServerDiagnoseRun.canRun(tool, input: input, reachable: isReachable(server), running: serverDiagnose(server, tool)?.running ?? false),
              let request = ServerDiagnose.request(tool, input: input) else { return }
        let run = ServerDiagnose.Run(request: request)
        serverDiagnoses[server.key, default: [:]][tool] = run
        // 그 사이 다시 돌렸거나 지웠으면 버린다
        let current: @MainActor () -> Bool = { [weak self] in self?.serverDiagnoses[server.key]?[tool]?.at == run.at }
        Task {
            let outcome = await ServerDiagnose.runLocal(request, runner: runner)
            if current() { serverDiagnoses[server.key]?[tool]?.mac = outcome }
        }
        Task {
            let result = await runRemote(server, command: "sh -s", stdin: ServerDiagnose.script(request) + "\n", timeout: 30)
            let outcome = ServerDiagnose.parseServer(request, output: result.stdout, ok: result.ok,
                                                     failure: result.ok ? nil : RemoteFailure.text(result, serverKey: server.key))
            if current() { serverDiagnoses[server.key]?[tool]?.server = outcome }
        }
    }

    func clearServerDiagnose(_ tool: ServerDiagnose.Tool, on server: Server) {
        guard serverDiagnose(server, tool)?.running != true else { return }
        serverDiagnoses[server.key]?[tool] = nil
    }
}
