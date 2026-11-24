// Ethernet 화면의 서비스 관리: 유선 서비스 활성화·비활성화 · Intranet 으로 지정 · 서비스 추가(수동 IP).
// 활성화·비활성화 명령은 관리자 권한 스크립트(LanCommands — Touch ID 또는 승인 창). Intranet 도 같은 함수 — 지정할 때만 순서 맨 뒤로.

import AppKit
import Foundation
import ServersCore

extension AppModel {
    /// Ethernet 화면 서비스 목록: 유선 서비스 전부 (꺼진 것·같은 어댑터의 여러 서비스 포함, 서비스 순서 그대로)
    var wiredServices: [LanServiceEntry] { lanServiceCandidates }

    /// 판정 하나 (ServersCore ServiceLink): 활성과 연결을 가른다 — 어댑터·링크·그 서비스의 IP, 수동 IP 면 게이트웨이까지
    func serviceLink(_ entry: LanServiceEntry) -> ServiceLink {
        wired?.link(entry) ?? (entry.enabled ? .noAddress : .disabled)
    }

    /// 유선 서비스 스냅숏을 다시 읽는다 (5초 갱신마다 · 활성화/비활성화·지정 뒤). 서비스 목록(lanServices)도 여기서.
    /// reads: 갱신 라운드의 읽기 공유. force: 게이트웨이 응답 캐시(15초)를 보지 않는다 — 활성화·지정 뒤 연결을 기다릴 때.
    /// 더 늦게 시작한 읽기가 있으면 이 결과는 버린다 (5초 갱신과 활성화 뒤 읽기가 겹칠 때)
    func refreshServices(reads: (any CommandRunner)? = nil, force: Bool = false) async {
        if reads == nil { roundReads?.invalidate() }   // 혼자 부른 읽기(활성화 뒤 등) — 도는 라운드가 그 전 목록을 나눠 쓰지 않게
        servicesGeneration += 1
        let generation = servicesGeneration
        let snapshot = await WiredSnapshot.fetch(runner: reads ?? runner, gateways: gatewayCache, force: force)
        guard generation == servicesGeneration else { return }
        wired = snapshot
        lanServices = snapshot.services
    }

    /// Intranet 서비스의 연결 상태 (지정한 서비스가 있으면)
    var lanLink: ServiceLink? {
        lan.flatMap { wired?.link(named: $0.service) }
    }

    /// Ethernet 어댑터 카드: Intranet 으로 지정한 서비스만 뺀 활성 유선 서비스 (nil = 아직 안 읽음)
    var ethernet: [EthernetAdapter]? {
        wired?.adapters(excluding: intranetDesignated)
    }

    /// Intranet 으로 지정한 서비스 (lan.json, 못 읽었으면 servers.conf). 없으면 비어 있다.
    var intranetDesignated: Set<String> {
        Set([lanSettings?.service ?? config?.lan?.service].compactMap { $0 })
    }

    /// Ethernet 화면의 [활성화]/[비활성화] 를 누를 수 있는가 (다른 관리자 작업 중이 아니면)
    func canToggleService(_ entry: LanServiceEntry) -> Bool { busyAction == nil }

    /// 유선 서비스 하나 활성화·비활성화 — 모든 유선 서비스 공통. Intranet 스위치(toggleLan)도 지정한 서비스로 이걸 부른다.
    func setServiceEnabled(_ entry: LanServiceEntry, on: Bool) {
        guard canToggleService(entry) else { return }
        let intranet = intranetDesignated.contains(entry.name)
        // 지정 서비스면 메뉴바·사이드바 Intranet 스위치가 진행 중으로 보인다 (.lan)
        busyAction = intranet ? BusyAction(.lan, "LAN \(on ? "on" : "off") · 인증") : BusyAction(.service, "서비스 \(on ? "on" : "off") · 인증")
        serviceSettling.insert(entry.name)
        let name = entry.name
        Task {
            defer { serviceSettling.remove(name) }
            let result = await LanCommands.runPrivileged(LanCommands.serviceEnableScript(name, on: on), runner: runner)
            await refreshServiceState()
            busyAction = nil
            if let problem = PrivilegedOutcome(result).authProblem {
                statusMessage = "\(problem) · 서비스를 바꾸지 않았습니다."
                return
            }
            guard result.ok else {
                statusMessage = "\(name) 서비스를 \(on ? "활성화하지" : "비활성화하지") 못했습니다 · \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
                return
            }
            if intranet, !on { stopLanTunnels() }   // 내부망이 꺼졌으니 내부망 서버로 연 터널은 닫는다
            statusMessage = "\(name) 서비스를 \(on ? "활성화했습니다" : "비활성화했습니다")"
            // 활성화는 명령이 끝나도 DHCP·수동 IP 적용에 몇 초 걸린다 — 연결될 때까지(최대 15초) 1초마다 다시 읽는다
            if on { await waitServiceConnected(name, seconds: 15) }
        }
    }

    /// [Intranet 으로 지정] 을 누를 수 있는가 (다른 관리자 작업 중이 아니면)
    func canDesignate(_ entry: LanServiceEntry) -> Bool { busyAction == nil }

    /// [Intranet 으로 지정]: 무엇이 바뀌는지 확인 창 → 지정(순서를 옮길 땐 관리자 인증)
    func confirmDesignateIntranet(_ name: String) {
        guard let entry = lanServices.first(where: { $0.name == name }), canDesignate(entry) else { return }
        pendingConfirm = PendingConfirm(title: "\(name) Intranet 으로 지정",
                                        message: "이 서비스를 네트워크 서비스 순서 맨 뒤로 옮깁니다. 관리자 인증이 필요합니다.\n순서를 되돌리려면: 시스템 설정 > 네트워크 > ⋯ > 서비스 순서 설정") { [weak self] in
            self?.designateIntranet(name)
        }
    }

    /// 서비스를 Intranet 으로 지정: 기록(lan.json, 처음이면 servers.conf 에 [network:lan]) + 서비스 순서 맨 뒤로(이미 맨 뒤면 인증 없이 건너뜀).
    /// 켜고 끄지 않는다 — 이전 Intranet 서비스가 켜져 있었으면 그대로다 (필요하면 서비스 카드에서 비활성화).
    func designateIntranet(_ name: String) {
        guard let entry = lanServices.first(where: { $0.name == name }), canDesignate(entry) else { return }
        if config?.lan == nil {
            if let error = editConfig({ try ServerConfigEditor.addingLanService(name, to: $0, reference: configPath) }) {
                statusMessage = "Intranet 으로 지정하지 못했습니다: \(error.problem)"
                return
            }
            adoptLanService(name)
            loadConfig()
        } else {
            adoptLanService(name)
        }
        statusMessage = "\(name) 서비스를 Intranet 으로 지정했습니다."
        requestRefresh()
    }

    /// 지정한 서비스를 서비스 순서 맨 뒤로 — 켜도 기본 경로를 가로채지 않게 (이 앱을 만든 이유: 기본 경로가 내부망 이더넷으로 잡히지 않게).
    /// 이미 맨 뒤면 아무 것도 하지 않는다 (순서는 관리자 권한 없이 읽힌다).
    func moveIntranetLastIfNeeded(_ name: String) {
        Task {
            lanServices = await NetworkInfoFetcher.services(runner: runner)
            guard lanServices.last?.name != name, lanServices.contains(where: { $0.name == name }) else { return }
            // 다른 관리자·원격 작업 중이면 인증 창을 겹쳐 띄우지 않는다 — 지정은 기록됐으니 순서만 손으로 옮기게 알린다
            guard busyAction == nil else {
                statusMessage = "다른 작업 중이라 \(name) 서비스 순서를 맨 뒤로 옮기지 못했습니다 · 시스템 설정 > 네트워크 > 서비스 순서 설정에서 맨 아래로 옮기세요."
                return
            }
            let result = await runPrivileged(LanCommands.moveLastScript(name, libDir: libDir), busy: BusyAction(.service, "서비스 순서 · 인증"))
            await refreshServiceState()
            if let problem = PrivilegedOutcome(result).authProblem {
                statusMessage = "\(problem) · \(name) 서비스 순서를 맨 뒤로 옮기지 않았습니다 (켜면 기본 경로를 가져갈 수 있습니다)."
            } else if !result.ok {
                statusMessage = "\(name) 서비스 순서를 맨 뒤로 옮기지 못했습니다 · 시스템 설정 > 네트워크 > 서비스 순서 설정에서 맨 아래로 옮기세요."
            }
        }
    }

    /// 활성화 뒤 그 서비스가 연결될 때까지 서비스 카드 값을 다시 읽는다 (어댑터·링크가 없으면 기다려도 안 붙으니 그만둔다)
    func waitServiceConnected(_ name: String, seconds: Int) async {
        for _ in 0..<seconds {
            guard let entry = lanServices.first(where: { $0.name == name }) else { return }
            switch serviceLink(entry) {
            case .connected, .noGateway, .noAdapter, .noLink, .disabled: return
            case .noAddress: break
            }
            try? await Task.sleep(for: .seconds(1))
            await refreshServices(force: true)
        }
        await refreshServiceState()
    }

    /// 행 스피너: 이 서비스를 활성화·비활성화하는 중이거나 주소를 기다리는 중
    func serviceBusy(_ entry: LanServiceEntry) -> Bool { serviceSettling.contains(entry.name) }

    /// 서비스 스냅숏·기본 경로·로컬 상태를 다시 읽는다 (활성화·비활성화·추가 뒤)
    func refreshServiceState() async {
        await refreshServices(force: true)   // 게이트웨이 캐시 없이 — 방금 바뀐 서비스
        await refreshDefaultRoute()
        await refreshLocalNow()
    }

    func promptAddService() { serviceAddPrompt = true }

    /// [서비스 추가…] 어댑터 후보: 케이블이 연결된(링크 있음) 유선 어댑터
    func linkedWiredPorts() async -> [HardwarePort] {
        let ports = HardwarePort.parse(await runner.run("networksetup", ["-listallhardwareports"], timeout: 5).stdout).filter(\.isWired)
        var linked: [HardwarePort] = []
        for port in ports {
            let text = await runner.run("ifconfig", [port.device], timeout: 5).stdout
            if HardwarePort.linkActive(ifconfig: text) { linked.append(port) }
        }
        return linked
    }

    /// 서비스 추가: 만들고(꺼진 채, 순서 맨 뒤) 원하면 Intranet 으로 지정. 실패하면 입력창에 보일 문장.
    func createNetworkService(_ draft: NetworkServiceDraft, designate: Bool) async -> String? {
        let draft = draft.trimmed
        guard busyAction == nil else { return "다른 작업이 끝난 뒤 다시 하세요." }
        if let problem = draft.problem(existing: lanServices.map(\.name)) { return problem }
        let result = await runPrivileged(LanCommands.createServiceScript(draft, libDir: libDir), busy: BusyAction(.service, "서비스 추가 · 인증"))
        if let problem = PrivilegedOutcome(result).authProblem { return "\(problem) · 서비스를 만들지 않았습니다." }
        guard result.ok else {
            let detail = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            return "서비스를 만들지 못했습니다" + (detail.isEmpty ? "" : " · \(detail)")
        }
        await refreshServiceState()
        // 순서를 뒤로 못 보냈으면 알린다 — 켜면 이 서비스가 Wi-Fi 보다 앞에서 기본 경로를 가져갈 수 있다
        let warning = result.stderr.split(separator: "\n").first { $0.hasPrefix("주의:") }.map { " · \($0)" } ?? ""
        statusMessage = "\(draft.name) 서비스를 만들었습니다 (비활성)." + warning
        if designate { designateIntranet(draft.name) }
        return nil
    }

    /// Intranet 화면의 [변경…]: 서비스 지정은 Ethernet 화면에서
    func showEthernet() { selectedKey = AppModel.ethernetKey }
}
