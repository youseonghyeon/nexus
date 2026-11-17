// WebKit 실물 확인 (진단용, 환경변수 SERVERS_BROWSER_MOCK=<디렉터리> 가 있을 때만 돈다). 서버 접속 없음 — 이 Mac 의 가짜 SOCKS(상류 역할)·HTTP 서버로.
// WebKit → 앱 안 SocksRelay → (서버 IP 면 상류 SOCKS / 루프백·터널 이름이면 직접 / 그 밖 거절)
//   1) 서버 IP 페이지가 뜨고 범위 안 하위 요청은 오는가
//   2) 페이지 안의 범위 밖 하위 요청(CSS)이 콘텐츠 규칙에 막히는가      → 상류 로그에 그 호스트가 없어야 함
//   3) 루프백·터널 이름(jenkins.acme, hosts 에 없음)이 중계에서 직접 풀려 뜨는가 → 상류 로그에 없어야 함
//   4) 범위 밖 페이지 이동이 즉시 취소되는가
//   5) 자기 주소가 아닌 서버 IP 는 상류 SOCKS 를 지나는가

import Foundation
@testable import ServersCore
import Network
import WebKit
import XCTest

@MainActor
final class BrowserWebKitProbeTests: XCTestCase {
    final class Delegate: NSObject, WKNavigationDelegate {
        let scope: BrowserScope
        var finished: (() -> Void)?
        var blocked: [String] = []
        init(scope: BrowserScope) { self.scope = scope }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
            guard let url = action.request.url, BrowserPolicy.isAllowed(url, scope: scope) else {
                blocked.append(action.request.url?.absoluteString ?? "?"); return (.cancel, preferences)
            }
            return (.allow, preferences)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished?() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finished?() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finished?() }
    }

    private var relays: [SocksRelay] = []

    /// 중계·규칙을 건 WKWebView 하나. 상류는 가짜 SOCKS(1088).
    private func makeWebView(scope: BrowserScope) async throws -> (WKWebView, Delegate) {
        let relay = SocksRelay(upstreamPort: 1088) { host, port in BrowserPolicy.route(host: host, port: port, scope: scope) }
        let relayPort = try await relay.start()
        relays.append(relay)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(relayPort))!))
        configuration.websiteDataStore.proxyConfigurations = [proxy]
        let rules = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "probe-\(UUID().uuidString)",
                                                                                          encodedContentRuleList: BrowserPolicy.contentRulesJSON(scope: scope))
        configuration.userContentController.add(try XCTUnwrap(rules))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let delegate = Delegate(scope: scope)
        webView.navigationDelegate = delegate
        return (webView, delegate)
    }

    /// 로드가 끝나거나(didFinish/didFail) 정책이 막거나(blocked) 시간이 다 될 때까지
    private func load(_ webView: WKWebView, _ delegate: Delegate, _ url: String, timeout: TimeInterval = 10) async {
        let before = delegate.blocked.count
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            var done = false
            func finish() { if !done { done = true; c.resume() } }
            delegate.finished = finish
            webView.load(URLRequest(url: URL(string: url)!))
            // 정책이 취소하면 WebKit 은 아무 콜백도 주지 않는다 — blocked 가 늘면 끝난 것으로 본다
            Task { @MainActor in
                let deadline = Date().addingTimeInterval(timeout)
                while !done, Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(100))
                    if delegate.blocked.count > before { finish() }
                }
                finish()
            }
        }
    }

    func testProxyAndScopeThroughRealWebKit() async throws {
        guard let dir = ProcessInfo.processInfo.environment["SERVERS_BROWSER_MOCK"] else { throw XCTSkip("SERVERS_BROWSER_MOCK 없음") }
        let serverIP = try String(contentsOfFile: dir + "/en0.txt", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let logPath = dir + "/proxy.log"
        try "".write(toFile: logPath, atomically: true, encoding: .utf8)
        func log() -> String { (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "" }

        // 1·2: 서버 IP(여기선 이 Mac 의 en0 주소 — 자기 주소라 프록시를 안 거치는 건 WebKit 의 암묵 예외) 페이지가 뜨고,
        //      그 안의 범위 밖 CSS(203.0.113.9)는 콘텐츠 규칙이 막아 프록시까지 가지 않는다. 범위 안 이미지는 온다.
        let scope = BrowserScope(serverIP: serverIP, loopbackNameAddresses: ["jenkins.acme": "127.0.0.1"])
        let (webView, delegate) = try await makeWebView(scope: scope)
        await load(webView, delegate, "http://\(serverIP):9093/")
        try await Task.sleep(for: .seconds(1))
        let heading = try await webView.evaluateJavaScript("document.getElementById('ok') && document.getElementById('ok').textContent") as? String
        XCTAssertEqual(heading, "SERVER-VIA-PROXY")
        let imageLoaded = try await webView.evaluateJavaScript("document.images[0] && document.images[0].complete && document.images[0].naturalWidth >= 0") as? Bool
        XCTAssertEqual(imageLoaded, true, "범위 안 하위 요청은 허용")
        XCTAssertFalse(log().contains("203.0.113.9"), "범위 밖 CSS 는 콘텐츠 규칙이 막아 프록시까지 가지 않아야 한다: \(log())")

        // 3: 루프백은 중계가 직접, 터널 이름(hosts 에 없음)도 중계가 직접 푼다 — 상류엔 안 간다
        await load(webView, delegate, "http://127.0.0.1:9091/")
        let loop = try await webView.evaluateJavaScript("document.body.textContent") as? String
        XCTAssertEqual(loop?.trimmingCharacters(in: .whitespacesAndNewlines), "LOOPBACK-DIRECT")
        await load(webView, delegate, "http://jenkins.acme:9091/")
        let named = try await webView.evaluateJavaScript("document.body.textContent") as? String
        XCTAssertEqual(named?.trimmingCharacters(in: .whitespacesAndNewlines), "LOOPBACK-DIRECT", "jenkins.acme 는 /etc/hosts 에 없어도 앱이 127.0.0.1 로 푼다")
        XCTAssertEqual(webView.url?.host, "jenkins.acme", "주소창은 이름 그대로")
        XCTAssertFalse(log().contains("9091"), "루프백·이름은 상류에 가지 않는다: \(log())")

        // 4: 범위 밖 페이지 이동은 정책이 즉시 취소 (WebKit 이 정책 판단 중에 미리 연결(preconnect)을 시도해 프록시 로그에 CONNECT 가 남을 수는 있다 — 요청은 안 나간다)
        let before = Date()
        await load(webView, delegate, "http://192.168.112.11/")
        XCTAssertLessThan(Date().timeIntervalSince(before), 3, "기다리지 않고 바로 취소돼야 한다")
        XCTAssertEqual(delegate.blocked.last, "http://192.168.112.11/")

        // 5: 자기 주소가 아닌 서버 IP 는 상류 SOCKS 를 지난다 — TEST-NET 주소를 서버로 두면 상류가 CONNECT 를 시도하고(닿진 않음) 로그에 남는다
        let far = BrowserScope(serverIP: "203.0.113.9")
        let (farView, farDelegate) = try await makeWebView(scope: far)
        await load(farView, farDelegate, "http://203.0.113.9/", timeout: 3)
        XCTAssertTrue(log().contains("CONNECT 203.0.113.9:80"), "서버 IP 로의 요청은 SOCKS 를 지나야 한다: \(log())")
        XCTAssertTrue(farDelegate.blocked.isEmpty, "서버 IP 는 범위 안")
    }
}
