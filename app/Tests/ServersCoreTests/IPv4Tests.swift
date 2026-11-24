// IPv4 주소 풀이·대역 계산 (IPv4.swift)과 그것을 쓰는 곳마다의 판정. 받는 꼴이 곳마다 다르다 — 통일하지 않고 지금 판정을 고정한다
// (2026-11-24 구현을 한 곳으로 모으기 전에 넣은 테스트).

import Foundation
import XCTest
@testable import ServersCore

final class IPv4Tests: XCTestCase {
    /// 엄격한 풀이: 앞자리 0 거부 (서비스 편집 · 경로 판정 · ARP · 공인 IP 판정이 쓴다)
    func testStrictParse() {
        XCTAssertEqual(IPv4.parse("10.50.10.17"), 0x0A320A11)
        XCTAssertEqual(IPv4.parse("0.0.0.0"), 0)
        XCTAssertEqual(IPv4.parse("255.255.255.255"), .max)
        for bad in ["", "1.2.3", "1.2.3.4.5", "1..2.3", "1.2.3.", ".1.2.3", "256.1.1.1", "010.1.1.1", "00.1.1.1", "1.2.3.0004", " 1.2.3.4", "1.2.3.4 ", "a.b.c.d", "1.2.3.x", "１.2.3.4"] {
            XCTAssertNil(IPv4.parse(bad), bad)
        }
        // 지금 구현은 칸 앞의 부호를 받는다 (UInt32("+1") == 1) — 고칠지는 따로 정할 일이라 그대로 고정만 한다
        XCTAssertEqual(IPv4.parse("+1.2.3.4"), 0x01020304)
        XCTAssertEqual(IPv4.parse("-0.2.3.4"), 0x00020304)
        XCTAssertEqual(IPv4.dotted(0xC0A80867), "192.168.8.103")
        XCTAssertEqual(IPv4.dotted(0), "0.0.0.0")
    }

    /// 브라우저 주소창: 숫자 칸 넷이면 주소 (앞자리 0 은 받는다)
    func testBrowserInputAcceptsLeadingZero() {
        for ok in ["1.2.3.4", "010.1.1.1", "0.0.0.0", "255.255.255.255", "000.000.000.000"] { XCTAssertTrue(BrowserInput.isIPv4(ok), ok) }
        for bad in ["", "1.2.3", "1.2.3.4.5", "1..2.3", "1.2.3.4.", "256.1.1.1", "0001.1.1.1", "+1.2.3.4", "-0.2.3.4", "a.b.c.d", " 1.2.3.4", "١.2.3.4"] {
            XCTAssertFalse(BrowserInput.isIPv4(bad), bad)
        }
    }

    /// 터널 대상 호스트: 숫자와 점뿐이면 IPv4 꼴이어야 한다 (앞자리 0 은 받고, 글자는 그대로 돌려준다)
    func testTunnelRemoteHost() {
        XCTAssertEqual(TunnelTarget.remoteHost("10.0.0.5"), "10.0.0.5")
        XCTAssertEqual(TunnelTarget.remoteHost(" 010.0.0.5 "), "010.0.0.5")
        XCTAssertEqual(TunnelTarget.remoteHost("000.000.000.000"), "000.000.000.000")
        for bad in ["1.2.3", "1.2.3.4.5", "256.1.1.1", "0001.1.1.1", "1.2.3.999", "12345", "1..2.3", "1.2.3.4."] { XCTAssertNil(TunnelTarget.remoteHost(bad), bad) }
    }

    /// "주소/접두사" 끼리의 대역 비교 (ip route 출력): 칸은 느슨하게 읽는다
    func testPrefixSameNetwork() {
        XCTAssertTrue(IPv4Prefix.sameNetwork("10.1.2.3/8", "10.0.0.0/8"))
        XCTAssertFalse(IPv4Prefix.sameNetwork("11.1.2.3/8", "10.0.0.0/8"))
        XCTAssertTrue(IPv4Prefix.sameNetwork("10.0.0.2/0", "200.0.0.0/0"), "/0 은 전부 같은 대역")
        XCTAssertTrue(IPv4Prefix.sameNetwork("10.0.0.2/32", "10.0.0.2/32"))
        XCTAssertFalse(IPv4Prefix.sameNetwork("10.0.0.2/32", "10.0.0.3/32"))
        XCTAssertTrue(IPv4Prefix.sameNetwork("192.168.8.103/31", "192.168.8.102/31"))
        XCTAssertFalse(IPv4Prefix.sameNetwork("192.168.8.103/33", "192.168.8.102/33"), "접두사는 0~32")
        XCTAssertFalse(IPv4Prefix.sameNetwork("192.168.8.103", "192.168.8.0/24"), "접두사가 없으면 비교하지 않는다")
        XCTAssertFalse(IPv4Prefix.sameNetwork("256.168.8.103/24", "256.168.8.0/24"))
        XCTAssertTrue(IPv4Prefix.sameNetwork("010.1.2.3/8", "10.0.0.0/8"), "앞자리 0 은 받는다")
        XCTAssertEqual(IPv4Prefix.parse("192.168.8.103/24")?.address, 0xC0A80867)
        XCTAssertEqual(IPv4Prefix.parse("192.168.8.103/24")?.prefix, 24)
        XCTAssertNil(IPv4Prefix.parse("1.2.3/24"))
        XCTAssertNil(IPv4Prefix.parse("1.2.3.4/24/1"))
        // 지금 구현은 못 읽는 칸을 버린 뒤 센다 — "1..2.3.4" 는 네 칸으로 읽힌다 (ip 출력에는 없는 꼴, 그대로 고정만)
        XCTAssertEqual(IPv4Prefix.parse("1..2.3.4/24")?.address, 0x01020304)
    }

    /// 이 Mac 의 경로 표에서 주소가 타는 줄: 대역은 엄격한 풀이로 읽는다
    func testRouteMatchMasks() {
        func entry(_ destination: String, _ device: String) -> RouteEntry { RouteEntry(destination: destination, gateway: nil, interfaces: [device], kind: .route) }
        let table = RouteTable(entries: [entry("default", "en0"), entry("10.0.0.0/8", "en1"), entry("10.1.0.0/16", "en2"), entry("10.1.2.3", "en3"),
                                         entry("10.1.2.4/32", "en4"), entry("0.0.0.0/0", "en5"), entry("010.9.0.0/16", "en6"), entry("10.8.0.0/33", "en7")], interfaces: [:])
        let cases: [(String, String?)] = [("8.8.8.8", "en0"), ("10.200.0.1", "en1"), ("10.1.200.1", "en2"), ("10.1.2.3", "en3"), (" 10.1.2.4 ", "en4"),
                                          ("10.9.0.1", "en1"), ("10.8.0.1", "en1"), ("010.1.2.3", nil), ("host", nil), ("", nil)]
        for (address, device) in cases { XCTAssertEqual(RouteGraph.match(address, in: table)?.interfaces.first, device, address) }
    }

    /// 점 표기 마스크 → 접두사 길이: 빈 칸은 건너뛰고 읽는다
    func testMaskPrefixLength() {
        let cases: [(String, Int?)] = [("255.255.255.0", 24), ("255.255.255.252", 30), ("128.0.0.0", 1), ("255.255.255.255", 32), ("0.0.0.0", 0),
                                       ("255.0.255.0", nil), ("0.255.0.0", nil), ("255.255.255", nil), ("255.255.256.0", nil), ("", nil),
                                       ("255..255.255.0", 24), ("0255.255.255.0", 24)]
        for (mask, length) in cases { XCTAssertEqual(NetworkInfoFetcher.prefixLength(mask: mask), length, mask) }
        XCTAssertEqual(Ethernet.dottedMask(hex: "0xffffff00"), "255.255.255.0")
        XCTAssertEqual(Ethernet.dottedMask(hex: "0xfffffffc"), "255.255.255.252")
        XCTAssertNil(Ethernet.dottedMask(hex: "ffffff00"))
    }

    /// 한곳으로 모으지 않은 판정 — 받는 꼴이 서로 달라 그대로 둔 것
    func testCallSitesKeptApart() {
        XCTAssertTrue(PowerWatch.sameSubnet24("192.168.8.1", "192.168.8.200"))
        XCTAssertFalse(PowerWatch.sameSubnet24("192.168.8.1", "192.168.9.1"))
        XCTAssertFalse(PowerWatch.sameSubnet24("192.168.08.1", "192.168.8.1"), "글자로 견준다")
        XCTAssertFalse(PowerWatch.sameSubnet24("host", "192.168.8.1"))
        XCTAssertEqual(OpenWrt.ipSortKey("192.168.8.20"), [192, 168, 8, 20])
        XCTAssertEqual(OpenWrt.ipSortKey("fe80::1"), [Int.max])
        XCTAssertEqual(OpenWrt.ipSortKey(nil), [Int.max])
        XCTAssertTrue(BrowserPolicy.isLoopback("127.0.0.2"))
        XCTAssertTrue(BrowserPolicy.isLoopback("LOCALHOST"))
        XCTAssertFalse(BrowserPolicy.isLoopback("127.0.0"))
        XCTAssertFalse(BrowserPolicy.isLoopback("128.0.0.1"))
    }

    /// 범위 밖 접두사 길이로 불러도 죽지 않는다 (예전 식은 Int 시프트라 죽지 않았다 — 리팩터링 검토에서 짚은 것)
    func testMaskClampsOutOfRangePrefix() {
        XCTAssertEqual(IPv4.mask(prefix: 0), 0)
        XCTAssertEqual(IPv4.mask(prefix: 24), 0xFFFF_FF00)
        XCTAssertEqual(IPv4.mask(prefix: 32), 0xFFFF_FFFF)
        XCTAssertEqual(IPv4.mask(prefix: -1), 0)
        XCTAssertEqual(IPv4.mask(prefix: 33), 0xFFFF_FFFF)
        XCTAssertEqual(IPv4.mask(prefix: Int.max), 0xFFFF_FFFF)
    }
}
