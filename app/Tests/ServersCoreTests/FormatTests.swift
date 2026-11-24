// 기간·바이트 글의 꼴 (Format.swift). 화면 문구라 글자 단위로 고정한다 — 화면별 이름(ServicesFormat · SystemVPNs · SystemFormat · DiskFormat)으로 불러도 같은 글.

import Foundation
import XCTest
@testable import ServersCore

final class FormatTests: XCTestCase {
    /// 큰 단위 둘까지, 0 인 둘째 단위는 생략 (Services · Spec · OpenWrt · 타이머)
    func testCompactDuration() {
        let cases: [(TimeInterval, String)] = [
            (0, "0초"), (10, "10초"), (59, "59초"), (60, "1분"), (90.9, "1분"), (300, "5분"), (3600, "1시간"), (3660, "1시간 1분"),
            (86400, "1일"), (86400 + 14 * 3600, "1일 14시간"), (86400 + 59 * 60, "1일"), (220 * 86400, "220일"), (-5, "0초"),
        ]
        for (seconds, text) in cases { XCTAssertEqual(ServicesFormat.duration(seconds), text, "\(seconds)") }
    }

    /// 늘 두 단위, 초까지 (VPN 연결 시간)
    func testDurationWithSeconds() {
        let cases: [(Int, String)] = [(0, "0초"), (5, "5초"), (60, "1분 0초"), (975, "16분 15초"), (3600, "1시간 0분"), (3 * 3600 + 125, "3시간 2분"),
                                      (86400, "1일 0시간"), (2 * 86400 + 4 * 3600 + 59, "2일 4시간")]
        for (seconds, text) in cases { XCTAssertEqual(SystemVPNs.duration(seconds), text, "\(seconds)") }
    }

    /// 분까지 세 단위 (가동 시간)
    func testFullDuration() {
        let cases: [(TimeInterval, String)] = [(0, "0분"), (59, "0분"), (60, "1분"), (3600, "1시간 0분"), (86400, "1일 0시간 0분"),
                                               (25 * 86400 + 3 * 3600 + 4 * 60, "25일 3시간 4분"), (-5, "0분")]
        for (seconds, text) in cases { XCTAssertEqual(SystemFormat.uptime(seconds), text, "\(seconds)") }
    }

    /// 2진 단위: GiB·TiB 는 소수 한 자리, MiB·KiB 는 정수
    func testBinaryBytes() {
        let cases: [(UInt64, String)] = [(0, "0 B"), (1023, "1023 B"), (1024, "1 KiB"), (1 << 20, "1 MiB"), (300 << 20, "300 MiB"),
                                         (1 << 30, "1.0 GiB"), (3 << 29, "1.5 GiB"), (1 << 40, "1.0 TiB")]
        for (value, text) in cases { XCTAssertEqual(SystemFormat.bytes(value), text, "\(value)") }
    }

    /// 10진 단위: 100 이상은 정수, 그 아래는 소수 한 자리
    func testDecimalBytes() {
        let cases: [(Double, String)] = [(0, "0 B"), (999, "999 B"), (1000, "1.0 KB"), (150_000, "150 KB"), (1.2e6, "1.2 MB"),
                                         (1.5e9, "1.5 GB"), (500_107_862_016, "500 GB"), (2e12, "2.0 TB")]
        for (value, text) in cases { XCTAssertEqual(DiskFormat.bytes(value), text, "\(value)") }
        XCTAssertEqual(DiskFormat.bytes(UInt64(1_200_000)), "1.2 MB")
        XCTAssertEqual(DiskFormat.rate(1e6), "1.0 MB/s")
        XCTAssertEqual(DiskFormat.rate(0), "0 B/s")
    }
}
