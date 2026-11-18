// LoginForms: 스크립트를 실제 WKWebView 에 넣어 본다 (문자열로 준 페이지 — 망으로 나가는 요청 없음).
// 페이지 쪽 조작(값 넣기·제출·클릭)은 페이지 영역에서, 잡기·채우기는 앱과 같이 분리된 영역에서.

import WebKit
import XCTest
@testable import ServersCore

@MainActor
private final class Sink: NSObject, WKScriptMessageHandler {
    var messages: [LoginForms.Message] = []
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let parsed = LoginForms.parse(message.body) { messages.append(parsed) }
    }
}

@MainActor
private final class Loader: NSObject, WKNavigationDelegate {
    var finished = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
}

@MainActor
final class LoginFormsTests: XCTestCase {
    private let world = WKContentWorld.world(name: LoginForms.world)
    private var loaders: [Loader] = []

    private func page(_ body: String) async throws -> (WKWebView, Sink) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let sink = Sink()
        configuration.userContentController.add(sink, contentWorld: world, name: LoginForms.handler)
        configuration.userContentController.addUserScript(WKUserScript(source: LoginForms.captureScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loader = Loader()
        loaders.append(loader)
        view.navigationDelegate = loader
        view.loadHTMLString("<!doctype html><meta charset=utf-8><body>\(body)</body>", baseURL: nil)
        try await wait("페이지 로드") { loader.finished }
        return (view, sink)
    }

    private func wait(_ what: String, seconds: Double = 5, until done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() {
            if Date() > deadline { return XCTFail("\(what): 시간 안에 오지 않았다") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// 페이지 영역에서 실행 (사용자·페이지 스크립트가 하는 일)
    private func inPage(_ view: WKWebView, _ script: String) async throws -> Any? {
        try await view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }

    private func fill(_ view: WKWebView, username: String, password: String) async throws -> LoginForms.Filled? {
        let result = try await view.callAsyncJavaScript(LoginForms.fillScript, arguments: ["username": username, "password": password], in: nil, contentWorld: world)
        return (result as? String).flatMap(LoginForms.Filled.init(rawValue:))
    }

    private let form = """
        <form id=f onsubmit="event.preventDefault()"><input name=q type=hidden value=x><input id=u type=text><input id=p type=password><button id=b>Login</button></form>
        """

    // MARK: 잡기

    func testFormSubmitSendsUserAndPassword() async throws {
        let (view, sink) = try await page(form)
        _ = try await inPage(view, "u.value = 'admin'; p.value = 's3cret'; f.requestSubmit();")
        try await wait("제출") { !sink.messages.isEmpty }
        XCTAssertEqual(sink.messages.first, .candidate(username: "admin", password: "s3cret"))
    }

    func testFormlessButtonClickAndEnter() async throws {
        let html = "<input type=search id=s value=찾기><div><input id=u type=email><input id=p type=password><div role=button id=b><span id=inner>Sign in</span></div></div>"
        let (view, sink) = try await page(html)
        _ = try await inPage(view, "u.value = 'a@example.com'; p.value = 'pw 1'; inner.click();")
        try await wait("클릭") { !sink.messages.isEmpty }
        XCTAssertEqual(sink.messages.first, .candidate(username: "a@example.com", password: "pw 1"), "비밀번호 바로 앞의 글자 칸이 ID")
        sink.messages = []
        _ = try await inPage(view, "p.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));")
        try await wait("Enter") { !sink.messages.isEmpty }
        XCTAssertEqual(sink.messages.first, .candidate(username: "a@example.com", password: "pw 1"))
    }

    func testNothingSentWithoutSingleFilledVisiblePassword() async throws {
        // 빈 비밀번호 · 비밀번호 칸 둘(변경·가입) · 숨긴 칸의 값
        let cases = [
            ("u.value = 'admin'; f.requestSubmit();", form),
            ("p.value = 'old'; n.value = 'new'; f.requestSubmit();", "<form id=f onsubmit='event.preventDefault()'><input id=p type=password><input id=n type=password></form>"),
            ("p.value = 'hidden'; f.requestSubmit();", "<form id=f onsubmit='event.preventDefault()'><input id=p type=password style='display:none'></form>"),
        ]
        for (script, html) in cases {
            let (view, sink) = try await page(html)
            _ = try await inPage(view, script)
            // 같은 페이지에서 잡히는 제출을 한 번 더 내 본다 — 그게 올 때까지 앞의 것이 안 왔으면 안 보낸 것이다
            _ = try await inPage(view, "document.body.insertAdjacentHTML('beforeend', '<form id=g onsubmit=\"event.preventDefault()\"><input id=gp type=password></form>'); f.remove(); gp.value = 'mark'; g.requestSubmit();")
            try await wait("표지 제출") { !sink.messages.isEmpty }
            XCTAssertEqual(sink.messages, [.candidate(username: "", password: "mark")], script)
        }
    }

    func testGoneAfterPasswordFieldDisappears() async throws {
        let (view, sink) = try await page(form)
        _ = try await inPage(view, "u.value = 'admin'; p.value = 's3cret'; b.click(); f.remove();")
        try await wait("gone") { sink.messages.contains(.gone) }
        XCTAssertEqual(sink.messages.first, .candidate(username: "admin", password: "s3cret"))
    }

    func testFieldStillThereSendsNoGone() async throws {
        let (view, sink) = try await page(form)
        _ = try await inPage(view, "u.value = 'admin'; p.value = 'wrong'; b.click();")
        try await Task.sleep(for: .milliseconds(1900))   // 첫 확인(1.5초)이 지난 뒤
        XCTAssertFalse(sink.messages.contains(.gone), "칸이 그대로면(로그인 실패·딴 버튼) 사라졌다고 하지 않는다")
        XCTAssertFalse(sink.messages.isEmpty)
    }

    func testPageCannotSeeScriptOrHandler() async throws {
        let (view, _) = try await page(form)
        let seen = try await inPage(view, "return [typeof window.__nexusLoginWatch, typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(LoginForms.handler))].join()")
        XCTAssertEqual(seen as? String, "undefined,undefined")
    }

    // MARK: 채우기·확인

    func testFillSetsBothAndTellsValueTrackingPage() async throws {
        let (view, _) = try await page(form)
        // 값을 따로 들고 있는 화면 흉내 (React 방식): 노드의 value 를 가로채 기억하고, input 때 실제 값이 기억과 다르면 바뀐 것으로 본다
        _ = try await inPage(view, """
            const d = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value'); let tracked = '';
            Object.defineProperty(p, 'value', { get() { return d.get.call(this) }, set(v) { tracked = v; d.set.call(this, v) } });
            p.addEventListener('input', () => { const now = d.get.call(p); if (now !== tracked) { tracked = now; window.changed = now; } });
            """)
        let filled = try await fill(view, username: "admin", password: "s3cret")
        XCTAssertEqual(filled, .filled)
        let values = try await inPage(view, "return [u.value, p.value, window.changed, document.activeElement.id].join('|')")
        XCTAssertEqual(values as? String, "admin|s3cret|s3cret|p")
    }

    func testFillUserOnlyStepAndNoFields() async throws {
        let (first, _) = try await page("<input type=text name=search><input type=email name=loginfmt id=u>")
        let userOnly = try await fill(first, username: "admin", password: "s3cret")
        XCTAssertEqual(userOnly, .user)
        let typed = try await inPage(first, "return u.value")
        XCTAssertEqual(typed as? String, "admin")
        let (second, _) = try await page("<input type=text name=search><p>글</p>")
        let nothing = try await fill(second, username: "admin", password: "s3cret")
        XCTAssertEqual(nothing, LoginForms.Filled.none)
        let hidden = try await page("<input type=password id=p style='visibility:hidden'>").0
        let skipped = try await fill(hidden, username: "", password: "s3cret")
        XCTAssertEqual(skipped, LoginForms.Filled.none, "숨긴 칸에는 넣지 않는다")
        let leaked = try await inPage(hidden, "return p.value")
        XCTAssertEqual(leaked as? String, "")
    }

    func testVisibleScript() async throws {
        let (view, _) = try await page(form)
        let shown = try await view.callAsyncJavaScript(LoginForms.visibleScript, arguments: [:], in: nil, contentWorld: world)
        XCTAssertEqual(shown as? Bool, true)
        _ = try await inPage(view, "f.remove()")
        let gone = try await view.callAsyncJavaScript(LoginForms.visibleScript, arguments: [:], in: nil, contentWorld: world)
        XCTAssertEqual(gone as? Bool, false)
    }

    func testParse() {
        XCTAssertEqual(LoginForms.parse(["username": "a", "password": "b"]), .candidate(username: "a", password: "b"))
        XCTAssertEqual(LoginForms.parse(["password": "b"]), .candidate(username: "", password: "b"))
        XCTAssertEqual(LoginForms.parse(["gone": true]), .gone)
        XCTAssertNil(LoginForms.parse(["username": "a", "password": ""]))
        XCTAssertNil(LoginForms.parse(["username": "a", "password": 3]))
        XCTAssertNil(LoginForms.parse("글자"))
    }
}
