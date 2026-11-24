import Foundation
import Network
@testable import ServersCore
import XCTest

final class WebProbeTests: XCTestCase {
    func testTitleExtraction() {
        XCTAssertEqual(WebProbe.title(inHTML: "<html><head><TITLE>Dashboard [Jenkins]</TITLE></head>"), "Dashboard [Jenkins]")
        XCTAssertEqual(WebProbe.title(inHTML: "<title data-x=\"1\">\n  Grafana\n   &amp; Loki </title>"), "Grafana & Loki", "속성·줄바꿈·엔티티")
        XCTAssertNil(WebProbe.title(inHTML: "<title>   </title>"))
        XCTAssertNil(WebProbe.title(inHTML: "<h1>no title</h1>"))
        XCTAssertNil(WebProbe.title(inHTML: "<title>닫는 태그 없음"))
        XCTAssertNil(WebProbe.title(inHTML: ""))
        XCTAssertEqual(WebProbe.title(inHTML: "<title>" + String(repeating: "가", count: 200) + "</title>")?.count, 81, "길면 80자 + …")
    }

    func testCandidatesSkipKnownNonWebPorts() {
        func item(_ port: Int, tunnel: String? = "*") -> PortItem { PortItem(port: port, addresses: ["*"], label: RemoteInfo.knownPorts[port], tunnelAddress: tunnel) }
        for web in [80, 443, 3000, 8080, 8443, 9090, 7000, 18080] { XCTAssertTrue(WebProbe.isCandidate(item(web)), "\(web)") }
        for other in [22, 53, 445, 3306, 3389, 5432, 6379, 6443, 27017] { XCTAssertFalse(WebProbe.isCandidate(item(other)), "\(other)") }
        XCTAssertFalse(WebProbe.isCandidate(item(8080, tunnel: nil)), "서버 자신도 닿지 못하는 대기는 묻지 않는다")
        XCTAssertEqual(WebProbe.schemes(for: 443), ["https", "http"])
        XCTAssertEqual(WebProbe.schemes(for: 8080), ["http", "https"])
        XCTAssertTrue(WebProbe.isPlainToTLS(status: 400, body: "The plain HTTP request was sent to HTTPS port"))
        XCTAssertFalse(WebProbe.isPlainToTLS(status: 400, body: "Bad Request"))
        XCTAssertFalse(WebProbe.isPlainToTLS(status: 200, body: "https everywhere"))
    }

    // MARK: 실제 요청 (이 Mac 안에서만 — 가짜 서버 + 브라우저 탭과 같은 중계 두 겹)

    /// 127.0.0.1 의 빈 포트에 정해진 바이트를 돌려주는 리스너
    private func server(replying response: String) async throws -> (NWListener, Int) {
        try await server { _ in Data(response.utf8) }
    }

    /// 요청 글자(첫 줄에 경로)를 보고 답을 정하는 리스너
    private func server(answering: @escaping @Sendable (String) -> Data) async throws -> (NWListener, Int) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "probe-test")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                connection.send(content: answering(String(decoding: data ?? Data(), as: UTF8.self)), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        final class Flag: @unchecked Sendable { let lock = NSLock(); var done = false
            func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } } }
        let flag = Flag()
        let port: Int = try await withCheckedThrowingContinuation { c in
            listener.stateUpdateHandler = { state in
                if case .ready = state, flag.claim() { c.resume(returning: Int(listener.port!.rawValue)) }
                if case let .failed(e) = state, flag.claim() { c.resume(throwing: e) }
            }
            listener.start(queue: queue)
        }
        return (listener, port)
    }

    private func http(_ body: String, status: String = "200 OK") -> String {
        "HTTP/1.1 \(status)\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }

    /// localhost 로 물은 것이 별칭 → 중계 → 상류(서버 역할)의 127.0.0.1 로 가서 제목이 돌아온다. 웹이 아닌 포트·닫힌 포트는 답 없음.
    func testProbeThroughBrowserRelay() async throws {
        let (web, webPort) = try await server(replying: http("<html><title>Grafana</title></html>"))
        let (plain, plainPort) = try await server(replying: http("no title here"))
        let (binary, binaryPort) = try await server(replying: "\u{0}\u{1}NOT-HTTP\r\n")
        let (locked, lockedPort) = try await server(replying: http("<html><title>Sign in</title></html>", status: "401 Unauthorized"))
        defer { web.cancel(); plain.cancel(); binary.cancel(); locked.cancel() }

        // 상류 = ssh -D 역할 (서버에서 연결한다): 127.0.0.1 만 실제로 연결
        let upstream = SocksRelay(upstreamPort: nil) { host, port in host == "127.0.0.1" ? .direct(host: host, port: port) : .deny }
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let relay = SocksRelay(upstreamPort: upstreamPort) { host, port in BrowserPolicy.route(host: host, port: port) }
        let relayPort = try await relay.start()
        defer { relay.stop() }

        let found = await WebProbe.probeAll([(webPort, "localhost"), (plainPort, "127.0.0.1"), (binaryPort, "localhost")], proxyPort: relayPort, timeout: 2)
        XCTAssertEqual(found[webPort], WebProbeResult(scheme: "http", title: "Grafana", status: 200, html: true))
        XCTAssertEqual(found[plainPort], WebProbeResult(scheme: "http", title: nil, status: 200, html: true), "HTTP 로 답했으면 제목이 없어도 웹")
        XCTAssertNil(found[binaryPort], "HTTP 가 아닌 답")
        let denied = await WebProbe.probe(host: "127.0.0.1", port: lockedPort, proxyPort: relayPort, timeout: 2)
        XCTAssertEqual(denied, WebProbeResult(scheme: "http", title: "Sign in", status: 401, html: true), "401·403 의 제목은 로그인 화면의 것이라 쓴다 — 상태는 그대로 싣는다")
        // 중계가 꺼져 있으면 전부 답 없음 (매달리지 않는다)
        relay.stop()
        let started = Date()
        let none = await WebProbe.probeAll([(webPort, "localhost")], proxyPort: relayPort, timeout: 2)
        XCTAssertTrue(none.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
    }

    // MARK: HTML · 제목

    func testHTMLAndUsableTitleTable() {
        XCTAssertTrue(WebProbe.isHTML(contentType: "text/html; charset=utf-8", body: ""))
        XCTAssertTrue(WebProbe.isHTML(contentType: "application/xhtml+xml", body: ""))
        XCTAssertFalse(WebProbe.isHTML(contentType: "application/json", body: "<html>"), "적어 준 종류가 먼저")
        XCTAssertFalse(WebProbe.isHTML(contentType: "text/plain", body: "ok"))
        XCTAssertTrue(WebProbe.isHTML(contentType: nil, body: "\n<!DOCTYPE html><html>"), "종류를 안 적는 서버는 본문 머리로")
        XCTAssertFalse(WebProbe.isHTML(contentType: nil, body: "{\"ok\":true}"))
        XCTAssertFalse(WebProbe.isHTML(contentType: nil, body: ""))

        func title(_ status: Int, _ text: String) -> String? { WebProbe.usableTitle(status: status, html: "<title>\(text)</title>") }
        XCTAssertEqual(title(200, "Grafana"), "Grafana")
        XCTAssertEqual(title(403, "OpenWrt - LuCI"), "OpenWrt - LuCI", "403 으로 오는 로그인 화면")
        XCTAssertEqual(title(401, "Sign in"), "Sign in")
        XCTAssertNil(title(403, "403 Forbidden"), "오류 문구는 이름이 아니다")
        XCTAssertNil(title(401, "401 Authorization Required"))
        XCTAssertNil(title(403, "Forbidden"))
        XCTAssertNil(title(404, "My App"), "401·403 말고는 오류 응답의 제목을 쓰지 않는다")
        XCTAssertNil(title(502, "Bad Gateway"))
        XCTAssertNil(WebProbe.usableTitle(status: 200, html: "no title"))
    }

    func testMetaRefreshTable() {
        let page = URL(string: "http://localhost:8080/")!
        func target(_ html: String) -> String? { WebProbe.metaRefresh(inHTML: html, page: page)?.absoluteString }
        XCTAssertEqual(target("<meta http-equiv=\"refresh\" content=\"0; URL=cgi-bin/luci/\" />"), "http://localhost:8080/cgi-bin/luci/", "LuCI 의 /")
        XCTAssertEqual(target("<META HTTP-EQUIV='Refresh' CONTENT='3;url=/login?a=1&amp;b=2'>"), "http://localhost:8080/login?a=1&b=2")
        XCTAssertEqual(target("<meta content=\"0;URL='https://sso.example.com/x'\" http-equiv=refresh>"), "https://sso.example.com/x", "속성 순서 · 따옴표 안의 따옴표")
        XCTAssertNil(target("<meta http-equiv=\"refresh\" content=\"30\">"), "주소 없는 새로 고침")
        XCTAssertNil(target("<meta charset=\"utf-8\"><meta name=\"viewport\" content=\"url=x\">"))
        XCTAssertNil(target("plain"))
    }

    /// 제목 없는 HTML 이 <meta refresh> 로 넘기고 그 로그인 화면이 403 으로 온다 (LuCI) → 화면이고, 이름은 넘겨진 곳의 제목. JSON 은 화면이 아니다
    func testProbeNamesMetaRefreshPageAndTellsHTMLFromJSON() async throws {
        @Sendable func reply(_ body: String, type: String, status: String = "200 OK") -> Data {
            Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
        }
        final class Seen: @unchecked Sendable { let lock = NSLock(); var items: [String] = []
            func add(_ item: String) { lock.withLock { items.append(item) } } }
        let seen = Seen()
        let (luci, luciPort) = try await server { request in
            seen.add(String(request.split(separator: " ").dropFirst().first ?? ""))
            if request.hasPrefix("GET /cgi-bin/luci/ ") { return reply("<html><head><title>OpenWrt - LuCI</title></head></html>", type: "text/html", status: "403 Forbidden") }
            if request.hasPrefix("GET / ") { return reply("<html><head><meta http-equiv=\"refresh\" content=\"0; URL=cgi-bin/luci/\" /></head><body></body></html>", type: "text/html") }
            return reply("", type: "text/plain", status: "404 Not Found")
        }
        let (api, apiPort) = try await server { _ in reply("{\"status\":\"ok\"}", type: "application/json") }
        let (untitled, untitledPort) = try await server { _ in reply("<html><body>hi</body></html>", type: "text/html") }
        let (forbidden, forbiddenPort) = try await server { _ in reply("<html><title>403 Forbidden</title></html>", type: "text/html", status: "403 Forbidden") }
        defer { [luci, api, untitled, forbidden].forEach { $0.cancel() } }

        let upstream = SocksRelay(upstreamPort: nil) { host, port in host == "127.0.0.1" ? .direct(host: host, port: port) : .deny }
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let relay = SocksRelay(upstreamPort: upstreamPort) { host, port in BrowserPolicy.route(host: host, port: port) }
        let relayPort = try await relay.start()
        defer { relay.stop() }

        let found = await WebProbe.probeAll([(luciPort, "localhost"), (apiPort, "localhost"), (untitledPort, "localhost"), (forbiddenPort, "localhost")],
                                            proxyPort: relayPort, timeout: 2)
        XCTAssertEqual(found[luciPort], WebProbeResult(scheme: "http", title: "OpenWrt - LuCI", status: 200, html: true), "상태는 처음 답(200)의 것 — 403 표시를 달지 않는다")
        XCTAssertEqual(Array(seen.items.prefix(2)), ["/", "/cgi-bin/luci/"])
        XCTAssertEqual(found[apiPort], WebProbeResult(scheme: "http", title: nil, status: 200, html: false))
        XCTAssertEqual(found[untitledPort], WebProbeResult(scheme: "http", title: nil, status: 200, html: true), "제목이 없어도 화면")
        XCTAssertEqual(found[forbiddenPort], WebProbeResult(scheme: "http", title: nil, status: 403, html: true), "오류 문구 제목은 쓰지 않는다")
    }


    // MARK: 이동 (3xx)

    func testRedirectFollowAndTextTable() {
        func url(_ s: String) -> URL { URL(string: s)! }
        let page = BrowserPolicy.proxied(url("http://localhost:8080/"))   // 실제로 묻는 주소는 별칭
        // 따라갈 곳: 같은 서버(루프백끼리 · 같은 호스트)의 http·https 만
        XCTAssertEqual(WebProbe.followTarget(url("https://localhost:8443/login"), from: page), BrowserPolicy.proxied(url("https://localhost:8443/login")))
        XCTAssertEqual(WebProbe.followTarget(url("http://127.0.0.1:9000/"), from: page), BrowserPolicy.proxied(url("http://127.0.0.1:9000/")), "localhost 와 127.0.0.1 은 같은 서버")
        XCTAssertNotNil(WebProbe.followTarget(BrowserPolicy.proxied(url("http://localhost:9000/x")), from: page), "서버가 별칭 이름(Host 헤더)으로 적어 보낸 것")
        XCTAssertNotNil(WebProbe.followTarget(url("https://10.0.0.5:8443/"), from: url("http://10.0.0.5:80/")))
        XCTAssertNil(WebProbe.followTarget(url("https://sso.example.com/login"), from: page), "다른 호스트로는 묻지 않는다")
        XCTAssertNil(WebProbe.followTarget(url("https://10.0.0.6/"), from: url("http://10.0.0.5/")))
        XCTAssertNil(WebProbe.followTarget(url("ftp://localhost/x"), from: page))
        // 화면에 적을 꼴
        XCTAssertEqual(WebProbe.redirectText(url("https://localhost:8443/login?next=%2F#top"), from: page), ":8443/login", "같은 서버: 포트부터, 질의·조각은 뺀다")
        XCTAssertEqual(WebProbe.redirectText(BrowserPolicy.proxied(url("http://localhost:8080/login")), from: page), "/login", "같은 포트면 경로만")
        XCTAssertEqual(WebProbe.redirectText(url("https://localhost/"), from: page), ":443/")
        XCTAssertEqual(WebProbe.redirectText(url("https://sso.example.com/realms/a/login?client=x"), from: page), "sso.example.com/realms/a/login")
        XCTAssertEqual(WebProbe.redirectText(url("https://sso.example.com:8443/"), from: page), "sso.example.com:8443")
        XCTAssertEqual(WebProbe.redirectText(url("https://sso.example.com/" + String(repeating: "a", count: 80)), from: page).count, 61, "길면 자른다")
    }

    /// 같은 서버의 다른 포트로 보내면 한 번 더 물어 그 제목을, 다른 호스트로 보내면 묻지 않고 가리키는 곳만
    func testProbeFollowsRedirectWithinServerOnly() async throws {
        final class Seen: @unchecked Sendable { let lock = NSLock(); var items: [String] = []
            func add(_ item: String) { lock.withLock { items.append(item) } } }
        @Sendable func moved(_ location: String, status: String = "302 Found") -> Data {
            Data("HTTP/1.1 \(status)\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        }
        let loginPage = Data(http("<html><title>Sign in · Grafana</title></html>").utf8)
        let seenLogin = Seen()
        let (login, loginPort) = try await server { request in
            seenLogin.add(String(request.split(separator: " ").dropFirst().first ?? ""))
            return loginPage
        }
        let (blank, blankPort) = try await server(replying: http("{}"))
        let (again, againPort) = try await server { _ in moved("http://127.0.0.1:\(loginPort)/login") }
        // 1) 같은 서버의 다른 포트(이름은 localhost 로 적어 보냄) → 그 페이지의 제목
        let (front, frontPort) = try await server { _ in moved("http://localhost:\(loginPort)/login?next=%2F") }
        // 2) 다른 호스트(SSO) → 묻지 않는다
        let (sso, ssoPort) = try await server { _ in moved("https://sso.example.com/realms/a/login?client=x", status: "303 See Other") }
        // 3) 같은 서버로 보냈지만 거기에 제목이 없다 → 3xx 그대로, 가리키는 곳
        let (dull, dullPort) = try await server { _ in moved("http://127.0.0.1:\(blankPort)/api") }
        // 4) 두 번 넘긴다 → 한 번만 따라가고 멈춘다
        let (twice, twicePort) = try await server { _ in moved("http://127.0.0.1:\(againPort)/hop") }
        // 5) Location 없는 3xx
        let (bare, barePort) = try await server(replying: "HTTP/1.1 302 Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        defer { [login, blank, again, front, sso, dull, twice, bare].forEach { $0.cancel() } }

        let asked = Seen()
        let upstream = SocksRelay(upstreamPort: nil) { host, port in
            asked.add(host)
            return host == "127.0.0.1" ? .direct(host: host, port: port) : .deny
        }
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let relay = SocksRelay(upstreamPort: upstreamPort) { host, port in BrowserPolicy.route(host: host, port: port) }
        let relayPort = try await relay.start()
        defer { relay.stop() }

        let found = await WebProbe.probeAll([(frontPort, "127.0.0.1"), (ssoPort, "localhost"), (dullPort, "localhost"), (twicePort, "localhost"), (barePort, "localhost")],
                                            proxyPort: relayPort, timeout: 2)
        XCTAssertEqual(found[frontPort], WebProbeResult(scheme: "http", title: "Sign in · Grafana", status: 302, redirect: ":\(loginPort)/login", redirectPort: loginPort, html: true),
                       "넘겨진 곳의 제목 — 여는 주소·상태는 처음 포트 그대로")
        XCTAssertEqual(seenLogin.items.first, "/login?next=%2F")
        XCTAssertEqual(found[ssoPort], WebProbeResult(scheme: "http", title: nil, status: 303, redirect: "sso.example.com/realms/a/login"))
        XCTAssertEqual(found[dullPort], WebProbeResult(scheme: "http", title: nil, status: 302, redirect: ":\(blankPort)/api", redirectPort: blankPort))
        XCTAssertEqual(found[twicePort], WebProbeResult(scheme: "http", title: nil, status: 302, redirect: ":\(againPort)/hop", redirectPort: againPort), "두 번째 이동은 따라가지 않는다")
        XCTAssertEqual(found[barePort], WebProbeResult(scheme: "http", title: nil, status: 302))
        XCTAssertEqual(Set(asked.items), ["127.0.0.1"], "다른 호스트(SSO)로는 연결조차 하지 않는다")
    }

    // MARK: 아이콘

    func testIconHrefTable() {
        XCTAssertEqual(WebProbe.iconHref(inHTML: "<head><link rel=\"stylesheet\" href=\"a.css\"><link rel=\"icon\" href=\"/static/fav.png\"></head>"), "/static/fav.png")
        XCTAssertEqual(WebProbe.iconHref(inHTML: "<LINK HREF='public/img/fav32.png?v=1&amp;x=2' TYPE='image/png' REL='shortcut icon'>"), "public/img/fav32.png?v=1&x=2", "대문자·작은따옴표·순서·엔티티")
        XCTAssertEqual(WebProbe.iconHref(inHTML: "<link rel=icon href=fav.ico>"), "fav.ico", "따옴표 없는 속성")
        XCTAssertEqual(WebProbe.iconHref(inHTML: "<link rel=\"apple-touch-icon\" href=\"big.png\"><link rel=\"mask-icon\" href=\"m.svg\"><link rel=\"icon\" href=\"s.png\">"), "s.png", "icon 토큰만")
        XCTAssertNil(WebProbe.iconHref(inHTML: "<link rel=\"apple-touch-icon\" href=\"big.png\">"))
        XCTAssertNil(WebProbe.iconHref(inHTML: "<link rel=\"icon\" href=\"\">"))
        XCTAssertNil(WebProbe.iconHref(inHTML: "<link rel=\"icon\">"))
        XCTAssertNil(WebProbe.iconHref(inHTML: ""))
    }

    /// 받을 주소: 페이지가 적은 것(같은 호스트·포트만) → /favicon.ico. 바깥 주소로는 묻지 않는다.
    func testIconURLsStaySameOrigin() {
        let page = URL(string: "http://127-0-0-1.server.localhost:3000/login")!
        func urls(_ href: String?) -> [String] { WebProbe.iconURLs(href: href, page: page).map(\.absoluteString) }
        let fallback = "http://127-0-0-1.server.localhost:3000/favicon.ico"
        XCTAssertEqual(urls(nil), [fallback])
        XCTAssertEqual(urls("public/fav.png"), ["http://127-0-0-1.server.localhost:3000/public/fav.png", fallback], "상대 주소는 페이지 기준")
        XCTAssertEqual(urls("/favicon.ico"), [fallback], "같은 주소는 한 번만")
        XCTAssertEqual(urls("http://127.0.0.1:3000/a.png"), ["http://127-0-0-1.server.localhost:3000/a.png", fallback], "루프백 절대 주소는 별칭으로")
        XCTAssertEqual(urls("https://cdn.example.com/a.png"), [fallback], "다른 호스트")
        XCTAssertEqual(urls("http://127.0.0.1:9999/a.png"), [fallback], "다른 포트")
        XCTAssertEqual(urls("javascript:alert(1)"), [fallback])
    }

    func testImageDataURISniffsTheBytes() {
        XCTAssertEqual(WebProbe.imageDataURI(Data([0x89, 0x50, 0x4E, 0x47, 1, 2])), "data:image/png;base64,iVBORwEC")
        XCTAssertTrue(WebProbe.imageDataURI(Data([0, 0, 1, 0, 1, 0]))?.hasPrefix("data:image/x-icon;base64,") ?? false)
        XCTAssertTrue(WebProbe.imageDataURI(Data([0x47, 0x49, 0x46, 0x38, 0x39]))?.hasPrefix("data:image/gif;") ?? false)
        XCTAssertTrue(WebProbe.imageDataURI(Data([0xFF, 0xD8, 0xFF, 0xE0]))?.hasPrefix("data:image/jpeg;") ?? false)
        XCTAssertTrue(WebProbe.imageDataURI(Data("RIFF\u{1}\u{2}\u{3}\u{4}WEBPVP8 ".utf8))?.hasPrefix("data:image/webp;") ?? false)
        XCTAssertTrue(WebProbe.imageDataURI(Data("<?xml version=\"1.0\"?><svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8))?.hasPrefix("data:image/svg+xml;") ?? false)
        XCTAssertNil(WebProbe.imageDataURI(Data("<!doctype html><html><title>Not Found</title>".utf8)), "없는 favicon.ico 에 HTML 을 주는 서버")
        XCTAssertNil(WebProbe.imageDataURI(Data()))
    }

    /// 제목 있는 페이지의 아이콘을 같은 길(별칭 → 중계 → 상류)로 받아 data: 주소로 싣는다. 그림이 아니거나 오류 페이지면 없음.
    func testProbeFetchesIconThroughRelay() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 9, 9])
        final class Seen: @unchecked Sendable { let lock = NSLock(); var paths: [String] = []
            func add(_ request: String) { lock.withLock { paths.append(String(request.split(separator: " ").dropFirst().first ?? "")) } } }
        @Sendable func bytes(_ body: Data, type: String, status: String = "200 OK") -> Data {
            Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
        }
        @Sendable func page(_ html: String) -> Data { bytes(Data(html.utf8), type: "text/html") }
        let seenLinked = Seen(), seenBroken = Seen(), seenError = Seen()
        // 1) <link rel="icon"> 이 가리키는 그림
        let (linked, linkedPort) = try await server { request in
            seenLinked.add(request)
            if request.hasPrefix("GET /static/fav.png ") { return bytes(png, type: "image/png") }
            return page("<html><head><title>Grafana</title><link rel=\"icon\" href=\"static/fav.png\"></head></html>")
        }
        // 2) 링크가 없고 /favicon.ico 에는 HTML 을 200 으로 준다 (그림이 아님)
        let (broken, brokenPort) = try await server { request in
            seenBroken.add(request)
            return page("<html><title>App</title></html>")
        }
        // 3) 오류 페이지 — 제목을 쓰지 않으니 아이콘도 묻지 않는다
        let (failing, failingPort) = try await server { request in
            seenError.add(request)
            return bytes(Data("<html><title>404 Not Found</title><link rel=\"icon\" href=\"/x.png\"></html>".utf8), type: "text/html", status: "404 Not Found")
        }
        defer { linked.cancel(); broken.cancel(); failing.cancel() }

        let upstream = SocksRelay(upstreamPort: nil) { host, port in host == "127.0.0.1" ? .direct(host: host, port: port) : .deny }
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let relay = SocksRelay(upstreamPort: upstreamPort) { host, port in BrowserPolicy.route(host: host, port: port) }
        let relayPort = try await relay.start()
        defer { relay.stop() }

        let found = await WebProbe.probeAll([(linkedPort, "localhost"), (brokenPort, "127.0.0.1"), (failingPort, "127.0.0.1")], proxyPort: relayPort, timeout: 2)
        XCTAssertEqual(found[linkedPort], WebProbeResult(scheme: "http", title: "Grafana", status: 200, icon: "data:image/png;base64,\(png.base64EncodedString())", html: true))
        XCTAssertEqual(seenLinked.paths, ["/", "/static/fav.png"])
        XCTAssertEqual(found[brokenPort], WebProbeResult(scheme: "http", title: "App", status: 200, icon: nil, html: true), "그림이 아닌 답은 아이콘으로 쓰지 않는다")
        XCTAssertEqual(seenBroken.paths, ["/", "/favicon.ico"])
        XCTAssertEqual(found[failingPort], WebProbeResult(scheme: "http", title: nil, status: 404, icon: nil, html: true))
        XCTAssertEqual(seenError.paths, ["/"], "제목 없는 응답에는 아이콘 요청을 보내지 않는다")
    }
}
