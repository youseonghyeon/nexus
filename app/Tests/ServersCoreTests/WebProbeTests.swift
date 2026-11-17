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
        XCTAssertEqual(found[webPort], WebProbeResult(scheme: "http", title: "Grafana", status: 200))
        XCTAssertEqual(found[plainPort], WebProbeResult(scheme: "http", title: nil, status: 200), "HTTP 로 답했으면 제목이 없어도 웹")
        XCTAssertNil(found[binaryPort], "HTTP 가 아닌 답")
        let denied = await WebProbe.probe(host: "127.0.0.1", port: lockedPort, proxyPort: relayPort, timeout: 2)
        XCTAssertEqual(denied, WebProbeResult(scheme: "http", title: nil, status: 401), "2xx 가 아니어도 HTTP 로 답했으면 웹 — 상태는 싣고, 오류 응답의 제목은 쓰지 않는다")
        // 중계가 꺼져 있으면 전부 답 없음 (매달리지 않는다)
        relay.stop()
        let started = Date()
        let none = await WebProbe.probeAll([(webPort, "localhost")], proxyPort: relayPort, timeout: 2)
        XCTAssertTrue(none.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
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
        XCTAssertEqual(found[linkedPort], WebProbeResult(scheme: "http", title: "Grafana", status: 200, icon: "data:image/png;base64,\(png.base64EncodedString())"))
        XCTAssertEqual(seenLinked.paths, ["/", "/static/fav.png"])
        XCTAssertEqual(found[brokenPort], WebProbeResult(scheme: "http", title: "App", status: 200, icon: nil), "그림이 아닌 답은 아이콘으로 쓰지 않는다")
        XCTAssertEqual(seenBroken.paths, ["/", "/favicon.ico"])
        XCTAssertEqual(found[failingPort], WebProbeResult(scheme: "http", title: nil, status: 404, icon: nil))
        XCTAssertEqual(seenError.paths, ["/"], "제목 없는 응답에는 아이콘 요청을 보내지 않는다")
    }
}
