// 이 Mac 의 Wi-Fi: CoreWLAN 으로 전원·SSID·신호를 읽고 전원을 켜고 끈다. SSID 는 macOS 14+ 에서 위치 권한이 있어야 읽힌다.
// (networksetup/system_profiler 는 SSID 를 <redacted> 로 주거나 7초씩 걸려 쓰지 않는다.)

import CoreLocation
import CoreWLAN
import Foundation
import ServersCore

struct WiFiInfo: Equatable {
    var interface: String
    var powerOn: Bool
    /// nil = 연결 안 됨 또는 위치 권한 없음
    var ssid: String?
    var bssid: String?
    var rssi: Int
    var noise: Int
    var channel: String?
    var phyMode: String?
    /// Mbps
    var txRate: Double
    var security: String?

    /// 연결돼 있는가 (권한이 없어 SSID 가 비어도 PHY 가 있으면 연결된 것 — 끊겨도 채널은 남아 있어 채널로는 못 가른다, 2026-10-14)
    var associated: Bool { powerOn && phyMode != nil }
}

@MainActor
final class WiFiMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var info: WiFiInfo?
    @Published private(set) var authorization: CLAuthorizationStatus
    /// 주변 네트워크 (신호 센 순 6개) — 화면을 열 때 한 번 + [다시 검색] 때만 직접 검색한다 (WiFiNearby 머리 주석)
    @Published private(set) var nearby: [NearbyNetwork] = []
    @Published private(set) var nearbyAt: Date?
    @Published private(set) var scanning = false
    @Published private(set) var scanFailed = false
    private let location = CLLocationManager()

    override init() {
        authorization = location.authorizationStatus
        super.init()
        location.delegate = self
    }

    var locationAuthorized: Bool { authorization == .authorizedAlways || authorization == .authorized }
    var locationDenied: Bool { authorization == .denied || authorization == .restricted }

    /// 시스템 권한 창 (아직 안 물었을 때만 뜬다)
    func requestLocationIfNeeded() {
        guard authorization == .notDetermined, !DemoMode.active else { return }
        location.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            self.refresh()
        }
    }

    func refresh() {
        // 데모: 실제 SSID·BSSID 를 읽지 않고 가상의 값 (DemoMode)
        if DemoMode.active {
            info = WiFiInfo(interface: "en0", powerOn: true, ssid: "home_5G", bssid: "02:00:5e:10:0a:01", rssi: -52, noise: -94,
                            channel: "149 (5GHz, 80MHz)", phyMode: "802.11ax", txRate: 1200, security: "WPA3 Personal")
            return
        }
        guard let iface = CWWiFiClient.shared().interface() else { info = nil; return }
        let channel = iface.wlanChannel().map { ch -> String in
            let band = Self.bandName(ch.channelBand) ?? "?"
            let width: String
            switch ch.channelWidth {
            case .width20MHz: width = "20MHz"
            case .width40MHz: width = "40MHz"
            case .width80MHz: width = "80MHz"
            case .width160MHz: width = "160MHz"
            default: width = "?"
            }
            return "\(ch.channelNumber) (\(band), \(width))"
        }
        let phy: String?
        switch iface.activePHYMode() {
        case .mode11a: phy = "802.11a"
        case .mode11b: phy = "802.11b"
        case .mode11g: phy = "802.11g"
        case .mode11n: phy = "802.11n"
        case .mode11ac: phy = "802.11ac"
        case .mode11ax: phy = "802.11ax"
        case .mode11be: phy = "802.11be"
        case .modeNone: phy = nil
        @unknown default: phy = "802.11"
        }
        let security: String?
        switch iface.security() {
        case .none: security = "없음 (개방)"
        case .WEP: security = "WEP"
        case .wpaPersonal, .wpaPersonalMixed: security = "WPA Personal"
        case .wpa2Personal: security = "WPA2 Personal"
        case .wpa3Personal, .wpa3Transition: security = "WPA3 Personal"
        case .personal: security = "Personal"
        case .dynamicWEP: security = "Dynamic WEP"
        case .wpaEnterprise, .wpaEnterpriseMixed: security = "WPA Enterprise"
        case .wpa2Enterprise: security = "WPA2 Enterprise"
        case .wpa3Enterprise: security = "WPA3 Enterprise"
        case .enterprise: security = "Enterprise"
        case .OWE, .oweTransition: security = "OWE"
        case .unknown: security = nil
        @unknown default: security = nil
        }
        let new = WiFiInfo(interface: iface.interfaceName ?? "en0",
                           powerOn: iface.powerOn(),
                           ssid: iface.ssid(),
                           bssid: iface.bssid(),
                           rssi: iface.rssiValue(),
                           noise: iface.noiseMeasurement(),
                           channel: phy == nil ? nil : channel,   // 끊기면 CoreWLAN 이 검색용 채널(1)을 그대로 준다
                           phyMode: phy,
                           txRate: iface.transmitRate(),
                           security: security)
        if info != new { info = new }   // 매 라운드 불린다 — 같은 값이면 알리지 않는다 (@Published 는 대입마다 알린다)
    }

    nonisolated static func bandName(_ band: CWChannelBand) -> String? {
        switch band {
        case .band2GHz: return "2.4GHz"
        case .band5GHz: return "5GHz"
        case .band6GHz: return "6GHz"
        default: return nil
        }
    }

    /// 주변 네트워크 직접 검색. 2~3초 막히므로 메인 스레드 밖에서. 꺼져 있거나 이미 검색 중이면 하지 않는다.
    func scanNearby() {
        guard !scanning, info?.powerOn == true, !DemoMode.active else { return }
        scanning = true
        Task {
            let found = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: Self.scan()) }
            }
            scanning = false
            if let found {
                nearby = NearbyNetworks.strongest(found)
                nearbyAt = Date()
                scanFailed = false
            } else {
                scanFailed = true
            }
        }
    }

    /// CWNetwork 는 이 스레드 안에서만 쓰고 값으로 바꿔 넘긴다
    nonisolated private static func scan() -> [NearbyNetwork]? {
        guard let iface = CWWiFiClient.shared().interface(), let found = try? iface.scanForNetworks(withName: nil) else { return nil }
        return found.map { network in
            NearbyNetwork(ssid: network.ssid ?? "", rssi: network.rssiValue, channel: network.wlanChannel?.channelNumber,
                          band: network.wlanChannel.flatMap { bandName($0.channelBand) }, security: securityName(network))
        }
    }

    /// 지원하는 보안 중 가장 강한 것
    nonisolated private static func securityName(_ network: CWNetwork) -> String {
        let order: [(CWSecurity, String)] = [(.wpa3Enterprise, "WPA3 Enterprise"), (.wpa3Personal, "WPA3"), (.wpa3Transition, "WPA2/WPA3"),
                                             (.wpa2Enterprise, "WPA2 Enterprise"), (.wpa2Personal, "WPA2"), (.wpaEnterprise, "WPA Enterprise"),
                                             (.wpaPersonal, "WPA"), (.OWE, "OWE"), (.WEP, "WEP"), (.dynamicWEP, "WEP")]
        return order.first { network.supportsSecurity($0.0) }?.1 ?? "개방"
    }

    /// 전원 켜기/끄기 (권한·sudo 불필요)
    func setPower(_ on: Bool) throws {
        guard !DemoMode.active else { return }
        guard let iface = CWWiFiClient.shared().interface() else { return }
        try iface.setPower(on)
        refresh()
    }
}
