import Foundation
@testable import ServersCore
import XCTest

final class HostsFileTests: XCTestCase {
    /// macOS 기본 줄·주석·빈 줄은 빼고, 앱 줄(# servers-app)은 표시, 직접 넣은 줄은 그대로 (파일 순서·줄 번호 유지)
    func testSkipsDefaultsAndMarksAppLines() {
        let text = """
        ##
        # Host Database
        ##
        127.0.0.1\tlocalhost
        255.255.255.255\tbroadcasthost
        ::1             localhost

        127.0.0.2\tjenkins.acme\t# servers-app
        10.0.0.5  nas nas.home   # 집 NAS
        127.0.0.1 dev.local
        """
        let entries = HostsFile.parse(text)
        XCTAssertEqual(entries.map(\.address), ["127.0.0.2", "10.0.0.5", "127.0.0.1"])
        XCTAssertEqual(entries.map(\.names), [["jenkins.acme"], ["nas", "nas.home"], ["dev.local"]])
        XCTAssertEqual(entries.map(\.byApp), [true, false, false])
        XCTAssertEqual(entries.map(\.line), [8, 9, 10])
    }

    /// 같은 이름은 앞 줄이 이긴다 (대소문자 무시). IPv4 줄과 IPv6 줄은 따로 — 둘 다 쓰인다
    func testLaterDuplicateIsShadowedPerFamily() {
        let text = """
        10.0.0.5 db.acme
        127.0.0.3 DB.acme api.acme # servers-app
        fd00::5 db.acme
        """
        let entries = HostsFile.parse(text)
        XCTAssertEqual(entries.map(\.shadowed), [[], ["DB.acme"], []])
    }

    /// 기본 줄 이름이 앞에 있으면 뒤의 localhost 재정의도 가려진 것으로
    func testDefaultLineStillTakesItsName() {
        let entries = HostsFile.parse("127.0.0.1 localhost\n10.0.0.9 localhost\n")
        XCTAssertEqual(entries.map(\.address), ["10.0.0.9"])
        XCTAssertEqual(entries.first?.shadowed, ["localhost"])
    }

    /// 빈 파일·주석만·이름 없는 줄·표식이 다른 주석은 앱 줄이 아님
    func testEdgeCases() {
        XCTAssertEqual(HostsFile.parse(""), [])
        XCTAssertEqual(HostsFile.parse("# only\n\n   \n10.0.0.1\n"), [])
        XCTAssertEqual(HostsFile.parse("10.0.0.1 a # servers-app-old\n").first?.byApp, false)
        XCTAssertNil(HostsFile.read(path: "/nonexistent/hosts"))
    }
}
