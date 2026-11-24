// 망 화면(Intranet · Wi-Fi · Ethernet)의 결론 · 칸 문구. 화면(NetworkDashboardView · NetworkParts · WiFiDashboardView · EthernetDashboardView)에
// 있던 분기를 그대로 옮긴 것 — 사이드바 행의 문구(StatusText.lanDetail · wifiDetail · ethernetDetail)와는 일부러 다른 낱말이다(화면은 짧게).

import Foundation

extension StatusText {
    // MARK: Intranet 화면

    /// 머리글 결론: 켜져 있으면 서비스 판정 하나(link), 못 읽었으면 어댑터 유무로
    public static func lanConclusion(_ state: LanState, link: ServiceLink?, adapterPresent: Bool) -> String {
        switch state {
        case .up: return link?.text ?? (adapterPresent ? "활성" : "활성 · 어댑터 없음")
        case .down: return "비활성"
        case .missing: return "서비스 없음"
        case .none: return "설정 없음"
        }
    }

    /// 상태 카드의 서비스 이름 옆 글자
    public static func lanServiceState(_ state: LanState) -> String {
        switch state {
        case .up: return "활성"
        case .missing: return "서비스 없음"
        default: return "비활성"
        }
    }

    /// 상태 카드의 인터페이스 줄. info 가 없으면(아직 못 읽음) "–"
    public static func lanInterfaceText(_ info: LanInfo?, adapterPresent: Bool) -> String {
        guard let info else { return "–" }
        guard let device = info.device else { return "장치 없음" }
        return adapterPresent ? device : device + " · 연결 안 됨"
    }

    /// 주소 카드의 게이트웨이 줄: 게이트웨이 + 응답 (내부망이 실제로 통하는지)
    public static func lanGatewayText(router: String?, ping: PingSummary?) -> String {
        guard let router else { return "–" }
        guard let ping else { return router }
        return "\(router) · \(ping.text)"
    }

    /// 게이트웨이 타일(응답을 못 쟀을 때)의 아래 줄: 게이트웨이 주소, 모르면 망 상태로
    public static func lanGatewayIdleCaption(router: String?, state: LanState) -> String {
        router ?? (state == .up ? "확인 중…" : "연결 안 됨")
    }

    // MARK: 망 화면 공통

    /// 서버 타일의 색: 서버가 없으면 회색, 모두 접속 가능하면 초록, 하나도 안 되면 빨강, 일부면 노랑
    public static func serverCountLevel(reachable: Int, total: Int) -> StatusLevel {
        total == 0 ? .muted : (reachable == total ? .good : (reachable == 0 ? .bad : .warn))
    }

    /// 서버 카드의 줄 끝 글자 (사이드바 풀이말 remoteHelp 보다 짧게)
    public static func remoteBrief(_ state: RemoteState, check: CheckMethod, lanName: String) -> String {
        let method = check == .tcp ? "포트" : "SSH"
        switch state {
        case let .ok(ms): return "\(method) ok · \(ms)ms"
        case let .fail(ms): return "\(method) 실패 · \(ms)ms"
        case .off: return "꺼짐"
        case .needsAuth: return "Tailscale 인증 필요"
        case let .skip(reason): return skipReasonText(reason, lanName: lanName)
        case .pending: return "확인 중"
        }
    }

    /// 받기·보내기 타일의 아래 줄. total: VPN 누적 바이트(있으면 그것만) · hasDevice: 잴 장치가 있는가 ·
    /// connected: 망은 연결됐는데 장치를 아직 못 읽음 · measured: 속도 값이 있는가 · sending: 보내기 타일인가
    public static func trafficCaption(total: Int64?, hasDevice: Bool, connected: Bool, measured: Bool, sending: Bool, samples: Int) -> String? {
        if let total { return "누적 \(TransferMeter.format(total))" }
        guard hasDevice else { return connected ? "측정 중…" : nil }
        if !measured { return "측정 중…" }
        return sending ? "최근 \(samples)회" : nil   // 링크 표기는 링크 타일에만
    }

    /// 주소 카드의 IP 줄: "192.0.2.17/24" (서브넷은 접두 길이로 붙인다). 주소가 없으면 "–", 마스크를 못 읽으면 주소만
    public static func addressText(ip: String?, mask: String?) -> String {
        guard let ip else { return "–" }
        let prefix = mask.flatMap(NetworkInfoFetcher.prefixLength(mask:)).map { "/\($0)" } ?? ""
        return ip + prefix
    }

    // MARK: Wi-Fi 화면

    /// 머리글 결론 (사이드바 wifiDetail 과 달리 SSID 를 넣지 않는다 — 제목이 SSID 다)
    public static func wifiConclusion(_ info: WiFi?) -> String {
        guard let info else { return "인터페이스 없음" }
        if !info.powerOn { return "꺼짐" }
        return info.associated ? "연결됨" : "연결 안 됨"
    }

    /// 화면 제목 · 상태 카드의 SSID 줄. SSID 는 위치 권한이 있어야 읽힌다 — 연결됐는데 이름이 없으면 권한 여부로 가른다
    public static func wifiTitle(_ info: WiFi?, locationAuthorized: Bool) -> String {
        guard let info, info.powerOn else { return "Wi-Fi" }
        guard info.associated else { return "연결 안 됨" }
        return info.ssid ?? (locationAuthorized ? "이름 없음" : "이름 숨김")
    }

    /// 주변 네트워크 카드가 비었을 때의 글. scanned: 한 번이라도 검색을 끝냈는가(nearbyAt 이 있음)
    public static func wifiNearbyEmptyText(scanning: Bool, scanned: Bool, failed: Bool, locationAuthorized: Bool) -> String {
        if scanning || (!scanned && !failed) { return "검색 중…" }
        if failed { return "주변 네트워크를 검색하지 못했습니다 · 다시 검색하세요" }
        return locationAuthorized ? "주변 네트워크가 없습니다." : "위치 권한이 없어 네트워크 이름을 읽지 못했습니다."
    }

    // MARK: Ethernet 화면

    /// 머리글 결론 (서비스 판정 하나). loaded: 유선 서비스를 한 번이라도 읽었는가
    public static func ethernetConclusion(loaded: Bool, primary: EthernetAdapter?) -> String {
        guard loaded else { return "확인 중…" }
        guard let primary else { return "연결 안 됨" }
        switch primary.link {
        case .connected: return "연결됨"
        case .noLink: return "링크 없음"
        default: return primary.link.shortText
        }
    }

    /// 상태 카드의 링크 줄. 주소가 없으면 NIC 의 링크는 이 서비스 것이 아니다 (같은 NIC 의 다른 서비스가 그 선을 쓴다) — "–"
    public static func ethernetLinkText(_ adapter: EthernetAdapter) -> String {
        switch adapter.state {
        case .noLink: return "링크 없음"
        case .noAddress: return "–"
        case .connected: return adapter.interface.media ?? "연결됨"
        }
    }
}
