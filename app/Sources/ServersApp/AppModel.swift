// 앱 상태의 저장 속성·설정 로딩·5초 주기 상태 갱신. 기능별 메서드는 AppModel+*.swift
// (Browse·Browser·Credentials·Diagnostics·Live·Local·Network·Notify·Proxy·Remote·Servers·Services·Tabs·TerminalPaste·Transfers·Tunnels).
// 규칙: 저장 속성은 이 파일에만 둔다. 뷰는 읽기만 하고, 쓰기는 AppModel 의 메서드를 거친다.

import AppKit
import Foundation
import GhosttyTerminal
import ServersCore
import SwiftUI

@MainActor
@Observable
final class AppModel {
    static let localKey = "__local__"
    /// 사이드바 NETWORK 행의 선택 키 (망 Dashboard)
    static let tailscaleKey = "__network_tailscale__"
    static let lanKey = "__network_lan__"
    static let wifiKey = "__network_wifi__"
    static let ethernetKey = "__network_ethernet__"
    /// 시스템 설정 VPN 모음 (Tailscale 아래 한 행)
    static let vpnKey = "__network_vpn__"
    /// 사이드바 LOCAL 의 이 Mac 모니터 행
    static let systemKey = "__local_system__"
    static let diskKey = "__local_disk__"
    static let bluetoothKey = "__local_bluetooth__"
    /// 서버가 아닌 고정 화면 (`--select` 이름 → 선택 키). servers.conf 를 다시 읽어도 이 키들은 선택이 풀리지 않는다 — 새 화면은 여기에만 더한다
    static let fixedScreens: [String: String] = [
        "local": localKey, "tailscale": tailscaleKey, "vpn": vpnKey, "lan": lanKey, "wifi": wifiKey, "ethernet": ethernetKey,
        "system": systemKey, "disk": diskKey, "bluetooth": bluetoothKey,
    ]

    let configPath: String
    let runner: any CommandRunner
    let libDir: String
    private(set) var config: ServerConfig?
    private(set) var configError: ConfigError?
    private(set) var status = StatusSnapshot()
    private(set) var isChecking = false
    private(set) var lastRefresh: Date?
    var selectedKey: String? {
        didSet {
            guard selectedKey != oldValue else { return }
            if oldValue == AppModel.wifiKey { wifiDetail = nil }   // 상세(루트로 읽은 값)는 그 화면을 보는 동안만
            refreshIdentityProblems()
            autoFetchSpecIfNeeded()
            Task { await fetchNetworkInfoIfSelected() }
        }
    }
    /// 망 Dashboard 정보 (그 화면을 보고 있을 때만 갱신 루프에서 함께 조회)
    var tailscaleInfo: TailscaleInfo?
    var lanInfo: LanInfo?
    /// LOCAL 화면: 이 Mac 의 Spec·주소·리스닝 포트 (그 화면을 볼 때만 갱신)
    var localInfo: LocalInfo?
    /// 패킷 캡처 창 (Window ▸ Packet Capture). 창이 닫혀 있으면 프로세스 없음
    let capture = PacketCaptureController()
    var networkInfoAt: Date?
    /// Wi-Fi: 전원·SSID·신호는 매 갱신마다(CoreWLAN, 즉시), IP·게이트웨이는 Wi-Fi 화면을 볼 때만 networksetup 으로
    let wifi = WiFiMonitor()
    /// 시스템 화면(CPU·메모리·GPU·온도·프로세스) 수집기 — 그 화면을 볼 때 3초마다, 사이드바 요약은 창이 보일 때 5초마다 (AppModel+Local)
    let system = SystemMonitor()
    /// 디스크 화면(볼륨·APFS·입출력) 수집기 — 같은 규칙 (AppModel+Local)
    let disk = DiskMonitor()
    /// 블루투스 화면(컨트롤러·기기·배터리) 수집기 — 화면 5초, 사이드바 요약 30초 (AppModel+Local)
    let bluetooth = BluetoothMonitor()
    var wifiAddress: (ip: String?, subnet: String?, router: String?, configuration: String?) = (nil, nil, nil, nil)
    /// 유선 서비스 스냅숏 — 서비스 순서·장치·서비스별 getinfo·게이트웨이 응답 (5초 갱신마다, nil = 아직 안 읽음).
    /// Ethernet 화면·서비스 카드·Intranet·사이드바가 모두 이것과 ServiceLink 판정 하나를 쓴다 (ServersCore WiredSnapshot)
    var wired: WiredSnapshot?
    /// 인터넷이 나가는 기본 경로 (인터페이스·게이트웨이)
    var defaultRoute: DefaultRoute?
    /// 인터넷이 나가는 서비스 (scutil PrimaryService). nil = 못 읽음 — carriesInternet 이 장치 기준으로
    var primaryService: PrimaryService?
    /// Ethernet 화면 [서비스 추가…] 입력창
    var serviceAddPrompt = false
    /// 활성화·비활성화 중이거나, 활성화 뒤 주소가 붙기를 기다리는 서비스 (행 스피너)
    var serviceSettling: Set<String> = []
    /// 인터페이스별 초당 속도 (netstat 카운터 차이)
    var trafficRates: [String: TrafficRate] = [:]
    /// 스파크라인용 최근 속도 (최대 40 표본)
    var trafficHistory: [String: [TrafficRate]] = [:]
    @ObservationIgnored var lastCounters: [String: InterfaceCounters] = [:]
    /// 링크 속도·상태 (ifconfig media)
    var linkMedia: [String: LinkMedia] = [:]
    /// 인터넷 응답 (204 엔드포인트 5회, 요청이 많아 장치마다 15초에 한 번) — 키는 재는 장치 (Wi-Fi·Ethernet 화면이 각자 자기 장치로만 잰다)
    var internetProbe: [String: PingSummary] = [:]
    @ObservationIgnored var lastProbeAt: [String: Date] = [:]
    /// 내부망 게이트웨이 ping
    var gatewayPing: PingSummary?
    /// 진단 카드 (Intranet·Wi-Fi·Ethernet·VPN 화면) — 키는 화면(lanKey·wifiKey·ethernetKey·vpnKey), 그 화면의 장치로만 보낸다 (diagnosticDevice).
    /// ping: 입력한 주소로 5회 → 이어서 경로. HTTP: 입력한 URL 로 요청 한 번 (리다이렉트는 따라가지 않음). 결과·실행 중은 DiagnosticState
    var diagnostics: [String: DiagnosticState] = [:]
    /// IEEE 배정 목록 (번들 oui.tsv, 처음 [Scan] 때 한 번 읽는다)
    static let ouiTable: OUITable? = OUITable.load(path: (Bundle.main.resourcePath ?? "") + "/oui.tsv")
    /// Wi-Fi 상세 (sudo wdutil info — [상세 보기] 를 눌러 인증할 때 한 번). 화면을 떠나거나 Wi-Fi 가 끊기면 지운다.
    var wifiDetail: WiFiDetail?
    var wifiDetailLoading = false
    /// DNS (scutil --dns, 루트 권한 필요 없음) — 이 Mac·Wi-Fi·Ethernet 화면을 볼 때 읽는다
    var dnsConfig: DNSConfig?
    /// 공인 IP — 키는 나가는 장치: "" = 기본 경로(이 Mac 화면), "en0" 등 = 그 장치로만(Wi-Fi 화면)
    var publicIP: [String: String] = [:]
    var publicIPLoading: Set<String> = []
    @ObservationIgnored var publicIPAt: [String: Date] = [:]
    /// 공인 IP 의 위치 (IP → 위치 — 공인 IP 를 물을 때 함께 받는다) · 조회에 실패한 장치 (VPN 화면만 — fetchVPNPublicIP)
    var publicIPLocation: [String: IPLocation] = [:]
    var publicIPFailed: Set<String> = []
    /// 그 장치 값의 주인(VPN id) — 같은 utun 이름을 다른 VPN 이 다시 쓰면 옛 값을 지운다
    @ObservationIgnored var publicIPOwner: [String: String] = [:]
    /// 장치 값을 지울 때마다 올린다 — 지우기 전에 시작한 응답·공인 IP 조회가 끝나서 옛 값을 되살리지 않게
    @ObservationIgnored var internetEpoch: [String: Int] = [:]
    /// 속도 측정 결과 — 키는 잰 장치 (Wi-Fi·Ethernet 화면이 각자 자기 장치로만)
    var speedTest: [String: SpeedTest] = [:]
    /// 지금 재는 장치 — 한 번에 하나만 (회선을 가득 채우므로)
    var speedTestDevice: String?
    var tabs: [TerminalTab] = []
    /// 소유자별로 마지막에 보던 탭. 서버를 떠났다 돌아와도 그 탭을 그대로 보여 준다.
    var activeTabByOwner: [String: UUID] = [:]
    /// 탭 대신 Dashboard(정보 화면)를 보는 소유자. 탭 막대 맨 왼쪽의 Dashboard 를 누르면 그 서버로 기억한다.
    var dashboardOwner: String?
    var tunnels: [TunnelSession] = []
    /// 최근 터널 (recent.json). 앱을 다시 켜도 남아 [열기] 로 다시 연다.
    var recent = RecentStore.load()
    /// 서버 주소 터널의 루프백 별칭 배정표 (hosts.json)
    var hostAliases = HostAliasStore.load()
    /// Services 탭 로그 조회 중인 "서버|유닛" (두 번 눌러 두 번 돌지 않게)
    @ObservationIgnored var serviceLogLoading: Set<String> = []
    /// 명령 모음 (snippets.json). 못 읽었으면 snippetsError 가 차고 추가·편집을 막는다 — 저장하면 그 파일을 덮는다 (아래 MARK: 명령 모음)
    private(set) var snippets = SnippetState()
    private(set) var snippetsError: ConfigError?
    /// 명령 모음 팝오버 (탭 막대 버튼 · ⌘P)
    var snippetsShown = false
    /// 빈칸 {{이름}} 에 마지막으로 넣은 값 (이름별, 앱이 켜져 있는 동안만) — 다음에 채워 둔다
    @ObservationIgnored private(set) var snippetValues: [String: String] = [:]
    var transfers: [TransferSession] = []
    var uploadPrompt: UploadPromptRequest?
    /// 계정별 마지막 업로드 폴더 (앱이 켜져 있는 동안, 키는 accountID). 업로드 창을 다시 열면 이걸로 채운다.
    @ObservationIgnored var lastUploadPath: [String: String] = [:]
    /// 계정별 로그인 홈 절대 경로 캐시 (키는 accountID — 업로드 기본 폴더를 절대 경로로 보이려고)
    @ObservationIgnored var remoteHomes: [String: String] = [:]
    var downloadPrompt: DownloadPromptRequest?
    /// key → query → 결과
    var remoteInfo: [String: [RemoteCommands.Query: RemoteInfoResult]] = [:]
    /// 원격 정보 카드에서 보고 있는 탭 (서버별)
    var infoTab: [String: RemoteCommands.Query] = [:]
    /// 서버별 "실시간" 탭 수집기 (그 탭을 처음 열 때 만든다 — AppModel+Live)
    @ObservationIgnored var liveMonitors: [String: ServerLiveMonitor] = [:]
    /// 오른쪽 아래 토스트 (StatusToast). 같은 글이 떠 있는 동안 또 오면 횟수만 올린다 (×2).
    var statusMessage: String? {
        didSet { statusRepeat = statusMessage != nil && statusMessage == oldValue ? statusRepeat + 1 : 1 }
    }
    private(set) var statusRepeat = 1
    /// 사이드바 검색칸에 포커스가 있다 — 그동안 Enter 는 검색(첫 결과 고르기)이지 SSH 기본 버튼이 아니다
    var sidebarSearchFocused = false
    var queryResult: QueryResult?
    var pendingConfirm: PendingConfirm?
    /// 서버별 비밀번호. passwords.bin 에 암호화해 두고(PasswordVault) 시작 시 읽는다. ssh 를 띄울 때 헬퍼에 넘겨 창 없이 대입한다.
    var passwords: [String: String] = [:]
    /// 서버별 키 파일 경로 (identities.json). config 의 Server.identityFile 로 붙어 모든 연결이 -i 로 쓴다.
    var identities: [String: String] = IdentityStore.load()
    /// 서버별로 고른 계정 ({서버 키: 계정}, extra_users 서버 · 기본 계정은 적지 않는다). 다시 켜도 유지 (UserDefaults). 탭·터널은 연 계정 그대로 — 새로 여는 것만 따른다.
    var activeAccounts: [String: String] = UserDefaults.standard.dictionary(forKey: AppPreferences.activeAccountsKey) as? [String: String] ?? [:]
    /// 등록한 키 파일의 문제 (없으면 키 없음 = 쓸 수 있음). 파일 I/O 라 그리기마다 읽지 않고 refreshIdentityProblems 가 채운다 —
    /// 시작·키 등록/지우기·목록 다시 읽기·화면 선택 바뀜·앱 활성화 때.
    private(set) var identityProblems: [String: IdentityFile.Problem] = [:]
    /// Moonlight·Chrome 설치 여부. 그리기마다 LaunchServices 를 묻지 않도록 시작·앱 활성화 때만 읽는다 (refreshInstalledApps).
    private(set) var moonlightInstalled = false
    private(set) var chromeInstalled = false
    /// passwords.bin 키 (로그인 키체인, 없으면 시작 때 만든다). 설정의 [키 새로 만들기]로 바뀐다.
    @ObservationIgnored var vaultKey: VaultKey
    let vaultKeyStore: VaultKeyStore = KeychainKeyStore()
    /// 내부망 서비스·대역 (lan.json). 파일이 없으면 servers.conf 값으로 만든다 (loadConfig). 못 읽으면 nil — servers.conf 값을 쓴다.
    var lanSettings: LanSettings?
    /// 고를 수 있는 네트워크 서비스 목록 (망 Dashboard 를 볼 때 읽는다)
    var lanServices: [LanServiceEntry] = []
    var tunnelPrompt: TunnelPromptRequest?
    /// 서버 추가 입력창 (servers.conf 에 블록을 붙인다)
    var addServerPrompt: AddServerRequest?
    /// 서버별 액션(tunnel_ports·proxy_port·wol_*) 편집 시트
    var actionsEditor: Server?
    /// 서버 기본 항목 편집 시트
    var serverEditor: Server?
    /// 터널 정보 시트 (사이드바 행 클릭 · 터널 카드 [정보])
    var tunnelInfo: TunnelSession?
    /// 전송 정보 시트 (TRANSFERS 행 클릭)
    var transferInfo: TransferSession?
    var busyAction: BusyAction?
    /// 앱 업데이트 띠 (사이드바 아래 UpdateBanner). 새 버전이 없으면 .none — 값은 AppUpdater 가 Sparkle 알림을 옮겨 넣는다
    var appUpdate: AppUpdate = .none
    @ObservationIgnored var updater: AppUpdater?
    /// 시스템 설정의 VPN (scutil --nc, Tailscale 제외). nil = 아직 못 읽음 ("없음"과 구분) · 켜고 끄는 중인 VPN UUID
    var vpns: [SystemVPN]?
    var vpnBusy: Set<String> = []
    /// VPN 화면을 볼 때 읽는 상세 (UUID → 상세)
    var vpnDetails: [String: SystemVPNDetail] = [:]
    /// 목록 읽기 세대 — 늦게 끝난 옛 읽기가 새 상태를 덮지 않게
    @ObservationIgnored var vpnGeneration = 0
    /// 목록을 마지막으로 읽은 시각 — VPN 화면 루프가 방금 읽은 목록을 다시 읽지 않게 (refreshVPNDetails)
    @ObservationIgnored var vpnsReadAt: Date?
    /// 시스템 VPN 바깥 장치(ps·nettop·route) — 망이 같으면 45초 (VPN 화면·this Mac Routes 공통)
    let vpnEgressCache = VPNEgressCache()
    /// 유선 스냅숏 읽기 세대 — 5초 갱신과 활성화 뒤 읽기가 겹칠 때 먼저 시작한 쪽이 나중에 덮지 않게 (refreshServices)
    @ObservationIgnored var servicesGeneration = 0
    /// 수동 IP 서비스의 게이트웨이 응답 (ping·ARP) — 같은 IP·게이트웨이면 15초
    let gatewayCache = GatewayCache()
    /// this Mac 화면 읽기 (Spec 한 번 · 느린 값 30초 — ServersCore LocalInfoCollector) · 진행 중인 읽기 (화면을 열 때 두 번 돌지 않게)
    let localCollector = LocalInfoCollector()
    @ObservationIgnored var localInfoTask: Task<Void, Never>?
    /// 창이 가려져 있어 지난 갱신이 화면 정보를 건너뛰었다 — 창이 다시 보이면 바로 한 바퀴 (installVisibilityObserver)
    @ObservationIgnored var screenFetchSkipped = false
    /// 지금 도는 갱신 라운드의 읽기 공유 — 라운드 도중 켜기·끄기 뒤의 읽기가 그 전 답을 나눠 받지 않게 비운다 (refreshServices·refreshVPNs·refreshLocalNow)
    @ObservationIgnored var roundReads: SharedReads?
    /// Tailscale SSH 브라우저 인증 중인 ssh (배너 URL 을 열고 확인이 끝날 때까지 연결을 쥔다)
    @ObservationIgnored var tailscaleLoginProcess: TunnelProcess?
    /// notify=on 서버의 켜짐·꺼짐 판정 (AppModel+Notify)
    @ObservationIgnored var powerWatch = PowerWatch()
    @ObservationIgnored var notifyAuthRequested = false

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshRequested = false
    /// 라운드 사이의 대기 — requestRefresh 가 취소해 바로 깨운다
    @ObservationIgnored private var refreshWait: Task<Void, Never>?
    /// 망을 켜고 끈 뒤 올린다. 그 전에 시작한 갱신은 토글 전 상태를 읽었으므로 결과를 버린다 (refreshNow).
    @ObservationIgnored private var refreshGeneration = 0
    /// 설정 창의 "서버 상태 확인" (기본 5초). 루프가 기다릴 때마다 읽으므로 바꾸면 다음 대기부터 반영된다.
    var checkInterval: TimeInterval { AppSettings.interval(AppPreferences.statusInterval) }
    /// `--run <명령>` 을 시작 시 한 번만 열기 위한 표시 (AppModel+Tabs)
    @ObservationIgnored var launchCommandOpened = false

    /// 지정 경로(`--conf <경로>` · 환경변수 SERVERS_CONF, 테스트용). 없으면 nil — 앱 저장소의 servers.conf (ConfigLocation)
    static var configOverride: String? {
        ConfigLocation.override(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)
    }

    init(configPath: String? = AppModel.configOverride, runner: any CommandRunner = ProcessRunner()) {
        // 기본 경로는 없으면 만든다 (옛 ~/.config/servers 에 있으면 복사). 지정 경로는 만들지 않는다.
        var prepared: Result<ConfigLocation.Prepared, ConfigError>?
        if configPath == nil {
            do { prepared = .success(try ConfigLocation.prepare(path: ConfigLocation.defaultPath, legacy: ConfigLocation.legacyPath)) }
            catch { prepared = .failure(error as? ConfigError ?? ConfigError(problem: "\(error)", fix: "", reference: ConfigLocation.defaultPath)) }
        }
        self.configPath = configPath ?? ConfigLocation.defaultPath
        self.runner = runner
        vaultKey = PasswordVault.resolveKey(store: vaultKeyStore)
        let vault = PasswordVault.load(key: vaultKey)
        passwords = vault.passwords
        // lan.zsh·hosts.zsh 는 번들 Resources/lib 에 넣는다 (Makefile)
        libDir = (Bundle.main.resourcePath ?? "") + "/lib"
        loadConfig()
        refreshInstalledApps()
        if vault.needsResave { savePasswords() }   // 옛 고정 키 파일 → 키체인 키로 다시 쓴다
        switch prepared {
        case .success(.copied(let from)): statusMessage = "서버 목록을 \(from) 에서 \(self.configPath) 로 복사했습니다."
        case .failure(let error): configError = error
        default: break
        }
        restoreRecentTunnels()
        do { snippets = try SnippetStore.load() } catch { snippetsError = error as? ConfigError }
        // `--select <키>` 로 시작 화면을 고정할 수 있다 (스크린샷·검증용). wifi/ethernet/tailscale/lan 은 NETWORK 행.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--select"), args.indices.contains(i + 1) {
            let name = args[i + 1]
            if let key = AppModel.fixedScreens[name] { selectedKey = key } else if config?.server(name) != nil { selectedKey = name }
        }
    }

    /// 이전 실행의 터널(recent.json)을 닫힌 항목으로 목록에 올린다. 사이드바 TUNNELS·터널 카드에서 다시 연결한다.
    func restoreRecentTunnels() {
        guard let config else { return }
        for item in recent.tunnels where tunnels.allSatisfy({ !$0.matches(item) }) {
            guard let server = config.server(item.serverKey)?.account(item.user) else { continue }
            let session = TunnelSession(spec: TunnelSpec(server: server, kind: item.kind, localPort: item.localPort,
                                                         bindAddress: item.bindAddress, hostName: item.hostName))
            session.state = .idle
            tunnels.append(session)
        }
    }

    /// 다시 읽기에 실패하면 이전 설정을 유지하고 오류만 보여준다. 목록에서 사라진 서버의 탭은 닫는다.
    func loadConfig() {
        do {
            let loaded = try ServerConfigParser.load(path: configPath).applyingAccounts(activeAccounts)
            // 접속 정보가 바뀐 서버의 원격 정보 캐시는 버린다 (같은 키로 다른 서버를 가리킬 수 있다). 액션 줄(tunnel_ports 등)만 바뀐 건 두고.
            // 무엇을 버릴지는 ServersCore ConfigReloadChanges — 여기는 적용만
            var connectionChanged = false
            if let old = config {
                let changes = ConfigReloadChanges.between(old: old, loaded: loaded)
                for before in changes.connectionChanged {
                    let key = before.key
                    remoteInfo[key] = nil
                    liveMonitors[key] = nil   // 다른 서버의 값과 이어 계산하지 않게
                    powerWatch.forget(key)   // 다른 서버의 켜짐·꺼짐으로 알리지 않게
                    // 옛 주소의 상태·캐시 (인증 필요 URL·원격 홈·마지막 업로드 폴더)
                    status.remote[key] = nil
                    for name in before.accounts { remoteHomes[before.accountID(for: name)] = nil; lastUploadPath[before.accountID(for: name)] = nil }
                    // 옛 주소로 열린 터널(브라우저·Chrome 프록시 포함)은 끊는다. 목록에 닫힌 채 남고 [다시 연결]은 새 설정으로 (reconnectTunnel)
                    for session in tunnels where session.isActive && session.spec.server.key == key {
                        session.stopReason = "접속 정보 바뀜"
                        session.process.stop()
                    }
                }
                connectionChanged = !changes.connectionChanged.isEmpty
                // 고른 계정이 목록에서 빠져 기본 계정으로 돌아왔다 — 원격 정보만 새 계정으로
                for key in changes.accountChanged {
                    remoteInfo[key] = nil
                    liveMonitors[key] = nil
                }
                // 목록에서 사라진 서버의 키별 상태 (같은 키로 다시 추가했을 때 옛 상태가 보이지 않게)
                for key in changes.removed {
                    remoteInfo[key] = nil; infoTab[key] = nil; powerPendings[key] = nil; liveMonitors[key] = nil
                    activeTabByOwner[key] = nil; status.remote[key] = nil
                    if activeAccounts.removeValue(forKey: key) != nil { saveActiveAccounts() }
                }
                // 지금 도는 갱신은 옛 목록으로 확인 중이다 — 끝나면서 위에서 지운 상태(옛 주소·사라진 서버)를 되살리지 않게 버린다 (refreshNow)
                if changes.discardsRunningRefresh { refreshGeneration += 1 }
                // 계정 순서가 바뀌었으면(편집·파일 직접 수정) 비밀번호·키 파일을 계정을 따라 옮긴다
                let rekeyedPasswords = ServerConfigEditor.rekeyingCredentials(passwords, from: old, to: loaded)
                if rekeyedPasswords != passwords { passwords = rekeyedPasswords; savePasswords() }
                let rekeyedIdentities = ServerConfigEditor.rekeyingCredentials(identities, from: old, to: loaded)
                if rekeyedIdentities != identities { identities = rekeyedIdentities; saveIdentities() }
            }
            config = loaded.applyingIdentities(identities)
            configError = nil
            if connectionChanged { refreshBrowserScopes() }
            loadLanSettingsIfNeeded()
            let removed = tabs.filter { tab in tab.server.map { loaded.server($0.key) == nil } ?? false }
            for tab in removed { closeTab(tab.id) }
            let kept = passwords.filter { loaded.ownsCredential($0.key) }   // 추가 계정의 값(키@계정)도 지우지 않게
            if kept != passwords { passwords = kept; savePasswords() }
            let keptIdentities = identities.filter { loaded.ownsCredential($0.key) }
            if keptIdentities != identities { identities = keptIdentities; saveIdentities() }
            if selectedKey.map({ !AppModel.fixedScreens.values.contains($0) && loaded.server($0) == nil }) ?? true {
                selectedKey = loaded.servers.first?.key
            }
            refreshIdentityProblems()
        } catch let error as ConfigError {
            configError = error
        } catch {
            configError = ConfigError(problem: "\(error)", fix: "servers.conf 를 확인하세요.", reference: configPath)
        }
    }

    /// identities 를 지금 목록에 다시 붙인다 (키 파일 등록·지우기 — servers.conf 는 다시 읽지 않는다)
    func applyIdentities() {
        config = config?.applyingIdentities(identities)
        refreshIdentityProblems()
    }

    /// 고른 계정을 지금 목록에 다시 적용한다 (사용자 칸 — servers.conf 는 다시 읽지 않는다)
    func applyActiveAccounts() {
        config = config?.applyingAccounts(activeAccounts)
        refreshIdentityProblems()
    }

    /// 등록된 키 파일을 검사해 identityProblems 를 채운다. 통째로 대입하므로 같은 값이면 화면을 다시 그리지 않는다.
    func refreshIdentityProblems() {
        var problems: [String: IdentityFile.Problem] = [:]
        for server in config?.servers ?? [] {
            if let path = server.identityFile, let problem = IdentityFile.check(path: path) { problems[server.key] = problem }
        }
        identityProblems = problems
    }

    /// 설치 여부를 다시 읽는다 (같은 값이면 알리지 않는다)
    func refreshInstalledApps() {
        let workspace = NSWorkspace.shared
        moonlightInstalled = workspace.urlForApplication(withBundleIdentifier: Self.moonlightBundleID) != nil
        chromeInstalled = workspace.urlForApplication(withBundleIdentifier: ChromeProxy.bundleID) != nil
    }

    /// 앱이 활성화될 때 밖에서 바뀐 것(키 파일 권한·Moonlight/Chrome 설치)을 다시 읽는다
    func installActivationObserver() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshIdentityProblems()
                self?.refreshInstalledApps()
            }
        }
    }

    // MARK: 상태 갱신

    func startMonitoring() {
        guard refreshTask == nil else { return }
        installWakeObserver()
        installVisibilityObserver()
        installActivationObserver()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshNow()
                await self?.waitForNextRound()
            }
        }
    }

    /// 다음 라운드까지 checkInterval 만큼 잔다 (설정을 바꾸면 다음 대기부터). 그 사이 requestRefresh 가 오면 바로 깬다 — 250ms 마다 깨어 보지 않게.
    /// 라운드 도중에 온 요청은 대기 없이 바로 다음 라운드로.
    private func waitForNextRound() async {
        guard !refreshRequested else { return }
        let interval = checkInterval
        let wait = Task { _ = try? await Task.sleep(for: .seconds(interval)) }
        refreshWait = wait
        await wait.value
        refreshWait = nil
    }

    func requestRefresh() {
        refreshRequested = true
        refreshWait?.cancel()
    }

    /// Tailscale 인증을 마친 뒤: "인증 필요" 상태를 지워 다음 갱신이 60초 대기 없이 바로 다시 확인하게 한다.
    func clearAuthNeeded() {
        refreshGeneration += 1   // 진행 중인 갱신은 옛 "인증 필요" 를 다시 쓰므로 버린다
        for (key, state) in status.remote where state.needsAuth { status.remote[key] = .pending }
        requestRefresh()
    }

    func refreshNow() async {
        refreshRequested = false
        guard let config, !isChecking else { return }
        isChecking = true
        let generation = refreshGeneration
        // 이 라운드의 읽기 공유: 서비스 목록·ifconfig·scutil --nc list 등은 StatusMonitor·VPN·유선 스냅숏·화면이 한 번 읽은 걸 나눠 쓴다
        let reads = SharedReads(runner)
        roundReads = reads
        defer { if roundReads === reads { roundReads = nil } }
        let monitor = StatusMonitor(config: config.replacingLan(lan), runner: reads)
        let previous = status
        // 서버 확인과 이 Mac 읽기를 함께 돈다 — 화면 값이 가장 느린 서버(타임아웃)를 기다리지 않게
        async let checked = monitor.refresh(previous: previous) { [weak self] partial in
            await self?.applyRefreshProgress(partial, generation: generation)
        }
        wifi.refresh()
        await refreshVPNs(reads: reads)
        await refreshServices(reads: reads)   // 유선 서비스 스냅숏 — Ethernet·Intranet·서비스 카드·사이드바 공통
        // 선택한 화면의 정보는 창이 보일 때만 (가려져 있으면 다시 보일 때 바로 한 바퀴 — installVisibilityObserver)
        screenFetchSkipped = !Self.mainWindowVisible
        if !screenFetchSkipped { await fetchNetworkInfoIfSelected(round: reads) }
        let next = await checked
        isChecking = false
        // 확인하는 사이 망을 켜고 껐으면(refreshLocalNow) 이 결과는 낡았다. 버리고 다시 돈다.
        guard generation == refreshGeneration else { requestRefresh(); return }
        status = next
        lastRefresh = Date()
        // 전원 대기·알림은 라운드 끝에서 한 번 (PowerWatch 가 라운드 횟수를 센다)
        settlePowerPendings()
        refreshIdentityProblems()   // 키 파일 권한을 앱 안 터미널에서 고쳐도(활성화 알림 없음) 다음 라운드에 반영 — 키를 등록한 서버마다 파일 머리 200바이트 읽기 + 속성 조회
        notifyPowerChanges()
        autoFetchSpecIfNeeded()
        await sampleLocalSummaries()
    }

    /// 갱신 도중: 먼저 끝난 서버 결과부터 목록에 보인다. 알림·전원 대기 판정은 라운드 끝(refreshNow)에서 한 번만 — PowerWatch 가 라운드 횟수를 센다.
    private func applyRefreshProgress(_ partial: StatusSnapshot, generation: Int) {
        guard generation == refreshGeneration else { return }   // 망을 켜고 끈 뒤의 낡은 결과
        status = partial
    }

    /// 망을 켜고 끈 직후: 이 Mac 의 로컬 상태(tailscale·networksetup)만 바로 다시 읽어 반영한다 (0.5초 안쪽).
    /// 서버 확인까지 기다리면 그동안 낡은 "켜기·비활성" 이 보인다. 원격 확인은 requestRefresh 로 이어서 돈다.
    func refreshLocalNow() async {
        guard let config else { return }
        refreshGeneration += 1
        roundReads?.invalidate()
        var fresh = StatusSnapshot()
        await StatusMonitor(config: config.replacingLan(lan), runner: runner).collectLocal(into: &fresh)
        // 기다리는 사이 다른 갱신이 원격 결과를 썼을 수 있으니 로컬 필드만 덮는다
        var merged = status
        merged.tailscale = fresh.tailscale
        merged.tailscaleChecked = fresh.tailscaleChecked
        merged.peers = fresh.peers
        merged.lan = fresh.lan
        merged.lanAdapterPresent = fresh.lanAdapterPresent
        merged.lanDevice = fresh.lanDevice   // lan 연결을 묶을 장치 — 켠 직후 여는 SSH 탭·터널이 바로 쓴다
        merged.vpnLinks = fresh.vpnLinks     // vpn 연결을 묶을 utun
        status = merged
        requestRefresh()
    }

    // MARK: 서버 조회

    /// 망 표시 이름. NETWORK 섹션·그룹 배지·Dashboard·접속 카드가 모두 이 이름을 쓴다.
    /// 내부망은 역할 이름으로 고정한다 — 서비스(프리셋) 이름은 앱에서 바꿀 수 있어 부제로만 보인다.
    func networkName(_ network: ServerNetwork) -> String {
        switch network {
        case .tailscale: return "Tailscale VPN"
        case .lan: return "Intranet"
        case .vpn: return "VPN"
        case .direct: return "Direct"
        }
    }

    var selectedServer: Server? {
        guard let selectedKey, selectedKey != AppModel.localKey else { return nil }
        return config?.server(selectedKey)
    }

    /// 그 서버를 사이드바에서 고른 것처럼 (망 화면의 서버 목록)
    func select(_ server: Server) {
        selectedKey = server.key
    }

    func isReachable(_ server: Server) -> Bool {
        status.allowsConnection(to: server)   // 판정은 ServersCore (ActionAvailability)
    }

    /// 깨우기 경로를 고를 때마다 올린다. 경로는 UserDefaults 라 관찰에 안 잡히므로, wakeRoute 를 읽는 화면은 이 값을 함께 읽어 다시 그린다.
    private var wakeRouteRevision = 0

    /// 설정 창에서 고른 깨우기 경로 (고른 적 없으면 wol_via 의 첫 경로)
    func wakeRoute(_ server: Server) -> WakeRoute? {
        _ = wakeRouteRevision
        guard server.wolMac != nil else { return nil }
        return AppPreferences.wakeRoute(server.wolRoutes, stored: UserDefaults.standard.string(forKey: AppPreferences.wakeRouteKey(for: server.key)))
    }

    /// 설정 창에서 깨우기 경로를 고른다. 화면(Boot 도움말·정보 줄)이 바로 바뀌게 알린다.
    func setWakeRoute(_ via: String, for server: Server) {
        UserDefaults.standard.set(via, forKey: AppPreferences.wakeRouteKey(for: server.key))
        wakeRouteRevision += 1
    }

    /// 깨워 줄 서버. 화면에서 고른 계정이 아니라 기본 계정으로 실행한다 — 다른 계정을 골라 뒀다고 etherwake 권한이 사라지면 안 된다
    func wakeVia(_ server: Server) -> Server? {
        wakeRoute(server).flatMap { config?.server($0.via) }.map { $0.account($0.primaryUser) }
    }

    /// Wake 는 서버가 꺼져 있을 때(닿지 않을 때)만, Shutdown 은 켜져 있을 때(닿을 때)만. 둘 중 하나만 활성이다.
    func canWake(_ server: Server) -> Bool {
        status.canWake(server, via: wakeVia(server), idle: busyAction == nil && powerPending(server) == nil)
    }

    func canShutdown(_ server: Server) -> Bool {
        status.canShutdown(server, idle: busyAction == nil && powerPending(server) == nil)
    }

    /// 전원 요청 뒤 대기: 30초 동안 같은 서버의 전원 버튼을 막고, 상태가 바뀌면(켜짐/꺼짐 확인) 먼저 푼다.
    struct PowerPending: Equatable {
        typealias Kind = PowerRequest   // 풀지 말지 판정은 ServersCore (PowerRequest.settles)
        let kind: Kind
        let until: Date
    }
    static let powerCooldown: TimeInterval = 30
    var powerPendings: [String: PowerPending] = [:]

    /// 전원 요청을 보낸 뒤: 대기를 걸고, 끝나는 시각에 맞춰 한 번 푼다 (라운드 끝 settlePowerPendings 를 기다리면 "0초" 가 남는다)
    func startPowerPending(_ key: String, _ kind: PowerPending.Kind) {
        let pending = PowerPending(kind: kind, until: Date().addingTimeInterval(Self.powerCooldown))
        powerPendings[key] = pending
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.powerCooldown))
            guard let self, self.powerPendings[key] == pending else { return }   // 그 사이 풀렸거나 새 요청이면 그대로
            self.powerPendings[key] = nil
        }
    }

    func powerPending(_ server: Server) -> PowerPending? {
        guard let pending = powerPendings[server.key], pending.until > Date() else { return nil }
        return pending
    }

    /// 상태 갱신 뒤: 부팅 요청은 닿기 시작하면, 종료 요청은 안 닿기 시작하면 대기를 끝낸다. 시간이 지난 것도 지운다.
    private func settlePowerPendings() {
        let now = Date()
        for (key, pending) in powerPendings where pending.kind.settles(reachable: status.remote(key).isReachable, until: pending.until, now: now) {
            powerPendings[key] = nil
        }
    }

    func canQuery(_ server: Server, _ query: RemoteCommands.Query) -> Bool {
        RemoteCommands.query(query, for: server.type) != nil
    }

    // MARK: 클립보드

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "복사됨: \(text.prefix(60))"
    }

    // MARK: 명령 모음

    /// 명령 모음이 입력할 터미널: 선택한 서버(또는 이 Mac)의 보이는 탭이 살아 있는 터미널일 때만 (Dashboard·브라우저 탭이면 nil)
    var visibleTerminal: TerminalViewState? {
        guard let tab = visibleTab, tab.isAlive, case let .terminal(terminal) = tab.content else { return nil }
        return terminal
    }

    /// 보이는 터미널에 붙여 넣는다. 붙여 넣기 모드라 Enter 전엔 실행되지 않고, 바로 실행이면 Enter 까지 보낸다.
    func typeSnippet(_ snippet: CommandSnippet) {
        // 한글 조합 중인 글자가 남아 있으면 명령 뒤에 붙어 같이 실행된다 ("uptimeㅎ") — 버리고 붙인다 (pasteDiscardingMarkedText)
        guard let terminal = visibleTerminal, pasteDiscardingMarkedText(snippet.command, into: terminal) else {
            statusMessage = "터미널에 입력하지 못했습니다. 우클릭 ▸ 복사로 붙여 넣으세요."
            return
        }
        if snippet.runImmediately { terminal.attachedPlatformView?.sendKey(.enter) }
        terminal.requestFocus()
    }

    /// ⌘P · 탭 막대 버튼. 버튼이 있는 곳(서버·이 Mac 로컬 셸의 탭 막대)에서만 연다.
    func toggleSnippets() {
        guard selectedServer != nil || selectedKey == AppModel.localKey, !tabsForSelected.isEmpty else { snippetsShown = false; return }
        snippetsShown.toggle()
    }

    func closeSnippets() {
        if snippetsShown { snippetsShown = false }
    }

    func rememberSnippetValues(_ values: [String: String]) {
        snippetValues.merge(values) { _, new in new }
    }

    /// 추가·편집 저장. 명령이 비었거나 파일을 못 읽은 상태면 false (편집기는 저장 버튼을 비활성으로 둔다).
    @discardableResult
    func saveSnippet(_ snippet: CommandSnippet) -> Bool {
        guard snippetsError == nil, let clean = SnippetStore.normalized(snippet) else { return false }
        return writeSnippets(SnippetStore.upsert(clean, in: snippets))
    }

    func deleteSnippet(_ id: UUID) {
        guard snippetsError == nil else { return }
        writeSnippets(SnippetStore.remove(id: id, from: snippets))
    }

    @discardableResult
    private func writeSnippets(_ next: SnippetState) -> Bool {
        do {
            try SnippetStore.save(next)
            snippets = next
            return true
        } catch {
            statusMessage = "명령 모음 저장 실패: \(error.localizedDescription) · \(SnippetStore.defaultURL.path)"
            return false
        }
    }
}

/// 진행 중인 관리자·원격 작업 (한 번에 하나 — 끝날 때까지 다른 작업을 막는다). 망 스위치·서비스 칸의 스피너는 kind 로 가르고, text 는 그대로 보인다.
struct BusyAction: Equatable {
    enum Kind { case tailscale, lan, service, other }
    let kind: Kind
    let text: String

    init(_ kind: Kind, _ text: String) {
        self.kind = kind; self.text = text
    }

    init(_ text: String) { self.init(.other, text) }
}
