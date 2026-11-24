// 상태 → 색·문구. 사이드바 행과 메뉴바 패널이 같은 판정을 쓰도록 한곳에 둔다.
// 판정·문구는 ServersCore StatusText(테스트 StatusTextTests), 여기는 AppModel 값을 넘기고 단계를 StatusTone 으로 바꾸는 연결만.

import AppKit
import ServersCore
import SwiftUI

extension AppModel {
    // MARK: 망 — 판정·문구는 ServersCore StatusText

    var tailscaleTone: StatusTone { StatusTone(StatusText.tailscaleLevel(status.tailscale)) }

    var tailscaleDetail: String { StatusText.tailscaleDetail(status.tailscale) }

    var lanTone: StatusTone {
        StatusTone(StatusText.lanLevel(status.lan, link: lanLink, adapterPresent: status.lanAdapterPresent))
    }

    var lanDetail: String {
        StatusText.lanDetail(status.lan, service: lan?.service, link: lanLink, adapterPresent: status.lanAdapterPresent)
    }

    /// Wi-Fi 는 WiFiMonitor 가 따로 발행하므로 호출하는 뷰가 그 객체를 관찰해야 갱신된다.
    func wifiTone(_ info: WiFiInfo?) -> StatusTone { StatusTone(StatusText.wifiLevel(info?.statusInput)) }

    func wifiDetail(_ info: WiFiInfo?) -> String {
        StatusText.wifiDetail(info?.statusInput, locationAuthorized: wifi.locationAuthorized)
    }

    var ethernetTone: StatusTone { StatusTone(StatusText.ethernetLevel(ethernetPrimary)) }

    var ethernetDetail: String { StatusText.ethernetDetail(loaded: ethernet != nil, primary: ethernetPrimary) }

    // MARK: 서버

    func remoteTone(_ server: Server) -> StatusTone { StatusTone(StatusText.remoteLevel(status.remote(server.key))) }

    func remoteHelp(_ server: Server) -> String {
        StatusText.remoteHelp(status.remote(server.key), check: server.check, type: server.type, lanName: networkName(.lan))
    }
}

extension WiFiInfo {
    /// 판정에 쓰는 값만 (StatusText.WiFi)
    var statusInput: StatusText.WiFi { StatusText.WiFi(powerOn: powerOn, associated: associated, ssid: ssid) }
}

extension TunnelSession {
    var tone: StatusTone { state.tone }

    /// "3001 → 3000 · 연결됨" (호스트명 없이 포트만)
    var detail: String { StatusText.tunnelDetail(mapping: spec.portMapping, state: state) }
}

extension TransferSession {
    var tone: StatusTone { state.tone }
}

extension MemoryPressure {
    /// 메모리 Pressure 값 문구 (System 화면 · 서버 Live 탭 공통)
    var text: String {
        switch self {
        case .normal: return "정상"
        case .warning: return "경고"
        case .critical: return "위험"
        case .unknown: return "–"
        }
    }
}

extension StatusTone {
    /// ServersCore 판정의 단계 → 색
    init(_ level: StatusLevel) {
        switch level {
        case .good: self = .good
        case .warn: self = .warn
        case .bad: self = .bad
        case .muted: self = .muted
        }
    }

    /// 컨테이너 · 파드 줄의 상태 → 색
    init(_ tone: ContainerItem.Tone) {
        switch tone {
        case .good: self = .good
        case .warn: self = .warn
        case .bad: self = .bad
        case .muted: self = .muted
        }
    }
}
