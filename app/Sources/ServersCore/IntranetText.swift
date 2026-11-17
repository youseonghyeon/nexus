// Intranet 화면 글자: 주소 카드의 IP 줄, 링크 타일의 값·아래 줄.

import Foundation

extension LanInfo {
    /// "10.50.10.17/24" (서브넷은 접두 길이로 붙인다). 실제 주소와 설정 주소가 다르면 설정을 괄호로,
    /// 설정만 있으면 켜진 서비스는 "미적용", 꺼진 서비스는 "수동" (꺼진 서비스에 주소가 보이면 수동으로 넣은 값 — DHCP 는 꺼지면 비어 있다)
    public var addressText: String {
        let prefix = subnetMask.flatMap(NetworkInfoFetcher.prefixLength(mask:)).map { "/\($0)" } ?? ""
        switch (actualIP, configuredIP) {
        case let (actual?, configured?) where actual == configured: return actual + prefix
        case let (actual?, configured?): return "\(actual)\(prefix) (설정 \(configured))"
        case let (nil, configured?): return "\(configured)\(prefix) · \(enabled ? "미적용" : "수동")"
        case let (actual?, nil): return actual + prefix
        case (nil, nil): return "–"
        }
    }
}

extension LinkMedia {
    /// 링크 타일 값: "1000baseT <full-duplex>" → "1000baseT". 매체를 모르면 "–"
    public var valueText: String {
        guard let media else { return "–" }
        return media.replacingOccurrences(of: " <full-duplex>", with: "")
    }

    /// 링크 타일 아래 줄: "active · full-duplex" (전이중만 적는다)
    public var captionText: String {
        [status, media?.contains("full-duplex") == true ? "full-duplex" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}
