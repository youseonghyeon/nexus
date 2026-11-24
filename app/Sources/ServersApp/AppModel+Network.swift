// 망 Dashboard 의 이 Mac 정보 수집(tailscale·networksetup·route·netstat·ping·curl)과 망 켜기/끄기. 서버에는 접속하지 않는다.

import AppKit
import Foundation
import ServersCore

extension AppModel {
    /// 내부망 설정: 서비스는 lan.json 의 지정 서비스. 파일을 못 읽었으면 servers.conf 값.
    var lan: LanNetwork? {
        config?.lan.map { base in lanSettings.map { base.replacing(service: $0.service) } ?? base }
    }

    /// 이 서버로 여는 연결을 묶을 장치: 내부망 서버면 그 서비스의 장치(en10 등), VPN 서버면 그 VPN 의 utun, 아니면 nil.
    /// 시스템에 내부망 경로를 넣지 않으므로 앱의 lan 연결은 전부 이걸 지나야 한다 (ssh·scp·sftp·터널·상태 확인). 판정은 StatusSnapshot.bindInterface.
    func bindInterface(for server: Server) -> String? {
        status.bindInterface(for: server)
    }

    /// 서버 정보 네트워크 줄에 붙이는 장치: 묶는 서버는 그 장치, 아니면 라우팅 표가 고르는 장치 (VPN 이 경로를 가져가면 utun).
    /// vpn 서버인데 묶을 utun 이 없으면 nil — 연결 자체를 막으므로(lacksVPNBind) 시스템 경로를 보여 주지 않는다.
    func outgoingInterface(_ server: Server) async -> String? {
        if let bound = bindInterface(for: server) { return bound }
        guard server.network != .vpn else { return nil }
        return await NetworkProbe.routeInterface(to: server.ip, runner: runner)
    }

    /// 연결 진입점(SSH 탭·터널·전송·탐색·원격 명령)의 마지막 방어: vpn 서버인데 묶을 utun 이 없으면 열지 않는다 (StatusSnapshot.lacksVPNBind).
    /// 버튼은 isReachable 로 이미 꺼지지만, 복원된 항목·단축키처럼 버튼을 거치지 않는 길도 있다.
    func vpnBindMissing(_ server: Server) -> Bool {
        guard status.lacksVPNBind(server) else { return false }
        statusMessage = "\(server.vpn ?? "VPN") 이 연결돼 있지 않아 \(server.key) 에 연결하지 못했습니다."
        return true
    }

    /// 유선 서비스 전부 (Ethernet 서비스 카드·Intranet 지정 후보). Wi-Fi·VPN(장치 없음)·브리지·테더링은 뺀다.
    var lanServiceCandidates: [LanServiceEntry] {
        lanServices.filter(\.isWiredAdapter)   // 유선 판정은 Ethernet 행과 같은 규칙 (ServersCore)
    }

    /// 이 서비스로 인터넷이 나가는가 (서비스 카드의 "인터넷 경로" 딱지 — 표시만): macOS 의 인터넷 서비스(PrimaryService), VPN 이면 그 아래 회선의 서비스.
    /// 못 읽었을 때만 예전 판정(기본 경로가 그 장치로 나간다)
    func carriesInternet(_ service: String) -> Bool {
        let deviceMatch: Bool = {
            guard let internet = defaultRoute?.interface, !internet.isEmpty,
                  let device = lanServices.first(where: { $0.name == service })?.device else { return false }
            return device == internet
        }()
        return PrimaryService.carriesInternet(service, primary: primaryService, services: lanServices, deviceMatch: deviceMatch)
    }

    /// 기본 경로(장치·게이트웨이)와 인터넷 서비스를 함께 읽는다
    func refreshDefaultRoute() async {
        // 서로 독립인 읽기 — 함께 시작하고 대입은 예전 순서대로
        let runner = self.runner
        async let route = NetworkProbe.defaultRoute(runner: runner)
        async let primary = NetworkProbe.primaryService(runner: runner)
        defaultRoute = await route
        primaryService = await primary
    }

    /// Tailscale·Intranet 켜기·끄기를 누를 수 있는가 (사이드바 행·망 화면·메뉴 막대의 네트워크 메뉴 공통). 판정은 ServersCore (ActionAvailability)
    var canToggleTailscale: Bool { status.canToggleTailscale(idle: busyAction == nil) }
    var canToggleLan: Bool { status.canToggleLan(idle: busyAction == nil) }

    // MARK: 내부망 서비스 (lan.json)

    /// 첫 실행이면 servers.conf 값으로 파일을 만든다. 파일이 깨졌으면 servers.conf 값을 쓰고 이유를 보여준다.
    func loadLanSettingsIfNeeded() {
        guard lanSettings == nil, let seed = config?.lan else { return }
        do {
            lanSettings = try LanStore.loadOrSeed(service: seed.service)
        } catch {
            statusMessage = "내부망 설정을 읽지 못해 servers.conf 값을 씁니다: \(error.localizedDescription) · 해결: 파일을 지우면 다시 만듭니다 · \(LanStore.defaultURL.path)"
        }
    }

    func saveLanSettings() -> String? {
        guard let settings = lanSettings else { return nil }
        defer { Task { await fetchNetworkInfoIfSelected() } }
        do {
            try LanStore.save(settings)
            return nil
        } catch {
            return "내부망 설정을 저장하지 못했습니다: \(error.localizedDescription) · \(LanStore.defaultURL.path)"
        }
    }

    /// carriesInternet 이 보는 값(서비스 목록·기본 경로)을 지금 다시 읽는다.
    /// 평소엔 LAN·Wi-Fi 화면을 볼 때만 갱신되므로, 메뉴바·사이드바에서 끌 때 비었거나 낡았을 수 있다. 서버 추가 창의 첫 내부망 서비스 고르기도 이걸로.
    func refreshInternetRoute() async {
        lanServices = await NetworkInfoFetcher.services(runner: runner)
        await refreshDefaultRoute()
    }

    /// 이 Mac 정보. 주소·기본 경로·DNS 는 볼 때마다, 바뀌지 않는 Spec 은 한 번, 리스닝 포트·라우팅 표·방화벽·프록시·hosts 는 30초에 한 번 (LocalInfoCollector).
    /// force(새로고침 버튼)면 전부 다시. 이미 읽는 중이면 그 읽기를 기다린다 — 화면을 열 때 선택(didSet)과 화면(.task)이 함께 불러도 한 번만.
    func fetchLocalInfo(force: Bool = false, reads: (any CommandRunner)? = nil) async {
        if let running = localInfoTask {
            await running.value
            if !force { return }   // 새로고침은 기다린 뒤 새로 읽는다
        }
        let runner = reads ?? self.runner
        let own = self.runner   // 기본 경로·인터넷 서비스는 refreshDefaultRoute 처럼 라운드 공유 없이 직접
        let task = Task {
            // 기본 경로·인터넷 서비스·DNS 는 수집과 독립 — 함께 시작하고 대입은 예전 순서대로
            async let route = NetworkProbe.defaultRoute(runner: own)
            async let primary = NetworkProbe.primaryService(runner: own)
            async let dns = DNSConfig.fetch(runner: runner)
            let info = await localCollector.collect(runner: runner, force: force, vpns: vpns ?? [], egressCache: vpnEgressCache,
                                                     network: egressNetworkKey, slowKey: localSlowKey)
            defaultRoute = await route
            primaryService = await primary
            dnsConfig = await dns
            localInfo = info
            fetchPublicIP()
        }
        localInfoTask = task
        await task.value
        if localInfoTask == task { localInfoTask = nil }
    }

    /// VPN 바깥 장치 캐시의 망 조건: 기본 경로·인터넷 서비스·연결된 유선 장치·Wi-Fi 연결 — 회선이 바뀌면 바깥 장치를 다시 찾는다 (VPNEgressCache)
    var egressNetworkKey: String {
        let route = [defaultRoute?.interface, defaultRoute?.gateway].map { $0 ?? "" }.joined(separator: ",")
        let primary = primaryService.map { String(describing: $0) } ?? ""
        let wiredUp = (wired?.wired ?? []).filter { wired?.link($0).isConnected == true }.compactMap(\.device).sorted().joined(separator: ",")
        let wifiUp = wifi.info?.associated == true ? wifi.info?.interface ?? "" : ""
        return [route, primary, wiredUp, wifiUp].joined(separator: "|")
    }

    /// this Mac 느린 값(라우팅 표·방화벽·프록시…)의 조건: 회선 + 연결된 VPN + Tailscale — 망을 켜고 끄면 30초를 기다리지 않고 다시 읽는다
    var localSlowKey: String {
        let connected = (vpns ?? []).filter { $0.state == .connected }.map(\.id).sorted().joined(separator: ",")
        return [egressNetworkKey, connected, String(describing: status.tailscale), String(describing: status.lan)].joined(separator: "|")
    }

    /// 선택한 NETWORK 행의 정보를 이 Mac 명령(tailscale status · networksetup)으로 읽는다. 서버 접속 없음.
    /// round: 5초 갱신 라운드의 읽기 공유 (SharedReads) — 그때는 서비스 목록·유선 스냅숏을 방금 읽었으므로 다시 읽지 않는다.
    /// nil 이면 화면을 바꿨을 때처럼 혼자 부른 것 — 필요한 걸 직접 읽는다.
    func fetchNetworkInfoIfSelected(round reads: (any CommandRunner)? = nil) async {
        let inRound = reads != nil
        let runner = reads ?? self.runner
        switch selectedKey {
        case AppModel.localKey:
            await fetchLocalInfo(reads: reads)
        case AppModel.tailscaleKey:
            tailscaleInfo = await NetworkInfoFetcher.tailscale(runner: runner)
            networkInfoAt = Date()
        case AppModel.lanKey:
            guard let lan = self.lan else { return }
            let info = await NetworkInfoFetcher.lan(lan, runner: runner)
            lanInfo = info
            if !inRound { lanServices = await NetworkInfoFetcher.services(runner: runner) }   // 라운드에선 refreshServices 가 방금 채웠다
            await refreshDefaultRoute()
            dnsConfig = await DNSConfig.fetch(runner: runner)   // 이 Mac 설정 읽기만 — 내부망으로 나가는 요청 없음
            if let device = info.device {
                let media = await NetworkProbe.linkMedia(device: device, runner: runner)
                if linkMedia[device] != media { linkMedia[device] = media }   // 딕셔너리 칸 대입은 같은 값이어도 알린다 — 바뀔 때만
                await sampleTraffic(device: device)
            }
            // 내부망이 실제로 통하는지: 게이트웨이 응답 (내부망 장치로만)
            if info.enabled, let router = info.router, let device = info.device {
                gatewayPing = await NetworkProbe.ping(router, device: device, runner: runner)
            } else {
                gatewayPing = nil
            }
            networkInfoAt = Date()
        case AppModel.wifiKey:
            wifi.requestLocationIfNeeded()
            if !inRound { wifi.refresh() }   // 라운드에선 refreshNow 가 방금 읽었다
            let service = NetworkInfoFetcher.serviceName(forDevice: wifi.info?.interface, in: inRound ? lanServices : await NetworkInfoFetcher.services(runner: runner))
            let getInfo = await runner.run("networksetup", ["-getinfo", service], timeout: 5).stdout
            var actual: String?
            if let device = wifi.info?.interface, wifi.info?.associated == true {
                actual = NetworkInfoFetcher.parseIfAddr(await runner.run("ipconfig", ["getifaddr", device], timeout: 5))
            }
            // 튜플은 비교가 안 돼 같은 값을 매 라운드 다시 쓰면 화면이 다시 그려진다 — 바뀔 때만
            let address = NetworkInfoFetcher.wifiAddress(getInfo: getInfo, actualIP: actual)
            if wifiAddress != address { wifiAddress = address }
            await refreshDefaultRoute()
            dnsConfig = await DNSConfig.fetch(runner: runner)
            // 링크(연결 속도)는 CoreWLAN 전송 속도 — ifconfig media 는 Wi-Fi 에서 autoselect 뿐이라 읽지 않는다
            if let device = wifi.info?.interface { await sampleTraffic(device: device) }
            // 인터넷 응답·공인 IP: Wi-Fi 장치로만 (기본 경로가 VPN·유선이어도 Wi-Fi 쪽 값). 응답은 15초, 공인 IP 는 5분에 한 번.
            if let device = wifi.info?.interface {
                if wifi.info?.associated == true {
                    await probeInternet(device: device)
                    fetchPublicIP(device: device)
                } else {
                    // 끊기면 이전 값을 지운다 (게이트웨이 ping 과 같은 규칙)
                    clearInternet(device: device)
                    wifiDetail = nil
                }
            }
            networkInfoAt = Date()
        case AppModel.ethernetKey:
            // 서비스 스냅숏 하나로 (어댑터·서비스 카드 공통). NIC 값(받기/보내기·공인 IP·인터넷 응답)은 그 서비스가 연결됨일 때만
            let before = Set((ethernet ?? []).map(\.device))
            if !inRound { await refreshServices() }   // 라운드에선 방금 읽었다
            await refreshDefaultRoute()
            dnsConfig = await DNSConfig.fetch(runner: runner)
            let adapters = ethernet ?? []
            let connectedDevices = Set(adapters.filter { $0.state == .connected }.map(\.device))
            for device in connectedDevices {
                await sampleTraffic(device: device)
                fetchPublicIP(device: device)
            }
            // 연결된 서비스가 없는 장치(뽑힘·주소 없음·게이트웨이 응답 없음)는 옛 공인 IP·속도를 지운다 — 같은 장치에 연결된 서비스가 있으면 두고
            for device in before.union(adapters.map(\.device)).subtracting(connectedDevices) { clearInternet(device: device) }
            // 인터넷 응답: 대표 어댑터로만 (기본 경로가 아니어도 그 유선의 응답) — Wi-Fi 화면과 같은 15초 간격
            if let primary = ethernetPrimary, primary.state == .connected { await probeInternet(device: primary.device) }
            networkInfoAt = Date()
        default:
            break
        }
    }

    /// 화면들의 "기본 경로" 한 줄: "Samsung Hub NIC (en8) · 192.168.0.1" — 장치를 이 Mac 의 서비스 이름으로 (this Mac 화면)
    var defaultRouteText: String {
        guard let route = defaultRoute, !route.isEmpty else { return "–" }
        let via = route.interface ?? "?"
        let name = serviceName(device: via).map { "\($0) (\(via))" } ?? via
        return route.gateway.map { "\(name) · \($0)" } ?? name
    }

    /// 장치의 서비스 이름: Wi-Fi · 유선(Ethernet 행) · 그 밖에 켜진 서비스 (VPN 의 utun 처럼 서비스에 장치가 없으면 nil)
    private func serviceName(device: String) -> String? {
        if device == wifi.info?.interface { return "Wi-Fi" }
        if let adapter = ethernet?.first(where: { $0.device == device }) { return adapter.service }
        return lanServices.first { $0.device == device && $0.enabled }?.name
    }

    /// Ethernet 행·타일의 대표 어댑터 (기본 경로 → 연결 → 링크 → 첫 번째)
    var ethernetPrimary: EthernetAdapter? {
        ethernet.flatMap { adapters in
            Ethernet.primary(adapters, internetService: adapters.first { carriesInternet($0.service) }?.service, defaultRoute: defaultRoute?.interface)
        }
    }

    /// 그 장치의 지난 카운터·속도·그래프를 지운다 (utun 번호를 다른 세션이 다시 쓸 때 · 직전 표본이 오래됐을 때)
    private func resetTraffic(device: String) {
        lastCounters[device] = nil
        trafficRates[device] = nil
        trafficHistory[device] = nil
    }

    /// 인터페이스 카운터를 한 번 읽어 직전 표본과의 차이로 초당 속도를 낸다. 직전 표본이 오래됐으면(화면을 떠나 있었음) 이어 계산하지 않는다.
    private func sampleTraffic(device: String) async {
        if let previous = lastCounters[device], !TrafficRate.continues(from: previous, at: Date(), interval: checkInterval) {
            resetTraffic(device: device)
        }
        guard let current = await NetworkProbe.counters(device: device, runner: runner) else { return }
        if let previous = lastCounters[device], let rate = TrafficRate.between(previous, current) {
            trafficRates[device] = rate
            var history = trafficHistory[device] ?? []
            history.append(rate)
            if history.count > 40 { history.removeFirst(history.count - 40) }
            trafficHistory[device] = history
        }
        lastCounters[device] = current
    }

    /// Wi-Fi 상세: 루트로 wdutil info 를 한 번 읽는다 (Touch ID 시트 → 안 되면 암호 창). 취소하면 아무 것도 바꾸지 않는다.
    func fetchWiFiDetail() {
        guard !wifiDetailLoading else { return }
        wifiDetailLoading = true
        Task {
            let result = await LanCommands.runPrivileged(WiFiDetail.script, runner: runner)
            wifiDetailLoading = false
            if let problem = PrivilegedOutcome(result).authProblem {
                statusMessage = "\(problem) · Wi-Fi 상세를 읽지 않았습니다."
                return
            }
            guard result.ok else {
                statusMessage = "Wi-Fi 상세를 읽지 못했습니다 · wdutil info 실패(종료 코드 \(result.exitCode))."
                return
            }
            let detail = WiFiDetail.parse(result.stdout)
            guard !detail.isEmpty else {
                statusMessage = "Wi-Fi 상세를 읽지 못했습니다 · wdutil info 출력에 WIFI 값이 없습니다."
                return
            }
            // 인증하는 사이 화면을 떠났거나 Wi-Fi 가 끊겼으면 버린다 (상세는 Wi-Fi 화면을 보는 동안만)
            guard selectedKey == AppModel.wifiKey, wifi.info?.associated == true else { return }
            wifiDetail = detail
        }
    }

    /// 인터넷 응답을 그 장치로만 잰다 (외부 요청이라 장치마다 15초에 한 번)
    private func probeInternet(device: String) async {
        if let at = lastProbeAt[device], Date().timeIntervalSince(at) < 15 { return }
        lastProbeAt[device] = Date()
        let epoch = internetEpoch[device, default: 0]
        let probe = await NetworkProbe.internetProbe(device: device, runner: runner)
        guard internetEpoch[device, default: 0] == epoch else { return }   // 재는 사이 끊겨 지워졌으면 버린다
        internetProbe[device] = probe
    }

    /// 장치가 끊기면 그 장치의 응답·공인 IP 를 지운다 — 다시 붙었을 때 옛 값이 보이지 않게
    private func clearInternet(device: String) {
        // 끊긴 채로 매 라운드 불리므로 이미 비어 있으면 건드리지 않는다 (칸에 nil 대입도 알린다)
        if internetProbe[device] != nil { internetProbe[device] = nil }
        lastProbeAt[device] = nil
        if publicIP[device] != nil { publicIP[device] = nil }
        publicIPAt[device] = nil
        if speedTest[device] != nil { speedTest[device] = nil }
        internetEpoch[device, default: 0] += 1
    }

    /// 공인 IP 와 위치를 요청 한 번으로 (ip-api.com). 그쪽이 안 되면 주소만이라도 (ipify). device "" = 기본 경로, 그 밖은 그 장치로만.
    /// 막힌 망이면 요청마다 연결 2초·전체 4초에서 끊는다.
    private func lookupPublicIP(device: String) async -> (ip: String, location: IPLocation?)? {
        let bound = device.isEmpty ? nil : device
        if let found = await IPLocate.selfLookup(device: bound, runner: runner) { return (found.ip, found.location) }
        return await NetworkProbe.publicIP(device: bound, runner: runner).map { ($0, nil) }
    }

    /// 공인 IP 조회 (+ 위치). device "" = 기본 경로, 그 밖은 그 장치로만 나가 본다. 자동 갱신은 5분에 한 번(실패해도 같은 간격),
    /// force 면 즉시 (버튼). 실패하면 이전 값을 유지한다.
    func fetchPublicIP(device: String = "", force: Bool = false) {
        guard !publicIPLoading.contains(device) else { return }
        if !force, let at = publicIPAt[device], Date().timeIntervalSince(at) < 300 { return }
        publicIPLoading.insert(device)
        let epoch = internetEpoch[device, default: 0]
        Task {
            let found = await lookupPublicIP(device: device)
            publicIPLoading.remove(device)
            guard internetEpoch[device, default: 0] == epoch else { return }   // 묻는 사이 끊겨 지워졌으면 버린다
            publicIPAt[device] = Date()
            if let found {
                publicIP[device] = found.ip
                if let location = found.location { publicIPLocation[found.ip] = location }
            }
            if found == nil, force { statusMessage = "공인 IP 를 가져오지 못했습니다." }
        }
    }

    /// VPN 화면의 공인 IP: 그 VPN 의 utun 으로만 나가 본 주소와 위치 (lookupPublicIP).
    /// 지정한 경로만 가는 VPN·막힌 망이면 실패. 자동은 5분에 한 번, force 면 즉시 (버튼).
    func fetchVPNPublicIP(device: String, owner: String, force: Bool = false) {
        if publicIPOwner[device] != owner {   // 같은 utun 을 다른 VPN 이 쓰게 됐다
            clearVPNPublicIP(device: device)
            publicIPOwner[device] = owner
        }
        guard !publicIPLoading.contains(device) else { return }
        if !force, let at = publicIPAt[device], Date().timeIntervalSince(at) < 300 { return }
        publicIPLoading.insert(device)
        let epoch = internetEpoch[device, default: 0]
        Task {
            let found = await lookupPublicIP(device: device)
            publicIPLoading.remove(device)
            guard internetEpoch[device, default: 0] == epoch else { return }   // 묻는 사이 끊겼거나 주인이 바뀌었으면 버린다
            publicIPAt[device] = Date()
            if let found {
                publicIP[device] = found.ip
                publicIPFailed.remove(device)
                if let location = found.location { publicIPLocation[found.ip] = location }
            } else {
                publicIP[device] = nil   // 실패는 옛 값을 남기지 않는다 — VPN 은 나가는 주소가 바뀌는 것이 곧 정보다
                publicIPFailed.insert(device)
            }
        }
    }

    /// 연결이 끊긴 VPN 이 쓰던 장치의 공인 IP 를 지운다 — 다시 연결하면 나가는 주소가 달라질 수 있다
    private func forgetVPNPublicIP(connected: Set<String>) {
        for (device, owner) in publicIPOwner where !connected.contains(owner) {
            clearVPNPublicIP(device: device)
            publicIPOwner[device] = nil
        }
    }

    private func clearVPNPublicIP(device: String) {
        if publicIP[device] != nil { publicIP[device] = nil }
        publicIPAt[device] = nil
        if publicIPFailed.contains(device) { publicIPFailed.remove(device) }
        internetEpoch[device, default: 0] += 1
    }

    /// 속도 측정 (networkQuality -s -M 3초 · 회선을 가득 채운다). 그 장치로만 잰다 (Wi-Fi 화면 = Wi-Fi, Ethernet 화면 = 대표 어댑터)
    func runSpeedTest(device: String) {
        guard speedTestDevice == nil else { return }
        guard runner.hasExecutable("networkQuality") else { statusMessage = "networkQuality 명령이 없습니다."; return }
        speedTestDevice = device
        speedTest[device] = nil
        Task {
            let result = await NetworkProbe.speedTest(device: device, runner: runner)
            speedTestDevice = nil
            speedTest[device] = result
            statusMessage = result.map { "속도 측정: \($0.text)" } ?? "속도 측정에 실패했습니다."
        }
    }

    func toggleWiFi() {
        guard let info = wifi.info else { statusMessage = "Wi-Fi 인터페이스가 없습니다."; return }
        do {
            try wifi.setPower(!info.powerOn)
            statusMessage = info.powerOn ? "Wi-Fi 껐습니다." : "Wi-Fi 켰습니다."
        } catch {
            statusMessage = "Wi-Fi 전원 변경 실패: \(error.localizedDescription)"
        }
        requestRefresh()
    }

    /// 시스템 설정 → 개인정보 보호 → 위치 서비스
    func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 망 켜기/끄기

    var tailscaleRunning: Bool { status.tailscale == .running }

    func toggleTailscale() {
        guard status.tailscale != .missing else { statusMessage = "tailscale 명령을 찾을 수 없습니다."; return }
        if tailscaleRunning {
            pendingConfirm = PendingConfirm(title: "Tailscale 끄기",
                                            message: "Tailscale 을 끄면 이 Mac 의 연결 전체가 해제됩니다. Tailscale 망의 모든 서버와 연결이 끊깁니다.") { [weak self] in
                self?.runTailscale("down")
            }
        } else {
            runTailscale("up")
        }
    }

    private func runTailscale(_ action: String) {
        // 끄기 확인 창이 떠 있는 사이 다른 작업이 시작됐으면 그 잠금을 덮지 않는다
        guard busyAction == nil else {
            statusMessage = "다른 작업 중이라 Tailscale 을 \(action == "up" ? "켜지" : "끄지") 못했습니다."
            return
        }
        busyAction = BusyAction(.tailscale, "tailscale \(action)")
        Task {
            let result = await runner.run("tailscale", [action], timeout: 30)
            await refreshLocalNow()   // 스피너가 사라질 때 이미 새 상태가 보이게
            busyAction = nil
            if result.ok {
                statusMessage = action == "up" ? "Tailscale 을 켰습니다." : "Tailscale 을 껐습니다."
            } else {
                queryResult = QueryResult(title: "tailscale \(action) · error", lines: RemoteCommands.cleanOutput(result.stdout + result.stderr, type: .linux), failed: true)
            }
        }
    }

    /// Intranet 켜기·끄기 = 지정한 서비스의 활성화·비활성화 (Ethernet 서비스 카드와 같은 함수 — setServiceEnabled).
    /// 인증은 Touch ID 또는 관리자 승인 창. 끄면 내부망 터널은 닫는다(setServiceEnabled).
    func toggleLan() {
        guard let lan = self.lan else { statusMessage = "내부망 설정([network:lan])이 없습니다."; return }
        let on = status.lan != .up
        let entry = lanServices.first { $0.name == lan.service }
            ?? LanServiceEntry(name: lan.service, hardwarePort: nil, device: nil, enabled: !on)
        setServiceEnabled(entry, on: on)
    }

    // MARK: 시스템 VPN

    /// 목록을 다시 읽는다. 읽기에 실패하면 이전 목록을 그대로 둔다 (행이 깜빡 사라지지 않게).
    /// 그 사이 더 늦게 시작한 읽기가 있으면 이 결과는 버린다 (5초 갱신과 켜기/끄기 뒤 읽기가 겹칠 때).
    /// reads: 갱신 라운드의 읽기 공유 (StatusMonitor 의 vpn 연결 확인과 scutil --nc list 한 번을 나눈다)
    func refreshVPNs(reads: (any CommandRunner)? = nil) async {
        if reads == nil { roundReads?.invalidate() }   // 켜기·끄기 뒤 읽기 — 도는 라운드가 그 전 목록을 나눠 쓰지 않게
        vpnGeneration += 1
        let generation = vpnGeneration
        guard let list = await SystemVPNs.list(runner: reads ?? runner), generation == vpnGeneration else { return }
        vpns = list
        forgetVPNPublicIP(connected: Set(list.filter { $0.state == .connected }.map(\.id)))
        vpnsReadAt = Date()
    }

    /// VPN 화면: 목록과 상세(주소·경로·DNS·통계)를 함께 읽는다. Invalid 는 읽을 게 없다.
    /// 목록은 5초 갱신이 방금(4초 안) 읽었으면 그걸 쓰고, VPN 마다 상세는 함께 읽는다. 바깥 장치는 망이 같으면 45초 (VPNEgressCache)
    func refreshVPNDetails() async {
        if vpnsReadAt.map({ Date().timeIntervalSince($0) >= 4 }) ?? true { await refreshVPNs() }
        let list = (vpns ?? []).filter { $0.state != .invalid }
        let runner = self.runner, cache = vpnEgressCache, network = egressNetworkKey
        let details = await withTaskGroup(of: (String, SystemVPNDetail).self) { group in
            for vpn in list {
                group.addTask { (vpn.id, await SystemVPNs.detail(vpn, runner: runner, egressCache: cache, network: network)) }
            }
            var out: [String: SystemVPNDetail] = [:]
            for await (id, detail) in group { out[id] = detail }
            return out
        }
        // 받기·보내기 속도 타일: 연결된 VPN 의 인터페이스(utunN) 카운터 — Wi-Fi·Ethernet 과 같은 표본
        for vpn in list where vpn.state == .connected {
            if let device = details[vpn.id]?.interface { await sampleTraffic(device: device) }
        }
        vpnDetails = details
    }

    /// 켜기/끄기: macOS 에 요청하고 상태가 바뀔 때까지 기다린다. 다른 VPN·망 동작은 막지 않는다.
    func toggleVPN(_ vpn: SystemVPN) {
        guard vpn.canToggle, !vpnBusy.contains(vpn.id) else { return }
        let on = !vpn.isOn
        vpnBusy.insert(vpn.id)
        Task {
            let error = await SystemVPNs.set(vpn, on: on, runner: runner)
            await refreshVPNs()
            vpnBusy.remove(vpn.id)
            statusMessage = error ?? "\(vpn.name) VPN 을 \(on ? "켰습니다" : "껐습니다")."
            requestRefresh()   // 경로가 바뀌어 서버 확인 결과가 달라질 수 있다
        }
    }
}
