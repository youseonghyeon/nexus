// 앱 안 브라우저 탭 하나 (WKWebView) — 그 서버에서 브라우저를 켠 것처럼: 모든 요청이 앱 안 SOCKS 중계(SocksRelay)를 거쳐 그 서버의 ssh -D 로 간다.
//   프록시: 데이터 스토어의 proxyConfigurations 를 127.0.0.1:<중계 포트> 로. 이름 풀이는 서버가 한다. 막는 주소는 없다.
//   루프백(127.0.0.1·localhost): WebKit 이 프록시에 안 보내므로 별칭 이름으로 바꿔 열고 주소창엔 원래 주소를 보인다 (BrowserPolicy 머리 주석).
//   쿠키·로그인: 서버별 영구 데이터 스토어 (재실행해도 유지). 다운로드는 ~/Downloads. 파일 선택·alert/confirm/prompt 도 받는다.
//   로그인 저장·채우기: 페이지와 분리된 영역에서 폼을 읽고 채운다 (ServersCore LoginForms · 저장은 NoteVault — 아래 MARK: 로그인).

import AppKit
import Network
import ServersCore
import WebKit

@MainActor
final class BrowserSession: NSObject, ObservableObject {
    let server: Server
    /// 그 서버로 연 ssh -D 포트 (중계의 상류)
    let socksPort: Int
    let webView: WKWebView
    private let onStatus: @MainActor (String) -> Void
    /// 시작 페이지 HTML (서버·열린 포트 — 모델이 지금 값으로 만들어 준다, ServersCore BrowserStartPage)
    private let startPage: @MainActor () -> String
    /// 시작 페이지의 포트 부분만 (포트 목록·웹 확인이 올 때 갈아 끼운다)
    private let startPorts: @MainActor () -> String
    /// 시작 페이지를 띄웠다 — 모델이 웹 확인을 시작한다 (아직 안 했으면)
    private let onStartShown: @MainActor () -> Void
    /// 시작 페이지에서 ↻ 를 눌렀다 — 모델이 포트 목록을 다시 읽는다
    private let onStartReload: @MainActor () -> Void
    /// 즐겨찾기(서버별 — 모델이 들고 있다)로 가는 길: 시작 페이지의 즐겨찾기 부분 · 이 주소가 들어 있는가 · 넣기/빼기(주소·제목·아이콘) · 빼기(주소)
    struct BookmarkHooks {
        let startHTML: @MainActor () -> String
        let contains: @MainActor (URL) -> Bool
        let toggle: @MainActor (URL, String, String?) -> Void
        let remove: @MainActor (String) -> Void
    }
    private let bookmarks: BookmarkHooks
    /// 메모·로그인(서버별 — 모델이 들고 있다)으로 가는 길: 잡은 로그인을 물을지(주소·ID·비밀번호) · 저장 · 그 주소에 저장해 둔 로그인
    struct LoginHooks {
        let captured: @MainActor (URL, String, String) -> NoteVault.Capture
        let save: @MainActor (SecretNote) -> Void
        let saved: @MainActor (String) -> [SecretNote]
    }
    private let logins: LoginHooks
    /// 웹 화면 오른쪽 위 카드로 묻는 중인 로그인 (새로 저장 · 저장한 것의 비밀번호 바꾸기). site 는 잡은 페이지의 주소
    struct LoginOffer: Equatable {
        let note: SecretNote
        let isUpdate: Bool
        let site: String
    }
    @Published private(set) var loginOffer: LoginOffer?
    /// 로그인 칸에 포커스가 있고 이 주소에 저장해 둔 로그인이 있다 — 그 칸 아래에 목록을 띄운다 (BrowserOverlays). field 는 웹 화면 안의 칸 자리
    struct FillPrompt: Equatable {
        let field: LoginForms.Rect
        let logins: [SecretNote]
    }
    @Published private(set) var fillPrompt: FillPrompt?
    /// 목록 위에 마우스가 있다 — 그동안 온 blur 는 미룬다 (목록을 누르는 사이 칸이 포커스를 잃어도 누르기 전에 사라지지 않게)
    private var fillPromptHovered = false
    private var fillBlurPending = false
    /// 채운 직후: 채우면서 준 포커스로 목록이 다시 뜨지 않게 잠깐 막는다
    private var fillQuietUntil = Date.distantPast
    /// 페이지에서 잡아 둔 로그인 — 로그인이 된 것 같을 때(비밀번호 칸이 사라짐) 묻는다
    private var loginCandidate: (address: URL, username: String, password: String, at: Date)?
    /// 이 탭에서 [나중에] 한 것 (잡은 주소 + ID) — 탭을 닫을 때까지 다시 묻지 않는다
    private var declinedLogins: Set<String> = []
    private let loginWorld = WKContentWorld.world(name: LoginForms.world)
    /// 지금 시작 페이지를 보고 있는가 (포트 목록이 오면 다시 그린다 · 주소창은 비운다)
    private(set) var showingStart = false { didSet { if !showingStart { startPending = false }; updateCanGoBack() } }
    /// 시작 페이지 자리(빈 문서)로 가는 중 — 다 뜨면 그 위에 시작 페이지를 그린다 (openStart · 뒤로/앞으로 돌아온 빈 문서)
    private var startPending = false
    /// 시작 페이지를 한 번이라도 띄웠는가 (프록시 연결 중에는 뒤로 갈 곳이 없다)
    private var started = false

    /// 뒤로: 기록에 앞 항목이 있으면 간다 (시작 페이지도 기록의 한 항목 — openStart). 앞 항목이 없어도 시작 페이지가 아니면 시작 페이지로 (BrowserHistory).
    private func updateCanGoBack() { canGoBack = BrowserHistory.canGoBack(started: started, showingStart: showingStart, historyHasBack: webView.canGoBack) }
    private let relay: SocksRelay
    /// 앱 안 중계의 포트 (준비되면 값이 있다) — 웹 확인(WebProbe)도 이 중계로 보낸다
    private(set) var relayPort: Int?
    /// 웹 확인을 보낼 중계 포트 — SOCKS 터널이 열려 시작 페이지를 띄운 뒤에만 값이 있다.
    /// 중계는 터널보다 먼저 준비되므로 relayPort 만 보고 물으면 ssh -D 가 뜨기 전이라 전부 실패하고, 그 결과가 "다 물음"으로 남는다 (2026-11-17)
    var probePort: Int? { started ? relayPort : nil }

    @Published private(set) var title = ""
    @Published private(set) var url: URL?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    /// 받은 정도 0…1 (WebKit 의 estimatedProgress) — 주소창 아래 진행 줄. 서버가 답을 안 주면 0.1 근처에 멈춰 있다
    @Published private(set) var progress = 0.0
    /// 보고 있는 주소가 이 서버의 즐겨찾기에 있는가 (주소창의 별)
    @Published private(set) var bookmarked = false
    /// 보고 있는 페이지의 아이콘 (탭 머리 — 없으면 지구본). 주소(호스트·포트)가 바뀔 때만 다시 받는다
    @Published private(set) var icon: NSImage?
    /// 아이콘을 받아 본 주소 (못 받았어도 — 같은 곳에서 페이지마다 다시 묻지 않게)
    private var iconSite: String?
    /// SOCKS 터널이 열리기 전(또는 못 열었을 때)의 안내. 페이지가 뜨면 nil.
    @Published private(set) var notice: String? = "프록시 터널 연결 중…"

    private var observers: [NSKeyValueObservation] = []
    private var downloads: [WKDownload: URL] = [:]

    init(server: Server, socksPort: Int, startPage: @escaping @MainActor () -> String, startPorts: @escaping @MainActor () -> String,
         onStartShown: @escaping @MainActor () -> Void, onStartReload: @escaping @MainActor () -> Void, bookmarks: BookmarkHooks,
         logins: LoginHooks, onStatus: @escaping @MainActor (String) -> Void) {
        self.server = server
        self.socksPort = socksPort
        self.startPage = startPage
        self.startPorts = startPorts
        self.onStartShown = onStartShown
        self.onStartReload = onStartReload
        self.bookmarks = bookmarks
        self.logins = logins
        self.onStatus = onStatus
        relay = SocksRelay(upstreamPort: socksPort) { host, port in BrowserPolicy.route(host: host, port: port) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.storeIdentifier(for: server.key))
        // 사이트가 Safari 로 알아보게 (이름 없는 기본 User-Agent 에는 구글 등이 옛 화면을 내준다)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        configuration.applicationNameForUserAgent = BrowserPolicy.userAgentSuffix(osMajor: os.majorVersion, osMinor: os.minorVersion)
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // 시작 페이지의 즐겨찾기 ✕ 가 보내는 것 (약한 참조로 — 컨트롤러가 처리기를 붙들어 탭이 닫혀도 남는 것을 막는다)
        configuration.userContentController.add(MessageRelay(self), name: "nexus")
        // 로그인 폼 읽기: 페이지의 스크립트가 못 보는 영역에서, 맨 위 프레임에만 (통로도 그 영역에서만 열린다)
        configuration.userContentController.add(MessageRelay(self), contentWorld: loginWorld, name: LoginForms.handler)
        configuration.userContentController.addUserScript(WKUserScript(source: LoginForms.captureScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: loginWorld))
        Task {
            do {
                let port = try await relay.start()
                relayPort = port
                applyProxy(relayPort: port)
            } catch {
                notice = "브라우저 중계를 열지 못했습니다: \(error.localizedDescription)"
            }
        }
        observers = [
            webView.observe(\.title) { [weak self] view, _ in Task { @MainActor in self?.title = view.title ?? "" } },
            // 주소창에는 별칭이 아니라 입력한 루프백 주소 그대로
            webView.observe(\.url) { [weak self] view, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.url = self.showingStart ? nil : view.url.map(BrowserPolicy.displayed)   // 시작 페이지(about:blank)는 주소창을 비운다
                    self.updateBookmarked()
                }
            },
            webView.observe(\.canGoBack) { [weak self] _, _ in Task { @MainActor in self?.updateCanGoBack() } },
            webView.observe(\.canGoForward) { [weak self] view, _ in Task { @MainActor in self?.canGoForward = view.canGoForward } },
            webView.observe(\.isLoading) { [weak self] view, _ in Task { @MainActor in self?.isLoading = view.isLoading } },
            webView.observe(\.estimatedProgress) { [weak self] view, _ in Task { @MainActor in self?.progress = view.estimatedProgress } },
        ]
    }

    /// 서버별 영구 스토어 ID. 한 번 만들면 UserDefaults 에 남겨 재실행해도 같은 쿠키·로그인을 쓴다.
    static func storeIdentifier(for key: String) -> UUID {
        let defaultsKey = AppPreferences.browserStoreKey(for: key)
        if let saved = UserDefaults.standard.string(forKey: defaultsKey), let uuid = UUID(uuidString: saved) { return uuid }
        let fresh = UUID()
        UserDefaults.standard.set(fresh.uuidString, forKey: defaultsKey)
        return fresh
    }

    // MARK: 동작

    /// SOCKS 터널이 열린 뒤 모델이 부른다. 중계가 준비되면 시작 페이지를 보인다.
    func start() {
        Task {
            let deadline = Date().addingTimeInterval(5)
            while relayPort == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            guard relayPort != nil else { notice = notice ?? "브라우저 중계가 준비되지 않았습니다"; return }
            notice = nil
            started = true
            openStart()
        }
    }

    /// 터널을 못 열었을 때
    func fail(_ reason: String) { notice = reason }

    /// 탭을 닫을 때: 중계를 내린다 (열린 연결도 끊긴다)
    func close() {
        relay.stop()
        webView.stopLoading()
    }

    /// 주소창·시작 페이지 입력칸에 친 글자: 주소면 그 주소, 아니면 Google 검색 (BrowserInput)
    func load(_ text: String) {
        guard let url = BrowserInput.resolve(text), BrowserPolicy.isOpenable(url) else { return }
        open(URLRequest(url: BrowserPolicy.proxied(url)))
    }

    /// 이 탭이 직접 여는 길 (주소창 · 루프백을 별칭으로 바꿔 다시 열기 · 새 창 링크). 웹 주소면 여기서 시작 페이지를 떠난 것으로 한다 —
    /// load 는 그 자리에서 webView.url 을 바꾸는데(주소 관찰이 바로 돈다) 이동 정책 물음은 그 뒤에 온다. 그때까지 시작 페이지로 남아 있으면
    /// 주소창을 비우고, 같은 주소로 확정될 때는 관찰이 다시 오지 않아 빈 채로 남았다 (2026-11-18 — 시작 페이지에서 즐겨찾기·포트 타일로 연 루프백 주소).
    private func open(_ request: URLRequest) {
        if let url = request.url, BrowserPolicy.isWeb(url) { showingStart = false }
        webView.load(request)
    }

    /// 시작 페이지로 간다 (첫 표시 · 집 버튼 · 앞 항목 없는 뒤로): 빈 문서로 이동해 기록에 한 항목을 만들고, 다 뜨면 그 위에 그린다 (didFinish).
    /// 그리기(loadHTMLString)만으로는 기록에 항목이 생기지 않는다 — 시작 페이지에서 연 페이지의 뒤로가 시작 페이지를 건너뛰어 그 앞 페이지로 갔고,
    /// 집 버튼으로 온 시작 페이지에서는 뒤로가 꺼져 있었다 (2026-11-25 사용자 지적, 화면 밖 웹 뷰로 기록을 찍어 확인). 이미 시작 페이지면 다시 그리기만.
    func openStart() {
        if showingStart, !startPending, webView.url?.absoluteString == "about:blank" { return showStart() }
        markStart()
        startPending = true
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    /// 시작 페이지(서버·열린 포트)를 지금 자리에 지금 값으로 그린다 — 기록은 건드리지 않는다
    func showStart() {
        markStart()
        webView.loadHTMLString(startPage(), baseURL: nil)
        onStartShown()
    }

    private func markStart() {
        showingStart = true
        url = nil
        fillPrompt = nil
        icon = nil; iconSite = nil
    }

    /// 포트 목록·웹 확인 결과가 새로 왔을 때 모델이 부른다 — 시작 페이지를 보고 있을 때만, 포트 부분만 갈아 끼운다 (주소칸에 치던 글자는 그대로)
    func refreshStartPorts() {
        guard showingStart, notice == nil else { return }
        guard let json = try? JSONEncoder().encode(startPorts()), let literal = String(data: json, encoding: .utf8) else { return }
        webView.evaluateJavaScript("var p=document.getElementById('ports');if(p){p.innerHTML=\(literal)}", completionHandler: nil)
    }

    // MARK: 즐겨찾기

    /// 별을 누를 수 있는가: 웹 페이지를 보고 있을 때 (시작 페이지·연결 중에는 넣을 주소가 없다)
    var canBookmark: Bool { url.map { BookmarkStore.isBookmarkable($0.absoluteString) } ?? false }

    private func updateBookmarked() { bookmarked = url.map(bookmarks.contains) ?? false }

    /// 모델이 부른다 — 이 서버의 즐겨찾기가 바뀌었다 (이 탭·같은 서버의 다른 탭에서): 별과 시작 페이지의 즐겨찾기 줄을 다시 맞춘다
    func bookmarksChanged() {
        updateBookmarked()
        guard showingStart, notice == nil else { return }
        guard let json = try? JSONEncoder().encode(bookmarks.startHTML()), let literal = String(data: json, encoding: .utf8) else { return }
        webView.evaluateJavaScript("var m=document.getElementById('marks');if(m){m.innerHTML=\(literal)}", completionHandler: nil)
    }

    /// 주소창의 별: 들어 있으면 빼고, 없으면 그 페이지의 제목·아이콘과 함께 넣는다. 아이콘은 그 페이지 안에서 받아 data: 주소로 (같은 쿠키·같은 길).
    func toggleBookmark() {
        guard let url, canBookmark else { return }
        let title = self.title
        if bookmarked { bookmarks.toggle(url, title, nil); return }
        Task {
            let icon = try? await webView.callAsyncJavaScript(Self.iconScript, arguments: ["limit": BookmarkStore.iconLimit], in: nil, contentWorld: .defaultClient) as? String
            guard self.url == url else { return }   // 받는 사이 다른 페이지로 갔으면 넣지 않는다
            bookmarks.toggle(url, title, icon)
        }
    }

    /// 페이지가 다 열렸다: 탭 머리의 아이콘을 맞춘다. 같은 주소(호스트·포트) 안에서 옮겨 다닐 때는 그대로 두고, 다른 곳이면 그 페이지 안에서 받는다
    /// (즐겨찾기와 같은 스크립트 — 같은 쿠키·같은 길). 못 받으면 지구본.
    private func refreshIcon() {
        guard !showingStart, let site, site != iconSite else { return }
        iconSite = site
        Task {
            let found = try? await webView.callAsyncJavaScript(Self.iconScript, arguments: ["limit": BookmarkStore.iconLimit], in: nil, contentWorld: .defaultClient) as? String
            guard iconSite == site else { return }   // 받는 사이 다른 곳으로 갔다
            icon = BookmarkStore.iconData(found).flatMap(NSImage.init(data:))
        }
    }

    /// <link rel="icon"> → 없으면 /favicon.ico. 64KB 이하의 그림만, 2초 안에. 못 받으면 null (아이콘 없이 넣는다).
    private static let iconScript = """
        const link = [...document.querySelectorAll('link[rel]')].find(l => l.rel.toLowerCase().split(/\\s+/).includes('icon'));
        const urls = [];
        if (link && link.href) urls.push(link.href);
        urls.push(new URL('/favicon.ico', location.href).href);
        for (const u of urls) {
            try {
                if (u.startsWith('data:')) { if (u.startsWith('data:image/') && u.length <= limit) return u; continue; }
                const stop = new AbortController(); const timer = setTimeout(() => stop.abort(), 2000);
                const response = await fetch(u, { credentials: 'include', signal: stop.signal });
                if (!response.ok) { clearTimeout(timer); continue; }
                const blob = await response.blob(); clearTimeout(timer);
                if (blob.size === 0 || blob.size > 65536 || !(blob.type || '').startsWith('image/')) continue;
                const data = await new Promise(done => { const r = new FileReader(); r.onload = () => done(r.result); r.onerror = () => done(null); r.readAsDataURL(blob); });
                if (data && data.length <= limit) return data;
            } catch (e) {}
        }
        return null;
        """

    // MARK: 로그인 (메모·로그인 — NoteVault)

    /// 지금 보는 페이지의 로그인 주소 (시작 페이지·연결 중이면 nil)
    var site: String? { url.flatMap { NoteVault.site(of: $0.absoluteString) } }

    /// 페이지가 보낸 것: 잡은 ID·비밀번호는 들고만 있고, 비밀번호 칸이 사라졌다고 하면 묻는다
    private func receivedLogin(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let parsed = LoginForms.parse(message.body) else { return }
        // 칸이 안 보인다·떠났다는 알림은 어느 페이지에서든 목록을 내린다 (시작 페이지·오류 페이지로 넘어갔을 때도)
        if parsed == .field(false) { fillPrompt = nil }
        if parsed == .blur { if fillPromptHovered { fillBlurPending = true } else { fillPrompt = nil } }
        guard !showingStart, let url, let site else { return }
        switch parsed {
        case let .candidate(username, password): loginCandidate = (url, username, password, Date())
        case .gone, .field(false): settleLogin(passwordFieldVisible: false)
        case let .focus(field):
            guard Date() >= fillQuietUntil else { return }
            let saved = logins.saved(site)
            fillBlurPending = false
            fillPrompt = saved.isEmpty ? nil : FillPrompt(field: field, logins: saved)
        case .field(true), .blur: break
        }
    }

    /// 목록 화면이 알린다: 마우스가 목록 위에 있다·떠났다
    func setFillPromptHovered(_ hovered: Bool) {
        fillPromptHovered = hovered
        if !hovered, fillBlurPending { fillBlurPending = false; fillPrompt = nil }
    }

    /// 잡아 둔 것을 끝낸다: 로그인이 된 것 같으면 모델에 물어 띠를 띄우고, 아니면(칸이 다시 떴다·오래됐다) 버린다
    private func settleLogin(passwordFieldVisible: Bool) {
        guard let candidate = loginCandidate else { return }
        loginCandidate = nil
        guard NoteVault.confirms(capturedAt: candidate.at, now: Date(), passwordFieldVisible: passwordFieldVisible) else { return }
        switch logins.captured(candidate.address, candidate.username, candidate.password) {
        case .ignore: break
        case let .add(note): offer(note, isUpdate: false, at: candidate.address)
        case let .update(note): offer(note, isUpdate: true, at: candidate.address)
        }
    }

    private func offer(_ note: SecretNote, isUpdate: Bool, at address: URL) {
        let site = NoteVault.site(of: address.absoluteString) ?? ""
        guard !declinedLogins.contains(site + "\n" + note.username) else { return }
        loginOffer = LoginOffer(note: note, isUpdate: isUpdate, site: site)
    }

    /// 페이지가 통째로 넘어간 뒤: 새 페이지에 비밀번호 칸이 없으면 로그인이 된 것으로 본다 (확인을 못 하면 버린다)
    private func settleLoginAfterNavigation() {
        guard loginCandidate != nil else { return }
        guard !showingStart else { loginCandidate = nil; return }
        Task {
            let visible = try? await webView.callAsyncJavaScript(LoginForms.visibleScript, arguments: [:], in: nil, contentWorld: loginWorld) as? Bool
            settleLogin(passwordFieldVisible: visible ?? true)
        }
    }

    /// 카드의 [저장]·[바꾸기]
    func acceptLoginOffer() {
        guard let offer = loginOffer else { return }
        loginOffer = nil
        logins.save(offer.note)
    }

    /// 카드의 [나중에]
    func declineLoginOffer() {
        guard let offer = loginOffer else { return }
        declinedLogins.insert(offer.site + "\n" + offer.note.username)
        loginOffer = nil
    }

    /// 팝오버·칸 아래 목록에서 로그인을 눌렀다: 지금 페이지가 그 주소일 때만 채운다 (다른 사이트에 비밀번호를 넣지 않는다)
    func fill(_ note: SecretNote) {
        guard NoteVault.canFill(note, site: site) else { return }
        fillPrompt = nil
        fillPromptHovered = false; fillBlurPending = false
        fillQuietUntil = Date().addingTimeInterval(1)
        let address = url
        Task {
            guard url == address else { return }
            let result = try? await webView.callAsyncJavaScript(LoginForms.fillScript, arguments: ["username": note.username, "password": note.password],
                                                              in: nil, contentWorld: loginWorld) as? String
            switch result.flatMap(LoginForms.Filled.init(rawValue:)) ?? .none {
            case .filled: break
            case .user: onStatus("ID 만 넣었습니다 — 비밀번호 칸이 나오면 다시 누르세요")
            case .none: onStatus("채울 로그인 칸을 찾지 못했습니다")
            }
        }
    }

    /// 시작 페이지가 보낸 것만 받는다 — 이 탭이 여는 다른 웹 페이지도 같은 이름으로 보낼 수 있다.
    /// remove: 즐겨찾기 타일의 ✕ · open: 입력칸에 친 글자 (주소창과 같은 판정 — load)
    fileprivate func received(_ message: WKScriptMessage) {
        if message.name == LoginForms.handler { return receivedLogin(message) }
        guard showingStart, message.frameInfo.isMainFrame, webView.url?.absoluteString == "about:blank",
              let body = message.body as? [String: Any] else { return }
        if let address = body["remove"] as? String { bookmarks.remove(address) }
        if let text = body["open"] as? String { load(text) }
    }

    func goBack() {
        if webView.canGoBack { webView.goBack() } else { openStart() }
    }
    func goForward() { webView.goForward() }
    func reload() {
        if showingStart { onStartReload(); showStart() } else { webView.reload() }
    }
    func stopLoading() { webView.stopLoading() }

    /// 같은 서버의 다른 브라우저 탭이 닫혔을 때 모델이 부른다. 데이터 스토어(서버별 같은 ID)를 탭끼리 나눠 쓰면
    /// 스토어의 프록시가 닫힌 탭의 중계 포트를 가리키고 있을 수 있으니, 살아 있는 이 탭의 중계로 다시 건다.
    func reapplyProxy() {
        guard let relayPort else { return }
        applyProxy(relayPort: relayPort)
    }

    /// 모든 요청을 앱 안 중계(127.0.0.1:<중계 포트>)로. 루프백만 WebKit 이 프록시를 건너뛰므로 별칭으로 바꿔 연다 (BrowserPolicy.proxied).
    private func applyProxy(relayPort: Int) {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: relayPort)) else { return }
        webView.configuration.websiteDataStore.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: port))]
    }
}

// MARK: - 이동 정책·다운로드

extension BrowserSession: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let url = navigationAction.request.url else { return (.cancel, preferences) }
        guard BrowserPolicy.isOpenable(url) else { return (.cancel, preferences) }   // file: 등 이 Mac 의 것
        // 루프백으로 가는 이동(링크·리다이렉트)은 별칭으로 바꿔 다시 연다 — 그대로 두면 WebKit 이 이 Mac 으로 붙는다
        let target = BrowserPolicy.proxied(url)
        if target != url, navigationAction.targetFrame?.isMainFrame ?? true {
            var request = navigationAction.request
            request.url = target
            open(request)
            return (.cancel, preferences)
        }
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        // 웹 주소로 떠나면 시작 페이지가 아니다. 뒤로 · 앞으로 돌아온 시작 페이지(about:blank)는 다 뜬 뒤 다시 그린다 — 기록에 남은 것은 빈 문서뿐이다
        // (이동이 끝나기 전에 그리면 그 이동이 취소돼 기록의 자리가 안 옮겨진다 — didFinish 에서)
        if navigationAction.targetFrame?.isMainFrame ?? true {
            if BrowserPolicy.isWeb(url) { showingStart = false }
            else if url.absoluteString == "about:blank", navigationAction.navigationType == .backForward {
                Task { @MainActor in
                    self.markStart()
                    // 이미 다 떴으면(didFinish 가 먼저 왔다) 바로 그린다
                    if !webView.isLoading, webView.url?.absoluteString == "about:blank" { self.showStart() } else { self.startPending = true }
                }
            }
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    /// 서버 인증서 확인: 서버 자신의 루프백(별칭 이름)으로 붙을 때만 받아들인다 — 이름을 앱이 바꿨으니 맞는 인증서가 있을 수 없다 (BrowserPolicy).
    /// 그 밖의 주소와 다른 인증 요청(기본 인증 · 클라이언트 인증서)은 WebKit 이 평소대로 처리한다.
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust,
              BrowserPolicy.acceptsUnverifiedCertificate(host: space.host) else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    /// 시작 페이지가 다 그려진 뒤 포트 부분을 한 번 더 맞춘다 — 그리는 사이에 온 포트 목록·웹 확인 결과를 놓치지 않게
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if startPending, webView.url?.absoluteString == "about:blank" {   // 시작 페이지 자리에 닿았다 — 이제 그린다
            startPending = false
            return showStart()
        }
        refreshStartPorts()
        settleLoginAfterNavigation()
        refreshIcon()
    }

    /// 새 문서로 넘어갔다 — 옛 페이지의 칸 아래 목록은 내린다 (옛 문서는 blur 를 못 보낸다)
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        fillPrompt = nil
        fillPromptHovered = false; fillBlurPending = false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    /// 실패한 주소에 오류 페이지를 띄운다 — 이전 페이지로 되돌아가 주소창이 바뀌는 대신, 입력한 주소와 이유가 남게.
    private func showError(_ error: Error) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        // 응답을 다운로드로 돌리면 WebKit 이 이동을 "프레임 로드 중단"(102)으로 끝낸다 — 다운로드는 진행 중이라 오류 페이지를 띄우지 않는다
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }   // WebKitErrorFrameLoadInterruptedByPolicyChange
        let failed = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? (nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
        let (title, detail) = BrowserErrorPage.message(code: nsError.code, fallback: nsError.localizedDescription)
        let target = failed.map(BrowserPolicy.displayed)?.absoluteString ?? ""
        webView.loadHTMLString(BrowserErrorPage.html(title: title, detail: detail, target: target), baseURL: failed)
        url = failed.map(BrowserPolicy.displayed)
    }
}

extension BrowserSession: WKDownloadDelegate {
    /// ~/Downloads 에 제안된 이름으로, 같은 이름이 있으면 " (2)" 식으로 비켜 저장한다.
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        let target = BrowserDownload.destination(in: dir, suggested: suggestedFilename) { FileManager.default.fileExists(atPath: $0.path) }
        downloads[download] = target
        onStatus("다운로드 시작: \(target.lastPathComponent)")
        return target
    }

    func downloadDidFinish(_ download: WKDownload) {
        onStatus("다운로드 완료: \(downloads[download]?.lastPathComponent ?? "")")
        downloads[download] = nil
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        onStatus("다운로드 실패: \(error.localizedDescription)")
        downloads[download] = nil
    }
}

// MARK: - 창·대화상자·파일 선택

extension BrowserSession: WKUIDelegate {
    /// target=_blank 는 새 창 대신 같은 탭에서 연다
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, BrowserPolicy.isOpenable(url) {
            var request = navigationAction.request
            request.url = BrowserPolicy.proxied(url)
            open(request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = server.key
        alert.informativeText = message
        alert.runModal()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = server.key
        alert.informativeText = message
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let alert = NSAlert()
        alert.messageText = server.key
        alert.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.urls : nil
    }
}

/// 스크립트 메시지를 탭에 넘기는 약한 다리 (WKUserContentController 는 처리기를 강하게 붙든다)
private final class MessageRelay: NSObject, WKScriptMessageHandler {
    private weak var session: BrowserSession?
    init(_ session: BrowserSession) { self.session = session }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { session?.received(message) }
    }
}
