import Foundation
@testable import ServersCore
import XCTest

final class BookmarkStoreTests: XCTestCase {
    private func add(_ url: String, _ title: String = "T", icon: String? = nil, to key: String = "a", _ state: BookmarkState = .init()) -> BookmarkState {
        BookmarkStore.adding(url: url, title: title, icon: icon, serverKey: key, to: state)
    }

    /// 같은 주소로 보는 기준: 조각·끝 슬래시·스킴과 호스트의 대소문자는 무시, 경로·질의는 구분
    func testKeyTable() {
        XCTAssertEqual(BookmarkStore.key("http://localhost:3000/"), "http://localhost:3000")
        XCTAssertEqual(BookmarkStore.key("HTTP://LocalHost:3000/d/x#panel-2"), "http://localhost:3000/d/x")
        XCTAssertEqual(BookmarkStore.key("http://localhost:3000/d/x/"), BookmarkStore.key("http://localhost:3000/d/x"))
        XCTAssertNotEqual(BookmarkStore.key("http://localhost:3000/d/x"), BookmarkStore.key("http://localhost:3000/d/X"), "경로의 대소문자는 다른 페이지")
        XCTAssertNotEqual(BookmarkStore.key("http://localhost:3000/d?x=1"), BookmarkStore.key("http://localhost:3000/d?x=2"))
        XCTAssertNotEqual(BookmarkStore.key("http://localhost:3000"), BookmarkStore.key("https://localhost:3000"))
    }

    func testBookmarkableOnlyWebAddresses() {
        for ok in ["http://localhost:3000/", "https://wiki.internal.example/deploy", "http://127.0.0.1:9090/graph?g0.expr=up", "http://[fd7a::1]:8080/"] {
            XCTAssertTrue(BookmarkStore.isBookmarkable(ok), ok)
        }
        for bad in ["about:blank", "data:text/html,hi", "file:///etc/hosts", "javascript:alert(1)", "http://", "", "localhost:3000"] {
            XCTAssertFalse(BookmarkStore.isBookmarkable(bad), bad)
        }
    }

    /// 넣기·빼기를 순서대로: 넣은 순서 유지 · 같은 주소는 한 번만 · 서버마다 따로 · 마지막 것을 빼면 서버 칸도 없어진다
    func testAddRemoveSequence() {
        var state = add("http://localhost:3000/d/x", "  Pay \n latency  ")
        state = add("http://localhost:8081/", "cAdvisor", to: "a", state)
        state = add("http://localhost:3000/d/x/#p", "다시", to: "a", state)
        XCTAssertEqual(state.servers["a"]?.map(\.url), ["http://localhost:3000/d/x", "http://localhost:8081/"], "같은 주소(조각·슬래시만 다름)는 다시 넣지 않는다")
        XCTAssertEqual(state.servers["a"]?.first?.title, "Pay latency", "제목의 공백은 한 칸으로")
        state = add("http://localhost:3000/d/x", "B 서버의 것", to: "b", state)
        XCTAssertTrue(BookmarkStore.contains("http://LOCALHOST:3000/d/x/", serverKey: "b", in: state))
        XCTAssertFalse(BookmarkStore.contains("http://localhost:8081", serverKey: "b", in: state), "서버마다 따로")
        XCTAssertFalse(BookmarkStore.contains("http://localhost:3000", serverKey: "none", in: state))

        state = BookmarkStore.removing(url: "http://localhost:3000/d/x#other", serverKey: "a", from: state)
        XCTAssertEqual(state.servers["a"]?.map(\.url), ["http://localhost:8081/"])
        XCTAssertEqual(state.servers["b"]?.count, 1, "다른 서버의 같은 주소는 그대로")
        state = BookmarkStore.removing(url: "http://localhost:8081", serverKey: "a", from: state)
        XCTAssertNil(state.servers["a"], "마지막 것을 빼면 서버 칸도 없어진다")
        XCTAssertEqual(BookmarkStore.removing(url: "http://nothing.example/", serverKey: "zz", from: state), state, "없는 것을 빼도 그대로")
        // 넣을 수 없는 주소
        XCTAssertEqual(add("about:blank", to: "a", state), state)
        XCTAssertEqual(add("javascript:alert(1)", to: "a", state), state)
    }

    func testTitleAndIconAreCleaned() {
        XCTAssertEqual(add("http://localhost:3000/d/x/", "   ").servers["a"]?.first?.title, "localhost:3000/d/x", "제목이 비면 짧은 주소")
        XCTAssertEqual(add("https://wiki.internal.example/", "").servers["a"]?.first?.title, "https://wiki.internal.example", "https 는 스킴을 남긴다")
        XCTAssertEqual(add("http://x.example/", String(repeating: "가", count: 300)).servers["a"]?.first?.title.count, 121, "길면 120자 + …")
        XCTAssertEqual(add("http://x.example/", icon: "data:image/png;base64,AAAA").servers["a"]?.first?.icon, "data:image/png;base64,AAAA")
        XCTAssertNil(add("http://x.example/", icon: "https://cdn.example.com/a.png").servers["a"]?.first?.icon, "data:image/ 만")
        XCTAssertNil(add("http://x.example/", icon: "data:text/html,<script>").servers["a"]?.first?.icon)
        XCTAssertNil(add("http://x.example/", icon: "data:image/png;base64," + String(repeating: "A", count: BookmarkStore.iconLimit)).servers["a"]?.first?.icon, "너무 크면 아이콘 없이")
    }

    func testRenameAndRemoveServer() {
        var state = add("http://localhost:3000/", to: "old")
        state = add("http://localhost:9090/", to: "other", state)
        let renamed = BookmarkStore.renamingServer(from: "old", to: "new", in: state)
        XCTAssertEqual(renamed.servers.keys.sorted(), ["new", "other"])
        XCTAssertEqual(renamed.servers["new"]?.first?.url, "http://localhost:3000/")
        // 옛 이름에 것이 없으면 새 이름에 남아 있던 값(지운 서버의 것)도 지운다
        XCTAssertNil(BookmarkStore.renamingServer(from: "empty", to: "other", in: state).servers["other"])
        XCTAssertEqual(BookmarkStore.renamingServer(from: "old", to: "old", in: state), state)
        XCTAssertEqual(BookmarkStore.removingServer("old", from: state).servers.keys.sorted(), ["other"])
    }

    func testSaveLoadRoundTripAndBrokenFile() throws {
        let dir = tempPath("bookmarks")
        let file = dir.appendingPathComponent("bookmarks.json")
        XCTAssertEqual(BookmarkStore.load(from: file), BookmarkState(), "파일이 없으면 빈 상태")
        let state = add("http://localhost:3000/d/x", "결제 지연", icon: "data:image/png;base64,AAAA")
        try BookmarkStore.save(state, to: file)
        XCTAssertEqual(BookmarkStore.load(from: file), state)
        try Data("{ broken".utf8).write(to: file)
        XCTAssertEqual(BookmarkStore.load(from: file), BookmarkState(), "깨진 파일은 빈 상태 (오류로 막지 않는다)")
    }

    /// 시작 페이지의 즐겨찾기 부분: 없으면 줄 자체가 없다 · 타일 꼴 · ✕ 가 그 주소를 들고 있다 · 바깥 글자는 태그가 되지 않는다
    func testStartPageSection() {
        XCTAssertEqual(BrowserStartPage.bookmarksHTML([]), "")
        let evil = "<script>alert(1)</script>\"&"
        let html = BrowserStartPage.bookmarksHTML([
            BrowserBookmark(url: "http://localhost:3000/d/x", title: "결제 지연", icon: "data:image/png;base64,AAAA"),
            BrowserBookmark(url: "https://wiki.internal.example/a?b=\"1\"", title: evil),
            BrowserBookmark(url: "javascript:alert(1)", title: "파일을 손으로 고쳐 넣은 것"),
        ])
        XCTAssertTrue(html.hasPrefix("<h2>즐겨찾기</h2><div class=\"grid\">"))
        XCTAssertTrue(html.contains("<a class=\"tile\" href=\"http://localhost:3000/d/x\"><img class=\"i\" src=\"data:image/png;base64,AAAA\" alt=\"\">"))
        XCTAssertTrue(html.contains("<div class=\"t\">결제 지연</div><div class=\"b\"><span class=\"u\">localhost:3000/d/x</span>"))
        XCTAssertTrue(html.contains("<button class=\"rm\" data-u=\"http://localhost:3000/d/x\""))
        XCTAssertEqual(html.components(separatedBy: "class=\"i ph\"").count - 1, 1, "아이콘이 없으면 자리 그림")
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("b=\"1\""), "주소의 따옴표도 속성을 끊지 못한다")
        XCTAssertFalse(html.contains("javascript:"), "웹 주소가 아닌 것은 그리지 않는다")
        let page = BrowserStartPage.html(hero: .init(key: "a", target: "u@h", role: nil, tags: [], status: "꺼짐", level: .muted), bookmarksHTML: html, portsHTML: "<p>P</p>")
        XCTAssertTrue(page.contains("<div id=\"marks\"><h2>즐겨찾기</h2>"), "즐겨찾기만 갈아 끼울 자리 — 포트 부분보다 위")
        XCTAssertLessThan(page.range(of: "id=\"marks\"")!.lowerBound, page.range(of: "id=\"ports\"")!.lowerBound)
        XCTAssertTrue(page.contains("messageHandlers.nexus"))
    }

    func testIconData() {
        XCTAssertEqual(BookmarkStore.iconData("data:image/png;base64,AQID"), Data([1, 2, 3]))
        XCTAssertEqual(BookmarkStore.iconData("DATA:image/PNG;BASE64,AQID"), Data([1, 2, 3]), "머리 글자는 대소문자 무시")
        XCTAssertEqual(BookmarkStore.iconData("data:image/svg+xml,%3Csvg%2F%3E").map { String(decoding: $0, as: UTF8.self) }, "<svg/>")
        for bad in [nil, "", "data:text/html;base64,AQID", "data:image/png;base64,", "data:image/png;base64,!!!", "data:image/png", "https://a.example/favicon.ico",
                    "data:image/png;base64," + String(repeating: "A", count: BookmarkStore.iconLimit)] {
            XCTAssertNil(BookmarkStore.iconData(bad), bad ?? "nil")
        }
    }
}
