// 원격 정보 화면 글자: 공유기 포트 속도·포트 요약·DHCP 임대 남은 시간, systemd 타이머 다음·지난 실행.
// 기댓값은 옮기기 전 OpenWrtViews(speedText·portSummary·leaseText)와 LinuxInfoViews.timerRow 를 따라 적었다.

import XCTest
@testable import ServersCore

final class RemoteInfoTextTests: XCTestCase {
    private func port(_ name: String = "eth0", carrier: Bool = true, mbps: Int? = 1000, full: Bool? = true) -> OpenWrtPort {
        OpenWrtPort(name: name, carrier: carrier, speedMbps: mbps, fullDuplex: full, rxBytes: nil, txBytes: nil)
    }

    func testPortSpeedText() {
        let rows: [(String, OpenWrtPort, String)] = [
            ("1G 전이중", port(mbps: 1000, full: true), "1 Gbps"),
            ("2.5G", port(mbps: 2500, full: true), "2.5 Gbps"),
            ("100M 반이중", port(mbps: 100, full: false), "100 Mbps · Half"),
            ("이중 모름은 Half 를 붙이지 않는다", port(mbps: 100, full: nil), "100 Mbps"),
            ("속도 모름", port(mbps: nil, full: nil), "up"),
        ]
        for (note, p, expected) in rows { XCTAssertEqual(p.speedText, expected, note) }
    }

    func testPortSummary() {
        let rows: [(String, [OpenWrtPort], String?)] = [
            ("포트 없음", [], nil),
            ("하나 · 속도", [port(mbps: 1000)], "1 Gbps"),
            ("하나 · 반이중", [port(mbps: 100, full: false)], "100 Mbps · Half"),
            ("하나 · 링크 없음", [port(carrier: false)], "no link"),
            ("하나 · 링크 없음은 속도를 몰라도", [port(carrier: false, mbps: nil)], "no link"),
            ("하나 · 속도 모름 → 적지 않는다", [port(mbps: nil)], nil),
            ("여럿 · 연결 수", [port("lan1"), port("lan2", carrier: false), port("lan3")], "2/3 ports"),
            ("여럿 · 모두 끊김", [port("lan1", carrier: false), port("lan2", carrier: false)], "0/2 ports"),
        ]
        for (note, ports, expected) in rows { XCTAssertEqual(OpenWrtPort.summary(ports), expected, note) }
    }

    func testLeaseText() {
        let rows: [(TimeInterval?, String)] = [
            (nil, ""), (.infinity, "무기한"), (0, "만료"), (-5, "만료"),
            (1, "1초"), (59, "59초"), (60, "1분"), (3600, "1시간"), (3660, "1시간 1분"), (86400, "1일"), (90000, "1일 1시간"),
        ]
        for (remaining, expected) in rows { XCTAssertEqual(OpenWrtClient.leaseText(remaining), expected, "\(remaining.map { "\($0)" } ?? "nil")") }
    }

    func testTimerTexts() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func timer(next: TimeInterval?, last: TimeInterval?) -> SystemdTimer {
            SystemdTimer(unit: "apt-daily.timer", activates: "apt-daily.service",
                         next: next.map { now.addingTimeInterval($0) }, last: last.map { now.addingTimeInterval($0) })
        }
        // (다음까지 초, 지난 뒤 초(음수), 다음 글자, 지난 글자)
        let rows: [(TimeInterval?, TimeInterval?, String, String)] = [
            (nil, nil, "–", "–"),
            (840, -7200, "14분 뒤", "2시간 전"),
            (0, 0, "곧", "0초 전"),
            (-30, -30, "곧", "30초 전"),
            (0.5, nil, "0초 뒤", "–"),
            (90000, -90000, "1일 1시간 뒤", "1일 1시간 전"),
            (nil, 30, "–", "0초 전"),   // 지난 실행이 now 보다 뒤(시계 차이) → 0초로 자른다
        ]
        for (next, last, nextText, lastText) in rows {
            let t = timer(next: next, last: last)
            XCTAssertEqual(t.nextText(now: now), nextText, "next \(next.map { "\($0)" } ?? "nil")")
            XCTAssertEqual(t.lastText(now: now), lastText, "last \(last.map { "\($0)" } ?? "nil")")
        }
    }
}
