import Foundation
@testable import ServersCore
import XCTest

final class BrowserStartPageTests: XCTestCase {
    private func item(_ port: Int, _ addresses: [String] = ["*"], process: String? = nil, tunnel: String? = "*") -> PortItem {
        PortItem(port: port, addresses: addresses, label: RemoteInfo.knownPorts[port], process: process, tunnelAddress: tunnel)
    }

    private let hero = BrowserStartPage.Hero(key: "jenkins", target: "deploy@10.20.4.11", role: "CI/CD", tags: ["PROD", "Jenkins", "QA"], status: "접속 가능", level: .good)
    /// 나누기 표: 이름 붙인 포트 · 제목과 함께 답한 포트 · 제목 없이 답한 포트 · 묻는 중 · 답 없음 · 알려진 비웹 · 닿지 못하는 대기
    func testSectionsTable() {
        let list = [item(22), item(80), item(5432, ["127.0.0.1"], tunnel: "127.0.0.1"), item(7000), item(8443), item(9000, tunnel: nil), item(9090)]
        let probes = [80: WebProbeResult(scheme: "http", title: "Welcome to nginx!", status: 200, icon: "data:image/png;base64,AAAA"),
                      8443: WebProbeResult(scheme: "https", title: nil, status: 404), 9090: WebProbeResult(scheme: "http", title: "Dashboard [Jenkins]")]
        let named = [QuickTunnel(name: "Jenkins", port: 9090), QuickTunnel(name: nil, port: 3000)]

        // 다 물은 뒤
        var (web, bare, other) = BrowserStartPage.sections(named: named, ports: list, probes: probes, probed: true)
        XCTAssertEqual(web.map(\.port), [9090, 3000, 80], "이름 붙인 포트(적은 순서) 먼저, 그다음 제목과 함께 답한 포트(번호 순)")
        XCTAssertEqual(web[0], .init(port: 9090, title: "Jenkins", detail: "Dashboard [Jenkins]", url: "http://localhost:9090/"))
        XCTAssertEqual(web[1], .init(port: 3000, title: "포트 3000", detail: "", url: "http://localhost:3000/"), "목록에 없고 이름도 없는 tunnel_ports — 답이 없어도 타일")
        XCTAssertEqual(web[2], .init(port: 80, title: "Welcome to nginx!", detail: "", url: "http://localhost:80/", status: 200, icon: "data:image/png;base64,AAAA"))
        XCTAssertEqual(bare, [.init(port: 8443, label: "https-alt", url: "https://localhost:8443/", status: 404)], "제목 없이 답한 포트는 칩 — 답한 스킴으로 연다")
        XCTAssertEqual(other.map(\.port), [22, 5432, 7000, 9000], "알려진 비웹 · 답 없음 · 닿지 못하는 대기")
        XCTAssertEqual(other[0], .init(port: 22, label: "ssh", addresses: "*"))
        XCTAssertEqual(other[1].addresses, "127.0.0.1")

        // 아직 묻는 중: 물어볼 포트는 칩 줄에 (답이 오면 타일·칩·그 밖으로 갈린다)
        (web, bare, other) = BrowserStartPage.sections(named: [], ports: list, probes: [:], probed: false)
        XCTAssertTrue(web.isEmpty)
        XCTAssertEqual(bare.map(\.port), [80, 7000, 8443, 9090])
        XCTAssertTrue(bare.allSatisfy { $0.status == nil })
        XCTAssertEqual(other.map(\.port), [22, 5432, 9000])

        // 빈 상태
        (web, bare, other) = BrowserStartPage.sections(named: [], ports: [], probes: [:], probed: false)
        XCTAssertTrue(web.isEmpty && bare.isEmpty && other.isEmpty)
    }

    func testHostFollowsWhereThePortListens() {
        XCTAssertEqual(BrowserStartPage.host(for: item(8080)), "localhost", "모든 주소 대기")
        XCTAssertEqual(BrowserStartPage.host(for: item(8443, ["100.101.0.1"], tunnel: "100.101.0.1")), "100.101.0.1", "특정 주소에만 묶임")
        XCTAssertEqual(BrowserStartPage.host(for: item(8443, ["fd7a::1"], tunnel: "fd7a::1")), "[fd7a::1]", "IPv6 는 대괄호")
        XCTAssertNil(BrowserStartPage.host(for: item(9000, tunnel: nil)))
        let (web, _, _) = BrowserStartPage.sections(named: [], ports: [item(7001, ["127.0.0.1"], tunnel: "127.0.0.1"), item(7002, ["10.0.0.5"], tunnel: "10.0.0.5"), item(7003)],
                                                    probes: [7001: WebProbeResult(scheme: "http", title: "x"), 7002: WebProbeResult(scheme: "http", title: "y"), 7003: WebProbeResult(scheme: "http", title: "z")], probed: true)
        XCTAssertEqual(web.map(\.url), ["http://127.0.0.1:7001/", "http://10.0.0.5:7002/", "http://localhost:7003/"])
        XCTAssertEqual(web.map(\.address), ["", "10.0.0.5", ""], "타일에는 특정 주소에 묶였을 때만 주소를 적는다 (루프백·localhost 는 포트와 중복)")
    }

    func testProbeTargetsSkipKnownNonWebAndUnreachable() {
        let list = [item(22), item(80), item(5432), item(7000, ["10.0.0.5"], tunnel: "10.0.0.5"), item(9000, tunnel: nil), item(9090)]
        let targets = BrowserStartPage.probeTargets(named: [QuickTunnel(name: "Jenkins", port: 9090), QuickTunnel(name: "DB UI", port: 5432)], ports: list)
        XCTAssertEqual(targets.map(\.port), [9090, 5432, 80, 7000], "이름 붙인 포트는 비웹 번호여도 묻는다 (사용자가 웹이라고 적은 것)")
        XCTAssertEqual(targets.map(\.host), ["localhost", "localhost", "localhost", "10.0.0.5"])
        XCTAssertTrue(BrowserStartPage.probeTargets(named: [], ports: []).isEmpty)
    }

    func testPortsHTMLStates() {
        let named = [QuickTunnel(name: "Jenkins", port: 9090)]
        let loading = BrowserStartPage.portsHTML(named: [], state: .loading, probes: [:], probed: false)
        XCTAssertTrue(loading.contains("읽는 중"))
        XCTAssertFalse(loading.contains("class=\"grid\""))
        // 읽는 중·실패여도 이름 붙은 포트는 타일로 보인다
        let failed = BrowserStartPage.portsHTML(named: named, state: .failed, probes: [:], probed: false)
        XCTAssertTrue(failed.contains("href=\"http://localhost:9090/\""))
        XCTAssertTrue(failed.contains("읽지 못했습니다"))
        let loaded = BrowserStartPage.portsHTML(named: named, state: .loaded([item(22), item(443), item(9090)]),
                                                probes: [443: WebProbeResult(scheme: "https", title: "Admin")], probed: true)
        XCTAssertTrue(loaded.contains("<h2>웹</h2>") && loaded.contains("<h2>그 밖</h2>"))
        XCTAssertTrue(loaded.contains("href=\"https://localhost:443/\""))
        XCTAssertTrue(loaded.contains("<span class=\"n\">443</span><span class=\"k\">https</span>"), "https 는 작은 표시로만")
        XCTAssertFalse(loaded.contains(">localhost:9090<"), "주소 줄은 없다 — 포트가 이미 말한다")
        XCTAssertFalse(loaded.contains("class=\"chips\""), "제목 없는 응답이 없으면 칩 줄도 없다")
        XCTAssertFalse(loaded.contains("읽는 중"))
        XCTAssertTrue(BrowserStartPage.portsHTML(named: [], state: .loaded([]), probes: [:], probed: true).contains("열려 있는 포트가 없습니다"))
    }

    func testPageHasHeroAddressBoxAndPortsSlot() {
        let html = BrowserStartPage.html(hero: hero, portsHTML: "<p>PORTS</p>")
        XCTAssertTrue(html.contains("<title>jenkins</title>"))
        XCTAssertTrue(html.contains("deploy@10.20.4.11 · CI/CD"))
        XCTAssertTrue(html.contains("<span class=\"tag prod\">PROD</span><span class=\"tag\">Jenkins</span><span class=\"tag stg\">QA</span>"), "태그 색은 본창과 같은 분류")
        XCTAssertTrue(html.contains("<span class=\"pill good\"><i></i>접속 가능</span>"))
        XCTAssertTrue(html.contains("<div id=\"ports\"><p>PORTS</p></div>"), "포트 부분만 갈아 끼울 자리")
        XCTAssertTrue(html.contains("id=\"q\""))
        let noRole = BrowserStartPage.html(hero: .init(key: "a", target: "u@h", role: nil, tags: [], status: "꺼짐", level: .muted), portsHTML: "")
        XCTAssertTrue(noRole.contains("<div class=\"sub\">u@h</div>"))
        XCTAssertTrue(noRole.contains("pill muted"))
    }

    /// 이름·역할·페이지 제목은 바깥에서 온 글자 — 태그로 해석되지 않게
    func testEscapesOutsideText() {
        let evil = "<script>alert(1)</script>\"&"
        let ports = BrowserStartPage.portsHTML(named: [QuickTunnel(name: evil, port: 1)], state: .loaded([item(7000)]),
                                               probes: [1: WebProbeResult(scheme: "http", title: evil), 7000: WebProbeResult(scheme: "http", title: evil, icon: "data:x\" onerror=\"alert(1)")], probed: true)
        XCTAssertFalse(ports.contains("<script>"))
        XCTAssertFalse(ports.contains("\" onerror=\""), "아이콘 주소도 바깥에서 온 글자")
        XCTAssertTrue(ports.contains("&lt;script&gt;alert(1)&lt;/script&gt;&quot;&amp;"))
        let page = BrowserStartPage.html(hero: .init(key: evil, target: evil, role: evil, tags: [evil], status: evil, level: .bad), portsHTML: "")
        XCTAssertFalse(page.contains("<script>alert"))
    }

    /// 상태 코드 표시 표: 2xx·모름은 없음, 그 밖은 숫자, 5xx 만 경고색. 웹인지 가르는 데는 쓰지 않는다 (401·404 도 답한 것).
    func testStatusBadgeTable() {
        func badge(_ status: Int?) -> String? { BrowserStartPage.badge(status).map { $0.text + ($0.warn ? "!" : "") } }
        XCTAssertNil(badge(nil), "상태를 모름 (TLS 포트 추정 · 아직 안 물은 포트)")
        XCTAssertNil(badge(200)); XCTAssertNil(badge(204)); XCTAssertNil(badge(299))
        XCTAssertEqual(badge(302), "302"); XCTAssertEqual(badge(401), "401"); XCTAssertEqual(badge(404), "404"); XCTAssertEqual(badge(199), "199")
        XCTAssertEqual(badge(500), "500!"); XCTAssertEqual(badge(502), "502!")

        let probes = [7000: WebProbeResult(scheme: "http", title: nil, status: 401), 7001: WebProbeResult(scheme: "http", title: "ok", status: 200),
                      7002: WebProbeResult(scheme: "http", title: nil, status: 502), 9090: WebProbeResult(scheme: "http", title: nil, status: 404)]
        let list = [item(7000), item(7001), item(7002), item(9090)]
        let named = [QuickTunnel(name: "Admin", port: 9090)]
        let (web, bare, other) = BrowserStartPage.sections(named: named, ports: list, probes: probes, probed: true)
        XCTAssertEqual(web.map(\.port), [9090, 7001])
        XCTAssertEqual(web.map(\.status), [404, 200], "이름 붙인 포트에도 상태가 실린다")
        XCTAssertEqual(bare.map(\.port), [7000, 7002], "2xx 가 아니어도 답했으면 그 밖이 아니라 칩")
        XCTAssertEqual(bare.map(\.status), [401, 502])
        XCTAssertTrue(other.isEmpty)
        let html = BrowserStartPage.portsHTML(named: named, state: .loaded(list), probes: probes, probed: true)
        XCTAssertTrue(html.contains("<span class=\"n\">7000</span><span class=\"s\">401</span>"))
        XCTAssertTrue(html.contains("<span class=\"s warn\">502</span>"))
        XCTAssertTrue(html.contains("<span class=\"n\">9090</span><span class=\"s\">404</span>"), "타일 아랫줄")
        XCTAssertFalse(html.contains(">200<"), "2xx 는 붙이지 않는다")
    }

    /// 타일의 아이콘 자리 · 칩 줄 제목 · 아랫줄에 붙는 것(묶인 주소 · 이름 붙인 포트의 페이지 제목)
    func testTileAndChipHTML() {
        let list = [item(3000), item(7002, ["10.0.0.5"], tunnel: "10.0.0.5"), item(8080), item(9090)]
        let probes = [3000: WebProbeResult(scheme: "http", title: "Grafana", status: 200, icon: "data:image/png;base64,AAAA"),
                      7002: WebProbeResult(scheme: "http", title: "Bound", status: 200), 8080: WebProbeResult(scheme: "http", title: nil, status: 301),
                      9090: WebProbeResult(scheme: "http", title: "Dashboard", status: 200)]
        let html = BrowserStartPage.portsHTML(named: [QuickTunnel(name: "CI", port: 9090)], state: .loaded(list), probes: probes, probed: true)
        XCTAssertTrue(html.contains("<img class=\"i\" src=\"data:image/png;base64,AAAA\" alt=\"\"><div class=\"x\"><div class=\"t\">Grafana</div>"))
        XCTAssertEqual(html.components(separatedBy: "class=\"i ph\"").count - 1, 2, "아이콘이 없는 타일(7002·9090)은 자리 그림")
        XCTAssertTrue(html.contains("<span class=\"n\">7002</span><span class=\"e\">10.0.0.5</span>"))
        XCTAssertTrue(html.contains("<div class=\"t\">CI</div><div class=\"b\"><span class=\"n\">9090</span><span class=\"e\">Dashboard</span>"))
        XCTAssertTrue(html.contains("<h2>제목 없는 응답</h2><div class=\"chips\"><a class=\"chip\" href=\"http://localhost:8080/\"><span class=\"n\">8080</span><em>http-alt</em><span class=\"s\">301</span></a>"))
        // 묻는 중: 칩 줄 제목이 다르고 상태는 없다
        let probing = BrowserStartPage.portsHTML(named: [], state: .loaded(list), probes: [:], probed: false)
        XCTAssertTrue(probing.contains("<h2>확인 중…</h2>"))
        XCTAssertFalse(probing.contains("<h2>웹</h2>") || probing.contains("class=\"s\""))
    }
}
