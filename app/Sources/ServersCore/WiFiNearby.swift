// Wi-Fi 화면의 "주변 네트워크": CoreWLAN 직접 검색 결과 → 보여 줄 목록. 검색 자체는 앱(WiFiMonitor.scanNearby).
// 캐시(cachedScanResults)는 몇 분 묵은 값이라 쓰지 않는다 — 화면을 열 때 한 번 + [다시 검색] 때만 직접 검색한다 (검색하는 2~3초 동안 연결 응답이 잠깐 늦어진다).

import Foundation

public struct NearbyNetwork: Sendable, Equatable, Identifiable {
    public var id: String { ssid }
    public let ssid: String
    public let rssi: Int
    public let channel: Int?
    /// "2.4GHz" · "5GHz" · "6GHz"
    public let band: String?
    public let security: String?

    public init(ssid: String, rssi: Int, channel: Int?, band: String?, security: String?) {
        self.ssid = ssid; self.rssi = rssi; self.channel = channel; self.band = band; self.security = security
    }
}

public enum NearbyNetworks {
    /// 이름 없는(숨긴 SSID·위치 권한 없음) 것은 빼고, 같은 이름은 가장 센 것 하나만, 신호 센 순으로 limit 개
    public static func strongest(_ networks: [NearbyNetwork], limit: Int = 6) -> [NearbyNetwork] {
        var best: [String: NearbyNetwork] = [:]
        for network in networks where !network.ssid.isEmpty {
            if let current = best[network.ssid], current.rssi >= network.rssi { continue }
            best[network.ssid] = network
        }
        return Array(best.values.sorted { ($0.rssi, $1.ssid) > ($1.rssi, $0.ssid) }.prefix(limit))
    }
}
