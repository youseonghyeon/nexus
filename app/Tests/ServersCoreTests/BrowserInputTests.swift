// BrowserInput: 주소창·시작 페이지 입력칸에 친 글자 → 주소 또는 Google 검색 (판정 표)

import XCTest
@testable import ServersCore

final class BrowserInputTests: XCTestCase {
    private func open(_ text: String) -> String? { BrowserInput.resolve(text)?.absoluteString }
    private func google(_ encoded: String) -> String { "https://www.google.com/search?q=" + encoded }

    func testAddresses() {
        XCTAssertEqual(open("3000"), "http://localhost:3000/", "숫자만 = 그 서버의 포트")
        XCTAssertEqual(open(" 8080 "), "http://localhost:8080/")
        XCTAssertEqual(open("https://example.com/a?b=1"), "https://example.com/a?b=1")
        XCTAssertEqual(open("http://127.0.0.1:3000/"), "http://127.0.0.1:3000/")
        XCTAssertEqual(open("db:5432"), "http://db:5432", "호스트:포트 는 점이 없어도 주소")
        XCTAssertEqual(open("10.0.0.5:8080/metrics"), "http://10.0.0.5:8080/metrics")
        XCTAssertEqual(open("192.0.2.10"), "http://192.0.2.10")
        XCTAssertEqual(open("localhost"), "http://localhost")
        XCTAssertEqual(open("localhost/admin"), "http://localhost/admin")
        XCTAssertEqual(open("grafana.localhost"), "http://grafana.localhost")
        XCTAssertEqual(open("wiki.example.com"), "http://wiki.example.com")
        XCTAssertEqual(open("example.dev/a#x"), "http://example.dev/a#x")
        XCTAssertEqual(open("[::1]:8080"), "http://[::1]:8080")
        XCTAssertEqual(open("jenkins/"), "http://jenkins/", "점 없는 이름은 끝에 / 를 붙이면 주소")
        XCTAssertEqual(open("jenkins/job/x"), "http://jenkins/job/x")
        XCTAssertEqual(open("about:blank"), "about:blank")
    }

    func testSearches() {
        XCTAssertEqual(open("grafana"), google("grafana"), "점 없는 한 단어는 검색")
        XCTAssertEqual(open("grafana 대시보드 설정"), google("grafana%20%EB%8C%80%EC%8B%9C%EB%B3%B4%EB%93%9C%20%EC%84%A4%EC%A0%95"))
        XCTAssertEqual(open("c++ a&b=c"), google("c%2B%2B%20a%26b%3Dc"), "+ & = 도 검색어 그대로")
        XCTAssertEqual(open("? example.com"), google("example.com"), "? 로 시작하면 주소 꼴이어도 검색")
        XCTAssertEqual(open("v1.2"), google("v1.2"), "끝 이름이 숫자면 도메인이 아니다")
        XCTAssertEqual(open("a.b"), google("a.b"), "끝 이름이 한 글자")
        XCTAssertEqual(open("1.2.3"), google("1.2.3"), "IP 가 아닌 숫자 점")
        XCTAssertEqual(open("999.1.1.1"), google("999.1.1.1"))
        XCTAssertEqual(open("70000"), google("70000"), "포트 범위 밖 숫자")
        XCTAssertEqual(open("0"), google("0"))
        XCTAssertEqual(open("host:abc"), google("host%3Aabc"), "포트 자리가 숫자가 아니다")
        XCTAssertEqual(open(":8080"), google("%3A8080"))
        XCTAssertEqual(open("ftp://example.com"), google("ftp%3A%2F%2Fexample.com"), "웹이 아닌 스킴은 열지 않는다")
        XCTAssertEqual(open("example.com bad"), google("example.com%20bad"), "띄어쓰기가 있으면 검색")
    }

    func testEmpty() {
        XCTAssertNil(BrowserInput.resolve(""))
        XCTAssertNil(BrowserInput.resolve("   "))
        XCTAssertNil(BrowserInput.resolve("?"), "검색어 없는 ?")
    }
}
