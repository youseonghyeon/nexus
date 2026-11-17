// 서버 화면 접속 카드의 "네트워크" 줄 (2026-11-17): 어느 길로 나가는가를 사이드바와 같은 말(Wi-Fi · Ethernet)로.
// 예전엔 "Direct · en11" — Direct 는 "특별한 망을 거치지 않는다"라 적을 것이 없고, en11 은 유선인지 Wi-Fi 인지 알 수 없었다.
//   direct            나가는 길만                "Ethernet (en11)"
//   lan·tailscale·vpn 망 이름 · (VPN 이름) · 길   "Intranet · Ethernet (en10)" · "VPN · Office · utun6"
// 나가는 장치를 모르면 망 이름만 (direct 도 "Direct" — 줄이 비지 않게).

import Foundation

public enum NetworkPathText {
    /// 장치의 표시 이름: Wi-Fi·유선은 사이드바 행 이름 + 장치, 그 밖의 서비스는 어댑터 이름 + 장치, 서비스 목록에 없으면(utun·bridge·목록을 아직 못 읽음) 장치 그대로
    public static func route(device: String, services: [LanServiceEntry]) -> String {
        let matching = services.filter { $0.device == device }
        guard let entry = matching.first(where: \.enabled) ?? matching.first else { return device }
        let port = entry.hardwarePort ?? ""
        let kind: String
        if ["Wi-Fi", "AirPort"].contains(where: { port.localizedCaseInsensitiveContains($0) }) { kind = "Wi-Fi" }
        else if entry.isWiredAdapter { kind = "Ethernet" }
        else { kind = port.isEmpty ? entry.name : port }
        return "\(kind) (\(device))"
    }

    /// 네트워크 줄. networkName 은 화면의 망 이름(AppModel.networkName), vpn 은 서버에 적은 VPN 이름, device 는 나가는 장치(모르면 nil).
    public static func text(network: ServerNetwork, networkName: String, vpn: String?, device: String?, services: [LanServiceEntry]) -> String {
        let path = device.flatMap { $0.isEmpty ? nil : route(device: $0, services: services) }
        if network == .direct { return path ?? networkName }
        return ([networkName, vpn, path] as [String?]).compactMap { $0 }.joined(separator: " · ")
    }
}
