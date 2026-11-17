// 앱 안 브라우저 탭 하나 (WKWebView). 통신은 앱 안 SOCKS 중계(SocksRelay)로만 — 중계가 서버 IP 는 ssh -D 로, 루프백·터널 이름은 직접, 그 밖은 거절.
//   프록시: 데이터 스토어의 proxyConfigurations 를 127.0.0.1:<중계 포트> 로. 이름 풀이는 중계(앱)가 하므로 시스템 리졸버·hosts 와 무관.
//   페이지 이동: decidePolicyFor(navigationAction) 에서 범위 밖이면 즉시 취소하고 "차단" 을 표시 (기다리지 않는다 → 타임아웃 없음)
//   하위 요청(CSS·스크립트·이미지·웹소켓): WKContentRuleList 로 차단. 터널 목록이 바뀌면 프록시 예외·규칙을 다시 건다.
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
    /// 지금 허용 범위. 모델이 터널 목록으로 계산해 준다 (터널 이름·바인딩 주소가 바뀌면 달라진다).
    private let scope: @MainActor () -> BrowserScope
    private let onStatus: @MainActor (String) -> Void
    /// 중계가 (자기 큐에서) 읽는 범위 스냅샷. refreshScope 가 갱신한다.
    private let scopeBox: ScopeBox
    private let relay: SocksRelay
    private var relayPort: Int?

    @Published private(set) var title = ""
    @Published private(set) var url: URL?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    /// 마지막으로 막은 주소 (주소창 아래 한 줄). 다음 이동이 성공하면 지운다.
    @Published private(set) var blocked: String?
    /// SOCKS 터널이 열리기 전(또는 못 열었을 때)의 안내. 페이지가 뜨면 nil.
    @Published private(set) var notice: String? = "프록시 터널 연결 중…"

    private var observers: [NSKeyValueObservation] = []
    private var ruleListIdentifier: String { "servers-browser-\(server.key)" }
    private var downloads: [WKDownload: URL] = [:]

    init(server: Server, socksPort: Int, scope: @escaping @MainActor () -> BrowserScope, onStatus: @escaping @MainActor (String) -> Void) {
        self.server = server
        self.socksPort = socksPort
        self.scope = scope
        self.onStatus = onStatus
        let box = ScopeBox(scope())
        scopeBox = box
        relay = SocksRelay(upstreamPort: socksPort) { host, port in BrowserPolicy.route(host: host, port: port, scope: box.current) }
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
            webView.observe(\.url) { [weak self] view, _ in Task { @MainActor in self?.url = view.url } },
            webView.observe(\.canGoBack) { [weak self] view, _ in Task { @MainActor in self?.canGoBack = view.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] view, _ in Task { @MainActor in self?.canGoForward = view.canGoForward } },
            webView.observe(\.isLoading) { [weak self] view, _ in Task { @MainActor in self?.isLoading = view.isLoading } },
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

    /// SOCKS 터널이 열린 뒤 모델이 부른다. 중계·규칙이 준비된 뒤 시작 주소를 연다. url 이 nil 이면(터널 없음) 빈 탭으로 둔다.
    func start(url: URL?) {
        Task {
            let deadline = Date().addingTimeInterval(5)
            while relayPort == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            guard relayPort != nil else { notice = notice ?? "브라우저 중계가 준비되지 않았습니다"; return }
            await applyContentRules()   // 첫 로드 전에 규칙이 걸려 있어야 하위 요청이 새지 않는다
            notice = nil
            if let url { webView.load(URLRequest(url: url)) }
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
        guard let url = URL(string: candidate) else { return }
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stopLoading() { webView.stopLoading() }

    /// 같은 서버의 다른 브라우저 탭이 닫혔을 때 모델이 부른다. 데이터 스토어(서버별 같은 ID)를 탭끼리 나눠 쓰면
    /// 스토어의 프록시가 닫힌 탭의 중계 포트를 가리키고 있을 수 있으니, 살아 있는 이 탭의 중계로 다시 건다.
    func reapplyProxy() {
        guard let relayPort else { return }
        applyProxy(relayPort: relayPort)
    }

    /// 터널이 생기거나 없어졌을 때 모델이 부른다: 중계의 판정 범위와 하위 요청 규칙을 새 범위로.
    func refreshScope() {
        scopeBox.current = scope()
        Task { await applyContentRules() }
    }

    /// 모든 요청을 앱 안 중계(127.0.0.1:<중계 포트>)로. 예외 없음 — 루프백·이름도 중계가 직접 처리한다.
    private func applyProxy(relayPort: Int) {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: relayPort)) else { return }
        webView.configuration.websiteDataStore.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: port))]
    }

    /// 중계 큐에서 읽고 메인에서 쓰는 범위 스냅샷
    final class ScopeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: BrowserScope
        init(_ value: BrowserScope) { self.value = value }
        var current: BrowserScope {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    private func applyContentRules() async {
        let json = BrowserPolicy.contentRulesJSON(scope: scope())
        do {
            let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: ruleListIdentifier, encodedContentRuleList: json)
            webView.configuration.userContentController.removeAllContentRuleLists()
            if let list { webView.configuration.userContentController.add(list) }
        } catch {
            onStatus("브라우저 차단 규칙을 만들지 못했습니다: \(error.localizedDescription)")
        }
    }
}

// MARK: - 이동 정책·다운로드

extension BrowserSession: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let url = navigationAction.request.url else { return (.cancel, preferences) }
        guard BrowserPolicy.isAllowed(url, scope: scope()) else {
            if navigationAction.targetFrame?.isMainFrame ?? true { blocked = url.absoluteString }
            return (.cancel, preferences)
        }
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        if navigationAction.targetFrame?.isMainFrame ?? true { blocked = nil }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

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
        let target = failed?.absoluteString ?? ""
        let html = """
        <!doctype html><meta charset="utf-8"><title>\(escape(title))</title>
        <style>body{font:14px -apple-system,system-ui;color:#333;background:#fafafa;margin:0;display:flex;height:100vh;align-items:center;justify-content:center}
        @media(prefers-color-scheme:dark){body{color:#ddd;background:#1e1e1e}} .box{max-width:560px;padding:24px} h1{font-size:17px;margin:0 0 6px}
        p{margin:0 0 14px;opacity:.85} code{font:12px ui-monospace,Menlo;word-break:break-all;opacity:.7}</style>
        <div class="box"><h1>\(escape(title))</h1><p>\(escape(detail))</p><code>\(escape(target))</code></div>
        """
        webView.loadHTMLString(html, baseURL: failed)
        url = failed
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
    /// target=_blank 는 새 창 대신 같은 탭에서 연다 (정책은 그대로 적용된다)
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, BrowserPolicy.isAllowed(url, scope: scope()) {
            webView.load(navigationAction.request)
        } else if let url = navigationAction.request.url {
            blocked = url.absoluteString
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
