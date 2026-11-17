// 메뉴바 스위치 행(Wi-Fi·Tailscale·Intranet)의 판정 — 켜짐 · 아래 줄 상태 단어 · 누를 수 있는가 · 누르면 메뉴를 닫는가.
// 화면(MenuBarController)은 이 값을 그리기만 한다. 아래 줄은 상태 단어만 — 수치·이유 문구는 넣지 않는다.

public struct MenuBarSwitch: Sendable, Equatable {
    public enum Kind: Sendable, Equatable, Hashable { case wifi, tailscale, lan }

    public let kind: Kind
    public let isOn: Bool
    public let subtitle: String
    public let isEnabled: Bool

    public static let changingText = "바꾸는 중…"

    /// - busy: 다른 켜기·끄기가 진행 중 (누를 수 없다)
    /// - changing: 이 행이 바꾸는 중 (아래 줄을 "바꾸는 중…"으로)
    init(_ kind: Kind, isOn: Bool, subtitle: String, available: Bool, busy: Bool = false, changing: Bool = false) {
        self.kind = kind
        self.isOn = isOn
        self.subtitle = changing ? Self.changingText : subtitle
        self.isEnabled = available && !busy && !changing
    }

    /// 누르면 메뉴를 닫고 실행하는가 — 인증(Touch ID) 창이나 본창의 확인 창이 뜨는 동작은 메뉴를 열어 둔 채로 하지 않는다.
    public var closesMenuOnToggle: Bool {
        switch kind {
        case .lan: return true          // 켜기·끄기 모두 sudo 인증
        case .tailscale: return isOn    // 끄기는 본창에서 확인을 받는다
        case .wifi: return false
        }
    }

    /// 끄기 확인이 본창에 뜨는가 (닫은 뒤 본창을 연다)
    public var confirmsInWindow: Bool {
        kind == .tailscale && isOn
    }

    // MARK: 망별

    /// powerOn 이 nil 이면 Wi-Fi 인터페이스가 없다
    public static func wifi(powerOn: Bool?, associated: Bool) -> MenuBarSwitch {
        guard let powerOn else { return MenuBarSwitch(.wifi, isOn: false, subtitle: "없음", available: false) }
        let subtitle = !powerOn ? "꺼짐" : associated ? "연결됨" : "연결 안 됨"
        return MenuBarSwitch(.wifi, isOn: powerOn, subtitle: subtitle, available: true)
    }

    public static func tailscale(_ state: TailscaleState, busy: Bool, changing: Bool) -> MenuBarSwitch {
        switch state {
        case .running: return MenuBarSwitch(.tailscale, isOn: true, subtitle: "연결됨", available: true, busy: busy, changing: changing)
        case .stopped: return MenuBarSwitch(.tailscale, isOn: false, subtitle: "꺼짐", available: true, busy: busy, changing: changing)
        case .missing: return MenuBarSwitch(.tailscale, isOn: false, subtitle: "없음", available: false)
        case .unknown: return MenuBarSwitch(.tailscale, isOn: false, subtitle: "알 수 없음", available: true, busy: busy, changing: changing)
        }
    }

    /// .none(설정 없음)이면 행을 두지 않는다 → nil.
    public static func lan(_ state: LanState, busy: Bool, changing: Bool) -> MenuBarSwitch? {
        switch state {
        case .up: return MenuBarSwitch(.lan, isOn: true, subtitle: "켜짐", available: true, busy: busy, changing: changing)
        case .down: return MenuBarSwitch(.lan, isOn: false, subtitle: "꺼짐", available: true, busy: busy, changing: changing)
        case .missing: return MenuBarSwitch(.lan, isOn: false, subtitle: "없음", available: false)
        case .none: return nil
        }
    }
}
