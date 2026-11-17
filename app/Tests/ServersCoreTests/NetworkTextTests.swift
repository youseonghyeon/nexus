// 망 화면 글자·문턱: Wi-Fi 채널 글자 · Intranet IP 줄과 링크 타일 · 신호(RSSI)·응답 시간 단계 · 신호 막대 채움.
// 기댓값은 옮기기 전 화면 코드(WiFiDashboardView.linkTile · NetworkDashboardView.ipText/linkValue/linkCaption ·
// SignalScale · SignalBars)의 분기를 따라 적었다.

import XCTest
@testable import ServersCore

final class NetworkTextTests: XCTestCase {
    // MARK: Wi-Fi 채널

    func testWiFiChannelText() {
        // (입력, 채널, 대역, 폭, 아래 줄) — nil 이면 parse 가 nil
        let rows: [(String, (String, String?, String?, String)?)] = [
            ("36 (5GHz, 80MHz)", ("36", "5GHz", "80MHz", "5GHz · 80MHz")),
            ("1 (2.4GHz, 20MHz)", ("1", "2.4GHz", "20MHz", "2.4GHz · 20MHz")),
            ("149 (5GHz, 160MHz)", ("149", "5GHz", "160MHz", "5GHz · 160MHz")),
            ("37 (6GHz, ?)", ("37", "6GHz", "?", "6GHz · ?")),
            ("6 (?, ?)", ("6", "?", "?", "? · ?")),
            ("36 (5GHz)", ("36", "5GHz", nil, "5GHz")),
            ("36 ()", ("36", "", nil, "")),
            ("36", nil),
            ("", nil),
        ]
        for (input, expected) in rows {
            let parsed = WiFiChannelText.parse(input)
            guard let expected else { XCTAssertNil(parsed, input); continue }
            XCTAssertEqual(parsed?.number, expected.0, input)
            XCTAssertEqual(parsed?.band, expected.1, input)
            XCTAssertEqual(parsed?.width, expected.2, input)
            XCTAssertEqual(parsed?.caption, expected.3, input)
        }
    }

    // MARK: Intranet

    private func lan(actual: String?, configured: String?, mask: String? = "255.255.255.0", enabled: Bool = true) -> LanInfo {
        LanInfo(service: "Acme Intranet", enabled: enabled, device: "en10", hardwarePort: nil, configuration: nil,
                configuredIP: configured, subnetMask: mask, router: nil, actualIP: actual)
    }

    func testLanAddressText() {
        let rows: [(String, LanInfo, String)] = [
            ("같음", lan(actual: "10.50.10.17", configured: "10.50.10.17"), "10.50.10.17/24"),
            ("다름 → 설정을 괄호로", lan(actual: "10.50.10.18", configured: "10.50.10.17"), "10.50.10.18/24 (설정 10.50.10.17)"),
            ("설정만, 켜진 서비스 → 미적용", lan(actual: nil, configured: "10.50.10.17"), "10.50.10.17/24 · 미적용"),
            ("설정만, 꺼진 서비스 → 수동", lan(actual: nil, configured: "10.50.10.17", enabled: false), "10.50.10.17/24 · 수동"),
            ("실제만 (DHCP)", lan(actual: "10.50.10.17", configured: nil), "10.50.10.17/24"),
            ("둘 다 없음", lan(actual: nil, configured: nil), "–"),
            ("마스크 없음 → 접두 길이 없이", lan(actual: "10.50.10.17", configured: nil, mask: nil), "10.50.10.17"),
            ("연속 아닌 마스크 → 접두 길이 없이", lan(actual: "10.50.10.17", configured: nil, mask: "255.0.255.0"), "10.50.10.17"),
            ("/16", lan(actual: "10.50.10.17", configured: "10.50.10.17", mask: "255.255.0.0"), "10.50.10.17/16"),
        ]
        for (note, info, expected) in rows { XCTAssertEqual(info.addressText, expected, note) }
    }

    func testLinkMediaText() {
        // (media, status, 값, 아래 줄)
        let rows: [(String?, String?, String, String)] = [
            ("1000baseT <full-duplex>", "active", "1000baseT", "active · full-duplex"),
            ("1000baseT <full-duplex,flow-control>", "active", "1000baseT <full-duplex,flow-control>", "active · full-duplex"),
            ("100baseTX <half-duplex>", "active", "100baseTX <half-duplex>", "active"),
            ("2500Base-T", "active", "2500Base-T", "active"),
            ("none", "inactive", "none", "inactive"),
            (nil, "inactive", "–", "inactive"),
            ("1000baseT <full-duplex>", nil, "1000baseT", "full-duplex"),
            (nil, nil, "–", ""),
        ]
        for (media, status, value, caption) in rows {
            let link = LinkMedia(media: media, status: status)
            XCTAssertEqual(link.valueText, value, "\(media ?? "nil")")
            XCTAssertEqual(link.captionText, caption, "\(media ?? "nil") · \(status ?? "nil")")
        }
    }

    // MARK: 문턱

    func testSignalGradeBoundaries() {
        let rows: [(Int, SignalGrade)] = [
            (-30, .excellent), (-50, .excellent), (-51, .good), (-60, .good), (-61, .fair), (-70, .fair), (-71, .weak), (-100, .weak),
        ]
        for (rssi, grade) in rows { XCTAssertEqual(SignalGrade(rssi: rssi), grade, "\(rssi)") }
    }

    func testLatencyGradeBoundaries() {
        let rows: [(Double, LatencyGrade)] = [
            (0, .fast), (39.9, .fast), (40, .slow), (119.9, .slow), (120, .poor), (5000, .poor), (.nan, .poor), (.infinity, .poor),
        ]
        for (ms, grade) in rows { XCTAssertEqual(LatencyGrade(ms: ms), grade, "\(ms)") }
    }

    func testSignalLevel() {
        let rows: [(Int, Double)] = [(-120, 0), (-100, 0), (-75, 0.5), (-50, 1), (-30, 1)]
        for (rssi, level) in rows { XCTAssertEqual(SignalMeter.level(rssi: rssi), level, accuracy: 1e-9, "\(rssi)") }
    }

    /// 칸 i 는 level ≥ (i+1)/4 − 0.12 일 때: 0.13 · 0.38 · 0.63 · 0.88 문턱 (부동소수 경계를 피해 양옆 값으로)
    func testFilledBars() {
        let rows: [(rssi: Int, bars: Int)] = [
            (-100, 0), (-94, 0), (-93, 1),   // 0.12 · 0.14
            (-82, 1), (-80, 2),              // 0.36 · 0.40
            (-69, 2), (-68, 3),              // 0.62 · 0.64
            (-57, 3), (-55, 4),              // 0.86 · 0.90
            (-50, 4), (-20, 4),
        ]
        for row in rows {
            XCTAssertEqual(SignalMeter.filledBars(level: SignalMeter.level(rssi: row.rssi)), row.bars, "\(row.rssi)")
        }
        XCTAssertEqual(SignalMeter.filledBars(level: 0), 0)
        XCTAssertEqual(SignalMeter.filledBars(level: 1), 4)
        XCTAssertEqual(SignalMeter.filledBars(level: 1, bars: 0), 0, "칸이 없으면 0")
    }
}
