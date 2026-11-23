// 사이드바 서버 행의 기기 아이콘 (SF Symbols 이름). 지금은 type 에서 정한다 — 서버마다 고르는 설정은 나중에 여기에 얹는다.

import Foundation

public enum ServerIcon {
    public static func symbol(for type: ServerType) -> String {
        switch type {
        case .linux: return "server.rack"
        case .windows: return "desktopcomputer"
        case .openwrt: return "wifi.router"
        }
    }
}

public extension Server {
    var iconSymbol: String { ServerIcon.symbol(for: type) }
}

/// 사이드바 터널 행의 아이콘 — 종류마다 (2026-11-19 시안 B): SOCKS 는 어디로든 나가니 지구본, 포트는 화살표, DB 는 원통
public enum TunnelIcon {
    public static func symbol(for kind: TunnelKind) -> String {
        switch kind {
        case .socks: return "globe"
        case .port: return "arrow.forward.circle"
        case .db: return "cylinder"
        }
    }
}

/// 사이드바 전송 행의 아이콘 — 방향마다 (2026-11-19 시안 A): 문서에 위·아래 화살표
public enum TransferIcon {
    public static func symbol(for direction: TransferDirection) -> String {
        direction == .upload ? "arrow.up.doc" : "arrow.down.doc"
    }
}
