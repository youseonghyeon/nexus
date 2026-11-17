// Wi-Fi 상세: sudo wdutil info 의 WIFI 구역 파싱. Fixtures/wdutil-info.txt 는 이 Mac 의 실제 출력(2026-10-14)에서
// MAC·서비스 ID 를 가짜로 바꾸고 블루투스 기기·지원 채널 목록을 줄인 것이다.

import XCTest
@testable import ServersCore

final class WiFiDetailTests: XCTestCase {
    private var fixture: String {
        (try? fixtureText("wdutil-info")) ?? ""
    }

    func testParsesRootOnlyValues() {
        let detail = WiFiDetail.parse(fixture)
        XCTAssertEqual(detail.cca, 4)
        XCTAssertEqual(detail.mcs, 9)
        XCTAssertEqual(detail.nss, 2)
        XCTAssertEqual(detail.guardInterval, 400)
        XCTAssertEqual(detail.countryCode, "KR")
        XCTAssertFalse(detail.isEmpty)
    }

    func testCarriageReturnLinesFromPasswordPath() {
        // 암호 창 경로(osascript)는 줄 끝을 \r 로 바꾼다 — 같은 값이 나와야 한다
        let cr = WiFiDetail.parse(fixture.replacingOccurrences(of: "\n", with: "\r"))
        let crlf = WiFiDetail.parse(fixture.replacingOccurrences(of: "\n", with: "\r\n"))
        XCTAssertEqual(cr.mcs, 9)
        XCTAssertEqual(cr.countryCode, "KR")
        XCTAssertEqual(crlf.nss, 2)
    }

    func testOnlyWiFiSection() {
        // 다른 구역의 같은 키는 무시한다 (WIFI FAULTS 처럼 WIFI 로 시작하는 구역도 다른 구역)
        let text = """
        ————
        AWDL
        ————
            MCS Index            : 3
        ————
        WIFI FAULTS LAST HOUR
        ————
            CCA                  : 80 %
        """
        XCTAssertTrue(WiFiDetail.parse(text).isEmpty)
    }

    func testOffOrFailed() {
        // Wi-Fi 가 꺼졌거나 연결 전: 값이 None·비어 있음 → 빈 값
        let off = "————\nWIFI\n————\n    Power                : Off [Off]\n    CCA                  : None\n    MCS Index            :\n"
        XCTAssertTrue(WiFiDetail.parse(off).isEmpty)
        XCTAssertTrue(WiFiDetail.parse("").isEmpty)
        // 권한 없이 돌면 사용법만 나온다
        XCTAssertTrue(WiFiDetail.parse("usage: sudo wdutil diagnose [-q] [-f outputDirectoryPath]\n       sudo wdutil info\n").isEmpty)
    }

    func testScriptRunsWdutilAsRootThroughSharedAuth() {
        XCTAssertTrue(WiFiDetail.script.contains("sudo /usr/bin/wdutil info"))
        XCTAssertTrue(WiFiDetail.script.contains("env -u SUDO_ASKPASS sudo -v"), "Touch ID 시트 먼저 (askpass 모드면 Touch ID 를 건너뜀)")
        XCTAssertTrue(WiFiDetail.script.contains("with administrator privileges"), "안 되면 암호 창")
    }
}
