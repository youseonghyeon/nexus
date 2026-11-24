// 공유기(OpenWrt) 화면 글자: 포트 속도 · 인터페이스 줄의 포트 요약 · DHCP 임대 남은 시간.

import Foundation

extension OpenWrtPort {
    /// 1000 → "1 Gbps", 2500 → "2.5 Gbps", 100 → "100 Mbps", 반이중이면 " · Half". 속도를 모르면 "up"
    public var speedText: String {
        guard let speedMbps else { return "up" }
        let speed = Ethernet.speedLabel(mbps: speedMbps)
        return fullDuplex == false ? speed + " · Half" : speed
    }

    /// 인터페이스 줄 끝: 포트 하나면 속도, 여럿이면 "연결된 수/전체 ports", 하나인데 링크가 없으면 "no link".
    /// 포트가 없거나 하나뿐인 포트의 속도를 모르면 nil (적지 않는다)
    public static func summary(_ ports: [OpenWrtPort]) -> String? {
        guard let port = ports.first else { return nil }
        if ports.count > 1 { return "\(ports.filter(\.carrier).count)/\(ports.count) ports" }
        guard port.carrier else { return "no link" }
        return port.speedMbps == nil ? nil : port.speedText
    }
}

extension OpenWrtClient {
    /// 임대 남은 시간 글자: 없으면 "", 무기한 "무기한", 남았으면 "2시간 5분", 0 이하 "만료"
    public static func leaseText(_ remaining: TimeInterval?) -> String {
        guard let remaining else { return "" }
        if remaining == .infinity { return "무기한" }
        return remaining > 0 ? DurationFormat.compact(remaining) : "만료"
    }
}
