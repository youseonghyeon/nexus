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
