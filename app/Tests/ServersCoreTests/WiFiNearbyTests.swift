// NearbyNetworks: 주변 Wi-Fi 목록 — 이름 없는 것 빼기 · 같은 이름은 가장 센 것 · 신호 순 6개.

import XCTest
@testable import ServersCore

final class WiFiNearbyTests: XCTestCase {
    private func net(_ ssid: String, _ rssi: Int, band: String = "5GHz") -> NearbyNetwork {
        NearbyNetwork(ssid: ssid, rssi: rssi, channel: 36, band: band, security: "WPA2 Personal")
    }

    func testStrongestDedupesSortsAndLimits() {
        let list = [net("home", -70, band: "2.4GHz"), net("home", -48), net("", -30), net("cafe", -60), net("a", -80), net("b", -81),
                    net("c", -82), net("d", -83), net("e", -84)]
        let top = NearbyNetworks.strongest(list)
        XCTAssertEqual(top.map(\.ssid), ["home", "cafe", "a", "b", "c", "d"], "신호 순 6개, 이름 없는 것은 뺀다")
        XCTAssertEqual(top.first?.rssi, -48, "같은 이름은 가장 센 것 (5GHz 쪽)")
        XCTAssertEqual(top.first?.band, "5GHz")
        XCTAssertEqual(NearbyNetworks.strongest([], limit: 6), [])
        XCTAssertEqual(NearbyNetworks.strongest([net("x", -50), net("y", -50)]).map(\.ssid), ["x", "y"], "신호가 같으면 이름 순")
    }
}
