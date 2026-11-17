// 상태 → (단계, 문구). 사이드바 행·메뉴바 패널·서버 정보 머리글·상태 파이프라인이 같은 판정을 쓴다.
// 색은 앱 쪽(StatusTone)이 단계(StatusLevel)로 대응시킨다 — 여기는 색 없이 판정·문구만.

import Foundation

/// 상태 점의 단계. 앱이 StatusTone(초록·노랑·빨강·회색)으로 바꾼다.
public enum StatusLevel: Sendable, Equatable { case good, warn, bad, muted }

public enum StatusText {
    // MARK: 망

    public static func tailscaleLevel(_ state: TailscaleState) -> StatusLevel {
        switch state {
        case .running: return .good
        case .missing, .stopped: return .bad
        case .unknown: return .warn
        }
    }

    public static func tailscaleDetail(_ state: TailscaleState) -> String {
        switch state {
        case .running: return "연결됨"
        case let .stopped(state): return "꺼짐 (\(state))"
        case .missing: return "tailscale 명령 없음"
        case .unknown: return "상태 확인 실패"
        }
    }

    /// 켜져 있을 때는 서비스 판정 하나(link — 어댑터·링크·IP·게이트웨이)로: 연결됨만 초록. link 가 없으면(지정 서비스를 못 읽음) 어댑터 유무로.
    public static func lanLevel(_ state: LanState, link: ServiceLink?, adapterPresent: Bool) -> StatusLevel {
        switch state {
        case .up: return (link?.isConnected ?? adapterPresent) ? .good : .warn
        case .down: return .muted   // 평소엔 일부러 꺼 둔다 (AI 차단 스위치) — 오류가 아니다
        case .missing: return .bad
        case .none: return .muted
        }
    }

    /// service: 지정한 내부망 서비스 이름 (없으면 머리 없이)
    public static func lanDetail(_ state: LanState, service: String?, link: ServiceLink?, adapterPresent: Bool) -> String {
        let service = service.map { "\($0) · " } ?? ""
        let adapter = adapterPresent ? "" : " · 어댑터 없음"
        switch state {
        case .up: return service + (link?.text ?? "활성\(adapter)")
        case .down: return "\(service)비활성\(adapter)"
        case .missing: return "\(service)서비스 없음"
        case .none: return "설정 없음"
        }
    }

    /// Wi-Fi 인터페이스에서 읽은 값 중 판정에 쓰는 것 (앱의 WiFiInfo — CoreWLAN). nil = 인터페이스 없음.
    public struct WiFi: Sendable, Equatable {
        public let powerOn: Bool
        public let associated: Bool
        public let ssid: String?
        public init(powerOn: Bool, associated: Bool, ssid: String?) {
            self.powerOn = powerOn; self.associated = associated; self.ssid = ssid
        }
    }

    public static func wifiLevel(_ info: WiFi?) -> StatusLevel {
        guard let info else { return .muted }
        if !info.powerOn { return .bad }
        return info.associated ? .good : .warn
    }

    /// SSID 는 위치 권한이 있어야 읽힌다 — 연결됐는데 이름이 없으면 권한 여부로 문구를 가른다
    public static func wifiDetail(_ info: WiFi?, locationAuthorized: Bool) -> String {
        guard let info else { return "인터페이스 없음" }
        if !info.powerOn { return "꺼짐" }
        guard info.associated else { return "연결 안 됨" }
        return info.ssid ?? (locationAuthorized ? "연결됨" : "연결됨 · 이름은 위치 권한 필요")
    }

    /// Ethernet: 대표 서비스의 판정(ServiceLink) — 연결 초록 · 링크는 있는데 연결 아님(주소 없음·게이트웨이 응답 없음) 노랑 · 그 밖 회색
    public static func ethernetLevel(_ primary: EthernetAdapter?) -> StatusLevel {
        switch primary?.state {
        case .connected: return .good
        case .noAddress: return .warn
        default: return .muted
        }
    }

    /// "Samsung Hub NIC · en8" — 어느 어댑터(장치)에 붙었는지 보이게. loaded: 유선 서비스를 한 번이라도 읽었는가
    public static func ethernetDetail(loaded: Bool, primary: EthernetAdapter?) -> String {
        guard loaded else { return "확인 중…" }
        guard let primary else { return "연결 안 됨" }
        switch primary.state {
        case .connected: return "\(primary.service) · \(primary.device)"
        case .noAddress: return "\(primary.service) · \(primary.device) · \(primary.link.shortText)"
        case .noLink: return "연결 안 됨"
        }
    }

    // MARK: 서버

    public static func remoteLevel(_ state: RemoteState) -> StatusLevel {
        switch state {
        case .ok: return .good
        case .fail: return .bad
        case .off: return .muted
        case .needsAuth: return .warn
        case .skip: return .muted
        case .pending: return .warn
        }
    }

    /// 원 위 툴팁. 회색(skip)이면 이유(peer offline 등)를 같이 보여 오른쪽 글자 없이도 왜인지 알 수 있게.
    public static func remoteHelp(_ state: RemoteState, check: CheckMethod, type: ServerType, lanName: String) -> String {
        let method = check == .tcp ? "포트" : "SSH 로그인"
        switch state {
        case let .ok(ms): return "\(method) 확인됨 · \(ms)ms"
        case let .fail(ms): return "\(method) 실패 · \(ms)ms"
        case .off: return type == .windows ? "\(method) 응답 없음 · 꺼짐" : "\(method)·ping 응답 없음 · 꺼짐"
        case .needsAuth: return "Tailscale 인증 필요"
        case let .skip(reason): return "확인 안 함 · \(skipReasonText(reason, lanName: lanName))"
        case .pending: return "확인 중"
        }
    }

    /// 서버 정보 머리글의 결론 한 줄. lanName: 내부망 표시 이름 (AppModel.networkName(.lan))
    public static func conclusion(_ state: RemoteState, lanName: String) -> String {
        switch state {
        case .ok: return "접속 가능"   // 응답 시간은 바로 아래 단계 줄(SSH up 3ms)에 있다
        case .fail: return "접속 불가"
        case .off: return "꺼짐"
        case .needsAuth: return "Tailscale 인증 필요"
        case let .skip(reason): return skipReasonText(reason, lanName: lanName)
        case .pending: return "확인 중"
        }
    }

    /// skip 이유(StatusMonitor.SkipReason 의 값) → 머리글 문구. 모르는 이유는 그대로.
    public static func skipReasonText(_ reason: String, lanName: String) -> String {
        switch StatusMonitor.SkipReason(rawValue: reason) {
        case .tailscaleDown: return "Tailscale 꺼짐"
        case .noTailscale: return "tailscale 명령 없음"
        case .tailscaleUnknown: return "Tailscale 상태 확인 실패"
        case .peerOffline: return "Peer offline"
        case .peerMissing: return "피어 없음"
        case .lanDown: return "\(lanName) down"
        case .lanMissing: return "\(lanName) missing"
        case .vpnDown: return "VPN down"
        case .vpnMissing: return "VPN missing"
        case nil: return reason
        }
    }

    // MARK: 상태 파이프라인 (망 → 피어 → SSH/포트)

    public struct PipelineStep: Sendable, Equatable {
        public let label: String
        public let value: String
        public let level: StatusLevel
        public init(label: String, value: String, level: StatusLevel) {
            self.label = label; self.value = value; self.level = level
        }
    }

    /// 서버 정보의 단계 줄. 어디서 막혔는지 한 줄로. lanName: 내부망 표시 이름 (AppModel.networkName(.lan))
    public static func pipeline(_ server: Server, in snapshot: StatusSnapshot, lanName: String) -> [PipelineStep] {
        var out: [PipelineStep] = []
        switch server.network {
        case .tailscale:
            switch snapshot.tailscale {
            case .running: out.append(PipelineStep(label: "Tailscale", value: "up", level: .good))
            case let .stopped(s): out.append(PipelineStep(label: "Tailscale", value: "down (\(s))", level: .bad))
            case .missing: out.append(PipelineStep(label: "Tailscale", value: "missing", level: .bad))
            case .unknown: out.append(PipelineStep(label: "Tailscale", value: "?", level: .warn))
            }
            switch snapshot.peer(server.key) {
            case .online: out.append(PipelineStep(label: "Peer", value: "online", level: .good))
            case .offline: out.append(PipelineStep(label: "Peer", value: "offline", level: .bad))
            case .missing: out.append(PipelineStep(label: "Peer", value: "missing", level: .warn))
            case .unchecked: out.append(PipelineStep(label: "Peer", value: "–", level: .muted))
            }
        case .lan:
            switch snapshot.lan {
            case .up: out.append(PipelineStep(label: lanName, value: snapshot.lanAdapterPresent ? "up" : "up · no adapter",
                                              level: snapshot.lanAdapterPresent ? .good : .warn))
            case .down: out.append(PipelineStep(label: lanName, value: "down", level: .bad))
            case .missing: out.append(PipelineStep(label: lanName, value: "missing", level: .bad))
            case .none: out.append(PipelineStep(label: lanName, value: "not set", level: .muted))
            }
        case .vpn:
            let label = server.vpn ?? "VPN"
            if let link = snapshot.vpnLink(name: server.vpn) {
                out.append(link.device.map { PipelineStep(label: label, value: "up · \($0)", level: .good) }
                           ?? PipelineStep(label: label, value: "down", level: .bad))
            } else {
                out.append(PipelineStep(label: label, value: "missing", level: .bad))
            }
        case .direct:
            break   // 망 설정 없음: 망 단계 없이 SSH 만
        }
        // 라벨은 항상 SSH: check=tcp 도 같은 포트(server.port)를 확인 방식만 다르게 본다 (화면 캡션이 방식을 설명한다).
        // 값은 "ok" 대신 "up": 이 단계가 말하는 건 검사 성공 여부가 아니라 서비스가 떠 있는가다.
        switch snapshot.remote(server.key) {
        case let .ok(ms): out.append(PipelineStep(label: "SSH", value: "up \(ms)ms", level: .good))
        case let .fail(ms): out.append(PipelineStep(label: "SSH", value: "fail \(ms)ms", level: .bad))
        case .off: out.append(PipelineStep(label: "SSH", value: "down", level: .muted))
        case .needsAuth: out.append(PipelineStep(label: "SSH", value: "auth required", level: .warn))
        case .skip: out.append(PipelineStep(label: "SSH", value: "skip", level: .muted))
        case .pending: out.append(PipelineStep(label: "SSH", value: "…", level: .warn))
        }
        return out
    }

    // MARK: 터널

    /// "3001 → 3000 · 연결됨" (호스트명 없이 포트만). mapping: TunnelSpec.portMapping
    public static func tunnelDetail(mapping: String, state: TunnelState) -> String {
        switch state {
        case .idle: return "\(mapping) · 닫힘"
        case .connecting: return "\(mapping) · 연결 중"
        case .open: return "\(mapping) · 연결됨"
        case let .closed(code, message): return "\(mapping) · 끊김 (exit \(code)) \(message.split(separator: "\n").last ?? "")"
        }
    }
}
