// 앱 안 브라우저 탭 하나 (WKWebView) — 그 서버에서 브라우저를 켠 것처럼: 모든 요청이 앱 안 SOCKS 중계(SocksRelay)를 거쳐 그 서버의 ssh -D 로 간다.
//   프록시: 데이터 스토어의 proxyConfigurations 를 127.0.0.1:<중계 포트> 로. 이름 풀이는 서버가 한다. 막는 주소는 없다.
//   루프백(127.0.0.1·localhost): WebKit 이 프록시에 안 보내므로 별칭 이름으로 바꿔 열고 주소창엔 원래 주소를 보인다 (BrowserPolicy 머리 주석).
//   쿠키·로그인: 서버별 영구 데이터 스토어 (재실행해도 유지). 다운로드는 ~/Downloads. 파일 선택·alert/confirm/prompt 도 받는다.

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
    /// 지금 시작 페이지를 보고 있는가 (포트 목록이 오면 다시 그린다 · 주소창은 비운다)
    private(set) var showingStart = false { didSet { updateCanGoBack() } }
    /// 시작 페이지를 한 번이라도 띄웠는가 (프록시 연결 중에는 뒤로 갈 곳이 없다)
    private var started = false

    /// 뒤로: 시작 페이지가 아니면 늘 갈 수 있다 — 기록의 앞 항목이 없거나 빈 문서(시작 페이지 자리)면 시작 페이지로 간다 (goBack).
    /// WebKit 의 canGoBack 만 보면 시작 페이지에서 처음 연 페이지에서 뒤로가 꺼졌다 (2026-11-17 사용자 확인).
    private func updateCanGoBack() { canGoBack = started && !showingStart }
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
    /// SOCKS 터널이 열리기 전(또는 못 열었을 때)의 안내. 페이지가 뜨면 nil.
    @Published private(set) var notice: String? = "프록시 터널 연결 중…"

    private var observers: [NSKeyValueObservation] = []
    private var downloads: [WKDownload: URL] = [:]

    init(server: Server, socksPort: Int, startPage: @escaping @MainActor () -> String, startPorts: @escaping @MainActor () -> String,
         onStartShown: @escaping @MainActor () -> Void, onStartReload: @escaping @MainActor () -> Void, onStatus: @escaping @MainActor (String) -> Void) {
        self.server = server
        self.socksPort = socksPort
        self.startPage = startPage
        self.startPorts = startPorts
        self.onStartShown = onStartShown
        self.onStartReload = onStartReload
        self.onStatus = onStatus
        relay = SocksRelay(upstreamPort: socksPort) { host, port in BrowserPolicy.route(host: host, port: port) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.storeIdentifier(for: server.key))
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
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
            showStart()
        }
    }

    /// 터널을 못 열었을 때
    func fail(_ reason: String) { notice = reason }

    /// 탭을 닫을 때: 중계를 내린다 (열린 연결도 끊긴다)
    func close() {
        relay.stop()
        webView.stopLoading()
    }

    func load(_ text: String) {
        var candidate = text.trimmingCharacters(in: .whitespaces)
        if !candidate.contains("://") { candidate = "http://" + candidate }
        guard let url = URL(string: candidate), BrowserPolicy.isOpenable(url) else { return }
        webView.load(URLRequest(url: BrowserPolicy.proxied(url)))
    }

    /// 시작 페이지(서버·열린 포트)를 지금 값으로 그린다
    func showStart() {
        showingStart = true
        url = nil
        webView.loadHTMLString(startPage(), baseURL: nil)
        onStartShown()
    }

    /// 포트 목록·웹 확인 결과가 새로 왔을 때 모델이 부른다 — 시작 페이지를 보고 있을 때만, 포트 부분만 갈아 끼운다 (주소칸에 치던 글자는 그대로)
    func refreshStartPorts() {
        guard showingStart, notice == nil else { return }
        guard let json = try? JSONEncoder().encode(startPorts()), let literal = String(data: json, encoding: .utf8) else { return }
        webView.evaluateJavaScript("var p=document.getElementById('ports');if(p){p.innerHTML=\(literal)}", completionHandler: nil)
    }

    func goBack() {
        if let back = webView.backForwardList.backItem, back.url.absoluteString != "about:blank" { webView.goBack() } else { showStart() }
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
            webView.load(request)
            return (.cancel, preferences)
        }
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        // 웹 주소로 떠나면 시작 페이지가 아니다. 뒤로 가기로 돌아온 시작 페이지(about:blank)는 다시 그린다 — 기록에 남은 것은 빈 문서뿐이다
        if navigationAction.targetFrame?.isMainFrame ?? true {
            if BrowserPolicy.isWeb(url) { showingStart = false }
            else if url.absoluteString == "about:blank", navigationAction.navigationType == .backForward {
                Task { @MainActor in self.showStart() }
            }
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    /// 시작 페이지가 다 그려진 뒤 포트 부분을 한 번 더 맞춘다 — 그리는 사이에 온 포트 목록·웹 확인 결과를 놓치지 않게
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshStartPorts()
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
        let title: String, detail: String
        switch nsError.code {
        case NSURLErrorCannotConnectToHost: (title, detail) = ("연결할 수 없습니다", "이 주소에서 응답하는 서버가 없습니다.")
        case NSURLErrorTimedOut: (title, detail) = ("응답이 없습니다", "서버가 제한 시간 안에 응답하지 않았습니다.")
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: (title, detail) = ("주소를 찾을 수 없습니다", "서버 이름을 확인하세요.")
        case NSURLErrorNetworkConnectionLost: (title, detail) = ("연결이 끊어졌습니다", "페이지를 불러오는 중 연결이 끊어졌습니다.")
        default: (title, detail) = ("페이지를 열 수 없습니다", nsError.localizedDescription)
        }
        let target = failed.map(BrowserPolicy.displayed)?.absoluteString ?? ""
        let html = """
        <!doctype html><meta charset="utf-8"><title>\(escape(title))</title>
        <style>body{font:14px -apple-system,system-ui;color:#333;background:#fafafa;margin:0;display:flex;height:100vh;align-items:center;justify-content:center}
        @media(prefers-color-scheme:dark){body{color:#ddd;background:#1e1e1e}} .box{max-width:560px;padding:24px} h1{font-size:17px;margin:0 0 6px}
        p{margin:0 0 14px;opacity:.85} code{font:12px ui-monospace,Menlo;word-break:break-all;opacity:.7}</style>
        <div class="box"><h1>\(escape(title))</h1><p>\(escape(detail))</p><code>\(escape(target))</code></div>
        """
        webView.loadHTMLString(html, baseURL: failed)
        url = failed.map(BrowserPolicy.displayed)
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

extension BrowserSession: WKDownloadDelegate {
    /// ~/Downloads 에 제안된 이름으로, 같은 이름이 있으면 " (2)" 식으로 비켜 저장한다.
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        var target = dir.appendingPathComponent(suggestedFilename)
        let base = target.deletingPathExtension().lastPathComponent, ext = target.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
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
            webView.load(request)
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
